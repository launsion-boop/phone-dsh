// SPDX-License-Identifier: MIT

import Foundation
import PhoneDSH
import PhoneDSHAgentCore
import PhoneDSHBot
import PhoneDSHDeviceTasks
import PhoneDSHShell


#if canImport(PhoneDSHADB) && canImport(PhoneDSHLoopback)
import PhoneDSHADB
import PhoneDSHLoopback
#endif
#if canImport(PhoneDSHBLE)
import PhoneDSHBLE
#endif
#if canImport(ProbeKit)
import ProbeKit
#endif

/// Ordered-channel context is diagnostic-only and needs the PhoneDSH host
/// types, so it stays beside the production composition.
@MainActor
extension BotRebindDiagnostics {
    /// Bounded connection context for a step. The boot id is the Worker's
    /// public identity; the connection ids are process-local UUIDs.
    static func channelDetail(_ selection: PhoneDSHChannelSelection?) -> String {
        guard let selection else { return "conn=none" }
        var parts: [String] = []
        parts.append("conn=" + short(selection.currentConnectionID))
        if let boot = selection.currentWorkerBootID {
            parts.append("boot=" + String(boot.prefix(8)))
        }
        parts.append("hello=" + short(selection.latestHelloConnectionID))
        parts.append("hello_count=\(selection.latestHelloCount)")
        parts.append("latest=" + (selection.isCurrentConnectionLatestHello ? "yes" : "no"))
        parts.append("conns=\(selection.connectionCount)")
        return parts.joined(separator: " ")
    }

    static func short(_ id: UUID?) -> String {
        guard let id else { return "none" }
        return String(id.uuidString.replacingOccurrences(of: "-", with: "").prefix(8)).lowercased()
    }
}

actor BotDeferredVolatileContextProvider: BotVolatileContextProviding {
    private var provider: (any BotVolatileContextProviding)?

    func attach(_ provider: any BotVolatileContextProviding) {
        self.provider = provider
    }

    func snapshot(botId: String, sessionId: String, kind: BotSessionKind) async throws -> BotVolatileBlocks {
        guard let provider else { throw BotMCPError.unavailable("volatile provider is not connected") }
        return try await provider.snapshot(botId: botId, sessionId: sessionId, kind: kind)
    }
}

actor BotRuntimeTurnStopper: BotProductionTurnStopping {
    let remote: BotDSHRemoteRuntime
    init(remote: BotDSHRemoteRuntime) { self.remote = remote }
    func stopCurrentTurn(turnID: String?) async throws { try await remote.stopMainTurn(turnID: turnID) }
}

/// Stage timeline for one App-side Bot rebind.
///
/// Kept in the production app so the next tester can grep `bot-rebind` in
/// `Documents/chat-status.log` and see the last stage that started. A line
/// carries only the stage name, elapsed milliseconds, a bounded error token and
/// truncated ordered-channel ids — never a prompt, message, path, token or any
/// other content. The connection fields let a hang be attributed to the wrong
/// connection without a debugger: `conn` is what `makeTransport()` will use and
/// `latest=yes` says it is the newest Worker HELLO.

/// Thread-safe snapshot of the roster's main-Bot pointer. The maintainer write
/// rule and candidate selection are synchronous host checks, so they cannot
/// await the profile store; the roster observation keeps this pointer current.
final class BotMainBotPointer: @unchecked Sendable {
    private let lock = NSLock()
    private var mainBotID: String?

    init(_ mainBotID: String?) { self.mainBotID = mainBotID }

    func update(_ mainBotID: String?) {
        lock.lock()
        self.mainBotID = mainBotID
        lock.unlock()
    }

    func isMain(_ botID: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return mainBotID == botID
    }
}

/// Per-Bot delivery/cycle context. The team tool host owns it; it is not
/// durable, because only a live hand-off chain needs it.
@MainActor
final class BotAgentCommTracker {
    struct Context: Equatable {
        var depth = 0
        var chain: [String] = []
        /// The hop that opened the current turn; makes an answer to the
        /// immediate previous hop a reply instead of a cycle (`team.md`
        /// §2.3.1). In-memory only, like `chain`.
        var inbound: BotAgentInboundHop?
    }

    private var active: [String: Context] = [:]
    private var pendingHeld: [String: Context] = [:]
    private var rowIDs: [String: Set<String>] = [:]

    func context(for botID: String) -> Context {
        if let pending = pendingHeld.removeValue(forKey: botID), active[botID] == nil {
            return pending
        }
        return active[botID] ?? Context()
    }

    func setActive(_ context: Context, for botID: String) { active[botID] = context }
    func clearActive(for botID: String) { active.removeValue(forKey: botID) }
    func setPendingHeld(_ context: Context, for botID: String) { pendingHeld[botID] = context }

    func addRowID(_ id: String, for botID: String) {
        rowIDs[botID, default: []].insert(id)
    }

    func existingRowIDs(for botID: String) -> Set<String> { rowIDs[botID] ?? [] }

    func reset(for botID: String) {
        active.removeValue(forKey: botID)
        pendingHeld.removeValue(forKey: botID)
        rowIDs.removeValue(forKey: botID)
    }
}

/// Runs the v4 pending-action outbox replay away from the bind path.
///
/// One pass per Bot at a time. A unit start schedules a pass; if the unit is
/// started again while a pass is still running, one follow-up pass is queued
/// instead of overlapping. An empty outbox costs one indexed read, and a pass
/// that cannot reach the transport simply leaves the rows for the next launch.
@MainActor
final class BotPendingActionReplayCoordinator {
    private var passes: [String: Task<Void, Never>] = [:]
    private var rerun: Set<String> = []

    func schedule(botID: String, rows: BotProductionRowService, reason: String) {
        if passes[botID] != nil {
            rerun.insert(botID)
            return
        }
        passes[botID] = Task { [weak self] in
            let report = await rows.replayPendingActions()
            guard let self else { return }
            self.finish(botID: botID, rows: rows, report: report, reason: reason)
        }
    }

    private func finish(botID: String, rows: BotProductionRowService,
                        report: BotPendingActionReplayReport, reason: String) {
        passes[botID] = nil
        // Silent when the outbox was empty and healthy: this line is for a
        // launch that actually had something to recover.
        if report.loaded > 0 || report.loadFailed || report.remaining > 0 {
            var line = "bot-pending-action step=replay reason=\(reason) bot=\(botID)"
            line += " loaded=\(report.loaded) accepted=\(report.accepted)"
            line += " duplicate=\(report.duplicates) stale=\(report.stale)"
            line += " rejected=\(report.rejected) deferred=\(report.deferred)"
            line += " remaining=\(report.remaining)"
            line += report.loadFailed ? " ok=0 load=error" : " ok=1"
            if let errorType = report.lastErrorType { line += " error=\(errorType)" }
            BotRebindDiagnostics.emit(line)
        }
        if rerun.remove(botID) != nil {
            schedule(botID: botID, rows: rows, reason: reason)
        }
    }
}

/// The single production composition root for the whole Bot roster.
///
/// Hard constraint: one `BotMCPRuntime`, one `BotMCPHTTPServer` and one effect
/// outbox. Everything Bot-specific (DSH remote, routine scheduler, wake inbox,
/// row/info services) lives in a `BotRuntimeUnit` created on demand.
@MainActor
final class BotRuntimeComposition {
    struct Launch {
        let composition: BotRuntimeComposition
        let environment: BotProductionEnvironment
        /// The Worker environment for the next Host build. It is read from the
        /// composition so a listener that healed onto a new port is reflected
        /// without rebuilding the composition.
        @MainActor var workerEnvironment: [String: String] { composition.workerEnvironment }
    }

    let domain: SQLiteDomainStore
    let profileStore: BotProfileStore
    let runtime: BotMCPRuntime
    /// Shared read-only record service used by the shell `phone record`
    /// command and the memory evidence resolver.
    let recordService: BotRecordService
    let handler: BotMCPHandler
    let server: BotMCPHTTPServer
    let outbox: BotProductionEffectRunner
    let rosterModel: BotRosterModel
    let selectionStore: BotSelectionStore
    let agentCommTracker = BotAgentCommTracker()
    /// Durable pending-action replay (v4). Off the bind path: a unit start
    /// schedules a pass, the bind never awaits it.
    private let pendingActionReplay = BotPendingActionReplayCoordinator()
    /// Synchronous main-Bot pointer for the maintainer write rule.
    let mainBotPointer: BotMainBotPointer

    /// The Worker environment carrying the Bot MCP endpoint/token. The whole
    /// roster shares one listener, so one URL (and one token) feeds the single
    /// Worker. Only the URL changes on recovery; the token remains the
    /// process-lifetime bearer.
    private(set) var workerEnvironment: [String: String] = [:]

    private var units: [String: BotRuntimeUnit] = [:]
    /// Optional scheduler test seam. Both stay nil in production, so every
    /// `RoutineScheduler` keeps its wall-clock default. The eval runner injects
    /// a controllable clock/sleeper through `prepare(...)`.
    private let schedulerNow: (@Sendable () -> Int64)?
    private let schedulerSleep: RoutineScheduler.Sleeper?
    /// G-1 provenance read model (process-wide, one event log).
    private(set) var provenance: BotProvenanceService?
    /// G-2 feedback center, shared by every unit and the RecordFeedback tool.
    private(set) var feedbackCenter: BotFeedbackCenter?
    /// Installed by the App-side connector wiring (tokens and the Gmail/GitHub
    /// clients are App-side). It returns the records this scan newly made
    /// durable; nil means the connector step reports `skipped("not-configured")`
    /// and never half-scans.
    var connectorSweep: (() async throws -> [ConnectorUpdateRecord])?
    /// The durable connector-update outbox. Set by the same App wiring so the
    /// held-inbox replay step can re-enqueue an unacknowledged interval.
    private(set) var connectorUpdateOutbox: ConnectorUpdateOutbox?
    /// PLAN §2.9 I2: the App's durable WakeDemand sink. nil in the eval harness
    /// and unit tests; the App installs the ledger adapter after prepare.
    private(set) var wakeDemandSink: (any BotWakeDemanding)?
    /// Recurring connector scan cadence. The minimum interval is a contract
    /// constant (r3); nil keeps the scan wake-driven without inventing a value.
    var connectorScanDemandIntervalMs: Int64?
    /// PLAN §2.8 hand-off for Bot channels. A channel signals this only after
    /// its request is durable; the App bridge maps the signal to
    /// `EngineLaunchOrchestrator.shared.wake`. It never starts the engine here.
    private(set) var botWakeSource: BotChannelWakeSource?
    private var routineRouter: BotRoutineOutboxRouter?
    private var host: PhoneDSHHost?
    private let hostReference = BotHostReference()
    private let workspaceRoot: URL
    private var hostTask: Task<Void, Never>?
    private var observedHost: PhoneDSHHost?
    /// Owns "one bind per new Worker boot" across terminations, planned
    /// restarts and foreground resumes. The host can publish those events in
    /// any relative order; the scheduler never binds before a replacement
    /// boot exists, never drops a newer boot seen mid-bind, and bounds every
    /// attempt so a stalled transport cannot leave the page at recovering.
    private let workerRecovery = BotWorkerRecoveryScheduler()
    /// The single consumer of the scheduler's ordered phase stream. It is
    /// installed with the recovery callback and before the host is observed,
    /// and applies every phase on this composition's main actor in order.
    private var workerRecoveryPhaseTask: Task<Void, Never>?
    /// Set while a caller deliberately parks/resumes the host and then
    /// reattaches the Bot remote itself (the session-epoch eraser). The
    /// automatic `.workerHello` recovery would race that manual sequence with
    /// a second attach, so it stays out until the manual rebind completes.
    private var suppressesWorkerBootRebind = false
    /// True while the session-epoch eraser parks/resumes the host on purpose.
    /// That park is not a background keep-alive transition, so the host's
    /// background-park hold must not refuse it.
    private var suppressesParkHold = false
    /// The live MCP egress policy this composition installed the Bot write
    /// approver on. Cleared on detach so a stopped Bot runtime cannot answer
    /// for a later `/v1/http` write.
    private var botEgressPolicy: MCPEgressPolicy?
    private var tickTask: Task<Void, Never>?
    private var rosterTask: Task<Void, Never>?
    private var started = false
    /// Monotonic binding lifecycle fence. Every bind and every detach/stop
    /// advances it. A bind re-checks it after every suspension and immediately
    /// before each remaining side effect, so a bind that a stop or a newer
    /// binding superseded cannot reinstall the egress approver, restart a unit,
    /// publish ready or set `started` after the newer lifecycle took over.
    private var bindEpoch = 0
    /// Monotonic attempt number for the `bot-rebind` diagnostic timeline. It
    /// distinguishes the first bind from the scheduler's bounded retries.
    private var bindAttempts = 0
    private var deliversDeviceTaskResults = false
    private var threadsLoaded = false
    private var agentCommThreads: [String: String] = [:]
    private var pendingApprovalTicks = 0
    private var approvalNotifications: BotApprovalNotificationReconciler?

