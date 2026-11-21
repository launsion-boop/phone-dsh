// SPDX-License-Identifier: MIT

import Foundation
import PhoneDSH
import PhoneDSHAgentCore
import PhoneDSHBot

/// The production prompt-only resume seam for a card answer that was committed
/// before a kill/rebind but whose prompt never reached the Worker.
extension BotDSHRemoteRuntime: BotCardAnswerPromptResuming {
    public func resumeCardAnswerPrompt(text: String, nonce: String) async throws {
        try await resumePendingPrompt(
            text, requestId: BotTurnOrigin.cardAnswerRequestId(nonce: nonce))
    }
}
#if canImport(UIKit)
import UIKit
#endif

/// One Bot's runtime half. The App shares exactly one `BotMCPRuntime`, one
/// `BotMCPHTTPServer` and one effect outbox; every Bot gets its own DSH remote
/// (subscription for live frames), routine scheduler, wake inbox, planner and
/// row/info service. Units are created on demand and torn down by the delete
/// cascade.
/// Counts in-flight routine runs for one Bot. Routine turns are hidden and do
/// not publish live chat frames, but they still keep the process alive and
/// must show as running in the roster model.
actor BotRoutineActivityFlag {
    private var count = 0

    func begin() { count += 1 }
    func end() { count = max(0, count - 1) }
    func isRunning() -> Bool { count > 0 }
}

/// One lifecycle attempt of a ``BotRuntimeUnit`` startup.
///
/// ``BotRuntimeUnit/beginStart()`` mints a lease synchronously and advances the
/// unit's generation, so every older attempt is invalid before it can run its
/// next awaited step. ``BotRuntimeUnit/detach()`` advances the same generation.
/// The lease carries no resources; it is only the identity a start re-checks
/// after each suspension together with the composition's outer bind.
struct BotUnitStartLease: Equatable, Sendable {
    fileprivate let generation: UInt64
}

@MainActor
final class BotRuntimeUnit {
    let botID: String
    let environment: BotProductionEnvironment
    let remote: BotDSHRemoteRuntime
    let scheduler: RoutineScheduler
    let wakeInbox: WakeInbox
    let planner: BotRemoteActionPlanner
    let routineOutbox: BotRoutineOutbox
    let rows: BotProductionRowService
    let info: BotProductionInfoService
    let maintenance: BotMemoryMaintenanceController
    let proactive: ProactiveEngine
    let deviceResults: DeviceTaskResultOutbox
    private let routineActivity: BotRoutineActivityFlag
    private let nowProvider: @Sendable () -> Int64

    private(set) var started = false
    /// Monotonic unit-local lifecycle fence. `beginStart` and `detach` advance
    /// it synchronously, before their first suspension, so a start suspended in
    /// one of its awaited steps can never resume to restart the scheduler,
    /// subscribe the live observer or publish `started` after a newer
    /// lifecycle took over.
    private var lifecycleGeneration: UInt64 = 0
    private var liveSubscription: BotLiveFrameSubscription?
    private var liveFish: BotLiveFishProjection
    private var liveRunning = false
    private var liveGeneration = 0

    private init(botID: String, environment: BotProductionEnvironment,
                 remote: BotDSHRemoteRuntime, scheduler: RoutineScheduler,
                 wakeInbox: WakeInbox, planner: BotRemoteActionPlanner,
                 routineOutbox: BotRoutineOutbox, rows: BotProductionRowService,
                 info: BotProductionInfoService,
                 maintenance: BotMemoryMaintenanceController,
                 proactive: ProactiveEngine,
                 deviceResults: DeviceTaskResultOutbox,
                 routineActivity: BotRoutineActivityFlag,
                 nowProvider: @escaping @Sendable () -> Int64) {
        self.botID = botID
        self.environment = environment
        self.remote = remote
        self.scheduler = scheduler
        self.wakeInbox = wakeInbox
        self.planner = planner
        self.routineOutbox = routineOutbox
        self.rows = rows
        self.info = info
        self.maintenance = maintenance
        self.proactive = proactive
        self.deviceResults = deviceResults
        self.routineActivity = routineActivity
        self.nowProvider = nowProvider
        self.liveFish = BotLiveFishProjection(botID: botID)
    }

