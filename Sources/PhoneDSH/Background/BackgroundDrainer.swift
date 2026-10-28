// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — PhoneDSH: background drainer.
//
// PLAN W6-BACKGROUND and budgets.md §2/§3:
//
//   scenePhase background
//     -> begin the OS execution window (iOS 26 BGContinuedProcessingTask, else
//        UIApplication.beginBackgroundTask)
//     -> controller `scenePhase(.background)`: Running -> Draining with the
//        20 s deadline (the state machine owns that timer)
//     -> wait for the controller to leave Draining. Leaving Draining closes
//        the WAL epoch in the D18 order (the controller calls the epoch
//        closer), so the OS window is only ended after the durable flush.
//     -> on the OS expiration or the drainer deadline, force the documented
//        controller signal (`.backgroundTaskExpired` / `.drainDeadlineElapsed`)
//        and wait a short grace period.
//     -> end the window.
//
// The drainer does no tool work and never opens admission. The App calls
// `observe(_:)` once and retains the returned task; the facade may instead
// call `drainForBackground()` directly.

import Foundation
import PhoneDSHController

/// The controller operations the drainer needs.
///
/// ``HostStateMachine`` conforms below; tests can use a deterministic double
/// that never leaves `Draining` to exercise the deadline path.
public protocol BackgroundDrainControlling: Sendable {
    /// The controller state right now.
    func currentHostState() async -> HostState
    /// Applies one D14 signal (the drainer uses `.scenePhase(.background)`,
    /// `.drainDeadlineElapsed` and `.backgroundTaskExpired`).
    func handleBackgroundSignal(_ signal: HostSignal) async throws -> HostState
    /// Accepted transitions; the last one is replayed to a late subscriber.
    func hostTransitionStream() -> AsyncStream<HostTransitionRecord>
}

extension HostStateMachine: BackgroundDrainControlling {
    public func currentHostState() async -> HostState {
        currentState()
    }

    public func handleBackgroundSignal(_ signal: HostSignal) async throws -> HostState {
        try await handle(signal)
    }

    public nonisolated func hostTransitionStream() -> AsyncStream<HostTransitionRecord> {
        transitions()
    }
}

/// Result of one background drain window.
public struct BackgroundDrainReport: Equatable, Sendable {
    public enum Outcome: String, CaseIterable, Codable, Sendable {
        /// The controller left `Draining` before the deadline.
        case completed
        /// The 20 s deadline elapsed first; the deadline signal was delivered.
        case deadlineExceeded
        /// The OS background window expired first; the expiration signal was
        /// delivered (budgets.md §3).
        case backgroundTaskExpired
        /// The controller was already parked; no drain was needed.
        case alreadyParked
        /// The controller was not running and had nothing to drain.
        case notRunning
        /// The controller ended in `Failed` (fail loud).
        case failed
    }

    public var outcome: Outcome
    public var taskKind: BackgroundTaskKind
    public var startedAt: Date
    public var finishedAt: Date
    public var elapsedSeconds: TimeInterval
    public var deadlineSeconds: TimeInterval
    /// Controller state after the window closed.
    public var finalState: HostState?
    public var errorDescription: String?

    public init(outcome: Outcome, taskKind: BackgroundTaskKind,
                startedAt: Date, finishedAt: Date,
                elapsedSeconds: TimeInterval, deadlineSeconds: TimeInterval,
                finalState: HostState?, errorDescription: String? = nil) {
        self.outcome = outcome
        self.taskKind = taskKind
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.elapsedSeconds = elapsedSeconds
        self.deadlineSeconds = deadlineSeconds
        self.finalState = finalState
        self.errorDescription = errorDescription
    }
}

/// Waits for the OS background-window expiration callback.
private final class BackgroundExpirationLatch: @unchecked Sendable {
    private let lock = NSLock()
    private var expired = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func expire() {
        let waiters: [CheckedContinuation<Void, Never>] = lock.withLock {
            guard !expired else { return [] }
            expired = true
            let waiters = self.waiters
            self.waiters.removeAll()
            return waiters
        }
        for waiter in waiters { waiter.resume() }
    }

    func wait() async {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let alreadyExpired = lock.withLock { () -> Bool in
                    if expired { return true }
                    waiters.append(continuation)
                    return false
                }
                if alreadyExpired {
                    continuation.resume()
                }
            }
        } onCancel: { [weak self] in
            self?.expire()
        }
    }
}

