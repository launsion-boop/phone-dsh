// SPDX-License-Identifier: MIT
import Foundation
import PhoneDSHAgentCore

/// The binding sends only confirmed acceptance and terminal reports.
public protocol DeviceTaskInbox: Sendable {
    func accept(id: String) async throws
    func report(id: String, outcome: DeviceTaskOutcome) async throws
}

/// A negotiated Link binding receives the durable request identity and must
/// query rather than upload whenever `fresh` is false.
public protocol BLETaskLinkInbox: DeviceTaskInbox {
    func invokeOrQuery(requestID: UUID, name: String, arguments: JSONValue,
                       idempotencyKey: String, fresh: Bool) async throws -> JSONValue
}

public extension BLETaskLinkInbox {
    func accept(id: String) async throws { throw DeviceTaskError.unauthorized }
    func report(id: String, outcome: DeviceTaskOutcome) async throws { throw DeviceTaskError.unauthorized }
}

/// A runner must verify its isolated no-tools DSH scope before accepting work.
public protocol DeviceTaskRunner: Sendable {
    func session(for deviceID: String, existingSession: String?) async throws -> String
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
        try Task.checkCancellation()
        guard activeDevices.insert(deviceID).inserted else { throw DeviceTaskError.deviceBusy }
        defer { activeDevices.remove(deviceID) }
        var record: DeviceTaskRecord
        if let existing = try journal.find(deviceID: deviceID, key: task.idempotencyKey) {
            guard existing.task == task else { throw DeviceTaskError.idempotencyConflict }
            record = existing
            if record.phase == .terminal {
                guard let outcome = record.outcome else { throw DeviceTaskError.corruptJournal }
                try Task.checkCancellation()
                try await report(record: record, outcome: outcome, inbox: inbox)
                return
            }
            if record.phase == .accepted || record.phase == .running {
                try await finish(&record, outcome: .failed(kind: .unknownOutcome,
                    message: "Previous execution was interrupted; its outcome is unknown."), inbox: inbox)
                return
            }
        } else {
            let prior = try journal.records().filter { $0.deviceID == deviceID }.max { $0.seq < $1.seq }?.sessionID
            let session = try await runner.session(for: deviceID, existingSession: prior)
            record = try journal.create(deviceID: deviceID, task: task, sessionID: session, now: clock())
        }

        // Revalidate on every delivery, including a crash before acceptance;
        // an old received record does not prove isolation is still installed.
        guard try await runner.session(for: deviceID, existingSession: record.sessionID) == record.sessionID else {
            throw DeviceTaskError.unauthorized
        }
        try Task.checkCancellation()
        // A lost accept response is safe to retry: no task has been dispatched.
        try await accept(record: record, inbox: inbox)
        let acceptedAt = clock()
        let deadline = min(task.deadlineDate ?? acceptedAt.addingTimeInterval(300), acceptedAt.addingTimeInterval(300))
        record.deadlineMS = Int64(deadline.timeIntervalSince1970 * 1000)
        record.phase = .accepted
        try journal.save(record)
        try Task.checkCancellation()
        if Int64(clock().timeIntervalSince1970 * 1000) >= record.deadlineMS {
            try await finish(&record, outcome: .failed(kind: .expired, message: "Task expired before submission."), inbox: inbox)
            return
        }
        record.phase = .running
        try journal.save(record)
        try Task.checkCancellation()
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
            let safeMessage = message.unicodeScalars.contains(where: { $0.value == 0 }) ? "Invalid failure message." : message
            for scalar in safeMessage.unicodeScalars {
                if text.utf8.count + String(scalar).utf8.count > 256 { break }
                text.unicodeScalars.append(scalar)
            }
            bounded = .failed(kind: kind, message: text)
        }
        record.phase = .terminal
        record.outcome = bounded
        try journal.save(record)
        try Task.checkCancellation()
        try await report(record: record, outcome: bounded, inbox: inbox)
    }

    private func accept(record: DeviceTaskRecord, inbox: any DeviceTaskInbox) async throws {
        guard let link = inbox as? any BLETaskLinkInbox else { try await inbox.accept(id: record.task.id); return }
        try await linkOperation(record: record, action: .accept,
                                arguments: .object(["id": .string(record.task.id)]), link: link)
    }

    private func report(record: DeviceTaskRecord, outcome: DeviceTaskOutcome, inbox: any DeviceTaskInbox) async throws {
        guard let link = inbox as? any BLETaskLinkInbox else { try await inbox.report(id: record.task.id, outcome: outcome); return }
        let action: BLETaskIntent.Action
        let args: JSONValue
        switch outcome {
        case .completed(let output, let truncated):
            action = .complete
            args = .object(["id": .string(record.task.id), "output": .string(output), "truncated": .bool(truncated)])
        case .failed(let kind, let message):
            action = .fail
            args = .object(["id": .string(record.task.id), "failure": .object(["kind": .string(kind.rawValue), "message": .string(message)])])
        }
        try await linkOperation(record: record, action: action, arguments: args, link: link)
    }

    private func linkOperation(record: DeviceTaskRecord, action: BLETaskIntent.Action,
                               arguments: JSONValue, link: any BLETaskLinkInbox) async throws {
        let (intent, fresh) = try journal.prepareBLETransition(record: record, action: action, arguments: arguments)
        guard let requestID = UUID(uuidString: intent.requestID) else { throw DeviceTaskError.corruptJournal }
        let result = try await link.invokeOrQuery(requestID: requestID, name: "pdsh.task." + action.rawValue,
                                                  arguments: arguments, idempotencyKey: intent.idemKey, fresh: fresh)
        guard result["request_id"]?.stringValue == intent.requestID,
              result["status"]?.stringValue == "completed" else { throw DeviceTaskError.unauthorized }
    }
}