    /// The Worker never carries the real Bot bearer. The host egress route
    /// (`MCPEgressPolicy.grantBotRuntimeEndpoint`) injects it after stripping
    /// the placeholder, so neither the page URL (`?env=`) nor the Worker
    /// process ever sees it.
    static let workerTokenPlaceholder = "phone-host-injects-bot-mcp-token"

    private(set) var state: BotRuntimeState = .idle {
        didSet {
            guard oldValue != state else { return }
            // Mirror readiness outside the main actor. `tools/call` reads this
            // snapshot; it must not wait for a blocked UI thread.
            readinessState.update(
                ready: state == .ready,
                terminal: state == .stopped || state.isFailure)
            onStateChange?(state)
        }
    }
    /// Nonisolated mirror of ``state`` for the Bot MCP tool path. Only the
    /// `.ready` bit and the terminal bit matter to the readiness probe.
    private let readinessState = BotRuntimeReadinessState()
    var onStateChange: ((BotRuntimeState) -> Void)?
    /// Called after a successful delete so the UI can drop cached models.
    var onBotDeleted: ((String) -> Void)?

    // MARK: - Compatibility views (single-Bot callers and the E2E build)

    var environment: BotProductionEnvironment { currentUnit.environment }
    var remote: BotDSHRemoteRuntime { currentUnit.remote }
    var scheduler: RoutineScheduler { currentUnit.scheduler }
    var wakeInbox: WakeInbox { currentUnit.wakeInbox }
    var planner: BotRemoteActionPlanner { currentUnit.planner }
    var routineOutbox: BotRoutineOutbox { currentUnit.routineOutbox }
    var rows: BotProductionRowService { currentUnit.rows }
    var info: BotProductionInfoService { currentUnit.info }

    private var currentUnit: BotRuntimeUnit {
        if let selected = rosterModel.selectedBotID, let unit = units[selected] { return unit }
        if let main = rosterModel.mainBotID, let unit = units[main] { return unit }
        return units.values.first!
    }

    // MARK: - Prepare

    /// Builds the one production composition. The first Bot (or the restored
    /// selection) gets its unit eagerly; the rest are created on demand when
    /// selected, messaged, or when a routine owner reconnects.
    static func prepare(store: SQLiteDomainStore,
                        profileStore: BotProfileStore = BotProfileStore(
                            directory: BotProfileStorage.directory()),
                        selectedBotID: String? = nil,
                        sessionLogURL: URL? = nil,
                        workspaceRoot: URL? = nil,
                        now: (@Sendable () -> Int64)? = nil,
                        sleep: RoutineScheduler.Sleeper? = nil) async throws -> Launch {
        let legacyName = await legacyRenamedName(domain: store)
        var roster = try await profileStore.roster()
        if roster.bots.isEmpty {
            // First launch only. An existing desktop/old roster must keep its
            // insertion order and get its pointer repaired to its first Bot;
            // never append a synthetic "main" record to it.
            _ = try await profileStore.bootstrapMainIfNeeded(legacyName: legacyName)
            roster = try await profileStore.roster()
        }
        let defaults = UserDefaults.standard
        let restored = BotMainPointerRouting.restoredSelection(
            selectedBotID ?? defaults.string(forKey: BotSelectionDefaults.key),
            in: roster)
        let selectionStore = BotSelectionStore(selected: restored)

        guard let selectedCandidate = restored ?? roster.mainBotID ?? roster.bots.first?.id else {
            throw BotTeamHostError.botNotFound("empty roster")
        }
        let deferred = BotDeferredVolatileContextProvider()
        // The eval seam must govern every clock in the composition: the
        // gateway (identity/attribution expiry), `BotMCPRuntime`, the record
        // service and the scheduler must read the same injected clock. A
        // gateway on the wall clock while the runtime runs on a deterministic
        // baseline makes a registration look expired immediately and rejects
        // real tool calls as unattributed. Production passes nil and keeps the
        // wall clock for both.
        let runtimeClock = now ?? { Int64(Date().timeIntervalSince1970 * 1_000) }
        let gateway = BotGateway(now: runtimeClock)
        let recordService = BotRecordService(
            store: store, gateway: gateway,
            workspaceRoot: workspaceRoot ?? BotProductionPaths.workspaceRoot())
        // The image bridge is App-side iOS code. The macOS eval host compiles the
        // same production composition without the App target, so vision is
        // absent there and the existing optional reader stays nil; text/path
        // attachments are unaffected. iOS behavior is unchanged.
        #if canImport(UIKit)
        let modelImageReader: BotMCPRuntime.BotModelImageReader? = BotWorkspaceModelImage.image(for:)
        #else
        let modelImageReader: BotMCPRuntime.BotModelImageReader? = nil
        #endif
        let runtime = BotMCPRuntime(store: store, gateway: gateway,
                                    volatileProvider: deferred,
                                    recordEvidence: recordService,
                                    modelImageReader: modelImageReader,
                                    now: runtimeClock)
        let machine = await runtime.routineMachine
        let baseMemory = await runtime.memory(for: selectedCandidate)
        let language = Locale.preferredLanguages.first?.hasPrefix("zh") == true ? "zh" : "en"
        let mainBotID = roster.mainBotID
        let volatile = BotDomainVolatileContextProvider(
            memory: baseMemory, routines: machine,
            personaAsync: DeviceAppWiring.decoratePersona { botId, _, _ in
                let profile = try? await profileStore.profile(id: botId)
                let name = profile?.name ?? (botId == mainBotID ? "大肥鱼" : botId)
                return "你的名字是\(name)。用户问起名字时如实回答。"
            },
            memoryForBot: { botID in await runtime.memory(for: botID) },
            teammates: { callerBotID in
                let roster = (try? await profileStore.roster())
                    ?? BotRoster(bots: [], mainBotID: nil)
                return roster.bots
                    .filter { !$0.hiddenByUser && $0.id != callerBotID }
                    .map { bot in
                        BotTeammateSummary(id: bot.id, name: bot.name,
                                           description: bot.description,
                                           isMain: bot.id == roster.mainBotID)
                    }
            },
            botDescription: { botID in
                try? await profileStore.profile(id: botID)?.description
            },
            language: language)
        await deferred.attach(volatile)

        // G-2: one decision-context service and one trace log for the process.
        // The service reuses the Bot's own memory authority; the permission
        // revision binds a request to the host instance, the grant set and the
        // roster, and the runtime compares it before a delivery side effect.
        let materialTrace = BotMaterialTraceLog()
        let instanceID = UUID().uuidString
        let grantStore = await runtime.grants
        let permissionRevision: BotPermissionRevisionEvaluator = { botID, sessionID, recipient in
            let grantState = await grantStore.list(botId: botID)
                .map { "\($0.id)|\($0.resource)|\($0.expiresAt ?? 0)" }
                .sorted().joined(separator: ",")
            let roster = (try? await profileStore.roster())?.bots.map(\.id).sorted()
                .joined(separator: ",") ?? ""
            let recipientState = recipient.map { "\($0.kind.rawValue):\($0.id)" } ?? ""
            return BotArgumentsDigest.digest(
                ofUTF8: "\(instanceID)|\(botID)|\(sessionID)|\(recipientState)|\(grantState)|\(roster)")
        }
        // G-1 provenance first: the decision material state adapter reads it.
        let fileRechecker = BotFileSourceRechecker(
            locator: BotWorkspaceFileURLResolver(
                workspaceRoot: workspaceRoot ?? BotProductionPaths.workspaceRoot()))
        // E3 external page freshness reuses the existing account /v1/web/fetch
        // endpoint. It is not cloud scheduling and adds no new service.
        let webBaseURL = ProcessInfo.processInfo.environment["PDSH_CLOUD_BASE_URL"]
            .flatMap(URL.init(string:)) ?? URL(string: "https://account.tonoai.cn")
        let webRechecker: BotProvenanceRechecking? = webBaseURL.map { baseURL in
            BotProvenanceWebRecheckAdapter(
                transport: CloudWebRecheckTransport(
                    configuration: .init(baseURL: baseURL),
                    tokenProvider: { try await TonoAccountSession.shared.accessToken() }))
        }
        let provenance = BotProvenanceService(
            eventLog: store,
            resolver: recordService,
            rechecker: BotProvenanceRecheckerComposite(
                file: BotProvenanceFileRecheckAdapter(rechecker: fileRechecker),
                web: webRechecker))
        await runtime.installProvenance(provenance)
        let materialState = BotDecisionMaterialStateAdapter(provenance: provenance)
        let workspaceCatalog = BotWorkspaceDirectoryCatalog(
            workspaceRoot: workspaceRoot ?? BotProductionPaths.workspaceRoot())
        let workspaceMaterials = WorkspaceDecisionContextService(
            catalog: workspaceCatalog,
            eligibility: provenance)
        // G-2 feedback: one center for the process, created before the
        // decision context so its read views feed material construction.
        let feedbackCenter: BotFeedbackCenter?
        do {
            feedbackCenter = try BotFeedbackCenter.live(
                eventLog: store,
                memory: { botID in await runtime.memory(for: botID) },
                routineReader: BotFeedbackRoutineReader(domainStore: store))
        } catch {
            feedbackCenter = nil
        }
        if let feedbackCenter {
            await runtime.installFeedbackTools(BotFeedbackTools(center: feedbackCenter))
        }
        let decisionContext = BotDecisionContextService(
            memoryForBot: { botID in await runtime.memory(for: botID) },
            permissionRevision: permissionRevision,
            materialState: { lookup in await materialState.state(for: lookup) },
            disputedRefs: { paths in
                guard let feedbackCenter else { return [:] }
                return try await feedbackCenter.disputedRefs(paths: paths)
            },
            preferences: { botID in
                guard let feedbackCenter else {
                    return BotFeedbackPreferences(
                        botID: botID, generatedAtMS: 0, active: [], recentlyRevoked: [])
                }
                return try await feedbackCenter.preferences(botID: botID)
            },
            workspaceMaterials: workspaceMaterials)
        await runtime.installDecisionContext(
            decisionContext, trace: materialTrace, permissionRevision: permissionRevision)

        let handler = BotMCPHandler(runtime: runtime)
        let server = BotMCPHTTPServer(handler: handler)
        let url = try await server.start()
        let rosterModel = BotRosterModel(
            roster: roster, selectedBotID: restored, store: profileStore,
            selectionStore: selectionStore, defaults: defaults)
        let composition = try await BotRuntimeComposition(
            domain: store, profileStore: profileStore, runtime: runtime,
            recordService: recordService,
            handler: handler, server: server, rosterModel: rosterModel,
            selectionStore: selectionStore,
            workspaceRoot: workspaceRoot ?? BotProductionPaths.workspaceRoot(),
            schedulerNow: now, schedulerSleep: sleep)
        composition.provenance = provenance
        composition.feedbackCenter = feedbackCenter
        // A Worker rebuilt by a foreground resume loses its in-memory
        // credential map. On the first rejected registration the App
        // re-claims that exact session's current token and the Worker retries
        // once; the body sessionId alone never authenticates.
        await runtime.installSessionReclaimer { [weak composition] (sessionId: String, suppliedToken: String) async -> Bool in
            guard let composition else { return false }
            return await composition.reclaimSessionForIdentity(
                sessionId, suppliedToken: suppliedToken)
        }
        composition.workerEnvironment = [
            "PDSH_PHONE_MCP_URL": url.absoluteString,
            "PDSH_PHONE_MCP_TOKEN": workerTokenPlaceholder,
        ]
        // F1: a tool call from a Worker that was just replaced must not hold
        // its MCP client open until the 130 s client deadline while this
        // composition is still reattaching the transport. The probe resolves
        // on the first `.ready` or gives up with a retryable human error.
        await runtime.setRuntimeReadinessProbe { [weak composition] (timeout: Int) async -> Bool in
            guard let composition else { return false }
            return await composition.waitUntilRuntimeReady(
                timeoutMilliseconds: timeout)
        }
        composition.routineRouter = BotRoutineOutboxRouter(
            store: store, machine: machine, profileStore: profileStore,
            selectionStore: selectionStore)
        // PLAN §2.5: the connector scan is assembled once, App-side, where the
        // Gmail/GitHub authorization actually lives. It reads only metadata and
        // writes one durable `connector-update` per cursor interval.
        // ProbeKit is the App target's module; the BotE2E harness compiles
        // this file without it and keeps the step unconfigured.
        #if os(iOS) && canImport(ProbeKit)
        await ConnectorSweepWiring.install(on: composition)
        // PLAN §2.9: the host owns future due times. Install the durable
        // demand adapter before anything can schedule a routine, then project
        // the current roster so a launch without an engine already has it.
        await WakeDemandWiring.install(on: composition)
        #endif
        // PLAN §2.8: the Bot wake surfaces are assembled here, before any host
        // exists, so a device task result or Bot MCP request that arrives while
        // the engine is down is durable first and then asks the launch
        // orchestrator for a wake. Without the App bridge the signal is a
        // no-op and the durable item waits for the next foreground pass.
        await composition.installBotWakeSource(
            mainBotID: roster.mainBotID ?? roster.bots.first?.id ?? selectedCandidate,
            now: runtimeClock)
        composition.installDeviceTaskResultDelivery()
        await runtime.registerTeamTools(BotTeamTools(host: composition))
        await runtime.registerFishActionTool()
        #if canImport(PhoneDSHBLE) && canImport(UIKit)
        await DeviceAppLiveWiring.attach(runtime: runtime, domain: store)
        #endif
        #if DEBUG
        await XiaozhiFirmwareWiring.attach(runtime: runtime)
        #endif
        rosterModel.start()
        composition.startRosterObservation()
        let selectedUnit = try await composition.ensureUnit(
            for: rosterModel.selectedBotID ?? selectedCandidate,
            reason: "prepare")
        return Launch(composition: composition, environment: selectedUnit.environment)
    }

