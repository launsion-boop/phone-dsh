// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — PhoneDSHController: host state machine.
//
// PLAN §2.5 (D14/D15) and spec/v1/budgets.md §1–§3. The nine host
// states are driven only by the signals of the D14 table; every accepted
// transition persists `host-state.json` atomically. Admission is published to
// the loopback layer through `AdmissionGate` and is open only in `Running`.
// A boot that finds `Running`, `Draining` or `Recovering` restores `Recovering`;
// `Recovering -> Running` is reachable only through `verifyLease()`.

import Foundation
import PhoneDSHLog
import PhoneDSHWire

/// Why this host process booted. The D14 state table is unchanged, including
/// "no persisted state -> Recovering": the disposition is the machine-readable
/// distinction between a genuinely empty workspace and a crash recovery.
public enum HostBootDisposition: String, CaseIterable, Codable, Sendable {
    /// No persisted host state, WAL or manifest: a new, empty workspace.
    case coldStart = "cold_start"
    /// Persisted host state or workspace history was found at process start.
    case crashRecovery = "crash_recovery"
    /// A clean persisted `Parked` host was restored (its `resume()` follows).
    case parkedResume = "parked_resume"
    /// The explicit user reset of a persisted `Failed` host.
    case userReset = "user_reset"
}

/// The driving inputs of the D14 transition table plus the signals of
/// budgets.md §3. Each case is a signal, not a request: the state machine
/// rejects it when the current state or the guard does not match.
public enum HostSignal: Equatable, Sendable {
    /// App lifecycle callback.
    case scenePhase(ScenePhase)
    /// Background task signalled that in-flight work drained early.
    case backgroundDrainCompleted
    /// The injected clock reached the 20 s drain deadline.
    case drainDeadlineElapsed
    /// The OS background task expired; forces the drain deadline (budgets.md §3).
    case backgroundTaskExpired
    /// Planned WebContent restart at a tool-call boundary (PLAN §2.5).
    case plannedRestart
    /// WKWebView terminated the WebContent process.
    case webContentTerminated(WebContentTermination)
    /// NWPathMonitor changed its status.
    case networkPath(NetworkPathStatus)
    /// The model upstream answered 429 or 5xx.
    case upstreamUnavailable(status: Int)
    /// Backoff retry reached a successful probe.
    case retryProbeSucceeded
    /// A handoff to the remote was requested while foreground/draining.
    case handoffRequested
    /// `POST /v1/handoff/fence` succeeded; the remote holds generation + 1.
    case handoffFenceInstalled
    /// The remote accepted fence, snapshot and segments and opened admission.
    case handoffCompleted(remoteAdmission: Admission)
    /// The handoff failed after a successful fence; the token must be reclaimed.
    case handoffFailed
    /// The user or a foreground return asked to reclaim authority.
    case reclaimRequested
    /// The reclaim response and returned segments were applied.
    case reclaimResponseApplied
    /// The new fence was persisted and an epoch was closed.
    case reclaimCompleted(fencePersisted: Bool, epochClosed: Bool)
    /// Unrecoverable condition, fail loud.
    case failure(reason: String)
    /// Explicit user reset of a `Failed` host.
    case userReset
}

extension HostSignal {
    /// Stable label used in transition records and errors.
    public var label: String {
        switch self {
        case .scenePhase(let phase): return "scenePhase(\(phase.rawValue))"
        case .backgroundDrainCompleted: return "backgroundDrainCompleted"
        case .drainDeadlineElapsed: return "drainDeadlineElapsed"
        case .backgroundTaskExpired: return "backgroundTaskExpired"
        case .plannedRestart: return "plannedRestart"
        case .webContentTerminated: return "webContentTerminated"
        case .networkPath(let status): return "networkPath(\(status.rawValue))"
        case .upstreamUnavailable(let status): return "upstreamUnavailable(\(status))"
        case .retryProbeSucceeded: return "retryProbeSucceeded"
        case .handoffRequested: return "handoffRequested"
        case .handoffFenceInstalled: return "handoffFenceInstalled"
        case .handoffCompleted: return "handoffCompleted"
        case .handoffFailed: return "handoffFailed"
        case .reclaimRequested: return "reclaimRequested"
        case .reclaimResponseApplied: return "reclaimResponseApplied"
        case .reclaimCompleted: return "reclaimCompleted"
        case .failure: return "failure"
        case .userReset: return "userReset"
        }
    }
}