    static func make(runtime: BotMCPRuntime, handler: BotMCPHandler,
                     store: SQLiteDomainStore, botID: String,
                     displayName: String,
                     recordService: BotRecordService? = nil,
                     isMainBot: @escaping @Sendable () -> Bool = { true },
                     workspaceRoot: URL = BotProductionPaths.workspaceRoot(),
                     now: (@Sendable () -> Int64)? = nil,
                     sleep: RoutineScheduler.Sleeper? = nil,
                     feedback: BotFeedbackCenter? = nil,
                     provenance: BotProvenanceService? = nil) async throws -> BotRuntimeUnit {
        let memory = await runtime.memory(for: botID)
        let machine = await runtime.routineMachine
        let grants = await runtime.grants
        let environment = BotProductionEnvironment(
            domain: store, botID: botID, sessionID: botID,
            routineMachine: machine, memory: memory, grants: grants,
            workspaceRoot: workspaceRoot,
            fallbackName: displayName)
        let inbox = WakeInbox(store: SQLiteWakeInboxStore(domainStore: store, botId: botID))
        let botData = BotSessionRegistry.botDataDirectory
        let remote = try await BotDSHRemoteRuntime(
            transport: UnstartedBotTransport(), runtime: runtime,
            botId: botID, wakeInbox: inbox,
            botDataDirectory: botData,
            onSessionRegistered: { sessionID in
                Task { @MainActor in BotSessionRegistry.shared.register(sessionID) }
            })
        await runtime.installUserContentRecordProvider { sessionID in
            await remote.userContentRecordRef(sessionId: sessionID)
        }
        let planner = BotRemoteActionPlanner(
            remote: remote, runtime: runtime, handler: handler,
            store: store, botID: botID, wakeInbox: inbox)
        let routineOutbox = BotRoutineOutbox(store: store, machine: machine, botID: botID)
        let resolvedNow = now ?? { Int64(Date().timeIntervalSince1970 * 1000) }
        let rows = BotProductionRowService(
            environment: environment, remote: remote,
            cardAnswerPromptResumer: remote)
        let routineActivity = BotRoutineActivityFlag()
        let settingsStore = ProactiveSettingsStore.shared
        let proactive = ProactiveEngine(
            settings: { settingsStore.settings() },
            now: resolvedNow,
            deliverer: BotRuntimeUnit.proactiveDelivery(),
            eventLog: store,
            feedback: feedback,
            deliveryKinds: [.routineResult])
        let notificationScheduling = BotRuntimeUnit.notificationScheduling()
        let scheduler = RoutineScheduler(
            botId: botID, machine: machine, inbox: inbox, sink: routineOutbox,
            proactive: proactive,
            notifications: notificationScheduling,
            runner: { [remote] request in
                await routineActivity.begin()
                let result = await remote.runRoutine(request)
                await routineActivity.end()
                return result
            },
            cancelRunner: { [remote] cancellation in await remote.cancelRoutine(cancellation) },
            approvalCanceller: { [runtime] approvalID in
                await runtime.approvals.cancelPersistent(
                    approvalId: approvalID, reason: "routine_stopped")
            },
            available: { [remote] _ in await remote.isAvailable() },
            busy: { [remote] _ in await remote.isMainTurnBusy() },
            settings: { settingsStore.settings() },
            // Defaults intentionally mirror `RoutineScheduler.init`; the eval
            // runner injects a controllable clock/sleeper through the production
            // composition. Production callers pass neither and keep the wall
            // clock.
            now: resolvedNow,
            sleep: sleep ?? { milliseconds in
                guard milliseconds > 0 else { return }
                try? await Task.sleep(nanoseconds: UInt64(milliseconds) * 1_000_000)
            },
            leaseOwner: "bot-runtime-composition")
        await remote.installRoutineApprovalHandler { [scheduler] notice in
            await scheduler.approvalResolved(
                approvalId: notice.approvalID, sessionId: notice.principal.sessionId,
                allowed: notice.allowed, expired: notice.expired,
                cancelled: notice.cancelled)
        }
        let maintenance = BotMemoryMaintenanceController(
            store: store, botID: botID, memory: memory, runtime: runtime,
            remote: remote, recordReading: recordService,
            feedbackReading: feedback.map { BotFeedbackDisputeAdapter(query: $0) },
            invalidationReading: provenance.map { service in
                BotProvenanceInvalidationAdapter(scopedQuery: { request in
                    let artifact = BotDerivedRef(
                        kind: .memory, id: request.artifact.path,
                        version: request.artifact.version)
                    let statuses = try await service.sourceStatuses(
                        for: artifact, botID: request.botID)
                    return Dictionary(statuses.map { ($0.ref, $0) },
                                      uniquingKeysWith: { first, _ in first })
                })
            },
            isMainBot: isMainBot,
            isAppActive: {
#if canImport(UIKit)
                if Thread.isMainThread {
                    return UIApplication.shared.applicationState == .active
                }
                return DispatchQueue.main.sync {
                    UIApplication.shared.applicationState == .active
                }
#else
                // The macOS eval harness drives the same production unit; it
                // has no iOS application state, so the foreground opportunity
                // is always eligible there.
                return true
#endif
            },
            notify: { text in
                let item = try? WakeInboxItem(
                    id: "memory-maintenance-\(UUID().uuidString.lowercased())",
                    kind: "memory-maintenance",
                    title: "记忆整理",
                    text: text,
                    requestId: "memory-maintenance:\(UUID().uuidString.lowercased())",
                    createdAt: resolvedNow())
                if let item { _ = try? await inbox.enqueue(item) }
            },
            now: resolvedNow)
        // A user turn yields immediately: cancel quiet timer and any running
        // maintenance batch (committed writes stay).
        await remote.setUserTurnObservers(
            started: { [weak maintenance] in
                await maintenance?.noteUserTurnStarted()
            },
            finished: { [weak maintenance] in
                await maintenance?.noteUserTurnFinished()
            })
        let info = BotProductionInfoService(
            environment: environment, scheduler: scheduler, settingsStore: settingsStore,
            maintenance: maintenance,
            bridgeDiagnostic: { [runtime, remote] in
                guard let diagnostic = await runtime.lastBridgeError(),
                      await remote.ownsSession(diagnostic.sessionId) else { return nil }
                return diagnostic
            })
        let deviceResults = DeviceTaskResultOutbox(domain: store, now: resolvedNow)
        await environment.setRoutineCanceller { [scheduler] routineID in
            await scheduler.cancelRunning(routineId: routineID)
        }
        return BotRuntimeUnit(
            botID: botID, environment: environment, remote: remote,
            scheduler: scheduler, wakeInbox: inbox, planner: planner,
            routineOutbox: routineOutbox, rows: rows, info: info,
            maintenance: maintenance,
            proactive: proactive, deviceResults: deviceResults,
            routineActivity: routineActivity, nowProvider: resolvedNow)
    }

