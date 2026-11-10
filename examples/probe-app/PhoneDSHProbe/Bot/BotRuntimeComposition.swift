// SPDX-License-Identifier: MIT

import Foundation
import PhoneDSH
import PhoneDSHAgentCore
import PhoneDSHBot
import PhoneDSHDeviceTasks
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

/// Per-Bot delivery/cycle context. The team tool host owns it; it is not
/// durable, because only a live hand-off chain needs it.
@MainActor
final class BotAgentCommTracker {
    struct Context: Equatable {
        var depth = 0
        var chain: [String] = []
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
    let handler: BotMCPHandler
    let server: BotMCPHTTPServer
    let outbox: BotProductionEffectRunner
    let rosterModel: BotRosterModel
    let selectionStore: BotSelectionStore
    let agentCommTracker = BotAgentCommTracker()

    /// The Worker environment carrying the Bot MCP endpoint/token. The whole
    /// roster shares one listener, so one URL (and one token) feeds the single
    /// Worker. Only the URL changes on recovery; the token remains the
    /// process-lifetime bearer.
    private(set) var workerEnvironment: [String: String] = [:]

    private var units: [String: BotRuntimeUnit] = [:]
    private var routineRouter: BotRoutineOutboxRouter?
    private var host: PhoneDSHHost?
    private var hostTask: Task<Void, Never>?
    private var observedHost: PhoneDSHHost?
    private var tickTask: Task<Void, Never>?
    private var recoveryTask: Task<Void, Never>?
    private var rosterTask: Task<Void, Never>?
    private var started = false
    private var deliversDeviceTaskResults = false
    private var threadsLoaded = false
    private var agentCommThreads: [String: String] = [:]
    private var agentCommHops: [String: Int] = [:]
    private var pendingApprovalTicks = 0

    /// The Worker never carries the real Bot bearer. The host egress route
    /// (`MCPEgressPolicy.grantBotRuntimeEndpoint`) injects it after stripping
    /// the placeholder, so neither the page URL (`?env=`) nor the Worker
    /// process ever sees it.
    static let workerTokenPlaceholder = "phone-host-injects-bot-mcp-token"