    private static func legacyRenamedName(domain: SQLiteDomainStore) async -> String? {
        var name: String?
        for event in (try? await BotProductionEventReader.all(domain: domain)) ?? [] {
            guard event.type == "ui.system_event", event.principal.botId == BotMainPointerRouting.legacyMainID,
                  event.data["event"]?.stringValue == "renamed",
                  let candidate = event.data["botName"]?.stringValue?
                    .trimmingCharacters(in: .whitespacesAndNewlines), !candidate.isEmpty else { continue }
            name = candidate
        }
        return name
    }

    private init(domain: SQLiteDomainStore, profileStore: BotProfileStore,
                 runtime: BotMCPRuntime, recordService: BotRecordService,
                 handler: BotMCPHandler,
                 server: BotMCPHTTPServer, rosterModel: BotRosterModel,
                 selectionStore: BotSelectionStore,
                 workspaceRoot: URL,
                 schedulerNow: (@Sendable () -> Int64)?,
                 schedulerSleep: RoutineScheduler.Sleeper?) async throws {
        self.domain = domain
        self.profileStore = profileStore
        self.runtime = runtime
        self.recordService = recordService
        self.handler = handler
        self.server = server
        self.rosterModel = rosterModel
        self.selectionStore = selectionStore
        self.workspaceRoot = workspaceRoot
        self.schedulerNow = schedulerNow
        self.schedulerSleep = schedulerSleep
        self.outbox = BotProductionEffectRunner(store: domain)
        let mainBotPointer = BotMainBotPointer(rosterModel.mainBotID)
        self.mainBotPointer = mainBotPointer
        // Shared `user/` memory has exactly one maintainer: the main Bot's.
        // Keep the synchronous pointer current from the roster observation and
        // from the write rule's own view of the same pointer.
        rosterModel.onRosterChange = { [mainBotPointer] roster in
            mainBotPointer.update(roster.mainBotID)
        }
        await runtime.setMainBotProvider { [mainBotPointer] botID in
            mainBotPointer.isMain(botID)
        }
        // A rebind that was not requested through ensureListening() (for
        // example a future automatic recovery) still updates the environment
        // the next Host build reads.
        server.onEndpointChange = { [weak self] url in
            Task { @MainActor [weak self] in self?.applyWorkerEndpoint(url) }
        }
        await installWorkerRecovery()
    }

    /// The composition owns the rebind; the scheduler only owns event order,
    /// redo-on-newer-boot and the per-attempt deadline.
    ///
    /// The recovery callback is `Sendable` and not actor-isolated: it enters
    /// this composition's main actor explicitly. The scheduler publishes its
    /// phases through one non-dropping stream; the single consumer below is
    /// started here, before `observeHost` can accept host events, so phase
    /// order is preserved on the UI actor.
    private func installWorkerRecovery() async {
        await workerRecovery.install { [weak self] _ in
            guard let self else { throw CancellationError() }
            guard let host = await self.host else {
                throw BotMCPError.unavailable("the Bot host is not connected")
            }
            try await self.bind(to: host, recovering: true)
        }
        workerRecoveryPhaseTask?.cancel()
        let phases = workerRecovery.phases
        workerRecoveryPhaseTask = Task { [weak self] in
            for await event in phases {
                guard !Task.isCancelled, let self else { return }
                await self.applyWorkerRecoveryPhase(event)
            }
        }
    }

    /// Applies one queued scheduler phase only when it still belongs to this
    /// binding's lifecycle.
    ///
    /// The scheduler emits phases through one ordered stream, but a phase
    /// buffered before a `stop()`/manual takeover/new round is read after the
    /// fence already happened. The notification epoch is compared with the
    /// scheduler's *current* epoch, and the bind epoch is checked again after
    /// that await. A detach, stop or newer bind that ran while this consumer
    /// was suspended therefore wins; the queued event is dropped instead of
    /// setting `.failed`/`.ready` over the newer lifecycle. Current phases are
    /// not lost: every scheduler fence republishes its current phase at the
    /// new epoch.
    private func applyWorkerRecoveryPhase(
        _ event: BotWorkerRecoveryScheduler.PhaseEvent
    ) async {
        let bindingEpoch = bindEpoch
        let currentEpoch = await workerRecovery.phaseEpoch
        guard bindingEpoch == bindEpoch, event.epoch == currentEpoch else { return }
        switch event.phase {
        case .idle:
            break
        case .recovering:
            state = .recovering
        case .ready:
            state = .ready
        case .failed(let message):
            // The scheduler owns the bounded automatic-retry round: an
            // event-driven failure (or the user's 重试) starts one, but a
            // failure inside that round never re-arms it. Once the round is
            // exhausted this phase stays `.failed` until the user retries or
            // a new Worker boot/foreground event arrives.
            state = .failed(message)
        }
    }

    /// The endpoint currently published by the Bot MCP listener. The whole
    /// roster shares this one listener, so one URL feeds the Worker environment
    /// and the host egress grant for every Bot.
    var url: URL? { server.url }

    /// Heals the Bot MCP listener and keeps the Worker environment in sync.
    /// A same-port rebind is silent for callers because their URL stays valid;
    /// a new port is written to ``workerEnvironment`` before the next
    /// `makeHostLaunch`, and the App rebuilds a Host that captured the old one.
    func ensureListening() async -> BotMCPListenerRecovery {
        let result = await server.ensureListening()
        if let url = result.url {
            applyWorkerEndpoint(url)
        }
        return result
    }

    private func applyWorkerEndpoint(_ url: URL) {
        let value = url.absoluteString
        guard workerEnvironment["PDSH_PHONE_MCP_URL"] != value else { return }
        workerEnvironment["PDSH_PHONE_MCP_URL"] = value
        print("[BotRuntimeComposition] Bot MCP endpoint recovered at \(value)")
    }

    // MARK: - Unit lifecycle

    func unit(for botID: String) -> BotRuntimeUnit? { units[botID] }

    /// Any typed/poked/tapped page wakes the sidebar's 60 s idle clock for the
    /// same Bot, so the drawer and the open page never disagree.
    func noteInteraction(for botID: String) {
        units[botID]?.noteInteraction()
    }

    @discardableResult
    func ensureUnit(for botID: String, reason: String = "selected") async throws -> BotRuntimeUnit {
        // Guard: an existing unit is returned untouched. Re-attaching it here
        // (as a selection side effect) would swap a live transport and cut the
        // unit's running turn, so a switch must never reach transport creation.
        if let existing = units[botID] { return existing }
        let profile = try await profileStore.profile(id: botID)
        guard let profile else { throw BotTeamHostError.botNotFound(botID) }
        let unit = try await BotRuntimeUnit.make(
            runtime: runtime, handler: handler, store: domain,
            botID: botID, displayName: profile.name,
            recordService: recordService,
            isMainBot: { [mainBotPointer] in mainBotPointer.isMain(botID) },
            workspaceRoot: workspaceRoot,
            now: schedulerNow, sleep: schedulerSleep,
            feedback: feedbackCenter, provenance: provenance,
            wakeDemandSink: wakeDemandSink)
        units[botID] = unit
        let eraser = BotSessionEpochEraser(
            remote: unit.remote,
            environment: unit.environment,
            recordService: recordService,
            hostReference: hostReference,
            workspaceRoot: workspaceRoot,
            beginManualWorkerRebind: { [weak self] in
                await self?.beginManualWorkerRebind()
            },
            endManualWorkerRebind: { [weak self] succeeded in
                await self?.endManualWorkerRebind(succeeded: succeeded)
            })
        await unit.info.setSessionEraser { request in
            try await eraser.erase(request)
        }
        rosterModel.setRuntimeState(BotRosterRuntimeState(runtimeState: state), for: botID)
        if started, let host {
            // Mint the unit-local lease before the first await. The catch below
            // can then clean up only the attempt this selection still owns: a
            // bind/newer start that took over while the transport was being
            // created makes `detach(ifCurrent:)` a no-op instead of tearing
            // the newer start down.
            let bindingEpoch = bindEpoch
            let lease = unit.beginStart()
            do {
                let channelDetail = BotRebindDiagnostics.channelDetail(
                    await host.channelSelection())
                try Task.checkCancellation()
                guard started, self.host === host, bindEpoch == bindingEpoch else {
                    throw CancellationError()
                }
                let transport = try await host.makeTransport()
                try Task.checkCancellation()
                guard started, self.host === host, bindEpoch == bindingEpoch else {
                    throw CancellationError()
                }
                try await unit.start(
                    transport: transport, attempt: 0,
                    channelDetail: channelDetail,
                    lease: lease,
                    isOuterBindCurrent: { [weak self] in
                        guard let self else { return false }
                        return self.started && self.host === host
                            && self.bindEpoch == bindingEpoch
                    })
                installTransportFailureHandler(for: unit, botID: botID)
                schedulePendingActionReplay(for: unit, reason: "unit-start")
            } catch {
                let detached = await unit.detach(ifCurrent: lease)
                if detached, units[botID] === unit {
                    units.removeValue(forKey: botID)
                    await runtime.detachTaskExecutor(botID: botID)
                }
                throw error
            }
        }
        return unit
    }

    /// The hub calls this when the user switches Bots: attach the unit first so
    /// the first message is not sent into an unstarted transport.
    ///
    /// Selection is a page/route change, never a Worker lifecycle event. It must
    /// never call `bind`, `retry` or the worker-recovery scheduler: those
    /// replace every unit's transport, and doing that from a switch is what made
    /// the *other* Bot's running turn disconnect. The only side effect here is
    /// `ensureUnit`, which returns an existing unit untouched (transport and
    /// turn stay live) and attaches a unit that does not exist yet once, to the
    /// host incarnation the current bind already owns. A unit created while a
    /// bind is in flight is picked up by that bind's own unit pass.
    func select(_ botID: String) async throws {
        guard rosterModel.bots.contains(where: { $0.id == botID }) else {
            throw BotTeamHostError.botNotFound(botID)
        }
        _ = try await ensureUnit(for: botID)
        await rosterModel.select(botID)
    }

    // MARK: - Host binding

    func start(host newHost: PhoneDSHHost) async throws {
        if let current = host, current === newHost, started, !state.isFailure {
            return
        }
        if let current = host, current !== newHost {
            await detachBinding()
        }
        host = newHost
        await hostReference.set(newHost)
        try await bind(to: newHost, recovering: false)
    }

    /// The visible 重试 action. A rebind may still be in flight (the d
    /// scenario's first bind never returned); the scheduler supersedes it and
    /// starts a fresh bind for the newest Worker boot instead of treating the
    /// in-flight flag as "already retrying".
    func retry() async {
        guard host != nil else { return }
        // The manual session-epoch eraser owns the only rebind for this Worker
        // boot. An automatic attempt started here would race the caller's own
        // park/start and could outlive the manual outcome.
        guard !suppressesWorkerBootRebind else { return }
        guard !started || state.isFailure || state == .recovering else { return }
        await workerRecovery.forceRetry()
        await workerRecovery.waitUntilIdle()
    }

    /// Bounded wait used by `BotMCPRuntime` before a Bot/team tool executes.
    /// Returns immediately when ready, and `false` for a terminal failure or
    /// after the supplied budget. This is deliberately `nonisolated`: the
    /// runtime calls it from an arbitrary executor, and hopping onto the main
    /// actor here was what let a blocked UI thread hold every `tools/call`
    /// until the Worker's 130 s deadline.
    nonisolated func waitUntilRuntimeReady(
        timeoutMilliseconds: Int = BotMCPRuntime.defaultRuntimeReadinessTimeoutMilliseconds
    ) async -> Bool {
        await BotRuntimeReadiness.wait(
            timeoutMilliseconds: timeoutMilliseconds,
            state: readinessState)
    }

    /// Rejects every remaining step of a bind that a detach, manual takeover,
    /// stop or newer binding superseded. It is main-actor isolated, and callers
    /// invoke it immediately before the side effect it guards, so the check
    /// and that side effect are one non-interleaved step on the composition's
    /// actor.
    private func ensureCurrentBind(_ epoch: Int, host newHost: PhoneDSHHost) throws {
        try Task.checkCancellation()
        guard bindEpoch == epoch, host === newHost else {
            throw CancellationError()
        }
    }

