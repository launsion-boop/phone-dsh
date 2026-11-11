// SPDX-License-Identifier: MIT

import Foundation
import PhoneDSH
import PhoneDSHAgentCore
import PhoneDSHBot

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
    let proactive: ProactiveEngine
    let deviceResults: DeviceTaskResultOutbox
    private let routineActivity: BotRoutineActivityFlag
    private let nowProvider: @Sendable () -> Int64

    private(set) var started = false
    private var liveSubscription: BotLiveFrameSubscription?
    private var liveFish: BotLiveFishProjection
    private var liveRunning = false
    private var liveGeneration = 0

    private init(botID: String, environment: BotProductionEnvironment,
                 remote: BotDSHRemoteRuntime, scheduler: RoutineScheduler,
                 wakeInbox: WakeInbox, planner: BotRemoteActionPlanner,
                 routineOutbox: BotRoutineOutbox, rows: BotProductionRowService,
                 info: BotProductionInfoService, proactive: ProactiveEngine,
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
        self.proactive = proactive
        self.deviceResults = deviceResults
        self.routineActivity = routineActivity
        self.nowProvider = nowProvider
        self.liveFish = BotLiveFishProjection(botID: botID)
    }

    static func make(runtime: BotMCPRuntime, handler: BotMCPHandler,
                     store: SQLiteDomainStore, botID: String,
                     displayName: String,
                     now: (@Sendable () -> Int64)? = nil,
                     sleep: RoutineScheduler.Sleeper? = nil) async throws -> BotRuntimeUnit {
        let memory = await runtime.memory(for: botID)
        let machine = await runtime.routineMachine
        let environment = BotProductionEnvironment(
            domain: store, botID: botID, sessionID: botID,
            routineMachine: machine, memory: memory,
            fallbackName: displayName)
        let inbox = WakeInbox(store: SQLiteWakeInboxStore(domainStore: store, botId: botID))
        let remote = try await BotDSHRemoteRuntime(
            transport: UnstartedBotTransport(), runtime: runtime,
            botId: botID, wakeInbox: inbox,
            botDataDirectory: BotSessionRegistry.botDataDirectory,
            onSessionRegistered: { sessionID in
                Task { @MainActor in BotSessionRegistry.shared.register(sessionID) }
            })
        let planner = BotRemoteActionPlanner(
            remote: remote, runtime: runtime, handler: handler,
            store: store, botID: botID, wakeInbox: inbox)
        let routineOutbox = BotRoutineOutbox(store: store, machine: machine, botID: botID)
        let rows = BotProductionRowService(environment: environment, remote: remote)
        let routineActivity = BotRoutineActivityFlag()
        let resolvedNow = now ?? { Int64(Date().timeIntervalSince1970 * 1000) }
        let settingsStore = ProactiveSettingsStore.shared
        let proactive = ProactiveEngine(
            settings: { settingsStore.settings() },
            now: resolvedNow,
            deliverer: BotRuntimeUnit.proactiveDelivery(),
            eventLog: store,
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
        let info = BotProductionInfoService(
            environment: environment, scheduler: scheduler, settingsStore: settingsStore)
        let deviceResults = DeviceTaskResultOutbox(domain: store, now: resolvedNow)
        return BotRuntimeUnit(
            botID: botID, environment: environment, remote: remote,
            scheduler: scheduler, wakeInbox: inbox, planner: planner,
            routineOutbox: routineOutbox, rows: rows, info: info,
            proactive: proactive, deviceResults: deviceResults,
            routineActivity: routineActivity, nowProvider: resolvedNow)
    }

    /// Rebinds this Bot's private remote to a fresh Host transport. The shared
    /// engine session id and environment are maintained in the same order as
    /// the single-Bot composition: invalidate the replaced Worker first (the
    /// composition does it once for all units), then transport, session,
    /// durable routines and interrupted tasks, then the scheduler.
    func start(transport: any DSHRemoteTransport) async throws {
        await remote.attachTransport(transport)
        let sessionID = try await remote.startMainSession()
        try await environment.connect(BotProductionComposition(
            sessionID: sessionID, planner: planner,
            turnStopping: BotRuntimeTurnStopper(remote: remote)))
        _ = try await scheduler.recover()
        _ = await remote.deliverInterruptedTaskWakes()
        _ = try? await deviceResults.redeliver(botID: botID, in: wakeInbox)
        await scheduler.start()
        await startLiveObservation()
        started = true
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
    func detach() async {
        await scheduler.stop()
        await stopLiveObservation()
        started = false
        liveRunning = false
        liveFish = BotLiveFishProjection(botID: botID)
        await remote.attachTransport(UnstartedBotTransport())
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

    /// Live status for the sidebar. It is intentionally cheap (no durable
    /// row rebuild): visible chat turns publish live frames; a selected Bot's
    /// cached `BotChatModel` supplies the richer detail when its page is open.
    func statusSnapshot(pendingApprovalCount: Int,
                        runtimeState: BotRuntimeState) async -> BotRosterRuntimeState {
        let now = BotLiveFishProjection.now
        let live = liveFish.presentation(now: now)
        let remoteBusy = await remote.isMainTurnBusy()
        let routineRunning = await routineActivity.isRunning()
        let running = liveRunning || remoteBusy || routineRunning
        let fish: BotFishLifecycle
        if pendingApprovalCount > 0 {
            fish = .alerting
        } else if running {
            fish = live.fishState == .idle ? .working : live.fishState
        } else if liveFish.isIdleSleeping(now: now) {
            fish = .sleeping
        } else {
            fish = live.fishState
        }
        return BotRosterRuntimeState(
            fishState: fish,
            activity: running ? live.activity : nil,
            isRunning: running,
            pendingApprovalCount: pendingApprovalCount,
            reaction: live.reaction,
            runtimeState: runtimeState)
    }

    private static func proactiveDelivery() -> (any ProactiveDelivering)? {
        // The macOS eval harness is a bare XCTest process: UserNotifications
        // throws at `currentNotificationCenter`, and a headless runner has no
        // application bundle to display to. The eval plan sets this variable;
        // the App never does. The proactive decision/event chain still runs.
        if ProcessInfo.processInfo.environment["PDSH_BOT_EVAL_PLAN"] != nil { return nil }
        #if canImport(UserNotifications)
        return UNUserNotificationProactiveDelivery()
        #else
        return nil
        #endif
    }

    private static func notificationScheduling() -> (any RoutineNotificationScheduling)? {
        if ProcessInfo.processInfo.environment["PDSH_BOT_EVAL_PLAN"] != nil { return nil }
        #if canImport(UserNotifications)
        return UNUserNotificationRoutineScheduling()
        #else
        return nil
        #endif
    }

    // MARK: - Live observation

    private func startLiveObservation() async {
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
