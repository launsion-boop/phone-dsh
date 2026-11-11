// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — PhoneDSH: the App-process host.
//
// PLAN §2.1/§2.5 and W2-FACADE. `PhoneDSHHost` assembles the landed services:
//
//   WorkspaceLog -> channel seams -> LoopbackServer (static/image/overlay,
//   /v1/http gateway, MCP proxy, exec provider)
//   FenceAuthority / HostStateMachine / StepMachine / SideEffectLedger
//   ChannelDSHTransport -> DSHRemoteHarness -> AgentHarness
//   WebEngineControlling (WKWebView in production, a mock in tests)
//
// Lifecycle: `start()` recovers, boots the engine, waits for the Worker HELLO,
// verifies the lease and only then opens admission (D14). `park()` follows
// `Running -> Draining -> Parked` and keeps the workspace resources for a fast
// `resume()`; `stop()` drains if needed and releases everything.

import Foundation
import PhoneDSHAgentCore
import PhoneDSHController
import PhoneDSHEngine
import PhoneDSHGateway
import PhoneDSHLog
import PhoneDSHLoopback
import PhoneDSHWire
import PhoneDSHShell

/// The App-process facade (PLAN §2.1). See ``PhoneDSHHosting`` for the minimal
/// host-facing protocol and ``PhoneDSHHost/harness()`` for the Agent bridge.
public actor PhoneDSHHost: PhoneDSHHosting {
    /// Services assembled by one boot. Parked hosts keep this value; stopped
    /// hosts release it.
    private struct RuntimeServices {
        let log: WorkspaceLog
        let authority: FenceAuthority
        let machine: HostStateMachine
        let stepMachine: StepMachine
        let ledger: SideEffectLedger
        let ledgerRecorder: PhoneDSHLedgerRecorder
        let gateway: ModelGateway
        let responseLog: ResponseLog?
        let coordinator: PhoneDSHChannelCoordinator
        /// D15 handoff/reclaim owner over this live workspace. `nil` when the
        /// App did not configure ``PhoneDSHConfiguration/handoff``.
        let handoff: HandoffCoordinator?
        let loopback: LoopbackServer
        let budgetMonitor: BudgetMonitor
        let overlayURL: URL
        var engine: (any WebEngineControlling)?
        var engineConfiguration: WebEngineConfiguration
    }

    /// The remote half of the facade that must survive a host stop while the
    /// controller is `Remote`/`Reclaiming`: the coordinator owns the in-memory
    /// reclaim token, and the controller stays alive so the D15 return path can
    /// still complete after the App restarts the host object.
    private struct RemoteHandoffContext {
        let coordinator: HandoffCoordinator
        let machine: HostStateMachine
    }

    /// Immutable configuration of this host instance.
    public nonisolated let configuration: PhoneDSHConfiguration
    /// The single ordered event sequence (see ``PhoneDSHEvent``).
    public nonisolated let eventBus: PhoneDSHEventBus

    private let engineFactory: PhoneDSHEngineFactory
    /// Transport seam for the D15 remote endpoints. `nil` uses
    /// ``URLSessionHandoffTransport``; tests inject the in-process simulator.
    private let handoffTransport: (any HandoffHTTPTransport)?
    /// App-owned secure vault for the reclaim token. The default is
    /// process-lifetime only; a cold process needs the injected secure store.
    private let reclaimTokenStore: any HandoffReclaimTokenStore
    private let bootID: String
    /// Per-Worker-process boot id. channel.md D6 defines `boot_id` per Worker
    /// process, not per host; a resume/rebuild that reused the host id made a
    /// suspended old Worker indistinguishable from its replacement. Each boot
    /// now generates a fresh value and retires every earlier one.
    private var workerBootID = PhoneDSHBootID.make()
    /// Every Worker boot id this host has already stopped. A late HELLO or a
    /// reconnect from one of these incarnations is refused by the channel
    /// barrier instead of stealing the replacement's connection.
    private var retiredWorkerBootIDs: Set<String> = []
    /// Foreground-only elapsed time for boot/resume diagnostics and budgets.
    private let foregroundClock = PhoneDSHForegroundClock()
    /// Page/Worker phase console lines for `boot-timings.log`.
    private let bootPhaseRecorder = PhoneDSHBootPhaseRecorder()
    /// The in-flight resume's cancellation token. `setForeground(false)` fires
    /// it; the resume unwinds, releases the exclusive gate and leaves the
    /// controller in `Recovering` for the next foreground attempt.
    private var activeResumeCancellation: PhoneDSHResumeCancellation?
    /// The engine created for the in-flight resume. `setForeground(false)`
    /// shuts it down directly; the boot call then returns and the resume catch
    /// can release the gate without a task-group race over the WebSocket.
    private var activeResumeEngine: (any WebEngineControlling)?
    /// Foreground-clock value when the current resume started. Resume phase
    /// numbers subtract it so a background interval is not reported as work.
    private var activeResumeActiveStart: Double = 0
    /// True when the last resume was cancelled by a background transition. The
    /// controller stays `Recovering`; the next resume continues that boot
    /// instead of requiring a `Parked` edge D14 does not define.
    private var resumeInterrupted = false
    private let sessionEpoch: UInt64 = 1
    /// The one MCP egress credential of this host incarnation
    /// (`PDSH_MCP_EGRESS_TOKEN`). Generated once at object creation, delivered
    /// with every Worker boot of this host run, and never rotated by a Worker
    /// restart or engine rebuild. It lives in host memory only.
    nonisolated let mcpEgressToken: String = MCPEgressCredential.make()
    /// Turn-inactivity counters shared by every supervised harness this host
    /// hands out (G2-FIX-12). It holds no session or credential state.
    private let inactivityLedger: PhoneDSHTurnInactivityLedger
    /// DSH session ids this host incarnation handed to the Worker (G2-FIX-9).
    /// The drain uses it to scope terminal-journal verification to live
    /// sessions; a journal left open by an earlier crashed boot is ignored.
    private let sessionTracker = PhoneDSHSessionTracker()
    /// Incremental journal-state cache for the abort drain (G2-FIX-9 P1). The
    /// drain polls every 50 ms; a stat-only check keeps an unchanged journal
    /// (up to the 64 MiB `budgets.md` bound) from being re-read.
    private let sessionJournalCache = PhoneDSHJournalStateCache()
    /// Wall-clock start of the current Worker incarnation. A child journal
    /// whose immutable `createdAt` predates it is a stale record from an
    /// earlier Worker **unless the current route reports that exact id live**:
    /// DSH cold resume reuses the child id and persisted header, so the route's
    /// live set overrides the timestamp. A journal that is old and not reported
    /// live has no resident Activation to close, and cold-resume recovery owns
    /// it instead.
    ///
    /// This is a Worker-epoch boundary, not only a host-start boundary. Every
    /// boot (``beginStart``, ``bootRuntime``, ``plannedRestart`` and
    /// ``recoverAfterTermination``) starts a new Worker with no inherited
    /// child Activation, so a journal left open by the previous Worker must
    /// not make the next park/stop wait for a `turn/end` it can never write.
    /// A cold-resumed child is still reachable through the route-reported live
    /// set.
    private var workerIncarnationStartedAt = Date()
    /// Descendant ids the Worker route reported live at any point in the
    /// current Worker epoch. DSH cold resume reuses the child id and persisted
    /// header, so an old `createdAt` alone is not stale evidence. Keeping the
    /// reported set across the early pre-graceful pass and the abort
    /// verification pass means a child that was live here is still checked for
    /// its durable `turn/end`, even if a later listing omits it. Cleared by
    /// ``beginWorkerIncarnation``.
    private var reportedLiveDescendantSessionIDs: Set<String> = []
    /// Exact tracked roots this drain window already named in a *successful*
    /// scoped descendant-drain route call.
    ///
    /// This is deliberately scoped to one park/stop (cleared by
    /// ``beginDescendantDrainWindow``) rather than to the Worker epoch: the
    /// early pre-graceful pass may spend the route budget while the graceful
    /// wait still legitimately runs until the cancellation reserve. When the
    /// abort pass starts after ``DrainEscalationPlan/escalationDeadline`` but
    /// before ``DrainEscalationPlan/verifyDeadline``, a second route call has
    /// no pre-escalation budget left even though the roots were already named
    /// successfully. Treating that as an *unattempted* mandatory route fails a
    /// normal park whose turn simply ended late. The durable forest is still
    /// re-read and verified; the early receipt is not accepted as terminal
    /// evidence. A root that was never covered stays fail loud.
    private var descendantDrainAttemptedRoots: Set<String> = []

    /// The coarse App-facing state (PLAN §2.5).
    public private(set) var state: PhoneDSHState = .stopped

    private var runtime: RuntimeServices?
    /// One exclusive App-facing lifecycle operation. The actor is reentrant
    /// across network, engine and drain awaits, so start/resume/park/stop,
    /// planned restart, reset and the D15 begin/reclaim calls must not overlap
    /// each other or the fence/state transitions they drive.
    private enum ExclusiveOperation: String, Equatable {
        case start
        case resume
        case handoff
        case reclaim
        case park
        case stop
        case restart
        case reset
    }
    private var exclusiveOperation: ExclusiveOperation?
    private var handoffOperationInFlight: Bool {
        exclusiveOperation == .handoff || exclusiveOperation == .reclaim
    }
    /// Kept only while the controller is `Remote`/`Reclaiming` and the host was
    /// stopped: the coordinator (and its injected token store) must survive a
    /// same-process host restart instead of being rebuilt.
    private var remoteHandoff: RemoteHandoffContext?
    private var machineObserver: Task<Void, Never>?
    private var engineObserver: Task<Void, Never>?
    /// D7 periodic epoch close. Runs only in `Running`; a held/outstanding
    /// resync skips the tick with a recorded reason (GAP-12).
    private var periodicEpochCloseTask: Task<Void, Never>?
    private var periodicEpochCloseToken = UUID()
    private var periodicEpochCloseIntervalOverride: TimeInterval?
    private var periodicEpochCloseObserver: (@Sendable (PeriodicEpochCloseOutcome) -> Void)?
    private var lastError: String?
    /// The resume line being accumulated, and the phase currently in flight.
    /// The exclusive resume gate guarantees one at a time.
    private var activeResumeTiming: PhoneDSHResumeTiming?
    private var activeResumePhase: String?
    private var activeResumeNote: String?
    /// Visibility-wait clock; tests replace it with a virtual one.
    private var resumeVisibilityClock = PhoneDSHResumeVisibilityClock.system
    /// The most specific wal.md §5.2 drain-close mismatch detail (path + mseq).
    /// The controller wraps an epoch-close failure as "epoch close failed before
    /// parked", so the host keeps this detail and reports it instead of losing
    /// it in the wrapper.
    private var lastMismatchDetail: String?
    private var lastSnapshot: PhoneDSHDiagnostics?
    private var terminations: UInt64 = 0
    private var lastBudgetDecision: BudgetDecision?
    /// Latest WebContent heap sample reported by the engine/App. `nil` until
    /// the platform provides one; the budget monitor then uses only the VFS
    /// proxy.
    private var engineHeapBytes: Int?
    /// Remembered engine capability: a failed boot still lets ``harness()``
    /// explain that Lockdown Mode is the reason.
    private var lockdownModeObserved = false
    /// A termination observed while parking must not start a recovery boot.
    private var parking = false
    /// Whether the current park is a host teardown (`stop()`) rather than a
    /// background park. A teardown also cancels in-flight Worker tool signals
    /// (0x50 LIFECYCLE stop, G2-FIX-84); a background park drains gracefully
    /// and lets a running tool finish inside the drain window, because its
    /// writes are exactly what the park/resume recovery has to preserve.
    private var stopping = false
    /// A host-side planned restart owns the `Running -> Recovering` edge; a
    /// WebContent termination observed meanwhile must not start a second boot.
    private var restarting = false
    /// Whether the App is in the foreground (P6). Recovery boots WebContent,
    /// replays the WAL and reopens an epoch, so they only run while the App can
    /// actually be scheduled; a termination observed in the background records
    /// ``pendingRecovery`` instead. Defaults to `true` so a caller that never
    /// reports the scene phase keeps the pre-gate behaviour.
    private var isForeground = true
    /// A WebContent termination arrived while the App was in the background.
    /// ``setForeground(_:)`` consumes it (the controller must still be in
    /// `Recovering`); ``recoverAfterTermination(_:)`` never boots on its own
    /// from the background.
    private var pendingRecovery = false
    /// A termination recovery boot owns the controller's `Recovering` state
    /// until it opens admission or fails. A second termination observed during
    /// that boot must not start a competing Worker.
    private var recoveringTermination = false
    /// The process-lifecycle observer this host installed itself (P1).
    ///
    /// The host observes the platform so `setForeground(_:)` does not depend on
    /// the App forwarding `scenePhase`. The probe app forwards scene phase to
    /// `ChatModel` for keep-alive, park and resume. A build that dropped that
    /// call froze the Worker with no drain, and this gate would not have run
    /// either. Observing here keeps the gate on when an App forgets to forward.
    /// This observer only updates the foreground flag and consumes
    /// `pendingRecovery`. The silent audio session stays in the probe app.
    private var processLifecycle: PhoneDSHProcessLifecycle?

    /// Extra replacement-Worker boot attempts after a `.boot`-class failure.
    ///
    /// The incident's failure (`PROTO_MISMATCH` arriving as a bootstrap
    /// failure) is process-scoped: a new page and new Worker clear it. Two
    /// retries keep the total boot work bounded without turning one bad
    /// handshake into a persisted `failed`.
    private static let maximumBootRetries = 2
    /// Short pause between two replacement-Worker boot attempts. Long enough
    /// for a just-killed WebContent process to be reaped, short enough not to
    /// dominate the boot budget.
    private static let bootRetryBackoff: TimeInterval = 0.25
    /// The smallest remaining HELLO window a retry is worth starting in.
    private static let minimumRetryHelloBudget: TimeInterval = 0.25
    /// Boot ids of restarts already published as `.restarted`.
    ///
    /// A planned restart produces the same report twice — once as the engine's
    /// own `.restarted` event, once as the return value of
    /// ``WebEngineRestartRequesting/restart(reason:)`` — and the two can be
    /// observed in either order. The boot id identifies the same cold start, so
    /// the second copy is dropped; a termination recovery publishes only
    /// through the engine's event and is recorded here as well.
    private var publishedRestartBootIDs: Set<String> = []
    /// Test seam: runs after the D14 drain (including the controller's epoch
    /// close) and before ``closeRuntimeForPark(_:)`` tears the loopback down,
    /// with the live workspace log. Production leaves it `nil`. The G2-B08
    /// regression injects the sink mutation that reached the log in exactly
    /// that window, which is what opened the never-closed epoch.
    private var drainWindowProbe: (@Sendable (WorkspaceLog) async throws -> Void)?
    private var failureSealProbeForTesting: (@Sendable () async throws -> Void)?
    /// Test seam: runs after the handoff operation gate is acquired and before
    /// the local runtime is suspended. Production leaves it `nil`; the facade
    /// regression uses it to inject a lifecycle call or a WebContent
    /// termination into that exact window.
    private var handoffPreparationProbe: (@Sendable () async throws -> Void)?
    /// Test seam: runs after the pre-boot guard observed a durable definite
    /// rejection and before it clears that marker. Production leaves it `nil`;
    /// the cold-safety regression replaces the file with an unresolved intent
    /// in exactly the load/clear window to prove the guard re-reads the file.
    private var handoffBootIntentProbe: (@Sendable () async throws -> Void)?

    /// Creates the host. Nothing is allocated until ``start()``.
    ///
    /// - Parameters:
    ///   - configuration: Workspace root, bundle, providers and budgets.
    ///   - engineFactory: Creates the engine; defaults to the WKWebView engine
    ///     on the standard UI actor. Tests inject a deterministic engine.
    ///   - handoffTransport: TLS transport of the D15 remote endpoints;
    ///     defaults to ``URLSessionHandoffTransport``. Tests inject the
    ///     in-process remote simulator through this seam.
    ///   - reclaimTokenStore: App secure vault for the 128-bit reclaim token.
    ///     It is stored outside the workspace/WAL/log. The default is
    ///     process-lifetime only; inject the Keychain (or another
    ///     `ThisDeviceOnly` vault) to reclaim after a process death.
    public init(configuration: PhoneDSHConfiguration,
                engineFactory: PhoneDSHEngineFactory? = nil,
                handoffTransport: (any HandoffHTTPTransport)? = nil,
                reclaimTokenStore: (any HandoffReclaimTokenStore)? = nil) {
        self.configuration = configuration
        self.engineFactory = engineFactory ?? PhoneDSHHost.defaultEngineFactory
        self.handoffTransport = handoffTransport
        self.reclaimTokenStore = reclaimTokenStore
            ?? InMemoryHandoffReclaimTokenStore()
        self.eventBus = PhoneDSHEventBus()
        self.bootID = PhoneDSHBootID.make()
        self.inactivityLedger = PhoneDSHTurnInactivityLedger(
            timeout: configuration.turnInactivityTimeout)
    }

    // MARK: - Events

    /// Creates a new independent subscription to the ordered event sequence.
    public nonisolated func eventStream() -> AsyncStream<PhoneDSHEvent> {
        eventBus.stream()
    }

    // MARK: - Lifecycle

    /// Opens the workspace, recovers the WAL, boots the Worker and opens
    /// admission (D14 `Recovering -> Running`). Idempotent while starting or
    /// running. A parked host is resumed instead of rebuilt. A host restored in
    /// `Backoff` starts only after its D24 retry deadline and throws
    /// ``PhoneDSHError/backoffNotElapsed(_:)`` before it, leaving the persisted
    /// state untouched.
    ///
    /// A failure no longer refuses the next start: a persisted `failed` maps
    /// into its retry window, and a transient boot failure leaves the live
    /// controller in `Backoff` (see ``startWithoutGate()``). Only a `Failed`
    /// controller from an earlier incarnation is rebuilt from disk.
    public func start() async throws {
        // The public contract keeps start() idempotent while a boot is in
        // progress. The in-flight call owns the gate; a second start returns
        // instead of turning that documented idempotence into invalidState.
        if exclusiveOperation == .start {
            return
        }
        try beginExclusiveOperation(.start)
        defer { endExclusiveOperation(.start) }
        try await startWithoutGate()
    }

    private func startWithoutGate() async throws {
        installProcessLifecycleObservation()
        if state == .remote || remoteHandoff != nil {
            throw PhoneDSHError.invalidState(
                "reclaim the remote workspace before starting locally")
        }
        if let runtime, await hasRemoteAuthority(runtime) {
            throw PhoneDSHError.invalidState(
                "reclaim the remote workspace before starting locally")
        }
        if let runtime, await runtime.machine.currentState() == .parked {
            try await resumeWithoutGate()
            return
        }
        // A failure is a retryable state, not a dead end. A persisted `failed`
        // now boots into its retry window (Backoff until `next_retry_at_ms`,
        // Recovering after it), and a transient boot failure leaves the live
        // controller in `Backoff`. `start()` used to refuse both up front;
        // that refusal is exactly what made one bad handshake permanent (the
        // App had no path back without `userReset()`).
        if let runtime {
            let controller = await runtime.machine.currentState()
            if state == .failed {
                // The controller's `Failed` is absorbing for its own
                // incarnation, so rebuild it from `host-state.json`: the
                // persisted retry window (not this facade) decides whether the
                // boot may proceed. `prepareMachineForBoot` throws
                // `backoffNotElapsed` while the window is still closed, and
                // `beginStart` preserves the state instead of failing.
                await releaseFailedRuntime(runtime)
                setState(.stopped)
                try await beginStart()
                return
            }
            if state == .starting, controller == .backoff {
                try await resumeFromFailedBoot(runtime)
                return
            }
        } else if state == .failed {
            // No live services: `beginStart` builds the controller from disk,
            // so the same persisted retry window applies.
            setState(.stopped)
            try await beginStart()
            return
        }
        if state == .starting || state == .running { return }
        if state == .draining {
            throw PhoneDSHError.invalidState("wait for park() or resume() to finish draining")
        }
        try await beginStart()
    }

    /// Drains in-flight work, closes an epoch, parks the Worker and stops the
    /// loopback listener. The workspace services stay alive for ``resume()``.
    ///
    /// The order is the D18 invariant: the drain waits for in-flight API
    /// exchanges and write-direction sink/journal frames, closes an aborting
    /// tool call at the tool-call level (G2-FIX-84: terminal tool result, D13
    /// step `journaled`), the controller closes an epoch, and only after the
    /// loopback is gone (no frame can open another epoch) does the host seal
    /// the WAL tail and record `fence.wal_seq` at it.
    /// A seal failure is fail loud: parking never hides a fence below the
    /// on-disk WAL tail.
    ///
    /// A background park drains gracefully: an in-flight turn/tool keeps
    /// running through the drain window so its writes reach the WAL (the
    /// scenario `park_resume` contract), and the turn is cancelled only when
    /// the window narrows to the cancellation reserve. ``stop()`` marks the
    /// park as a teardown before calling this method so the Worker tool layer
    /// is also cancelled immediately (see ``sendDrainLifecycle``).
    public func park() async throws {
        try beginExclusiveOperation(.park)
        defer { endExclusiveOperation(.park) }
        try await parkWithoutGate()
    }

    private func parkWithoutGate() async throws {
        guard let runtime else {
            setState(.stopped)
            return
        }
        // A deliberate park replaces any deferred termination recovery: the
        // foreground return resumes the parked host instead of booting a
        // replacement Worker.
        pendingRecovery = false
        guard state != .stopped else { return }
        guard !restarting else {
            throw PhoneDSHError.invalidState("a planned restart is already draining")
        }
        let controller = await runtime.machine.currentState()
        guard controller != .remote, controller != .reclaiming else {
            throw PhoneDSHError.invalidState(
                "reclaim the remote workspace before parking locally")
        }
        parking = true
        setState(.draining)
        beginDescendantDrainWindow()
        do {
            switch await runtime.machine.currentState() {
            case .running:
                _ = try await runtime.machine.handle(.scenePhase(.background))
                // G2-FIX-9: once admission is closed no new turn can start,
                // so this is the one place every abort reason (wall budget,
                // request budget, user cancel, background drain) funnels
                // through before the Worker is torn down.
                //
                // G2-FIX-Q3 ordering: the D14 drain window is there to let
                // in-flight work finish, not to abort it on entry. A graceful
                // park waits for the turn handled by the running Worker page
                // (and its D13 tool step) to settle, so the command's writes
                // are durable when that page is replaced. What is still open
                // when the cancellation reserve is reached is cancelled by
                // `abortOpenSessionTurns` below. A teardown has no such
                // obligation and cancels immediately so a hung command cannot
                // hold the window.
                if stopping {
                    await sendDrainLifecycle(runtime)
                } else {
                    await drainDescendantsBeforeGracefulPark(runtime)
                    await drainOpenTurnsGracefullyBeforePark(runtime)
                }
                try await abortOpenSessionTurns(runtime)
                try await drainInFlightWork(runtime)
            case .draining:
                if stopping {
                    await sendDrainLifecycle(runtime)
                } else {
                    await drainDescendantsBeforeGracefulPark(runtime)
                    await drainOpenTurnsGracefullyBeforePark(runtime)
                }
                try await abortOpenSessionTurns(runtime)
                try await drainInFlightWork(runtime)
            case .parked:
                break
            default:
                // D14 has no edge from Recovering/Backoff/... to Parked; the
                // teardown below still seals the WAL tail so the fence can
                // never lag the on-disk log after a park.
                break
            }
            if let probe = drainWindowProbe {
                try await probe(runtime.log)
            }
            try await closeRuntimeForPark(runtime)
        } catch {
            await failClassifying(error, context: "park")
            throw error
        }
    }

    // MARK: - Testing seams

    /// Installs the drain-window probe used by the G2-FIX-17 regression tests.
    ///
    /// Internal, not App API: only `@testable` tests can inject work between
    /// the controller's drain epoch close and the loopback teardown. Production
    /// leaves the probe `nil`, so parking behaves exactly as documented.
    internal func setDrainWindowProbeForTesting(
        _ probe: (@Sendable (WorkspaceLog) async throws -> Void)?) {
        drainWindowProbe = probe
    }

    internal func setFailureSealProbeForTesting(
        _ probe: (@Sendable () async throws -> Void)?) {
        failureSealProbeForTesting = probe
    }

    /// Installs the pre-suspension handoff probe used by the facade
    /// concurrency regression. Internal, not App API.
    internal func setHandoffPreparationProbeForTesting(
        _ probe: (@Sendable () async throws -> Void)?) {
        handoffPreparationProbe = probe
    }

    /// Installs the pre-boot intent probe used by the load/clear concurrency
    /// regression. Internal, not App API.
    internal func setHandoffBootIntentProbeForTesting(
        _ probe: (@Sendable () async throws -> Void)?) {
        handoffBootIntentProbe = probe
    }

    /// Holds one accepted write-direction frame in flight. Internal, not App
    /// API: the handoff quiescence regression uses it to prove the facade never
    /// sends the fence CAS while the old Worker tail is still unsettled.
    internal func holdInboundWriteForTesting() async -> Bool {
        guard let runtime else { return false }
        await runtime.coordinator.inboundWriteStarted()
        return true
    }

    /// Releases the frame started by ``holdInboundWriteForTesting()``.
    internal func releaseInboundWriteForTesting() async {
        await runtime?.coordinator.inboundWriteFinished()
    }

    /// Internal observation point for the host replay-window regression.
    ///
    /// Production owns the window through the controller-state observer; the
    /// App never needs to read it directly. Tests use this to prove that the
    /// Recovering/Running edges actually moved the gateway window.
    internal func replayWindowIsOpenForTesting() -> Bool {
        runtime?.gateway.isReplayWindowOpen() ?? false
    }

    /// Boots a parked host again (`Parked -> Recovering -> Running`). Admission
    /// stays closed until the Worker HELLO and the lease are verified.
    ///
    /// A boot that failed transiently leaves the live controller in `Backoff`;
    /// a foreground `resume()` is the natural retry request for it, so it goes
    /// through the same D24 deadline as a persisted Backoff instead of
    /// refusing. Every other non-parked controller is still refused.
    public func resume() async throws {
        try beginExclusiveOperation(.resume)
        defer { endExclusiveOperation(.resume) }
        try await resumeWithoutGate()
    }

    private func resumeWithoutGate() async throws {
        guard let runtime else { throw PhoneDSHError.notStarted }
        if state == .running { return }
        if await hasRemoteAuthority(runtime) {
            throw PhoneDSHError.invalidState(
                "reclaim the remote workspace before resuming locally")
        }
        let controller = await runtime.machine.currentState()
        if controller == .backoff {
            try await resumeFromFailedBoot(runtime)
            return
        }
        // A cancelled resume leaves the controller in `Recovering`. D14 has no
        // `Recovering -> Parked` edge, and there is no reason to invent one:
        // the next foreground call continues the same boot from the same
        // controller state. Every other non-parked state is still refused.
        let continuesInterruptedBoot = controller == .recovering
            && state == .stopped && resumeInterrupted
        guard controller == .parked || continuesInterruptedBoot else {
            throw PhoneDSHError.invalidState("resume requires a parked controller")
        }
        resumeInterrupted = false
        setState(.starting)
        let timing = PhoneDSHResumeTiming()
        activeResumeTiming = timing
        activeResumePhase = nil
        activeResumeNote = nil
        activeResumeActiveStart = foregroundClock.activeMilliseconds()
        let cancellation = PhoneDSHResumeCancellation()
        activeResumeCancellation = cancellation
        var outcome = "failed"
        defer {
            if activeResumeCancellation === cancellation {
                activeResumeCancellation = nil
            }
            // `markResumePhase` updates `activeResumeTiming`, not the local
            // initial value; read it back for the line.
            let finalTiming = activeResumeTiming ?? timing
            writeResumeTiming(finalTiming.line(outcome: outcome,
                                               stoppedAt: activeResumePhase,
                                               note: activeResumeNote))
            activeResumeTiming = nil
            activeResumePhase = nil
            activeResumeNote = nil
            activeResumeEngine = nil
        }
        do {
            beginResumePhase("preflight")
            try cancellation.throwIfCancelled()
            if continuesInterruptedBoot == false {
                _ = try await runtime.machine.handle(.scenePhase(.active))
            }
            // A parked host kept this runtime and its one gateway URLSession.
            // Give the resumed Worker a fresh, prewarmed connection pool so a
            // dead HTTP/2 connection cannot hold `host.start()` for the whole
            // upstream timeout. The gateway is not shut down.
            await runtime.gateway.rebuildSessionForResume()
            try await bootRuntime(runtime, resume: ResumeBootPlan(
                bootReadyTimeout: configuration.resumeBootReadyTimeout,
                helloTimeout: configuration.resumeHelloTimeout,
                visibilityTimeout: configuration.resumeVisibilityTimeout),
                cancellation: cancellation)
            outcome = "ok"
        } catch {
            if cancellation.isCancelled || Self.isResumeCancelled(error) {
                outcome = "cancelled"
                resumeInterrupted = true
                // Release the half-booted page and close its channel before
                // the next foreground attempt. The controller stays in
                // `Recovering`; the App's next resume continues it.
                activeResumeEngine = nil
                await runtime.coordinator.prepareForReboot()
                if let engine = self.runtime?.engine {
                    await shutdownEngineBestEffort(engine)
                    if var services = self.runtime {
                        services.engine = nil
                        self.runtime = services
                    }
                }
                setState(.stopped)
                throw PhoneDSHError.resumeCancelled
            }
            if Self.isResumeTimeout(error) { outcome = "timeout" }
            await failClassifying(error, context: "resume")
            throw error
        }
    }

    private static func isResumeCancelled(_ error: Error) -> Bool {
        if let error = error as? PhoneDSHError, case .resumeCancelled = error {
            return true
        }
        return false
    }

    /// The resume-only budgets. A cold start deliberately keeps the App's
    /// larger `engine.bootTimeout`/`helloTimeout`: device evidence shows every
    /// cold start completes in 1–2 s, and the long ceiling only ever mattered
    /// on the stuck resume path.
    private struct ResumeBootPlan {
        let bootReadyTimeout: TimeInterval
        let helloTimeout: TimeInterval
        let visibilityTimeout: TimeInterval
    }

    private func markResumePhase(_ name: String,
                                 milliseconds: Double? = nil) {
        activeResumePhase = name
        guard var timing = activeResumeTiming else { return }
        if let milliseconds {
            timing.mark(name, milliseconds: milliseconds)
        } else {
            // Foreground-only: a background interval between two phases is
            // not resume work. The line still carries the wall timestamp.
            let active = max(0, foregroundClock.activeMilliseconds()
                - activeResumeActiveStart)
            timing.mark(name, milliseconds: active)
        }
        activeResumeTiming = timing
    }

    private func beginResumePhase(_ name: String) {
        guard activeResumeTiming != nil else { return }
        activeResumePhase = name
    }

    private static func isResumeTimeout(_ error: Error) -> Bool {
        if let error = error as? PhoneDSHError, case .startTimedOut = error {
            return true
        }
        if let error = error as? WebEngineError {
            switch error {
            case .navigationTimedOut, .bootTimedOut: return true
            default: return false
            }
        }
        return false
    }

    private func writeResumeTiming(_ line: String) {
        // Same adjacency as `boot-timings.log`: the workspace root's parent is
        // the App's Documents directory on the phone.
        let url = configuration.workspaceRoot.deletingLastPathComponent()
            .appendingPathComponent("boot-timings.log")
        guard let data = line.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
    }

    // MARK: Resume visibility and teardown

    /// Waits until the engine reports both halves of the WebKit visibility
    /// precondition. The timeout is not a failure: a harness may never publish
    /// the occlusion signal, and the page must still boot there.
    private func waitForResumeVisibility(
        _ engine: any WebEngineControlling,
        timeout: TimeInterval,
        cancellation: PhoneDSHResumeCancellation? = nil
    ) async -> (waitedMilliseconds: Double, timedOut: Bool) {
        let clock = resumeVisibilityClock
        let startedAt = clock.now()
        let deadline = startedAt.addingTimeInterval(max(0, timeout))
        while true {
            if cancellation?.isCancelled == true {
                return (max(0, clock.now().timeIntervalSince(startedAt) * 1_000), true)
            }
            let beforeRefresh = clock.now()
            let remaining = deadline.timeIntervalSince(beforeRefresh)
            if remaining <= 0 {
                return (max(0, beforeRefresh.timeIntervalSince(startedAt) * 1_000), true)
            }
            // Bound the UI-actor refresh itself. On iOS it hops to the main
            // actor; a harness that synchronously waits on the main thread can
            // leave that hop queued forever, so the resume budget must expire
            // without a pumped run loop. The helper's deadline uses its own
            // Task.sleep and does not need one.
            _ = await phoneDSHResultWithinDeadline(min(remaining, 1)) {
                await engine.refreshVisibilityForResume()
            }
            let attached = engine.isAttachedWithVisibleArea
            // `nil` means the platform has no equivalent signal or the view is
            // not in a window; keep the same unknown-as-visible rule as
            // `WebEngine/isVisibleForWebKit`, but require the window when the
            // engine does publish it.
            let occlusion = engine.isWindowOcclusionVisible
            if attached, occlusion != false {
                return (max(0, clock.now().timeIntervalSince(startedAt) * 1_000), false)
            }
            let now = clock.now()
            let remainingAfterRefresh = deadline.timeIntervalSince(now)
            if remainingAfterRefresh <= 0 {
                return (max(0, now.timeIntervalSince(startedAt) * 1_000), true)
            }
            await clock.sleep(min(max(0.01, clock.pollInterval),
                                  remainingAfterRefresh))
            if cancellation?.isCancelled == true {
                return (max(0, clock.now().timeIntervalSince(startedAt) * 1_000), true)
            }
        }
    }

    /// Stops the old page/bridge before the host drops its reference.
    ///
    /// A WKWebView retained by the anchor view hierarchy keeps its WebContent
    /// process alive even after the engine object is gone. Park/resume used to
    /// replace the engine without `shutdown()`, which is consistent with the
    /// eight `com.apple.WebKit.WebContent` processes seen on the device.
    private func shutdownEngineBestEffort(
        _ engine: (any WebEngineControlling)?,
        terminate: Bool = false,
        budget: TimeInterval = 2
    ) async {
        guard let engine else { return }
        _ = await phoneDSHResultWithinDeadline(budget) {
            if terminate, let terminator = engine as? any WebEngineWorkerTerminating {
                try? await terminator.terminateWorker()
            }
            if let stopper = engine as? any WebEngineShutdownRequesting {
                try? await stopper.shutdownWorker()
            }
        }
    }

    internal func setResumeVisibilityClockForTesting(
        _ clock: PhoneDSHResumeVisibilityClock
    ) {
        resumeVisibilityClock = clock
    }


    /// D24 planned restart: the D14 `Running -> Recovering -> Running` edge.
    ///
    /// 1. admission closes immediately (side effects stop entering the host);
    /// 2. in-flight `0x40 API_REQ` exchanges get the 20 s drain window to
    ///    finish; a request still open at the deadline is cancelled by the
    ///    controller's drain signal and re-issued by its initiator on the next
    ///    connection (D2);
    /// 3. the controller closes the WAL epoch (`Running -> Recovering`);
    /// 4. the overlay is rebuilt and the Worker is reloaded;
    /// 5. the host waits for HELLO and gives the replacement Worker the same
    ///    bounded DSH write-open reconcile as an abnormal termination, so a
    ///    step interrupted by a page/Worker kill cannot stay at
    ///    `tool_dispatched`;
    /// 6. the host verifies the lease and only then reopens admission
    ///    (`Recovering -> Running`).
    ///
    /// `park()` / `resume()` remain the background path and are unchanged.
    public func plannedRestart(reason: String) async throws {
        try beginExclusiveOperation(.restart)
        defer { endExclusiveOperation(.restart) }
        guard let runtime else { throw PhoneDSHError.notStarted }
        guard state == .running else {
            throw PhoneDSHError.invalidState("plannedRestart requires a running host")
        }
        guard await runtime.machine.currentState() == .running else {
            throw PhoneDSHError.invalidState("plannedRestart requires a running controller")
        }
        restarting = true
        defer { restarting = false }
        // A deliberate restart replaces any deferred termination recovery: its
        // own replacement Worker serves the same purpose.
        pendingRecovery = false
        // Close admission before the drain: once this returns no new side
        // effect can enter the host, while the in-flight responses may still
        // complete on the existing connection.
        runtime.machine.admission.set(.closed)
        setState(.draining)
        do {
            let timeout = max(0, configuration.drainDeadline)
            let idle = await runtime.coordinator.waitForDrainQuiescence(timeout: timeout)
            if !idle {
                // The controller deadline aborts the wait; the Worker's
                // response stream ends when the connection is rebuilt below.
                runtime.machine.drainCancellation.cancel()
            }
            if await runtime.machine.currentState() == .running {
                do {
                    _ = try await runtime.machine.handle(.plannedRestart)
                } catch {
                    // A concurrent WebContent termination may already have
                    // taken the Running -> Recovering edge; that is the same
                    // recovery this restart needs.
                    if await runtime.machine.currentState() != .recovering {
                        throw error
                    }
                }
            }
            guard await runtime.machine.currentState() == .recovering else {
                throw PhoneDSHError.invalidState(
                    "the controller did not enter Recovering for the planned restart")
            }
            // The controller closed the epoch while the old Worker channel was
            // still connected. A sink frame that slipped into the close window
            // opened a new epoch; seal it too, so the overlay and the fence are
            // built at the same durable WAL tail.
            try await sealEpochAfterControllerClose(runtime)
            setState(.starting)
            // D24 step 4: rebuild the overlay (gzip, D21) and the Worker. A
            // `.boot`-class failure retries with a fresh channel barrier, a
            // fresh page and a fresh Worker (see
            // ``bootReplacementWorker(_:reason:orphanReason:incarnationCutoffAfterBoot:publishReportImmediately:)``);
            // only an exhausted retry budget reaches `fail(_:)`.
            let report = try await bootReplacementWorker(
                runtime,
                reason: .planned,
                orphanReason: "planned-restart",
                // G2-F01 epoch ordering: the old Worker channel was still
                // connected through the seal above and can write a child
                // journal in that shutdown window. Only after the replacement
                // Worker has actually booted is no child Activation from the
                // old Worker resident. Moving the cutoff there keeps a child
                // spawned during the shutdown window stale (its journal
                // predates that instant), while a child the replacement Worker
                // creates later remains current. Clearing the route-reported
                // live set here also prevents an old Worker's late child from
                // being mistaken for a replacement-Worker descendant.
                incarnationCutoffAfterBoot: true,
                publishReportImmediately: false)
            setState(.running)
            if let report {
                publishRestart(report)
            }
            await evaluateBudget(runtime)
        } catch {
            // A planned restart that fails before the replacement Worker can
            // prove the outcome (engine restart, HELLO timeout, lease check)
            // must still not leave a step at `tool_dispatched`: this host is
            // about to enter Failed, and reset()/bootRuntime never revisit the
            // orphan reconcile. Best-effort settle the still-open records
            // before failing loud; the restart error remains the reported one
            // and admission is never reopened.
            do {
                let settled = try await runtime.stepMachine.settleOrphans(
                    reason: "planned-restart")
                publishOrphanSettlement(settled, reason: "planned-restart")
            } catch {
                // The restart failure below is the actionable error.
            }
            await failClassifying(error, context: "planned restart")
            throw error
        }
    }

    /// D15 handoff: `Running -> HandingOff -> Remote`.
    ///
    /// The coordinator closes admission and the epoch, runs the fence CAS and
    /// the snapshot/segments upload, and installs the remote authority. On
    /// success this facade stops the local Worker/loopback (the phone no longer
    /// owns execution) and reports `.remote`. It deliberately keeps the live
    /// workspace services and the coordinator so ``reclaim()`` can apply the
    /// return segments with the same injected token store.
    ///
    /// A failure before the fence CAS is fail loud (`Failed`, local authority
    /// unchanged). A failure after the CAS leaves the controller in
    /// `Reclaiming` with the remote token retained; the caller must call
    /// ``reclaim()`` to bring authority home.
    public func beginHandoff() async throws -> HandoffCompletion {
        guard !handoffOperationInFlight else {
            throw PhoneDSHError.invalidState("another handoff operation is in flight")
        }
        try beginExclusiveOperation(.handoff)
        defer { endExclusiveOperation(.handoff) }
        try Task.checkCancellation()
        guard let runtime else { throw PhoneDSHError.notStarted }
        guard let coordinator = runtime.handoff else {
            throw PhoneDSHError.unsupported("no remote handoff endpoint is configured")
        }
        guard state == .running,
              await runtime.machine.currentState() == .running,
              await coordinator.phase == .idle else {
            throw PhoneDSHError.invalidState("handoff requires a running local host")
        }
        // A handoff owns the Worker from here; a deferred termination recovery
        // would only compete with its drain.
        pendingRecovery = false
        do {
            if let handoffPreparationProbe {
                try await handoffPreparationProbe()
            }
            // Stop the only mutation source *before* the coordinator closes the
            // epoch and snapshots. The state machine closes admission at
            // `handoffRequested`, but VFS_MUT frames are not admission-gated on
            // an already-connected channel; removing the loopback first makes
            // the source's `(base, wal_seq]` check race-free.
            try await suspendRuntimeForRemote(runtime)
            // A caller cancellation that arrived while the Worker was being
            // stopped must not continue into the irreversible CAS. The stop
            // helper propagates cancellation into its operation; this explicit
            // check covers a stop that completed at the same instant.
            try Task.checkCancellation()
            let completion = try await coordinator.beginHandoff()
            // The remote now owns generation + 1. Keep the controller/remote
            // coordinator alive for reclaim, but no local side effect may run.
            setState(.remote)
            _ = await diagnostics()
            setState(.remote)
            return completion
        } catch {
            let phase = await coordinator.phase
            let controller = await coordinator.controllerState()
            let fence = await runtime.authority.current
            let remoteOwnsAuthority = phase == .reclaiming
                || phase == .remote
                || controller == .reclaiming
                || controller == .remote
                || fence.owner != HandoffLimits.phoneOwner
            if remoteOwnsAuthority {
                // The fence CAS succeeded, so the remote owns the workspace.
                // The local Worker is already stopped; keep the token and the
                // coordinator so reclaim() can finish the return path. This
                // must not depend on the controller alone: a local fence write
                // that failed after the CAS leaves the persisted owner at
                // `phone`, but the remote already holds generation + 1.
                setState(.starting)
            } else {
                // Before the CAS the coordinator fails the controller. Any
                // unexpected refusal still fails loud instead of leaving a
                // running controller without its local Worker.
                await failClassifying(error, context: "handoff",
                                      shutdownEngine: false)
            }
            throw error
        }
    }

    /// D15 reclaim: `Remote -> Reclaiming -> Recovering -> Running`.
    ///
    /// Applies the segments returned by the remote, installs the new phone
    /// fence, then rebuilds the runtime from the recovered workspace and boots
    /// the local Worker. Admission stays closed through `Recovering` and is
    /// reopened only by the lease check in the rebuild. The operation is
    /// serialized with ``beginHandoff()`` and can be retried after a transport
    /// failure because the remote caches the response per token.
    public func reclaim() async throws -> HandoffReclaimOutcome {
        try await performReclaim(explicitCredential: nil)
    }

    /// Reclaims with the complete credential the App recovered from its own
    /// secure vault.
    ///
    /// This is the safe cold-recovery entry: it works on a fresh
    /// ``PhoneDSHHost`` (no same-object state) and checks the credential's
    /// non-secret endpoint, workspace identifier and remote fence against this
    /// host's persisted authority *before* any request or segment apply. The
    /// remote's `200` is then the proof that the CAS took effect. The token is
    /// never accepted from a URL, workspace file or log.
    public func reclaim(using credential: HandoffReclaimToken) async throws
        -> HandoffReclaimOutcome {
        try await performReclaim(explicitCredential: credential)
    }

    /// Reclaims with a bare token that must already be bound to this workspace
    /// in the injected secure store.
    ///
    /// A bare string has no workspace/endpoint binding, so it cannot be safely
    /// applied to a workspace without trusting the caller's memory. This
    /// overload therefore accepts it only when the App's vault already holds
    /// the exact credential; otherwise callers must use
    /// ``reclaim(using:)`` with the saved ``HandoffReclaimToken``. Both
    /// entries use the same full cold path.
    public func reclaim(usingRemoteToken token: String) async throws
        -> HandoffReclaimOutcome {
        guard HandoffHex.isLowercaseHex(token, count: 32) else {
            throw HandoffError.unauthorized
        }
        let stored: HandoffReclaimToken?
        do {
            stored = try await reclaimTokenStore.load()
        } catch let error as HandoffError {
            throw error
        } catch {
            throw HandoffError.reclaimTokenStoreFailed(
                "cannot load the reclaim credential from the App vault")
        }
        guard let stored, stored.token == token else {
            throw HandoffError.manualReclaimRequired(
                "a bare reclaim token carries no workspace or endpoint binding; "
                    + "use reclaim(using:) with the complete saved credential")
        }
        return try await performReclaim(explicitCredential: stored)
    }

    private func performReclaim(explicitCredential: HandoffReclaimToken?) async throws
        -> HandoffReclaimOutcome {
        guard !handoffOperationInFlight else {
            throw PhoneDSHError.invalidState("another handoff operation is in flight")
        }
        try beginExclusiveOperation(.reclaim)
        defer { endExclusiveOperation(.reclaim) }
        try Task.checkCancellation()
        let credential: HandoffReclaimToken?
        if let explicitCredential {
            credential = try await makeExplicitReclaimCredential(explicitCredential)
        } else {
            credential = nil
        }
        let coldStart = runtime == nil && remoteHandoff == nil
        let outcome: HandoffReclaimOutcome
        do {
            outcome = try await reclaimRemoteWorkspace(credential: credential)
        } catch {
            if coldStart { await failClassifying(error, context: "cold reclaim") }
            throw error
        }
        // The applier rewrote the manifest/WAL while the old runtime was
        // quiesced. Rebuild every service from disk so the next Worker HELLO
        // sees the reclaimed positions and the new phone fence.
        try await beginStart()
        return outcome
    }

    /// Validates and binds an App-supplied credential before any network
    /// request. The workspace/endpoint checks are on the *supplied* values,
    /// never overwritten with this host's own values. The generation is
    /// derived from the persisted fence plus the pre-CAS intent (never
    /// guessed) and is recorded only after the remote's `200` proves it.
    private func makeExplicitReclaimCredential(
        _ supplied: HandoffReclaimToken) async throws -> HandoffReclaimToken {
        guard HandoffHex.isLowercaseHex(supplied.token, count: 32) else {
            throw HandoffError.unauthorized
        }
        guard let handoffConfiguration = configuration.handoff else {
            throw PhoneDSHError.unsupported("handoff was not configured for this host")
        }
        let expectedEndpoint = try handoffConfiguration.endpointIdentity()
        let expectedWorkspace = HandoffReclaimToken.workspaceIdentifier(
            for: configuration.workspaceRoot)
        guard supplied.endpoint == expectedEndpoint else {
            throw HandoffError.manualReclaimRequired(
                "the saved reclaim token belongs to another remote endpoint")
        }
        guard supplied.workspaceIdentifier == expectedWorkspace else {
            throw HandoffError.manualReclaimRequired(
                "the saved reclaim token belongs to another workspace")
        }
        guard let suppliedRemoteFence = supplied.remoteFence else {
            throw HandoffError.manualReclaimRequired(
                "the saved reclaim credential has no verified remote fence evidence")
        }
        let authority: FenceAuthority
        if let runtime {
            authority = runtime.authority
        } else {
            do {
                authority = try FenceAuthority(root: configuration.workspaceRoot,
                                               owner: HandoffLimits.phoneOwner,
                                               walSeq: 0)
            } catch {
                throw PhoneDSHError.invalidState(
                    "cannot open the persisted authority for reclaim: \(error)")
            }
        }
        let current = await authority.current.wireFence
        let recordedIntent = await authority.handoffAuthorityIntent
        // A definite-rejection marker is not an unresolved CAS; it carries no
        // remote authority and must not be used to guess a remote fence.
        let intent = recordedIntent?.isDefiniteRejection == true
            ? nil : recordedIntent
        let evidence: Fence
        if current.owner == HandoffLimits.remoteOwner {
            evidence = current
        } else if let intent {
            if intent.expectedGeneration == current.generation {
                // The lost CAS response: the remote owns expected + 1.
                evidence = Fence(owner: HandoffLimits.remoteOwner,
                                 generation: intent.expectedGeneration + 1,
                                 walSeq: intent.walSeq)
            } else if current.generation == intent.expectedGeneration + 2 {
                // The reclaimed phone fence was already written before the
                // intent/token cleanup. Its remote predecessor is
                // current.generation - 1; the cached 200 is validated by
                // ReclaimClient's already-reclaimed branch before clearing the
                // stale intent. No generation is guessed.
                evidence = Fence(owner: HandoffLimits.remoteOwner,
                                 generation: current.generation - 1,
                                 walSeq: intent.walSeq)
            } else {
                throw HandoffError.manualReclaimRequired(
                    "the pre-CAS authority evidence does not match the current fence")
            }
        } else {
            throw HandoffError.manualReclaimRequired(
                "no non-secret remote fence evidence exists for this token")
        }
        guard suppliedRemoteFence == evidence else {
            throw HandoffError.manualReclaimRequired(
                "the saved remote fence does not match the persisted authority")
        }
        return HandoffReclaimToken(
            token: supplied.token,
            remoteFence: evidence,
            endpoint: expectedEndpoint,
            workspaceIdentifier: expectedWorkspace)
    }

    /// Runs the coordinator return path against the live runtime, the context
    /// preserved by ``stop()``, or the persisted cold workspace. It returns
    /// only after the old services are released, so the caller's
    /// ``beginStart()`` cannot race an open ``WorkspaceLog`` over the applier's
    /// manifest rewrite.
    private func reclaimRemoteWorkspace(
        credential: HandoffReclaimToken?) async throws -> HandoffReclaimOutcome {
        if let runtime {
            guard let coordinator = runtime.handoff else {
                throw PhoneDSHError.unsupported("handoff was not configured for this host")
            }
            let controller = await coordinator.controllerState()
            if credential == nil {
                // `HandingOff` is allowed only so an in-process token cached
                // before a failed vault write can still reclaim; the
                // coordinator itself refuses it without a token.
                guard controller == .remote || controller == .reclaiming
                        || controller == .handingOff else {
                    throw PhoneDSHError.invalidState(
                        "reclaim requires the remote, reclaiming or uncertain handoff")
                }
            } else {
                guard controller == .handingOff || controller == .remote
                        || controller == .reclaiming else {
                    throw PhoneDSHError.invalidState(
                        "an explicit token requires a remote, reclaiming or uncertain handoff")
                }
            }
            do {
                let outcome: HandoffReclaimOutcome
                if let credential {
                    outcome = try await coordinator.reclaim(using: credential)
                } else {
                    outcome = try await coordinator.reclaim()
                }
                await releaseRuntimeAfterReclaim(runtime)
                setState(.starting)
                return outcome
            } catch {
                let current = await coordinator.controllerState()
                if current == .failed {
                    await failClassifying(error, context: "reclaim")
                } else {
                    // Stay Reclaiming: the token and the remote's cached
                    // response make another attempt idempotent.
                    setState(.starting)
                }
                throw error
            }
        }
        if let context = remoteHandoff {
            startMachineObserver(context.machine)
            do {
                let outcome: HandoffReclaimOutcome
                if let credential {
                    outcome = try await context.coordinator.reclaim(using: credential)
                } else {
                    outcome = try await context.coordinator.reclaim()
                }
                await context.machine.shutdown()
                await drainMachineObserver()
                remoteHandoff = nil
                return outcome
            } catch {
                let current = await context.coordinator.controllerState()
                if current == .failed {
                    await context.machine.shutdown()
                    await drainMachineObserver()
                    remoteHandoff = nil
                    await failClassifying(error, context: "reclaim")
                } else {
                    setState(.starting)
                }
                throw error
            }
        }
        return try await coldReclaimRemoteWorkspace(credential: credential)
    }

    /// Cold-process reclaim over the persisted workspace.
    ///
    /// A new host has no in-memory coordinator. It may proceed only with a
    /// token from the App vault (plus a persisted remote fence, or the
    /// pre-CAS intent and a token-bound remote fence). With intent but no
    /// token it returns ``HandoffError/manualReclaimRequired(_:)`` and never
    /// clears the evidence or boots the local Worker.
    private func coldReclaimRemoteWorkspace(
        credential explicit: HandoffReclaimToken?) async throws -> HandoffReclaimOutcome {
        guard let handoffConfiguration = configuration.handoff else {
            throw PhoneDSHError.unsupported("handoff was not configured for this host")
        }
        guard let bootData = PhoneDSHBootID.data(hex: bootID) else {
            throw PhoneDSHError.invalidBundle(
                "the boot id is not 32 lowercase hex characters")
        }
        let authority: FenceAuthority
        do {
            authority = try FenceAuthority(root: configuration.workspaceRoot,
                                           owner: HandoffLimits.phoneOwner,
                                           walSeq: 0)
        } catch {
            throw PhoneDSHError.invalidState(
                "cannot open the persisted authority for reclaim: \(error)")
        }
        let current = await authority.current.wireFence
        let recordedIntent = await authority.handoffAuthorityIntent
        let intent = recordedIntent?.isDefiniteRejection == true
            ? nil : recordedIntent
        let endpoint = try handoffConfiguration.endpointIdentity()
        let stored: HandoffReclaimToken?
        if let explicit {
            stored = explicit
        } else {
            do {
                stored = try await reclaimTokenStore.load()
            } catch let error as HandoffError {
                throw error
            } catch {
                throw HandoffError.reclaimTokenStoreFailed(
                    "cannot load the reclaim credential from the App vault")
            }
        }
        if let intent, intent.endpoint != endpoint {
            throw HandoffError.manualReclaimRequired(
                "the unresolved handoff belongs to another remote endpoint")
        }
        if current.owner == HandoffLimits.phoneOwner {
            guard let intent else {
                throw PhoneDSHError.invalidState(
                    "there is no remote workspace to reclaim")
            }
            guard let stored else {
                throw HandoffError.manualReclaimRequired(
                    "the generation CAS is unresolved; provide the reclaim token "
                        + "from the App secure vault")
            }
            guard let remoteFence = stored.remoteFence else {
                throw HandoffError.manualReclaimRequired(
                    "the saved token has no verified remote fence evidence")
            }
            guard remoteFence.owner == HandoffLimits.remoteOwner,
                  remoteFence.generation == intent.expectedGeneration + 1 else {
                throw HandoffError.manualReclaimRequired(
                    "the saved remote fence does not match the pre-CAS evidence")
            }
            if current.generation == remoteFence.generation + 1 {
                // The reclaim already installed the phone generation, but the
                // process died before the stale intent/token cleanup finished.
                // The remote may have appended mutations after the CAS, so the
                // installed phone wal_seq can legitimately be *ahead* of the
                // remote fence captured in the vault. The cached reclaim 200
                // and its metadata are the authority for that advance;
                // ReclaimClient validates them before clearing the intent.
                guard current.walSeq >= remoteFence.walSeq else {
                    throw HandoffError.manualReclaimRequired(
                        "the installed phone fence falls behind the saved remote fence")
                }
            } else {
                // Still before the reclaimed fence is installed: the remote's
                // CAS fence must not lower the local WAL position.
                guard remoteFence.walSeq >= current.walSeq else {
                    throw HandoffError.manualReclaimRequired(
                        "the saved remote fence precedes the local WAL")
                }
            }
        } else if current.owner == HandoffLimits.remoteOwner {
            guard let stored else {
                throw HandoffError.manualReclaimRequired(
                    "the remote owns the workspace but no reclaim token is "
                        + "available; manual recovery is required")
            }
            if let remoteFence = stored.remoteFence, remoteFence != current {
                throw HandoffError.manualReclaimRequired(
                    "the saved remote fence differs from the persisted authority")
            }
        } else {
            throw PhoneDSHError.invalidState(
                "the persisted authority is not a handoff authority")
        }
        guard let stored else {
            throw PhoneDSHError.invalidState(
                "there is no remote workspace to reclaim")
        }
        guard stored.workspaceIdentifier
                == HandoffReclaimToken.workspaceIdentifier(
                    for: configuration.workspaceRoot) else {
            throw HandoffError.manualReclaimRequired(
                "the stored reclaim token belongs to another workspace")
        }

        let machine: HostStateMachine
        do {
            machine = try HostStateMachine(
                root: configuration.workspaceRoot,
                epochCloser: nil,
                leaseVerifier: nil,
                drainDeadlineSeconds: configuration.drainDeadline,
                workspaceHasState: true)
        } catch {
            throw PhoneDSHError.invalidState(
                "cannot open the persisted controller for reclaim: \(error)")
        }
        let client: HandoffClient
        let applier: WorkspaceLogSegmentApplier
        do {
            client = try HandoffClient(
                configuration: handoffConfiguration,
                transport: handoffTransport ?? URLSessionHandoffTransport(),
                credentialProvider: configuration.credentialProvider)
            applier = try WorkspaceLogSegmentApplier(
                root: configuration.workspaceRoot,
                configuration: configuration.log,
                bootID: bootData)
        } catch let error as HandoffError {
            await machine.shutdown()
            throw error
        } catch {
            await machine.shutdown()
            throw PhoneDSHError.invalidConfiguration(
                "the reclaim client could not be created: \(error)")
        }
        let reclaimClient = ReclaimClient(
            client: client,
            applier: applier,
            fences: FenceAuthorityHandoffStore(authority: authority),
            tokenStore: reclaimTokenStore)
        startMachineObserver(machine)
        do {
            // Persist a bootable recovery state *before* the token is consumed
            // or the reclaimed fence is written. The persisted controller may
            // still be `Remote` (a reclaim interrupted before the completion
            // edge) or `Failed` (a persisted `HandingOff`, i.e. a lost CAS
            // response or an interrupted handoff, maps to `Failed` at boot).
            // In both cases a crash after the reclaimed fence is installed but
            // before the completion edges would leave the next start looking
            // at a persisted `Failed` controller and refuse it forever. The
            // local authority evidence was validated above, so this transition
            // cannot open admission: the unmarked intent or the persisted
            // remote fence still keeps `beginStart()` closed if the reclaim
            // later fails.
            switch await machine.currentState() {
            case .remote:
                _ = try await machine.handle(.reclaimRequested)
            case .failed:
                _ = try await machine.handle(.userReset)
            default:
                // `.recovering` (persisted Reclaiming/HandingOff) is already
                // the safe boot state; beginStart() will verify the lease.
                break
            }
            let outcome: HandoffReclaimOutcome
            if let explicit {
                outcome = try await reclaimClient.reclaim(using: explicit)
            } else {
                outcome = try await reclaimClient.reclaimStoredToken()
            }
            switch await machine.currentState() {
            case .reclaiming:
                _ = try await machine.handle(.reclaimResponseApplied)
                _ = try await machine.handle(
                    .reclaimCompleted(fencePersisted: true,
                                      epochClosed: outcome.epochClosed))
            default:
                // The pre-consumption transition already left a persisted
                // `Recovering` (or another bootable state); beginStart() will
                // verify the lease.
                break
            }
            await machine.shutdown()
            await drainMachineObserver()
            setState(.starting)
            return outcome
        } catch {
            await machine.shutdown()
            await drainMachineObserver()
            throw error
        }
    }

    /// Stops the local Worker-facing services but keeps the controller and the
    /// handoff coordinator alive for the D15 return path.
    ///
    /// The real page/Worker is destroyed first (`about:blank` navigation), then
    /// the engine bridge is shut down. Both hooks are required and run inside
    /// one fixed bound; a missing hook or a failed/timed-out stop may not fall
    /// through to `engine = nil`. Only a confirmed stop closes the loopback and
    /// lets the accepted inbound tail converge before the caller sends the
    /// fence. A caller cancellation propagates into the stop operation and is
    /// checked again before the CAS.
    private func suspendRuntimeForRemote(_ runtime: RuntimeServices) async throws {
        engineObserver?.cancel()
        engineObserver = nil
        guard let engine = runtime.engine else {
            throw HandoffError.invalidControllerState(
                "the live engine is unavailable; refusing a handoff without a "
                    + "verified Worker stop")
        }
        // An engine with neither terminal surface cannot prove a stop at all;
        // report the dedicated error. A wrapper that exposes exactly one half
        // gets the precise controller-state diagnostic below, so the caller
        // knows which required hook is missing.
        guard engine is any WebEngineWorkerTerminating
                || engine is any WebEngineShutdownRequesting else {
            throw HandoffError.engineShutdownUnsupported
        }
        guard let terminator = engine as? any WebEngineWorkerTerminating else {
            throw HandoffError.invalidControllerState(
                "the live engine has no verified Worker termination hook")
        }
        guard let stopper = engine as? any WebEngineShutdownRequesting else {
            throw HandoffError.invalidControllerState(
                "the live engine has no verified shutdown hook")
        }
        let stopBudget = min(max(0, configuration.drainDeadline),
                             HandoffLimits.workerStopTimeout)
        let stopped = await phoneDSHResultWithinDeadline(stopBudget) {
            // Destroy the old execution context first: an about:blank
            // navigation tears down the page's DedicatedWorker and its
            // WebSocket, then the bridge is removed. `shutdown()` alone only
            // stops loading and drops the host's engine reference.
            try await terminator.terminateWorker()
            try await stopper.shutdownWorker()
        }
        switch stopped {
        case .success?:
            break
        case .failure(let error)?:
            throw error
        case nil:
            throw HandoffError.notQuiescent(
                "the live Worker did not terminate inside the bounded handoff "
                    + "stop window")
        }
        if var services = self.runtime {
            services.engine = nil
            self.runtime = services
        }
        parking = false
        await runtime.loopback.stop()
        // The engine was shut down above, but a write frame that was already
        // decoded or handed to the log may still be running. The CAS must not
        // overtake it: a late VFS mutation would otherwise land after the
        // remote fence and be lost from the replicated range. Fail loud without
        // sending the CAS instead of pretending the tail converged.
        let quiesced = await runtime.coordinator.waitForInboundWritesToQuiesce()
        guard quiesced else {
            throw HandoffError.notQuiescent(
                "accepted inbound Worker writes did not converge before the fence CAS")
        }
        await runtime.coordinator.prepareForReboot()
    }

    /// Releases the runtime after the applier installed the returned segments.
    /// No seal is attempted here: the applier already closed the reclaimed
    /// epoch, and the old in-memory log is stale by construction.
    ///
    /// The machine stream is finished before the observer is awaited so the
    /// buffered `reclaiming -> recovering` transitions are published instead of
    /// being dropped by an early cancellation.
    private func releaseRuntimeAfterReclaim(_ runtime: RuntimeServices) async {
        engineObserver?.cancel()
        engineObserver = nil
        await shutdownEngineBestEffort(runtime.engine)
        await runtime.loopback.stop()
        await runtime.machine.shutdown()
        await drainMachineObserver()
        await runtime.gateway.shutdown()
        self.runtime = nil
    }

    /// Releases the services of a failed incarnation before a cold rebuild.
    ///
    /// `fail(_:)` already closed admission, stopped the loopback and sealed the
    /// WAL; the remaining observers and the model gateway are released here so
    /// the rebuilt runtime owns the workspace alone. Called only by
    /// ``startWithoutGate()`` when a `Failed` host is asked to start again.
    private func releaseFailedRuntime(_ runtime: RuntimeServices) async {
        engineObserver?.cancel()
        engineObserver = nil
        await shutdownEngineBestEffort(runtime.engine)
        await runtime.loopback.stop()
        _ = await runtime.coordinator.waitForInboundWritesToQuiesce()
        await runtime.machine.shutdown()
        await drainMachineObserver()
        await runtime.gateway.shutdown()
        self.runtime = nil
    }

    /// Retries the boot of a host whose transient failure left the live
    /// controller in its persisted `Backoff`.
    ///
    /// The controller's own D24 deadline decides: a start before it throws
    /// ``PhoneDSHError/backoffNotElapsed(_:)`` with the persisted window (and
    /// the facade state) intact, exactly like the cold-boot path. Once the
    /// window elapsed the machine enters `Recovering` and the live services are
    /// booted again by ``bootRuntime(_:)``.
    private func resumeFromFailedBoot(_ runtime: RuntimeServices) async throws {
        do {
            do {
                _ = try await runtime.machine.resumeFromPersistedBackoff()
            } catch let error as HostStateError {
                if case .backoffDeadlineNotReached(let deadline) = error {
                    throw PhoneDSHError.backoffNotElapsed(deadline)
                }
                throw error
            }
            setState(.starting)
            try await bootRuntime(runtime, reconcileOrphans: true)
        } catch {
            if let phoneError = error as? PhoneDSHError,
               case .backoffNotElapsed = phoneError {
                // A healthy wait, not a failure: keep the persisted deadline
                // and let the App retry with start() once it elapses.
                throw error
            }
            await failClassifying(error, context: "start")
            throw error
        }
    }

    /// Finishes the transition stream and waits for its observer to consume the
    /// buffered records. Callers must `await machine.shutdown()` first.
    private func drainMachineObserver() async {
        if let observer = machineObserver {
            await observer.value
        }
        machineObserver = nil
    }

    /// Clears the fail-loud state after the user acknowledged it (D14
    /// `Failed -> Recovering`) and boots the host again.
    ///
    /// A failed host is not a dead end any more. A persisted `failed` maps into
    /// its retry window at the next boot (`Backoff` until `next_retry_at_ms`,
    /// then `Recovering`), and this explicit reset clears that window and
    /// starts a new retry budget. A host that was stopped after the failure (no
    /// runtime is left, only the remembered error) re-assembles its services
    /// from scratch; one that is still failed in memory reuses them.
    public func reset() async throws {
        try await userReset()
    }

    /// D24 name of ``reset()``: the explicit user acknowledgement of a
    /// persisted `Failed` controller. The two operations are identical.
    public func userReset() async throws {
        try beginExclusiveOperation(.reset)
        defer { endExclusiveOperation(.reset) }
        try await userResetWithoutGate()
    }

    private func userResetWithoutGate() async throws {
        // A failed host that was already stopped has no runtime left; the
        // remembered error is the only evidence of the failure, and the
        // persisted controller state is still `Failed`.
        let resettable = state == .failed || (state == .stopped && lastError != nil)
        guard resettable else {
            throw PhoneDSHError.invalidState("userReset requires a failed host")
        }
        if let runtime, await hasRemoteAuthority(runtime) {
            throw PhoneDSHError.invalidState(
                "the remote owns the workspace; call reclaim() instead of resetting locally")
        }
        lastError = nil
        lastMismatchDetail = nil
        if let runtime {
            do {
                // A failed host with live services must not bypass the
                // authority-uncertain guard that `beginStart()` applies to a
                // cold host. Resolve (or refuse) the persisted intent before
                // any controller transition can reopen the local path.
                try await resolveHandoffAuthorityIntentForBoot()
                _ = try await runtime.machine.handle(.userReset)
                try await bootRuntime(runtime)
            } catch {
                await failClassifying(error, context: "reset")
                throw error
            }
            return
        }
        setState(.stopped)
        try await beginStart(userReset: true)
    }

    /// Reboots the engine on an assembled runtime and opens admission after
    /// the Worker HELLO and the fence are verified. Shared by ``resume()`` and
    /// ``reset()``; both start from the controller's `Recovering` state.
    /// - Parameter reconcileOrphans: `true` on a retry that reopens admission
    ///   after an earlier failure. A retry must not open admission over a step
    ///   this host already gave up on (D13), so it reconciles first. A normal
    ///   boot keeps the historical behaviour: the scenario/kill contracts
    ///   expect an interrupted step to stay open until the run reconciles it.
    private func bootRuntime(_ runtime: RuntimeServices,
                             reconcileOrphans: Bool = false,
                             resume: ResumeBootPlan? = nil,
                             cancellation: PhoneDSHResumeCancellation? = nil) async throws {
        installMCPEgressCredential()
        bootPhaseRecorder.begin(bootID: bootID,
                                workspaceRoot: configuration.workspaceRoot)
        try cancellation?.throwIfCancelled()
        // `userReset()` and `resume()` reuse a live runtime, so the pre-start
        // guard in `beginStart()` alone is not enough: a persisted unresolved
        // CAS intent must also keep this path closed. A definite-rejection
        // marker is safe to clean and does not block the ordinary reset.
        try await resolveHandoffAuthorityIntentForBoot()
        if await hasRemoteAuthority(runtime) {
            throw PhoneDSHError.invalidState(
                "the remote owns the workspace; call reclaim() before booting locally")
        }
        // Resume and the user-reset runtime branch both boot a fresh Worker;
        // a child journal left open by the parked/failed Worker has no
        // resident Activation in it.
        beginWorkerIncarnation()
        beginWorkerBootID()
        await runtime.coordinator.prepareForReboot()
        await runtime.coordinator.beginWorkerBoot(
            expectedBootID: workerBootID,
            retiring: retiredWorkerBootIDs,
            sessionEpoch: sessionEpoch,
            fence: await runtime.authority.wireFence())
        try cancellation?.throwIfCancelled()
        if resume != nil { beginResumePhase("overlay") }
        // The overlay path is stable for this boot id; rewriting it picks up
        // every mutation that the parked or failed Worker acknowledged.
        _ = try await runtime.log.overlay(bootID: bootID)
        if resume != nil { markResumePhase("overlay") }
        if resume != nil { beginResumePhase("loopback") }
        let endpoint = try await runtime.loopback.start()
        if resume != nil { markResumePhase("loopback") }
        var engineConfiguration = makeEngineConfiguration(
            endpoint: endpoint, fence: await runtime.authority.wireFence())
        if let resume {
            // The resume budget reaches the engine, so even a page that never
            // reports boot-ready is bounded inside WebEngine itself. The cold
            // path keeps the App's larger timeout unchanged.
            engineConfiguration.bootTimeout = resume.bootReadyTimeout
        }
        if resume != nil { beginResumePhase("webview") }
        // A failed boot leaves the previous engine installed in `runtime`.
        // Never build a second WKWebView on top of it: the old page would keep
        // its WebContent process alive and the new one would load beside it.
        if let existing = self.runtime?.engine {
            await shutdownEngineBestEffort(existing)
            if var services = self.runtime {
                services.engine = nil
                self.runtime = services
            }
        }
        let engine = try await engineFactory(engineConfiguration)
        lockdownModeObserved = engine.isLockdownModeEnabled
        if var services = self.runtime {
            services.engine = engine
            services.engineConfiguration = engineConfiguration
            self.runtime = services
        }
        if resume != nil { activeResumeEngine = engine }
        startEngineObserver(engine)
        if resume == nil {
            try checkEngine(engine)
        } else if engine.isLockdownModeEnabled {
            throw PhoneDSHError.lockdownMode
        }
        if resume != nil { markResumePhase("webview") }
        if let resume {
            beginResumePhase("visible")
            let visibility = await waitForResumeVisibility(
                engine, timeout: resume.visibilityTimeout,
                cancellation: cancellation)
            try cancellation?.throwIfCancelled()
            markResumePhase("visible", milliseconds: visibility.waitedMilliseconds)
            if visibility.timedOut {
                activeResumeNote = "visible-timeout"
                // Not a failure: a harness may never publish the occlusion
                // signal. Record the enum only — no window/view paths.
                eventBus.send(.console(ConsolePayload(
                    level: .warn,
                    text: "webview-visibility=not_visible_timeout; "
                        + "the resume continued after \(Int(visibility.waitedMilliseconds.rounded())) ms "
                        + "without both visibility halves")))
            }
            // The wait may have ended on the timeout without ever seeing an
            // attached view; that is still the existing fail-loud refusal.
            guard engine.isAttachedWithVisibleArea else {
                throw PhoneDSHError.engineNotAttached
            }
            beginResumePhase("navigation")
        }
        let engineBootStartedAt = Date()
        let engineBootActiveStart = max(
            0, foregroundClock.activeMilliseconds() - activeResumeActiveStart)
        do {
            try await bootWorkerForResume(engine, engineConfiguration,
                                          timeout: resume?.bootReadyTimeout,
                                          cancellation: cancellation)
        } catch {
            recordEngineBootPhases(engine, startedAt: engineBootStartedAt,
                                   activeBase: engineBootActiveStart,
                                   success: false)
            throw error
        }
        recordEngineBootPhases(engine, startedAt: engineBootStartedAt,
                               activeBase: engineBootActiveStart,
                               success: true)
        if resume != nil { beginResumePhase("hello") }
        let helloTimeout = resume?.helloTimeout ?? configuration.helloTimeout
        let hello = try await waitForWorkerHello(
            runtime, timeout: helloTimeout, cancellation: cancellation)
        if resume != nil { markResumePhase("hello") }
        try cancellation?.throwIfCancelled()
        try await verifyLease(hello, runtime: runtime)
        await runtime.coordinator.finishWorkerBoot()
        activeResumeEngine = nil
        // D13: never open admission over a step this host gave up on. The
        // replacement-Worker paths already reconcile before `sendOpenFrames`;
        // the boot path needs the same guarantee, otherwise a retry after a
        // failed settlement can reopen admission while the step record is
        // still `tool_dispatched`. A boot with no open step pays nothing here.
        if reconcileOrphans {
            try await waitForWorkerToCloseOrphanSteps(runtime, reason: "boot-retry")
        }
        if resume != nil { beginResumePhase("running") }
        try await sendOpenFrames(hello.connection, runtime: runtime)
        setState(.running)
        if resume != nil { markResumePhase("running") }
        // This boot supersedes any deferred termination: a foreground return
        // must not inject a second recovery into a healthy host.
        pendingRecovery = false
        await evaluateBudget(runtime)
    }

    /// Waits for the boot-ready handshake under a host-side deadline, on top
    /// of the engine's own `bootTimeout`.
    ///
    /// The engine timeout is the primary bound; this guard covers an injected
    /// engine or a WebKit call that never returns. On expiry the caller tears
    /// the engine down and `resume()` throws, so the exclusive operation gate
    /// is released and the App can rebuild.
    private func bootWorkerForResume(
        _ engine: any WebEngineControlling,
        _ configuration: WebEngineConfiguration,
        timeout: TimeInterval?,
        cancellation: PhoneDSHResumeCancellation? = nil
    ) async throws {
        try cancellation?.throwIfCancelled()
        guard let timeout else {
            try await engine.bootWorker(configuration)
            return
        }
        let hardDeadline = timeout + 1
        let result = await phoneDSHResultWithinDeadline(hardDeadline) {
            try await engine.bootWorker(configuration)
        }
        if cancellation?.isCancelled == true {
            throw PhoneDSHError.resumeCancelled
        }
        switch result {
        case .success?:
            return
        case .failure(let error)?:
            if cancellation?.isCancelled == true { throw PhoneDSHError.resumeCancelled }
            throw error
        case nil:
            throw PhoneDSHError.startTimedOut(
                "resume boot-ready did not finish within \(hardDeadline) s")
        }
    }

    /// Waits for the replacement Worker's HELLO. A background transition clears
    /// the coordinator's waiter from ``setForeground(_:)`` and the nil result
    /// becomes ``PhoneDSHError/resumeCancelled``.
    private func waitForWorkerHello(
        _ runtime: RuntimeServices,
        timeout: TimeInterval,
        cancellation: PhoneDSHResumeCancellation?
    ) async throws -> PhoneDSHHelloResult {
        let result = try await runtime.coordinator.waitForHello(
            after: 0, expecting: workerBootID, timeout: timeout)
        if cancellation?.isCancelled == true {
            throw PhoneDSHError.resumeCancelled
        }
        return result
    }

    /// Adds the engine's navigation/boot-ready marks to the resume line.
    /// Engine durations are relative to `bootWorker`; the recorder wants
    /// milliseconds since the resume started.
    private func recordEngineBootPhases(_ engine: any WebEngineControlling,
                                        startedAt: Date,
                                        activeBase: Double,
                                        success: Bool) {
        guard activeResumeTiming != nil else { return }
        let base = activeBase
        guard let reporting = engine as? any WebEngineBootPhaseTimingReporting else {
            if success { markResumePhase("boot-ready") }
            return
        }
        let timings = reporting.bootPhaseTimings()
        if let navigation = timings.navigationMilliseconds {
            markResumePhase("navigation", milliseconds: base + navigation)
        }
        if let bootReady = timings.bootReadyMilliseconds {
            markResumePhase("boot-ready", milliseconds: base + bootReady)
        }
        if timings.reachedPhase == "boot-ready" {
            activeResumePhase = success ? "hello" : "boot-ready"
        } else {
            activeResumePhase = "navigation"
        }
    }

    /// Waits inside the controller's D14 drain window for the `0x40 API_REQ`
    /// exchanges **and** the write-direction sink/journal frames still in
    /// flight, then lets the state machine finish the drain.
    ///
    /// A request or sink frame that does not finish before the deadline is
    /// cancelled by the controller's own timer (D2: the initiator re-issues a
    /// request on the next connection after resume); the host does not keep it
    /// alive past the window. Whatever slipped past the close is sealed after
    /// the loopback is torn down (``closeRuntimeForPark(_:)``).
    private func drainInFlightWork(_ runtime: RuntimeServices) async throws {
        let controllerDeadline = await runtime.machine.drainDeadline
        let now = Date()
        let deadline = controllerDeadline
            ?? now.addingTimeInterval(max(0, configuration.drainDeadline))
        let timeout = max(0, deadline.timeIntervalSince(now))
        let idle = await runtime.coordinator.waitForDrainQuiescence(timeout: timeout)
        // The controller's own timer may have ended the drain while in-flight
        // work was finishing. If the close failed on a base mismatch, surface
        // its path/mseq instead of the wrapped "epoch close failed" reason.
        if await runtime.machine.currentState() != .draining {
            let holds = await runtime.log.pendingResyncHolds()
            if !holds.isEmpty {
                throw unrepairedMismatchError(holds, context: "drain epoch close")
            }
            return
        }

        // budgets.md §1/§2: while the Worker is connected, Draining includes
        // the answers to already-issued VFS_RESYNCs. A disconnected Worker is
        // not waited for; an unrepaired mismatch at the deadline is Failed
        // with its path and mseq (wal.md §5.2).
        let outstanding = await waitForOutstandingResyncAnswers(
            runtime, deadline: deadline)
        if !outstanding.isEmpty {
            throw unrepairedMismatchError(outstanding, context: "drain deadline")
        }
        if idle {
            try await completeDrain(runtime, signal: .backgroundDrainCompleted)
            return
        }
        guard let controllerDeadline else { return }
        // The controller timer cancels in-flight admission and parks the host
        // at the deadline; wait for that transition (or the grace timer)
        // instead of polling the state every few milliseconds.
        await waitForDrainDeadline(runtime, deadline: controllerDeadline)
        if await runtime.machine.currentState() != .draining {
            let holds = await runtime.log.pendingResyncHolds()
            if !holds.isEmpty {
                throw unrepairedMismatchError(holds, context: "drain deadline")
            }
            return
        }
        try await completeDrain(runtime, signal: .drainDeadlineElapsed)
    }

    /// Waits inside the drain deadline for issued VFS_RESYNC answers while the
    /// Worker is connected. Returns the still-held path/mseq pairs (empty when
    /// the repair arrived or there was nothing outstanding).
    private func waitForOutstandingResyncAnswers(
        _ runtime: RuntimeServices,
        deadline: Date
    ) async -> [MaterializationHold] {
        var pending = await runtime.log.pendingResyncHolds()
        guard !pending.isEmpty else { return [] }
        // budgets.md §1/§2: a disconnected Worker is not waited for.
        guard await workerChannelIsConnected(runtime) else {
            return pending
        }
        while Date() < deadline {
            let remaining = deadline.timeIntervalSince(Date())
            if remaining <= 0 { break }
            try? await Task.sleep(
                nanoseconds: UInt64(min(0.02, max(0.001, remaining)) * 1_000_000_000))
            pending = await runtime.log.pendingResyncHolds()
            if pending.isEmpty { return [] }
            if !(await workerChannelIsConnected(runtime)) { break }
        }
        return await runtime.log.pendingResyncHolds()
    }

    /// Whether the current Worker channel can still answer a VFS_RESYNC. A
    /// connection row outlives its socket; the receive-loop bit is the proof.
    private func workerChannelIsConnected(_ runtime: RuntimeServices) async -> Bool {
        guard let connection = await runtime.coordinator.currentConnection() else {
            return false
        }
        if await connection.server.hasFinishedReceiveLoop() { return false }
        return true
    }

    /// The wal.md §5.2 failure detail names every unrepaired path and mseq.
    private func unrepairedMismatchError(
        _ holds: [MaterializationHold],
        context: String
    ) -> LogError {
        let detail = holds
            .map { "\($0.path) mseq \($0.mseq)" }
            .joined(separator: ", ")
        return LogError.corrupt("\(context): unrepaired base mismatch at \(detail)")
    }

    // MARK: - Abort-path terminal journal (G2-FIX-9)

    /// Guarantees that every live DSH session has a terminal record before the
    /// Worker is torn down.
    ///
    /// Called once admission is closed (`Running -> Draining`), so no new turn
    /// can start and this is the single choke point for every abort reason: a
    /// wall-budget timeout, a request-budget abort, a user cancel that is
    /// followed by `stop()`, and a background drain. For each session this host
    /// handed to the Worker with an open turn it:
    ///
    /// 1. delivers one awaited `session/cancel` (bounded by the drain
    ///    window); the Worker's DSH loop journals its terminal `turn/end`
    ///    (a live cancel writes `aborted`), and
    /// 2. polls the materialized session journal until the turn is closed,
    ///    then gives the App's session event stream a bounded moment to forward
    ///    the terminal event before teardown.
    ///
    /// G2-FIX-105: the cancel RPC only works while the Worker can run it. When
    /// a blocked job owns the execution channel, step 1 times out and no
    /// record can be written. The abort path first sends the teardown
    /// LIFECYCLE stop, which fuses the Worker's tool signals; when that still
    /// cannot run, ``DrainEscalationPlan`` carves a bounded escalation area out
    /// of the same window. At its start ``PhoneDSHAbortEscalator`` stops the
    /// old Worker (two-phase), repacks only after it is gone, boots the
    /// replacement, and drives DSH's own resume/repair route. That route is
    /// what appends the pinned session layer's `interrupted` tail closers: a
    /// fresh Worker has no live Agent for `session/cancel` to address, so a
    /// cancel-only retry cannot settle a real interrupted turn. The loop then
    /// verifies that terminal record (bounded retry) before the draining
    /// transition completes. Swift never writes a session event; if the
    /// bounded escalation cannot produce the record, the open turn is still
    /// fail loud and is published on the host event stream.
    ///
    /// The cross-boundary assumption in step 1 is not taken from the comment:
    /// `plugins/worker-entry/src/abort-journal.test.ts` boots the pinned DSH
    /// image, hangs a model SSE response mid-body, sends the real
    /// `session/cancel`, and asserts the session journal ends on
    /// `turn/end {reason:{kind:'aborted', reason:{kind:'user'}}}`. That test is
    /// the CHANGE(3) diagnosis; no worker-entry shim is needed because the
    /// pinned runtime closes the turn itself (llm-bridge forwards the abort
    /// signal to the host-route fetch). If a future pin changes it, the test
    /// fails before this drain can silently regress.
    ///
    /// A window that expires with an open turn is fail loud: the error is
    /// published on the host event stream (the scenario report records it) and
    /// thrown, never silently swallowed. The host does not write DSH records;
    /// only the Worker's session layer does that.
    private func abortOpenSessionTurns(_ runtime: RuntimeServices) async throws {
        let controllerDeadline = await runtime.machine.drainDeadline
        let now = Date()
        let configured = max(0, configuration.drainDeadline)
        let fallback = now.addingTimeInterval(configured)
        let deadline = min(controllerDeadline ?? fallback, fallback)
        // G2-FIX-105: the controller owns the single split of the D14 window
        // between the cooperative cancel, the terminate/reboot escalation and
        // the teardown reserve, so the escalation can never wait past the
        // window it was granted.
        let plan = DrainEscalationPlan(deadline: deadline, window: configured)
        let verifyDeadline = plan.verifyDeadline

        let snapshot = await sessionTracker.snapshot()
        guard !snapshot.sessionIDs.isEmpty else { return }
        // A tracked session makes the scoped route mandatory. If the window is
        // already gone (for example a pre-graceful drain or a long journal scan
        // consumed it), returning here would park without ever attempting the
        // route: an unattempted mandatory call is unknown, never convergence.
        guard verifyDeadline > now else {
            let message = "abort: the drain window expired before the scoped "
                + "descendant drain could be attempted for "
                + "\(snapshot.sessionIDs.count) tracked session(s); an "
                + "unattempted route is not convergence"
            eventBus.send(.error(message))
            throw PhoneDSHError.invalidState(message)
        }

        // G2-F01: a spawned child owns its own durable session and activation.
        // The tracked root ids above do not include it, and `session/cancel`
        // below is scoped to one Agent. Drain the exact App-owned roots through
        // the public DSH manager first, then verify the root *and* its
        // `origin: "subagent"` descendants in the journal closure.
        //
        // A failed route is not allowed to skip the root drain. The route
        // covers descendants, but the root turn is closed by `session/cancel`
        // (and, if the Worker is jammed, by the existing terminate/reboot
        // escalation). Record the route failure, read the local forest so
        // descendant ids are still never sent to the single-Agent cancel, run
        // the existing root loop, and only fail loud after the roots converge.
        let forest: PhoneDSHDescendantForest
        let descendantDrainFailure: Error?
        do {
            forest = try await drainDescendantSessionsForAbort(
                runtime, rootSessionIDs: snapshot.sessionIDs, plan: plan)
            descendantDrainFailure = nil
        } catch {
            descendantDrainFailure = error
            let message = "abort: scoped descendant drain failed; continuing with "
                + "the root cancel/escalation path before fail loud: "
                + String(describing: error)
            eventBus.send(.error(message))
            forest = await localDescendantForestForAbort(
                runtime, rootSessionIDs: snapshot.sessionIDs)
        }
        let liveSessionIDs = forest.sessionIDs
        // `session/cancel` is scoped to one Agent and DSH rejects a
        // subagent-owned id as `session/agent-busy`; never send it to a child.
        // A descendant still open after the awaited scoped drain is verified
        // and reported, not cancelled through the wrong primitive.
        let descendantSessionIDs = forest.descendantSessionIDs

        // Open-turn number this drain already cancelled, per session. A
        // session that opens another turn inside the window is cancelled
        // again rather than let through.
        var cancelledTurns: [String: Int] = [:]
        // The exact turns each cancel is responsible for. Kept separately from
        // `terminalRequired` (which trades entries down as they close) so the
        // final settle branch can still prove every cancelled turn itself got
        // a terminal record instead of merely losing its open marker. This is
        // a list per session: observing turn 3 must not drop the still-open
        // turn 2 from an earlier cancel.
        var cancelledExpectedTurns: [String: [PhoneDSHExpectedTerminalTurn]] = [:]
        var lastCancelError: String?
        var promptGraceDeadline: Date?
        var settledAfterTerminal = false
        var escalationAttempts = 0
        // Sessions whose turn was open when escalation began, keyed to the
        // exact turn they must close. Once a Worker has been terminated for
        // them, only a journal `turn/end` that closes *that* turn may settle
        // the drain: a truncated/header-only log, or one that fell back to an
        // older completed turn, is not evidence for this interruption.
        var terminalRequired: [String: [PhoneDSHExpectedTerminalTurn]] = [:]
        // `stop()` already sent the teardown frame before entering the drain.
        // A background park reaches its cancellation reserve first here, so
        // this is where its LIFECYCLE stop is delivered. The frame fuses the
        // Worker's tool signals and lets the tool-journal settle a command
        // that ignores `session/cancel`; it is sent once per drain.
        var lifecycleSent = stopping

        while true {
            let states = await sessionTurnStates(runtime: runtime,
                                                 sessionIDs: liveSessionIDs)
            let open = states.filter { $0.value.isTurnOpen }
            let openIDs = open.keys.sorted()
            if !open.isEmpty {
                if !lifecycleSent {
                    lifecycleSent = true
                    // Never spend the escalation allowance on the best-effort
                    // teardown frame: a blocked lifecycle send is abandoned at
                    // its own short budget. The background park reaches this
                    // point at `escalationDeadline`, so passing that instant
                    // would make the send a no-op; keep the opportunity bounded
                    // by the verify deadline (the send itself caps at 2 s).
                    await sendDrainLifecycle(runtime,
                                             deadline: plan.verifyDeadline)
                }
                settledAfterTerminal = false
                let pending = open.filter { sessionID, state in
                    !descendantSessionIDs.contains(sessionID)
                        && cancelledTurns[sessionID] != state.openTurn
                }.keys.sorted()
                let openRootIDs = openIDs.filter { !descendantSessionIDs.contains($0) }
                // The route already failed and every open root turn is now
                // terminal; only a descendant remains. DSH rejects
                // `session/cancel` for a subagent-owned id, so there is no
                // further root work to do: fail loud with the route failure
                // once the roots converged instead of misreporting the child
                // as an uncancelled root.
                if openRootIDs.isEmpty, let descendantDrainFailure {
                    throw descendantDrainFailure
                }
                let escalator = !openRootIDs.isEmpty
                    && plan.shouldEscalate(now: Date(), attempts: escalationAttempts)
                    ? makeAbortEscalator(
                        runtime: runtime,
                        maximumTerminations: max(
                            1, DrainEscalationPlan.maximumWorkerTerminations
                                - escalationAttempts))
                    : nil
                let escalate = escalator != nil
                if !escalate, !pending.isEmpty {
                    let harness = DSHRemoteHarness(transport: makeTransport(runtime: runtime))
                    for sessionID in pending {
                        // Record the exact turn this cancel is responsible for
                        // before the RPC. A cancel can make the journal lose its
                        // open turn by truncating back to an older completed
                        // turn; the closing branch below must not read "no open
                        // turn" as "this turn reached a terminal record".
                        if let turn = open[sessionID]?.openTurn {
                            let expected = PhoneDSHExpectedTerminalTurn(
                                turn: turn,
                                openedAtMillis:
                                    open[sessionID]?.lastTurnBoundaryTimeMillis)
                            cancelledTurns[sessionID] = turn
                            var cancelled = cancelledExpectedTurns[sessionID] ?? []
                            if !cancelled.contains(expected) {
                                cancelled.append(expected)
                            }
                            cancelledExpectedTurns[sessionID] = cancelled
                            var required = terminalRequired[sessionID] ?? []
                            if !required.contains(expected) {
                                required.append(expected)
                            }
                            terminalRequired[sessionID] = required
                        }
                        // Never spend the escalation allowance on a Worker that
                        // cannot run the cancel: the budget ends at the
                        // escalation point, not at the drain deadline.
                        let remaining = plan.cancelBudget(now: Date())
                        guard remaining > 0 else { break }
                        let outcome = await phoneDSHResultWithinDeadline(remaining) {
                            try await harness.send(.cancel, to: sessionID)
                        }
                        if case .failure(let error)? = outcome {
                            lastCancelError = String(describing: error)
                        }
                    }
                }
                if let escalator {
                    // The bounded escalation owner: terminate the Worker, boot
                    // the replacement from the refreshed overlay, re-drive the
                    // public abort at it and verify DSH's own terminal record.
                    cancelledTurns.removeAll()
                    cancelledExpectedTurns.removeAll()
                    let expectedTurns: [String: PhoneDSHExpectedTerminalTurn] =
                        Dictionary(uniqueKeysWithValues: open.compactMap { sessionID, state in
                            state.openTurn.map {
                                (sessionID,
                                 PhoneDSHExpectedTerminalTurn(
                                    turn: $0,
                                    openedAtMillis: state.lastTurnBoundaryTimeMillis))
                            }
                        })
                    // Merge, never replace: a session may have accumulated
                    // more than one observed open turn before escalation.
                    for (sessionID, expected) in expectedTurns {
                        var required = terminalRequired[sessionID] ?? []
                        if !required.contains(expected) {
                            required.append(expected)
                        }
                        terminalRequired[sessionID] = required
                    }
                    // Verify the union of every turn this drain has observed
                    // open, not only the turn that happened to trigger this
                    // escalation. A session can open turn 3 after turn 2 was
                    // cancelled; settling turn 3 must not hide unclosed turn 2.
                    let requiredForEscalation = terminalRequired
                    let requiredSessions = Set(terminalRequired.keys)
                    let log = runtime.log
                    let cache = sessionJournalCache
                    let outcome = await escalator.terminateAndReboot(
                        sessionIDs: openRootIDs,
                        deadline: verifyDeadline,
                        hasTerminalTurn: {
                            let states = await Self.sessionTurnStates(
                                log: log, cache: cache, sessionIDs: requiredSessions)
                            // The journal must close every turn this drain saw
                            // open, not merely end on any earlier `turn/end`.
                            // An absent state, a header-only journal or a torn
                            // tail is not settled; a terminated Worker must
                            // never turn "no open turn" into "completed".
                            return requiredForEscalation.allSatisfy {
                                sessionID, expectedTurns in
                                expectedTurns.allSatisfy {
                                    $0.isClosed(by: states[sessionID])
                                }
                            }
                        })
                    escalationAttempts += max(1, outcome.attempts.count)
                    if let error = outcome.lastError { lastCancelError = error }
                    let text = outcome.settled
                        ? "drain escalation: settled the open DSH turn(s) after "
                            + "terminating the Worker/WebContent (\(outcome.diagnostic))"
                        : "drain escalation: could not settle the open DSH turn(s) "
                            + "inside the drain window (\(outcome.diagnostic))"
                    eventBus.send(.console(ConsolePayload(level: outcome.settled ? .warn : .error,
                                                          text: text)))
                    if !outcome.retryable {
                        // The old connection did not quiesce before the pack
                        // point. A queued VFS/JOURNAL frame may already be
                        // lost, so no later escalation may repack or boot a
                        // replacement and pretend the drain succeeded. Stop
                        // the whole drain here instead of letting the retry
                        // loop see an empty/retired connection table.
                        var message = "abort: the old Worker's inbound writes for "
                        message += "DSH session(s) "
                        message += openIDs.joined(separator: ", ")
                        message += " did not quiesce before the overlay repack; "
                        message += "no replacement Worker was booted"
                        if let lastCancelError {
                            message += " (last error: \(lastCancelError))"
                        }
                        eventBus.send(.error(message))
                        throw PhoneDSHError.invalidState(message)
                    }
                    continue
                }
                guard Date() < verifyDeadline else {
                    var message = "abort: DSH session(s) "
                    message += openIDs.joined(separator: ", ")
                    message += " still have an open turn after the "
                    message += "\(Int(max(0, configured).rounded())) s drain window; "
                    message += "no terminal turn/end was journaled in the materialized "
                    message += "session log"
                    if escalationAttempts > 0 {
                        message += " (bounded escalation attempted \(escalationAttempts) "
                        message += "time(s))"
                    }
                    if let lastCancelError {
                        message += " (last cancel error: \(lastCancelError))"
                    }
                    if let descendantDrainFailure {
                        message += " (scoped descendant drain also failed: "
                            + String(describing: descendantDrainFailure) + ")"
                    }
                    eventBus.send(.error(message))
                    throw PhoneDSHError.invalidState(message)
                }
            } else {
                // A session the escalation had to terminate is not settled by
                // the absence of an open turn. Its journal must now carry the
                // terminal record that closes the turn observed open before
                // escalation; an empty, header-only, torn or regressed journal
                // stays fail loud until the drain deadline.
                var stillRequired: [String: [PhoneDSHExpectedTerminalTurn]] = [:]
                for (sessionID, expectedTurns) in terminalRequired {
                    let unclosed = expectedTurns.filter {
                        !$0.isClosed(by: states[sessionID])
                    }
                    if !unclosed.isEmpty { stillRequired[sessionID] = unclosed }
                }
                terminalRequired = stillRequired
                if !terminalRequired.isEmpty {
                    guard Date() < verifyDeadline else {
                        let ids = terminalRequired.keys.sorted()
                        var message = "abort: DSH session(s) "
                        message += ids.joined(separator: ", ")
                        message += " have no terminal turn/end in the materialized "
                        message += "session log after the bounded drain/escalation; "
                        message += "an interrupted or terminated Worker is not "
                        message += "a completed turn"
                        if escalationAttempts > 0 {
                            message += " (bounded escalation attempted "
                            message += "\(escalationAttempts) time(s))"
                        }
                        eventBus.send(.error(message))
                        throw PhoneDSHError.invalidState(message)
                    }
                    try? await Task.sleep(nanoseconds: 50_000_000)
                    continue
                }
                // A prompt the Worker accepted can be journaled a moment after
                // the prompt RPC returns. Wait a short bounded grace for its
                // turn/start, and abort it if it opens; a queued prompt that
                // never starts has no open turn and needs no record.
                let pendingPrompt = snapshot.promptTimes.contains { entry in
                    guard let state = states[entry.key] else {
                        // The accepted prompt's first journal write is still in
                        // flight; it may open its turn inside this window.
                        return true
                    }
                    guard state.openTurn == nil else { return false }
                    let ended = state.lastTurnEndTimeMillis
                        .map { TimeInterval($0) / 1000 } ?? 0
                    // Journal milliseconds are rounded, and a trivially empty
                    // turn can close in the same millisecond the prompt was
                    // accepted: a 50 ms tolerance keeps that completed turn
                    // from looking queued. An actually open turn is caught by
                    // the branch above before this check.
                    return entry.value.timeIntervalSince1970 > ended + 0.05
                }
                if pendingPrompt && Date() < verifyDeadline {
                    if promptGraceDeadline == nil {
                        promptGraceDeadline = Date().addingTimeInterval(
                            min(2.0, verifyDeadline.timeIntervalSinceNow))
                    }
                    if let promptGraceDeadline, Date() < promptGraceDeadline {
                        try? await Task.sleep(nanoseconds: 50_000_000)
                        continue
                    }
                }
                if !cancelledTurns.isEmpty {
                    // The cancel is only settled when the journal carries the
                    // terminal record for the exact turn it was sent to. A
                    // truncated/regressed journal has no open turn but also no
                    // record for this turn; that is not a completed cancel.
                    var unclosed: [String: [PhoneDSHExpectedTerminalTurn]] = [:]
                    for (sessionID, expectedTurns) in cancelledExpectedTurns {
                        let remaining = expectedTurns.filter {
                            !$0.isClosed(by: states[sessionID])
                        }
                        if !remaining.isEmpty { unclosed[sessionID] = remaining }
                    }
                    if !unclosed.isEmpty {
                        guard Date() < verifyDeadline else {
                            let ids = unclosed.keys.sorted()
                            var message = "abort: DSH session(s) "
                            message += ids.joined(separator: ", ")
                            message += " have no terminal turn/end closing the "
                            message += "cancelled turn; an interrupted Worker is not "
                            message += "a completed turn"
                            if let lastCancelError {
                                message += " (last cancel error: \(lastCancelError))"
                            }
                            eventBus.send(.error(message))
                            throw PhoneDSHError.invalidState(message)
                        }
                        try? await Task.sleep(nanoseconds: 50_000_000)
                        continue
                    }
                }
                if !cancelledTurns.isEmpty && !settledAfterTerminal {
                    // The terminal record is durably in the journal; give the
                    // harness event stream a bounded moment to deliver
                    // turnEnded before the channel goes away, then scan once
                    // more in case the session opened another queued turn.
                    let settle = min(0.35, max(0, verifyDeadline.timeIntervalSinceNow))
                    if settle > 0 {
                        try? await Task.sleep(nanoseconds: UInt64(settle * 1_000_000_000))
                    }
                    settledAfterTerminal = true
                    continue
                }
                // G2-FIX-84: a closed turn is not enough. DSH writes the
                // terminal tool/result of a cancelled dispatch before turn/end,
                // but the tool-journal's `done` record and the D13 step it
                // terminalizes travel as a separate 0x30 frame. Wait for every
                // in-flight step of these sessions to reach `journaled` so the
                // teardown cannot park on a step stuck at `tool_dispatched`
                // with a journal that has only `start`.
                try await waitForInFlightToolCallsToSettle(
                    runtime, sessionIDs: liveSessionIDs,
                    deadline: verifyDeadline, configured: configured)
                // The root turn(s) and their tool steps are terminal, but the
                // scoped route failed. This is still not a graceful close:
                // fail loud with the route error now, after the root path
                // above had its chance to converge.
                if let descendantDrainFailure { throw descendantDrainFailure }
                return
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    /// Sends the best-effort `0x50 LIFECYCLE stop` that fuses host teardown
    /// cancellation into the in-flight Worker tool signals (G2-FIX-84).
    ///
    /// A teardown park sends this immediately. A background park sends it only
    /// when its graceful drain reaches the cancellation reserve and
    /// ``abortOpenSessionTurns(_:)`` must close the turn; until then the park
    /// keeps the command running and waits for its journal end. A background
    /// park that still lets the command run is what makes the drain-window
    /// write in the `park_resume` self-test land in the WAL before the park.
    ///
    /// The session-level `session/cancel` below remains the authoritative
    /// abort; this frame is what reaches the Worker's tool layer when that RPC
    /// is slow or lost. The Worker entry dispatches it as `pdsh-lifecycle`, the
    /// tool-journal aborts the fused tool signal, and the command that runs in
    /// the Worker (D12) observes the cancellation. A send failure is not a
    /// drain failure: the drain window and the fail-loud checks still apply.
    private func sendDrainLifecycle(_ runtime: RuntimeServices,
                                    deadline: Date? = nil) async {
        // A half-dead ordered channel can block forever in acquireSendSlot or
        // in the socket write. This frame is best effort, so it must never eat
        // the fixed drain window before terminate/quiesce/overlay/reboot.
        let remaining: TimeInterval
        if let deadline {
            remaining = deadline.timeIntervalSinceNow
        } else {
            let fallback = max(0, configuration.drainDeadline)
            let controllerDeadline = await runtime.machine.drainDeadline
            remaining = controllerDeadline?.timeIntervalSinceNow ?? fallback
        }
        // Best effort is never allowed to become a multi-second stall: the
        // cooperative cancel has the same 2 s cap, and a LIFECYCLE frame that
        // cannot reach a half-dead socket in that time must not hold the
        // terminate/quiesce/pack/reboot path.
        let budget = min(2.0, remaining)
        guard budget > 0 else { return }
        let coordinator = runtime.coordinator
        _ = await phoneDSHResultWithinDeadline(budget) {
            guard let connection = await coordinator.currentConnection() else {
                return
            }
            try await connection.sendLifecycle(LifecyclePayload(state: .stop,
                                                                budget: 0,
                                                                admission: .closed,
                                                                reason: "drain"))
        }
    }

    /// G2-F01: run the scoped descendant drain before the graceful park wait
    /// consumes the cooperative window.
    ///
    /// A child activation can keep its own turn open after the parent turn
    /// ends, and the graceful wait may legitimately use most of the window.
    /// Draining here gives the scoped route a real budget while the parent is
    /// still allowed to finish. ``abortOpenSessionTurns`` runs the same drain
    /// again for verification and owns the fail-loud decision in the remaining
    /// window; an early failure is logged there rather than skipping the
    /// graceful wait and root cancellation entirely.
    private func drainDescendantsBeforeGracefulPark(_ runtime: RuntimeServices) async {
        let controllerDeadline = await runtime.machine.drainDeadline
        let now = Date()
        let configured = max(0, configuration.drainDeadline)
        let fallback = now.addingTimeInterval(configured)
        let deadline = min(controllerDeadline ?? fallback, fallback)
        let plan = DrainEscalationPlan(deadline: deadline, window: configured)
        // This is an *early* attempt, not the abort's verification attempt. It
        // must not spend the escalation allowance or the verification window:
        // if the route is slow, `abortOpenSessionTurns` still needs its own
        // bounded route + fail-loud path. A window too short for one bounded
        // pre-drain call is skipped here and left to the mandatory abort call.
        guard plan.escalationDeadline > Date() else { return }
        let snapshot = await sessionTracker.snapshot()
        guard !snapshot.sessionIDs.isEmpty else { return }
        do {
            _ = try await drainDescendantSessionsForAbort(
                runtime, rootSessionIDs: snapshot.sessionIDs, plan: plan,
                deadline: plan.escalationDeadline)
        } catch {
            eventBus.send(.console(ConsolePayload(
                level: .warn,
                text: "descendant drain before graceful park: "
                    + "\(String(describing: error))")))
        }
    }

    /// Lets the work in flight on a *graceful* park (backgrounding) finish
    /// inside the D14 drain window before any turn is cancelled.
    ///
    /// closing admission only stops *new* side effects; the turn the running
    /// page already accepted still needs the window. A `bash -c` step that is
    /// executing in the Worker (D12) is not abortable without losing its
    /// partial writes (D8/D9 forbids rolling them back), so the park waits for
    /// the session journal to close the turn and for the D13 tool step to
    /// reach `journaled`. The timeout is bounded by the same
    /// ``DrainEscalationPlan`` the abort path uses: the graceful phase must
    /// stop at ``DrainEscalationPlan/escalationDeadline``, so a jammed Worker
    /// still gets the full escalation allowance (terminate, quiesce, overlay,
    /// reboot, HELLO, DSH repair and journal verification) instead of reaching
    /// it with only the teardown tail left.
    ///
    /// This method only observes; it never fabricates a terminal record and
    /// never extends the drain past the controller's deadline.
    ///
    /// A teardown park (``stop()``) skips this and cancels immediately.
    private func drainOpenTurnsGracefullyBeforePark(_ runtime: RuntimeServices) async {
        let configured = max(0, configuration.drainDeadline)
        guard configured > 0 else { return }
        let controllerDeadline = await runtime.machine.drainDeadline
        let fallback = Date().addingTimeInterval(configured)
        let deadline = min(controllerDeadline ?? fallback, fallback)
        // Reuse the abort path's single split of the window. The graceful
        // phase must not eat the escalation area: on the real 20 s window the
        // escalation starts around 6 s, not after 16 s once the cancellation
        // budget has also been spent. `abortOpenSessionTurns` then enters the
        // terminate/quiesce/overlay/reboot/DSH-repair path with the whole
        // allowance still ahead of `verifyDeadline`.
        let plan = DrainEscalationPlan(deadline: deadline, window: configured)
        let gracefulDeadline = plan.escalationDeadline
        guard gracefulDeadline > Date() else { return }
        let snapshot = await sessionTracker.snapshot()
        guard !snapshot.sessionIDs.isEmpty else { return }
        while Date() < gracefulDeadline {
            let states = await sessionTurnStates(runtime: runtime,
                                                 sessionIDs: snapshot.sessionIDs)
            let hasOpenTurn = states.values.contains { $0.isTurnOpen }
            let pending = await runtime.stepMachine.reconcile().filter {
                snapshot.sessionIDs.contains($0.sessionID) && !$0.state.isTerminal
            }
            if !hasOpenTurn && pending.isEmpty { return }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    /// Waits inside the drain window until every in-flight D13 step of the
    /// drained sessions has a terminal journal record (G2-FIX-84).
    ///
    /// The session-level abort (G2-FIX-9) proves the turn closed, but a tool
    /// call is settled one layer below it: the Worker's tool-journal writes a
    /// terminal `done` only after the dispatch returns. If the Worker is torn
    /// down between `turn/end` and that record, the D13 step stays at
    /// `tool_dispatched` and the materialized tool-journal keeps a `start` with
    /// no end, while a partially written file is already WAL state (D8/D9
    /// forbids rolling it back). A closed turn with a non-terminal step is
    /// therefore fail loud: the run must carry the error, never park silently
    /// on the half-state.
    ///
    /// The wait is bounded by the same drain deadline as the open-turn check.
    /// `StepMachine` is the authority here; it advances on the `completed`
    /// journal record (exec.md §4), so an empty `reconcile()` is exactly
    /// "every observed step is terminal" (journaled or abandoned).
    private func waitForInFlightToolCallsToSettle(
        _ runtime: RuntimeServices,
        sessionIDs: Set<String>,
        deadline: Date,
        configured: TimeInterval
    ) async throws {
        guard !sessionIDs.isEmpty else { return }
        while true {
            let pending = await runtime.stepMachine.reconcile().filter {
                sessionIDs.contains($0.sessionID) && !$0.state.isTerminal
            }
            if pending.isEmpty { return }
            guard Date() < deadline else {
                let detail = pending.prefix(8)
                    .map { "\($0.sessionID)/\($0.stepKey)=\($0.state.rawValue)" }
                    .joined(separator: ", ")
                // The drain is still fail loud, but the D13 records must not
                // stay permanently open: the host gives up ownership of the
                // steps it could not settle before reporting the error.
                var settlementDetail = ""
                do {
                    let settled = try await runtime.stepMachine.settleOrphans(
                        reason: "drain-timeout")
                    publishOrphanSettlement(settled, reason: "drain-timeout")
                } catch {
                    settlementDetail = "; settling the orphan steps also failed: \(error)"
                }
                var message = "abort: \(pending.count) tool call(s) still have no terminal D13 step "
                message += "after the \(Int(max(0, configured).rounded())) s drain window: \(detail); "
                message += "the tool-journal end record (or the completed journal record) was not durable"
                message += settlementDetail
                eventBus.send(.error(message))
                throw PhoneDSHError.invalidState(message)
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    /// Builds the bounded abort escalation owner for this drain (G2-FIX-105).
    ///
    /// The escalator terminates the Worker/WebContent through the engine, so it
    /// needs the same transport the harness uses for the replacement Worker and
    /// the log/coordinator the host already owns. It never receives App state or
    /// credentials. Returns `nil` when the host has no engine to terminate.
    private func makeAbortEscalator(
        runtime: RuntimeServices,
        maximumTerminations: Int
    ) -> PhoneDSHAbortEscalator? {
        guard let engine = runtime.engine else { return nil }
        return PhoneDSHAbortEscalator(
            bootID: bootID,
            engine: engine,
            log: runtime.log,
            coordinator: runtime.coordinator,
            transport: makeTransport(runtime: runtime),
            maximumTerminations: maximumTerminations)
    }

    /// Materializes the WAL and reads the live sessions' journal turn state.
    private func sessionTurnStates(
        runtime: RuntimeServices,
        sessionIDs: Set<String>
    ) async -> [String: PhoneDSHSessionTurnState] {
        await Self.sessionTurnStates(log: runtime.log,
                                     cache: sessionJournalCache,
                                     sessionIDs: sessionIDs)
    }

    /// Reads the local forest after the scoped route failed.
    ///
    /// The route failure must not skip the root cancel/escalation loop, but the
    /// loop still has to know which open ids are subagent descendants: DSH
    /// rejects `session/cancel` for them with `session/agent-busy`. This is
    /// best effort only for *classification*. A read failure is logged and
    /// leaves only the exact roots, not a fabricated terminal child; the route
    /// error itself is still rethrown after the root path settles.
    private func localDescendantForestForAbort(
        _ runtime: RuntimeServices,
        rootSessionIDs: Set<String>
    ) async -> PhoneDSHDescendantForest {
        let home = await runtime.log.paths.materializedHomeDirectory
        let sessionsDirectory = home.appendingPathComponent("sessions",
                                                            isDirectory: true)
        do {
            _ = try await runtime.log.materialize()
            let forest = try PhoneDSHDescendantSessions.forest(
                inSessionsDirectory: sessionsDirectory,
                rootSessionIDs: rootSessionIDs,
                incarnationStart: workerIncarnationStartedAt,
                liveDescendantSessionIDs: reportedLiveDescendantSessionIDs,
                cache: sessionJournalCache)
            eventBus.send(.console(ConsolePayload(
                level: .warn,
                text: "descendant drain fallback: \(forest.descendantSessionIDs.count) "
                    + "local subagent session(s) classified while the route failure "
                    + "still owns the final error")))
            return forest
        } catch {
            // The lineage walk may fail on an unreadable/incomplete child
            // header. The root journals are still independently readable, and
            // the root cancel must not be skipped just because a descendant
            // could not be classified. No descendant is claimed here.
            let rootStates = PhoneDSHSessionLog.states(
                inSessionsDirectory: sessionsDirectory,
                including: rootSessionIDs,
                cache: sessionJournalCache)
            eventBus.send(.console(ConsolePayload(
                level: .warn,
                text: "descendant drain fallback could not classify the local forest "
                    + "(only root journals will drive cancellation): \(error)")))
            return PhoneDSHDescendantForest(states: rootStates,
                                            rootSessionIDs: rootSessionIDs,
                                            descendantSessionIDs: [])
        }
    }

    /// Drains the exact App-owned roots' descendants and returns the journal
    /// closure the abort loop must verify.
    ///
    /// G2-F01: the route call is the only Worker-side operation that can close
    /// a child activation. It is bounded by the pre-escalation part of the same
    /// D14 window, leaving the terminate/reboot area for the root sessions, and
    /// its result is not trusted as evidence:
    /// the caller re-reads the durable headers and turn states, including
    /// `origin: "subagent"` descendants.
    ///
    /// The route is called even when no descendant journal is visible: the
    /// scoped call also closes subagent admission below the roots and covers
    /// an external or concurrently spawned child that has no materialized
    /// journal yet. Its budget ends at the escalation point, not at the
    /// verification deadline, so a slow/timed-out route cannot consume the
    /// bounded terminate/reboot window the root sessions still need. It is also
    /// mandatory when the materialize/forest scan consumed the window:
    /// ``PhoneDSHDescendantDrain/teardownBudget(until:now:rootCount:
    /// openDescendantCount:maximumSeconds:transportGrace:)`` throws an
    /// unattempted route through as fail loud instead of treating
    /// `budget == nil` as convergence. A legacy transport without the route is
    /// tolerated only when no descendant turn is open:
    /// ``PhoneDSHDescendantDrain.drain`` returns `nil` for that case. Once the
    /// route call is made, any transport error, timeout or malformed receipt
    /// is fail loud even when the local journal shows no child: an empty
    /// journal cannot prove a concurrently spawned child is absent. Only
    /// ``PhoneDSHDescendantDrain.drain`` may decide that the transport has no
    /// route; the host never swallows a thrown route failure.
    ///
    /// Descendant journals created before ``workerIncarnationStartedAt`` are
    /// stale crash records **only when the route did not report that id live in
    /// this Worker incarnation**. DSH cold resume reuses the child id and persisted header,
    /// so an old `createdAt` alone cannot exclude a live resumed child: the
    /// route's live-descendant set makes it (and its descendants) reachable,
    /// and the durable `turn/end` is still verified. Every other old journal is
    /// excluded because a live drain cannot close a non-resident Activation;
    /// cold-resume recovery owns it. A child that still has an open turn after
    /// the drain is fail loud below.
    ///
    /// Root ids are batched to the Worker's accepted maximum; one oversized
    /// request must not turn the whole abort into a 400.
    ///
    /// - Parameters:
    ///   - runtime: live host runtime.
    ///   - rootSessionIDs: exact App-owned roots this host opened or prompted.
    ///   - plan: the D14 budget split.
    ///   - deadline: optional earlier absolute deadline for the pre-graceful
    ///     pass. Abort normally keeps the escalation reserve; a first mandatory
    ///     call after that point gets at most 2.5 seconds, capped by the original
    ///     verification deadline. Earlier successful calls are only re-verified.
    private func drainDescendantSessionsForAbort(
        _ runtime: RuntimeServices,
        rootSessionIDs: Set<String>,
        plan: DrainEscalationPlan,
        deadline: Date? = nil
    ) async throws -> PhoneDSHDescendantForest {
        // Capture the boundary before the first await; a single park/stop owns
        // one Worker epoch, but the value must not drift if a future caller
        // interleaves a boot.
        let incarnationStartedAt = self.workerIncarnationStartedAt
        // A materialize failure means the verification tree is not current;
        // treating it as an empty forest could tear the Worker down with a live
        // child. Fail loud instead.
        _ = try await runtime.log.materialize()
        let materializedHome = await runtime.log.paths.materializedHomeDirectory
        let sessionsDirectory = materializedHome
            .appendingPathComponent("sessions", isDirectory: true)
        // Prefer the cooperative area so a slow route does not consume the
        // root escalation reserve. If a short window started beyond that area,
        // a first mandatory attempt still fits inside its verification bound.
        let preferredDeadline = min(deadline ?? plan.escalationDeadline,
                                    plan.escalationDeadline)
        let routeNow = Date()
        let alreadyAttempted = rootSessionIDs.isSubset(of: descendantDrainAttemptedRoots)
        // A short configured drain can begin after its escalation point even
        // when the verification window is still open. The first mandatory
        // scoped call must then get one bounded attempt, rather than failing
        // before dispatch. Successful early calls still reuse their receipt;
        // the pre-graceful pass never borrows the escalation reserve.
        let routeDeadline = deadline == nil && preferredDeadline <= routeNow && !alreadyAttempted
            ? min(plan.verifyDeadline, routeNow.addingTimeInterval(2.5))
            : preferredDeadline
        let before = try PhoneDSHDescendantSessions.forest(
            inSessionsDirectory: sessionsDirectory,
            rootSessionIDs: rootSessionIDs,
            incarnationStart: incarnationStartedAt,
            cache: sessionJournalCache)
        let openDescendants = before.openDescendantSessionIDs
        // Every open descendant must map to one of the exact roots this host
        // tracks; otherwise no batch could name it and the failure would be
        // silently skipped.
        for descendant in openDescendants {
            guard let root = before.rootSessionID(forDescendant: descendant),
                  rootSessionIDs.contains(root) else {
                throw PhoneDSHError.invalidState(
                    "the open descendant \(descendant) has no root in the tracked "
                        + "session set")
            }
        }
        // The early pre-graceful pass may already have named exactly these
        // roots in a successful scoped route call. If the escalation point
        // passed while the graceful wait was still letting a legitimate turn
        // finish, the abort has no pre-escalation route budget left, but that
        // is "already attempted", not "unattempted". Do not spend the root
        // escalation area on a redundant call: re-read the durable forest and
        // verify it below. Roots the earlier pass did not cover still fail
        // loud through ``teardownBudget``; a successful receipt is never
        // terminal evidence by itself.
        let reuseEarlierRoute = Date() >= routeDeadline
            && rootSessionIDs.isSubset(of: descendantDrainAttemptedRoots)
        if reuseEarlierRoute {
            eventBus.send(.console(ConsolePayload(
                level: .info,
                text: "descendant drain: reusing the successful pre-graceful route "
                    + "for \(rootSessionIDs.count) root(s); verifying the durable "
                    + "forest inside the abort window")))
        } else {
            // A tracked root makes the route mandatory. A nil budget means the
            // materialize/forest scan consumed the whole verification window;
            // that is an unknown, not convergence, so this is fail loud even
            // when no child journal is visible.
            _ = try PhoneDSHDescendantDrain.teardownBudget(
                until: routeDeadline,
                rootCount: rootSessionIDs.count,
                openDescendantCount: openDescendants.count)
        }
        var drainedRoots: Set<String> = []
        // Seed from earlier passes in the same incarnation, then add this
        // call's receipt. An old child that was already reported live cannot
        // disappear from verification just because a later listing no longer
        // names it.
        var liveDescendants = reportedLiveDescendantSessionIDs
        var drainMilliseconds = 0
        let overallDeadline = routeDeadline
        let batches = PhoneDSHDescendantDrain.rootBatches(
            rootSessionIDs.sorted())
        // Spend the bounded window on the batches that can actually
        // explain an open child first; the remaining roots still get their
        // admission-closing call when time permits.
        let openRoots = Set(openDescendants.compactMap {
            before.rootSessionID(forDescendant: $0)
        })
        let prioritized = batches.sorted { lhs, rhs in
            let lhsHasOpen = !Set(lhs).isDisjoint(with: openRoots)
            let rhsHasOpen = !Set(rhs).isDisjoint(with: openRoots)
            return lhsHasOpen && !rhsHasOpen
        }
        for batch in (reuseEarlierRoute ? [[String]]() : prioritized) {
            let batchRoots = Set(batch)
            let batchOpen = openDescendants.filter { descendant in
                guard let root = before.rootSessionID(
                    forDescendant: descendant) else { return false }
                return batchRoots.contains(root)
            }
            let left = overallDeadline.timeIntervalSinceNow
            guard left > 0 else {
                // A batch that is never named is an unattempted scoped call,
                // not evidence that its roots have no descendant. Fail loud for
                // an empty batch too; only a genuinely route-less transport
                // with no open child may return nil (inside `drain`).
                let openDetail = batchOpen.isEmpty
                    ? ""
                    : " and \(batchOpen.count) open subagent session(s)"
                throw PhoneDSHError.invalidState(
                    "the scoped descendant drain has no budget left to name "
                        + "\(batch.count) tracked root(s)\(openDetail)")
            }
            let batchBudget = try PhoneDSHDescendantDrain.teardownBudget(
                until: overallDeadline,
                now: Date(),
                rootCount: batch.count,
                openDescendantCount: batchOpen.count)
            // `drain` returns nil only when the transport has no route and
            // no descendant turn is open. Every thrown value means the
            // route was actually attempted and failed (or the transport
            // refused while a child was open); an empty journal must not
            // turn that unknown into success, so the host does not catch
            // it here.
            let receipt = try await PhoneDSHDescendantDrain.drain(
                transport: makeTransport(runtime: runtime),
                rootSessionIDs: batchRoots,
                openDescendantSessionIDs: Set(batchOpen),
                budget: batchBudget)
            if let receipt {
                // Persist the successful attempt per batch: a later batch
                // failure must not reclassify an already-named root as
                // unattempted after the escalation point.
                descendantDrainAttemptedRoots.formUnion(batchRoots)
                drainedRoots.formUnion(receipt.roots)
                // The receipt names the exact live/drained descendants. An old
                // durable header alone is not evidence they are stale: DSH cold
                // resume reuses the child id and header, so this set is what
                // makes the host verify a live resumed child's `turn/end`.
                liveDescendants.formUnion(receipt.descendants)
                // Persist each successful batch before the next one: a later
                // batch failure must not erase the evidence that an earlier
                // old child was live in this incarnation.
                reportedLiveDescendantSessionIDs = liveDescendants
                drainMilliseconds += receipt.durationMilliseconds ?? 0
            }
        }
        reportedLiveDescendantSessionIDs = liveDescendants
        if !drainedRoots.isEmpty || !before.descendantSessionIDs.isEmpty {
            eventBus.send(.console(ConsolePayload(
                level: .info,
                text: "descendant drain: \(drainedRoots.count) root(s), "
                    + "\(before.descendantSessionIDs.count) subagent session(s) "
                    + "observed (\(openDescendants.count) open, "
                    + "\(drainMilliseconds) ms)")))
        }
        // Re-read after the awaited disposal: a grandchild published during
        // the drain is part of the closure that must be terminal before the
        // Worker is torn down. Materialize first so the child's own final
        // `turn/end` write is in the copy this check reads.
        _ = try await runtime.log.materialize()
        let after = try PhoneDSHDescendantSessions.forest(
            inSessionsDirectory: sessionsDirectory,
            rootSessionIDs: rootSessionIDs,
            incarnationStart: incarnationStartedAt,
            liveDescendantSessionIDs: liveDescendants,
            cache: sessionJournalCache)
        // The receipt is diagnostic, not terminal evidence. `forest` only
        // contains a session whose journal is readable and whose parent chain
        // reaches one of these roots, so a route-reported child with no
        // materialized journal (or a missing intermediate parent) would vanish
        // from the verification set. That is an unknown child, never a
        // gracefully closed one: fail loud instead of parking as success.
        try after.requireVerifiableLiveDescendants(liveDescendants)
        // The same rule for roots: a receipt may not name a root outside this
        // request, and a root that had a durable journal before the drain must
        // still be in the re-read closure. A root with no journal has no
        // durable turn to verify; requiring a fabricated one would claim
        // evidence the Worker never wrote.
        let unexpectedRoots = drainedRoots.subtracting(rootSessionIDs)
        if let root = unexpectedRoots.sorted().first {
            throw PhoneDSHError.invalidState(
                "the scoped descendant drain reported root \(root) outside the "
                    + "exact tracked roots; the host cannot verify an unrelated "
                    + "root's convergence")
        }
        for root in drainedRoots.sorted() where before.states[root] != nil {
            guard after.states[root] != nil else {
                throw PhoneDSHError.invalidState(
                    "the scoped descendant drain reported root \(root) live, but "
                        + "its durable journal disappeared from the verification "
                        + "forest before the open turn could be verified")
            }
        }
        return after
    }

    /// Materializes the WAL and reads the live sessions' journal turn state.
    ///
    /// Split out as a static helper so the escalation's
    /// ``PhoneDSHAbortEscalator`` verification closure can poll the journal
    /// without capturing the host's runtime.
    private static func sessionTurnStates(
        log: WorkspaceLog,
        cache: PhoneDSHJournalStateCache,
        sessionIDs: Set<String>
    ) async -> [String: PhoneDSHSessionTurnState] {
        _ = try? await log.materialize()
        let materializedHome = await log.paths.materializedHomeDirectory
        return PhoneDSHSessionLog.states(
            inSessionsDirectory: materializedHome
                .appendingPathComponent("sessions", isDirectory: true),
            including: sessionIDs,
            cache: cache)
    }

    /// Waits until the controller's drain timer leaves `Draining`.
    ///
    /// The transition stream is event driven and replays the most recent
    /// transition to a late subscriber, so a timer that fired first is not
    /// missed. The one-second sleep past the deadline is only a safety net for
    /// a controller whose timer failed to fire; normally the transition task
    /// wins.
    private func waitForDrainDeadline(_ runtime: RuntimeServices,
                                      deadline: Date) async {
        let machine = runtime.machine
        let grace = max(0, deadline.timeIntervalSinceNow) + 1
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                for await record in machine.transitions() {
                    if record.to != .draining { return }
                }
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: Self.nanoseconds(grace))
            }
            await group.next()
            group.cancelAll()
        }
    }

    private static func nanoseconds(_ seconds: TimeInterval) -> UInt64 {
        UInt64(max(0, seconds) * 1_000_000_000)
    }

    /// Delivers a drain-completion signal, tolerating the controller's own
    /// deadline timer having completed the same drain first.
    private func completeDrain(_ runtime: RuntimeServices,
                               signal: HostSignal) async throws {
        do {
            _ = try await runtime.machine.handle(signal)
        } catch {
            guard await runtime.machine.currentState() == .parked else { throw error }
        }
    }

    /// Stops the host. Running/draining hosts are parked first so the WAL epoch
    /// closes in the D18 order and the fence covers the tail; then the
    /// listener, controller and gateway are released. A `Remote`/`Reclaiming`
    /// controller keeps its coordinator and machine (and therefore its injected
    /// token store) so the same host can still ``reclaim()``. A
    /// failed host keeps its diagnostics and last error. A drain/seal failure
    /// is reported to the caller after the resources are released; it is never
    /// swallowed.
    public func stop() async throws {
        try beginExclusiveOperation(.stop)
        defer { endExclusiveOperation(.stop) }
        try await stopWithoutGate()
    }

    private func stopWithoutGate() async throws {
        // A teardown also discards any deferred termination recovery.
        pendingRecovery = false
        if runtime == nil {
            setState(.stopped)
            // Consumers of the single event sequence observe the end of the
            // host instead of having to infer it from the state change.
            eventBus.finish()
            return
        }
        var drainError: Error?
        if state == .running || state == .draining {
            stopping = true
            do {
                try await parkWithoutGate()
            } catch {
                drainError = error
            }
            stopping = false
        }
        let snapshot = await diagnostics()
        machineObserver?.cancel()
        machineObserver = nil
        engineObserver?.cancel()
        engineObserver = nil
        if let runtime {
            await runtime.loopback.stop()
            let controller = await runtime.machine.currentState()
            let handoffPhase: HandoffCoordinatorPhase?
            if let handoff = runtime.handoff {
                handoffPhase = await handoff.phase
            } else {
                handoffPhase = nil
            }
            let fence = await runtime.authority.current
            let fenceOwner = fence.owner
            // D15: a remote/reclaiming controller must keep its coordinator and
            // injected token store across a host stop; the same-process
            // reclaim() then finishes the return path. The coordinator phase
            // and a remote fence also count: a local fence write can fail
            // after the remote CAS and before the controller is observable as
            // Reclaiming. Every other state keeps the normal full teardown.
            let preserveRemoteHandoff = runtime.handoff != nil
                && (controller == .remote || controller == .reclaiming
                    || handoffPhase == .remote || handoffPhase == .reclaiming
                    || fenceOwner != HandoffLimits.phoneOwner)
            if drainError == nil {
                // No frame can reach the log now. Seal the accepted tail and
                // verify the materialized copy even when the host reached stop
                // through Failed (a park abort that never got to the drain
                // close): an open epoch behind an inverted manifest is the
                // G2-A09 data-loss window. A failure here stays fail loud.
                _ = await runtime.coordinator.waitForInboundWritesToQuiesce()
                do {
                    _ = try await runtime.log.sealForStop()
                } catch {
                    drainError = error
                }
            }
            if preserveRemoteHandoff, let handoff = runtime.handoff {
                remoteHandoff = RemoteHandoffContext(coordinator: handoff,
                                                     machine: runtime.machine)
            } else {
                await runtime.machine.shutdown()
            }
            await runtime.gateway.shutdown()
            // A stop that did not take the running/draining park path (for
            // example a Backoff host being rebuilt) still owns the failed
            // page. Shut it down before the runtime is released.
            await shutdownEngineBestEffort(self.runtime?.engine)
        }
        self.runtime = nil
        var finalSnapshot = snapshot
        finalSnapshot.state = .stopped
        lastSnapshot = finalSnapshot
        setState(.stopped)
        // `stop()` ends this host incarnation: every subscriber's stream
        // finishes after the `.stopped` state change. A later `start()`
        // reopens the bus for new subscriptions.
        eventBus.finish()
        if let drainError { throw drainError }
    }

    // MARK: - Harness

    /// Returns an `AgentHarness` backed by `DSHRemoteHarness` over the ordered
    /// channel. Refuses with ``PhoneDSHError/lockdownMode`` when the engine
    /// reports Lockdown Mode: the local Worker needs a JIT-enabled WebContent
    /// process.
    public func harness() async throws -> any AgentHarness {
        guard let runtime else {
            if lockdownModeObserved { throw PhoneDSHError.lockdownMode }
            throw PhoneDSHError.notStarted
        }
        if runtime.engine?.isLockdownModeEnabled == true {
            lockdownModeObserved = true
            throw PhoneDSHError.lockdownMode
        }
        if state == .failed {
            if lockdownModeObserved { throw PhoneDSHError.lockdownMode }
            throw PhoneDSHError.hostFailed(lastError ?? "the host is failed")
        }
        // G2-FIX-12: every turn this harness runs is supervised for event
        // silence. The supervisor forwards commands and events unchanged and
        // records its stalls in the host ledger, so the App (and the scenario
        // report) can tell a hung turn from one that is still working. Each
        // call returns a fresh supervisor; a caller that replaces the harness
        // after a recovery releases the old `events()` subscription, which
        // disarms that supervisor (no zombie cancel, no phantom stall).
        return PhoneDSHTurnInactivitySupervisor(
            harness: DSHRemoteHarness(transport: makeTransport(runtime: runtime)),
            timeout: configuration.turnInactivityTimeout,
            ledger: inactivityLedger)
    }

    /// True while at least one workbench session this host opened or prompted
    /// still has an open turn in its durable journal. `excludedSessionIDs` is
    /// the App's live Bot-session set: Bot units share this host's transport,
    /// so they must not make a Bot-originated write look like workbench
    /// traffic. A journal read failure is `false`, which lets the egress
    /// fallback fail closed instead of silently allowing the write.
    public func hasActiveWorkbenchTurn(excluding excludedSessionIDs: Set<String>) async -> Bool {
        guard let runtime else { return false }
        let snapshot = await sessionTracker.snapshot()
        let candidates = snapshot.sessionIDs.subtracting(excludedSessionIDs)
        guard !candidates.isEmpty else { return false }
        let states = await Self.sessionTurnStates(
            log: runtime.log, cache: sessionJournalCache, sessionIDs: candidates)
        return states.values.contains { $0.isTurnOpen }
    }

    /// The ordered-channel `DSHRemoteTransport` the harness (or any other
    /// Agent adapter) can use. Exposed so the App can drive the same transport
    /// with its own `DSHRemoteHarness` configuration.
    public func makeTransport() async throws -> any DSHRemoteTransport {
        guard let runtime else { throw PhoneDSHError.notStarted }
        return makeTransport(runtime: runtime)
    }

    private func makeTransport(runtime: RuntimeServices) -> any DSHRemoteTransport {
        let coordinator = runtime.coordinator
        let channel = ChannelDSHTransport(channelProvider: { excluding in
            try await coordinator.waitForChannel(excluding: excluding, timeout: 10)
        })
        // G2-FIX-9: observe the session ids the App opens or prompts through
        // this host so the drain can verify *their* journals, not a stale one.
        return PhoneDSHTrackedTransport(base: channel, tracker: sessionTracker)
    }

    // MARK: - Diagnostics

    /// Snapshot for the App's diagnostics screen; never contains tokens or
    /// credentials.
    public func diagnostics() async -> PhoneDSHDiagnostics {
        let inactivity = inactivityLedger.report()
        guard let runtime else {
            if var snapshot = lastSnapshot {
                snapshot.state = state
                return snapshot
            }
            return PhoneDSHDiagnostics(
                state: state, bootID: bootID, lastError: lastError,
                turnInactivityStalls: inactivity.stallCount,
                turnInactivityReason: inactivity.lastStallReason,
                turnInactivityTimeout: inactivity.timeout)
        }
        let hostState = await runtime.machine.currentState()
        let bootDisposition = await runtime.machine.bootDisposition
        let bootReason = await runtime.machine.bootReason
        let admission = runtime.machine.admission.current
        let machineError = await runtime.machine.lastError
        let positions = await runtime.log.positions()
        let materialized = (try? await runtime.log.materialize()) ?? 0
        let metrics = (try? await runtime.log.metrics()) ?? WorkspaceLogMetrics()
        let stepMetrics = await runtime.stepMachine.metrics()
        let sideEffectEntries = await runtime.ledger.keys().count
        let channelMetrics = await runtime.coordinator.channelMetrics()
        let helloCount = await runtime.coordinator.helloCountValue()
        let connectionCount = await runtime.coordinator.connectionCountValue()
        let vfsRefusals = await runtime.coordinator.vfsRefusalCountValue()
        let lastVFSRefusal = await runtime.coordinator.lastVFSRefusal()
        let gatewayMetrics = runtime.gateway.metrics()
        let responseLogBytes: Int
        if let responseLog = runtime.responseLog {
            responseLogBytes = await responseLog.totalBytes()
        } else {
            responseLogBytes = 0
        }
        let fence = await runtime.authority.current
        let ledgerPersistenceError = await runtime.ledgerRecorder.lastPersistenceError
        let budget = await budgetSnapshot(runtime: runtime, metrics: metrics,
                                          responseLogBytes: responseLogBytes,
                                          advance: false)
        var reportedTerminations = terminations
        if let webEngine = runtime.engine as? WebEngine {
            reportedTerminations = max(reportedTerminations, webEngine.terminationCount)
        }
        let snapshot = PhoneDSHDiagnostics(
            state: state,
            bootID: bootID,
            nextMseq: positions.nextMseq,
            ackedMseq: positions.ackedMseq,
            durableMseq: positions.durableMseq,
            materializedUptoMseq: materialized,
            lastDurableEpoch: positions.lastDurableEpoch,
            webContentTerminations: reportedTerminations,
            lastError: lastMismatchDetail ?? machineError ?? lastError,
            hostState: hostState,
            bootDisposition: bootDisposition,
            bootReason: bootReason,
            admission: admission,
            fence: fence,
            budget: budget,
            walBytes: metrics.walBytes,
            journalBytes: metrics.journalBytes,
            nextEpoch: positions.lastDurableEpoch &+ 1,
            stepMetrics: stepMetrics,
            channelMetrics: channelMetrics,
            workerHelloCount: helloCount,
            channelConnectionCount: connectionCount,
            sideEffectEntries: sideEffectEntries,
            ledgerPersistenceError: ledgerPersistenceError,
            turnInactivityStalls: inactivity.stallCount,
            turnInactivityReason: inactivity.lastStallReason,
            turnInactivityTimeout: inactivity.timeout,
            vfsRefusals: vfsRefusals,
            lastVFSRefusal: lastVFSRefusal,
            gatewayMetrics: gatewayMetrics)
        lastSnapshot = snapshot
        return snapshot
    }

    // MARK: - Start internals

    /// `true` when the workspace already contains host or WAL state. The check
    /// runs before recovery mutates the directory, so `cold_start` is reserved
    /// for a genuinely empty workspace (G2-FIX-96).
    private static func workspaceHasState(workspaceRoot: URL) -> Bool {
        let paths = WorkspacePaths(root: workspaceRoot)
        let manager = FileManager.default
        if manager.fileExists(atPath:
            workspaceRoot.appendingPathComponent("host-state.json").path) {
            return true
        }
        if manager.fileExists(atPath: paths.manifestURL.path) { return true }
        if let entries = try? manager.contentsOfDirectory(atPath: paths.walDirectory.path),
           !entries.isEmpty {
            return true
        }
        return false
    }

    /// Resolves the persisted CAS intent before any local admission path.
    ///
    /// A normal intent means the remote may own generation + 1: fail closed and
    /// send the caller to token-based reclaim. A durable definite-rejection
    /// marker is the opposite: the remote changed nothing, so it may be cleared
    /// and the ordinary reset/start path may continue. Cleanup is retried on
    /// every boot; a repeated removal failure is reported but is not allowed to
    /// turn a proven rejection into a permanent local lockout.
    private func resolveHandoffAuthorityIntentForBoot() async throws {
        // A definite rejection observed by this process remains proof even if
        // the durable marker rewrite failed (for example because the path was
        // clobbered or storage is full). Remove the stale unmarked intent so
        // this process can reset; a new process still trusts only what it can
        // read from disk and stays fail-closed.
        if let authority = runtime?.authority,
           await authority.hasUnsavedDefiniteRejectionProof {
            let cleanup: HandoffIntentCleanupOutcome
            do {
                cleanup = try await authority.clearDefinitelyRejectedHandoffIntent()
            } catch {
                eventBus.send(.error(
                    "cannot clear the stale handoff rejection evidence: \(error)"))
                cleanup = .noIntent
            }
            if cleanup == .unmarkedIntentPresent {
                try refuseBootForUnresolvedHandoffIntent(
                    "a different unresolved handoff intent replaced the "
                        + "definite rejection evidence")
            }
        }
        let intent: HandoffAuthorityIntent?
        do {
            intent = try FenceAuthority.loadHandoffAuthorityIntent(
                root: configuration.workspaceRoot)
        } catch {
            try refuseBootForUnresolvedHandoffIntent(
                "the handoff authority evidence is unreadable: \(error)")
        }
        guard let intent else { return }
        guard intent.isDefiniteRejection else {
            try refuseBootForUnresolvedHandoffIntent(
                "a handoff generation CAS is unresolved "
                    + "(expected_generation \(intent.expectedGeneration)); "
                    + "call reclaim() with the App-held token before starting locally")
        }
        // The marker was observed as a definite rejection. A concurrent host
        // may replace it between this read and the cleanup; run the test seam
        // in exactly that window and then let the cleanup itself report an
        // unresolved intent instead of silently returning.
        if let probe = handoffBootIntentProbe {
            do {
                try await probe()
            } catch {
                try refuseBootForUnresolvedHandoffIntent(
                    "the boot intent probe failed: \(error)")
            }
        }
        let cleanup: HandoffIntentCleanupOutcome
        do {
            if let authority = runtime?.authority {
                cleanup = try await authority.clearDefinitelyRejectedHandoffIntent()
            } else {
                cleanup = try FenceAuthority.clearDefinitelyRejectedHandoffIntent(
                    root: configuration.workspaceRoot)
            }
        } catch {
            // The marker itself proves the remote rejected the CAS. Booting is
            // safe; surface the cleanup failure on the ordered event stream and
            // keep retrying on the next boot instead of hiding it. The fresh
            // read below still decides whether an unmarked intent replaced it.
            eventBus.send(.error(
                "cannot clear the definite handoff rejection evidence: \(error)"))
            cleanup = .noIntent
        }
        if cleanup == .unmarkedIntentPresent {
            try refuseBootForUnresolvedHandoffIntent(
                "a different unresolved handoff intent replaced the definite "
                    + "rejection evidence before it could be cleared")
        }
        // Re-read after cleanup. This is the critical guard against a
        // load/clear race: another host may have written a fresh unmarked
        // intent after the definite marker was read. Never boot on the
        // strength of the earlier read alone.
        let remaining: HandoffAuthorityIntent?
        do {
            remaining = try FenceAuthority.loadHandoffAuthorityIntent(
                root: configuration.workspaceRoot)
        } catch {
            try refuseBootForUnresolvedHandoffIntent(
                "the handoff authority evidence is unreadable after cleanup: \(error)")
        }
        if let remaining, !remaining.isDefiniteRejection {
            try refuseBootForUnresolvedHandoffIntent(
                "a handoff generation CAS is unresolved "
                    + "(expected_generation \(remaining.expectedGeneration)); "
                    + "call reclaim() with the App-held token before starting locally")
        }
    }

    private func refuseBootForUnresolvedHandoffIntent(_ message: String) throws
        -> Never {
        lastError = message
        setState(.failed)
        throw PhoneDSHError.invalidState(message)
    }

    /// Opens a new Worker epoch.
    ///
    /// A Worker boot is the point after which no child Activation from the
    /// previous Worker is resident. Resetting the born-before boundary and the
    /// route-reported live set here keeps an orphan child journal from the
    /// previous Worker out of this Worker's teardown verification. The scoped
    /// route can still add a cold-resumed child id back to the live set.
    private func beginWorkerIncarnation() {
        workerIncarnationStartedAt = Date()
        reportedLiveDescendantSessionIDs.removeAll()
        descendantDrainAttemptedRoots.removeAll()
    }

    /// Starts one Worker process identity. D6's `boot_id` is per Worker boot;
    /// the old value is retired so a suspended Worker's late HELLO or reconnect
    /// can never be mistaken for the replacement.
    @discardableResult
    private func beginWorkerBootID() -> String {
        retiredWorkerBootIDs.insert(workerBootID)
        workerBootID = PhoneDSHBootID.make()
        return workerBootID
    }

    /// Starts one park/stop drain window. The early pre-graceful route attempt
    /// and the abort verification pass share this ledger so a successful early
    /// attempt is not reclassified as "never attempted" after the escalation
    /// point. A new park/stop or Worker incarnation starts a fresh window.
    private func beginDescendantDrainWindow() {
        descendantDrainAttemptedRoots.removeAll()
    }

    private func beginStart(userReset: Bool = false) async throws {
        // Boot-phase timing (one line per boot in Documents/boot-timings.log).
        // The engine has several serial phases (WAL replay, journal restore,
        // overlay, loopback, WebContent spawn, Worker boot, HELLO); measuring
        // them is the only way to tell which one dominates a slow start. The
        // phase numbers use foreground-only time: a boot frozen in the
        // background must not report that wall-clock interval as its own work.
        // Both clocks are recorded: `wall=` keeps timestamp reconciliation.
        let bootWallStart = CFAbsoluteTimeGetCurrent()
        let bootActiveStart = foregroundClock.activeMilliseconds()
        bootPhaseRecorder.begin(bootID: bootID,
                                workspaceRoot: configuration.workspaceRoot)
        var bootPhases: [(String, Double)] = []
        func bootMark(_ phase: String) {
            let active = max(0, foregroundClock.activeMilliseconds() - bootActiveStart)
            bootPhases.append((phase, active))
            NSLog("phone-dsh boot: %@ at %.0f ms (foreground)", phase, active)
        }
        func writeBootTimings(_ outcome: String) {
            let wall = max(0, (CFAbsoluteTimeGetCurrent() - bootWallStart) * 1_000)
            let line = "boot \(ISO8601DateFormatter().string(from: Date())) \(outcome) "
                + bootPhases.map { "\($0.0)=\(Int($0.1))ms" }.joined(separator: " ")
                + " wall=\(Int(wall.rounded()))ms\n"
            let url = configuration.workspaceRoot.deletingLastPathComponent()
                .appendingPathComponent("boot-timings.log")
            PhoneDSHBootPhaseRecorder.append(line, to: url)
        }
        var bootOutcome = "failed"
        defer { writeBootTimings(bootOutcome) }
        installMCPEgressCredential()
        // Fail closed before any WAL/manifest work if a previous generation CAS
        // is unresolved. A new process cannot distinguish "the CAS never
        // arrived" from "the remote owns it and the response was lost", so it
        // must not boot over the old phone fence. `reclaim()` (with the App's
        // token vault) or the explicit token entry clears this evidence.
        try await resolveHandoffAuthorityIntentForBoot()
        // A new host and Worker start here. Session journals created before
        // this instant belong to an earlier boot/crash, even when a cold resume
        // reuses the same root session id.
        beginWorkerIncarnation()
        beginWorkerBootID()
        // A fresh host incarnation supersedes a WebContent termination observed
        // before it; the deferred recovery must not fire into this boot.
        pendingRecovery = false
        // ``stop()`` finishes every event subscription; a restarted host
        // publishes on a fresh bus.
        eventBus.reopen()
        setState(.starting)
        do {
            try FileManager.default.createDirectory(at: configuration.workspaceRoot,
                                                    withIntermediateDirectories: true)
            try configuration.validateForStart()
            guard let bundle = configuration.bundle else {
                throw PhoneDSHError.invalidBundle("no bundle is configured")
            }
            guard let bootData = PhoneDSHBootID.data(hex: bootID) else {
                throw PhoneDSHError.invalidBundle("the boot id is not 32 lowercase hex characters")
            }

            // G2-FIX-96: compute the boot disposition input before recovery
            // creates `manifest.json`/WAL structure, so a truly empty workspace
            // stays distinguishable from a crash recovery.
            let workspaceStateBeforeBoot = Self.workspaceHasState(
                workspaceRoot: configuration.workspaceRoot)

            // The single-file budget is resolved once by the facade and wired
            // into the log acceptance check; a caller-mutated `log` value can
            // never silently disagree with the budget table.
            var logConfiguration = configuration.log
            logConfiguration.singleFileLimitBytes = configuration.singleFileLimitBytes
            logConfiguration.vfsQuota = VfsQuota(
                logicalBytes: Int(clamping: configuration.budgets.vfsLogicalBytes),
                workspaceBytes: Int(clamping: configuration.budgets.workspaceBytes),
                sessionBytes: Int(clamping: configuration.budgets.sessionBytes),
                tmpBytes: Int(clamping: configuration.budgets.tmpBytes))
            // Recovery runs inside `WorkspaceLog.init`, so the divergence
            // fallback must wrap the init too — wrapping only `recover()` let a
            // force-kill with an ahead materialized tree bypass the reset and
            // fail the whole boot with WAL_CORRUPT.
            var log: WorkspaceLog
            let recovery: WorkspaceLogRecovery
            do {
                log = try WorkspaceLog(configuration: logConfiguration, bootID: bootData)
                recovery = try await log.recover()
            } catch let error as LogError where error.isMaterializedDivergence {
                // Killed after a materialized write, before the manifest
                // watermark advanced: the materialized tree is the durable
                // output and the retained WAL cannot prove a repair. Adopt the
                // tree, drop the unprovable tail, and boot. Loud, not silent.
                let watermark = try RecoveryReset.adoptMaterializedTree(
                    root: configuration.workspaceRoot)
                NSLog("phone-dsh: adopted the materialized tree at mseq %llu after %@",
                      watermark, String(describing: error))
                log = try WorkspaceLog(configuration: logConfiguration, bootID: bootData)
                recovery = try await log.recover()
            }
            bootMark("recovery")
            let workspaceHasState = workspaceStateBeforeBoot || recovery.nextMseq > 1
            let authority = try FenceAuthority(root: configuration.workspaceRoot,
                                               owner: "phone",
                                               walSeq: recovery.durableMseq)
            let persistedFence = await authority.current
            // A local boot must never reopen admission over a remote fence,
            // even when a crash left the controller in Failed/HandingOff. The
            // D15 return path owns that workspace.
            guard persistedFence.owner == HandoffLimits.phoneOwner else {
                throw PhoneDSHError.invalidState(
                    "the persisted fence is owned by \(persistedFence.owner); "
                        + "call reclaim() (cold recovery with the App-held token) "
                        + "before starting locally")
            }
            if recovery.durableMseq > persistedFence.walSeq {
                _ = try await authority.recordWalSeq(recovery.durableMseq)
            }
            let leaseVerifier = await authority.backoffLeaseVerifier(presented: {
                await authority.wireFence()
            })
            let machine = try HostStateMachine(
                root: configuration.workspaceRoot,
                epochCloser: log,
                leaseVerifier: leaseVerifier,
                drainDeadlineSeconds: configuration.drainDeadline,
                workspaceHasState: workspaceHasState,
                userReset: userReset)
            // Compatibility for a reclaim completed by an earlier crash: the
            // reclaimed phone fence and no unresolved intent prove local
            // authority, but host-state.json can still say `Remote`. A
            // definite-rejection marker is equally non-authoritative (the
            // remote changed nothing) even if its cleanup is still pending.
            // Without this mapping `start()` would refuse forever. Admission
            // stays closed through `Recovering` and the normal lease check.
            let persistedAuthorityIntent = await authority.handoffAuthorityIntent
            if await machine.currentState() == .remote,
               await authority.current.owner == HandoffLimits.phoneOwner,
               persistedAuthorityIntent == nil ||
                   persistedAuthorityIntent?.isDefiniteRejection == true {
                _ = try await machine.handle(.reclaimRequested)
                _ = try await machine.handle(.reclaimResponseApplied)
                _ = try await machine.handle(
                    .reclaimCompleted(fencePersisted: true, epochClosed: true))
            }
            // D24: resolve the restored state before any service is started, so
            // a Backoff refusal needs no teardown and leaves the persisted
            // deadline untouched.
            try await prepareMachineForBoot(machine)
            let stepMachine = try StepMachine(root: configuration.workspaceRoot)
            let ledger = try SideEffectLedger(root: configuration.workspaceRoot)
            let recoveredJournal = await log.recoveredJournalSnapshot()
            // Rebuild identities first, then correlate only explicitly
            // persisted D20 metadata, then replay completion/checkpoint
            // records. This avoids first projecting an accelerator completion
            // as worker-local when its snapshot was lost.
            for body in recoveredJournal where Self.journalType(body.record) == "dispatched" ||
                                               Self.journalType(body.record) == "start" {
                _ = try await stepMachine.observeJournal(body)
            }
            let recoveredPositions = await log.positions()
            for entry in await ledger.allEntries() {
                await ledgerRecorderRestore(stepMachine: stepMachine,
                                            entry: entry,
                                            ackedMseq: recoveredPositions.ackedMseq)
            }
            for body in recoveredJournal where Self.journalType(body.record) != "dispatched" &&
                                               Self.journalType(body.record) != "start" {
                _ = try await stepMachine.observeJournal(body)
            }
            let eventBus = self.eventBus
            let ledgerRecorder = PhoneDSHLedgerRecorder(ledger: ledger,
                                                        stepMachine: stepMachine) { message in
                // The frames still reach the Worker; the App must still learn
                // that a replay after restart would be incomplete.
                eventBus.send(.error("exec ledger persistence failed: \(message)"))
            }
            let budgetMonitor = BudgetMonitor(table: configuration.budgets)
            // ENG-04: the gateway allow-list is always the model upstream plus
            // the Worker egress allow-list (scenario `network.allow` / App
            // settings), never only one of them.
            let gatewayConfiguration = configuration.resolvedGatewayConfiguration()
            let responseLog = try? ModelGateway.makeResponseLog(
                configuration: gatewayConfiguration,
                workspaceRoot: configuration.workspaceRoot)
            // The same boot-timings file carries the loopback and gateway
            // timing lines: a resume stall is diagnosed from one artifact.
            let gatewayDiagnostics = GatewayUpstreamDiagnostics(
                sink: { [bootPhaseRecorder = self.bootPhaseRecorder] line in
                    bootPhaseRecorder.recordDiagnostic(line)
                })
            let gateway = ModelGateway(configuration: gatewayConfiguration,
                                       credentialProvider: configuration.credentialProvider,
                                       responseLog: responseLog,
                                       responseOutcomeHandler: { receipt in
                // The host publishes the bounded terminal outcome on its one
                // ordered event sequence; the gateway never exposes a body.
                eventBus.send(.gatewayResponse(receipt))
            },
                                       egressAuthorizer: configuration.egressAuthorizer,
                                       botEgressApprover: configuration.egressAuthorizer
                                           as? any BotEgressWriteApproving,
                                       officialDeepSeekWebCredentialProvider: configuration.officialDeepSeekWebCredentialProvider,
                                       upstreamDiagnostics: gatewayDiagnostics)
            let coordinator = PhoneDSHChannelCoordinator(eventBus: eventBus)
            // D15: build the facade handoff owner over this exact live log,
            // fence authority and controller. A host without a configured
            // remote endpoint keeps `nil` and refuses beginHandoff() loudly.
            let handoff = try makeHandoffCoordinator(machine: machine,
                                                     authority: authority,
                                                     log: log,
                                                     bootID: bootData)
            bootMark("machine+journal")
            let overlayURL = try await log.overlay(bootID: bootID)
            bootMark("overlay")
            let loopback = makeLoopback(log: log, authority: authority, machine: machine,
                                        coordinator: coordinator, stepMachine: stepMachine,
                                        ledger: ledger, ledgerRecorder: ledgerRecorder,
                                        gateway: gateway, bundle: bundle,
                                        overlayURL: overlayURL)
            let endpoint = try await loopback.start()
            bootMark("loopback")
            let engineConfiguration = makeEngineConfiguration(
                endpoint: endpoint, fence: await authority.wireFence())
            // Install the services before the engine factory runs so that a
            // factory failure still stops the just-started listener.
            self.runtime = RuntimeServices(
                log: log, authority: authority, machine: machine,
                stepMachine: stepMachine, ledger: ledger,
                ledgerRecorder: ledgerRecorder, gateway: gateway,
                responseLog: responseLog, coordinator: coordinator,
                handoff: handoff,
                loopback: loopback, budgetMonitor: budgetMonitor,
                overlayURL: overlayURL, engine: nil,
                engineConfiguration: engineConfiguration)
            // A boot starts from Recovering, before any Worker HELLO; open the
            // replay window here so a request that arrives during the boot can
            // be answered from the response log instead of the upstream.
            gateway.setReplayWindow(open: await machine.currentState() == .recovering)
            startMachineObserver(machine)

            let engine = try await engineFactory(engineConfiguration)
            bootMark("webview")
            lockdownModeObserved = engine.isLockdownModeEnabled
            if var services = self.runtime {
                services.engine = engine
                self.runtime = services
            }
            startEngineObserver(engine)
            try checkEngine(engine)
            await coordinator.beginWorkerBoot(
                expectedBootID: workerBootID,
                retiring: retiredWorkerBootIDs,
                sessionEpoch: sessionEpoch,
                fence: await authority.wireFence())
            try await engine.bootWorker(engineConfiguration)
            if let timings = (engine as? any WebEngineBootPhaseTimingReporting)?
                .bootPhaseTimings() {
                if let navigation = timings.navigationMilliseconds {
                    bootPhases.append(("engine-navigation", navigation))
                }
                if let ready = timings.bootReadyMilliseconds {
                    bootPhases.append(("engine-ready", ready))
                }
            }
            bootMark("worker-boot")
            let hello = try await coordinator.waitForHello(
                after: 0, expecting: workerBootID,
                timeout: configuration.helloTimeout)
            bootMark("hello")
            guard let services = self.runtime else {
                throw PhoneDSHError.invalidState("the host services were released during start")
            }
            try await verifyLease(hello, runtime: services)
            await coordinator.finishWorkerBoot()
            try await sendOpenFrames(hello.connection, runtime: services)
            setState(.running)
            bootMark("running")
            bootOutcome = "ok"
            await evaluateBudget(services)
        } catch {
            if let phoneError = error as? PhoneDSHError,
               case .backoffNotElapsed = phoneError {
                // The persisted Backoff is a healthy wait, not a failure: keep
                // the state and deadline, and let the App retry with start().
                setState(.stopped)
                throw error
            }
            await failClassifying(error, context: "start")
            throw error
        }
    }

    private static func journalType(_ data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return object["type"] as? String ?? object["t"] as? String
    }

    private func ledgerRecorderRestore(stepMachine: StepMachine,
                                       entry: SideEffectEntry,
                                       ackedMseq: UInt64) async {
        guard entry.kind == .exec, let toolKey = entry.toolKey,
              let execID = entry.execID else { return }
        do {
            _ = try await stepMachine.bindAccelerator(
                toolKey: toolKey, execID: execID,
                requiresMseq: entry.requiresMseq ?? 0)
            for text in entry.events {
                guard let event = text.data(using: .utf8) else { continue }
                _ = try await stepMachine.observeExecEvent(toolKey: toolKey,
                                                          execID: execID,
                                                          event: event)
            }
            if let required = entry.requiresMseq {
                _ = try await stepMachine.observeAcceleratorWAL(
                    toolKey: toolKey, execID: execID, requiresMseq: required,
                    ackedMseq: ackedMseq)
            }
        } catch {
            eventBus.send(.error("step evidence recovery failed: \(error)"))
        }
    }

    /// A boot that finds a persisted `Parked` host follows `Parked ->
    /// Recovering` (D14). A persisted `Backoff` host may start once its D24
    /// retry deadline has passed and then follows `Backoff -> Recovering`; a
    /// persisted `Remote`/`HandingOff` state needs the reclaim path first, so a
    /// plain start refuses it. A persisted `Failed` no longer refuses the boot:
    /// `HostStateMachine.bootState(for:)` maps it into the persisted retry
    /// window (`Backoff`, or `Recovering` once it elapsed), and a start before
    /// the window throws ``PhoneDSHError/backoffNotElapsed(_:)`` — a healthy
    /// wait that keeps the persisted state instead of failing the host.
    private func prepareMachineForBoot(_ machine: HostStateMachine) async throws {
        // A `Failed` controller no longer blocks the boot. `bootState(for:)`
        // maps a persisted failure into its retry window (`Backoff` until
        // `next_retry_at_ms`, `Recovering` after it), so a controller that
        // still reports `Failed` here was built in this process: the explicit
        // `start()`/`reset()` that got us here is the retry request, and the
        // reset edge is the controller's only way out of its absorbing state.
        // The normal `Recovering -> Running` lease check still gates admission.
        if await machine.currentState() == .failed {
            _ = try await machine.handle(.userReset)
        }
        switch await machine.currentState() {
        case .recovering:
            return
        case .parked:
            _ = try await machine.handle(.scenePhase(.active))
        case .backoff:
            do {
                _ = try await machine.resumeFromPersistedBackoff()
            } catch let error as HostStateError {
                if case .backoffDeadlineNotReached(let deadline) = error {
                    throw PhoneDSHError.backoffNotElapsed(deadline)
                }
                throw error
            }
            return
        case .remote:
            throw PhoneDSHError.invalidState("reclaim the remote workspace before starting locally")
        default:
            throw PhoneDSHError.invalidState("the controller is not in a bootable state")
        }
    }

    /// Builds the D15 owner over the live workspace and fence authority.
    ///
    /// The coordinator is not a second state machine: it drives the same
    /// ``HostStateMachine`` the facade owns through the landed D14 edges and
    /// uses the live ``WorkspaceLog`` as its snapshot/segment source. The
    /// reclaim applier writes only through the landed WAL/manifest types.
    private func makeHandoffCoordinator(machine: HostStateMachine,
                                        authority: FenceAuthority,
                                        log: WorkspaceLog,
                                        bootID: Data) throws -> HandoffCoordinator? {
        guard let handoffConfiguration = configuration.handoff else { return nil }
        let client: HandoffClient
        do {
            client = try HandoffClient(
                configuration: handoffConfiguration,
                transport: handoffTransport ?? URLSessionHandoffTransport(),
                credentialProvider: configuration.credentialProvider)
        } catch let error as HandoffError {
            throw PhoneDSHError.invalidConfiguration(
                "the handoff client configuration is unusable: \(error)")
        } catch {
            throw PhoneDSHError.invalidConfiguration(
                "the handoff client could not be created: \(error)")
        }
        let applier: WorkspaceLogSegmentApplier
        do {
            applier = try WorkspaceLogSegmentApplier(
                root: configuration.workspaceRoot,
                configuration: configuration.log,
                bootID: bootID)
        } catch {
            throw PhoneDSHError.invalidConfiguration(
                "the handoff applier cannot be configured: \(error)")
        }
        let fences = FenceAuthorityHandoffStore(authority: authority)
        let reclaimClient = ReclaimClient(client: client,
                                          applier: applier,
                                          fences: fences,
                                          tokenStore: reclaimTokenStore)
        return HandoffCoordinator(
            machine: machine,
            fences: fences,
            source: WorkspaceLogHandoffSource(log: log),
            client: client,
            reclaimClient: reclaimClient)
    }

    private func makeLoopback(log: WorkspaceLog,
                              authority: FenceAuthority,
                              machine: HostStateMachine,
                              coordinator: PhoneDSHChannelCoordinator,
                              stepMachine: StepMachine,
                              ledger: SideEffectLedger,
                              ledgerRecorder: PhoneDSHLedgerRecorder,
                              gateway: ModelGateway,
                              bundle: PhoneDSHBundleLocation,
                              overlayURL: URL) -> LoopbackServer {
        let workspaceLog = PhoneDSHWorkspaceLogBridge(log: log)
        let journalLog = PhoneDSHJournalBridge(log: log, coordinator: coordinator)
        let execProvider: any ExecProvider = configuration.execProvider ?? configuration.accelerators
        let accelerators = configuration.acceleratorNames
        let admission: @Sendable () async -> Admission = { machine.admission.current }
        let routes = LoopbackRoutes(
            staticDirectory: bundle.staticDirectory,
            imageBaseURL: bundle.imageArchive,
            lazyImageProvider: { sha in
                guard sha.count == 64 else { return nil }
                let url = bundle.lazyDirectory.appendingPathComponent("\(sha).tar.gz")
                return FileManager.default.fileExists(atPath: url.path) ? url : nil
            },
            overlayProvider: { _ in overlayURL },
            httpEgress: PhoneDSHGatewayEgress(gateway: gateway),
            execBridge: nil,
            mcpBaseURL: configuration.mcpLoopbackURL,
            nativeMCP: configuration.nativeMCP,
            execProvider: execProvider,
            workspaceLog: workspaceLog,
            journalLog: journalLog,
            accelerators: accelerators,
            mounts: [:],
            admission: admission)
        let machineAdmission = admission
        let eventBus = self.eventBus
        let bootID = self.bootID
        let sessionEpoch = self.sessionEpoch
        // Loopback timing evidence lands in the same `boot-timings.log` the
        // Worker phase recorder owns: those two streams are read together.
        let requestDiagnostics = LoopbackRequestDiagnostics(
            sink: { [bootPhaseRecorder = self.bootPhaseRecorder] line in
                bootPhaseRecorder.recordDiagnostic(line)
            })
        return LoopbackServer(
            configuration: configuration.loopback,
            routes: routes,
            channelStateProvider: {
                let positions = await log.positions()
                let fence = await authority.wireFence()
                return ChannelHostState(bootID: bootID,
                                        sessionEpoch: sessionEpoch,
                                        fence: fence,
                                        caps: [],
                                        ackedMseq: positions.ackedMseq,
                                        durableMseq: positions.durableMseq)
            },
            channelHandlerFactory: { outbound in
                // `LoopbackServer` always hands its own ChannelServer to the
                // factory (loopback.md §9); the cast documents that contract.
                guard let server = outbound as? ChannelServer else {
                    return PhoneDSHUnavailableChannelHandler()
                }
                let connection = PhoneDSHConnection(id: UUID(), server: server,
                                                    coordinator: coordinator)
                Task { await coordinator.register(connection) }
                // D10: the persisted ledger sits in front of the in-memory
                // default handler, records every emitted EXEC_EVT, and reports
                // persistence failures through the shared recorder.
                let delegate = DefaultChannelHandling(
                    outbound: PhoneDSHLedgerOutbound(base: outbound,
                                                     recorder: ledgerRecorder),
                    workspaceLog: workspaceLog,
                    journalLog: nil,
                    execProvider: execProvider,
                    accelerators: accelerators,
                    admission: machineAdmission)
                let ledgerHandler = PhoneDSHLedgerChannelHandling(
                    delegate: delegate,
                    ledger: ledger,
                    outbound: outbound,
                    recorder: ledgerRecorder)
                return PhoneDSHChannelHandler(connection: connection,
                                              delegate: ledgerHandler,
                                              coordinator: coordinator,
                                              stepMachine: stepMachine,
                                              eventBus: eventBus,
                                              bootPhaseRecorder: { [bootPhaseRecorder = self.bootPhaseRecorder] phase in
                                                  bootPhaseRecorder.record(phase)
                                              })
            },
            requestDiagnostics: requestDiagnostics)
    }

    private func makeEngineConfiguration(endpoint: LoopbackEndpoint,
                                         fence: Fence) -> WebEngineConfiguration {
        var engineConfiguration = configuration.engine
        engineConfiguration.origin = endpoint.baseURL
        engineConfiguration.token = endpoint.token
        // D6: the page/Worker `boot_id` names this Worker process, not the
        // host incarnation. The host id stays in `ChannelHostState.bootID`
        // and in the overlay path.
        engineConfiguration.bootID = workerBootID
        engineConfiguration.sessionEpoch = sessionEpoch
        // The loopback serves the bundle's static directory under `/static/*`
        // (`/` redirects to the same file by name). `PhoneDSHConfiguration`
        // starts from `WebEngineConfiguration`'s default (`/index.html`), so
        // that value is the "caller did not choose" sentinel rather than a
        // served path on this loopback. Native callers (ChatModel, smoke and
        // kill suites) use that default and must keep the historical bootstrap
        // `/static/index.html` even when the complete Web page is staged. The
        // App's complete-Web surface selects `/static/web/index.html`
        // explicitly through WebHostConfiguration; an explicit page path is an
        // integration contract and is never replaced here.
        let requestedPagePath = engineConfiguration.pagePath
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if requestedPagePath.isEmpty
            || requestedPagePath == WebEngineConfiguration.defaultPagePath {
            engineConfiguration.pagePath = "/static/index.html"
        } else {
            engineConfiguration.pagePath = requestedPagePath.hasPrefix("/")
                ? requestedPagePath : "/" + requestedPagePath
        }
        engineConfiguration.imagePath = "/image/base"
        engineConfiguration.channelPath = "/channel"
        engineConfiguration.workerPath = "/static/"
            + (configuration.bundle?.workerEntry.lastPathComponent ?? "worker-entry.js")
        engineConfiguration.overlays = []
        engineConfiguration.fence = WebEngineFence(owner: fence.owner,
                                                   generation: fence.generation,
                                                   walSeq: fence.walSeq)
        // D24: the host derives the Worker environment from the bound
        // listener, so the App no longer fills `engine.environment` by hand.
        // Entries the App did set still win (an explicit override).
        var environment = Self.workerEnvironment(
            endpoint: endpoint,
            channelPath: engineConfiguration.channelPath,
            mcpEgressToken: mcpEgressToken,
            overrides: configuration.engine.environment)
        Self.applyConfiguredMCPEnvironment(&environment, endpoint: endpoint,
                                           nativeMCP: configuration.nativeMCP)
        // ENG-05 reads this to state the real per-file budget in the Worker's
        // capability manifest; an explicit App override still wins.
        if environment[PhoneDSHWorkerEnvironment.singleFileLimit] == nil {
            environment[PhoneDSHWorkerEnvironment.singleFileLimit] =
                String(configuration.singleFileLimitBytes)
        }
        // The 12 GiB row publishes 640 MiB hot instances; the 8 GiB default
        // stays 260 MiB. The entry merges this into the manifest and the tool
        // workers' memory ceiling.
        if environment[PhoneDSHWorkerEnvironment.wasiHotInstanceBytes] == nil {
            environment[PhoneDSHWorkerEnvironment.wasiHotInstanceBytes] =
                String(configuration.budgets.wasiHotInstanceBytes)
        }
        // The capability manifest and the write-time VFS quota must publish
        // one set of numbers; both derive from the same BudgetTable row.
        let vfsEnvironment: [(String, Int)] = [
            (PhoneDSHWorkerEnvironment.vfsLogicalBytes, configuration.budgets.vfsLogicalBytes),
            (PhoneDSHWorkerEnvironment.vfsWorkspaceBytes, configuration.budgets.workspaceBytes),
            (PhoneDSHWorkerEnvironment.vfsSessionsBytes, configuration.budgets.sessionBytes),
            (PhoneDSHWorkerEnvironment.vfsTmpBytes, configuration.budgets.tmpBytes),
        ]
        for (key, value) in vfsEnvironment where environment[key] == nil {
            environment[key] = String(value)
        }
        // The capability manifest states which hosts `curl` may reach so the
        // agent does not have to probe; the gateway still enforces the union.
        // An explicit App override still wins.
        if environment[PhoneDSHWorkerEnvironment.egressAllow] == nil,
           let egress = Self.egressAllowEnvironmentValue(configuration.egressAllowHosts) {
            environment[PhoneDSHWorkerEnvironment.egressAllow] = egress
        }
        engineConfiguration.environment = environment
        return engineConfiguration
    }

    /// `PDSH_EGRESS_ALLOW` for the Worker: the configured egress hosts in a
    /// stable order, or `nil` when the App admitted none (the Worker then says
    /// "not reported" instead of claiming an empty list).
    static func egressAllowEnvironmentValue(_ hosts: Set<String>) -> String? {
        let entries = hosts
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .sorted()
        return entries.isEmpty ? nil : entries.joined(separator: ",")
    }

    /// Installs this host run's egress credential on the exact-route policy
    /// that the gateway consults. The policy is the one object that both
    /// authorises MCP credential injection and checks the hop header; a host
    /// without an MCP policy leaves the gate with nothing to protect.
    private func installMCPEgressCredential() {
        (configuration.egressAuthorizer as? any MCPEgressGating)?
            .setMCPEgressToken(mcpEgressToken)
    }

    /// The D24 Worker environment injected into the page's `?env=` boot input.
    ///
    /// `PDSH_DSH_LAUNCH_TOKEN` is the token the resident phone surface expects;
    /// the channel/gateway values are the llm-bridge route the Worker uses to
    /// reach `/v1/http`. `PDSH_MCP_EGRESS_TOKEN` is this host run's trusted-MCP
    /// egress credential (spec/bot/v1/mcp-endpoint.md §1.1); it is written after
    /// the App overrides so the value the host validates cannot be replaced by a
    /// persisted/App-supplied one. The App's other entries are merged before it.
    static func workerEnvironment(endpoint: LoopbackEndpoint,
                                  channelPath: String,
                                  mcpEgressToken: String,
                                  overrides: [String: String]) -> [String: String] {
        let origin = endpoint.baseURL.absoluteString
        var environment: [String: String] = [
            PhoneDSHWorkerEnvironment.launchToken: endpoint.token,
            PhoneDSHWorkerEnvironment.channelToken: endpoint.token,
            PhoneDSHWorkerEnvironment.channelURL: websocketURL(base: endpoint.baseURL,
                                                               path: channelPath),
            PhoneDSHWorkerEnvironment.gatewayURL: origin,
        ]
        environment.merge(overrides) { _, app in app }
        environment[PhoneDSHWorkerEnvironment.mcpEgressToken] = mcpEgressToken
        return environment
    }

    /// One owner for the `phone` MCP env. When the App supplied a Bot MCP
    /// endpoint it is the Worker's only phone server and forwards native tools
    /// in-process; nativeMCP stays available at `/mcp/native` for other
    /// callers but must not overwrite the Bot URL. Only a native-only
    /// configuration (no App endpoint) keeps the legacy `/mcp/native` env.
    static func applyConfiguredMCPEnvironment(_ environment: inout [String: String],
                                              endpoint: LoopbackEndpoint,
                                              nativeMCP: (any NativeMCPServing)?) {
        guard nativeMCP != nil, environment["PDSH_PHONE_MCP_URL"] == nil else { return }
        applyNativeMCPEnvironment(&environment, endpoint: endpoint)
    }

    /// The legacy native-only Worker endpoint. Exposed so the regression test
    /// can prove the Bot endpoint wins when both are configured.
    static func applyNativeMCPEnvironment(_ environment: inout [String: String],
                                          endpoint: LoopbackEndpoint) {
        environment["PDSH_PHONE_MCP_URL"] =
            endpoint.baseURL.appendingPathComponent("mcp/native").absoluteString
        environment["PDSH_PHONE_MCP_TOKEN"] = endpoint.token
    }

    private static func websocketURL(base: URL, path: String) -> String {
        guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
            return base.absoluteString + (path.hasPrefix("/") ? path : "/" + path)
        }
        switch components.scheme?.lowercased() {
        case "https": components.scheme = "wss"
        default: components.scheme = "ws"
        }
        components.path = path.hasPrefix("/") ? path : "/" + path
        components.query = nil
        return components.string ?? base.absoluteString
    }

    private func checkEngine(_ engine: any WebEngineControlling) throws {
        if engine.isLockdownModeEnabled { throw PhoneDSHError.lockdownMode }
        if !engine.isAttachedWithVisibleArea { throw PhoneDSHError.engineNotAttached }
    }

    private func verifyLease(_ hello: PhoneDSHHelloResult,
                             runtime: RuntimeServices) async throws {
        do {
            try await runtime.authority.validate(hello.hello.fence)
        } catch {
            throw PhoneDSHError.leaseRejected(String(describing: error))
        }
        guard await runtime.machine.currentState() == .recovering else {
            throw PhoneDSHError.invalidState("the controller is not recovering")
        }
        try await runtime.machine.verifyLease()
    }

    private func sendOpenFrames(_ connection: PhoneDSHConnection,
                                runtime: RuntimeServices) async throws {
        let fence = await runtime.authority.wireFence()
        try await connection.sendFence(FencePayload(fence: fence, admission: .open))
        try await connection.sendLifecycle(LifecyclePayload(state: .run,
                                                            budget: 0,
                                                            admission: .open,
                                                            reason: "foreground"))
    }

    /// Tears the Worker-facing channel down and seals the WAL at the tail.
    ///
    /// G2-FIX-17: the controller's drain closes the epoch while the loopback is
    /// still live, so a VFS sink mutation accepted in the drain window opens a
    /// *new* epoch that nobody closes. The manifest then keeps the old durable
    /// epoch and `fence.wal_seq` (taken from `durableMseq`) stays below the
    /// on-disk tail. The listener and every connection are stopped first — no
    /// new frame can be admitted — then the host waits for the write-direction
    /// handlers that were already in flight, closes every epoch opened behind
    /// the close in the D18 order, and only then records `fence.wal_seq` at the
    /// tail. A close/record failure fails loud instead of silently parking.
    private func closeRuntimeForPark(_ runtime: RuntimeServices) async throws {
        parking = false
        engineObserver?.cancel()
        engineObserver = nil
        // A parked host has no live page: remove the WKWebView before the host
        // drops its reference. Otherwise the view stays in the App's anchor
        // hierarchy and its WebContent process survives the next resume.
        await shutdownEngineBestEffort(runtime.engine)
        if var services = self.runtime {
            services.engine = nil
            self.runtime = services
        }
        await runtime.loopback.stop()
        // No frame can arrive now; let the handlers that were already
        // dispatching finish so the seal observes their WAL tail.
        _ = await runtime.coordinator.waitForInboundWritesToQuiesce()
        try await sealEpochAtTailAndRecordFence(runtime)
        await runtime.coordinator.prepareForReboot()
        setState(.stopped)
        lastSnapshot = await diagnostics()
    }

    /// Post-teardown seal: the durable WAL tail and `fence.wal_seq` must be the
    /// same number, and the manifest must list the closed tail epoch.
    ///
    /// The caller must already have stopped the mutation source (loopback).
    private func sealEpochAtTailAndRecordFence(
        _ runtime: RuntimeServices) async throws {
        let ack: WorkspaceLogAck
        do {
            ack = try await runtime.log.sealEpochCoveringTail()
        } catch let logError as LogError {
            // D18: the durable tail evidence cannot be repaired by trying
            // again, so a failed seal is a workspace fault. Wrapping it in
            // `PhoneDSHError.invalidState` (as this used to) classified it as a
            // retryable boot failure and let the host park a fence that is
            // below the WAL tail.
            throw HostFault.workspace(.log(logError))
        } catch {
            throw PhoneDSHError.invalidState(
                "the WAL epoch close after the drain failed: \(error)")
        }
        let positions = await runtime.log.positions()
        guard positions.durableMseq >= positions.ackedMseq else {
            throw HostFault.workspace(.log(.epochCoverageFailed(
                "the WAL tail \(positions.ackedMseq) is above durable_upto "
                    + "\(positions.durableMseq) after the epoch close")))
        }
        let target = max(ack.uptoMseq, positions.durableMseq)
        do {
            let fence = await runtime.authority.current
            if target > fence.walSeq {
                _ = try await runtime.authority.recordWalSeq(target)
            }
            let recorded = await runtime.authority.current
            guard recorded.walSeq == positions.ackedMseq else {
                throw PhoneDSHError.invalidState(
                    "fence.wal_seq \(recorded.walSeq) does not cover the WAL tail "
                        + "\(positions.ackedMseq) after parking")
            }
        } catch let error as PhoneDSHError {
            throw error
        } catch {
            throw PhoneDSHError.invalidState(
                "cannot record the WAL watermark in fence.json: \(error)")
        }
    }

    /// Seal used by the D24 planned restart after the controller closed the
    /// epoch. The old Worker channel may still deliver a frame, so this only
    /// requires that the close it performed covers the tail at that instant;
    /// a later frame opens the next (regular, open) epoch.
    private func sealEpochAfterControllerClose(
        _ runtime: RuntimeServices) async throws {
        let ack: WorkspaceLogAck
        do {
            ack = try await runtime.log.sealEpochCoveringTail()
        } catch let logError as LogError {
            // Same D18 rule as `sealEpochAtTailAndRecordFence`: a failed seal
            // is durable evidence that a retry cannot repair.
            throw HostFault.workspace(.log(logError))
        } catch {
            throw PhoneDSHError.invalidState(
                "the WAL epoch close for the planned restart failed: \(error)")
        }
        let fence = await runtime.authority.current
        if ack.uptoMseq > fence.walSeq {
            do {
                _ = try await runtime.authority.recordWalSeq(ack.uptoMseq)
            } catch {
                throw PhoneDSHError.invalidState(
                    "cannot record the WAL watermark in fence.json: \(error)")
            }
        }
    }

    // MARK: - Failure

    /// Fails this incarnation with the blast radius of a typed ``HostFault``.
    ///
    /// - `.boot` sends `.failure(reason:class: .transient)`: the controller
    ///   moves to its persisted `Backoff` and the host stays retryable. A
    ///   killed WebContent, a replacement Worker that answered a non-HELLO
    ///   first frame (`PROTO_MISMATCH`) or a lost channel can never persist
    ///   `failed` again.
    /// - `.workspace` sends `.terminal`: the condition holds across a process,
    ///   so this incarnation fails loud (the persisted retry window still lets
    ///   the next boot try again).
    ///
    /// Both classifications keep the existing abort teardown: admission
    /// closes, the loopback stops, the channel drops its connections and the
    /// WAL is sealed at the accepted tail.
    private func fail(_ fault: HostFault, shutdownEngine: Bool = true) async {
        let message = fault.description
        lastError = message
        lastMismatchDetail = message.contains("unrepaired base mismatch") ? message : nil
        eventBus.send(.error(message))
        if let runtime {
            // Failed/Backoff is not a recovery window: never serve a replay
            // from a host that has given up on this incarnation.
            runtime.gateway.setReplayWindow(open: false)
            if await runtime.machine.currentState() != .failed {
                _ = try? await runtime.machine.handle(
                    .failure(reason: message, class: fault.failureClass))
            } else {
                // A controller transition (for example the drain deadline's
                // epoch close) may already have failed with a wrapped reason.
                // The host's message carries the wal.md §5.2 path/mseq detail;
                // record it as the controller's failure detail too.
                await runtime.machine.escalateFailureToTerminal(reason: message)
            }
            engineObserver?.cancel()
            engineObserver = nil
            // The failed engine may still own a WKWebView (and its WebContent
            // process). Shut it down before dropping the reference, so a
            // retry cannot leave the old page alive beside the new one. The
            // handoff path owns its own two-phase stop and its regressions
            // assert that a refused/cancelled stop never adds a shutdown.
            if shutdownEngine, !fault.isHandoff {
                await shutdownEngineBestEffort(self.runtime?.engine)
            }
            await runtime.loopback.stop()
            _ = await runtime.coordinator.waitForInboundWritesToQuiesce()
            await runtime.coordinator.prepareForReboot()
            // The abort/failed teardown is terminal for this incarnation. Seal
            // the accepted tail in the D18 order and verify the materialized
            // copy: a Failed host must still leave a manifest that lists the
            // real WAL, never an open epoch whose records recovery would then
            // classify as stale. A seal failure keeps the host Failed and is
            // reported, never swallowed.
            do {
                if let failureSealProbeForTesting {
                    try await failureSealProbeForTesting()
                }
                _ = try await runtime.log.sealForStop()
            } catch {
                let sealMessage = "the WAL stop seal failed: \(error)"
                let combined = (lastError.map { "\($0); " } ?? "") + sealMessage
                lastError = combined
                if combined.contains("unrepaired base mismatch") {
                    lastMismatchDetail = combined
                }
                eventBus.send(.error(sealMessage))
                if await runtime.machine.currentState() != .failed {
                    await runtime.machine.escalateFailureToTerminal(reason: combined)
                }
            }
            if var services = self.runtime {
                services.engine = nil
                self.runtime = services
            }
        }
        // Mirror the controller instead of assuming `failed`: a transient
        // failure left it in `Backoff`, whose facade state is `starting`.
        if let runtime {
            setState(Self.facadeState(for: await runtime.machine.currentState()))
        } else {
            // No controller to ask: keep `start()` able to retry a boot fault
            // (`.stopped`) and surface a workspace fault as failed.
            setState(fault.isBoot ? .stopped : .failed)
        }
    }

    /// Routes one caught error through ``HostFault/classify(_:)``.
    ///
    /// A classified value becomes a typed ``HostFault`` and goes to
    /// ``fail(_:)``. A `nil` classification is either a documented
    /// non-failure (a superseded boot, a VFS resource refusal, a host that is
    /// already failed or backing off) or an unknown defect: the former is
    /// reported and leaves the host alone, the latter keeps the caller's
    /// fail-loud teardown (`unknownIsFailure`) because an unexpected error must
    /// not silently leave a half-booted host.
    private func failClassifying(_ error: Error,
                                 context: String,
                                 unknownIsFailure: Bool = true,
                                 shutdownEngine: Bool = true) async {
        if let fault = HostFault.classify(error) {
            await fail(fault, shutdownEngine: shutdownEngine)
            return
        }
        if HostFault.isBenign(error) {
            eventBus.send(.error("\(context): \(error) (not a host failure)"))
            return
        }
        guard unknownIsFailure else { return }
        await fail(.boot(.unclassified("\(context): \(error)")),
                  shutdownEngine: shutdownEngine)
    }

    /// Acquires the one exclusive lifecycle/handoff operation before the
    /// actor can suspend. A concurrent operation is refused with
    /// ``PhoneDSHError/invalidState(_:)``; it never waits on the actor and
    /// therefore cannot sneak into a handoff's network/drain window.
    private func beginExclusiveOperation(_ operation: ExclusiveOperation) throws {
        guard let current = exclusiveOperation else {
            exclusiveOperation = operation
            return
        }
        if current == .handoff || current == .reclaim {
            throw PhoneDSHError.invalidState(
                "another handoff operation is in flight")
        }
        throw PhoneDSHError.invalidState(
            "\(current.rawValue) is already in progress")
    }

    private func endExclusiveOperation(_ operation: ExclusiveOperation) {
        if exclusiveOperation == operation { exclusiveOperation = nil }
    }

    /// Whether this runtime's persisted fence or D15 owner is remote. A local
    /// start/resume/reset must refuse instead of opening admission over the
    /// remote authority.
    private func hasRemoteAuthority(_ runtime: RuntimeServices) async -> Bool {
        let fence = await runtime.authority.current
        if fence.owner != HandoffLimits.phoneOwner { return true }
        let controller = await runtime.machine.currentState()
        if controller == .remote || controller == .reclaiming { return true }
        if let handoff = runtime.handoff {
            let phase = await handoff.phase
            if phase == .remote || phase == .reclaiming { return true }
        }
        return false
    }

    // MARK: - Observation

    private func startMachineObserver(_ machine: HostStateMachine) {
        machineObserver?.cancel()
        machineObserver = Task { [weak self] in
            for await record in machine.transitions() {
                guard let self else { return }
                await self.handle(transition: record)
            }
        }
    }

    private func startEngineObserver(_ engine: any WebEngineControlling) {
        engineObserver?.cancel()
        engineObserver = nil
        guard let source = engine as? PhoneDSHEngineEventSource else { return }
        engineObserver = Task { [weak self] in
            for await event in source.phoneDSHEvents() {
                guard let self else { return }
                await self.handle(engineEvent: event)
            }
        }
    }

    private func handle(transition record: HostTransitionRecord) async {
        // Recovering is the only state in which a previously committed model
        // response may be replayed. A planned restart, a WebContent
        // termination and a user reset all re-enter it, so this one observer
        // re-opens the window without any caller having to open it by hand.
        runtime?.gateway.setReplayWindow(open: record.to == .recovering)
        eventBus.send(.hostTransition(record))
        if record.to == .failed, let runtime {
            let machineError = await runtime.machine.lastError
            lastError = lastMismatchDetail ?? machineError
        }
        // `Running` is the healthy state; a host that recovered on its own must
        // not keep reporting the reason it failed earlier.
        if record.to == .running {
            lastError = nil
            lastMismatchDetail = nil
        }
        setState(Self.facadeState(for: record.to))
    }

    private func handle(engineEvent event: WebEngineEvent) async {
        switch event {
        case .consoleLine(let line):
            if let phase = PhoneDSHBootPhase.parse(line.text) {
                bootPhaseRecorder.record(phase)
            }
            eventBus.send(.console(ConsolePayload(level: line.level.channelLevel,
                                                  text: line.text)))
        case .terminated(let count):
            terminations = max(terminations, count)
            eventBus.send(.webContentTerminated(count))
            if !parking { await recoverAfterTermination(count) }
        case .restarted(let report):
            publishRestart(report)
        case .bootReady, .loaded:
            break
        }
    }

    /// Publishes one `.restarted` event per completed engine boot.
    ///
    /// Planned restarts see the report twice (engine event plus the restart
    /// call's return value); the boot id keys the same restart, so only the
    /// first copy reaches subscribers. Termination recovery has no host-side
    /// copy and passes through unchanged.
    private func publishRestart(_ report: WebEngineRestartReport) {
        guard publishedRestartBootIDs.insert(report.bootID).inserted else { return }
        eventBus.send(.restarted(report))
    }

    /// Installs the host's own process-lifecycle observer (P1).
    ///
    /// Idempotent, and installed by ``start()`` rather than left to the App:
    /// the safety rule "do not boot WebContent from the background" must not
    /// depend on every App remembering to forward `scenePhase`. On iOS the
    /// current phase is emitted at install time so a host created in the
    /// background cannot inherit the foreground default.
    ///
    /// The observer maps every phase other than `.active` (including
    /// `.inactive`) to `setForeground(false)`, so a call, a system dialog or the
    /// app switcher stops a deferred termination recovery from booting here.
    /// That is deliberately narrower than parking: this observer never calls
    /// ``park()`` or ``resume()``. A caller that parks on leaving the foreground
    /// (the probe app's `ChatModel`) decides from the same phases, and the two
    /// must not disagree about who owns the host. A host that caller does not
    /// park keeps running while `isForeground` is false; the background-boot
    /// gate still holds.
    private func installProcessLifecycleObservation() {
        guard processLifecycle == nil else { return }
        let observer = PhoneDSHProcessLifecycle()
        #if canImport(UIKit) && os(iOS)
        observer.start { [weak self] phase in
            Task { await self?.applyPlatformForeground(phase == .active) }
        }
        #else
        observer.start(emitCurrentPhase: false) { [weak self] phase in
            Task { await self?.applyPlatformForeground(phase == .active) }
        }
        #endif
        processLifecycle = observer
    }

    /// Tells the host whether the App is in the foreground.
    ///
    /// A WebContent termination observed in the background only records the
    /// recovery intent (P6: a Worker boot, WAL replay and epoch reopen need the
    /// App to be foreground and not about to be reclaimed). This is where that
    /// intent is consumed: switching to the foreground re-drives the ordinary
    /// termination recovery with the real phase. Every other state is a no-op,
    /// so an App that never reports the phase keeps the old behaviour
    /// (`isForeground` defaults to `true`).
    public func setForeground(_ foreground: Bool) async {
        await applyForeground(foreground, cancelResume: true)
    }

    /// Platform lifecycle observation keeps the recovery gate truthful without
    /// cancelling a resume. On macOS an XCTest process is hidden/backgrounded by
    /// the window server even though no App scene transition happened, and a
    /// test must be able to drive the App phase explicitly. The App's own scene
    /// phase reaches ``setForeground(_:)`` through its scene observer.
    private func applyPlatformForeground(_ foreground: Bool) async {
        await applyForeground(foreground, cancelResume: false)
    }

    private func applyForeground(_ foreground: Bool,
                                 cancelResume: Bool) async {
        isForeground = foreground
        foregroundClock.setForeground(foreground)
        if !foreground {
            if cancelResume, let cancellation = activeResumeCancellation {
                // Leaving the foreground cancels an in-flight resume. Shut the
                // page down directly instead of racing a task group over the
                // WebSocket: the boot call returns with a superseded-navigation
                // error, and the resume catch releases the exclusive gate.
                cancellation.cancel()
                if let engine = activeResumeEngine {
                    await shutdownEngineBestEffort(engine)
                }
                if let coordinator = runtime?.coordinator {
                    await coordinator.prepareForReboot()
                }
            }
            return
        }
        guard pendingRecovery else { return }
        await consumePendingRecovery()
    }

    /// Consumes one deferred WebContent recovery.
    ///
    /// The intent survives an operation that owned the lifecycle when the App
    /// returned to the foreground; it is dropped when the controller is no
    /// longer bootable (a park/resume/reset/handoff took over) or when the host
    /// has no live services (a stopped host has to be started again). A
    /// background termination whose edge the controller refused (its table can
    /// still require the foreground) is retried here with the real phase
    /// through ``recoverAfterTermination(_:)``.
    private func consumePendingRecovery() async {
        guard pendingRecovery else { return }
        guard exclusiveOperation == nil, !parking, !restarting,
              !recoveringTermination else {
            // Keep the intent for the next foreground call instead of racing
            // the operation that owns the controller.
            return
        }
        guard let runtime, state != .stopped else {
            pendingRecovery = false
            return
        }
        let controller = await runtime.machine.currentState()
        guard controller == .recovering || controller == .running
                || controller == .draining else {
            pendingRecovery = false
            return
        }
        pendingRecovery = false
        await recoverAfterTermination(terminations)
    }

    private func recoverAfterTermination(_ count: UInt64) async {
        // A terminated WebContent must not inject a recovery boot into a
        // handoff, park, restart or stop that already owns the lifecycle.
        guard exclusiveOperation == nil else { return }
        guard let runtime else { return }
        guard !parking, !restarting, !recoveringTermination else { return }
        // Claim the recovery before the first suspension: a second termination
        // delivered while this one awaits the controller must not start a
        // competing Worker. Every early return below releases the claim.
        recoveringTermination = true
        defer { recoveringTermination = false }
        let current = await runtime.machine.currentState()
        guard current == .running || current == .draining || current == .recovering
        else { return }
        if current != .recovering {
            // Pass the real phase instead of the hard-coded `true`: the
            // controller owns whether a background termination may close
            // admission for recovery.
            _ = try? await runtime.machine.handle(
                .webContentTerminated(WebContentTermination(
                    wasForeground: isForeground, terminationCount: count)))
        }
        guard await runtime.machine.currentState() == .recovering else {
            // The controller refused the edge for this phase. The intent to
            // recover still has to survive until the App is foreground again.
            if !isForeground { pendingRecovery = true }
            return
        }
        guard isForeground else {
            // P6: never boot a WebContent process, replay the WAL or reopen an
            // epoch in the background. Record the intent; the foreground
            // return consumes it.
            pendingRecovery = true
            return
        }
        pendingRecovery = false
        await runTerminationRecovery(runtime)
    }

    /// Runs the replacement-Worker recovery for a controller in `Recovering`.
    ///
    /// A `.boot`-class failure is retried inside ``bootReplacementWorker``;
    /// only an exhausted retry budget reaches ``fail(_:)``, and that failure is
    /// `.boot` (transient → `Backoff`), never a persisted `failed`. The caller
    /// owns ``recoveringTermination``.
    private func runTerminationRecovery(_ runtime: RuntimeServices) async {
        setState(.starting)
        do {
            // The termination recovery boots a new Worker. A child Activation
            // from the terminated Worker cannot survive into it; an old child
            // journal must not be treated as this Worker's live descendant
            // (cutoff before the new boot for a termination).
            _ = try await bootReplacementWorker(
                runtime,
                reason: .webContentTerminated,
                orphanReason: "worker-terminated",
                incarnationCutoffAfterBoot: false,
                publishReportImmediately: true)
            setState(.running)
            await evaluateBudget(runtime)
        } catch {
            // A recovery that cannot reach a new Worker still must not leave
            // the step records permanently open; settle them before failing
            // loud. The original recovery error remains the reported one.
            do {
                let settled = try await runtime.stepMachine.settleOrphans(
                    reason: "worker-terminated")
                publishOrphanSettlement(settled, reason: "worker-terminated")
            } catch {
                // The recovery failure below is the actionable error.
            }
            await failClassifying(error, context: "worker termination recovery")
        }
    }

    // MARK: - Replacement Worker boot (bounded retry)

    /// One boot attempt's share of the host HELLO budget.
    ///
    /// A retry sequence may spend at most one `helloTimeout` waiting for HELLO
    /// in total. The first attempt that actually reaches the wait arms the
    /// deadline; a later attempt only gets what is left. A Worker that consumed
    /// the whole budget by not answering therefore is not granted the same
    /// budget twice, while a fast bootstrap failure (the `PROTO_MISMATCH` case,
    /// which fails before HELLO) keeps both retries.
    private final class BootHelloBudget {
        private var deadline: Date?

        /// Remaining wait for the next `waitForHello`, capped at
        /// `helloTimeout`; the first call arms the shared deadline.
        func timeout(helloTimeout: TimeInterval) -> TimeInterval {
            let budget = max(0, helloTimeout)
            if let deadline {
                return max(0, min(budget, deadline.timeIntervalSinceNow))
            }
            deadline = Date().addingTimeInterval(budget)
            return budget
        }

        /// Whether enough window is left to justify another boot attempt.
        var allowsRetry: Bool {
            guard let deadline else { return true }
            return deadline.timeIntervalSinceNow
                > PhoneDSHHost.minimumRetryHelloBudget
        }
    }

    /// Boots a replacement Worker for the controller's `Recovering` state,
    /// retrying a `.boot`-class failure up to ``maximumBootRetries`` times.
    ///
    /// Every attempt re-runs ``prepareForReboot()`` (so no connection or HELLO
    /// from the failed attempt survives), rebuilds the overlay from the current
    /// materialized tree and boots a fresh page/Worker. The engine's restart
    /// lever issues a new page `boot_id` on every call; the `bootWorker`
    /// fallback is the same cold boot the host performs on start, preceded by
    /// the same channel barrier and overlay rebuild. The retries share one
    /// HELLO budget (``BootHelloBudget``) and are separated by
    /// ``bootRetryBackoff``; a workspace-class failure is rethrown immediately
    /// because the next attempt would fail the same way.
    ///
    /// - Returns: the engine's restart report of the successful attempt, when
    ///   the engine reports one.
    private func bootReplacementWorker(
        _ runtime: RuntimeServices,
        reason: WebEngineRestartReason,
        orphanReason: String,
        incarnationCutoffAfterBoot: Bool,
        publishReportImmediately: Bool
    ) async throws -> WebEngineRestartReport? {
        let budget = BootHelloBudget()
        var lastError: Error?
        var attempt = 0
        while attempt <= Self.maximumBootRetries {
            if attempt > 0 {
                guard budget.allowsRetry else { break }
                // Give a just-killed WebContent process a moment before the
                // next page spawns; the sleep is part of the retry budget.
                try? await Task.sleep(
                    nanoseconds: UInt64(Self.bootRetryBackoff * 1_000_000_000))
            }
            do {
                return try await bootReplacementWorkerOnce(
                    runtime,
                    reason: reason,
                    orphanReason: orphanReason,
                    incarnationCutoffAfterBoot: incarnationCutoffAfterBoot,
                    publishReportImmediately: publishReportImmediately,
                    helloBudget: budget)
            } catch {
                lastError = error
                guard let fault = HostFault.classify(error), fault.isBoot else {
                    // A workspace-scoped failure would fail identically on
                    // every attempt: hand it to the caller's fail-loud path.
                    throw error
                }
                attempt += 1
                NSLog("phone-dsh: replacement Worker boot attempt %d failed (%@): %@",
                      attempt, reason.rawValue, fault.description)
            }
        }
        throw lastError ?? PhoneDSHError.startTimedOut(
            "the replacement Worker did not boot inside the retry budget")
    }

    /// One replacement-Worker boot attempt.
    private func bootReplacementWorkerOnce(
        _ runtime: RuntimeServices,
        reason: WebEngineRestartReason,
        orphanReason: String,
        incarnationCutoffAfterBoot: Bool,
        publishReportImmediately: Bool,
        helloBudget: BootHelloBudget
    ) async throws -> WebEngineRestartReport? {
        if !incarnationCutoffAfterBoot {
            beginWorkerIncarnation()
        }
        await runtime.coordinator.prepareForReboot()
        // Pick up every acknowledged mutation since the last epoch before the
        // page reloads; the overlay route serves this file.
        _ = try await runtime.log.overlay(bootID: bootID)
        let report = try await bootEngine(runtime, reason: reason)
        if incarnationCutoffAfterBoot {
            beginWorkerIncarnation()
        }
        if publishReportImmediately, let report {
            // The engine normally publishes the same report on its own stream;
            // `publishRestart` drops the copy that arrives second, and an
            // engine whose event is late still gets exactly one.
            publishRestart(report)
        }
        let hello = try await runtime.coordinator.waitForHello(
            timeout: helloBudget.timeout(helloTimeout: configuration.helloTimeout))
        // D13/G2-C07/G2-FIX-93: a replacement Worker can interrupt a tool call
        // exactly like an abnormal termination. DSH reconciles its tool journal
        // only on a write-open of the stored session, so drive the same bounded
        // write-open before reopening admission. A helper failure stays inside
        // this boot's fail-loud path; admission therefore remains closed and
        // `sendOpenFrames` is never reached.
        try await waitForWorkerToCloseOrphanSteps(runtime, reason: orphanReason)
        try await verifyLease(hello, runtime: runtime)
        try await sendOpenFrames(hello.connection, runtime: runtime)
        return report
    }

    /// Boots the Worker on the current engine, preferring the restart lever.
    private func bootEngine(_ runtime: RuntimeServices,
                            reason: WebEngineRestartReason) async throws
        -> WebEngineRestartReport? {
        if let requesting = runtime.engine as? WebEngineRestartRequesting {
            return try await requesting.restart(reason: reason)
        }
        if let engine = runtime.engine {
            try await engine.bootWorker(runtime.engineConfiguration)
            return nil
        }
        throw PhoneDSHError.notStarted
    }

    /// Budget for one recovery write-open inside the host's remaining grace.
    ///
    /// A quarter of the remaining window (capped at 250 ms) is reserved for
    /// the route's final `close()` and the response round trip. The server
    /// clamps this value again, so a large `helloTimeout` cannot make one
    /// session hold the pipe past the fixed post-termination grace.
    private static func recoveryBudget(until deadline: Date) -> PhoneDSHRecoveryBudget {
        let remaining = deadline.timeIntervalSinceNow
        guard remaining > 0 else {
            return PhoneDSHRecoveryBudget(
                timeoutMilliseconds: PhoneDSHRecoveryProtocol.minimumBudgetMilliseconds)
        }
        let reserve = min(0.25, remaining / 4)
        let milliseconds = Int(((remaining - reserve) * 1_000).rounded(.down))
        return PhoneDSHRecoveryBudget(timeoutMilliseconds: max(
            PhoneDSHRecoveryProtocol.minimumBudgetMilliseconds, milliseconds))
    }

    /// Waits `min(helloTimeout, 2 s)` for the replacement Worker to run DSH's
    /// write-open tool-journal reconcile, then settles the rest.
    ///
    /// Shared by both replacement-Worker paths: the automatic WebContent
    /// termination recovery (`worker-terminated`) and `plannedRestart`
    /// (`planned-restart`, which also covers the page-worker kill used by the
    /// scenario runner). The fixed grace is not extended by either caller.
    ///
    /// DSH reconciles the tool journal only in
    /// `sessionPersistence.open(id, "write")`; `session/follow` and
    /// `session/page` are history reads and never open the writer. The phone
    /// surface therefore exposes that exact write-open as a small
    /// authenticated route. The host asks the replacement Worker to open each
    /// affected stored session, which appends the journal's terminal
    /// `completed`/`resolved` record through the normal ordered channel, and
    /// waits for ``StepMachine`` to observe those JOURNAL frames. A Worker that
    /// died mid-`tool_dispatched` with no recoverable journal entry produces no
    /// such record, so only the steps still open at the deadline are abandoned.
    /// `settleOrphans` re-reads the store at the deadline, so evidence that
    /// arrived just before it is never overwritten.
    private func waitForWorkerToCloseOrphanSteps(_ runtime: RuntimeServices,
                                                 reason: String) async throws {
        let initial = await runtime.stepMachine.reconcile().filter { !$0.state.isTerminal }
        guard !initial.isEmpty else { return }
        let grace = min(max(0, configuration.helloTimeout), 2)
        guard grace > 0 else {
            let settled = try await runtime.stepMachine.settleOrphans(reason: reason)
            publishOrphanSettlement(settled, reason: reason)
            return
        }
        let deadline = Date().addingTimeInterval(grace)
        let transport = makeTransport(runtime: runtime)
        guard let recovery = transport as? any PhoneDSHRecoveryCalling else {
            throw PhoneDSHError.invalidState(
                "the replacement Worker transport has no recovery write-open path")
        }
        let sessionIDs = Array(Set(initial.map(\.sessionID))).sorted()
        await withTaskGroup(of: Void.self) { group in
            for sessionID in sessionIDs {
                // The outer deadline stays as a backstop, but the Worker now
                // gets its own strictly shorter budget: it aborts the real
                // reconcile/ack wait and closes the writer before it answers.
                // A local Promise.race alone used to leave the write handle
                // owned by a task the host no longer awaited.
                let budget = Self.recoveryBudget(until: deadline)
                let remaining = max(0, deadline.timeIntervalSinceNow)
                group.addTask {
                    _ = await phoneDSHResultWithinDeadline(remaining) {
                        try await recovery.reconcileSessionForRecovery(
                            sessionID, budget: budget)
                    }
                }
            }
            await group.waitForAll()
        }
        while Date() < deadline {
            let pending = await runtime.stepMachine.reconcile().filter { !$0.state.isTerminal }
            if pending.isEmpty { return }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        let settled = try await runtime.stepMachine.settleOrphans(reason: reason)
        publishOrphanSettlement(settled, reason: reason)
    }

    /// Publishes the bounded diagnostic of one settlement. The event carries
    /// only session ids and step keys; never tool arguments or content.
    private func publishOrphanSettlement(_ records: [StepRecord], reason: String) {
        guard !records.isEmpty else { return }
        let refs = records.map {
            PhoneDSHOrphanStepRef(sessionID: $0.sessionID, stepKey: $0.stepKey)
        }
        eventBus.send(.orphanStepsSettled(PhoneDSHOrphanStepSettlement(
            reason: reason, count: records.count, steps: refs)))
    }

    private static func facadeState(for state: HostState) -> PhoneDSHState {
        switch state {
        case .running: return .running
        case .draining, .handingOff: return .draining
        case .remote: return .remote
        case .failed: return .failed
        case .parked: return .stopped
        case .recovering, .backoff, .reclaiming: return .starting
        }
    }

    private func setState(_ newState: PhoneDSHState) {
        guard newState != state else { return }
        let previous = state
        state = newState
        if newState == .running {
            startPeriodicEpochClose()
        } else {
            stopPeriodicEpochClose()
        }
        eventBus.send(.stateChanged(from: previous, to: newState))
    }

    // MARK: - Periodic epoch close (D7, GAP-12)

    /// The interval is the frozen 30-60 s D7 range in production; the test
    /// seam may set a short value to exercise the tick deterministically.
    private var periodicEpochCloseInterval: TimeInterval {
        if let override = periodicEpochCloseIntervalOverride { return max(0, override) }
        let configured = configuration.log.epochIntervalSeconds
        return min(WorkspaceLogConfiguration.maximumEpochIntervalSeconds,
                   max(WorkspaceLogConfiguration.minimumEpochIntervalSeconds, configured))
    }

    private func startPeriodicEpochClose() {
        guard periodicEpochCloseTask == nil else { return }
        let token = UUID()
        periodicEpochCloseToken = token
        periodicEpochCloseTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let host = self else { return }
                let interval = await host.periodicEpochCloseInterval
                do {
                    try await Task.sleep(
                        nanoseconds: UInt64(max(0, interval) * 1_000_000_000))
                } catch {
                    break
                }
                switch await host.attemptPeriodicEpochClose() {
                case .notRunning:
                    await host.finishPeriodicEpochClose(token: token)
                    return
                case .closed, .skipped, .failed:
                    continue
                }
            }
            await self?.finishPeriodicEpochClose(token: token)
        }
    }

    private func finishPeriodicEpochClose(token: UUID) {
        guard periodicEpochCloseToken == token else { return }
        periodicEpochCloseTask = nil
    }

    private func stopPeriodicEpochClose() {
        periodicEpochCloseTask?.cancel()
        periodicEpochCloseTask = nil
        periodicEpochCloseToken = UUID()
    }

    /// One periodic D7 close. It runs only while the controller and facade are
    /// `Running`, so it never races the drain/restart edge. A held resync is
    /// skipped loudly instead of failing the host: the drain owns the repair
    /// deadline (wal.md §5.2, budgets.md §1).
    @discardableResult
    private func attemptPeriodicEpochClose() async -> PeriodicEpochCloseOutcome {
        guard state == .running, let runtime else { return .notRunning }
        guard await runtime.machine.currentState() == .running else {
            return .notRunning
        }
        let holds = await runtime.log.pendingResyncHolds()
        if !holds.isEmpty {
            let detail = holds.map { "\($0.path) mseq \($0.mseq)" }
                .joined(separator: ", ")
            let reason = "periodic epoch close skipped: outstanding VFS_RESYNC at \(detail)"
            NSLog("phone-dsh: %@", reason)
            periodicEpochCloseObserver?(.skipped(reason: reason))
            return .skipped(reason: reason)
        }
        do {
            let ack = try await runtime.log.closeEpochCoveringTail()
            periodicEpochCloseObserver?(.closed(uptoMseq: ack.uptoMseq))
            return .closed(uptoMseq: ack.uptoMseq)
        } catch {
            periodicEpochCloseObserver?(.failed(reason: String(describing: error)))
            await failClassifying(error, context: "periodic epoch close")
            return .failed(reason: String(describing: error))
        }
    }

    /// Test seams for the D7 periodic close. Production leaves them unset.
    internal func setPeriodicEpochCloseIntervalForTesting(_ interval: TimeInterval?) {
        periodicEpochCloseIntervalOverride = interval
    }

    internal func setPeriodicEpochCloseObserverForTesting(
        _ observer: (@Sendable (PeriodicEpochCloseOutcome) -> Void)?) {
        periodicEpochCloseObserver = observer
    }

    /// Runs one tick synchronously so a test does not depend on a wall clock.
    @discardableResult
    internal func performPeriodicEpochCloseForTesting() async -> PeriodicEpochCloseOutcome {
        await attemptPeriodicEpochClose()
    }

    // MARK: - Budgets

    /// Reports the latest WebContent heap sample. The engine or App calls this
    /// when its memory probe fires; `nil` clears the sample. A sample above the
    /// tier's engine heap budget drives the same clear-tmp -> planned-restart ->
    /// handoff sequence as VFS pressure, so publish-time amplification cannot
    /// hide behind a within-budget steady-state VFS.
    /// The engine's last reported heap, for the app's restart policy.
    public func currentEngineHeapBytes() -> Int? { engineHeapBytes }

    public func reportEngineHeapBytes(_ bytes: Int?) async {
        engineHeapBytes = bytes.map { max(0, $0) }
        if let runtime {
            await evaluateBudget(runtime)
        }
    }

    private func evaluateBudget(_ runtime: RuntimeServices) async {
        let metrics = (try? await runtime.log.metrics()) ?? WorkspaceLogMetrics()
        let responseLogBytes: Int
        if let responseLog = runtime.responseLog {
            responseLogBytes = await responseLog.totalBytes()
        } else {
            responseLogBytes = 0
        }
        _ = await budgetSnapshot(runtime: runtime, metrics: metrics,
                                 responseLogBytes: responseLogBytes,
                                 advance: true)
    }

    /// Builds the budget snapshot of one measurement.
    ///
    /// - Parameter advance: `true` consumes the next action of the pressure
    ///   episode and publishes it; `false` previews the episode without
    ///   consuming it, which is what a read-only `diagnostics()` call needs.
    ///   Polling diagnostics must never drive clear-tmp -> planned-restart ->
    ///   handoff by itself.
    private func budgetSnapshot(runtime: RuntimeServices,
                                metrics: WorkspaceLogMetrics,
                                responseLogBytes: Int,
                                advance: Bool) async -> PhoneDSHBudgetSnapshot {
        // Use the controller's canonical adapter so the monitor sees exactly
        // the `WorkspaceLog.metrics()` partition that `totalVFSBytes` (and
        // therefore `vfsLogicalBytesUsed` below) counts, including
        // `/dsh/home` outside `sessions/` (`otherBytes`).
        let sample = MemoryProxySample(metrics: metrics,
                                       webContentTerminations: terminations,
                                       engineHeapBytes: engineHeapBytes)
        let decision = advance
            ? await runtime.budgetMonitor.evaluate(sample)
            : await runtime.budgetMonitor.preview(sample)
        if advance, decision != lastBudgetDecision {
            lastBudgetDecision = decision
            if !decision.isClear { eventBus.send(.budget(decision)) }
        }
        let table = await runtime.budgetMonitor.table
        return PhoneDSHBudgetSnapshot(
            table: table,
            vfsLogicalBytesUsed: metrics.totalVFSBytes,
            workspaceBytesUsed: metrics.workspaceBytes,
            sessionBytesUsed: metrics.homeSessionsBytes,
            tmpBytesUsed: metrics.tmpBytes,
            walBytesUsed: metrics.walBytes,
            journalBytesUsed: metrics.journalBytes,
            responseLogBytesUsed: responseLogBytes,
            webContentTerminations: terminations,
            engineHeapBytesUsed: engineHeapBytes,
            lastAction: decision.action,
            hardFail: decision.hardFail)
    }
}

/// Fallback handler if a future loopback server stops passing its
/// `ChannelServer`; it fails loud instead of acknowledging anything.
private actor PhoneDSHUnavailableChannelHandler: ChannelHandling {
    private func unavailable() throws -> Never {
        throw LoopbackError.channelUnavailable
    }

    func handleHello(_ payload: HelloPayload) async throws { try unavailable() }
    func handleVFSMutation(_ body: VfsMutationBody, seq: UInt64) async throws {
        try unavailable()
    }
    func handleVFSBarrier(_ body: VfsBarrierBody) async throws { try unavailable() }
    func handleExecRequest(_ payload: ExecRequestPayload) async throws { try unavailable() }
    func handleExecControl(_ payload: ExecControlPayload) async throws { try unavailable() }
    func handleJournal(_ body: JournalBody) async throws { try unavailable() }
    func handleAPIResponse(_ frame: ApiResponseFrame) async throws { try unavailable() }
    func handleAPIEnd(_ frame: ApiEndFrame) async throws { try unavailable() }
    func handleAPIAbort(_ frame: ApiAbortFrame) async throws { try unavailable() }
    func handleConsole(_ payload: ConsolePayload) async throws { try unavailable() }
    func handleError(_ payload: ErrorPayload) async throws { try unavailable() }
}

/// Outcome of one D7 periodic epoch-close tick (GAP-12).
internal enum PeriodicEpochCloseOutcome: Equatable, Sendable {
    case closed(uptoMseq: UInt64)
    case skipped(reason: String)
    case notRunning
    case failed(reason: String)
}

extension PhoneDSHWorkspaceLogBridge: LoopbackResyncStatusProviding {
    func pendingResyncPaths() async -> [String] {
        await log.pendingResyncPaths()
    }
}