    /// Invalidates every older, possibly suspended, start and returns the
    /// lease for a new one. This is synchronous on the unit actor, so the
    /// invalidation happens before the caller can reach its first `await`.
    func beginStart() -> BotUnitStartLease {
        lifecycleGeneration &+= 1
        return BotUnitStartLease(generation: lifecycleGeneration)
    }

    /// Whether `lease` is still this unit's newest lifecycle attempt.
    func isCurrentStart(_ lease: BotUnitStartLease) -> Bool {
        lease.generation == lifecycleGeneration
    }

    /// The fence every start step uses. It rejects caller cancellation, a
    /// detach/newer start and a superseded composition bind in that order, so
    /// a stale attempt throws `CancellationError` before it can run another
    /// externally visible effect.
    private func ensureCurrentStart(
        _ lease: BotUnitStartLease,
        _ isOuterBindCurrent: @MainActor () -> Bool
    ) throws {
        try Task.checkCancellation()
        guard isCurrentStart(lease), isOuterBindCurrent() else {
            throw CancellationError()
        }
    }

    /// Rebinds this Bot's private remote to a fresh Host transport. The shared
    /// engine session id and environment are maintained in the same order as
    /// the single-Bot composition: invalidate the replaced Worker first (the
    /// composition does it once for all units), then transport, session,
    /// durable routines and interrupted tasks, then the scheduler.
    ///
    /// `started` is cleared *before* the first throwing step on purpose: a
    /// restart of an already-started unit that fails midway (after the transport
    /// was attached, before the main session/scheduler came back) must not be
    /// reported as a live+started unit by ``rebindState``, or the next bind
    /// would keep it and never retry `start`.
    ///
    /// Every attempt carries a ``BotUnitStartLease`` and the composition's
    /// outer bind validity. ``beginStart()`` invalidated every older attempt
    /// before this call's first suspension, and after every await — including
    /// the multi-await closures and the swallowed `try?` step below — the
    /// attempt re-checks caller cancellation, its lease and the outer bind. A
    /// stale attempt therefore throws `CancellationError` before it can run
    /// another externally visible effect or publish `started`.
    func start(transport: any DSHRemoteTransport, attempt: Int,
               channelDetail: String = "",
               lease: BotUnitStartLease,
               isOuterBindCurrent: @escaping @MainActor () -> Bool) async throws {
        // Check before touching `started`: a superseded attempt must not clear
        // the newer attempt's flag on its way out.
        try ensureCurrentStart(lease, isOuterBindCurrent)
        started = false
        let unitDetail = "bot=\(botID)" + (channelDetail.isEmpty ? "" : " " + channelDetail)
        try await BotRebindDiagnostics.run(
            "unit.attach-transport", attempt: attempt, detail: unitDetail
        ) {
            try ensureCurrentStart(lease, isOuterBindCurrent)
            await remote.attachTransport(transport)
            try ensureCurrentStart(lease, isOuterBindCurrent)
        }
        try ensureCurrentStart(lease, isOuterBindCurrent)
        let sessionID = try await BotRebindDiagnostics.run(
            "unit.start-main-session", attempt: attempt, detail: unitDetail
        ) {
            try ensureCurrentStart(lease, isOuterBindCurrent)
            let sessionID = try await remote.startMainSession()
            try ensureCurrentStart(lease, isOuterBindCurrent)
            return sessionID
        }
        try ensureCurrentStart(lease, isOuterBindCurrent)
        // A foreground resume parks the host and boots a fresh Worker; its
        // in-memory credential map is empty. Re-claim every session this Bot
        // still owns before the next turn, so the first tool call after the
        // lock screen does not race the claim. A session whose host token no
        // longer resolves is reissued here (same kind/capabilities), never by
        // extending the TTL.
        _ = try await BotRebindDiagnostics.run(
            "unit.reclaim-sessions", attempt: attempt, detail: unitDetail
        ) {
            try ensureCurrentStart(lease, isOuterBindCurrent)
            let reclaimed = await remote.reclaimOwnedSessions()
            try ensureCurrentStart(lease, isOuterBindCurrent)
            return reclaimed
        }
        try ensureCurrentStart(lease, isOuterBindCurrent)
        try await BotRebindDiagnostics.run(
            "unit.environment-connect", attempt: attempt, detail: unitDetail
        ) {
            try ensureCurrentStart(lease, isOuterBindCurrent)
            try await environment.connect(BotProductionComposition(
                sessionID: sessionID, planner: planner,
                turnStopping: BotRuntimeTurnStopper(remote: remote)))
            try ensureCurrentStart(lease, isOuterBindCurrent)
        }
        try ensureCurrentStart(lease, isOuterBindCurrent)
        _ = try await BotRebindDiagnostics.run(
            "unit.scheduler-recover", attempt: attempt, detail: unitDetail
        ) {
            try ensureCurrentStart(lease, isOuterBindCurrent)
            let actions = try await scheduler.recover()
            try ensureCurrentStart(lease, isOuterBindCurrent)
            return actions
        }
        try ensureCurrentStart(lease, isOuterBindCurrent)
        try await BotRebindDiagnostics.run(
            "unit.approvals", attempt: attempt, detail: unitDetail
        ) {
            try ensureCurrentStart(lease, isOuterBindCurrent)
            let waiting = await scheduler.waitingApprovalEntries()
            try ensureCurrentStart(lease, isOuterBindCurrent)
            for entry in waiting {
                let status = await remote.approvalStatus(approvalId: entry.approvalID)
                try ensureCurrentStart(lease, isOuterBindCurrent)
                switch status {
                case .allowed, .denied, .expired, .cancelled:
                    await scheduler.approvalResolved(
                        approvalId: entry.approvalID, sessionId: entry.sessionID,
                        allowed: status == .allowed, expired: status == .expired,
                        cancelled: status == .cancelled)
                    try ensureCurrentStart(lease, isOuterBindCurrent)
                case .pending, .unknown:
                    break
                }
            }
        }
        try ensureCurrentStart(lease, isOuterBindCurrent)
        _ = try await BotRebindDiagnostics.run(
            "unit.interrupted-wakes", attempt: attempt, detail: unitDetail
        ) {
            try ensureCurrentStart(lease, isOuterBindCurrent)
            let delivered = await remote.deliverInterruptedTaskWakes()
            try ensureCurrentStart(lease, isOuterBindCurrent)
            return delivered
        }
        try ensureCurrentStart(lease, isOuterBindCurrent)
        // The device-result redelivery is best effort (`try?` below), so its
        // inner CancellationError is swallowed on purpose. The explicit check
        // after the wrapper is what stops a stale attempt here.
        _ = try? await BotRebindDiagnostics.run(
            "unit.device-results", attempt: attempt, detail: unitDetail
        ) {
            try ensureCurrentStart(lease, isOuterBindCurrent)
            try await deviceResults.redeliver(botID: botID, in: wakeInbox)
            try ensureCurrentStart(lease, isOuterBindCurrent)
        }
        try ensureCurrentStart(lease, isOuterBindCurrent)
        try await BotRebindDiagnostics.run(
            "unit.scheduler-start", attempt: attempt, detail: unitDetail
        ) {
            try ensureCurrentStart(lease, isOuterBindCurrent)
            await scheduler.start()
            try ensureCurrentStart(lease, isOuterBindCurrent)
            try await startLiveObservation(
                lease: lease, isOuterBindCurrent: isOuterBindCurrent)
            try ensureCurrentStart(lease, isOuterBindCurrent)
        }
        try ensureCurrentStart(lease, isOuterBindCurrent)
        started = true
        // App-open, idle opportunity (spec/bot/v2 §4.5). It checks enabled,
        // main-chat idle, pending approvals and triggers itself. The task is
        // detached like before; it re-checks the lease when it runs so a
        // superseded start cannot trigger maintenance later.
        Task { @MainActor [weak self, maintenance, lease] in
            guard let self, self.isCurrentStart(lease), isOuterBindCurrent() else { return }
            await maintenance.maybeRun(reason: "foreground")
        }
        // A newly created Bot has its opening instruction in the durable
        // WakeInbox before its first unit starts. Only the onboarding item may
        // open a turn here; ordinary agent/routine held items keep their old
        // wait-for-user behavior. If the user already opened a turn, the item
        // stays pending and folds into that turn instead.
        if await BotOnboarding.hasPending(in: wakeInbox) {
            try ensureCurrentStart(lease, isOuterBindCurrent)
            try? await remote.wakeWithHeldMessages()
            try ensureCurrentStart(lease, isOuterBindCurrent)
        }
    }