    private func bind(to newHost: PhoneDSHHost, recovering: Bool) async throws {
        try Task.checkCancellation()
        bindEpoch &+= 1
        let bindingEpoch = bindEpoch
        try ensureCurrentBind(bindingEpoch, host: newHost)
        bindAttempts &+= 1
        let attempt = bindAttempts
        let bindStep = BotRebindDiagnostics.start(
            "bind.begin", attempt: attempt,
            detail: "recovering=\(recovering ? 1 : 0) "
                + BotRebindDiagnostics.channelDetail(await newHost.channelSelection()))
        try ensureCurrentBind(bindingEpoch, host: newHost)
        state = recovering ? .recovering : .connecting
        // A bind is a Worker-incarnation operation, not a UI selection. Compare
        // the boot the units are attached to with the one this host is serving:
        // a bind that is not for a replaced Worker must keep every live unit
        // untouched. Restarting a unit swaps its transport and (before the
        // adopt fix) cancelled its running turn, which is exactly the "the other
        // Bot disconnected when I switched" report.
        let workerReplaced = BotWorkerIncarnation.isReplaced(
            previousBootID: await workerRecovery.recoveredBootID,
            currentBootID: await newHost.currentWorkerBootID)
        try ensureCurrentBind(bindingEpoch, host: newHost)
        // Tell the host which turns the App is keeping alive. A graceful
        // background park that would abort one of them is refused instead of
        // cancelling it (see `PhoneDSHHost.setBackgroundTurnHoldProvider`).
        try ensureCurrentBind(bindingEpoch, host: newHost)
        await installParkHold(on: newHost)
        try ensureCurrentBind(bindingEpoch, host: newHost)
        // Units must not attach themselves inside `ensureUnit` while this
        // method is iterating them; the loop below owns transport creation.
        started = false
        do {
            if workerReplaced {
                // Invalidate the replaced Worker incarnation once; every
                // attached Bot remote receives `workerRestarted` through the
                // shared runtime. A bind for the same incarnation skips this:
                // its task/approval invalidation would interrupt work the
                // Worker process is still running.
                _ = try await BotRebindDiagnostics.run(
                    "worker-restarted", attempt: attempt
                ) {
                    await runtime.workerRestarted()
                }
            } else {
                BotRebindDiagnostics.emit(
                    "bot-rebind step=worker-kept attempt=\(attempt) reason=same-incarnation")
            }
            try ensureCurrentBind(bindingEpoch, host: newHost)
            // The host gateway calls this seam only for Bot-attributed
            // POST/PUT/PATCH/DELETE `/v1/http` writes. The policy is the same
            // live object the App uses for exact-MCP admission/credentials.
            try await BotRebindDiagnostics.run("egress-approvers", attempt: attempt) {
                botEgressPolicy?.installBotEgressApprover(nil)
                await runtime.installWorkbenchTurnProbe(nil)
                if let policy = newHost.configuration.egressAuthorizer as? MCPEgressPolicy {
                    let runtime = self.runtime
                    // Install the workbench probe first (the await), then
                    // check the bind epoch and install the approver and record
                    // its owner without another suspension. A detach that ran
                    // while this bind was suspended therefore cannot be
                    // followed by a stale approver install: either the check
                    // throws, or the install+record happen before the detach
                    // can run and the detach clears them.
                    await runtime.installWorkbenchTurnProbe { [weak newHost, weak runtime] in
                        guard let newHost, let runtime else { return false }
                        let botSessions = await runtime.activeSessionIDs()
                        return await newHost.hasActiveWorkbenchTurn(excluding: botSessions)
                    }
                    try self.ensureCurrentBind(bindingEpoch, host: newHost)
                    policy.installBotEgressApprover { request in
                        let outcome = await runtime.approveEgress(
                            method: request.method,
                            host: request.url.host ?? "",
                            scheme: request.url.scheme ?? "",
                            port: request.url.port,
                            hostAllowed: request.hostAllowed)
                        switch outcome {
                        case .notBot: return .notBot
                        case .allowed: return .allow
                        case .denied(let code, let message):
                            return .deny(code: code, message: message)
                        }
                    }
                    // The fail-closed fallback needs to know whether a
                    // workbench turn is running. Bot units share this host's
                    // transport, so the live Bot session ids are excluded from
                    // the journal scan. The probe is installed only while this
                    // composition is bound; a detached runtime answers no
                    // egress.
                    self.botEgressPolicy = policy
                }
            }
            try ensureCurrentBind(bindingEpoch, host: newHost)
            try await BotRebindDiagnostics.run(
                "host-start", attempt: attempt,
                detail: BotRebindDiagnostics.channelDetail(await newHost.channelSelection())
            ) {
                try self.ensureCurrentBind(bindingEpoch, host: newHost)
                try await newHost.start()
            }
            try ensureCurrentBind(bindingEpoch, host: newHost)

            // Always have the selected Bot and every routine owner attached
            // before the outbox/schedulers start.
            let selected = rosterModel.selectedBotID ?? rosterModel.mainBotID
            try await BotRebindDiagnostics.run("ensure-units", attempt: attempt) {
                try self.ensureCurrentBind(bindingEpoch, host: newHost)
                if let selected { _ = try await ensureUnit(for: selected) }
                try Task.checkCancellation()
                for botID in await routineOwnerBotIDs() where botID != selected {
                    _ = try? await ensureUnit(for: botID, reason: "routine-owner")
                }
            }
            try ensureCurrentBind(bindingEpoch, host: newHost)

            let restartErrors = try await rebindUnits(
                on: newHost, attempt: attempt,
                forceRestart: workerReplaced, selected: selected,
                bindEpoch: bindingEpoch)
            _ = restartErrors

            #if canImport(PhoneDSHADB) && canImport(PhoneDSHLoopback)
            #if canImport(PhoneDSHBLE) && canImport(PhoneDSHVenus)
            try await BotRebindDiagnostics.run("native-mcp", attempt: attempt) {
                try self.ensureCurrentBind(bindingEpoch, host: newHost)
                await attachNativeMCP(PhoneNativeMCP.server)
            }
            #elseif canImport(PhoneDSHBLE)
            try await BotRebindDiagnostics.run("native-mcp", attempt: attempt) {
                try self.ensureCurrentBind(bindingEpoch, host: newHost)
                await attachNativeMCP(DeviceMCPServer.shared)
            }
            #else
            try await BotRebindDiagnostics.run("native-mcp", attempt: attempt) {
                try self.ensureCurrentBind(bindingEpoch, host: newHost)
                await attachNativeMCP(ADBMCPServer.shared)
            }
            #endif
            #endif

            try ensureCurrentBind(bindingEpoch, host: newHost)
            try await BotRebindDiagnostics.run("outbox-handlers", attempt: attempt) {
                try self.ensureCurrentBind(bindingEpoch, host: newHost)
                await installOutboxHandlers()
            }
            try ensureCurrentBind(bindingEpoch, host: newHost)
            started = true
            if !recovering {
                // Seed before subscribing so a HELLO delivered immediately
                // after `observeHost` is compared with the boot this bind
                // actually attached, not a previous incarnation.
                try ensureCurrentBind(bindingEpoch, host: newHost)
                try await BotRebindDiagnostics.run("seed", attempt: attempt) {
                    let current = await newHost.currentWorkerBootID
                    await workerRecovery.seed(recoveredBootID: current)
                }
                try ensureCurrentBind(bindingEpoch, host: newHost)
            }
            try ensureCurrentBind(bindingEpoch, host: newHost)
            try await BotRebindDiagnostics.run("observe-host", attempt: attempt) {
                try self.ensureCurrentBind(bindingEpoch, host: newHost)
                await observeHost(newHost)
            }
            try ensureCurrentBind(bindingEpoch, host: newHost)
            try await BotRebindDiagnostics.run("outbox-start", attempt: attempt) {
                try self.ensureCurrentBind(bindingEpoch, host: newHost)
                await outbox.start()
            }
            try ensureCurrentBind(bindingEpoch, host: newHost)
            startTick()
            installDeviceTaskResultDelivery()
            state = .ready
            bindStep.end()
        } catch is CancellationError {
            bindStep.end(ok: false, error: CancellationError())
            throw CancellationError()
        } catch {
            if Task.isCancelled {
                bindStep.end(ok: false, error: CancellationError())
                throw CancellationError()
            }
            // A recovery bind's failure belongs to the scheduler's bounded
            // round: it schedules the next attempt or publishes the terminal
            // `.failed` phase once the budget is exhausted. Setting `.failed`
            // here would flash "重试" between attempts of the same round.
            if !recovering, bindingEpoch == self.bindEpoch, host === newHost {
                state = .failed("Bot 连接失败：\(error.localizedDescription)")
            }
            bindStep.end(ok: false, error: error)
            throw error
        }
    }

    /// Restarts only the units that cannot serve the current Worker
    /// incarnation. A live unit keeps its transport, main session, scheduler and
    /// running turn; only a unit that never attached, was detached, or whose
    /// last start failed is started again (and every unit when the bind is for a
    /// replaced Worker process).
    ///
    /// Returns the start errors of the skipped (non-selected) units. The
    /// selected Bot's error is rethrown: the page the user is on must show
    /// recovering/failed, while another Bot that failed to attach is skipped,
    /// logged, and retried by the next bind (it has no live transport, so it is
    /// always in the restart set).
    ///
    /// `BotRebindScope` is actor-neutral, so its callbacks are `@Sendable`.
    /// This composition and its units stay main-actor isolated: the closures
    /// hop explicitly, and the original `Error` of a failed unit is kept in an
    /// actor-owned box instead of a mutable captured dictionary (which a
    /// `@Sendable` callback must not mutate). The selected Bot's original
    /// `Error` is rethrown after the pass, never a formatted string.
    private func rebindUnits(on host: PhoneDSHHost, attempt: Int,
                             forceRestart: Bool,
                             selected: String?, bindEpoch: Int) async throws -> [String: Error] {
        actor RebindErrorBox {
            private var errors: [String: Error] = [:]

            func record(_ error: Error, for botID: String) {
                errors[botID] = error
            }

            func error(for botID: String) -> Error? {
                errors[botID]
            }

            func snapshot() -> [String: Error] {
                errors
            }
        }
        let errors = RebindErrorBox()
        var visited = Set<String>()
        // `select()` during this bind can create a unit after a pass took its
        // snapshot; take a bounded second look so a newly selected Bot is
        // attached before the bind completes instead of waiting for the next
        // one. No bind is ever started from the selection path.
        for _ in 0..<3 {
            try ensureCurrentBind(bindEpoch, host: host)
            let pending = units.filter { !visited.contains($0.key) }
            guard !pending.isEmpty else { break }
            let ordered = pending.sorted { lhs, rhs in
                if lhs.key == selected { return true }
                if rhs.key == selected { return false }
                return lhs.key < rhs.key
            }
            let outcome = await BotRebindScope.apply(
                ordered,
                forceRestart: forceRestart,
                state: { entry in await entry.value.rebindState() },
                restart: { entry in
                    do {
                        try await self.startUnit(entry.value, botID: entry.key,
                                                 on: host, attempt: attempt, bindEpoch: bindEpoch)
                    } catch {
                        await errors.record(error, for: entry.key)
                        throw error
                    }
                })
            try ensureCurrentBind(bindEpoch, host: host)
            visited.formUnion(ordered.map(\.key))
            for botID in outcome.kept {
                BotRebindDiagnostics.emit(
                    "bot-rebind step=unit-kept attempt=\(attempt) bot=\(botID)")
            }
            for botID in outcome.restarted {
                BotRebindDiagnostics.emit(
                    "bot-rebind step=unit-restarted attempt=\(attempt) bot=\(botID)")
            }
            for (botID, token) in outcome.failed where botID != selected {
                BotRebindDiagnostics.emit(
                    "bot-rebind step=unit-skipped attempt=\(attempt) bot=\(botID) \(token)")
                print("[BotRuntimeComposition] unit \(botID) start failed: \(token)")
            }
            if outcome.wasCancelled { throw CancellationError() }
            if let selected {
                if let error = await errors.error(for: selected) { throw error }
            }
        }
        if let selected {
            if let error = await errors.error(for: selected) { throw error }
        }
        return await errors.snapshot()
    }

    /// A Worker transport that stops answering must not surface as a silent
    /// infinite send. The runtime quarantines it once per generation; ask the
    /// existing recovery scheduler for a fresh bind without waiting for the
    /// whole recovery here (the runtime actor must stay free to fail other
    /// waiters).
    private func installTransportFailureHandler(for unit: BotRuntimeUnit, botID: String) {
        Task { [weak self] in
            await unit.remote.setTransportFailureHandler { [weak self] in
                guard let self else { return }
                await self.handleTransportFailure(botID: botID)
            }
        }
    }

