// SPDX-License-Identifier: MIT

import Foundation
import PhoneDSH
import PhoneDSHAgentCore
import PhoneDSHBot
import PhoneDSHEngine
import UniformTypeIdentifiers
#if canImport(ProbeKit)
import ProbeKit
#endif

func botProductionString(_ value: PhoneDSHBot.BotJSONValue?) -> String? {
    guard case .string(let text)? = value else { return nil }
    return text
}

func botProductionInt(_ value: PhoneDSHBot.BotJSONValue?) -> Int? {
    guard case .number(let number)? = value, number.isFinite, number.rounded() == number else { return nil }
    return Int(exactly: number)
}

func botProductionNowMilliseconds() -> Int64 {
    Int64(Date().timeIntervalSince1970 * 1_000)
}

enum BotProductionError: LocalizedError {
    case brainUnavailable
    case invalidService(String)

    var errorDescription: String? {
        switch self {
        case .brainUnavailable: return "Bot 大脑 planner 尚未接入，消息和审批动作未执行。"
        case .invalidService(let message): return message
        }
    }
}

protocol BotProductionTurnStopping: Actor {
    func stopCurrentTurn(turnID: String?) async throws
}

actor BotProductionUnavailablePlanner: BotUserActionPlanning {
    func plan(_ action: BotUserAction, trust: BotUserActionTrust) async throws -> BotUserActionPlanOutcome {
        .rejected(reason: BotProductionError.brainUnavailable.localizedDescription)
    }
}

struct BotProductionContext: Equatable, Sendable {
    var botID: String
    var botName: String
}

struct BotProductionRuntimeContext: Sendable {
    let botID: String
    /// The profile name of this Bot. It is the fallback after the last
    /// `renamed` system event, so a new Bot is not shown as the legacy name.
    let fallbackName: String

    func current(domain: SQLiteDomainStore) async throws -> BotProductionContext {
        let name = try await legacyName(domain: domain) ?? fallbackName
        return BotProductionContext(botID: botID, botName: name)
    }

    /// The name from the last `renamed` system event, or nil when the Bot was
    /// never renamed. Bootstrap uses this to decide `name_explicit`.
    func legacyName(domain: SQLiteDomainStore) async throws -> String? {
        var name: String?
        for event in try await BotProductionEventReader.all(domain: domain) {
            guard event.type == "ui.system_event", event.principal.botId == botID,
                  botProductionString(event.data["event"]) == "renamed",
                  let candidate = botProductionString(event.data["botName"])?
                    .trimmingCharacters(in: .whitespacesAndNewlines), !candidate.isEmpty else { continue }
            name = candidate
        }
        return name
    }
}

struct BotProductionComposition {
    let sessionID: String
    let planner: any BotUserActionPlanning
    var turnStopping: (any BotProductionTurnStopping)? = nil
}

/// The single production authority for one Bot's durable dependencies.
///
/// `BotMCPRuntime` owns exactly one `RoutineMachine` and one `BotMemory`; the
/// composition root creates those once and injects them here. No second
/// routine store or memory-fact wrapper is constructed for the UI path.
actor BotProductionEnvironment {
    let botID: String
    private(set) var sessionID: String
    /// Cached log URL for `sessionID`. It is refreshed on `connect` and on an
    /// S6 epoch switch; the row service still re-validates it against the
    /// session id so a stale cache can never keep the chat on the archived
    /// epoch.
    private(set) var sessionLogURL: URL?
    let domain: SQLiteDomainStore
    let routineMachine: RoutineMachine
    let memory: BotMemory
    let grants: BotGrantStore
    /// The workspace root this runtime actually uses. The session-log locator
    /// must scan this tree, never the process-global App Documents default:
    /// the BotE2E composition injects a temporary root and a global scan would
    /// silently miss every log written there.
    let workspaceRoot: URL
    let runtimeContext: BotProductionRuntimeContext
    private var planner: any BotUserActionPlanning
    private var turnStopping: (any BotProductionTurnStopping)?
    private var routineCanceller: (@Sendable (String) async -> RoutineCancellationResult)?

    init(domain: SQLiteDomainStore, botID: String, sessionID: String,
         routineMachine: RoutineMachine, memory: BotMemory,
         grants: BotGrantStore,
         planner: (any BotUserActionPlanning)? = nil,
         turnStopping: (any BotProductionTurnStopping)? = nil,
         sessionLogURL: URL? = nil,
         workspaceRoot: URL = BotProductionPaths.workspaceRoot(),
         fallbackName: String = "大肥鱼") {
        self.botID = botID
        self.sessionID = sessionID
        self.sessionLogURL = sessionLogURL
        self.workspaceRoot = workspaceRoot
        self.domain = domain
        self.routineMachine = routineMachine
        self.memory = memory
        self.grants = grants
        self.runtimeContext = BotProductionRuntimeContext(botID: botID, fallbackName: fallbackName)
        self.planner = planner ?? BotProductionUnavailablePlanner()
        self.turnStopping = turnStopping
    }

    func connect(_ composition: BotProductionComposition) throws {
        guard !composition.sessionID.isEmpty else {
            throw BotProductionError.invalidService("Bot 主会话 ID 不能为空")
        }
        sessionID = composition.sessionID
        sessionLogURL = BotSessionLogLocator.latestFile(
            sessionID: composition.sessionID, workspaceRoot: workspaceRoot)
        planner = composition.planner
        turnStopping = composition.turnStopping
    }

    func context() async throws -> BotProductionContext {
        try await runtimeContext.current(domain: domain)
    }

    func legacyName() async throws -> String? {
        try await runtimeContext.legacyName(domain: domain)
    }

    /// Advances the durable main-session pointer after an epoch switch. The
    /// planner and turn-stopping seams stay bound; the session id and the log
    /// URL the row/record services read both move to the new epoch. The row
    /// service still re-validates the cached URL on every rebuild.
    func updateSessionID(_ sessionID: String) {
        self.sessionID = sessionID
        sessionLogURL = BotSessionLogLocator.latestFile(
            sessionID: sessionID, workspaceRoot: workspaceRoot)
    }

    /// One read of the current epoch and its log. A cached URL that belongs to
    /// the replaced session is ignored; the resolver falls back to the current
    /// session's newest `session.v*.jsonl`.
    func sessionSnapshot() -> (sessionID: String, logURL: URL?) {
        (sessionID, BotSessionLogSelection.logURL(
            sessionID: sessionID, explicit: sessionLogURL,
            latest: { BotSessionLogLocator.latestFile(sessionID: $0, workspaceRoot: workspaceRoot) }))
    }

    func currentPlanner() -> any BotUserActionPlanning { planner }
    func currentTurnStopping() -> (any BotProductionTurnStopping)? { turnStopping }

    func setRoutineCanceller(
        _ canceller: (@Sendable (String) async -> RoutineCancellationResult)?
    ) {
        routineCanceller = canceller
    }

    func cancelRoutine(_ routineID: String) async -> RoutineCancellationResult {
        guard let routineCanceller else {
            return RoutineCancellationResult(cancelled: false, reason: "routine canceller is not configured")
        }
        return await routineCanceller(routineID)
    }
}