    private(set) var state: BotRuntimeState = .idle {
        didSet {
            guard oldValue != state else { return }
            onStateChange?(state)
        }
    }
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
                        sessionLogURL: URL? = nil) async throws -> Launch {
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
        let runtime = BotMCPRuntime(store: store, volatileProvider: deferred)
        let machine = await runtime.routineMachine
        let baseMemory = await runtime.memory(for: selectedCandidate)
        let language = Locale.preferredLanguages.first?.hasPrefix("zh") == true ? "zh" : "en"
        let mainBotID = roster.mainBotID
        let volatile = BotDomainVolatileContextProvider(
            memory: baseMemory, routines: machine,
            personaAsync: { botId, _, _ in
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

        let handler = BotMCPHandler(runtime: runtime)
        let server = BotMCPHTTPServer(handler: handler)
        let url = try await server.start()
        let rosterModel = BotRosterModel(
            roster: roster, selectedBotID: restored, store: profileStore,
            selectionStore: selectionStore, defaults: defaults)
        let composition = try await BotRuntimeComposition(
            domain: store, profileStore: profileStore, runtime: runtime,
            handler: handler, server: server, rosterModel: rosterModel,
            selectionStore: selectionStore)
        composition.workerEnvironment = [
            "PDSH_PHONE_MCP_URL": url.absoluteString,
            "PDSH_PHONE_MCP_TOKEN": workerTokenPlaceholder,
        ]
        composition.routineRouter = BotRoutineOutboxRouter(
            store: store, machine: machine, profileStore: profileStore,
            selectionStore: selectionStore)
        await runtime.registerTeamTools(BotTeamTools(host: composition))
        await runtime.registerFishActionTool()
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
                 runtime: BotMCPRuntime, handler: BotMCPHandler,
                 server: BotMCPHTTPServer, rosterModel: BotRosterModel,
                 selectionStore: BotSelectionStore) async throws {
        self.domain = domain
        self.profileStore = profileStore
        self.runtime = runtime
        self.handler = handler
        self.server = server
        self.rosterModel = rosterModel
        self.selectionStore = selectionStore
        self.outbox = BotProductionEffectRunner(store: domain)
        // A rebind that was not requested through ensureListening() (for
        // example a future automatic recovery) still updates the environment
        // the next Host build reads.
        server.onEndpointChange = { [weak self] url in
            Task { @MainActor [weak self] in self?.applyWorkerEndpoint(url) }
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
        if let existing = units[botID] { return existing }
        let profile = try await profileStore.profile(id: botID)
        guard let profile else { throw BotTeamHostError.botNotFound(botID) }
        let unit = try await BotRuntimeUnit.make(
            runtime: runtime, handler: handler, store: domain,
            botID: botID, displayName: profile.name)
        units[botID] = unit
        rosterModel.setRuntimeState(BotRosterRuntimeState(runtimeState: state), for: botID)
        if started, let host {
            do {
                let transport = try await host.makeTransport()
                try await unit.start(transport: transport)
            } catch {
                units.removeValue(forKey: botID)
                await runtime.detachTaskExecutor(botID: botID)
                await unit.detach()
                throw error
            }
        }
        return unit
    }

    /// The hub calls this when the user switches Bots: attach the unit first so
    /// the first message is not sent into an unstarted transport.
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
        try await bind(to: newHost, recovering: false)
    }

    func retry() async {
        guard let host else { return }
        guard !started || state.isFailure else { return }
        do { try await bind(to: host, recovering: true) }
        catch {
            state = .failed("Bot 连接恢复失败：\(error.localizedDescription)")
            scheduleRecoveryRetry(host)
        }
    }

    private func bind(to newHost: PhoneDSHHost, recovering: Bool) async throws {
        state = recovering ? .recovering : .connecting
        // Units must not attach themselves inside `ensureUnit` while this
        // method is iterating them; the loop below owns transport creation.
        started = false
        do {
            // Invalidate the replaced Worker incarnation once; every attached
            // Bot remote receives `workerRestarted` through the shared runtime.
            _ = await runtime.workerRestarted()
            try await newHost.start()

            // Always have the selected Bot and every routine owner attached
            // before the outbox/schedulers start.
            let selected = rosterModel.selectedBotID ?? rosterModel.mainBotID
            if let selected { _ = try await ensureUnit(for: selected) }
            for botID in await routineOwnerBotIDs() where botID != selected {
                _ = try? await ensureUnit(for: botID, reason: "routine-owner")
            }

            for (botID, unit) in units {
                do {
                    let transport = try await newHost.makeTransport()
                    try await unit.start(transport: transport)
                } catch {
                    if botID == selected {
                        throw error
                    }
                    print("[BotRuntimeComposition] unit \(botID) start failed: \(error)")
                }
            }

            #if canImport(PhoneDSHADB) && canImport(PhoneDSHLoopback)
            #if canImport(PhoneDSHBLE)
            await attachNativeMCP(DeviceMCPServer.shared)
            #else
            await attachNativeMCP(ADBMCPServer.shared)
            #endif
            #endif

            await installOutboxHandlers()
            started = true
            observeHost(newHost)
            await outbox.start()
            startTick()
            installDeviceTaskResultDelivery()
            state = .ready
        } catch {
            state = .failed("Bot 连接失败：\(error.localizedDescription)")
            throw error
        }
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
        await runtime.approvals.cancelAll(reason: "shutdown")
        _ = await runtime.gateway.attribution.prune()
        host = nil
        started = false
        state = .stopped
    }

    private func detachBinding() async {
        removeDeviceTaskResultDelivery()
        for unit in units.values { await unit.detach() }
        await outbox.stop()
        tickTask?.cancel(); tickTask = nil
        recoveryTask?.cancel(); recoveryTask = nil
        hostTask?.cancel(); hostTask = nil
        observedHost = nil
        started = false
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
                let item = try notice.wakeInboxItem()
                _ = try await unit.wakeInbox.enqueue(item)
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

    private func observeHost(_ host: PhoneDSHHost) {
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
                    await self.recoverAfterWorkerTermination(host)
                case .restarted:
                    await self.recoverAfterWorkerTermination(host)
                default:
                    break
                }
            }
        }
    }

    private func isAttached(_ host: PhoneDSHHost) -> Bool { self.host === host }

    private func recoverAfterWorkerTermination(_ host: PhoneDSHHost) async {
        guard self.host === host else { return }
        state = .recovering
        do { try await bind(to: host, recovering: true) }
        catch {
            state = .failed("Bot 连接恢复失败：\(error.localizedDescription)")
            scheduleRecoveryRetry(host)
        }
    }

