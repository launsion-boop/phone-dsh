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
    let sessionLogURL: URL?
    let domain: SQLiteDomainStore
    let routineMachine: RoutineMachine
    let memory: BotMemory
    let grants: BotGrantStore
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
         fallbackName: String = "大肥鱼") {
        self.botID = botID
        self.sessionID = sessionID
        self.sessionLogURL = sessionLogURL
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
        planner = composition.planner
        turnStopping = composition.turnStopping
    }

    func context() async throws -> BotProductionContext {
        try await runtimeContext.current(domain: domain)
    }

    func legacyName() async throws -> String? {
        try await runtimeContext.legacyName(domain: domain)
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
    static func latestFile(sessionID: String) -> URL? {
        let root = BotProductionPaths.workspaceRoot()
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

    static func events(sessionID: String) throws -> [BotDSHSessionEvent] {
        guard let url = latestFile(sessionID: sessionID) else { return [] }
        return BotDSHSessionEvent.parseJSONL(try Data(contentsOf: url)).events
    }
}

struct BotProductionHistoryPage: Sendable, Equatable {
    var rows: [BotRow]
    var nextCursor: String?
    var hasMore: Bool
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
        let sessionID = await environment.sessionID
        let logURL = environment.sessionLogURL ?? BotSessionLogLocator.latestFile(sessionID: sessionID)
        let logData = try logURL.map { try Data(contentsOf: $0) }
        let parsed = logData.map { BotDSHSessionEvent.parseJSONL($0) }
        let sessionEvents = parsed?.events ?? []
        sessionLogDiagnostics = parsed?.diagnostics ?? .empty
        updateProcesses(from: logData)
        let uiEvents = try await BotProductionEventReader.all(domain: environment.domain)
        let heldRequestNonces = await remote?.heldChatActionNonces(sessionID: sessionID) ?? [:]
        _ = try await history.rebuild(botID: environment.botID, sessionID: sessionID,
                                      sessionEvents: sessionEvents, uiEvents: uiEvents,
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
    var parameterSummary: String
    var decision: BotGrantDecision
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
    var effectSummary: String?
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
}

/// Read/write view over the same `BotMemory` and `RoutineMachine` the
/// composition root injected; nothing here opens a second fact store.
actor BotProductionInfoService {
    private let environment: BotProductionEnvironment
    private let scheduler: RoutineScheduler?
    private let settingsStore: ProactiveSettingsStore
    private let maintenance: BotMemoryMaintenanceController?

    init(environment: BotProductionEnvironment,
         scheduler: RoutineScheduler? = nil,
         settingsStore: ProactiveSettingsStore = .shared,
         maintenance: BotMemoryMaintenanceController? = nil) {
        self.environment = environment
        self.scheduler = scheduler
        self.settingsStore = settingsStore
        self.maintenance = maintenance
    }

    func load() async throws -> BotProductionInfoSnapshot {
        let memory = environment.memory
        let machine = environment.routineMachine
        let botName = try await environment.context().botName
        let documents = try await memory.documents(scope: nil)
        var memories: [BotProductionMemoryDocument] = []
        for document in documents {
            memories.append(BotProductionMemoryDocument(
                document: document,
                versions: try await memory.versions(path: document.path)))
        }
        async let routines = machine.list(botId: environment.botID)
        async let approvals = approvalRecords()
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
        let grants = await standingGrants()
        let reconciliations = try await reconciliationRecords(provided: routines)
        let maintenanceBatch = try? await maintenance?.lastBatch()
        let maintenanceSettings = await maintenance?.settings()
        let maintenanceEnabled = maintenanceSettings?.enabled ?? false
        let maintenanceBudget = await maintenance?.budgetStatus()
        return try await BotProductionInfoSnapshot(
            botName: botName, memories: memories, routines: routines, approvals: approvals,
            grants: grants, reconciliations: reconciliations,
            presence: presence, proactiveSettings: settingsStore.settings(),
            maintenance: maintenanceBatch,
            maintenanceEnabled: maintenanceEnabled,
            maintenanceDailyTokens: maintenanceBudget?.dailyTokensUsed ?? 0,
            maintenanceDailyBudget: maintenanceBudget?.dailyTokenLimit ?? 0)
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
                    "\($0.effect.operation) · \($0.effect.target) · "
                        + "\( $0.reconciliationReason ?? "unknown" )"
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
        let outcome = try await environment.memory.erase(path: path)
        guard outcome.ok else {
            throw BotProductionError.invalidService(outcome.error ?? "抹除记忆失败")
        }
    }

    /// Physically erases only this Bot's agent root. The shared user root is a
    /// separate explicit action (`eraseSharedMemories`) so one Bot can never
    /// wipe the documents every Bot shares.
    func eraseMemories() async throws {
        let outcome = try await environment.memory.erase(scope: .agent)
        guard outcome.ok else {
            throw BotProductionError.invalidService(outcome.error ?? "抹除记忆失败")
        }
    }

    /// Physically erases the shared user root for every Bot. Only called from
    /// the information page's separate, doubly-confirmed shared-memory entry.
    func eraseSharedMemories() async throws {
        let outcome = try await environment.memory.erase(scope: .user)
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
        var records: [BotProductionApproval] = []
        for event in try await BotProductionEventReader.all(domain: environment.domain) {
            guard ["grant.added", "grant.consumed", "grant.revoked"].contains(event.type),
                  let record = try? JSONDecoder().decode(BotAuditRecord.self, from: event.data.encoded()),
                  record.principal.botId == environment.botID else { continue }
            let effects = record.effects.map {
                "\($0.tool)/\($0.operation) · \($0.resourceDigest.prefix(16))"
            }.joined(separator: "\n")
            let grants = record.grants.map {
                "Grant \($0.id) · \($0.scope.rawValue) · \($0.resourceDigest.prefix(16))"
            }.joined(separator: "\n")
            records.append(BotProductionApproval(
                id: event.eventId,
                parameterSummary: [effects, grants].filter { !$0.isEmpty }.joined(separator: "\n"),
                decision: record.decision, decidedAtMS: record.at))
        }
        return records.sorted { $0.decidedAtMS > $1.decidedAtMS }
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
