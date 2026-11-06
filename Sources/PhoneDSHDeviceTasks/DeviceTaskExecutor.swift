// SPDX-License-Identifier: MIT
import Foundation

/// The binding sends only confirmed acceptance and terminal reports.
public protocol DeviceTaskInbox: Sendable {
    func accept(id: String) async throws
    func report(id: String, outcome: DeviceTaskOutcome) async throws
}

/// A runner must verify its isolated no-tools DSH scope before accepting work.
public protocol DeviceTaskRunner: Sendable {
    func session(for deviceID: String) async throws -> String
    func run(task: DeviceTask, record: DeviceTaskRecord) async -> DeviceTaskOutcome
    func cancel(sessionID: String) async
}

/// Serializes every operation for a device and persists intent before effects.
public actor DeviceTaskExecutor {
    private let journal: DeviceTaskJournal
    private let runner: any DeviceTaskRunner
    private let clock: @Sendable () -> Date
    private var activeDevices = Set<String>()

    public init(directory: URL, runner: any DeviceTaskRunner,
                clock: @escaping @Sendable () -> Date = { Date() }) throws {
        self.journal = try DeviceTaskJournal(directory: directory)
        self.runner = runner
        self.clock = clock
    }

    public func process(deviceID: String, task: DeviceTask, authorized: Bool,
                        inbox: any DeviceTaskInbox) async throws {
        guard authorized else { throw DeviceTaskError.unauthorized }
        guard activeDevices.insert(deviceID).inserted else { throw DeviceTaskError.deviceBusy }
        defer { activeDevices.remove(deviceID) }
        var record: DeviceTaskRecord
        if let existing = try journal.find(deviceID: deviceID, key: task.idempotencyKey) {
            guard existing.task == task else { throw DeviceTaskError.idempotencyConflict }
            record = existing
            if record.phase == .terminal {
                guard let outcome = record.outcome else { throw DeviceTaskError.corruptJournal }
                try await inbox.report(id: task.id, outcome: outcome)
                return
            }
            if record.phase == .accepted || record.phase == .running {
                try await finish(&record, outcome: .failed(kind: .unknownOutcome,
                    message: "Previous execution was interrupted; its outcome is unknown."), inbox: inbox)
                return
            }
        } else {
            let session = try await runner.session(for: deviceID)
            record = try journal.create(deviceID: deviceID, task: task, sessionID: session, now: clock())
        }

        // A lost accept response is safe to retry: no task has been dispatched.
        try await inbox.accept(id: task.id)
        record.phase = .accepted
        try journal.save(record)
        if Int64(clock().timeIntervalSince1970 * 1000) >= record.deadlineMS {
            try await finish(&record, outcome: .failed(kind: .expired, message: "Task expired before submission."), inbox: inbox)
            return
        }
        record.phase = .running
        try journal.save(record)
        let outcome = await runWithDeadline(task: task, record: record)
        try await finish(&record, outcome: outcome, inbox: inbox)
    }

    private func runWithDeadline(task: DeviceTask, record: DeviceTaskRecord) async -> DeviceTaskOutcome {
        let seconds = max(0, Double(record.deadlineMS) / 1000 - clock().timeIntervalSince1970)
        return await withTaskGroup(of: DeviceTaskOutcome.self) { group in
            group.addTask { await self.runner.run(task: task, record: record) }
            group.addTask {
                do { try await Task.sleep(for: .seconds(seconds)) }
                catch { return .failed(kind: .unknownOutcome, message: "Task was interrupted.") }
                await self.runner.cancel(sessionID: record.sessionID)
                return .failed(kind: .unknownOutcome, message: "Task deadline elapsed after submission.")
            }
            let result = await group.next() ?? .failed(kind: .unknownOutcome, message: "Task outcome is unknown.")
            group.cancelAll()
            return result
        }
    }

    private func finish(_ record: inout DeviceTaskRecord, outcome: DeviceTaskOutcome,
                        inbox: any DeviceTaskInbox) async throws {
        let bounded: DeviceTaskOutcome
        switch outcome {
        case .completed(let output, let truncated):
            if case .completed(let text, let didTruncate) = DeviceTaskOutcome.boundedOutput(output) {
                bounded = .completed(output: text, truncated: truncated || didTruncate)
            } else { bounded = .failed(kind: .failed, message: "Invalid result.") }
        case .failed(let kind, let message):
            var text = ""
            for scalar in message.unicodeScalars {
                if text.utf8.count + String(scalar).utf8.count > 256 { break }
                text.unicodeScalars.append(scalar)
            }
            bounded = .failed(kind: kind, message: text)
        }
        record.phase = .terminal
        record.outcome = bounded
        try journal.save(record)
        try await inbox.report(id: record.task.id, outcome: bounded)
    }
}