    /// Enters the composition's actor from the runtime's Sendable failure
    /// callback. `forceRetry` only starts the scheduler's next attempt; the
    /// scheduler owns its bounded completion and retries.
    private func handleTransportFailure(botID: String) async {
        BotRebindDiagnostics.emit(
            "bot-rebind step=transport-stall bot=\(botID)")
        // During the manual rebind window the manual path owns the reattach;
        // a stalled automatic transport must not start a competing bind.
        guard !suppressesWorkerBootRebind else { return }
        await workerRecovery.forceRetry()
    }

    /// Creates this unit's transport for the bind and attaches it. Kept as one
    /// awaited step so the transport diagnostics carry the same `attempt` as
    /// the rest of the bind.
    private func startUnit(_ unit: BotRuntimeUnit, botID: String,
                           on host: PhoneDSHHost, attempt: Int, bindEpoch: Int) async throws {
        try ensureCurrentBind(bindEpoch, host: host)
        let channelDetail = BotRebindDiagnostics.channelDetail(
            await host.channelSelection())
        let transport = try await BotRebindDiagnostics.run(
            "transport", attempt: attempt,
            detail: "bot=\(botID) " + channelDetail
        ) {
            try await host.makeTransport()
        }
        try ensureCurrentBind(bindEpoch, host: host)
        let lease = unit.beginStart()
        try await unit.start(
            transport: transport, attempt: attempt,
            channelDetail: channelDetail,
            lease: lease,
            isOuterBindCurrent: { [weak self] in
                guard let self else { return false }
                // The bind epoch is the composition's outer fence: a stop,
                // detach or newer bind advances it, so this attempt stops even
                // before that newer lifecycle reaches the unit's detach.
                return self.bindEpoch == bindEpoch && self.host === host
            })
        try ensureCurrentBind(bindEpoch, host: host)
        installTransportFailureHandler(for: unit, botID: botID)
        // The main session is live, so any action a previous process persisted
        // before its remote turn can be replayed now. Detached: the bind must
        // not wait for a turn that may take minutes.
        schedulePendingActionReplay(for: unit, reason: "bind")
        try Task.checkCancellation()
    }

    /// Schedules the v4 outbox replay for one started unit. Missing rows are a
    /// single indexed read; a row that cannot be delivered stays pending.
    private func schedulePendingActionReplay(for unit: BotRuntimeUnit, reason: String) {
        // Deliberately off: an automatic replay turns a stale pending send into
        // an unsolicited turn, activity bubble and transcript scroll at launch.
        // The rows stay durable for a future user-initiated retry.
        guard BotPendingActionReplayPolicy.automaticReplay else { return }
        pendingActionReplay.schedule(botID: unit.botID, rows: unit.rows, reason: reason)
    }

    private func routineOwnerBotIDs() async -> [String] {
        var ids = Set<String>()
        for event in (try? await BotProductionEventReader.all(domain: domain)) ?? [] {
            guard event.type.hasPrefix("routine.") else { continue }
            if let bot = event.principal.botId { ids.insert(bot) }
        }
        return ids.sorted()
    }

    private func installOutboxHandlers() async {
        guard let router = routineRouter else { return }
        await outbox.register(kind: BotRoutineOutbox.kind) { lease in
            try await router.apply(lease)
        }
    }

    func attachNativeMCP(_ server: any NativeMCPServing) async {
        await handler.attachNativeMCP(BotNativeMCPForwarder(server: server))
    }

    func stop() async {
        await detachBinding()
        // The wake surfaces belong to the process, not to one host bind: a
        // device result that arrives while the engine is rebound must still
        // land durably. They are released only when the whole composition
        // stops.
        removeDeviceTaskResultDelivery()
        server.onToolCall = nil
        if let source = botWakeSource {
            await source.stop()
            botWakeSource = nil
        }
        // Interactive cards cannot survive the process; durable todos are
        // deliberate facts and remain for the next launch (spec/bot/v1 §2.7).
        await runtime.approvals.cancelInteractive(reason: "shutdown")
        _ = await runtime.gateway.attribution.prune()
        host = nil
        await hostReference.set(nil)
        started = false
        state = .stopped
    }

    private func detachBinding() async {
        // Fence before any teardown: every suspended bind/phase application
        // now fails its epoch check, so it cannot undo the detach below.
        bindEpoch &+= 1
        if let host { await host.setBackgroundTurnHoldProvider(nil) }
        botEgressPolicy?.installBotEgressApprover(nil)
        await runtime.installWorkbenchTurnProbe(nil)
        botEgressPolicy = nil
        for unit in units.values { await unit.detach() }
        await outbox.stop()
        tickTask?.cancel(); tickTask = nil
        hostTask?.cancel(); hostTask = nil
        await workerRecovery.stop()
        observedHost = nil
        started = false
    }

    // MARK: - Bot wake surfaces (PLAN §2.8)

    /// Installs the one Bot-channel wake hand-off before any host exists.
    ///
    /// Each channel signals only after its own durable write: a device task
    /// result has already been written to the journal and the held inbox, and
    /// a Bot MCP `tools/call` is already a live request on the loopback
    /// listener. The hook never starts the engine; the App bridge translates
    /// the signal into `EngineLaunchOrchestrator.shared.wake`, and the policy
    /// there decides boot / resume / native-only / defer.
    private func installBotWakeSource(mainBotID: String,
                                      now: @escaping @Sendable () -> Int64) async {
        let source = BotChannelWakeSource()
        botWakeSource = source
        #if os(iOS) && canImport(ProbeKit)
        await BotWakeBridge.install(source)
        #endif
        // A Worker `tools/call` while the Bot runtime is not ready is a local
        // listener request that needs the engine; a healthy runtime must never
        // create one wake per tool call. The readiness mirror is lock-protected
        // and safe to read from the listener thread.
        server.onToolCall = { [weak source, readinessState] in
            guard !readinessState.isReady, !readinessState.isTerminal else { return }
            source?.signal(botId: mainBotID,
                           reason: BotChannelWakeSource.lanRequestReason,
                           at: now())
        }
    }

    /// App-side connector wiring installs one scan closure and the durable
    /// outbox it feeds. Both are optional: a build with no authorized
    /// connector keeps the step `skipped("not-configured")`, while the outbox
    /// may still be present to replay an older unacknowledged interval.
    func installConnectorSweep(_ sweep: (() async throws -> [ConnectorUpdateRecord])?,
                               outbox: ConnectorUpdateOutbox?) {
        connectorSweep = sweep
        connectorUpdateOutbox = outbox
    }

    /// PLAN §2.9 I2: installs the App's durable WakeDemand sink and projects
    /// the current routine due times for every Bot on the roster once, so a
    /// launch with no engine still leaves the earliest due time on the host.
    /// The sink is idempotent by `(source, key)`.
    func installWakeDemandSink(_ sink: any BotWakeDemanding) async {
        wakeDemandSink = sink
        await sink.removeAll(source: BotWakeDemand.botRoutineSource)
        await projectRoutineDemands()
    }

    /// Re-projects every Bot's earliest routine due time into the ledger.
    /// Called at install and from a scheduler state change (via the unit's
    /// demand hook). Bots with no runnable routine have their demand removed.
    func projectRoutineDemands() async {
        guard let sink = wakeDemandSink else { return }
        let machine = await runtime.routineMachine
        let roster = (try? await profileStore.roster()) ?? BotRoster(bots: [], mainBotID: nil)
        for bot in roster.bots {
            let routines = (try? await machine.list(botId: bot.id)) ?? []
            if let demand = RoutineDemandProjection.demand(botID: bot.id, routines: routines) {
                await sink.upsert(demand)
            } else {
                await sink.remove(source: BotWakeDemand.botRoutineSource, key: bot.id)
            }
        }
    }

    // MARK: - Device task results

    private func installDeviceTaskResultDelivery() {
        guard !deliversDeviceTaskResults else { return }
        deliversDeviceTaskResults = true
        DeviceTaskManager.shared.installTaskSettlementHandler(owner: self) { [weak self] settlement, displayName in
            guard let self, self.deliversDeviceTaskResults else { return }
            self.enqueueDeviceTaskResult(settlement, displayName: displayName)
        }
    }

    private func removeDeviceTaskResultDelivery() {
        deliversDeviceTaskResults = false
        DeviceTaskManager.shared.removeTaskSettlementHandler(owner: self)
    }

    private func enqueueDeviceTaskResult(_ settlement: DeviceTaskSettlement, displayName: String) {
        let status: DeviceTaskResultNotice.Status
        let result: String
        switch settlement.outcome {
        case .completed(let output, _):
            status = .completed
            result = output
        case .failed(let kind, let message):
            status = DeviceTaskResultNotice.Status(rawValue: kind.rawValue) ?? .failed
            result = message
        }
        let notice = DeviceTaskResultNotice(
            deviceID: settlement.deviceID,
            deviceDisplayName: displayName,
            taskID: settlement.taskID,
            idempotencyKey: settlement.idempotencyKey,
            goal: settlement.goal,
            status: status,
            result: result,
            createdAt: botProductionNowMilliseconds())
        Task { [weak self] in
            guard let self else { return }
            do {
                let roster = try await self.profileStore.roster()
                guard let botID = BotMainPointerRouting.deviceTaskRecipient(in: roster) else { return }
                let unit = try await self.ensureUnit(for: botID, reason: "device-result")
                let enqueued = try await unit.deviceResults.enqueue(
                    notice, botID: botID, in: unit.wakeInbox)
                // A startup replay may already have inserted this exact item;
                // do not bump unread twice for one terminal result.
                guard !enqueued.duplicate else { return }
                // PLAN §2.8: the result is durable and in the held inbox now
                // (write-before-enqueue + ack), so this Bot channel may ask the
                // launch orchestrator for a wake. The wake only decides *when*
                // the durable item is executed; it never grants a tool or a
                // device reply path.
                self.botWakeSource?.signal(
                    botId: botID,
                    reason: BotChannelWakeSource.bleRequestReason,
                    at: botProductionNowMilliseconds())
                let selected = self.rosterModel.selectedBotID
                await self.rosterModel.noteMessage(
                    to: botID,
                    bumpUnread: BotUnreadRules.shouldIncrementForDelivery(
                        to: botID, selectedBotID: selected),
                    at: botProductionNowMilliseconds())
            } catch {
                print("[BotRuntimeComposition] device task result delivery failed: \(error)")
            }
        }
    }

    /// Declares the live Bot turns to the host so a graceful background park
    /// refuses to abort them. Before this seam, the host's park cancelled every
    /// tracked session (`abortOpenSessionTurns`), so a park that won a race with
    /// the App's keep-alive decision silently killed the other Bot's turn.
    private func installParkHold(on host: PhoneDSHHost) async {
        await host.setBackgroundTurnHoldProvider { [weak self] in
            guard let self else { return nil }
            return await self.heldParkSessions()
        }
    }

    /// The sessions whose turn the App is still holding. Asked at park time, so
    /// a turn that finished (or a unit that was detached) is not protected.
    private func heldParkSessions() async -> PhoneDSHBackgroundTurnHold? {
        guard !suppressesParkHold else { return nil }
        var sessions = Set<String>()
        for unit in units.values where unit.started {
            sessions.formUnion(await unit.remote.inFlightSessionIDs())
        }
        guard !sessions.isEmpty else { return nil }
        return PhoneDSHBackgroundTurnHold(sessionIDs: sessions, reason: "Bot 正在执行任务")
    }

    /// The background keep-alive branch: any attached Bot with a routine due
    /// inside the window keeps the silent-audio session alive even when no
    /// turn is running.
    func hasRoutineDueSoon(within windowMs: Int64 = RoutinePresencePolicy.keepAliveWindowMs) async -> Bool {
        for unit in units.values {
            if await unit.hasRoutineDueSoon(within: windowMs) { return true }
        }
        return false
    }

    // MARK: - ReadySweep (Bot steps 4–7)

    #if canImport(ProbeKit)
    /// Runs the Bot-owned ReadySweep steps in contract order
    /// (`botHeldInbox`, `missedRoutines`, `connectorScan`, `approvalReminderSync`).
    ///
    /// The launch orchestrator owns steps 1–3 and merges this report into the
    /// full seven-step report. Every step is gated immediately before it
    /// starts by the shared `ReadySweepPolicy`; an unavailable lease leaves the
    /// step whole for the next wake (`skipped("lease")`). Each step is
    /// idempotent, so a repeated sweep is safe:
    /// - held inbox replay only wakes pending items and the remote coalesces
    ///   concurrent wakes;
    /// - routine catch-up goes through the scheduler's existing claim/lease;
    /// - the connector scan dedupes by cursor range and persists before it
    ///   enqueues;
    /// - approval reminders reconcile by their durable approval ids.
    func runReadySweep(_ context: ReadySweepContext) async -> ReadySweepReport {
        let budget = BotReadySweepBudget(
            remainingMs: { context.remainingMs() },
            shouldRun: { step, remaining in
                guard let shared = Self.sharedSweepStep(step) else { return false }
                return ReadySweepPolicy.shouldRun(shared, remainingMs: remaining)
            })
        let runner = BotReadySweepRunner(budget: budget, action: { [weak self] step in
            guard let self else { throw CancellationError() }
            try await self.performReadySweepStep(step)
        })
        let report = await runner.run()
        let steps: [ReadySweepReport.StepResult] = report.steps.compactMap { result in
            guard let shared = Self.sharedSweepStep(result.step) else { return nil }
            return ReadySweepReport.StepResult(
                step: shared, outcome: Self.sharedSweepOutcome(result.outcome))
        }
        return ReadySweepReport(steps: steps)
    }

