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
    @ObservationIgnored private let ingress: MainIngress?
    @ObservationIgnored private let suggestionGenerator: (any StructuredSuggestionGenerating)?
    @ObservationIgnored private let suggestionStore: SuggestionStore?
    @ObservationIgnored private let userLanguage: @Sendable () -> String
    @ObservationIgnored private var suggestionTask: Task<Void, Never>?
    @ObservationIgnored private var suggestionTurnID: UUID?

    public let conversationID: UUID
    public let principal: String
    public let accountID: String
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
    public private(set) var suggestion: SuggestionCard?
    public private(set) var isRunning = false
    public private(set) var didLoad = false
    @ObservationIgnored private var responseBuffer = ""
    @ObservationIgnored private var currentTurnID: UUID?
    @ObservationIgnored private var pendingAnswer: (turn: ConversationTurn, message: AssistantMessage)?
    @ObservationIgnored private var operationPollingTask: Task<Void, Never>?

    public var streamingText: String {
        PersonalAgentTextPolicy.visibleAssistantText(responseBuffer, allowEmpty: true)
    }

    public var followUpSummary: String? {
        guard !followUpRecords.isEmpty else { return nil }
        let attention = followUpRecords.filter(\.needsAttention).count
        return "跟进中 \(followUpRecords.count)" + (attention > 0 ? " · 需要你处理 \(attention)" : "")
    }

    public init(conversationID: UUID, principal: String, accountID: String = "local",
                agent: any MainAgentPort, conversations: ConversationStore, memories: MemoryStore,
                followUps: FollowUpStore, operations: (any OperationLedger)? = nil, ingress: MainIngress? = nil,
                suggestionGenerator: (any StructuredSuggestionGenerating)? = nil,
                suggestionStore: SuggestionStore? = nil,
                userLanguage: @escaping @Sendable () -> String = { Locale.preferredLanguages.first ?? "en" }) {
        self.conversationID = conversationID
        self.principal = principal
        self.accountID = accountID
        self.agent = agent
        self.conversations = conversations
        self.memories = memories
        self.followUps = followUps
        self.operations = operations
        self.ingress = ingress
        self.suggestionGenerator = suggestionGenerator
        self.suggestionStore = suggestionStore
        self.userLanguage = userLanguage
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
            await reloadSuggestions()
            if pendingQuestion == nil, !queuedTurns.isEmpty { await processQueue() }
        } catch {
            didLoad = false
            failureNotice = error.localizedDescription
        }
    }

    public func send(_ text: String? = nil, selection: SuggestionSelection? = nil) async {
        let content = (text ?? draft).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty, isModelConfigured else { return }
        if text == nil { draft = "" }
        failureNotice = nil
        suggestionTask?.cancel()
        let requestID = UUID()
        let source = SourceEnvelope(requestID: requestID, principal: principal, source: .phone,
                                    replyTo: .phoneChat, grantVersion: 0, receivedAt: Date())
        do {
            if let suggestion, suggestion.outcome == .shown {
                try await suggestionStore?.supersede(cardID: suggestion.cardID)
            }
            if let suggestionTurnID {
                try await suggestionStore?.supersede(turnID: suggestionTurnID, scope: suggestionScope)
            }
            suggestion = nil
            suggestionTurnID = nil
            if let ingress {
                if let selection {
                    _ = try await ingress.ingestSelection(envelope: source, selection: selection)
                } else {
                    _ = try await ingress.ingest(envelope: source, userText: content)
                }
            }
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
        suggestionTask?.cancel()
        guard let currentTurnID else { return }
        await agent.cancel(turnID: currentTurnID)
    }

    public func undoOperation(_ id: UUID) async {
        guard operationRecords.contains(where: { $0.id == id && $0.phase == .undoWindow }) else { return }
        await cancel()
    }

    public func dismissSuggestion() async {
        guard let suggestion else { return }
        let cardID = suggestion.cardID
        self.suggestion = nil
        do {
            try await suggestionStore?.dismiss(cardID: cardID)
        } catch {
            failureNotice = "关闭状态未能持久保存。"
        }
    }

    public func declineSuggestion() async {
        guard let suggestion else { return }
        let cardID = suggestion.cardID
        self.suggestion = nil
        do {
            try await suggestionStore?.decline(cardID: cardID)
        } catch {
            failureNotice = "拒绝状态未能持久保存。"
        }
    }

    public func chooseSuggestion(_ option: SuggestionOption, selectionEventID: UUID = UUID()) async {
        guard let suggestion else { return }
        do {
            guard let result = try await suggestionStore?.select(
                cardID: suggestion.cardID, optionID: option.id, selectionEventID: selectionEventID),
                  result.shouldSend else {
                self.suggestion = nil
                return
            }
            self.suggestion = nil
            await send(result.textToSend, selection: result.selection)
        } catch {
            self.suggestion = nil
            failureNotice = "选择未能持久保存，未发起后续操作。"
        }
    }

    public func answerPendingQuestion(_ answer: String) async {
        guard let question = pendingQuestion else { return }
        do {
            var selection: SuggestionSelection?
            if let card = try await suggestionStore?.outstanding(scope: suggestionScope)
                .first(where: { $0.cardID == question.id && $0.kind == .clarification }) {
                if let option = card.options.first(where: { $0.label == answer }) {
                    let result = try await suggestionStore?.select(cardID: card.cardID, optionID: option.id)
                    if let result, result.shouldSend { selection = result.selection }
                } else {
                    try await suggestionStore?.supersede(cardID: card.cardID)
                }
            }
            try await conversations.resolveQuestion(question.id)
            if let pendingAnswer {
                try await conversations.complete(pendingAnswer.turn, message: pendingAnswer.message)
                self.pendingAnswer = nil
                try await reloadMessages()
            }
            pendingQuestion = nil
            await send(selection?.visibleLabel ?? answer, selection: selection)
        } catch {
            failureNotice = error.localizedDescription
        }
    }

    public func dismissPendingQuestion() async {
        guard let question = pendingQuestion else { return }
        do {
            if let card = try await suggestionStore?.outstanding(scope: suggestionScope)
                .first(where: { $0.cardID == question.id && $0.kind == .clarification }) {
                try await suggestionStore?.dismiss(cardID: card.cardID)
            }
            try await conversations.resolveQuestion(question.id)
            if let waiting = try await conversations.turns(conversationID: conversationID)
                .first(where: { $0.state == .waitingForUser }) {
                try await conversations.fail(waiting.id, reason: "问题已关闭，任务暂停。", interrupted: true)
            }
            pendingAnswer = nil
            pendingQuestion = nil
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
        startOperationPolling()
        defer {
            operationPollingTask?.cancel()
            operationPollingTask = nil
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
                var input = turn.input
                if let ingress {
                    guard let mandate = await ingress.mandate(for: turn.requestID) else {
                        throw MainFailure.invalidResponse("当前回合缺少已持久化的用户委托")
                    }
                    input = MainTurnInput(turnID: turn.id, requestID: turn.requestID,
                                          principal: turn.principal, conversationID: turn.conversationID,
                                          text: turn.text, mandate: mandate)
                }
                let stream = agent.run(turn: input)
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
                        let waitsForClarification = await generateSuggestions(for: input, answer: message)
                        if waitsForClarification {
                            pendingAnswer = (turn, message)
                        } else {
                            try await conversations.complete(turn, message: message)
                            pendingQuestion = nil
                            try await reloadMessages()
                        }
                        responseBuffer = ""
                        activeStatus = nil
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

    private var suggestionScope: SuggestionScope {
        SuggestionScope(conversationID: conversationID, principal: principal, accountID: accountID)
    }

    private func generateSuggestions(for turn: MainTurnInput, answer: AssistantMessage) async -> Bool {
        guard let suggestionGenerator, let suggestionStore else { return false }
        suggestionTask?.cancel()
        suggestion = nil
        suggestionTurnID = turn.turnID
        do {
            let metadata = SuggestionHostMetadata(
                accountID: accountID,
                suppressionHistory: await suggestionStore.suppressionHistory(),
                userLanguage: userLanguage())
            let result = await suggestionGenerator.generateCard(turn: turn, answer: answer,
                                                                metadata: metadata)
            guard !Task.isCancelled else { return false }
            switch result {
            case .none, .suppressed:
                self.suggestion = nil
            case .card(let card):
                guard let shown = try await suggestionStore.shown(card) else {
                    self.suggestion = nil
                    return false
                }
                if shown.kind == .clarification {
                    let question = PendingQuestion(id: shown.cardID, text: shown.question,
                                                   choices: shown.options.map(\.label))
                    try await conversations.recordQuestion(question, turnID: turn.turnID)
                    pendingQuestion = question
                    self.suggestion = nil
                    return true
                }
                self.suggestion = shown
            }
        } catch {
            self.suggestion = nil
        }
        return false
    }

    private func reloadSuggestions() async {
        guard let suggestionStore else { return }
        do {
            let outstanding = try await suggestionStore.outstanding(scope: suggestionScope)
            if let card = outstanding.first(where: { $0.kind == .nextSteps }) {
                suggestion = card
            } else {
                suggestion = nil
            }
            if let clarification = outstanding.first(where: { $0.kind == .clarification }), pendingQuestion == nil {
                pendingQuestion = PendingQuestion(id: clarification.cardID, text: clarification.question,
                                                  choices: clarification.options.map(\.label))
            }
        } catch {
            suggestion = nil
            recoveryNotice = "建议状态无法读取，原始文件已保留；相关操作已停止。"
        }
    }

    private func startOperationPolling() {
        operationPollingTask?.cancel()
        operationPollingTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.reloadOperations()
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
    }

    private func reloadOperations() async {
        if let operations { operationRecords = await operations.pending() }
    }

    private func reload() async throws {
        try await reloadMessages()
        pendingQuestion = try await conversations.pendingQuestions(conversationID: conversationID).last
        candidates = try await memories.pendingCandidates(principal: principal)
        followUpRecords = try await followUps.records(principal: principal, accountScope: accountID)
        if let operations { operationRecords = await operations.pending() }
        await reloadSuggestions()
    }

    private func reloadMessages() async throws {
        messages = try await conversations.messages(conversationID: conversationID, limit: 100)
    }
}