enum BotProductionEventReader {
    static func all(domain: SQLiteDomainStore) async throws -> [BotEvent] {
        var result: [BotEvent] = []
        var cursor = 0
        while true {
            let page = try await domain.events(after: cursor, limit: 500)
            guard !page.isEmpty else { return result }
            result.append(contentsOf: page)
            cursor = page.last?.commitSeq ?? cursor
            if page.count < 500 { return result }
        }
    }
}

enum BotProductionPaths {
    static func workspaceRoot() -> URL {
        #if canImport(ProbeKit)
        return ChatHostConfiguration.workspaceRoot()
        #else
        return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("chat-host", isDirectory: true)
        #endif
    }
}

enum BotSessionLogLocator {
    /// Newest `session.v*.jsonl` for `sessionID` under the **owning**
    /// workspace root. Callers pass the same root their composition was built
    /// with; there is deliberately no process-global fallback.
    static func latestFile(sessionID: String, workspaceRoot: URL) -> URL? {
        let root = workspaceRoot
            .appendingPathComponent("materialized/home/sessions", isDirectory: true)
        let manager = FileManager.default
        guard let enumerator = manager.enumerator(
            at: root, includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }
        var candidates: [(url: URL, modified: Date)] = []
        for case let url as URL in enumerator {
            guard url.lastPathComponent.hasPrefix("session.v"), url.pathExtension == "jsonl",
                  url.deletingLastPathComponent().lastPathComponent == sessionID,
                  let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey]),
                  values.isRegularFile == true else { continue }
            candidates.append((url, values.contentModificationDate ?? .distantPast))
        }
        return candidates.sorted { $0.modified > $1.modified }.first?.url
    }

    static func events(sessionID: String, workspaceRoot: URL) throws -> [BotDSHSessionEvent] {
        guard let url = latestFile(sessionID: sessionID, workspaceRoot: workspaceRoot) else { return [] }
        return BotDSHSessionEvent.parseJSONL(try Data(contentsOf: url)).events
    }
}

struct BotProductionHistoryPage: Sendable, Equatable {
    var rows: [BotRow]
    var nextCursor: String?
    var hasMore: Bool
}

/// Loads the main-chat epoch chain from durable `runtime.started` events. Each
/// entry keeps its physical session id; the row projector stitches them in
/// first-start order so an epoch switch does not make the old conversation
/// disappear. A repeated `runtime.started` for the same id is deduplicated.
enum BotProductionSessionEpochs {
    static func load(botID: String, currentSessionID: String,
                     currentLogURL: URL?,
                     workspaceRoot: URL,
                     domain: SQLiteDomainStore) async throws -> [BotSessionEpochProjection] {
        var ordered: [String] = []
        var seen = Set<String>()
        for event in try await BotProductionEventReader.all(domain: domain)
        where event.type == "runtime.started"
            && event.principal.botId == botID
            && event.principal.kind == BotSessionKind.chat.rawValue {
            guard let sessionID = event.data["sessionId"]?.stringValue
                ?? event.principal.sessionId, !sessionID.isEmpty else { continue }
            if seen.insert(sessionID).inserted { ordered.append(sessionID) }
        }
        if seen.insert(currentSessionID).inserted { ordered.append(currentSessionID) }
        var epochs: [BotSessionEpochProjection] = []
        for sessionID in ordered {
            let url = sessionID == currentSessionID
                ? (currentLogURL ?? BotSessionLogLocator.latestFile(
                    sessionID: sessionID, workspaceRoot: workspaceRoot))
                : BotSessionLogLocator.latestFile(
                    sessionID: sessionID, workspaceRoot: workspaceRoot)
            let events: [BotDSHSessionEvent]
            if let url, let data = try? Data(contentsOf: url) {
                events = BotDSHSessionEvent.parseJSONL(data).events
            } else {
                events = []
            }
            if sessionID != currentSessionID && events.isEmpty { continue }
            epochs.append(BotSessionEpochProjection(sessionID: sessionID, events: events))
        }
        if epochs.isEmpty {
            epochs.append(BotSessionEpochProjection(sessionID: currentSessionID, events: []))
        }
        return epochs
    }
}

