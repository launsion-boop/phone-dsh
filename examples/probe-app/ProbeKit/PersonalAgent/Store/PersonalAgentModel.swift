// SPDX-License-Identifier: MIT

import Foundation
import Observation

public enum PersonalAgentSourceSelection: String, Sendable, CaseIterable {
    case automatic, github, gmail, files
}

@MainActor
@Observable
public final class PersonalAgentModel {
    @ObservationIgnored private let agent: any MainAgentPort
    @ObservationIgnored public let conversations: ConversationStore
    @ObservationIgnored public let memories: MemoryStore
    @ObservationIgnored public let followUps: FollowUpStore
    @ObservationIgnored private let operations: (any OperationLedger)?

    public let conversationID: UUID
    public let principal: String
    public var draft = ""
    public var sourceSelection: PersonalAgentSourceSelection = .automatic
    public var isModelConfigured = true
    public private(set) var messages: [ConversationMessage] = []
    public private(set) var activeStatus: StatusLine?
    public private(set) var queuedTurns: [ConversationTurn] = []
    public private(set) var pendingQuestion: PendingQuestion?
    public private(set) var failureNotice: String?
    public private(set) var recoveryNotice: String?
    public private(set) var candidates: [MemoryRecord] = []
    public private(set) var followUpRecords: [FollowUpRecord] = []
    public private(set) var operationRecords: [OperationRecord] = []
    public private(set) var isRunning = false
    public private(set) var didLoad = false
    @ObservationIgnored private var responseBuffer = ""
    @ObservationIgnored private var currentTurnID: UUID?

    public var streamingText: String {
        PersonalAgentTextPolicy.visibleAssistantText(responseBuffer, allowEmpty: true)
    }

    public var followUpSummary: String? {
        guard !followUpRecords.isEmpty else { return nil }
        let attention = followUpRecords.filter(\.needsAttention).count
        return "跟进中 \(followUpRecords.count)" + (attention > 0 ? " · 需要你处理 \(attention)" : "")
    }

    public init(conversationID: UUID, principal: String, agent: any MainAgentPort,
                conversations: ConversationStore, memories: MemoryStore, followUps: FollowUpStore,
                operations: (any OperationLedger)? = nil) {
        self.conversationID = conversationID
        self.principal = principal
        self.agent = agent
        self.conversations = conversations
        self.memories = memories
        self.followUps = followUps
        self.operations = operations
    }

    public func load() async {
        guard !didLoad else { return }
        didLoad = true
        do {
            try await conversations.prepare()
            try await memories.prepare()
            try await followUps.prepare()
            let recovery = try await conversations.recover(conversationID: conversationID)
            queuedTurns = recovery.queuedTurns
            if !recovery.interruptedTurns.isEmpty {
                recoveryNotice = "有 \(recovery.interruptedTurns.count) 次执行被中断，未自动重放。请确认后继续。"
            }
            try await reload()
            if pendingQuestion == nil, !queuedTurns.isEmpty { await processQueue() }
        } catch {
            didLoad = false
            failureNotice = error.localizedDescription
        }
    }

    public func send(_ text: String? = nil) async {
        let content = (text ?? draft).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty, isModelConfigured else { return }
        if text == nil { draft = "" }
        failureNotice = nil
        let requestID = UUID()
        let source = SourceEnvelope(requestID: requestID, principal: principal, source: .phone,
                                    replyTo: .phoneChat, grantVersion: 0, receivedAt: Date())
        do {
            _ = try await memories.ingestUserInstruction(
                content, principal: principal,
                source: MemorySource(kind: .phone, reference: requestID.uuidString, detail: "用户在 Chat 中明确要求记住"))
            let turn = try await conversations.enqueue(text: content, source: source, conversationID: conversationID)
            queuedTurns.append(turn)
            try await reloadMessages()
            if !isRunning { await processQueue() }
        } catch {
            failureNotice = error.localizedDescription
        }
    }

    public func cancel() async {
        guard let currentTurnID else { return }
        await agent.cancel(turnID: currentTurnID)
    }

