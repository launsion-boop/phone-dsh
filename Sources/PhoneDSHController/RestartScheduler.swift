// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — PhoneDSHController: planned restart scheduler.
//
// PLAN §2.5 (D14) and spec/v1/budgets.md §4. A WebContent restart is
// planned every two hours of foreground work or on a budget action, but it is
// requested only at a tool-call boundary. When the boundary does not arrive
// within 60 s the scheduler invokes the injected drain port and restarts
// anyway (budgets.md §4, last bullet). The facade adapts the merged engine's
// `WebEngineRestartRequesting.restart(reason:)` through
// `WebEngineRestartAdapter`; the step machine reports whether an
// `exec_running` step exists. The scheduler never restarts the engine by
// itself.

import Foundation

/// Why a WebContent restart was planned.
public enum RestartReason: String, Codable, Equatable, Sendable {
    /// The two-hour foreground interval elapsed.
    case plannedInterval = "planned_interval"
    /// A memory budget action selected `plannedRestart`.
    case budget
}

/// Scheduler port implemented by the facade's adapter around the WKWebView
/// engine. The controller calls it only at a tool-call boundary.
public protocol RestartRequesting: Sendable {
    /// Drains and reconstructs the WebContent process.
    func requestWebContentRestart(reason: RestartReason) async throws
}

/// Drain port used when the tool-call boundary of budgets.md §4 does not
/// arrive within 60 s.
///
/// The scheduler's ``RestartRequesting`` port only tears down the engine; the
/// controller-owned part of the drain (close admission, cancel or await
/// in-flight requests, close the WAL epoch) lives in ``HostStateMachine`` and
/// is exposed here. The facade injects ``HostStateMachineRestartDrainer`` so a
/// forced restart still passes through `Draining`/`Recovering` instead of
/// reusing the engine behind an open admission gate. Without a drainer the
/// scheduler still forces the engine restart after 60 s; production wiring
/// must supply the drainer.
public protocol RestartDraining: Sendable {
    /// Drains the host and closes its WAL epoch before the forced restart.
    func drainForForcedRestart(reason: RestartReason) async throws
}

/// Bridges the merged WKWebView engine's restart hook to
/// ``RestartRequesting``.
///
/// The engine exposes the concrete
/// `WebEngineRestartRequesting.restart(reason:) async throws ->
/// WebEngineRestartReport` (PhoneDSHEngine), while PLAN §2.1 keeps the
/// controller's dependency direction to Wire and Log only; the facade has both
/// modules and constructs this adapter, mapping the scheduler's reasons:
///
/// - ``RestartReason/plannedInterval`` → `WebEngineRestartReason.planned`
/// - ``RestartReason/budget`` → `WebEngineRestartReason.memoryPressure`
///
/// The closure discards the returned report (or logs it); a restart that
/// throws keeps the scheduler's pending request for the next poll. This is an
/// adapter type, not a second engine protocol.
public struct WebEngineRestartAdapter: RestartRequesting {
    /// Invokes the engine's `restart(reason:)` after mapping the reason.
    public typealias Handler = @Sendable (RestartReason) async throws -> Void

    private let handler: Handler

    public init(_ handler: @escaping Handler) {
        self.handler = handler
    }

    public func requestWebContentRestart(reason: RestartReason) async throws {
        try await handler(reason)
    }
}

/// Errors of the forced-restart drain.
public enum RestartDrainError: Error, Equatable, Sendable {
    /// The host state has handed authority away or failed loud, so a local
    /// restart must not run. The scheduler keeps its pending request.
    case hostNotRestartable(state: HostState)
}