/// Reads the same durable rows the production Bot page renders. One instance
/// belongs to the composition root; the UI passes its driver around instead of
/// constructing another projection authority.
actor BotProductionRowService {
    private let environment: BotProductionEnvironment
    private let history: BotRowHistory
    private let remote: BotDSHRemoteRuntime?
    private var dispatcher: BotUserActionDispatcher?
    private var plannerIdentity: ObjectIdentifier?
    private var started = false
    private var currentPresentation = BotRuntimePresentation()
    /// Tool steps per turn, re-projected only when the session log changes.
    private var processes: [Int: BotTurnProcess] = [:]
    private var processSource: Data?
    private var liveGeneration = 0
    /// Read-only evidence of session-log records the last `rebuild()` skipped.
    private(set) var sessionLogDiagnostics = BotDSHSessionLogDiagnostics.empty

    init(environment: BotProductionEnvironment, history: BotRowHistory = BotRowHistory(),
         remote: BotDSHRemoteRuntime? = nil) {
        self.environment = environment
        self.history = history
        self.remote = remote
    }

    func start() async throws {
        guard !started else { return }
        try await rebuild()
        await updateDispatcher()
        started = true
    }

    private func updateDispatcher() async {
        let planner = await environment.currentPlanner()
        let identity = ObjectIdentifier(planner)
        guard identity != plannerIdentity else { return }
        plannerIdentity = identity
        dispatcher = BotUserActionDispatcher(store: environment.domain, planner: planner)
    }

    private func rebuild() async throws {
        let snapshot = await environment.sessionSnapshot()
        let sessionID = snapshot.sessionID
        let logURL = snapshot.logURL
        let logData = try logURL.map { try Data(contentsOf: $0) }
        let parsed = logData.map { BotDSHSessionEvent.parseJSONL($0) }
        let sessionEvents = parsed?.events ?? []
        sessionLogDiagnostics = parsed?.diagnostics ?? .empty
        updateProcesses(from: logData)
        let uiEvents = try await BotProductionEventReader.all(domain: environment.domain)
        let heldRequestNonces = await remote?.heldChatActionNonces(sessionID: sessionID) ?? [:]
        let epochs = try await BotProductionSessionEpochs.load(
            botID: environment.botID, currentSessionID: sessionID,
            currentLogURL: logURL, workspaceRoot: environment.workspaceRoot,
            domain: environment.domain)
        _ = try await history.rebuild(botID: environment.botID, epochs: epochs,
                                      uiEvents: uiEvents,
                                      heldRequestNonces: heldRequestNonces)
        currentPresentation = BotRuntimePresentationFactory.make(
            botID: environment.botID, sessionID: sessionID,
            sessionEvents: sessionEvents, uiEvents: uiEvents)
    }

    private func updateProcesses(from data: Data?) {
        guard data != processSource else { return }
        processSource = data
        guard let data else {
            processes = [:]
            return
        }
        let records = data.split(separator: UInt8(ascii: "\n")).compactMap { line in
            try? JSONValue.parse(Data(line))
        }
        processes = BotTurnProcessProjector.make(records: records)
    }

    func turnProcesses() -> [Int: BotTurnProcess] { processes }

    /// Live frames of the visible main-chat turn. One subscriber at a time;
    /// a newer subscription replaces an older one, and only the current one
    /// detaches the observer when it ends.
    func liveFrames() -> AsyncStream<BotLiveTurnFrame> {
        liveGeneration += 1
        let generation = liveGeneration
        let (stream, continuation) = AsyncStream<BotLiveTurnFrame>.makeStream(bufferingPolicy: .bufferingNewest(512))
        guard let remote else {
            continuation.finish()
            return stream
        }
        continuation.onTermination = { [weak self] _ in
            Task { await self?.endLive(generation: generation) }
        }
        Task { await remote.setLiveObserver { frame in continuation.yield(frame) } }
        return stream
    }

    private func endLive(generation: Int) async {
        guard generation == liveGeneration else { return }
        await remote?.setLiveObserver(nil)
    }

    func presentation() async throws -> BotRuntimePresentation {
        try await start()
        return currentPresentation
    }

    func watch(after cursor: Int) async throws -> BotRowBatch {
        try await rebuild()
        return await history.watch(after: cursor)
    }

    func history(before rowID: String?, limit: Int) async throws -> BotProductionHistoryPage {
        try await rebuild()
        let rows = await history.history()
        let end = try rowID.map { id in
            guard let index = rows.firstIndex(where: { $0.id == id }) else {
                throw BotProductionError.invalidService("历史行游标不可用")
            }
            return index
        } ?? rows.endIndex
        let eligible = rows[..<end]
        let page = eligible.suffix(max(1, limit))
        return BotProductionHistoryPage(rows: Array(page), nextCursor: page.first?.id,
                                        hasMore: eligible.count > page.count)
    }

    func perform(_ action: BotUserAction) async throws -> BotActionResult {
        try await start()
        await updateDispatcher()
        guard let dispatcher else { return .rejected(reason: BotProductionError.brainUnavailable.localizedDescription) }
        return try await dispatcher.dispatch(action)
    }

    func stopCurrentTurn(turnID: String?) async throws {
        guard let stopping = await environment.currentTurnStopping() else {
            throw BotProductionError.brainUnavailable
        }
        try await stopping.stopCurrentTurn(turnID: turnID)
    }
}

struct BotProductionApproval: Sendable, Equatable, Identifiable {
    var id: String
    /// Human-readable action + operation labels; never an id or digest.
    var parameterSummary: String
    var decision: BotGrantDecision
    /// `once` / `session` / `until` for an allow; nil for a deny.
    var scope: String?
    /// `allowed` / `denied` / `timed-out` / `expired` / `cancelled`.
    var status: String?
    /// Durable cancellation/denial reason code (`worker_restarted`, …). The
    /// UI maps it through `BotApprovalReceipt.cancellationReason`; the raw
    /// value never reaches the page.
    var reason: String?
    var decidedAtMS: Int64
}

struct BotProductionGrant: Sendable, Equatable, Identifiable {
    var id: String
    var tool: String
    var operation: String
    var resource: String
    var scope: String
    var sessionID: String?
    var createdAtMS: Int64
    var source: String
}