    public func answerPendingQuestion(_ answer: String) async {
        guard let question = pendingQuestion else { return }
        do {
            try await conversations.resolveQuestion(question.id)
            pendingQuestion = nil
            await send(answer)
        } catch {
            failureNotice = error.localizedDescription
        }
    }

    public func acceptCandidate(_ id: UUID) async {
        do {
            _ = try await memories.acceptCandidate(id)
            candidates = try await memories.pendingCandidates(principal: principal)
        } catch {
            failureNotice = error.localizedDescription
        }
    }

    public func rejectCandidate(_ id: UUID) async {
        do {
            try await memories.rejectCandidate(id)
            candidates = try await memories.pendingCandidates(principal: principal)
        } catch {
            failureNotice = error.localizedDescription
        }
    }

    public func publishDailyBrief(snapshot: DailyBriefSnapshot, newItemCount: Int) async {
        guard let artifact = DailyBriefChatArtifact.make(snapshot: snapshot, newItemCount: newItemCount),
              !messages.contains(where: { $0.artifacts.contains(where: { $0.id == artifact.id }) }) else { return }
        do {
            try await conversations.appendArtifact(artifact, conversationID: conversationID,
                                                   text: "每日简报已更新，可展开查看。")
            try await reloadMessages()
        } catch {
            failureNotice = error.localizedDescription
        }
    }

    public func foreground() async {
        do {
            try await reload()
        } catch {
            failureNotice = error.localizedDescription
        }
    }

    public func loadOlderMessages() async {
        do {
            let older = try await conversations.messages(conversationID: conversationID,
                                                         before: messages.first?.sequence, limit: 50)
            messages = older + messages
        } catch {
            failureNotice = error.localizedDescription
        }
    }

    private func processQueue() async {
        guard !isRunning else { return }
        isRunning = true
        defer {
            isRunning = false
            currentTurnID = nil
        }
        while !queuedTurns.isEmpty {
            let turn = queuedTurns.removeFirst()
            currentTurnID = turn.id
            responseBuffer = ""
            activeStatus = StatusLine(text: "正在准备", phase: .preparing)
            pendingQuestion = nil
            do {
                try await conversations.markRunning(turn.id)
                let stream = agent.run(turn: turn.input)
                for try await event in stream {
                    switch event {
                    case .status(let status):
                        activeStatus = status
                        try await conversations.recordStatus(status, turnID: turn.id)
                    case .textDelta(let delta):
                        responseBuffer += delta
                    case .toolCall, .toolResult:
                        break
                    case .question(let question):
                        pendingQuestion = question
                        try await conversations.recordQuestion(question, turnID: turn.id)
                    case .completed(let message):
                        try await conversations.complete(turn, message: message)
                        responseBuffer = ""
                        activeStatus = nil
                        pendingQuestion = nil
                        try await reloadMessages()
                    case .failed(let failure):
                        let visible = PersonalAgentTextPolicy.failureText(failure)
                        try await conversations.fail(turn.id, reason: visible)
                        failureNotice = visible
                        responseBuffer = ""
                        activeStatus = nil
                    }
                }
                if try await conversations.turn(turn.id)?.state == .waitingForUser { break }
            } catch is CancellationError {
                try? await conversations.fail(turn.id, reason: "已停止，未自动重试。", interrupted: true)
                failureNotice = "已停止，未自动重试。"
                responseBuffer = ""
                activeStatus = nil
            } catch {
                let visible = "处理被中断，请稍后重试。"
                try? await conversations.fail(turn.id, reason: visible, interrupted: true)
                failureNotice = visible
                responseBuffer = ""
                activeStatus = nil
            }
        }
        do {
            candidates = try await memories.pendingCandidates(principal: principal)
            try await reload()
        } catch {
            failureNotice = error.localizedDescription
        }
    }

    private func reload() async throws {
        try await reloadMessages()
        pendingQuestion = try await conversations.pendingQuestions(conversationID: conversationID).last
        candidates = try await memories.pendingCandidates(principal: principal)
        followUpRecords = try await followUps.records()
        if let operations { operationRecords = await operations.pending() }
    }

    private func reloadMessages() async throws {
        messages = try await conversations.messages(conversationID: conversationID, limit: 100)
    }
}