/// Adapts ``HostStateMachine`` to ``RestartDraining`` for the budgets.md §4
/// 60 s escape.
///
/// In `Running`/`Draining` the drain enters the D14 `plannedRestart` edge,
/// which closes admission, closes the WAL epoch and moves to `Recovering`; the
/// engine restart that follows is the normal planned-restart path. States with
/// admission already closed and no authority in flight keep their state for
/// the engine restart. A host that is handing off, remote, reclaiming or
/// failed rejects the forced restart, so the scheduler retains the pending
/// request instead of restarting under a foreign fence.
public struct HostStateMachineRestartDrainer: RestartDraining {
    private let machine: HostStateMachine

    public init(_ machine: HostStateMachine) {
        self.machine = machine
    }

    public func drainForForcedRestart(reason: RestartReason) async throws {
        let state = await machine.currentState()
        switch state {
        case .running, .draining:
            _ = try await machine.handle(.plannedRestart)
        case .recovering, .parked, .backoff:
            // Admission is closed and no epoch is open for new work; the
            // engine restart can proceed without another transition.
            return
        case .handingOff, .remote, .reclaiming, .failed:
            throw RestartDrainError.hostNotRestartable(state: state)
        }
    }
}

/// Reports whether the host is at a complete D13 tool-call boundary.
///
/// budgets.md §4 defines the boundary as three conditions: no frame in flight,
/// a closed WAL epoch, and no `exec_running` step. ``StepMachine`` implements
/// only the step-level condition; ``ToolCallBoundary`` composes it with the
/// frame and epoch predicates owned by the loopback/facade adapters. The
/// scheduler trusts this result, so production wiring must pass the composed
/// type rather than ``StepMachine`` alone.
public protocol ToolCallBoundaryProviding: Sendable {
    func atToolCallBoundary() async -> Bool
}

/// The complete budgets.md §4 tool-call boundary: no frame in flight, the WAL
/// epoch closed, and no `exec_running` step. This is the code-enforced
/// composition of the three conditions; the facade supplies the frame counter
/// and the ``WorkspaceLog`` epoch predicate as closures.
public struct ToolCallBoundary: ToolCallBoundaryProviding {
    /// One of the three boundary conditions.
    public typealias Condition = @Sendable () async -> Bool

    private let noFrameInFlight: Condition
    private let epochClosed: Condition
    private let steps: any ToolCallBoundaryProviding

    public init(noFrameInFlight: @escaping Condition,
                epochClosed: @escaping Condition,
                steps: any ToolCallBoundaryProviding) {
        self.noFrameInFlight = noFrameInFlight
        self.epochClosed = epochClosed
        self.steps = steps
    }

    public func atToolCallBoundary() async -> Bool {
        guard await noFrameInFlight() else { return false }
        guard await epochClosed() else { return false }
        return await steps.atToolCallBoundary()
    }
}

/// Result of one ``RestartScheduler/poll()``.
public enum RestartPollResult: Equatable, Sendable {
    /// No restart is due.
    case notDue
    /// A restart is due but the host is not at a boundary yet.
    case deferred(reason: RestartReason)
    /// The engine was asked to restart at a boundary.
    case requested(reason: RestartReason)
    /// The 60 s boundary wait expired: the host was drained and the engine was
    /// asked to restart regardless of the boundary (budgets.md §4).
    case forced(reason: RestartReason)
}

/// Errors of ``RestartScheduler``.
public enum RestartSchedulerError: Error, Equatable, Sendable {
    case invalidInterval(TimeInterval)
    case invalidBoundaryTimeout(TimeInterval)
}