    /// The unit's state for a host bind's restart scope. A live transport and a
    /// completed start are both required to keep the unit: anything else means
    /// the unit cannot serve a turn on the current Worker incarnation and must
    /// be attached again.
    func rebindState() async -> BotRebindUnit {
        await BotRebindUnit(botID: botID,
                            hasLiveTransport: remote.hasLiveTransport(),
                            isStarted: started)
    }

    /// The keep-alive condition includes routines due inside the window even
    /// when no turn is running.
    func hasRoutineDueSoon(within windowMs: Int64 = RoutinePresencePolicy.keepAliveWindowMs) async -> Bool {
        let machine = await environment.routineMachine
        let routines = (try? await machine.list(botId: botID)) ?? []
        return RoutinePresencePolicy.hasRoutineDueSoon(routines, now: nowProvider(), windowMs: windowMs)
    }

    /// Drops the Host-bound half but keeps the unit and its durable data. A
    /// later `start(transport:)` reuses the same remote and scheduler.
    ///
    /// The detach invalidates every older start synchronously, before its first
    /// suspension. Each later teardown step re-checks the generation: if a
    /// newer start took over while this detach was suspended on the scheduler
    /// or remote actor, the detach stops instead of tearing that newer start
    /// down. Returns `true` only when this call owned the teardown from start
    /// to finish.
    @discardableResult
    func detach() async -> Bool {
        lifecycleGeneration &+= 1
        let generation = lifecycleGeneration
        await scheduler.stop()
        guard generation == lifecycleGeneration else { return false }
        await stopLiveObservation()
        guard generation == lifecycleGeneration else { return false }
        started = false
        liveRunning = false
        liveFish = BotLiveFishProjection(botID: botID)
        await remote.attachTransport(UnstartedBotTransport())
        return generation == lifecycleGeneration
    }