    /// One step body. It is only entered after the lease gate approved the
    /// step, and it never starts a later step itself.
    private func performReadySweepStep(_ step: BotReadySweepStep) async throws {
        switch step {
        case .botHeldInbox:
            try await performHeldInboxReplay()
        case .missedRoutines:
            try await performRoutineCatchUp()
        case .connectorScan:
            guard let connectorSweep else {
                // The connector wiring is assembled by the App (tokens and the
                // Gmail/GitHub clients are App-side); a build without it skips
                // the whole step instead of half-scanning.
                throw BotReadySweepSkip(reason: "not-configured")
            }
            let records = try await connectorSweep()
            // PLAN §2.9: a successful scan schedules its own next due time.
            // The minimum interval is a contract constant; until the App
            // injects it, the scan stays wake-driven and no value is invented.
            if let interval = connectorScanDemandIntervalMs, let sink = wakeDemandSink {
                await sink.upsert(BotWakeDemand(
                    source: BotWakeDemand.connectorScanSource, key: "configured",
                    dueAtMs: botProductionNowMilliseconds() + interval,
                    kind: .recurring, userVisible: false))
            }
            guard !records.isEmpty else { return }
            // The records and their held items are durable. The main Bot's
            // conversation is the one that processes them: consider each
            // metadata update through the existing proactive policy (dnd,
            // quiet hours and the frequency fuse apply; no new budget, quota,
            // cooldown or TTL), then open the ordinary held-message wake.
            guard let mainBotID = rosterModel.mainBotID,
                  let unit = units[mainBotID], unit.started else { return }
            let sources = ProactiveSources(now: { botProductionNowMilliseconds() })
            for record in records {
                let eventID = "connector-update:" + record.digest
                if let candidate = await sources.connectorCandidate(
                    for: record, botId: mainBotID, eventId: eventID) {
                    _ = await unit.proactive.consider(candidate)
                }
            }
            try await unit.remote.wakeWithHeldMessages()
        case .approvalReminderSync:
            await syncApprovalNotifications()
        }
    }

    /// Step 4: durable device-task results first (write-before-enqueue replay),
    /// then the Bot's own held-inbox wake. Only started units are touched: a
    /// unit without a host has no session to deliver to, and its pending items
    /// stay durable for the next wake.
    private func performHeldInboxReplay() async throws {
        var firstError: Error?
        let mainBotID = rosterModel.mainBotID
        for unit in units.values where unit.started {
            do {
                _ = try await unit.deviceResults.redeliver(
                    botID: unit.botID, in: unit.wakeInbox)
                // Connector updates target the main Bot's conversation; replay
                // an unacknowledged interval from the same durable outbox before
                // the wake, so a crash between record and enqueue heals here.
                if unit.botID == mainBotID, let outbox = connectorUpdateOutbox {
                    _ = try await outbox.redeliver(botID: unit.botID, in: unit.wakeInbox)
                }
                try await unit.remote.wakeWithHeldMessages()
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                firstError = firstError ?? error
            }
        }
        if let firstError { throw firstError }
    }

    /// Step 5: the scheduler's own `tick()` is the catch-up pass. One call runs
    /// at most one occurrence per routine and advances `nextRunAt` past now,
    /// so several missed occurrences become one run; quiet hours/dnd and the
    /// claim lease keep their existing behaviour.
    private func performRoutineCatchUp() async throws {
        var firstError: Error?
        for unit in units.values where unit.started {
            do {
                try await unit.scheduler.tick()
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                firstError = firstError ?? error
            }
        }
        if let firstError { throw firstError }
    }

    nonisolated static func sharedSweepStep(_ step: BotReadySweepStep) -> ReadySweepStep? {
        switch step {
        case .botHeldInbox: return .botHeldInbox
        case .missedRoutines: return .missedRoutines
        case .connectorScan: return .connectorScan
        case .approvalReminderSync: return .approvalReminderSync
        }
    }

    nonisolated static func sharedSweepOutcome(_ outcome: BotReadySweepOutcome) -> ReadySweepOutcome {
        switch outcome {
        case .ran: return .ran
        case .skipped(let reason): return .skipped(reason: reason)
        case .failed(let reason): return .failed(reason: reason)
        }
    }
    #endif

    // MARK: - Tick / observation

    private func startTick() {
        guard tickTask == nil else { return }
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                for unit in self.units.values {
                    _ = await unit.remote.watchdogMonitor().tick()
                }
                await self.refreshRuntimeStates()
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    /// Publishes live fish/activity/running/approval state to the roster model
    /// every tick. Pending approvals are rescanned less often because that
    /// walks the durable event log.
    private func refreshRuntimeStates() async {
        pendingApprovalTicks += 1
        let approvals: [String: Int]
        if pendingApprovalTicks % 3 == 0 || pendingApprovalTicks == 1 {
            approvals = await pendingApprovalCounts()
            await syncApprovalNotifications()
        } else {
            approvals = rosterModel.entries.reduce(into: [:]) {
                $0[$1.id] = $1.pendingApprovalCount
            }
        }
        for (botID, unit) in units {
            let snapshot = await unit.statusSnapshot(
                pendingApprovalCount: approvals[botID] ?? 0,
                runtimeState: state)
            rosterModel.setRuntimeState(snapshot, for: botID)
        }
    }

    /// Keeps one pre-scheduled local reminder per durable approval. The
    /// in-app card remains the only place to act (spec/ui/v1 bot-chat §17);
    /// the notification just brings the user back to that card.
    private func syncApprovalNotifications() async {
        #if os(iOS) && canImport(UserNotifications)
        // Local reminders belong to the launched iOS App. The macOS eval
        // harness links the same composition but has no application bundle;
        // `UNUserNotificationCenter.current()` throws there.
        guard Bundle.main.bundleURL.pathExtension == "app" else { return }
        let records = await runtime.approvals.pendingNotificationRecords()
        let reconciler: BotApprovalNotificationReconciler
        if let existing = approvalNotifications {
            reconciler = existing
        } else {
            let now: @Sendable () -> Int64 = schedulerNow ?? {
                Int64(Date().timeIntervalSince1970 * 1_000)
            }
            let created = BotApprovalNotificationReconciler(
                scheduling: UNUserNotificationApprovalScheduling(), now: now)
            approvalNotifications = created
            reconciler = created
        }
        _ = await reconciler.sync(records)
        #endif
    }

    private func pendingApprovalCounts() async -> [String: Int] {
        var requested: [String: Set<String>] = [:]
        var decided = Set<String>()
        for event in (try? await BotProductionEventReader.all(domain: domain)) ?? [] {
            guard let botID = event.principal.botId else { continue }
            switch event.type {
            case "approval.requested":
                if let id = event.data["approvalID"]?.stringValue { requested[botID, default: []].insert(id) }
            case "approval.decided":
                if let id = event.data["approvalID"]?.stringValue { decided.insert(id) }
            default:
                break
            }
        }
        return requested.reduce(into: [:]) { result, entry in
            let count = entry.value.filter { !decided.contains($0) }.count
            if count > 0 { result[entry.key] = count }
        }
    }

    /// Re-claims one session after the Worker rejected its registration. The
    /// Bot that owns the session does the claim; a session from another unit
    /// is never touched, and a cross-session token is refused by the remote.
    private func reclaimSessionForIdentity(_ sessionId: String,
                                           suppliedToken: String) async -> Bool {
        for unit in units.values {
            if await unit.remote.reclaimSessionForIdentity(
                sessionId, suppliedToken: suppliedToken) {
                return true
            }
        }
        return false
    }

    private func beginManualWorkerRebind() async {
        suppressesWorkerBootRebind = true
        // This rebind parks the host itself. Its author wants the in-flight Bot
        // work interrupted (the eraser marks the window with
        // `beginHostPark`), so the background-park hold must not refuse it.
        suppressesParkHold = true
        // The manual path is the only rebind for this Worker boot. Release
        // any armed ready gate/attempt so it cannot race the park/start.
        // Awaited so the manual fence is installed before the caller parks the
        // host and before any later event can observe a new bind.
        //
        // Fence the composition first: an automatic bind that is already
        // suspended fails its next epoch check instead of reinstalling egress
        // or publishing ready after the manual sequence took over.
        bindEpoch &+= 1
        await workerRecovery.beginManualRebind()
        // The parked Worker loses its in-memory registrations and every live
        // Task turn. This is the same transition an automatic bind performs;
        // without it a Task cut by the park settles as `failed` instead of
        // `interrupted`, and its wake is never queued.
        await runtime.workerRestarted()
    }

    private func endManualWorkerRebind(succeeded: Bool) async {
        suppressesParkHold = false
        if succeeded, let host {
            // The manual eraser parked/started the host and re-attached the
            // unit itself, including the new main session. Record the current
            // Worker boot as already bound so the page leaves recovering.
            let current = await host.currentWorkerBootID
            await workerRecovery.completeManualRebind(recoveredBootID: current)
        } else {
            await workerRecovery.failManualRebind("Bot 连接没有恢复，请重试。")
        }
        suppressesWorkerBootRebind = false
    }

    private func observeHost(_ host: PhoneDSHHost) async {
        if observedHost === host, hostTask != nil { return }
        hostTask?.cancel()
        observedHost = host
        hostTask = Task { [weak self, remote] in
            defer {
                if let self, self.observedHost === host {
                    self.observedHost = nil
                    self.hostTask = nil
                }
            }
            for await event in host.eventStream() {
                guard let self else { return }
                guard self.isAttached(host) else { return }
                switch event {
                case .webContentTerminated(let count):
                    _ = await remote.watchdogMonitor().observeMobile(
                        .webcontentTerminated, kind: .turn, id: "phone-host",
                        botId: self.environment.botID,
                        evidence: ["count": .number(Double(count))])
                    // Do not bind here: the old Worker is dead and the
                    // replacement has not HELLOed yet. The HELLO below is the
                    // point where a transport can actually answer.
                    if !self.suppressesWorkerBootRebind {
                        await self.workerRecovery.noteTermination(count: count)
                    }
                case .restarted(let report):
                    // Page boot-ready precedes the ordered-channel HELLO.
                    // Remember the boot id for a retry target, but wait for
                    // `.workerHello` before opening a transport.
                    await self.workerRecovery.noteBootCandidate(report.bootID)
                case .workerHello(let hello):
                    if self.suppressesWorkerBootRebind {
                        await self.workerRecovery.noteBootCandidate(hello.bootID)
                    } else {
                        // The HELLO count discards a duplicate; the termination
                        // event decides that this connection is the replacement,
                        // so a reused boot id still rebinds.
                        await self.workerRecovery.noteWorkerBoot(
                            hello.bootID, helloCount: hello.count,
                            fenceGeneration: hello.generation)
                    }
                case .console(let payload):
                    // The Worker installs its ordered-channel API bridge
                    // immediately before it logs this reserved boot phase.
                    // Binding on the earlier HELLO can send the first
                    // `session/page` into a dropped window; the scheduler waits
                    // for this `ready` line (bounded fallback for a bundle that
                    // does not forward it).
                    if let phase = PhoneDSHBootPhase.parse(payload.text),
                       phase.scope == "worker", phase.phase == "ready" {
                        await self.workerRecovery.noteWorkerReady()
                    }
                default:
                    break
                }
            }
        }
    }

    private func isAttached(_ host: PhoneDSHHost) -> Bool { self.host === host }

    /// Roster-aware tool definitions for the current caller. This is the App
    /// entry point for `BotToolCatalog.allDefinitions(roster:callerBotID:)`.
    ///
    /// The library's `BotMCPHandler.tools/list` still encodes the static
    /// catalog because `tools/list` has no Bot session identity and the handler
    /// has no catalog-provider hook. The app therefore cannot substitute this
    /// list on the wire without a library change (reported in the handoff);
    /// team tools are still routed by `registerTeamTools` at execute time.
    func toolDefinitions(callerBotID: String?) -> [BotMCPToolDefinition] {
        BotToolCatalog.allDefinitions(roster: rosterModel.roster,
                                      callerBotID: callerBotID)
    }

    // MARK: - Roster observation
    // MARK: - Roster observation

    private func startRosterObservation() {
        guard rosterTask == nil else { return }
        rosterTask = Task { [weak self, profileStore] in
            let updates = await profileStore.rosterUpdates()
            for await snapshot in updates {
                guard let self else { return }
                await self.reconcileRoster(snapshot)
            }
        }
    }

    private func reconcileRoster(_ snapshot: BotRoster) async {
        let ids = Set(snapshot.bots.map(\.id))
        for botID in units.keys where !ids.contains(botID) {
            if let unit = units.removeValue(forKey: botID) {
                await unit.abortRunningWork()
                await unit.detach()
            }
            agentCommTracker.reset(for: botID)
        }
        if let selected = rosterModel.selectedBotID, ids.contains(selected),
           started, units[selected] == nil {
            _ = try? await ensureUnit(for: selected)
        }
    }

    // MARK: - Session archive / delete cascade

    /// The full delete cascade. The profile record is removed by the last
    /// durable step; a failure before it leaves the Bot in the roster and the
    /// UI reports the exact blocking step. Reversible in-memory work (cached
    /// models, selection, units) is torn down only after the record is gone.
    func deleteBot(_ botID: String) async throws {
        let roster = try await profileStore.roster()
        guard roster.bots.contains(where: { $0.id == botID }) else {
            throw BotProfileStoreError.unknownBot(botID)
        }
        guard roster.bots.count > 1 else {
            rosterModel.deletionError = BotProfileStoreError.lastBot.description
            throw BotProfileStoreError.lastBot
        }
        let unit = units[botID]
        let sessions = await sessionIDs(for: botID)
        let previousSelection = rosterModel.selectedBotID
        var pendingApprovalIDs: [String] = []
        var archiveReceipt = BotSessionArchiveCascade.Receipt()

        let plan = BotDeletionPlan(steps: [
            BotDeletionStep(name: "abort-turns") { [weak self] in
                _ = self
                await unit?.abortRunningWork()
            },
            BotDeletionStep(name: "deny-approvals") { [weak self] in
                guard let self else { return }
                pendingApprovalIDs = await self.pendingApprovals(for: botID)
                for approvalID in pendingApprovalIDs {
                    guard let digest = await self.runtime.approvals.pendingDigest(approvalId: approvalID) else { continue }
                    _ = await self.runtime.approvals.resolve(
                        approvalId: approvalID, decision: .deny, digest: digest)
                }
            },
            BotDeletionStep(name: "revoke-auth") { [weak self] in
                guard let self else { return }
                await self.runtime.gateway.tokens.revokeBot(botID)
                _ = try await self.runtime.grants.revokeBot(botID)
            },
            BotDeletionStep(name: "archive-sessions") { [weak self] in
                guard let self else { return }
                archiveReceipt = await self.archiveSessions(sessions)
            } rollback: { [weak self] in
                // GAP-45: a later step failed and the Bot stays. An archived session is gated
                // as `blocked` by the Worker, so lift what this cascade archived.
                guard let self else { return }
                await self.restoreArchivedSessions(archiveReceipt)
            },
            BotDeletionStep(name: "clear-routines") { [weak self] in
                guard let self else { return }
                let machine = await self.runtime.routineMachine
                let routines = (try? await machine.list(botId: botID)) ?? []
                for routine in routines {
                    _ = try? await machine.delete(botId: botID, routineId: routine.id)
                }
                await self.wakeDemandSink?.remove(
                    source: BotWakeDemand.botRoutineSource, key: botID)
            },
            BotDeletionStep(name: "clear-held") { [weak self] in
                guard let self else { return }
                try await self.clearWakeInbox(for: botID)
            },
            BotDeletionStep(name: "erase-memory") { [weak self] in
                guard let self else { return }
                _ = try await self.runtime.deleteBotMemory(for: botID)
            },
            BotDeletionStep(name: "forget-memory") { [weak self] in
                guard let self else { return }
                _ = await self.runtime.forgetMemory(for: botID)
            },
            BotDeletionStep(name: "unregister-sessions") {
                for sessionID in sessions {
                    BotSessionRegistry.shared.unregister(sessionID)
                }
            },
            BotDeletionStep(name: "delete-profile") { [weak self] in
                guard let self else { return }
                _ = try await self.profileStore.deleteBot(id: botID)
            },
            BotDeletionStep(name: "teardown-caches") { [weak self] in
                guard let self else { return }
                if let unit = self.units.removeValue(forKey: botID) {
                    await unit.detach()
                }
                self.agentCommTracker.reset(for: botID)
                self.agentCommThreads = self.agentCommThreads.filter {
                    !$0.key.hasPrefix(botID + "\u{0}")
                }
                self.onBotDeleted?(botID)
                await self.rosterModel.refresh()
                if previousSelection == botID {
                    let next = self.rosterModel.mainBotID
                        ?? self.rosterModel.bots.first?.id
                    if let next { try? await self.select(next) }
                }
            },
        ])
        do {
            try await plan.run()
            rosterModel.deletionError = nil
        } catch {
            rosterModel.deletionError = String(describing: error)
            throw error
        }
    }

    private func pendingApprovals(for botID: String) async -> [String] {
        var requested: [String: Set<String>] = [:]
        var decided = Set<String>()
        for event in (try? await BotProductionEventReader.all(domain: domain)) ?? [] {
            guard event.principal.botId == botID else { continue }
            switch event.type {
            case "approval.requested":
                if let id = event.data["approvalID"]?.stringValue {
                    requested[botID, default: []].insert(id)
                }
            case "approval.decided":
                if let id = event.data["approvalID"]?.stringValue { decided.insert(id) }
            default:
                break
            }
        }
        return (requested[botID] ?? []).filter { !decided.contains($0) }.sorted()
    }

    private func sessionIDs(for botID: String) async -> [String] {
        var ids = Set<String>()
        ids.insert("gb-\(BotWorkspaceLayout.safePathComponent(botID))")
        for event in (try? await BotProductionEventReader.all(domain: domain)) ?? [] {
            guard event.principal.botId == botID else { continue }
            if let sessionID = event.principal.sessionId, !sessionID.isEmpty { ids.insert(sessionID) }
            if let sessionID = event.data["sessionId"]?.stringValue, !sessionID.isEmpty {
                ids.insert(sessionID)
            }
        }
        return ids.sorted()
    }

    private func archiveSessions(_ sessions: [String]) async -> BotSessionArchiveCascade.Receipt {
        guard let host, let transport = try? await host.makeTransport() else {
            return BotSessionArchiveCascade.Receipt()
        }
        return await BotSessionArchiveCascade.archive(sessions, via: transport)
    }

    private func restoreArchivedSessions(_ receipt: BotSessionArchiveCascade.Receipt) async {
        guard !receipt.archivedHere.isEmpty,
              let host, let transport = try? await host.makeTransport() else { return }
        await BotSessionArchiveCascade.restore(receipt, via: transport)
    }

#if DEBUG
    /// DEBUG self-test diagnostic: the Worker's archived-session set. `unarchiveSession` on an id
    /// that is not archived is an idempotent no-op that returns the resulting set, so this only
    /// reads. Never compiled into a release build.
    func debugArchivedSessionIDs(unarchive sessionID: String = "zz-diagnostic-none") async -> [String]? {
        guard let host, let transport = try? await host.makeTransport(),
              let value = try? await transport.call("workspace/unarchiveSession", args: .object([
                  "request": .object(["sessionId": .string(sessionID)]),
              ])) else { return nil }
        return value["archivedSessionIds"]?.arrayValue?.compactMap { $0.stringValue }
    }
#endif

    private func clearWakeInbox(for botID: String) async throws {
        let store = SQLiteWakeInboxStore(domainStore: domain, botId: botID)
        _ = try await store.mutate { document in
            let removed = document.items.count
            document.items.removeAll()
            return WakeInboxMutation(
                value: removed, persistSnapshot: removed > 0,
                eventType: "comm.reply",
                eventId: "wake-inbox:clear:\(botID):\(UUID().uuidString.lowercased())")
        }
    }
}

// MARK: - BotTeamHost

extension BotRuntimeComposition: BotTeamHost {
    /// `BotTeamTools.toolDefinitions` runs the per-caller catalog check on
    /// every `tools/call`. `roster()` only reads the profile-store actor, so
    /// it must not be pinned to the composition's main actor.
    nonisolated func roster() async throws -> BotRoster {
        try await profileStore.roster()
    }

