// SPDX-License-Identifier: MIT

import Foundation
import PhoneDSHAgentCore
import PhoneDSHBot
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

    func current(domain: SQLiteDomainStore) async throws -> BotProductionContext {
        var name = "大肥鱼"
        for event in try await BotProductionEventReader.all(domain: domain) {
            guard event.type == "ui.system_event", event.principal.botId == botID,
                  botProductionString(event.data["event"]) == "renamed",
                  let candidate = botProductionString(event.data["botName"])?
                    .trimmingCharacters(in: .whitespacesAndNewlines), !candidate.isEmpty else { continue }
            name = candidate
        }
        return BotProductionContext(botID: botID, botName: name)
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
    let runtimeContext: BotProductionRuntimeContext
    private var planner: any BotUserActionPlanning
    private var turnStopping: (any BotProductionTurnStopping)?

    init(domain: SQLiteDomainStore, botID: String, sessionID: String,
         routineMachine: RoutineMachine, memory: BotMemory,
         planner: (any BotUserActionPlanning)? = nil,
         turnStopping: (any BotProductionTurnStopping)? = nil,
         sessionLogURL: URL? = nil) {
        self.botID = botID
        self.sessionID = sessionID
        self.sessionLogURL = sessionLogURL
        self.domain = domain
        self.routineMachine = routineMachine
        self.memory = memory
        self.runtimeContext = BotProductionRuntimeContext(botID: botID)
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

    func currentPlanner() -> any BotUserActionPlanning { planner }
    func currentTurnStopping() -> (any BotProductionTurnStopping)? { turnStopping }
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
        return try BotDSHSessionEvent.parseJSONL(Data(contentsOf: url))
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
        let sessionEvents = try logData.map { try BotDSHSessionEvent.parseJSONL($0) } ?? []
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

struct BotProductionInfoSnapshot: Sendable {
    var botName: String
    var memories: [PhoneDSHBot.BotMemoryFact]
    var routines: [Routine]
    var approvals: [BotProductionApproval]
}

/// Read/write view over the same `BotMemory` and `RoutineMachine` the
/// composition root injected; nothing here opens a second fact store.
actor BotProductionInfoService {
    private let environment: BotProductionEnvironment

    init(environment: BotProductionEnvironment) {
        self.environment = environment
    }

    func load() async throws -> BotProductionInfoSnapshot {
        let memory = environment.memory
        let machine = environment.routineMachine
        let botName = try await environment.context().botName
        async let facts = memory.facts(scope: nil)
        async let routines = machine.list(botId: environment.botID)
        async let approvals = approvalRecords()
        return try await BotProductionInfoSnapshot(
            botName: botName, memories: facts, routines: routines, approvals: approvals)
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

    func forget(factID: String) async throws {
        let result = try await environment.memory.forget(factID: factID)
        guard result.ok else {
            throw BotProductionError.invalidService(result.error ?? "忘记记忆失败")
        }
    }

    func eraseMemories() async throws {
        let facts = try await environment.memory.facts(scope: nil)
        for fact in facts {
            _ = try await environment.memory.erase(factID: fact.factID)
        }
    }

    func setRoutineEnabled(_ routineID: String, enabled: Bool) async throws {
        _ = try await environment.routineMachine.update(
            botId: environment.botID, routineId: routineID,
            patch: RoutinePatch(enabled: enabled), now: botProductionNowMilliseconds())
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

    static func production(environment: BotProductionEnvironment) -> BotProductionInfoDriver {
        production(service: BotProductionInfoService(environment: environment))
    }
}