/// Runs the 20 s background drain window.
public actor BackgroundDrainer {
    /// Drain-window configuration.
    public struct Configuration: Equatable, Sendable {
        /// The drain deadline. The controller has its own timer with the same
        /// budget (`HostStateMachine.drainDeadlineSeconds` = 20 s).
        public var deadline: TimeInterval
        /// Grace waited for the controller to finish after a forced deadline
        /// or OS expiration. A policy constant, not a measurement.
        public var grace: TimeInterval
        /// Name passed to the OS background task.
        public var taskName: String

        public init(deadline: TimeInterval = HostStateMachine.drainDeadlineSeconds,
                    grace: TimeInterval = 2,
                    taskName: String = "phone-dsh-drain") {
            self.deadline = max(0, deadline)
            self.grace = max(0, grace)
            self.taskName = taskName
        }
    }

    private let controller: any BackgroundDrainControlling
    private let scheduler: any BackgroundTaskScheduling
    private let clock: any HostClock
    public let configuration: Configuration
    private var inFlight: Task<BackgroundDrainReport, Never>?

    /// Creates the drainer.
    ///
    /// - Parameters:
    ///   - controller: The host state machine (or a test double).
    ///   - scheduler: OS window factory. iOS uses
    ///     ``PlatformBackgroundTaskScheduler``; tests inject a recording
    ///     scheduler.
    ///   - clock: Injected clock; tests advance a manual clock and never sleep
    ///     for 20 real seconds.
    ///   - configuration: Deadline, grace and task name.
    public init(controller: any BackgroundDrainControlling,
                scheduler: any BackgroundTaskScheduling = PlatformBackgroundTaskScheduler(),
                clock: any HostClock = SystemHostClock(),
                configuration: Configuration = Configuration()) {
        self.controller = controller
        self.scheduler = scheduler
        self.clock = clock
        self.configuration = configuration
    }

    /// `true` while a drain window is open.
    public var isDraining: Bool { inFlight != nil }

    /// Runs one full drain window. Concurrent calls join the in-flight drain
    /// instead of opening a second OS task.
    @discardableResult
    public func drainForBackground() async -> BackgroundDrainReport {
        if let inFlight {
            return await inFlight.value
        }
        let task = Task { await self.performDrain() }
        inFlight = task
        let report = await task.value
        inFlight = nil
        return report
    }

    /// Alias for ``drainForBackground()``.
    @discardableResult
    public func drain() async -> BackgroundDrainReport {
        await drainForBackground()
    }

    /// Drain only when the phase is `background`; the App feeds every phase to
    /// this method.
    public func handle(scenePhase: ScenePhase) async -> BackgroundDrainReport? {
        guard scenePhase == .background else { return nil }
        return await drainForBackground()
    }

    /// Observes the scene-phase stream and drains on every `background` value.
    /// Retain the returned task; cancel it when the App tears the host down.
    public nonisolated func observe(_ signals: any HostSignals)
        -> Task<Void, Never> {
        Task { [weak self] in
            guard let self else { return }
            for await phase in signals.scenePhase {
                guard phase == .background else { continue }
                _ = await self.drainForBackground()
            }
        }
    }

    // MARK: - Window

    private func performDrain() async -> BackgroundDrainReport {
        let startedAt = clock.now
        let latch = BackgroundExpirationLatch()
        let token = await scheduler.beginBackgroundTask(
            name: configuration.taskName,
            expiration: { latch.expire() })
        if let token {
            await scheduler.reportProgress(0.05, for: token)
        }
        // Report the window that actually opened; `.none` when the
        // platform offered no window at all.
        let taskKind = token?.kind ?? BackgroundTaskKind.none

        var errorDescription: String?
        do {
            _ = try await controller.handleBackgroundSignal(.scenePhase(.background))
        } catch {
            errorDescription = String(describing: error)
            let state = await controller.currentHostState()
            if state != .draining {
                let outcome: BackgroundDrainReport.Outcome =
                    state == .parked ? .alreadyParked
                        : (state == .failed ? .failed : .notRunning)
                return await finish(outcome: outcome, startedAt: startedAt,
                                    token: token, taskKind: taskKind,
                                    finalState: state,
                                    errorDescription: errorDescription)
            }
        }
        let stateAfterEnter = await controller.currentHostState()
        if stateAfterEnter != .draining {
            // The controller refused the background signal (already parked,
            // backoff, remote, failed) or completed the drain synchronously.
            let outcome: BackgroundDrainReport.Outcome =
                stateAfterEnter == .parked ? .alreadyParked
                    : (stateAfterEnter == .failed ? .failed : .notRunning)
            return await finish(outcome: outcome, startedAt: startedAt,
                                token: token, taskKind: taskKind,
                                finalState: stateAfterEnter,
                                errorDescription: errorDescription)
        }
        if let token {
            await scheduler.reportProgress(0.2, for: token)
        }

        let deadline = configuration.deadline
        // Measure the remaining deadline from the window start: the controller
        // may have taken time to enter Draining, and a test/manual clock may
        // already be past the deadline when the wait starts.
        let remaining = max(0, deadline - clock.now.timeIntervalSince(startedAt))
        var outcome: BackgroundDrainReport.Outcome
        let first = await waitForExit(latch: latch,
                                      remaining: remaining,
                                      watchExpiration: true)
        switch first {
        case .drained:
            // The controller's own 20 s timer may have completed the drain at
            // the same instant this window woke: report the deadline then.
            let elapsed = clock.now.timeIntervalSince(startedAt)
            outcome = elapsed >= deadline ? .deadlineExceeded : .completed
        case .deadline:
            outcome = .deadlineExceeded
            await forceSignal(.drainDeadlineElapsed)
            _ = await waitForExit(latch: latch,
                                  remaining: configuration.grace,
                                  watchExpiration: false)
        case .expired:
            outcome = .backgroundTaskExpired
            await forceSignal(.backgroundTaskExpired)
            _ = await waitForExit(latch: latch,
                                  remaining: configuration.grace,
                                  watchExpiration: false)
        }

        if let token {
            await scheduler.reportProgress(1, for: token)
        }
        let finalState = await controller.currentHostState()
        if finalState == .failed {
            outcome = .failed
        }
        return await finish(outcome: outcome, startedAt: startedAt,
                            token: token, taskKind: taskKind,
                            finalState: finalState,
                            errorDescription: errorDescription)
    }

    private enum ExitWait: Sendable {
        case drained
        case deadline
        case expired
    }

    /// Waits until the controller leaves `Draining`, the remaining deadline
    /// elapses, or the OS window expires.
    private func waitForExit(latch: BackgroundExpirationLatch,
                             remaining: TimeInterval,
                             watchExpiration: Bool) async -> ExitWait {
        if remaining <= 0 { return .deadline }
        let controller = self.controller
        let clock = self.clock
        return await withTaskGroup(of: ExitWait.self) { group in
            group.addTask {
                for await record in controller.hostTransitionStream() {
                    if record.to != .draining { return .drained }
                }
                return .drained
            }
            group.addTask {
                await clock.sleep(for: remaining)
                return .deadline
            }
            if watchExpiration {
                group.addTask {
                    await latch.wait()
                    return .expired
                }
            }
            let first = await group.next() ?? .drained
            group.cancelAll()
            return first
        }
    }

    private func forceSignal(_ signal: HostSignal) async {
        // An illegal-transition error only means the controller left Draining
        // concurrently (or a second timer already fired); the state is read
        // again by the caller. Any other failure surfaces as `.failed` through
        // `finalState`.
        _ = try? await controller.handleBackgroundSignal(signal)
    }

    private func finish(outcome: BackgroundDrainReport.Outcome,
                        startedAt: Date,
                        token: BackgroundTaskToken?,
                        taskKind: BackgroundTaskKind,
                        finalState: HostState?,
                        errorDescription: String?) async -> BackgroundDrainReport {
        if let token {
            await scheduler.endBackgroundTask(token)
        }
        let finishedAt = clock.now
        return BackgroundDrainReport(
            outcome: outcome,
            taskKind: taskKind,
            startedAt: startedAt,
            finishedAt: finishedAt,
            elapsedSeconds: max(0, finishedAt.timeIntervalSince(startedAt)),
            deadlineSeconds: configuration.deadline,
            finalState: finalState,
            errorDescription: errorDescription)
    }
}