struct BotProductionReconciliation: Sendable, Equatable, Identifiable {
    var id: String { routineID }
    var routineID: String
    var routineTitle: String
    var attempt: Int
    var runID: String
    var error: String?
    var effectKey: String?
    var effectGeneration: Int?
    var effectAttempt: Int?
    /// Human-readable effect summary for the single reconciliation block.
    var effectSummary: String?
    /// Raw effect record (`operation · target · reason`) for the detail
    /// disclosure; the main row never prints the effect key.
    var effectDetail: String?
}

struct BotProductionMemoryDocument: Sendable {
    var document: PhoneDSHBot.BotMemoryDocument
    var versions: [PhoneDSHBot.BotMemoryDocumentVersion]
}

struct BotProductionInfoSnapshot: Sendable {
    var botName: String
    var memories: [BotProductionMemoryDocument]
    var routines: [Routine]
    var approvals: [BotProductionApproval]
    var grants: [BotProductionGrant]
    var reconciliations: [BotProductionReconciliation]
    var presence: RoutinePresence
    var proactiveSettings: ProactiveSettings
    var maintenance: BotMemoryMaintenanceBatchView?
    var maintenanceEnabled: Bool
    var maintenanceDailyTokens: Int
    var maintenanceDailyBudget: Int
    /// Last failed App identity registration for this runtime, if any. Read
    /// only; the info page renders it as one status line.
    var bridgeStatus: PhoneDSHBot.BotBridgeDiagnostic?
    /// Per-entry failure messages. Each data entry loads independently so a
    /// broken projection only fails its own page. The raw error goes to the
    /// diagnostic log; this string is the human-facing copy.
    var memoryError: String?
    var routinesError: String?
    var approvalsError: String?
    var grantsError: String?
}