    /// Detaches only when `lease` is still the unit's newest lifecycle attempt.
    /// A late cleanup from a failed or superseded start cannot tear down a start
    /// that replaced it.
    @discardableResult
    func detach(ifCurrent lease: BotUnitStartLease) async -> Bool {
        guard isCurrentStart(lease) else { return false }
        return await detach()
    }

    func wakeHeldMessages() async throws {
        try await remote.wakeWithHeldMessages()
    }

    func stopCurrentTurn() async throws {
        try await remote.cancelMainTurn()
    }

    func abortRunningWork() async {
        try? await remote.cancelMainTurn()
        await remote.workerRestarted()
    }

    func pendingRoutineCount() async -> Int {
        let machine = await environment.routineMachine
        return (try? await machine.list(botId: botID).count) ?? 0
    }

    /// Live status for the sidebar. The durable read is cached by its row
    /// service after the first call (no per-tick row rebuild), so this stays
    /// cheap while giving the projection the durable presentation the page
    /// also sees.
    func statusSnapshot(pendingApprovalCount: Int,
                        runtimeState: BotRuntimeState) async -> BotRosterRuntimeState {
        let now = BotLiveFishProjection.now
        let live = liveFish.presentation(now: now)
        let durable = (try? await rows.presentation()) ?? live
        let remoteBusy = await remote.isMainTurnBusy()
        let routineRunning = await routineActivity.isRunning()
        let running = liveRunning || remoteBusy || routineRunning
        let fish = BotFishLifecycleProjection.resolve(
            pendingApprovalCount: pendingApprovalCount,
            running: running,
            idleSleeping: liveFish.isIdleSleeping(now: now),
            livePresentation: BotFishLifecyclePresentation(
                fishState: live.fishState, oneShot: live.oneShot),
            durablePresentation: BotFishLifecyclePresentation(
                fishState: durable.fishState, oneShot: durable.oneShot),
            liveTurn: liveRunning,
            now: now)
        return BotRosterRuntimeState(
            fishState: fish,
            activity: running ? live.activity : nil,
            isRunning: running,
            pendingApprovalCount: pendingApprovalCount,
            reaction: live.reaction,
            runtimeState: runtimeState)
    }