    func createBot(name: String, description: String, color: BotFishColor?,
                   hairstyle: BotFishHairstyle?) async throws -> BotProfile {
        try await createBot(
            name: name, description: description, color: color,
            hairstyle: hairstyle, author: nil)
    }

    func createBot(name: String, description: String, color: BotFishColor?,
                   hairstyle: BotFishHairstyle?,
                   author: BotTeammateAuthor?) async throws -> BotProfile {
        let created = try await profileStore.createBot(
            name: name, fishColor: color, fishHairstyle: hairstyle,
            description: description.isEmpty ? nil : description)
        if let author {
            let eventID = "teammate-created-\(created.id)"
            var authorFields: [String: PhoneDSHBot.BotJSONValue] = [
                "origin": .string(author.origin.rawValue),
                "authorization": .string(author.authorization.rawValue),
            ]
            func put(_ key: String, _ value: String?) {
                authorFields[key] = value.map { .string($0) } ?? .null
            }
            put("rpcId", author.rpcId)
            put("turnId", author.turnId)
            put("sessionId", author.sessionId)
            put("approvalID", author.approvalID)
            let data: [String: PhoneDSHBot.BotJSONValue] = [
                "event": .string("teammate.created"),
                "agentId": .string(created.id),
                "name": .string(created.name),
                "description": .string(created.description),
                "author": .object(authorFields),
            ]
            let event = BotEvent(
                type: "ui.system_event", eventId: eventID,
                time: botProductionNowMilliseconds(), origin: .local(source: "comm-service"),
                traceId: eventID,
                principal: BotPrincipal(
                    botId: created.id, sessionId: author.sessionId, kind: "team"),
                causationId: nil, correlationId: author.rpcId, data: .object(data))
            do {
                _ = try await domain.append(event)
            } catch {
                // The Bot exists; the audit is best-effort only if the journal
                // rejects the event. Do not roll back a created Bot for an
                // audit write, but never silently claim it was recorded.
                print("[BotRuntimeComposition] teammate author audit failed: \(error)")
            }
        }
        await enqueueOnboarding(botID: created.id)
        await rosterModel.refresh()
        try? await wakeOnboardingIfPossible(botID: created.id)
        return created
    }

    /// Creation enqueues the one-time opening item; do not run a turn here.
    /// `BotRuntimeUnit.start` wakes it after the Worker/session is ready, or the
    /// user's first turn stages it as a held block. The deterministic request
    /// id makes a retry idempotent.
    private func enqueueOnboarding(botID: String) async {
        do {
            let inbox = WakeInbox(store: SQLiteWakeInboxStore(domainStore: domain, botId: botID))
            _ = try await inbox.enqueue(
                try BotOnboarding.item(botID: botID, now: botProductionNowMilliseconds()))
        } catch {
            print("[BotRuntimeComposition] onboarding enqueue failed for \(botID): \(error)")
        }
    }