/// Two-hour / budget-action restart scheduling, evaluated at tool-call
/// boundaries by the facade or controller loop.
public actor RestartScheduler {
    /// budgets.md §4: a due restart waits at most 60 s for a tool-call
    /// boundary, then the host drains and the restart runs anyway.
    public static let defaultBoundaryTimeoutSeconds: TimeInterval = 60

    public let intervalSeconds: TimeInterval
    /// How long a due restart waits for a tool-call boundary before the forced
    /// drain path runs (60 s by default).
    public let boundaryTimeoutSeconds: TimeInterval
    public private(set) var nextDeadline: Date
    public private(set) var pendingReason: RestartReason?
    /// The instant at which the pending restart stops waiting for a boundary
    /// and becomes a forced restart; `nil` when no restart is pending.
    public private(set) var boundaryDeadline: Date?

    private let clock: any HostClock
    private let requester: any RestartRequesting
    private let boundary: any ToolCallBoundaryProviding
    private let drainer: (any RestartDraining)?

    public init(clock: any HostClock = SystemHostClock(),
                requester: any RestartRequesting,
                boundary: any ToolCallBoundaryProviding,
                intervalSeconds: TimeInterval = 2 * 60 * 60,
                drainer: (any RestartDraining)? = nil,
                boundaryTimeoutSeconds: TimeInterval =
                    RestartScheduler.defaultBoundaryTimeoutSeconds) throws {
        guard intervalSeconds > 0 else {
            throw RestartSchedulerError.invalidInterval(intervalSeconds)
        }
        guard boundaryTimeoutSeconds > 0 else {
            throw RestartSchedulerError.invalidBoundaryTimeout(boundaryTimeoutSeconds)
        }
        self.clock = clock
        self.requester = requester
        self.boundary = boundary
        self.drainer = drainer
        self.intervalSeconds = intervalSeconds
        self.boundaryTimeoutSeconds = boundaryTimeoutSeconds
        self.nextDeadline = clock.now.addingTimeInterval(intervalSeconds)
    }

    /// Records a budget action (`BudgetAction.plannedRestart`) as a forced
    /// restart request. It is still delivered only at a boundary, or after the
    /// 60 s boundary wait.
    public func requestBudgetRestart() {
        if pendingReason == nil {
            boundaryDeadline = clock.now.addingTimeInterval(boundaryTimeoutSeconds)
        }
        pendingReason = .budget
    }

    /// Polls the interval and pending request. The engine is never called while
    /// a tool call is running and the 60 s boundary wait has not expired; after
    /// that wait the injected drainer runs, then the engine is asked to
    /// restart anyway (budgets.md §4).
    public func poll() async throws -> RestartPollResult {
        if pendingReason == nil, clock.now >= nextDeadline {
            pendingReason = .plannedInterval
            boundaryDeadline = nextDeadline.addingTimeInterval(boundaryTimeoutSeconds)
        }
        guard let reason = pendingReason else { return .notDue }

        if await boundary.atToolCallBoundary() {
            boundaryDeadline = nil
            return try await requestRestart(reason: reason, forced: false)
        }

        if boundaryDeadline == nil {
            // A pending request without a deadline starts its wait at this
            // poll; this keeps the escape finite even for externally created
            // pending restarts.
            boundaryDeadline = clock.now.addingTimeInterval(boundaryTimeoutSeconds)
        }
        guard let deadline = boundaryDeadline, clock.now >= deadline else {
            return .deferred(reason: reason)
        }
        boundaryDeadline = nil
        if let drainer {
            try await drainer.drainForForcedRestart(reason: reason)
        }
        return try await requestRestart(reason: reason, forced: true)
    }

    private func requestRestart(reason: RestartReason,
                                forced: Bool) async throws -> RestartPollResult {
        do {
            try await requester.requestWebContentRestart(reason: reason)
        } catch {
            // Keep the pending request so the facade can retry after the
            // engine reports that it is ready again.
            throw error
        }
        pendingReason = nil
        boundaryDeadline = nil
        nextDeadline = clock.now.addingTimeInterval(intervalSeconds)
        return forced ? .forced(reason: reason) : .requested(reason: reason)
    }

    /// Clears a pending request after an externally driven restart.
    public func restartCompleted() {
        pendingReason = nil
        boundaryDeadline = nil
        nextDeadline = clock.now.addingTimeInterval(intervalSeconds)
    }

    /// Abandons a pending request (for example when authority moved remote).
    public func cancelPendingRestart() {
        pendingReason = nil
        boundaryDeadline = nil
    }
}
