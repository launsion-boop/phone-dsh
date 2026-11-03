// SPDX-License-Identifier: MIT

import Foundation

public enum OperationLedgerError: Error, Equatable {
    case missing(UUID)
    case invalidTransition(OperationPhase, OperationPhase)
    case intentConflict(UUID)
    case unknownConflict(UUID)
    case invalidReceipt
}

public actor FileOperationLedger: OperationLedger {
    private let fileURL: URL
    private var records: [UUID: OperationRecord]
    private let now: @Sendable () -> Date

    public init(root: URL, now: @escaping @Sendable () -> Date = Date.init) throws {
        fileURL = root.appendingPathComponent("op/operations.json")
        records = try S4Persistence.load([UUID: OperationRecord].self, from: fileURL) ?? [:]
        self.now = now
    }

    public func prepare(_ intent: OperationIntent) async throws -> OperationRecord {
        if let existing = records[intent.id] {
            guard existing.intent == intent else { throw OperationLedgerError.intentConflict(intent.id) }
            return existing
        }
        if let conflict = records.values.first(where: {
            $0.phase == .unknown && $0.intent.digest == intent.digest
        }) {
            throw OperationLedgerError.unknownConflict(conflict.id)
        }
        let record = OperationRecord(id: intent.id, intent: intent, phase: .prepared,
                                     createdAt: now(), updatedAt: now())
        try update(record)
        return record
    }

    public func beginUndoWindow(_ id: UUID) throws -> OperationRecord {
        try transition(id, from: [.prepared], to: .undoWindow)
    }

    public func markCommitting(_ id: UUID) async throws {
        _ = try transition(id, from: [.prepared, .undoWindow], to: .committing)
    }

    public func commit(_ id: UUID, receipt: ProviderReceipt) async throws {
        guard !receipt.providerObjectID.isEmpty else { throw OperationLedgerError.invalidReceipt }
        _ = try transition(id, from: [.committing], to: .committed) { record in
            record.receipt = receipt
            record.failureReason = nil
        }
    }

    public func markUnknown(_ id: UUID, reason: String) async throws {
        _ = try transition(id, from: [.committing, .unknown], to: .unknown) { record in
            record.failureReason = reason
        }
    }

    public func markCancelled(_ id: UUID, reason: String = "用户取消或撤销窗口恢复") throws -> OperationRecord {
        try transition(id, from: [.prepared, .undoWindow], to: .cancelled) { record in
            record.failureReason = reason
        }
    }

    public func markFailed(_ id: UUID, reason: String) throws -> OperationRecord {
        try transition(id, from: [.prepared, .undoWindow, .committing], to: .failed) { record in
            record.failureReason = reason
        }
    }

    public func reconcile(_ id: UUID, receipt: ProviderReceipt?) async throws -> OperationRecord {
        if let receipt {
            guard !receipt.providerObjectID.isEmpty else { throw OperationLedgerError.invalidReceipt }
            return try transition(id, from: [.unknown, .committing], to: .reconciled) { record in
                record.receipt = receipt
                record.failureReason = nil
            }
        }
        return try transition(id, from: [.committing], to: .unknown) { record in
            record.failureReason = "进程恢复后结果未知；不会自动重发"
        }
    }

    public func recoverAfterProcessRestart() throws -> [OperationRecord] {
        let snapshot = records.values.sorted { $0.createdAt < $1.createdAt }
        for record in snapshot {
            switch record.phase {
            case .prepared, .undoWindow:
                _ = try transition(record.id, from: [record.phase], to: .cancelled) { updated in
                    updated.failureReason = "进程在提交前退出；已取消且不会补发"
                }
            case .committing:
                _ = try transition(record.id, from: [.committing], to: .unknown) { updated in
                    updated.failureReason = "进程退出时提交结果未知；等待对账且不会自动重发"
                }
            default:
                break
            }
        }
        return records.values.filter { [.prepared, .undoWindow, .committing, .unknown].contains($0.phase) }
            .sorted { $0.createdAt < $1.createdAt }
    }

    public func pending() async -> [OperationRecord] {
        records.values.filter { [.prepared, .undoWindow, .committing, .unknown].contains($0.phase) }
            .sorted { $0.createdAt < $1.createdAt }
    }

    public func record(id: UUID) -> OperationRecord? {
        records[id]
    }

    public func all() -> [OperationRecord] {
        records.values.sorted { $0.createdAt < $1.createdAt }
    }

    private func transition(_ id: UUID, from phases: [OperationPhase], to phase: OperationPhase,
                            mutate: ((inout OperationRecord) -> Void)? = nil) throws -> OperationRecord {
        guard var record = records[id] else { throw OperationLedgerError.missing(id) }
        guard phases.contains(record.phase) else {
            throw OperationLedgerError.invalidTransition(record.phase, phase)
        }
        record.phase = phase
        record.updatedAt = now()
        mutate?(&record)
        try update(record)
        return record
    }

    private func update(_ record: OperationRecord) throws {
        var updated = records
        updated[record.id] = record
        try S4Persistence.save(updated, to: fileURL)
        records = updated
    }
}
