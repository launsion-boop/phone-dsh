// SPDX-License-Identifier: MIT
// Shared fixtures for PhoneDSHControllerTests. All paths are created
// at run time under the system temporary directory; no repository path is
// stored.

import Foundation
import XCTest
@testable import PhoneDSHController
import PhoneDSHWire

/// Manual, injected clock. Tests advance virtual time; no test sleeps for a
/// real 20 s drain deadline.
final class ManualHostClock: HostClock, @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date
    private var waiters: [(deadline: Date, continuation: CheckedContinuation<Void, Never>)] = []
    private var finished = false

    init(now: Date = Date(timeIntervalSince1970: 1_700_000_000)) {
        self.current = now
    }

    var now: Date {
        lock.withLock { current }
    }

    func sleep(for duration: TimeInterval) async {
        guard duration > 0 else { return }
        let deadline = lock.withLock { current.addingTimeInterval(duration) }
        let skip = lock.withLock { deadline <= current || finished }
        guard !skip else { return }
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let ready = lock.withLock { () -> Bool in
                    if finished || deadline <= current { return true }
                    waiters.append((deadline, continuation))
                    return false
                }
                if ready { continuation.resume() }
            }
        } onCancel: { [weak self] in
            self?.wakeAll()
        }
    }

    func advance(by seconds: TimeInterval) {
        let due: [(deadline: Date, continuation: CheckedContinuation<Void, Never>)] =
            lock.withLock {
                current = current.addingTimeInterval(seconds)
                let due = waiters.filter { $0.deadline <= current }
                waiters.removeAll { $0.deadline <= current }
                return due
            }
        for waiter in due { waiter.continuation.resume() }
    }

    /// Resumes every sleeper so a test teardown never leaks a suspended task.
    func finish() {
        let all: [(deadline: Date, continuation: CheckedContinuation<Void, Never>)] =
            lock.withLock {
                finished = true
                let all = waiters
                waiters.removeAll()
                return all
            }
        for waiter in all { waiter.continuation.resume() }
    }

    private func wakeAll() {
        let all: [(deadline: Date, continuation: CheckedContinuation<Void, Never>)] =
            lock.withLock {
                let all = waiters
                waiters.removeAll()
                return all
            }
        for waiter in all { waiter.continuation.resume() }
    }
}

/// Epoch-close double for the state machine.
final class RecordingEpochCloser: HostEpochClosing, @unchecked Sendable {
    private let lock = NSLock()
    private var storedCount = 0
    private var storedError: (any Error & Sendable)?

    var count: Int {
        lock.withLock { storedCount }
    }

    func fail(with error: any Error & Sendable) {
        lock.withLock { storedError = error }
    }

    func closeHostEpoch() async throws {
        let error = lock.withLock { () -> (any Error & Sendable)? in
            storedCount += 1
            return storedError
        }
        if let error { throw error }
    }
}

/// Restart target double for the engine protocol.
final class RecordingRestartRequester: RestartRequesting, @unchecked Sendable {
    private let lock = NSLock()
    private var storedReasons: [RestartReason] = []
    private var storedError: (any Error & Sendable)?

    var reasons: [RestartReason] {
        lock.withLock { storedReasons }
    }

    func fail(with error: any Error & Sendable) {
        lock.withLock { storedError = error }
    }

    func requestWebContentRestart(reason: RestartReason) async throws {
        let error = lock.withLock { () -> (any Error & Sendable)? in
            let error = storedError
            if error == nil { storedReasons.append(reason) }
            return error
        }
        if let error { throw error }
    }
}

/// Records the forced-restart path in order: drain first, then the engine
/// restart. Conforms to both ports so one double cannot hide a missing drain.
final class RecordingRestartPath: RestartRequesting, RestartDraining, @unchecked Sendable {
    enum Event: Equatable, Sendable {
        case drained(RestartReason)
        case restarted(RestartReason)
    }

    private let lock = NSLock()
    private var storedEvents: [Event] = []
    private var storedRestartError: (any Error & Sendable)?
    private var storedDrainError: (any Error & Sendable)?

    var events: [Event] {
        lock.withLock { storedEvents }
    }

    var reasons: [RestartReason] {
        events.compactMap { event in
            guard case .restarted(let reason) = event else { return nil }
            return reason
        }
    }

    var drainReasons: [RestartReason] {
        events.compactMap { event in
            guard case .drained(let reason) = event else { return nil }
            return reason
        }
    }

    func failRestart(with error: any Error & Sendable) {
        lock.withLock { storedRestartError = error }
    }

    func failDrain(with error: any Error & Sendable) {
        lock.withLock { storedDrainError = error }
    }

    func drainForForcedRestart(reason: RestartReason) async throws {
        let error = lock.withLock { () -> (any Error & Sendable)? in
            let error = storedDrainError
            if error == nil { storedEvents.append(.drained(reason)) }
            return error
        }
        if let error { throw error }
    }

