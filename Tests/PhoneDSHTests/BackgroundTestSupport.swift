// SPDX-License-Identifier: MIT
// Shared fixtures for the W6-BACKGROUND tests. Manual clock, recording OS
// scheduler, recording epoch closer and a controller double that can be stuck
// in Draining to exercise the deadline paths.

import Foundation
import XCTest
import PhoneDSHController
@testable import PhoneDSH

/// Manual clock: tests advance virtual time; no test sleeps for a real
/// 20 s drain deadline.
final class ManualDrainClock: HostClock, @unchecked Sendable {
    private struct Waiter {
        let id: UUID
        let deadline: Date
        let continuation: CheckedContinuation<Void, Never>
    }

    private let lock = NSLock()
    private var current: Date
    private var waiters: [Waiter] = []
    private var finished = false

    init(now: Date = Date(timeIntervalSince1970: 1_700_000_000)) {
        self.current = now
    }

    var now: Date { lock.withLock { current } }

    /// Number of registered sleepers (test synchronization hook).
    var waiterCount: Int { lock.withLock { waiters.count } }

    func sleep(for duration: TimeInterval) async {
        guard duration > 0 else { return }
        let deadline = lock.withLock { current.addingTimeInterval(duration) }
        let skip = lock.withLock { deadline <= current || finished }
        guard !skip else { return }
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let ready = lock.withLock { () -> Bool in
                    if finished || deadline <= current { return true }
                    waiters.append(Waiter(id: id, deadline: deadline,
                                          continuation: continuation))
                    return false
                }
                if ready { continuation.resume() }
            }
        } onCancel: { [weak self] in
            self?.cancel(id)
        }
    }

    func advance(by seconds: TimeInterval) {
        let due: [Waiter] = lock.withLock {
            current = current.addingTimeInterval(seconds)
            let due = waiters.filter { $0.deadline <= current }
            waiters.removeAll { $0.deadline <= current }
            return due
        }
        for waiter in due { waiter.continuation.resume() }
    }

    func finish() {
        let all: [Waiter] = lock.withLock {
            finished = true
            let all = waiters
            waiters.removeAll()
            return all
        }
        for waiter in all { waiter.continuation.resume() }
    }

    private func cancel(_ id: UUID) {
        let cancelled: [Waiter] = lock.withLock {
            let cancelled = waiters.filter { $0.id == id }
            waiters.removeAll { $0.id == id }
            return cancelled
        }
        for waiter in cancelled { waiter.continuation.resume() }
    }
}

/// Records the OS window lifecycle for the drainer tests.
final class RecordingBackgroundScheduler: BackgroundTaskScheduling,
    @unchecked Sendable {
    private struct Begin {
        let name: String
        let expiration: @Sendable () -> Void
    }

    private let lock = NSLock()
    private let schedulerKind: BackgroundTaskKind
    private var nextID: UInt64 = 0
    private var begins: [Begin] = []
    private var endedTokens: [BackgroundTaskToken] = []
    private var progressValues: [Double] = []

    init(kind: BackgroundTaskKind = .backgroundTask) {
        self.schedulerKind = kind
    }

    var kind: BackgroundTaskKind { schedulerKind }
    var beginCount: Int { lock.withLock { begins.count } }
    var endCount: Int { lock.withLock { endedTokens.count } }
    var ended: [BackgroundTaskToken] { lock.withLock { endedTokens } }
    var progress: [Double] { lock.withLock { progressValues } }
    var beginNames: [String] { lock.withLock { begins.map(\.name) } }

    func beginBackgroundTask(
        name: String,
        expiration: @escaping @Sendable () -> Void) async -> BackgroundTaskToken? {
        let token: BackgroundTaskToken = lock.withLock {
            nextID += 1
            begins.append(Begin(name: name, expiration: expiration))
            return BackgroundTaskToken(id: nextID, kind: schedulerKind)
        }
        return token
    }

    func reportProgress(_ fraction: Double,
                        for token: BackgroundTaskToken) async {
        lock.withLock { progressValues.append(fraction) }
    }

    func endBackgroundTask(_ token: BackgroundTaskToken) async {
        lock.withLock { endedTokens.append(token) }
    }

    /// Simulates the OS expiration handler of every open window.
    func expireAll() {
        let expirations: [@Sendable () -> Void] = lock.withLock {
            begins.map(\.expiration)
        }
        for expiration in expirations { expiration() }
    }
}

/// Epoch-close double.
final class BackgroundEpochCloser: HostEpochClosing, @unchecked Sendable {
    private let lock = NSLock()
    private var storedCount = 0

    var count: Int { lock.withLock { storedCount } }

    func closeHostEpoch() async throws {
        lock.withLock { storedCount += 1 }
    }
}

/// Controller double whose drain can stay stuck in `Draining`.
final class StubDrainController: BackgroundDrainControlling, @unchecked Sendable {
    private let lock = NSLock()
    private var state: HostState
    private var signals: [HostSignal] = []

    init(initialState: HostState = .running) {
        self.state = initialState
    }

    var currentState: HostState { lock.withLock { state } }
    var receivedSignals: [HostSignal] { lock.withLock { signals } }

    func currentHostState() async -> HostState {
        lock.withLock { state }
    }

    func handleBackgroundSignal(_ signal: HostSignal) async throws -> HostState {
        lock.withLock {
            signals.append(signal)
            if case .scenePhase(.background) = signal, state == .running {
                state = .draining
            }
            return state
        }
    }

    func hostTransitionStream() -> AsyncStream<HostTransitionRecord> {
        // Never leaves Draining: the drainer must reach its own deadline or
        // the OS expiration path.
        AsyncStream { _ in }
    }
}

enum BackgroundTestSupport {
    static func root(for test: XCTestCase) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdsh-phone-background-\(UUID().uuidString)",
                                    isDirectory: true)
        try? FileManager.default.createDirectory(at: url,
                                                 withIntermediateDirectories: true)
        test.addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
        }
        return url
    }

    /// Waits for an async condition using real wall time (only the test's own
    /// polling is real; the drain deadline itself is on the manual clock).
    static func waitFor(_ description: String,
                        timeout: TimeInterval = 2,
                        _ condition: @Sendable () async -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return }
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTFail("timed out waiting for \(description)")
    }

    /// Waits until the manual clock has at least `count` registered sleepers so
    /// an `advance` cannot race the registration of a drain timer.
    static func waitForSleepers(_ clock: ManualDrainClock, count: Int,
                                timeout: TimeInterval = 2) async {
        await waitFor("\(count) clock sleeper(s)", timeout: timeout) {
            clock.waiterCount >= count
        }
    }

    static func makeMachine(for test: XCTestCase,
                            clock: ManualDrainClock,
                            closer: BackgroundEpochCloser) throws -> HostStateMachine {
        let machine = try HostStateMachine(root: root(for: test),
                                           clock: clock,
                                           epochCloser: closer)
        test.addTeardownBlock { clock.finish() }
        test.addTeardownBlock { await machine.shutdown() }
        return machine
    }
}