    private func scheduleRecoveryRetry(_ host: PhoneDSHHost) {
        recoveryTask?.cancel()
        recoveryTask = Task { [weak self] in
            guard let self else { return }
            for _ in 0..<5 {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard !Task.isCancelled, self.host === host else { return }
                do {
                    try await self.bind(to: host, recovering: true)
                    return
                } catch {
                    self.state = .failed("Bot 连接恢复失败：\(error.localizedDescription)")
                }
            }
        }
    }

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
                await self.archiveSessions(sessions)
            },
            BotDeletionStep(name: "clear-routines") { [weak self] in
                guard let self else { return }
                let machine = await self.runtime.routineMachine
                let routines = (try? await machine.list(botId: botID)) ?? []
                for routine in routines {
                    _ = try? await machine.delete(botId: botID, routineId: routine.id)
                }
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

    private func archiveSessions(_ sessions: [String]) async {
        guard let host, let transport = try? await host.makeTransport() else { return }
        for sessionID in sessions {
            _ = try? await transport.call("workspace/archiveSession", args: .object([
                "request": .object([
                    "sessionId": .string(sessionID), "stopActivity": .bool(false),
                ]),
            ]))
        }
    }

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
    func roster() async throws -> BotRoster {
        try await profileStore.roster()
    }

    func createBot(name: String, description: String, color: BotFishColor?,
                   hairstyle: BotFishHairstyle?) async throws -> BotProfile {
        let created = try await profileStore.createBot(
            name: name, fishColor: color, fishHairstyle: hairstyle,
            description: description.isEmpty ? nil : description)
        await rosterModel.refresh()
        return created
    }

    func agentCommContext(for botID: String) async -> BotAgentCommContext {
        await loadAgentCommThreadsIfNeeded()
        let context = agentCommTracker.context(for: botID)
        let turn = await currentTurnNumber(for: botID)
        return BotAgentCommContext(
            depth: context.depth,
            chain: context.chain,
            turn: turn,
            existingRowIDs: agentCommTracker.existingRowIDs(for: botID))
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
                .init(depth: request.hop, chain: request.chain), for: request.target.id)
            defer { agentCommTracker.clearActive(for: request.target.id) }
            let result = try await unit.remote.sendUserMessage(
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
                .init(depth: request.hop, chain: request.chain), for: request.target.id)
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
        if let sender = request.item.fromAgentId {
            let depth = request.item.threadId.flatMap { agentCommHops[$0] } ?? 1
            agentCommTracker.setPendingHeld(
                .init(depth: depth, chain: [sender, request.botID]), for: request.botID)
        }
        return try await unit.wakeInbox.enqueue(request.item)
    }

    func recordAgentComm(_ record: BotTeamAgentCommRecord) async throws {
        let event = BotEvent(
            type: "agent.comm",
            eventId: "agent.comm:\(record.rowID)",
            time: botProductionNowMilliseconds(),
            origin: .local(source: "team-tools"),
            traceId: "agent-comm:\(record.threadID)",
            principal: BotPrincipal(botId: record.botID, sessionId: nil, kind: "team"),
            causationId: nil,
            correlationId: record.requestID,
            data: record.eventData)
        _ = try await domain.append(event)
        agentCommTracker.addRowID(record.rowID, for: record.botID)
        if record.direction == .outbound {
            agentCommThreads["\(record.botID)\u{0}\(record.requestID)"] = record.threadID
            if let hop = record.hop { agentCommHops[record.threadID] = hop }
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
            guard comm["direction"]?.stringValue == "outbound",
                  let thread = comm["threadId"]?.stringValue,
                  let request = comm["requestId"]?.stringValue else { continue }
            agentCommThreads["\(botID)\u{0}\(request)"] = thread
        }
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

struct UnstartedBotTransport: DSHRemoteTransport {
    func call(_ endpoint: String, args: PhoneDSHBot.BotJSONValue) async throws -> PhoneDSHBot.BotJSONValue {
        throw BotMCPError.unavailable("Host transport is not attached")
    }
    func openMux() async throws -> any DSHMuxConnection {
        throw BotMCPError.unavailable("Host transport is not attached")
    }
    func authenticationFailed() async {}
}