    func requestWebContentRestart(reason: RestartReason) async throws {
        let error = lock.withLock { () -> (any Error & Sendable)? in
            let error = storedRestartError
            if error == nil { storedEvents.append(.restarted(reason)) }
            return error
        }
        if let error { throw error }
    }
}

/// Boundary double for the restart scheduler.
final class StubBoundary: ToolCallBoundaryProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var storedIdle: Bool
    private var storedChecks = 0

    init(idle: Bool) {
        self.storedIdle = idle
    }

    var idle: Bool {
        get {
            lock.withLock { storedIdle }
        }
        set {
            lock.withLock { storedIdle = newValue }
        }
    }

    var checks: Int {
        lock.withLock { storedChecks }
    }

    func atToolCallBoundary() async -> Bool {
        lock.withLock {
            storedChecks += 1
            return storedIdle
        }
    }
}

enum ControllerTestSupport {
    static func root(for test: XCTestCase, name: String = "workspace") -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdsh-phone-controller-\(UUID().uuidString)",
                                    isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        test.addTeardownBlock {
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        }
        return url
    }

    static func makeHost(for test: XCTestCase, root: URL? = nil,
                         clock: ManualHostClock,
                         closer: RecordingEpochCloser? = nil,
                         leaseVerifier: (@Sendable () async throws -> Bool)? = nil,
                         workspaceHasState: Bool = false,
                         userReset: Bool = false) throws -> HostStateMachine {
        let machine = try HostStateMachine(root: root ?? self.root(for: test),
                                           clock: clock,
                                           epochCloser: closer,
                                           leaseVerifier: leaseVerifier,
                                           workspaceHasState: workspaceHasState,
                                           userReset: userReset)
        test.addTeardownBlock { clock.finish() }
        test.addTeardownBlock { await machine.shutdown() }
        return machine
    }

    /// Polls the state machine until it reaches `expected` or the real timeout
    /// expires. Used only where the drain timer races an explicit signal.
    static func waitForState(_ machine: HostStateMachine,
                             _ expected: HostState,
                             timeout: TimeInterval = 2) async -> HostState {
        let deadline = Date().addingTimeInterval(timeout)
        var current = await machine.state
        while current != expected, Date() < deadline {
            try? await Task.sleep(nanoseconds: 2_000_000)
            current = await machine.state
        }
        return current
    }

    /// 64 lowercase hex characters for `idem_key` / `Idempotency-Key`.
    static func idemKey(_ seed: Int) -> String {
        let suffix = String(format: "%04x", seed % 0x10000)
        return String(repeating: "a", count: 60) + suffix
    }

    static func canonicalJSON(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    static func journalRecord(type: String, stepID: String, turnID: String,
                              key: String? = nil, execID: String? = nil) throws -> Data {
        var object: [String: Any] = [
            "v": 1,
            "type": type,
            "step_id": stepID,
            "turn_id": turnID,
            "call_id": "call-\(stepID)",
            "at": 1_700_000_000_000,
        ]
        if type == "completed" || type == "executed" {
            object["t"] = type == "completed" ? "done" : "executed"
            object["result"] = [
                "content": [["type": "text", "text": "ok"]],
                "isError": false,
            ]
        }
        if let key { object["key"] = key }
        if let execID { object["exec_id"] = execID }
        return try canonicalJSON(object)
    }

    static func execEvent(type: String, execID: String = "exec-1",
                          extra: [String: Any] = [:]) throws -> Data {
        var object: [String: Any] = ["type": type, "exec_id": execID]
        object.merge(extra) { _, new in new }
        return try canonicalJSON(object)
    }

    static func readJSON(_ url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(domain: "ControllerTestSupport", code: 1)
        }
        return object
    }
}

/// Collects the first `count` elements of a stream, failing after a short real
/// timeout so a missing signal is a test failure instead of a hang.
func collect<T: Sendable>(_ count: Int, from stream: AsyncStream<T>,
                          timeout: TimeInterval = 2) async -> [T]? {
    let box = CollectorBox<T>()
    let task = Task {
        var iterator = stream.makeAsyncIterator()
        var values: [T] = []
        while values.count < count, let value = await iterator.next() {
            values.append(value)
        }
        box.set(values)
        box.signal()
    }
    let deadline = Date().addingTimeInterval(timeout)
    while !box.isSignalled, Date() < deadline {
        try? await Task.sleep(nanoseconds: 2_000_000)
    }
    task.cancel()
    return box.isSignalled ? box.values : nil
}

final class CollectorBox<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [T] = []
    private var signalled = false

    var values: [T] {
        lock.withLock { stored }
    }

    var isSignalled: Bool {
        lock.withLock { signalled }
    }

    func set(_ values: [T]) {
        lock.withLock { stored = values }
    }

    func signal() {
        lock.withLock { signalled = true }
    }
}
