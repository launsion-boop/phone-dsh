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

/// The durable terminal result of one device task. It is delivered after the
/// journal write succeeds, independently of whether the device report succeeds.
public struct DeviceTaskSettlement: Sendable, Equatable {
    public let deviceID: String
    public let taskID: String
    public let idempotencyKey: String
    public let goal: String
    public let outcome: DeviceTaskOutcome

    public init(deviceID: String, taskID: String, idempotencyKey: String,
                goal: String, outcome: DeviceTaskOutcome) {
        self.deviceID = deviceID
        self.taskID = taskID
        self.idempotencyKey = idempotencyKey
        self.goal = goal
        self.outcome = outcome
    }
}

/// Serializes every operation for a device and persists intent before effects.
public actor DeviceTaskExecutor {
    private let journal: DeviceTaskJournal
    private let runner: any DeviceTaskRunner
    private let clock: @Sendable () -> Date
    private let onSettled: (@Sendable (DeviceTaskSettlement) -> Void)?
    private var activeDevices = Set<String>()

    public init(directory: URL, runner: any DeviceTaskRunner,
                clock: @escaping @Sendable () -> Date = { Date() },
                onSettled: (@Sendable (DeviceTaskSettlement) -> Void)? = nil) throws {
        self.journal = try DeviceTaskJournal(directory: directory)
        self.runner = runner
        self.clock = clock
        self.onSettled = onSettled
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
        // The settlement is observable only after the terminal journal record
        // is durable and before the device report. A failed report must not
        // hide the result from the Bot, and this branch is the only place a
        // new terminal record is announced. Retried terminal deliveries take
        // the report-only path in `process`.
        onSettled?(DeviceTaskSettlement(deviceID: record.deviceID,
                                        taskID: record.task.id,
                                        idempotencyKey: record.task.idempotencyKey,
                                        goal: record.task.body.text,
                                        outcome: bounded))
        try Task.checkCancellation()
        try await report(record: record, outcome: bounded, inbox: inbox)
    }

    /// Parent tasks already journaled for `deviceID` (secure-session §8.2
    /// local conflict check and the "accepted offer without parent" rule).
    public func tasks(deviceID: String) throws -> [DeviceTask] {
        try journal.records().filter { $0.deviceID == deviceID }.map(\.task)
    }

    private func accept(record: DeviceTaskRecord, inbox: any DeviceTaskInbox) async throws {
        if let secure = inbox as? any BLESecureTaskInbox {
            try await secureOperation(record: record, action: .accept, inbox: secure)
            return
        }
        guard let link = inbox as? any BLETaskLinkInbox else { try await inbox.accept(id: record.task.id); return }
        try await linkOperation(record: record, action: .accept,
                                arguments: .object(["id": .string(record.task.id)]), link: link)
    }

    private func report(record: DeviceTaskRecord, outcome: DeviceTaskOutcome, inbox: any DeviceTaskInbox) async throws {
        if let secure = inbox as? any BLESecureTaskInbox {
            let action: BLESecureTaskIntent.Action
            switch outcome { case .completed: action = .complete; case .failed: action = .fail }
            try await secureOperation(record: record, action: action, inbox: secure)
            return
        }
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

    /// secure-session-v2 §9.2: the arguments are reconstructed solely from the
    /// persisted parent, and the intent is durable before the binding may send.
    private func secureOperation(record: DeviceTaskRecord, action: BLESecureTaskIntent.Action,
                                 inbox: any BLESecureTaskInbox) async throws {
        let arguments = try BLESecureTransitionArguments.reconstruct(record: record, action: action)
        let (intent, fresh) = try journal.prepareBLESecureTransition(record: record, phoneID: inbox.phoneID, arguments: arguments)
        try Task.checkCancellation()
        try await inbox.transition(arguments, intent: intent, fresh: fresh)
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