    private static var isHeadlessXCTestProcess: Bool {
        // The macOS eval harness is a bare XCTest process: UserNotifications
        // throws at `currentNotificationCenter`, and a headless runner has no
        // application bundle to display to. eval.sh sets PDSH_BOT_EVAL_PLAN;
        // a plain `swift test` does not, so detect XCTest itself as well. The
        // App has neither and keeps the real delivery. The proactive
        // decision/event chain still runs in both cases.
        NSClassFromString("XCTestCase") != nil
            || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    private static func proactiveDelivery() -> (any ProactiveDelivering)? {
        if isHeadlessXCTestProcess
            || ProcessInfo.processInfo.environment["PDSH_BOT_EVAL_PLAN"] != nil { return nil }
        #if canImport(UserNotifications)
        return UNUserNotificationProactiveDelivery()
        #else
        return nil
        #endif
    }

    private static func notificationScheduling() -> (any RoutineNotificationScheduling)? {
        if isHeadlessXCTestProcess
            || ProcessInfo.processInfo.environment["PDSH_BOT_EVAL_PLAN"] != nil { return nil }
        #if canImport(UserNotifications)
        return UNUserNotificationRoutineScheduling()
        #else
        return nil
        #endif
    }

    // MARK: - Live observation

    private func startLiveObservation(
        lease: BotUnitStartLease,
        isOuterBindCurrent: @escaping @MainActor () -> Bool
    ) async throws {
        try ensureCurrentStart(lease, isOuterBindCurrent)
        guard liveSubscription == nil else { return }
        liveGeneration += 1
        let generation = liveGeneration
        liveFish = BotLiveFishProjection(botID: botID)
        let subscription = await remote.subscribeLiveFrames { [weak self] frame in
            guard let self else { return }
            Task { @MainActor [weak self] in
                guard let self, self.liveGeneration == generation else { return }
                self.receive(frame)
            }
        }
        do {
            // The subscribe hop is an await. A detach or newer start that ran
            // while it was outstanding owns the live observer now, so drop the
            // subscription this stale attempt just installed.
            try ensureCurrentStart(lease, isOuterBindCurrent)
            guard liveGeneration == generation else { throw CancellationError() }
        } catch {
            await remote.unsubscribeLiveFrames(subscription)
            throw error
        }
        liveSubscription = subscription
    }

    private func stopLiveObservation() async {
        liveGeneration += 1
        guard let subscription = liveSubscription else { return }
        liveSubscription = nil
        await remote.unsubscribeLiveFrames(subscription)
    }

    private func receive(_ frame: BotLiveTurnFrame) {
        let now = BotLiveFishProjection.now
        switch frame.kind {
        case .streamStart:
            if !liveRunning { liveRunning = true }
        case .textDelta:
            break
        case .event(let event):
            let type = event["type"]?.stringValue ?? ""
            guard let data = try? JSONEncoder().encode(event),
                  let value = try? JSONValue.parse(data) else { return }
            if type == "turn/start" { liveRunning = true }
            if type == "turn/end" { liveRunning = false }
            liveFish.receive(.event(value), now: now)
        }
        if case .streamStart = frame.kind {
            liveFish.receive(.streamStart, now: now)
        } else if case .textDelta(let text) = frame.kind {
            liveFish.receive(.textDelta(text), now: now)
        }
    }

    /// A page touch resets the same 60 s sidebar clock.
    func noteInteraction() {
        liveFish.noteInteraction()
    }

}