/// Errors of the host state machine. Illegal transitions are values so the
/// tests and the facade can report them without crashing.
public enum HostStateError: Error, Equatable, Sendable {
    case illegalTransition(from: HostState, signal: String)
    case guardFailed(signal: String, reason: String)
    case deadlineNotReached
    /// D24: a `Backoff` restored from disk may not start before its retry
    /// deadline.
    case backoffDeadlineNotReached(deadline: Date)
    case epochCloseFailed(String)
    case persistenceFailed(String)
}

/// One accepted transition, published to observers (facade diagnostics, UI).
public struct HostTransitionRecord: Equatable, Sendable {
    public var from: HostState
    public var to: HostState
    public var signal: String
    public var admission: Admission
    public var at: Date
    /// Machine-readable boot cause on a boot-related edge (`cold_start`,
    /// `crash_recovery`, `parked_resume`, `user_reset`), `nil` otherwise.
    public var reason: String?

    public init(from: HostState, to: HostState, signal: String,
                admission: Admission, at: Date, reason: String? = nil) {
        self.from = from
        self.to = to
        self.signal = signal
        self.admission = admission
        self.at = at
        self.reason = reason
    }
}

/// Persisted `host-state.json` (PLAN §2.5). Markdown/JSON files carry no SPDX
/// header; the record version is explicit so a future format can migrate.
struct PersistedHostState: Codable, Equatable {
    var version: Int
    var state: HostState
    var updatedAtMilliseconds: Int64
    var reason: String?
    /// D24: when a persisted `Backoff` may be booted again. Optional so files
    /// written before D24 (and every non-Backoff state) remain readable.
    var backoffUntilMilliseconds: Int64?
    /// G2-FIX-96: why this process booted. Optional so older files remain
    /// readable; a missing value is reported as unknown, never guessed.
    var bootDisposition: HostBootDisposition?
    var bootReason: String?

    enum CodingKeys: String, CodingKey {
        case version
        case state
        case updatedAtMilliseconds = "updated_at_ms"
        case reason
        case backoffUntilMilliseconds = "backoff_until_ms"
        case bootDisposition = "boot_disposition"
        case bootReason = "boot_reason"
    }
}

