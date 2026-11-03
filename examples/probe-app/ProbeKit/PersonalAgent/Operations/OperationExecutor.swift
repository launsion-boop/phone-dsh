// SPDX-License-Identifier: MIT

import Foundation

public actor OperationExecutor {
    public typealias Reauthorize = @Sendable () async -> Bool
    public typealias Provider = @Sendable () async throws -> ProviderReceipt

    private let ledger: FileOperationLedger
    private let breaker: CircuitBreaker
    private let undoInterval: TimeInterval
    private let sleep: @Sendable (TimeInterval) async throws -> Void
    private var cancelledIDs: Set<UUID> = []

    public init(ledger: FileOperationLedger, breaker: CircuitBreaker, undoInterval: TimeInterval = 5,
                sleep: (@Sendable (TimeInterval) async throws -> Void)? = nil) {
        self.ledger = ledger
        self.breaker = breaker
        self.undoInterval = undoInterval
        self.sleep = sleep ?? { interval in
            try await Task.sleep(nanoseconds: UInt64(max(0, interval) * 1_000_000_000))
        }
    }

    public func execute(intent: OperationIntent, connectorID: String, effect: ToolEffect,
                        reauthorize: @escaping Reauthorize, provider: @escaping Provider) async throws -> OperationRecord {
        var record = try await ledger.prepare(intent)
        if [.committed, .reconciled, .cancelled, .failed, .unknown].contains(record.phase) { return record }

        if effect == .irreversible {
            record = try await ledger.beginUndoWindow(intent.id)
            do {
                try await sleep(undoInterval)
            } catch {
                if await ledger.record(id: intent.id)?.phase == .undoWindow {
                    return try await ledger.markCancelled(intent.id, reason: "撤销窗口任务已取消；未调用服务")
                }
            }
        }
        if cancelledIDs.contains(intent.id) {
            if let current = await ledger.record(id: intent.id), current.phase == .cancelled { return current }
            return try await ledger.markCancelled(intent.id, reason: "用户在提交前取消；未调用服务")
        }
        guard await reauthorize() else {
            if let current = await ledger.record(id: intent.id), current.phase == .cancelled { return current }
            return try await ledger.markCancelled(intent.id, reason: "恢复时授权复核失败；未调用服务")
        }

        try await ledger.markCommitting(intent.id)
        do {
            try await breaker.recordOperation(connectorID: connectorID)
        } catch {
            _ = try await ledger.markFailed(intent.id, reason: "无法记录操作限额；未调用服务")
            throw error
        }
        let receipt: ProviderReceipt
        do {
            receipt = try await provider()
        } catch {
            let reason = "服务调用结果未知：\(String(describing: error))；不会自动重发"
            try await ledger.markUnknown(intent.id, reason: reason)
            try await breaker.recordProviderFailure(connectorID: connectorID)
            try await breaker.setUnknown(connectorID: connectorID, operationID: intent.id, isUnknown: true)
            cancelledIDs.remove(intent.id)
            return await ledger.record(id: intent.id)!
        }
        do {
            try await ledger.commit(intent.id, receipt: receipt)
        } catch {
            if let current = await ledger.record(id: intent.id), current.phase == .committed { return current }
            try await ledger.markUnknown(intent.id, reason: "服务已返回回执，但回执持久化失败；等待对账且不会自动重发")
            try await breaker.setUnknown(connectorID: connectorID, operationID: intent.id, isUnknown: true)
            return await ledger.record(id: intent.id)!
        }
        try await breaker.recordProviderSuccess(connectorID: connectorID)
        try await breaker.setUnknown(connectorID: connectorID, operationID: intent.id, isUnknown: false)
        cancelledIDs.remove(intent.id)
        return await ledger.record(id: intent.id)!
    }

    public func cancel(id: UUID) async throws {
        guard let record = await ledger.record(id: id),
              [.prepared, .undoWindow].contains(record.phase) else { return }
        cancelledIDs.insert(id)
        _ = try await ledger.markCancelled(id, reason: "用户在提交前取消；未调用服务")
    }
}

public protocol OperationReconciling: Sendable {
    var connectorID: String { get }
    func reconcile(_ record: OperationRecord) async throws -> ProviderReceipt?
}

public struct OperationRecovery: Sendable {
    private let ledger: FileOperationLedger
    private let breaker: CircuitBreaker
    private let reconcilers: [any OperationReconciling]

    public init(ledger: FileOperationLedger, breaker: CircuitBreaker,
                reconcilers: [any OperationReconciling] = []) {
        self.ledger = ledger
        self.breaker = breaker
        self.reconcilers = reconcilers
    }

    public func recover() async throws -> [OperationRecord] {
        _ = try await ledger.recoverAfterProcessRestart()
        for record in await ledger.pending() where record.phase == .unknown {
            guard let reconciler = reconcilers.first(where: { record.intent.toolName.hasPrefix($0.connectorID + ".") }) else {
                continue
            }
            let receipt = try await reconciler.reconcile(record)
            if let receipt {
                _ = try await ledger.reconcile(record.id, receipt: receipt)
                try await breaker.recordProviderSuccess(connectorID: reconciler.connectorID)
            }
            try await breaker.setUnknown(connectorID: reconciler.connectorID, operationID: record.id,
                                         isUnknown: receipt == nil)
        }
        return await ledger.pending()
    }
}
