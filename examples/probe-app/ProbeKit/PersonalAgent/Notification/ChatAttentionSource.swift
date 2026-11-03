// SPDX-License-Identifier: MIT

import Foundation

public final class ChatAttentionSource: AttentionSource, @unchecked Sendable {
    public let owner: AttentionOwner = .chat

    private let conversationID: UUID
    private let conversations: ConversationStore
    private let followUps: FollowUpStore
    private let operations: (any OperationLedger)?
    private let lock = NSLock()
    private var current: [AttentionItem] = []
    private var continuations: [UUID: AsyncStream<[AttentionItem]>.Continuation] = [:]

    public init(conversationID: UUID, conversations: ConversationStore,
                followUps: FollowUpStore, operations: (any OperationLedger)? = nil) {
        self.conversationID = conversationID
        self.conversations = conversations
        self.followUps = followUps
        self.operations = operations
    }

    public func items() -> AsyncStream<[AttentionItem]> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let id = UUID()
            lock.lock()
            continuations[id] = continuation
            let initial = current
            lock.unlock()
            continuation.yield(initial)
            continuation.onTermination = { _ in
                self.lock.lock()
                self.continuations.removeValue(forKey: id)
                self.lock.unlock()
            }
        }
    }

    @discardableResult
    public func refresh() async throws -> [AttentionItem] {
        var items: [AttentionItem] = []
        for question in try await conversations.pendingQuestions(conversationID: conversationID) {
            items.append(AttentionItem(id: question.id, title: "Personal Agent 需要你回答",
                                       reason: question.text, route: .chat(focus: nil)))
        }
        for turn in try await conversations.turns(conversationID: conversationID)
        where turn.state == .failed || turn.state == .interrupted {
            items.append(AttentionItem(id: turn.id, title: "回复需要恢复",
                                       reason: turn.failure ?? "请查看恢复方式",
                                       route: .chat(focus: .message(turn.userMessageID))))
        }
        for record in try await followUps.records() where record.needsAttention {
            items.append(AttentionItem(id: record.id, title: "跟进需要你处理",
                                       reason: record.lastChangeSummary ?? record.followUp.goal,
                                       route: .chat(focus: .followUp(record.id))))
        }
        if let operations {
            for operation in await operations.pending() where operation.phase == .unknown {
                items.append(AttentionItem(id: operation.id, title: "正在确认最终结果",
                                           reason: operation.failureReason ?? "请勿重复执行相同操作",
                                           route: .chat(focus: .operation(operation.id))))
            }
        }
        let updated = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            .values.sorted { $0.id.uuidString < $1.id.uuidString }
        lock.lock()
        current = updated
        let targets = Array(continuations.values)
        lock.unlock()
        for continuation in targets { continuation.yield(updated) }
        return updated
    }
}