    /// Creation should open promptly, not only when the user happens to tap
    /// the new Bot. Starting a unit is asynchronous and may need the Worker;
    /// if that fails the durable item stays pending for the first session.
    private func wakeOnboardingIfPossible(botID: String) async {
        let inbox = units[botID]?.wakeInbox
            ?? WakeInbox(store: SQLiteWakeInboxStore(domainStore: domain, botId: botID))
        guard await BotOnboarding.hasPending(in: inbox) else { return }
        if let unit = units[botID] {
            try? await unit.remote.wakeWithHeldMessages()
            return
        }
        guard started else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let unit = try await self.ensureUnit(for: botID, reason: "onboarding")
                if await BotOnboarding.hasPending(in: unit.wakeInbox) {
                    try? await unit.remote.wakeWithHeldMessages()
                }
            } catch {
                print("[BotRuntimeComposition] onboarding wake failed for \(botID): \(error)")
            }
        }
    }

    func agentCommContext(for botID: String) async -> BotAgentCommContext {
        await loadAgentCommThreadsIfNeeded()
        let context = agentCommTracker.context(for: botID)
        let turn = await currentTurnNumber(for: botID)
        return BotAgentCommContext(
            depth: context.depth,
            chain: context.chain,
            turn: turn,
            existingRowIDs: agentCommTracker.existingRowIDs(for: botID),
            inbound: context.inbound)
    }

    func existingAgentCommThread(botID: String, requestID: String) async -> String? {
        await loadAgentCommThreadsIfNeeded()
        return agentCommThreads["\(botID)\u{0}\(requestID)"]
    }

    func deliverToAgent(_ request: BotAgentDeliveryRequest) async throws -> BotAgentDeliveryReply {
        let unit = try await ensureUnit(for: request.target.id, reason: "team-now")
        let busy = await unit.remote.isMainTurnBusy()
        let decision = BotTeamDeliveryPolicy.decide(
            delivery: request.delivery, targetBusy: busy)
        switch decision {
        case .openVisibleTurn:
            agentCommTracker.setActive(
                .init(depth: request.hop, chain: request.chain,
                      inbound: inboundHop(for: request)),
                for: request.target.id)
            defer { agentCommTracker.clearActive(for: request.target.id) }
            let result = try await unit.remote.sendAgentMessage(
                request.promptText, requestId: request.requestId)
            guard result.status == "completed" else {
                throw BotTeamHostError.deliveryFailed(
                    "target turn ended with \(result.status)\(result.error.map { ": \($0)" } ?? "")")
            }
            return BotAgentDeliveryReply(text: result.text, status: result.status)

        case .queueHeldAndWakeAfterBusy, .queueHeldOnly:
            let item = try makeHeldItem(for: request)
            let enqueued = try await unit.wakeInbox.enqueue(item)
            if decision == .queueHeldOnly {
                agentCommTracker.setPendingHeld(
                    .init(depth: request.hop, chain: request.chain), for: request.target.id)
                return BotAgentDeliveryReply(
                    text: "已排队：\(request.target.name) 会在下一个回合收到这条消息。",
                    status: "queued")
            }
            guard !enqueued.duplicate else {
                // A replay of the same request is already pending; do not open
                // a second turn just because the first wake is still running.
                return BotAgentDeliveryReply(
                    text: "已排队：\(request.target.name) 会在下一个回合收到这条消息。",
                    status: "queued")
            }
            agentCommTracker.setActive(
                .init(depth: request.hop, chain: request.chain,
                      inbound: inboundHop(for: request)),
                for: request.target.id)
            defer { agentCommTracker.clearActive(for: request.target.id) }
            let cursor = await latestCommitSeq()
            let deadline = Date().addingTimeInterval(300)
            while true {
                try await waitUntilIdle(unit, deadline: deadline)
                try await unit.wakeHeldMessages()
                let items = (try? await unit.wakeInbox.items()) ?? []
                if !items.contains(where: { $0.id == item.id && $0.state == .pending }) {
                    break
                }
                if Date() > deadline { throw BotTeamHostError.deliveryTimeout }
            }
            let text = await lastAssistantText(botID: request.target.id, after: cursor)
                ?? "（\(request.target.name) 已完成回合，但没有文本回复。）"
            return BotAgentDeliveryReply(text: text, status: "completed")
        }
    }

    func enqueueHeld(_ request: BotTeamHeldRequest) async throws -> WakeInboxEnqueue {
        let unit = try await ensureUnit(for: request.botID, reason: "team-held")
        // Only a new outbound hop installs a chain on the target. The tool
        // passes nil for a teammate's reply held item, so receiving an answer
        // never makes the original sender look like part of the chain. The
        // hand-off also carries the inbound hop, which is what lets the target
        // answer its immediate previous hop (`team.md` §2.3.1).
        if let handOff = request.handOff {
            agentCommTracker.setPendingHeld(
                .init(depth: handOff.depth, chain: handOff.chain,
                      inbound: handOff.inbound),
                for: request.botID)
        }
        let enqueued = try await unit.wakeInbox.enqueue(request.item)
        // The explicit reply to a `now` hand-off wakes the sender once,
        // best-effort. A duplicate enqueue never wakes, and a busy sender
        // simply folds the durable item into its next turn.
        if request.wake, !enqueued.duplicate {
            try? await unit.wakeHeldMessages()
        }
        return enqueued
    }

    func recordAgentComm(_ record: BotTeamAgentCommRecord) async throws {
        let event = BotEvent(
            type: "agent.comm",
            eventId: "agent.comm:\(record.rowID)",
            time: botProductionNowMilliseconds(),
            origin: .local(source: "comm-service"),
            traceId: "agent-comm:\(record.threadID)",
            principal: BotPrincipal(botId: record.botID, sessionId: nil, kind: "team"),
            causationId: nil,
            correlationId: record.requestID,
            data: record.eventData)
        _ = try await domain.append(event)
        agentCommTracker.addRowID(record.rowID, for: record.botID)
        if record.direction == .outbound {
            agentCommThreads["\(record.botID)\u{0}\(record.requestID)"] = record.threadID
        }
        // A reply row carries the exchange requestID, so its own callID is the
        // durable idempotency key (`team.md` §2.4). The bare-callID key is the
        // same compatibility seam pre-WP4 outbound rows use.
        if record.direction == .reply, let callID = record.callID, !callID.isEmpty {
            agentCommThreads["\(record.botID)\u{0}\(callID)"] = record.threadID
        }
        let recipient = BotUnreadRules.recipient(for: record)
        if let recipient {
            let selected = rosterModel.selectedBotID
            await rosterModel.noteMessage(
                to: recipient,
                bumpUnread: BotUnreadRules.shouldIncrement(
                    recipient: recipient, selectedBotID: selected),
                at: botProductionNowMilliseconds())
        }
    }

    private func currentTurnNumber(for botID: String) async -> Int {
        guard let unit = units[botID],
              let sessionID = await unit.remote.mainSessionIdentifier(),
              let turnID = await runtime.currentTurnID(sessionId: sessionID) else { return 0 }
        return Int(turnID) ?? 0
    }

    private func loadAgentCommThreadsIfNeeded() async {
        guard !threadsLoaded else { return }
        threadsLoaded = true
        for event in (try? await BotProductionEventReader.all(domain: domain)) ?? [] {
            guard event.type == "agent.comm",
                  let botID = event.principal.botId,
                  let data = event.data.objectValue,
                  let comm = data["agentComm"]?.objectValue else { continue }
            if let rowID = data["rowID"]?.stringValue ?? data["id"]?.stringValue {
                agentCommTracker.addRowID(rowID, for: botID)
            }
            guard let thread = comm["threadId"]?.stringValue else { continue }
            switch comm["direction"]?.stringValue {
            case "outbound":
                guard let request = comm["requestId"]?.stringValue else { continue }
                agentCommThreads["\(botID)\u{0}\(request)"] = thread
            case "reply":
                // A reply's idempotency key is its own callID (top-level data
                // member), not the exchange requestID (`team.md` §2.4/§2.9).
                guard let callID = data["callId"]?.stringValue, !callID.isEmpty else { continue }
                agentCommThreads["\(botID)\u{0}\(callID)"] = thread
            default:
                continue
            }
        }
    }

    /// The in-memory identity of the hop a delivery opens. `SendToAgent` turns
    /// it into a reply instead of a cycle when the target answers this sender.
    private func inboundHop(for request: BotAgentDeliveryRequest) -> BotAgentInboundHop {
        BotAgentInboundHop(
            senderID: request.sender.id,
            requestID: request.requestId,
            threadID: request.threadId,
            delivery: request.delivery,
            title: request.title)
    }

    private func makeHeldItem(for request: BotAgentDeliveryRequest) throws -> WakeInboxItem {
        let text = String(request.message.prefix(BotTeamTools.heldTextLimit))
        return try WakeInboxItem(
            id: "held-\(UUID().uuidString.lowercased())",
            kind: "agent-held",
            fromAgentId: request.sender.id,
            fromAgentName: request.sender.name,
            title: request.title,
            text: text,
            requestId: BotTeamDeliveryPolicy.heldRequestID(for: request),
            threadId: request.threadId,
            createdAt: botProductionNowMilliseconds())
    }

    private func waitUntilIdle(_ unit: BotRuntimeUnit, deadline: Date) async throws {
        while await unit.remote.isMainTurnBusy() {
            if Date() > deadline { throw BotTeamHostError.deliveryTimeout }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    private func latestCommitSeq() async -> Int {
        let events = (try? await BotProductionEventReader.all(domain: domain)) ?? []
        return events.last?.commitSeq ?? 0
    }

    private func lastAssistantText(botID: String, after cursor: Int) async -> String? {
        let events = (try? await BotProductionEventReader.all(domain: domain)) ?? []
        return events.last(where: {
            $0.type == "conversation.assistant_message"
                && $0.principal.botId == botID
                && ($0.commitSeq ?? 0) > cursor
                && !($0.data["text"]?.stringValue ?? "").isEmpty
        })?.data["text"]?.stringValue
    }
}

// MARK: - Routine delivery router

/// One outbox handler for every Bot's routine deliveries. The effect carries
/// only the delivery key, so the owner Bot is resolved through the shared
/// routine machine before the same `conversation.automation_run` row is
/// appended. Unread is bumped only when the owner is not currently selected.
actor BotRoutineOutboxRouter {
    let store: SQLiteDomainStore
    let machine: RoutineMachine
    let profileStore: BotProfileStore
    let selectionStore: BotSelectionStore

    init(store: SQLiteDomainStore, machine: RoutineMachine,
         profileStore: BotProfileStore, selectionStore: BotSelectionStore) {
        self.store = store
        self.machine = machine
        self.profileStore = profileStore
        self.selectionStore = selectionStore
    }

    func apply(_ lease: BotEffectLease) async throws -> BotEffectState {
        guard let record = try await store.effect(lease.effectKey) else {
            try await store.fail(lease, errorClass: "permanent", reason: "routine delivery payload is missing")
            return .deadLetter
        }
        let roster = try await profileStore.roster()
        for bot in roster.bots {
            guard let delivery = try await machine.delivery(
                record.effect.logicalKey, botId: bot.id) else { continue }
            let automation = RoutineAutomation(delivery: delivery)
            let event = BotEvent(
                type: "conversation.automation_run",
                eventId: "automation:\(automation.deliveryKey)",
                time: automation.finishedAt, origin: .local(source: "scheduler"),
                traceId: "automation:\(automation.deliveryKey)",
                principal: BotPrincipal(botId: bot.id, sessionId: nil, kind: "routine"),
                causationId: nil, correlationId: automation.deliveryKey,
                data: .object([
                    "id": .string(automation.id), "routineId": .string(automation.routineId),
                    "title": .string(automation.routineTitle), "status": .string(automation.status),
                    "text": .string(automation.result), "result": .string(automation.result),
                    "error": automation.error.map(PhoneDSHBot.BotJSONValue.string) ?? .null,
                    "attempt": .number(Double(automation.attempt)), "runId": .string(automation.runId),
                    "deliveryKey": .string(automation.deliveryKey),
                    "delivery": .string(automation.delivery.rawValue),
                    "quiet": .bool(automation.quiet), "context": .string(automation.context),
                    "scheduledFor": automation.scheduledFor.map { .number(Double($0)) } ?? .null,
                    "finishedAt": .number(Double(automation.finishedAt)),
                    "heldInbox": automation.heldInbox.map(PhoneDSHBot.BotJSONValue.string) ?? .null,
                ]))
            _ = try await store.append(event)
            try await store.ack(lease, resultRef: automation.id)
            if await selectionStore.current() != bot.id,
               BotUnreadRules.shouldIncrementForDelivery(
                to: bot.id, selectedBotID: await selectionStore.current()) {
                try? await profileStore.incrementUnread(id: bot.id)
                try? await profileStore.touch(
                    id: bot.id, at: Int64(Date().timeIntervalSince1970 * 1_000))
            }
            return .acked
        }
        try await store.fail(
            lease, errorClass: "permanent", reason: "routine delivery payload is missing")
        return .deadLetter
    }
}

/// The Bot composition is the production implementation of the App's three
/// listener-recovery timings.
extension BotRuntimeComposition: BotMCPListenerEnsuring {}

#if canImport(PhoneDSHADB) && canImport(PhoneDSHLoopback)
/// Adapts any native JSON-RPC server to the Bot handler without adding a
/// PhoneDSHBot -> device module dependency. `DeviceMCPServer` handles the BLE
/// family itself and delegates every other call to `ADBMCPServer`.
struct BotNativeMCPForwarder: BotNativeMCPForwarding {
    let server: any NativeMCPServing

    func handle(_ request: PhoneDSHBot.BotJSONValue, headers: [String: String]) async -> PhoneDSHBot.BotJSONValue? {
        guard let body = try? request.encoded() else { return nil }
        let response = await server.handle(LoopbackRequest(
            method: "POST", path: "/mcp/native", headers: headers, body: body))
        guard response.status == 200 else { return nil }
        return try? PhoneDSHBot.BotJSONValue.parse(response.body)
    }
}
#endif

struct UnstartedBotTransport: BotUnattachedTransport {
    func call(_ endpoint: String, args: PhoneDSHBot.BotJSONValue) async throws -> PhoneDSHBot.BotJSONValue {
        throw BotMCPError.unavailable("Host transport is not attached")
    }
    func openMux() async throws -> any DSHMuxConnection {
        throw BotMCPError.unavailable("Host transport is not attached")
    }
    func authenticationFailed() async {}
}


/// Bridges the Bot module's record service into the shell's protocol without
/// making `PhoneDSHShell` depend on `PhoneDSHBot`.
struct BotRecordPhoneAdapter: PhoneRecordQuerying {
    let service: BotRecordService

    func runRecordCommand(arguments: [String], callerSessionID: String) async -> PhoneRecordCommandResult {
        let output = await BotRecordService.bridge(
            arguments: arguments, callerSessionID: callerSessionID, service: service)
        return PhoneRecordCommandResult(stdout: output.stdout,
                                        stderr: output.stderr,
                                        exitCode: output.exitCode)
    }
}