/// The host/step controller of PLAN §2.4–§2.5 (D13/D14/D15).
///
/// `HostStateMachine` owns exactly one of the nine ``HostState`` values, the
/// admission gate the loopback layer consults, the 20 s drain deadline and the
/// persisted record that boot recovery reads.
public actor HostStateMachine {
    /// PLAN §2.5 drain deadline.
    public static let drainDeadlineSeconds: TimeInterval = 20
    /// D24 default retry window of a persisted `Backoff`. The value is a policy
    /// constant (the controller has no `Retry-After` source), not a
    /// measurement.
    public static let defaultBackoffIntervalSeconds: TimeInterval = 30

    /// Admission published to the loopback layer. Kept outside the actor so
    /// the side-effect path can consult it synchronously.
    public nonisolated let admission: AdmissionGate

    /// Cooperative cancellation signalled when the drain deadline expires.
    public nonisolated let drainCancellation: DrainCancellation

    /// Workspace root, `Library/xl/<workspace_id>/`.
    public nonisolated let root: URL
    /// The current state (D14).
    public private(set) var state: HostState
    /// Why this process booted (G2-FIX-96); independent of the nine-state table.
    public private(set) var bootDisposition: HostBootDisposition
    /// Machine-readable boot cause persisted in `host-state.json`.
    public private(set) var bootReason: String
    /// Reason of the last fail-loud transition; `nil` when healthy.
    public private(set) var lastError: String?
    /// When the current drain began, `nil` outside `Draining`.
    public private(set) var drainDeadline: Date?
    /// The state the current drain continues to (parked / recovering / ...).
    public private(set) var drainTarget: HostState?

    private let clock: any HostClock
    private let epochCloser: (any HostEpochClosing)?
    /// budgets.md §2 `Backoff -> Running`: "Reopen admission after a lease
    /// check". The facade injects `FenceAuthority.backoffLeaseVerifier(presented:)`
    /// (or an equivalent check) so a host that lost authority never reopens
    /// admission from Backoff. `nil` keeps the verified invariant documented
    /// at the `.retryProbeSucceeded` edge.
    private let leaseVerifier: (@Sendable () async throws -> Bool)?
    private let deadlineSeconds: TimeInterval
    /// D24 retry window for a persisted `Backoff`.
    private let backoffIntervalSeconds: TimeInterval
    /// D24 deadline of the current `Backoff`, persisted in `host-state.json`.
    private var backoffUntil: Date?
    private let stateURL: URL
    private let transitionHub = SignalBroadcaster<HostTransitionRecord>()
    private var drainTimer: Task<Void, Never>?
    private var fenceInstalled = false
    private var networkPathSatisfied = false
    private var reclaimApplied = false
    private var shuttingDown = false
    /// Serializes signal handling across the await points of an epoch close.
    /// An actor is reentrant, so without this two signals could both observe
    /// `Draining` and close the epoch twice.
    private var transitionInFlight = false

    /// Boots from `host-state.json` with the D14 boot mapping.
    ///
    /// - persisted `Running`, `Draining`, `Recovering` → `Recovering`
    /// - persisted `Failed` → `Failed` (only an explicit reset leaves it)
    /// - persisted `Parked`/`Backoff`/`Remote` keep their state; an interrupted
    ///   `HandingOff` becomes `Failed` because the controller cannot prove the
    ///   CAS outcome on its own. A cold `reclaim()` against the App's secure
    ///   token vault may then leave `Failed` through the explicit user-reset
    ///   action once the remote response proves the token. `Reclaiming`
    ///   restarts in `Recovering`
    /// - no persisted state → `Recovering`
    ///
    /// Admission is closed in every restored state.
    ///
    /// - Parameters:
    ///   - workspaceHasState: `true` when the App found a persisted
    ///     `host-state.json`, WAL records or a manifest before this boot. It is
    ///     only used to label an otherwise stateless boot (`cold_start` versus
    ///     `crash_recovery`); the D14 state mapping is unchanged.
    ///   - userReset: the explicit user acknowledgement of a persisted
    ///     `Failed` controller, used for the `user_reset` disposition.
    public init(root: URL,
                clock: any HostClock = SystemHostClock(),
                epochCloser: (any HostEpochClosing)? = nil,
                leaseVerifier: (@Sendable () async throws -> Bool)? = nil,
                drainDeadlineSeconds: TimeInterval = HostStateMachine.drainDeadlineSeconds,
                backoffIntervalSeconds: TimeInterval = HostStateMachine.defaultBackoffIntervalSeconds,
                workspaceHasState: Bool = false,
                userReset: Bool = false) throws {
        self.root = root
        self.clock = clock
        self.epochCloser = epochCloser
        self.leaseVerifier = leaseVerifier
        self.deadlineSeconds = max(0, drainDeadlineSeconds)
        let interval = max(0, backoffIntervalSeconds)
        self.backoffIntervalSeconds = interval
        self.stateURL = root.appendingPathComponent("host-state.json")
        self.admission = AdmissionGate(.closed)
        self.drainCancellation = DrainCancellation()
        self.bootDisposition = .coldStart
        self.bootReason = Self.coldStartReason

        var restored = HostState.recovering
        var restoredError: String?
        var restoredBackoffUntil: Date?
        var persistedState: HostState?
        if let persisted = try ControllerFileStore.readJSON(
            PersistedHostState.self, from: stateURL),
            persisted.version == 1 {
            persistedState = persisted.state
            restored = Self.bootState(for: persisted.state)
            restoredError = persisted.reason
            if restored == .backoff {
                if let milliseconds = persisted.backoffUntilMilliseconds {
                    restoredBackoffUntil = Date(
                        timeIntervalSince1970: TimeInterval(milliseconds) / 1000)
                } else {
                    // Pre-D24 record: the transition that entered Backoff wrote
                    // `updated_at_ms`, so the deadline starts there.
                    restoredBackoffUntil = Date(
                        timeIntervalSince1970: TimeInterval(persisted.updatedAtMilliseconds) / 1000
                    ).addingTimeInterval(interval)
                }
            }
        }
        let boot = Self.bootInfo(persisted: persistedState,
                                 workspaceHasState: workspaceHasState,
                                 userReset: userReset)
        self.bootDisposition = boot.disposition
        self.bootReason = boot.reason
        self.state = restored
        self.lastError = restoredError
        self.backoffUntil = restoredBackoffUntil
        // Persist the mapped boot state even when the file did not exist so a
        // second boot always has a record.
        try Self.persist(state: restored, error: restoredError,
                         backoffUntil: restoredBackoffUntil,
                         bootDisposition: boot.disposition, bootReason: boot.reason,
                         to: stateURL, at: clock.now)
    }

    /// Stable reason for a brand-new, empty workspace.
    public static let coldStartReason = "empty_workspace"

    /// Chooses the machine-readable boot label without changing the D14 state
    /// mapping. A stateless boot with workspace history is a crash recovery,
    /// not a cold start.
    static func bootInfo(persisted: HostState?, workspaceHasState: Bool,
                         userReset: Bool) -> (disposition: HostBootDisposition,
                                              reason: String) {
        if userReset, persisted == .failed {
            return (.userReset, "explicit_user_reset")
        }
        if let persisted {
            switch persisted {
            case .parked:
                return (.parkedResume, "persisted_parked")
            case .running, .draining, .recovering, .reclaiming, .handingOff,
                 .backoff, .remote, .failed:
                return (.crashRecovery, "persisted_\(persisted.rawValue)")
            }
        }
        if workspaceHasState {
            return (.crashRecovery, "workspace_without_host_state")
        }
        return (.coldStart, Self.coldStartReason)
    }

    /// The D14 boot mapping.
    static func bootState(for persisted: HostState) -> HostState {
        switch persisted {
        case .running, .draining, .recovering, .reclaiming:
            return .recovering
        case .parked:
            return .parked
        case .backoff:
            return .backoff
        case .remote:
            return .remote
        case .handingOff:
            return .failed
        case .failed:
            return .failed
        }
    }

    /// Applies one signal of the D14 table. Signals that are not an edge out
    /// of the current state throw ``HostStateError/illegalTransition(from:signal:)``.
    @discardableResult
    public func handle(_ signal: HostSignal) async throws -> HostState {
        guard !shuttingDown else {
            throw HostStateError.illegalTransition(from: state, signal: signal.label)
        }
        guard !transitionInFlight else {
            throw HostStateError.illegalTransition(from: state, signal: signal.label)
        }
        transitionInFlight = true
        defer { transitionInFlight = false }
        switch signal {
        case .scenePhase(let phase):
            return try await handleScenePhase(phase, signal: signal)

        case .backgroundDrainCompleted:
            guard state == .draining else { throw illegal(signal) }
            return try await finishDrain(signal: signal, cancelInFlight: false)

        case .drainDeadlineElapsed:
            guard state == .draining else { throw illegal(signal) }
            guard let deadline = drainDeadline, clock.now >= deadline else {
                throw HostStateError.deadlineNotReached
            }
            return try await finishDrain(signal: signal, cancelInFlight: true)

        case .backgroundTaskExpired:
            guard state == .draining else { throw illegal(signal) }
            return try await finishDrain(signal: signal, cancelInFlight: true)

        case .plannedRestart:
            switch state {
            case .running, .draining:
                return try await transition(to: .recovering, signal: signal,
                                            closeEpoch: true)
            default:
                throw illegal(signal)
            }

        case .webContentTerminated(let termination):
            switch state {
            case .draining:
                return try await transition(to: .recovering, signal: signal,
                                            closeEpoch: true)
            case .running where termination.wasForeground:
                return try await transition(to: .recovering, signal: signal,
                                            closeEpoch: true)
            default:
                throw illegal(signal)
            }

        case .networkPath(let status):
            switch (state, status) {
            case (.running, .unsatisfied):
                return try await transition(to: .backoff, signal: signal)
            case (.backoff, .satisfied):
                networkPathSatisfied = true
                return state
            case (.backoff, .unsatisfied), (.backoff, .requiresConnection):
                networkPathSatisfied = false
                return state
            default:
                throw illegal(signal)
            }

        case .upstreamUnavailable(let status):
            guard state == .running, status == 429 || (500...599).contains(status) else {
                throw illegal(signal)
            }
            return try await transition(to: .backoff, signal: signal)

        case .retryProbeSucceeded:
            guard state == .backoff else { throw illegal(signal) }
            guard networkPathSatisfied else {
                throw HostStateError.guardFailed(signal: signal.label,
                                                 reason: "network path is not satisfied")
            }
            // budgets.md §2: "Reopen admission after a lease check". The facade
            // injects `FenceAuthority.backoffLeaseVerifier(presented:)`, so the lease
            // is validated against the persisted authority before admission
            // opens. Backoff never hands the fence off, but a host that lost
            // authority while it was away must still not reopen admission:
            // without a verifier the invariant is the D14 fact that no handoff
            // edge is reachable from Backoff. `verifyLease()` remains the only
            // Recovering -> Running entry (D14).
            if let leaseVerifier {
                let verified: Bool
                do {
                    verified = try await leaseVerifier()
                } catch {
                    throw HostStateError.guardFailed(
                        signal: signal.label,
                        reason: "lease check failed: \(error)")
                }
                guard verified else {
                    throw HostStateError.guardFailed(
                        signal: signal.label, reason: "lease check failed")
                }
            }
            return try await transition(to: .running, signal: signal)

        case .handoffRequested:
            guard state == .running || state == .draining else { throw illegal(signal) }
            fenceInstalled = false
            return try await transition(to: .handingOff, signal: signal,
                                        closeEpoch: true)

        case .handoffFenceInstalled:
            guard state == .handingOff else { throw illegal(signal) }
            fenceInstalled = true
            return state

        case .handoffCompleted(let remoteAdmission):
            guard state == .handingOff else { throw illegal(signal) }
            guard remoteAdmission == .open else {
                throw HostStateError.guardFailed(signal: signal.label,
                                                 reason: "remote admission is closed")
            }
            return try await transition(to: .remote, signal: signal)

        case .handoffFailed:
            guard state == .handingOff else { throw illegal(signal) }
            guard fenceInstalled else {
                throw HostStateError.guardFailed(signal: signal.label,
                                                 reason: "no fence was installed")
            }
            return try await transition(to: .reclaiming, signal: signal)

        case .reclaimRequested:
            guard state == .remote else { throw illegal(signal) }
            reclaimApplied = false
            return try await transition(to: .reclaiming, signal: signal)

        case .reclaimResponseApplied:
            guard state == .reclaiming else { throw illegal(signal) }
            reclaimApplied = true
            return state

        case .reclaimCompleted(let fencePersisted, let epochClosed):
            guard state == .reclaiming else { throw illegal(signal) }
            guard reclaimApplied else {
                throw HostStateError.guardFailed(signal: signal.label,
                                                 reason: "reclaim response was not applied")
            }
            guard fencePersisted else {
                throw HostStateError.guardFailed(signal: signal.label,
                                                 reason: "new fence was not persisted")
            }
            guard epochClosed else {
                throw HostStateError.guardFailed(signal: signal.label,
                                                 reason: "the epoch was not closed")
            }
            return try await transition(to: .recovering, signal: signal)

        case .failure(let reason):
            // "any state -> Failed": a repeated failure keeps the first reason.
            lastError = reason
            if state == .failed { return state }
            return try await transition(to: .failed, signal: signal)

        case .userReset:
            guard state == .failed else { throw illegal(signal) }
            lastError = nil
            bootDisposition = .userReset
            bootReason = "explicit_user_reset"
            // The migration record carries the disposition label; the more
            // specific `explicit_user_reset` stays in `bootReason`.
            return try await transition(to: .recovering, signal: signal,
                                        reason: HostBootDisposition.userReset.rawValue)
        }
    }

    /// Verifies the lease and opens admission (D14 `Recovering -> Running`).
    ///
    /// This is the only entry into `Running` from recovery and the only place
    /// that opens admission after a resume. The caller performs the actual
    /// lease/authority verification; calling this from any state other than
    /// `Recovering` is rejected.
    @discardableResult
    public func verifyLease() async throws -> HostState {
        guard !transitionInFlight else {
            throw HostStateError.illegalTransition(from: state, signal: "verifyLease")
        }
        guard state == .recovering else {
            throw HostStateError.illegalTransition(from: state, signal: "verifyLease")
        }
        transitionInFlight = true
        defer { transitionInFlight = false }
        return try await transition(to: .running, signal: .scenePhase(.active),
                                    signalLabel: "verifyLease",
                                    reason: bootDisposition.rawValue)
    }

    /// Current state without a signal round trip.
    public func currentState() -> HostState { state }

    /// D24: the persisted Backoff retry deadline, or `nil` outside `Backoff`.
    public func backoffDeadline() -> Date? {
        state == .backoff ? backoffUntil : nil
    }

    /// D24: lets a host that booted in `Backoff` enter `Recovering` once the
    /// persisted retry deadline has passed. This is the boot-side bridge the
    /// facade needs before it can boot a Worker and verify the lease; the D14
    /// signal table itself is unchanged (no new `HostSignal` case).
    ///
    /// - Throws: ``HostStateError/illegalTransition(from:signal:)`` outside
    ///   `Backoff`, and ``HostStateError/backoffDeadlineNotReached(deadline:)``
    ///   before the deadline.
    @discardableResult
    public func resumeFromPersistedBackoff() async throws -> HostState {
        guard state == .backoff else {
            throw HostStateError.illegalTransition(from: state,
                                                   signal: "backoffDeadlineElapsed")
        }
        guard let deadline = backoffUntil else {
            // A Backoff without a recorded deadline can only come from a
            // pre-D24 record whose timestamp was unreadable; treat the retry
            // window as already over rather than trapping the host forever.
            return try await forceBackoffRecovery()
        }
        guard clock.now >= deadline else {
            throw HostStateError.backoffDeadlineNotReached(deadline: deadline)
        }
        return try await forceBackoffRecovery()
    }

    private func forceBackoffRecovery() async throws -> HostState {
        guard !transitionInFlight else {
            throw HostStateError.illegalTransition(from: state,
                                                   signal: "backoffDeadlineElapsed")
        }
        transitionInFlight = true
        defer { transitionInFlight = false }
        return try await transition(to: .recovering,
                                    signal: .retryProbeSucceeded,
                                    signalLabel: "backoffDeadlineElapsed")
    }

    /// Accepted transitions, starting with the most recent one for a late
    /// subscriber. Ends after ``shutdown()``.
    public nonisolated func transitions() -> AsyncStream<HostTransitionRecord> {
        transitionHub.stream()
    }

    /// Cancels the drain timer and finishes the observation stream.
    public func shutdown() {
        shuttingDown = true
        drainTimer?.cancel()
        drainTimer = nil
        transitionHub.finish()
        admission.finish()
    }

    // MARK: - Transition internals

    private func handleScenePhase(_ phase: ScenePhase,
                                  signal: HostSignal) async throws -> HostState {
        switch (state, phase) {
        case (.running, .background):
            return try await beginDraining(target: .parked, signal: signal)
        case (.parked, .active):
            // A park/resume inside one process must not rewrite why the
            // process booted. A boot from persisted `Parked` is already
            // labelled by `init`; this edge only records the resume.
            return try await transition(to: .recovering, signal: signal,
                                        reason: "parked_resume")
        default:
            throw illegal(signal)
        }
    }

    private func beginDraining(target: HostState, signal: HostSignal) async throws -> HostState {
        drainTarget = target
        drainDeadline = clock.now.addingTimeInterval(deadlineSeconds)
        drainCancellation.reset()
        let result = try await transition(to: .draining, signal: signal)
        scheduleDrainTimer()
        return result
    }

    private func scheduleDrainTimer() {
        drainTimer?.cancel()
        guard let deadline = drainDeadline else { return }
        let clock = self.clock
        drainTimer = Task { [weak self] in
            let interval = max(0, deadline.timeIntervalSince(clock.now))
            await clock.sleep(for: interval)
            guard !Task.isCancelled else { return }
            guard let self else { return }
            await self.drainTimerFired()
        }
    }

    private func drainTimerFired() async {
        guard !shuttingDown, state == .draining else { return }
        guard let deadline = drainDeadline, clock.now >= deadline else { return }
        _ = try? await handle(.drainDeadlineElapsed)
    }

    private func finishDrain(signal: HostSignal,
                             cancelInFlight: Bool) async throws -> HostState {
        let target = drainTarget ?? .parked
        if cancelInFlight {
            drainCancellation.cancel()
        }
        drainTimer?.cancel()
        drainTimer = nil
        return try await transition(to: target, signal: signal, closeEpoch: true)
    }

    private func transition(to newState: HostState,
                            signal: HostSignal,
                            signalLabel: String? = nil,
                            closeEpoch: Bool = false,
                            reason: String? = nil) async throws -> HostState {
        let from = state
        let label = signalLabel ?? signal.label
        if closeEpoch, let epochCloser {
            do {
                try await epochCloser.closeHostEpoch()
            } catch {
                let reason = "epoch close failed before \(newState.rawValue)"
                lastError = reason
                try forceFailed(reason: reason)
                throw HostStateError.epochCloseFailed(reason)
            }
        }

        if from == .draining {
            drainTimer?.cancel()
            drainTimer = nil
            drainDeadline = nil
            drainTarget = nil
        }
        if newState != .backoff {
            networkPathSatisfied = false
        }
        if newState != .handingOff {
            fenceInstalled = false
        }
        if newState != .reclaiming {
            reclaimApplied = false
        }
        if newState == .backoff {
            // D24: record when the persisted Backoff may be booted again. A
            // process restart keeps this deadline; it does not restart it.
            backoffUntil = clock.now.addingTimeInterval(backoffIntervalSeconds)
        } else {
            backoffUntil = nil
        }

        state = newState
        admission.set(newState == .running ? .open : .closed)
        do {
            try Self.persist(state: newState, error: lastError,
                             backoffUntil: backoffUntil,
                             bootDisposition: bootDisposition, bootReason: bootReason,
                             to: stateURL, at: clock.now)
        } catch {
            let reason = "cannot persist host-state.json"
            lastError = reason
            state = .failed
            admission.set(.closed)
            throw HostStateError.persistenceFailed(reason)
        }
        transitionHub.yield(HostTransitionRecord(
            from: from, to: newState, signal: label,
            admission: admission.current, at: clock.now, reason: reason))
        return newState
    }

    private func forceFailed(reason: String) throws {
        let from = state
        state = .failed
        admission.set(.closed)
        backoffUntil = nil
        try? Self.persist(state: .failed, error: reason, backoffUntil: nil,
                          bootDisposition: bootDisposition, bootReason: bootReason,
                          to: stateURL, at: clock.now)
        transitionHub.yield(HostTransitionRecord(
            from: from, to: .failed, signal: "epochCloseFailure",
            admission: .closed, at: clock.now))
    }

    private func illegal(_ signal: HostSignal) -> HostStateError {
        HostStateError.illegalTransition(from: state, signal: signal.label)
    }

    private static func persist(state: HostState, error: String?, backoffUntil: Date?,
                                bootDisposition: HostBootDisposition, bootReason: String,
                                to url: URL, at date: Date) throws {
        let record = PersistedHostState(
            version: 1, state: state,
            updatedAtMilliseconds: date.millisecondsSinceEpoch,
            reason: error,
            backoffUntilMilliseconds: backoffUntil.map {
                Int64(($0.timeIntervalSince1970 * 1000).rounded())
            },
            bootDisposition: bootDisposition,
            bootReason: bootReason)
        let data = try ControllerFileStore.encode(record)
        do {
            try ControllerFileStore.writeAtomic(data, to: url)
        } catch {
            throw HostStateError.persistenceFailed("cannot write host-state.json")
        }
    }
}