/// Read/write view over the same `BotMemory` and `RoutineMachine` the
/// composition root injected; nothing here opens a second fact store.
actor BotProductionInfoService {
    private let environment: BotProductionEnvironment
    private let scheduler: RoutineScheduler?
    private let settingsStore: ProactiveSettingsStore
    private let maintenance: BotMemoryMaintenanceController?
    private let bridgeDiagnostic: (@Sendable () async -> BotBridgeDiagnostic?)?
    private var sessionEraser: BotSessionEraser?

    init(environment: BotProductionEnvironment,
         scheduler: RoutineScheduler? = nil,
         settingsStore: ProactiveSettingsStore = .shared,
         maintenance: BotMemoryMaintenanceController? = nil,
         bridgeDiagnostic: (@Sendable () async -> BotBridgeDiagnostic?)? = nil) {
        self.environment = environment
        self.scheduler = scheduler
        self.settingsStore = settingsStore
        self.maintenance = maintenance
        self.bridgeDiagnostic = bridgeDiagnostic
    }

    /// Installs the session-epoch eraser for this Bot unit. The composition
    /// sets it after the unit exists; memory erase stays unavailable until it
    /// is installed, so production never clears payloads without covering the
    /// closed session logs.
    func setSessionEraser(_ eraser: BotSessionEraser?) {
        sessionEraser = eraser
    }

    func load() async throws -> BotProductionInfoSnapshot {
        let memory = environment.memory
        let machine = environment.routineMachine
        // The page title is profile-driven; a missing runtime context must
        // not take the four data entries down with it.
        let botName = (try? await environment.context().botName) ?? ""
        let humanFailure = "暂时读不出来，请稍后重试。"

        var memories: [BotProductionMemoryDocument] = []
        var memoryError: String?
        do {
            let documents = try await memory.documents(scope: nil)
            for document in documents {
                memories.append(BotProductionMemoryDocument(
                    document: document,
                    versions: try await memory.versions(path: document.path)))
            }
        } catch {
            await logInfoProjectionFailure("memory", error)
            memoryError = humanFailure
        }

        var routines: [Routine] = []
        var routinesError: String?
        do {
            routines = try await machine.list(botId: environment.botID)
        } catch {
            await logInfoProjectionFailure("routines", error)
            routinesError = humanFailure
        }

        var approvals: [BotProductionApproval] = []
        var approvalsError: String?
        do {
            approvals = try await approvalRecords()
        } catch {
            await logInfoProjectionFailure("approvals", error)
            approvalsError = humanFailure
        }

        var grants: [BotProductionGrant] = []
        var grantsError: String?
        do {
            grants = try await standingGrants()
        } catch {
            await logInfoProjectionFailure("grants", error)
            grantsError = humanFailure
        }

        let context = await BotPresenceCenter.shared.context()
        let presence: RoutinePresence
        if let scheduler {
            presence = await scheduler.presenceSnapshot(
                appActive: context.appActive, keepingAlive: context.keepingAlive)
        } else {
            presence = RoutinePresence(
                level: RoutinePresencePolicy.level(
                    appActive: context.appActive, keepingAlive: context.keepingAlive,
                    scheduledNotificationCount: 0))
        }
        var reconciliations: [BotProductionReconciliation] = []
        if routinesError == nil {
            do {
                reconciliations = try await reconciliationRecords(provided: routines)
            } catch {
                await logInfoProjectionFailure("reconciliations", error)
            }
        }
        let maintenanceBatch = try? await maintenance?.lastBatch()
        let maintenanceSettings = await maintenance?.settings()
        let maintenanceEnabled = maintenanceSettings?.enabled ?? false
        let maintenanceBudget = await maintenance?.budgetStatus()
        let bridgeStatus: BotBridgeDiagnostic?
        if let bridgeDiagnostic {
            bridgeStatus = await bridgeDiagnostic()
        } else {
            bridgeStatus = nil
        }
        if let diagnostic = bridgeStatus {
            // The raw failure code belongs to the diagnostic log; the presence
            // line is built from the timestamp only (P09 bot-info §在场状态).
            await MainActor.run {
                BotRebindDiagnostics.emit(
                    "bot-info bridge-failure code=\(diagnostic.code)")
            }
        }
        return BotProductionInfoSnapshot(
            botName: botName, memories: memories, routines: routines, approvals: approvals,
            grants: grants, reconciliations: reconciliations,
            presence: presence, proactiveSettings: settingsStore.settings(),
            maintenance: maintenanceBatch,
            maintenanceEnabled: maintenanceEnabled,
            maintenanceDailyTokens: maintenanceBudget?.dailyTokensUsed ?? 0,
            maintenanceDailyBudget: maintenanceBudget?.dailyTokenLimit ?? 0,
            bridgeStatus: bridgeStatus,
            memoryError: memoryError,
            routinesError: routinesError,
            approvalsError: approvalsError,
            grantsError: grantsError)
    }

    /// The raw projection error belongs in the App diagnostic log. The page
    /// only ever receives the human message above.
    private func logInfoProjectionFailure(_ section: String, _ error: Error) async {
        await MainActor.run {
            BotRebindDiagnostics.emit(
                "bot-info projection=\(section) error=\(String(reflecting: error))")
        }
    }

    /// S3: enable/disable the background maintainer (default off). The switch
    /// is shared by every Bot and persisted under one P18 key.
    func setMaintenanceEnabled(_ enabled: Bool) async {
        if let maintenance {
            await maintenance.setEnabled(enabled)
        } else {
            var settings = BotMemoryMaintenanceSettingsStore.shared.settings()
            settings.enabled = enabled
            BotMemoryMaintenanceSettingsStore.shared.save(settings)
        }
    }

    /// S3: roll one batch back using the S2 restore primitive.
    func rollbackMaintenance(batchID: String) async throws {
        guard let maintenance else {
            throw BotProductionError.invalidService("记忆整理服务未接线")
        }
        let result = try await maintenance.rollback(batchID: batchID)
        guard let result else {
            throw BotProductionError.invalidService("找不到这次整理批次")
        }
        if !result.conflicts.isEmpty {
            throw BotProductionError.invalidService(
                "有 \(result.conflicts.count) 份文档在整理后又被改过，未覆盖")
        }
    }

    /// Standing grants only. A `once` grant is one execution permission, not a
    /// standing authorization, so the information page never shows it.
    func standingGrants() async -> [BotProductionGrant] {
        await environment.grants.list(botId: environment.botID)
            .filter { $0.scope != .once }
            .sorted { ($0.createdAt, $0.id) > ($1.createdAt, $1.id) }
            .map {
                BotProductionGrant(
                    id: $0.id, tool: $0.tool, operation: $0.operation,
                    resource: $0.resource, scope: $0.scope.rawValue,
                    sessionID: $0.sessionId, createdAtMS: $0.createdAt, source: $0.source)
            }
    }

    func revokeGrant(_ id: String) async throws {
        _ = try await environment.grants.revoke(id: id)
    }

    func cancelRoutine(_ routineID: String) async throws {
        let result = await environment.cancelRoutine(routineID)
        guard result.cancelled else {
            throw BotProductionError.invalidService(
                "取消例行任务失败：\(result.reason ?? "routine is not running")")
        }
    }

    /// Every routine that stopped in `needs-reconciliation`, plus the effect
    /// record that produced it when one still exists. The effect is the
    /// "already produced" evidence shown before the user chooses.
    func reconciliationRecords(provided: [Routine]? = nil) async throws -> [BotProductionReconciliation] {
        let routines: [Routine]
        if let provided {
            routines = provided
        } else {
            routines = try await environment.routineMachine.list(botId: environment.botID)
        }
        var records: [BotProductionReconciliation] = []
        for routine in routines {
            guard let state = routine.runState, state.status == .needsReconciliation else { continue }
            let deliveryKey = RoutineDelivery.key(routineId: routine.id, attempt: state.attempt)
            let effectKey = "routine:\(deliveryKey)"
            let effect = try? await environment.domain.effect(effectKey)
            let matching = effect?.state == .needsReconciliation ? effect : nil
            records.append(BotProductionReconciliation(
                routineID: routine.id, routineTitle: routine.title,
                attempt: state.attempt, runID: state.runId,
                error: state.error ?? routine.lastResult?.error,
                effectKey: matching?.effectKey,
                effectGeneration: matching?.generation,
                effectAttempt: matching?.attempt,
                effectSummary: matching.map {
                    BotUIFormat.routineEffectSummary(
                        operation: $0.effect.operation,
                        reason: $0.reconciliationReason)
                },
                effectDetail: matching.map {
                    BotUIFormat.routineEffectReference(
                        operation: $0.effect.operation,
                        target: $0.effect.target,
                        reason: $0.reconciliationReason)
                }))
        }
        return records
    }

    /// Resolve a routine reconciliation from the user's explicit choice. The
    /// routine state and its delivery effect are two different authorities;
    /// both are advanced when each is still in the reconciliation state.
    func resolveReconciliation(routineID: String, decision: String) async throws {
        let now = botProductionNowMilliseconds()
        let updated = try await environment.routineMachine.resolveReconciliation(
            botId: environment.botID, routineId: routineID, decision: decision, now: now)
        guard let updated else {
            throw BotProductionError.invalidService("例行任务不存在")
        }
        guard let state = updated.runState else { return }
        let deliveryKey = RoutineDelivery.key(routineId: routineID, attempt: state.attempt)
        let effectKey = "routine:\(deliveryKey)"
        guard let record = try? await environment.domain.effect(effectKey),
              record.state == .needsReconciliation else { return }
        switch decision {
        case "acknowledge":
            try await environment.domain.ackReconciled(
                effectKey: effectKey, generation: record.generation,
                attempt: record.attempt, resultRef: "user-acknowledged")
        case "retry":
            try await environment.domain.retryNeedsReconciliation(effectKey)
        default:
            throw RoutineError.unsupportedDecision(decision)
        }
    }

    /// Persists the host-level "can disturb" authorization and wakes the
    /// scheduler so a quiet-hours or DND change is applied immediately.
    func saveProactiveSettings(_ settings: ProactiveSettings) async -> ProactiveSettings {
        settingsStore.save(settings)
        let normalized = settingsStore.settings()
        await scheduler?.applySettingsChange()
        return normalized
    }

    func rename(_ name: String) async throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw BotProductionError.invalidService("Bot 名不能为空。") }
        let eventID = "bot-rename-\(UUID().uuidString.lowercased())"
        let event = BotEvent(
            type: "ui.system_event", eventId: eventID, time: botProductionNowMilliseconds(),
            origin: .local(source: "user"), traceId: eventID,
            principal: BotPrincipal(botId: environment.botID, sessionId: nil, kind: "ui"),
            causationId: nil, correlationId: nil,
            data: .object(["event": .string("renamed"), "botName": .string(trimmed)]))
        _ = try await environment.domain.append(event)
    }

    func forget(path: String, expectedVersion: Int) async throws {
        let result = try await environment.memory.forget(
            path: path, expectedVersion: expectedVersion)
        guard result.ok else {
            throw BotProductionError.invalidService(result.error ?? "忘记记忆失败")
        }
    }

    /// Physical erase of one memory document and every historical version.
    /// The shared user root is not touched.
    func eraseMemory(path: String) async throws {
        let outcome = try await environment.memory.erase(
            path: path, sessionEraser: sessionEraser)
        guard outcome.ok else {
            throw BotProductionError.invalidService(outcome.error ?? "抹除记忆失败")
        }
    }

    /// Physically erases only this Bot's agent root. The shared user root is a
    /// separate explicit action (`eraseSharedMemories`) so one Bot can never
    /// wipe the documents every Bot shares.
    func eraseMemories() async throws {
        let outcome = try await environment.memory.erase(
            scope: .agent, sessionEraser: sessionEraser)
        guard outcome.ok else {
            throw BotProductionError.invalidService(outcome.error ?? "抹除记忆失败")
        }
    }

    /// Physically erases the shared user root for every Bot. Only called from
    /// the information page's separate, doubly-confirmed shared-memory entry.
    func eraseSharedMemories() async throws {
        let outcome = try await environment.memory.erase(
            scope: .user, sessionEraser: sessionEraser)
        guard outcome.ok else {
            throw BotProductionError.invalidService(outcome.error ?? "清除共享记忆失败")
        }
    }

    func setRoutineEnabled(_ routineID: String, enabled: Bool) async throws {
        _ = try await environment.routineMachine.update(
            botId: environment.botID, routineId: routineID,
            patch: RoutinePatch(enabled: enabled), now: botProductionNowMilliseconds())
        await scheduler?.applySettingsChange()
    }

    private func approvalRecords() async throws -> [BotProductionApproval] {
        var requested: [String: BotEvent] = [:]
        var records: [BotProductionApproval] = []
        for event in try await BotProductionEventReader.all(domain: environment.domain) {
            guard event.principal.botId == environment.botID else { continue }
            switch event.type {
            case "approval.requested":
                guard let id = event.data["approvalID"]?.stringValue else { continue }
                requested[id] = event
            case "approval.decided":
                guard let id = event.data["approvalID"]?.stringValue else { continue }
                let data = event.data
                let decisionRaw = data["decision"]?.stringValue ?? "deny"
                let decision: BotGrantDecision = decisionRaw == "deny" ? .deny : .allow
                let status: String
                if data["timedOut"]?.boolValue == true {
                    status = "timed-out"
                } else {
                    status = data["status"]?.stringValue
                        ?? (decision == .allow ? "allowed" : "denied")
                }
                let scope: String?
                if decision == .allow {
                    if decisionRaw == "always" {
                        scope = data["alwaysScope"]?.stringValue
                            ?? requested[id]?.data["alwaysScope"]?.stringValue
                            ?? "until"
                    } else {
                        scope = "once"
                    }
                } else {
                    scope = nil
                }
                records.append(BotProductionApproval(
                    id: id,
                    parameterSummary: Self.approvalSummary(request: requested[id]),
                    decision: decision,
                    scope: scope,
                    status: status,
                    reason: data["reason"]?.stringValue,
                    decidedAtMS: event.time))
            default:
                continue
            }
        }
        return records.sorted { $0.decidedAtMS > $1.decidedAtMS }
    }

    /// A user-readable summary built from the approval request's action and
    /// effect labels. Digests, grant ids and raw scopes never reach this string.
    private static func approvalSummary(request: BotEvent?) -> String {
        guard let data = request?.data else { return "一次操作" }
        let action = (data["action"]?.stringValue ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var labels: [String] = []
        for effect in data["effects"]?.arrayValue ?? [] {
            let raw = (effect["label"]?.stringValue ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let label = raw.isEmpty ? "工具操作" : raw
            guard !labels.contains(label) else { continue }
            labels.append(label)
        }
        if action.isEmpty {
            return labels.isEmpty ? "一次操作" : labels.joined(separator: "、")
        }
        if labels.isEmpty || labels.contains(action) { return action }
        return "\(action) · \(labels.joined(separator: "、"))"
    }
}

struct BotProductionInfoDriver {
    var load: () async throws -> BotProductionInfoSnapshot

    static func production(service: BotProductionInfoService) -> BotProductionInfoDriver {
        BotProductionInfoDriver(load: { try await service.load() })
    }

    static func production(environment: BotProductionEnvironment,
                           scheduler: RoutineScheduler? = nil,
                           settingsStore: ProactiveSettingsStore = .shared) -> BotProductionInfoDriver {
        production(service: BotProductionInfoService(
            environment: environment, scheduler: scheduler, settingsStore: settingsStore))
    }
}

/// Imports the composer's picked files into the Bot's own DSH workspace through
/// the Worker's `phone/import*` service — the same path the DSH page uses for a
/// verbatim workspace file, because the Bot's file tools run in that workspace.
/// The concrete transport and the Bot's live session id are injected; the
/// session cwd is the Bot root (`BotWorkspaceLayout`), not the shared DSH
/// workspace.
///
/// Limits are enforced before the upload: at most 10 files, each <= 25 MiB.
/// A refused or failed file is reported by name and skipped; the successful
/// subset and the text still send.
final class BotWorkspaceAttachmentImporter: BotAttachmentImporting, @unchecked Sendable {
    private let transport: any DSHRemoteTransport
    private let sessionID: @Sendable () async throws -> String
    /// Bot data root the runtime also passes to `session/create`. The import
    /// service scopes writes to the session cwd, so this must match.
    private let botDataDirectory: String

    init(transport: any DSHRemoteTransport,
         sessionID: @escaping @Sendable () async throws -> String,
         botDataDirectory: String = BotDataRoot.path) {
        self.transport = transport
        self.sessionID = sessionID
        self.botDataDirectory = botDataDirectory
    }

    func importFiles(botID: String, messageID: String, files: [URL]) async -> BotAttachmentImportResult {
        guard !files.isEmpty else { return BotAttachmentImportResult(items: [], errors: []) }

        var errors: [(name: String, reason: String)] = []
        let accepted = Array(files.prefix(BotAttachmentPolicy.maxCount))
        for extra in files.dropFirst(BotAttachmentPolicy.maxCount) {
            errors.append((name: extra.lastPathComponent,
                           reason: "每条消息最多 \(BotAttachmentPolicy.maxCount) 个附件。"))
        }

        var prepared: [(safeName: String, data: Data, mimeType: String)] = []
        var usedNames: Set<String> = []
        for url in accepted {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let name = url.lastPathComponent.isEmpty ? "file" : url.lastPathComponent
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            guard size > 0 else {
                errors.append((name: name, reason: "文件为空或无法读取。"))
                continue
            }
            guard Int64(size) <= BotAttachmentPolicy.maxBytes else {
                errors.append((name: name, reason: "文件超过 25 MiB。"))
                continue
            }
            guard let data = try? Data(contentsOf: url, options: .mappedIfSafe), !data.isEmpty else {
                errors.append((name: name, reason: "文件为空或无法读取。"))
                continue
            }
            let safeName = Self.uniqueName(BotAttachmentPolicy.safeName(name), used: &usedNames)
            let mimeType = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType
                ?? "application/octet-stream"
            prepared.append((safeName, data, mimeType))
        }

        guard !prepared.isEmpty else { return BotAttachmentImportResult(items: [], errors: errors) }
        let session: String
        do {
            session = try await sessionID()
        } catch {
            let reason = "Bot 会话尚未就绪：\(error.localizedDescription)"
            errors.append(contentsOf: prepared.map { (name: $0.safeName, reason: reason) })
            return BotAttachmentImportResult(items: [], errors: errors)
        }

        let botRoot = BotWorkspaceLayout.botRoot(
            botId: botID, dataDirectory: botDataDirectory)
        let manifest = WebEngineDirectoryImportManifest(
            sessionID: session,
            targetDirectory: botRoot,
            entryName: "attachments-\(messageID)",
            directories: [],
            files: prepared.map { WebEngineDirectoryImportFile(path: $0.safeName, size: $0.data.count) },
            totalBytes: prepared.reduce(0) { $0 + $1.data.count })
        let sink = PhoneDSHWorkspaceImportSink(transport: transport)
        var importID: String?
        do {
            let started = try await sink.begin(manifest)
            importID = started
            let chunk = 1024 * 1024
            for file in prepared {
                var offset = 0
                while offset < file.data.count {
                    let end = min(offset + chunk, file.data.count)
                    try await sink.write(importID: started, path: file.safeName,
                                         offset: offset, data: file.data.subdata(in: offset..<end))
                    offset = end
                }
            }
            let result = try await sink.commit(importID: started)
            let items = prepared.map { file in
                BotAttachment(
                    name: file.safeName,
                    path: "\(result.absolutePath)/\(file.safeName)",
                    size: Int64(file.data.count),
                    mimeType: file.mimeType,
                    kind: BotAttachmentPolicy.kind(name: file.safeName, mimeType: file.mimeType))
            }
            return BotAttachmentImportResult(items: items, errors: errors)
        } catch {
            if let importID { await sink.abort(importID: importID) }
            errors.append(contentsOf: prepared.map {
                (name: $0.safeName, reason: "写入工作区失败：\(error.localizedDescription)")
            })
            return BotAttachmentImportResult(items: [], errors: errors)
        }
    }

    private static func uniqueName(_ name: String, used: inout Set<String>) -> String {
        var candidate = name
        var index = 1
        let ext = (name as NSString).pathExtension
        let base = (name as NSString).deletingPathExtension
        while used.contains(candidate) {
            candidate = ext.isEmpty ? "\(base) (\(index))" : "\(base) (\(index)).\(ext)"
            index += 1
        }
        used.insert(candidate)
        return candidate
    }
}

// MARK: - Session epoch erasure (S6 step 2)

/// Holds the composition's current host without making every child closure
/// MainActor-bound. The host actor itself stays the authority; this only
/// forwards the reference.
actor BotHostReference {
    private weak var host: PhoneDSHHost?

    init(host: PhoneDSHHost? = nil) {
        self.host = host
    }

    func set(_ host: PhoneDSHHost?) {
        self.host = host
    }

    func current() -> PhoneDSHHost? { host }
}

/// Orchestrates one S6 step-2 erasure: plan the session lines, switch the main
/// chat to a new epoch, park the Worker, rewrite the closed logs through the
/// host, then resume and stage the continuity seam. The memory store calls
/// this before it clears any event payload; a throw leaves memory intact.
final class BotSessionEpochEraser: Sendable {
    private let remote: BotDSHRemoteRuntime
    private let environment: BotProductionEnvironment
    private let recordService: BotRecordService
    private let hostReference: BotHostReference
    private let workspaceRoot: URL
    /// The composition owns the automatic Worker-boot recovery. This eraser
    /// parks/resumes the host itself and then reattaches the Bot remote, so it
    /// suppresses that automatic path for the duration and releases it (with
    /// the new boot id recorded) before returning.
    private let beginManualWorkerRebind: (@Sendable () async -> Void)?
    private let endManualWorkerRebind: (@Sendable (Bool) async -> Void)?

    init(remote: BotDSHRemoteRuntime,
         environment: BotProductionEnvironment,
         recordService: BotRecordService,
         hostReference: BotHostReference,
         workspaceRoot: URL,
         beginManualWorkerRebind: (@Sendable () async -> Void)? = nil,
         endManualWorkerRebind: (@Sendable (Bool) async -> Void)? = nil) {
        self.remote = remote
        self.environment = environment
        self.recordService = recordService
        self.hostReference = hostReference
        self.workspaceRoot = workspaceRoot
        self.beginManualWorkerRebind = beginManualWorkerRebind
        self.endManualWorkerRebind = endManualWorkerRebind
    }

    func erase(_ request: BotSessionErasureRequest) async throws -> BotSessionErasureReport {
        let current = try await remote.ensureMainSessionID()
        let botIDs: Set<String>
        if request.scope == BotMemoryScope.user.rawValue {
            var ids = Set([request.botID])
            for event in (try? await BotProductionEventReader.all(domain: environment.domain)) ?? [] {
                if let botID = event.principal.botId, !botID.isEmpty { ids.insert(botID) }
            }
            botIDs = ids
        } else {
            botIDs = [request.botID]
        }
        var owned = Set<String>()
        for botID in botIDs {
            owned.formUnion((try? await recordService.ownedSessionIDs(
                botID: botID, callerSessionID: "")) ?? [])
        }
        owned.remove("")
        let planner = BotSessionErasurePlanner(workspaceRoot: workspaceRoot)
        let scan = planner.scan(
            botID: request.botID, ownedSessionIDs: owned,
            needles: request.needles, records: request.records)
        guard !scan.targets.isEmpty else {
            return BotSessionErasureReport(uncoveredRecords: scan.uncovered)
        }
        let erasureID = "session-erasure-\(UUID().uuidString.lowercased())"
        let oldSeqs = Set(scan.targets.first { $0.sessionID == current }?.seqs ?? [])
        let seam = planner.continuation(sessionID: current, erasedSeqs: oldSeqs)
        let switched = try await remote.switchMainSessionForErasure(
            erasureID: erasureID,
            erasedRecords: scan.targets.flatMap(\.records))
        await environment.updateSessionID(switched.new)
        await remote.setPendingContinuation(seam)

        guard let host = await hostReference.current() else {
            throw BotProductionError.invalidService("会话宿主尚未连接，无法改写已关闭会话日志。")
        }
        var erased: [BotErasureEventData.ErasedSessionRecord] = []
        await beginManualWorkerRebind?()
        // The follow streams of running tasks are about to be cut by the
        // deliberate park. Mark the window so the runtime reports an
        // interruption instead of a transport failure.
        await remote.beginHostPark()
        do {
            try await host.park()
            for target in scan.targets {
                let lines = planner.tombstoneLines(
                    sessionID: target.sessionID,
                    erasedSeqs: Set(target.seqs),
                    erasureID: erasureID)
                guard lines.count == target.seqs.count else {
                    throw BotProductionError.invalidService(
                        "会话 \(target.sessionID) 的待抹除行已变化，请重试。")
                }
                let request = PhoneDSHSessionErasureRequest(
                    sessionID: target.sessionID,
                    replacements: lines.map {
                        PhoneDSHSessionLineReplacement(seq: $0.seq, line: $0.data)
                    })
                let result = try await host.eraseClosedSession(request)
                let covered = Set(result.erasedSeqs)
                erased.append(contentsOf: target.seqs.compactMap { seq in
                    guard covered.contains(seq) else { return nil }
                    return BotErasureEventData.ErasedSessionRecord(
                        record: "record://session/\(target.sessionID)#\(seq)",
                        sessionId: target.sessionID, seq: seq)
                })
            }
            try await host.start()
            let transport = try await host.makeTransport()
            await remote.attachTransport(transport)
            _ = try await remote.startMainSession()
            await environment.updateSessionID(switched.new)
            await remote.endHostPark()
            // The manual path bypasses `BotRuntimeUnit.start`, so deliver the
            // interrupted Task wakes here, after the replacement Worker and
            // the new main session are ready.
            _ = await remote.deliverInterruptedTaskWakes()
            await endManualWorkerRebind?(true)
        } catch {
            // Never leave the App parked: the session switch is already
            // durable, so a resume failure is reported separately from the
            // rewrite failure.
            var transportRecovered = false
            if (try? await host.start()) != nil {
                if let transport = try? await host.makeTransport() {
                    await remote.attachTransport(transport)
                    if (try? await remote.startMainSession()) != nil {
                        transportRecovered = true
                    }
                }
            }
            await remote.endHostPark()
            await endManualWorkerRebind?(transportRecovered)
            throw error
        }

        let notice = BotEvent(
            type: "ui.notice",
            eventId: "session-epoch-\(erasureID)",
            time: request.atMS,
            origin: .local(source: "user"),
            traceId: "trace-\(erasureID)",
            principal: BotPrincipal(
                botId: request.botID, sessionId: switched.new, kind: "ipc"),
            causationId: nil,
            correlationId: erasureID,
            data: .object([
                "tone": .string("info"),
                "text": .string(
                    "已抹除的内容已从旧会话日志移除；对话已接续到新会话，未抹除的内容仍然可用。"),
            ]))
        _ = try? await environment.domain.append(notice)
        return BotSessionErasureReport(
            erasedSessionRecords: erased,
            sessionEpochs: [BotErasureEventData.SessionEpoch(
                fromSessionId: switched.old,
                toSessionId: switched.new,
                atMS: request.atMS)],
            uncoveredRecords: scan.uncovered)
    }
}
