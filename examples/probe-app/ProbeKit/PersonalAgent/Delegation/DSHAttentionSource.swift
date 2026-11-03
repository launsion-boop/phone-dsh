// SPDX-License-Identifier: MIT

import Foundation

public enum DSHAttentionOrigin: Sendable, Equatable {
    case direct
    case delegated(requestID: UUID)
}

public struct DSHOperationAttention: Sendable {
    public let operation: OperationRecord
    public let origin: DSHAttentionOrigin
    public let sessionID: String

    public init(operation: OperationRecord, origin: DSHAttentionOrigin, sessionID: String) {
        self.operation = operation
        self.origin = origin
        self.sessionID = sessionID
    }
}

public actor DSHAttentionSource: AttentionSource {
    public nonisolated let owner: AttentionOwner = .dsh

    private var attentionItems: [UUID: AttentionItem] = [:]
    private var continuations: [UUID: AsyncStream<[AttentionItem]>.Continuation] = [:]

    public init() {}

    public nonisolated func items() -> AsyncStream<[AttentionItem]> {
        AsyncStream { continuation in
            Task {
                await addContinuation(continuation)
            }
        }
    }

    public func recordApproval(id: UUID = UUID(), toolName: String, sessionID: String,
                               origin: DSHAttentionOrigin) {
        attentionItems[id] = AttentionItem(
            id: id, title: "DSH 写入待审批",
            reason: "\(toolName) 需要用户在对应 DSH 会话逐项确认",
            route: .dsh(sessionID: sessionID, approvalID: id.uuidString))
        publish()
    }

    public func synchronize(operations: [DSHOperationAttention]) {
        let activeIDs = Set(operations.map { $0.operation.id })
        let staleIDs = attentionItems.values.filter {
            $0.title != "DSH 写入待审批" && !activeIDs.contains($0.id)
        }.map(\.id)
        for id in staleIDs { attentionItems.removeValue(forKey: id) }
        for entry in operations {
            let record = entry.operation
            let title: String
            switch record.phase {
            case .unknown:
                title = "DSH 操作待对账"
            case .failed:
                title = "DSH 操作待恢复"
            default:
                attentionItems.removeValue(forKey: record.id)
                continue
            }
            attentionItems[record.id] = AttentionItem(
                id: record.id, title: title,
                reason: record.failureReason ?? "需要用户确认最终状态",
                route: .dsh(sessionID: entry.sessionID, approvalID: nil))
        }
        publish()
    }

    public func resolve(id: UUID) {
        attentionItems.removeValue(forKey: id)
        publish()
    }

    public func currentItems() -> [AttentionItem] {
        sortedItems()
    }

    private func addContinuation(_ continuation: AsyncStream<[AttentionItem]>.Continuation) {
        let id = UUID()
        continuations[id] = continuation
        continuation.yield(sortedItems())
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeContinuation(id) }
        }
    }

    private func removeContinuation(_ id: UUID) {
        continuations.removeValue(forKey: id)
    }

    private func publish() {
        let items = sortedItems()
        for continuation in continuations.values { continuation.yield(items) }
    }

    private func sortedItems() -> [AttentionItem] {
        attentionItems.values.sorted { $0.id.uuidString < $1.id.uuidString }
    }
}
