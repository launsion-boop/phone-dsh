// SPDX-License-Identifier: MIT

#if DEBUG
import Foundation
import PhoneDSHBot

private struct BotProductionCheckFailure: Error, CustomStringConvertible {
    let description: String
}

private actor BotProductionCheckPlanner: BotUserActionPlanning {
    private var accepts = true
    private(set) var actions: [BotUserAction] = []
    private(set) var trusts: [BotUserActionTrust] = []

    func setAccepted(_ value: Bool) {
        accepts = value
    }

    func plan(_ action: BotUserAction, trust: BotUserActionTrust) async throws -> BotUserActionPlanOutcome {
        actions.append(action)
        trusts.append(trust)
        guard accepts else { return .rejected(reason: "check_rejected") }
        guard action.kind == .chat, let text = action.text else {
            return .rejected(reason: "check_requires_chat")
        }
        let id = "check-action-\(action.nonce)"
        let event = BotEvent(type: "ui.send_to_user", eventId: id, time: 4_000,
                             origin: .local(source: "user"), traceId: id,
                             principal: BotPrincipal(botId: action.botID, sessionId: "main", kind: "chat"),
                             causationId: nil, correlationId: action.nonce,
                             data: .object([
                                "type": .string("text"), "role": .string("user"), "text": .string(text),
                             ]))
        return .commit(BotUserActionPlan(event: event))
    }
}

enum BotProductionChecks {
    static func run() async throws -> [String] {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("phonedsh-bot-production-checks-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let databaseURL = root.appendingPathComponent("domain.sqlite")
        let sessionURL = root.appendingPathComponent("session.v4.jsonl")
        let sessionEvent = BotDSHSessionEvent(type: "user/message", seq: 1, time: 1_000, data: [
            "role": .string("user"),
            "surfaceOp": .string("append"),
            "message": .object([
                "role": .string("user"),
                "content": .array([.object(["type": .string("text"), "text": .string("真实 JSONL 用户消息")])]),
            ]),
        ], eventID: "session-user-1")
        try JSONEncoder().encode(sessionEvent).write(to: sessionURL)

        let domain = try SQLiteDomainStore(fileURL: databaseURL, now: { 5_000 })
        let planner = BotProductionCheckPlanner()
        let memoryStore = SQLiteBotMemoryDocumentStore(eventLog: domain, botID: "main", now: { 5_000 })
        let environment = BotProductionEnvironment(
            domain: domain, botID: "main", sessionID: "main",
            routineMachine: RoutineMachine(store: SQLiteRoutineStore(domainStore: domain)),
            memory: BotMemory(store: memoryStore, botID: "main", now: { 5_000 }),
            grants: BotGrantStore(domainStore: domain, now: { 5_000 }),
            planner: planner, sessionLogURL: sessionURL)
        let rows = BotProductionRowService(environment: environment)
        try await rows.start()
        _ = try await domain.append(progressEvent(id: "progress-1", time: 2_000, percent: 25))
        let initial = try await rows.watch(after: 0)
        try require(initial.reset && initial.rows.count == 2, "JSONL/progress rebuild did not produce two rows")
        try require(initial.rows.contains { botProductionString($0.body["text"]) == "真实 JSONL 用户消息" },
                    "real JSONL user row missing")
        guard let progress = initial.rows.first(where: { $0.body.cardType == .progress }) else {
            throw BotProductionCheckFailure(description: "real progress row missing")
        }

        _ = try await domain.append(progressEvent(id: "progress-2", time: 3_000, percent: 100))
        let update = try await rows.watch(after: initial.cursor)
        try require(!update.reset && update.rows.count == 1 && update.rows[0].id == progress.id,
                    "progress watch did not update the same row")
        try require(botProductionInt(update.rows[0].body["percent"]) == 100, "progress update payload missing")
        let older = try await rows.history(before: progress.id, limit: 1)
        try require(older.rows.count == 1 && botProductionString(older.rows[0].body["text"]) == "真实 JSONL 用户消息"
                    && !older.hasMore, "row-ID history pagination failed")

        let action = BotUserAction(nonce: "nonce-persistent", botID: "main", kind: .chat, text: "真实动作消息")
        let accepted = try await rows.perform(action)
        try require(accepted == .accepted(eventID: "check-action-nonce-persistent"),
                    "plan→commit action was not accepted")
        let duplicate = try await rows.perform(action)
        try require(duplicate == .duplicate(eventID: "check-action-nonce-persistent"),
                    "same nonce was not a duplicate")
        let plannedActions = await planner.actions
        let plannedTrusts = await planner.trusts
        try require(plannedActions.count == 1 && plannedTrusts == [.ownerDirect],
                    "duplicate reached planner or host trust was wrong")
        let actionBatch = try await rows.watch(after: update.cursor)
        try require(actionBatch.rows.contains { botProductionString($0.body["text"]) == "真实动作消息"
                      && $0.provenance.eventIDs == ["check-action-nonce-persistent"] },
                    "committed action did not project through SQLite")
        try require(try await domain.eventID(botID: action.botID, nonce: action.nonce)
                    == "check-action-nonce-persistent", "durable nonce missing")

        _ = try await memoryStore.write(BotMemoryStoreWriteRequest(
            action: .write, path: "agent/notes/check.md", content: "真实只读记忆",
            expectedVersion: 0,
            author: BotMemoryAuthor(botID: "main", kind: .system),
            atMS: 5_000))
        _ = try await environment.routineMachine.create(
            botId: "main", title: "真实 Routine", prompt: "生成报告",
            schedule: .interval(everyMinutes: 5, timezone: "UTC"), now: 5_000, id: "routine-check")
        let audit = BotAuditRecord(
            at: 6_000, event: "grant.added", source: "production-check", decision: .allow,
            principal: BotAuditPrincipal(botId: "main", sessionId: "main", kind: "ipc", certain: true),
            effects: [BotAuditEffect(tool: "phone.files", operation: "delete",
                                     resourceDigest: "sha256:resource", argsDigest: "sha256:arguments",
                                     mutability: .destructive, policy: .ask)],
            grants: [BotAuditGrant(id: "grant-check", scope: .once, decision: .allow,
                                   resourceDigest: "sha256:resource")], reason: "check")
        try require(await BotAuditLog(eventLog: domain).append(audit), "grant audit append failed")
        let rename = BotEvent(type: "ui.system_event", eventId: "runtime-rename", time: 6_100,
                              origin: .local(source: "user"), traceId: "runtime-rename",
                              principal: BotPrincipal(botId: "main", sessionId: nil, kind: "ipc"),
                              causationId: nil, correlationId: nil,
                              data: .object(["event": .string("renamed"), "botName": .string("真实大肥鱼")]))
        _ = try await domain.append(rename)
        let infoDriver = BotProductionInfoDriver.production(environment: environment)
        let snapshot = try await infoDriver.load()
        let readableMemories = snapshot.memories.filter {
            !BotMemoryAuthorizer.isIndex($0.document.path)
        }
        let readableMemoryPaths = readableMemories.map(\.document.path)
        try require(snapshot.botName == "真实大肥鱼",
                    "production info botName mismatch: \(snapshot.botName)")
        try require(readableMemoryPaths == ["agent/notes/check.md"]
                    && readableMemories.first?.document.content == "真实只读记忆",
                    "production info non-index memories mismatch: paths=\(readableMemoryPaths), "
                        + "contents=\(readableMemories.map(\.document.content))")
        let memoryPaths = snapshot.memories.map(\.document.path)
        try require(memoryPaths.contains("agent/INDEX.md") && memoryPaths.contains("user/INDEX.md"),
                    "production info memory indexes missing: \(memoryPaths)")
        try require(!snapshot.routines.isEmpty && snapshot.routines.map(\.id) == ["routine-check"]
                    && snapshot.routines[0].enabled,
                    "production info routines mismatch: \(snapshot.routines.map(\.id))")
        try require(snapshot.approvals.count == 1 && snapshot.approvals[0].decision == .allow
                    && snapshot.approvals[0].parameterSummary.contains("phone.files/delete")
                    && !snapshot.approvals[0].parameterSummary.contains("production-check"),
                    "grant audit projection/redaction failed")
        try await domain.close()

        let reopened = try SQLiteDomainStore(fileURL: databaseURL, now: { 7_000 })
        let reopenedEnvironment = BotProductionEnvironment(
            domain: reopened, botID: "main", sessionID: "main",
            routineMachine: RoutineMachine(store: SQLiteRoutineStore(domainStore: reopened)),
            memory: BotMemory(
                store: SQLiteBotMemoryDocumentStore(eventLog: reopened, botID: "main", now: { 7_000 }),
                botID: "main", now: { 7_000 }),
            grants: BotGrantStore(domainStore: reopened, now: { 7_000 }),
            planner: planner, sessionLogURL: sessionURL)
        let reopenedRows = BotProductionRowService(environment: reopenedEnvironment)
        let persistedDuplicate = try await reopenedRows.perform(action)
        try require(persistedDuplicate == .duplicate(eventID: "check-action-nonce-persistent"),
                    "nonce did not survive SQLite reopen")
        try require(await planner.actions.count == 1, "reopened duplicate reached planner")

        let rejectedAction = BotUserAction(nonce: "nonce-rejected", botID: "main", kind: .chat, text: "拒绝后再试")
        await planner.setAccepted(false)
        let rejected = try await reopenedRows.perform(rejectedAction)
        try require(rejected == .rejected(reason: "check_rejected"), "planner rejection was not returned")
        try require(try await reopened.eventID(botID: rejectedAction.botID, nonce: rejectedAction.nonce) == nil,
                    "rejected action consumed its nonce")
        await planner.setAccepted(true)
        let retry = try await reopenedRows.perform(rejectedAction)
        try require(retry == .accepted(eventID: "check-action-nonce-rejected"), "retry after rejection failed")
        let retryDuplicate = try await reopenedRows.perform(rejectedAction)
        try require(retryDuplicate == .duplicate(eventID: "check-action-nonce-rejected"),
                    "retry duplicate was not durable")

        let reopenedInfo = BotProductionInfoDriver.production(environment: reopenedEnvironment)
        let reopenedSnapshot = try await reopenedInfo.load()
        let reopenedMemories = reopenedSnapshot.memories.filter {
            !BotMemoryAuthorizer.isIndex($0.document.path)
        }
        try require(reopenedSnapshot.botName == "真实大肥鱼" && reopenedMemories.count == 1
                    && reopenedSnapshot.routines.first?.enabled == true && reopenedSnapshot.approvals.count == 1,
                    "reopened production info is inconsistent")

        let unavailableRows = BotProductionRowService(environment: BotProductionEnvironment(
            domain: reopened, botID: "main", sessionID: "main",
            routineMachine: RoutineMachine(store: SQLiteRoutineStore(domainStore: reopened)),
            memory: BotMemory(
                store: SQLiteBotMemoryDocumentStore(eventLog: reopened, botID: "main"),
                botID: "main"),
            grants: BotGrantStore(domainStore: reopened),
            sessionLogURL: sessionURL))
        let unavailableAction = BotUserAction(nonce: "nonce-unavailable", botID: "main", kind: .chat, text: "不会执行")
        let unavailableResult = try await unavailableRows.perform(unavailableAction)
        guard case .rejected(let unavailableReason) = unavailableResult else {
            throw BotProductionCheckFailure(description: "unavailable planner reported success")
        }
        try require(unavailableReason.contains("planner 尚未接入"), "unavailable planner error is not explicit")
        try require(try await reopened.eventID(botID: unavailableAction.botID, nonce: unavailableAction.nonce) == nil,
                    "unavailable planner consumed its nonce")

        let turn = BotDSHSessionEvent(type: "turn/start", seq: 10, time: 1_000,
                                      data: ["turn": .number(7)])
        let tool = BotDSHSessionEvent(type: "tool/call", seq: 11, time: 1_100, data: [
            "name": .string("read"), "callId": .string("read-report"),
            "arguments": .string("{\"path\":\"/tmp/report.md\"}"),
        ])
        let working = BotRuntimePresentationFactory.make(
            botID: "main", sessionID: "main", sessionEvents: [turn, tool], uiEvents: [], now: 1_100)
        try require(working.fishState == .working && working.runningTurnID == "7"
                    && working.activity?.status == .toolRunning
                    && working.activity?.detail.contains("report.md") == true,
                    "real turn/tool presentation failed")
        let stream = BotDSHSessionEvent(type: "assistant/stream", seq: 12, time: 1_200,
                                        data: ["channel": .string("text")])
        let speaking = BotRuntimePresentationFactory.make(
            botID: "main", sessionID: "main", sessionEvents: [turn, stream], uiEvents: [], now: 1_200)
        try require(speaking.fishState == .speaking && speaking.activity == nil,
                    "stream did not hide activity")
        let approval = BotEvent(type: "approval.requested", eventId: "fish-approval", time: 1_300,
                                origin: .local(source: "card-bridge"), traceId: "fish-approval",
                                principal: BotPrincipal(botId: "main", sessionId: "main", kind: "chat"),
                                causationId: nil, correlationId: nil, data: .object([:]))
        let alerting = BotRuntimePresentationFactory.make(
            botID: "main", sessionID: "main", sessionEvents: [turn, tool], uiEvents: [approval], now: 1_300)
        try require(alerting.fishState == .alerting, "approval did not drive alerting state")
        let settled = BotEvent(type: "task.settled", eventId: "fish-settled", time: 1_400,
                               origin: .local(source: "card-bridge"), traceId: "fish-settled",
                               principal: BotPrincipal(botId: "main", sessionId: "main", kind: "chat"),
                               causationId: nil, correlationId: nil,
                               data: .object(["status": .string("completed")]))
        let celebrated = BotRuntimePresentationFactory.make(
            botID: "main", sessionID: "main", sessionEvents: [], uiEvents: [settled], now: 1_400)
        let expired = BotRuntimePresentationFactory.make(
            botID: "main", sessionID: "main", sessionEvents: [], uiEvents: [settled], now: 5_000)
        try require(celebrated.fishState == .celebrate && expired.fishState == .idle,
                    "celebrate one-shot did not expire")
        let failure = BotEvent(type: "runtime.error", eventId: "fish-error", time: 1_400,
                               origin: .local(source: "card-bridge"), traceId: "fish-error",
                               principal: BotPrincipal(botId: "main", sessionId: "main", kind: "chat"),
                               causationId: nil, correlationId: nil,
                               data: .object(["error": .string("boom")]))
        let sad = BotRuntimePresentationFactory.make(
            botID: "main", sessionID: "main", sessionEvents: [], uiEvents: [failure], now: 1_400)
        let recovered = BotRuntimePresentationFactory.make(
            botID: "main", sessionID: "main", sessionEvents: [], uiEvents: [failure], now: 6_000)
        try require(sad.fishState == .sad && recovered.fishState == .idle,
                    "sad one-shot did not expire")
        let end = BotDSHSessionEvent(type: "turn/end", seq: 13, time: 1_500,
                                     data: ["reason": .object(["kind": .string("completed")])])
        let ended = BotRuntimePresentationFactory.make(
            botID: "main", sessionID: "main", sessionEvents: [turn, end], uiEvents: [], now: 1_500)
        try require(ended.fishState == .idle && ended.runningTurnID == nil && ended.activity == nil,
                    "turn end did not clear presentation")
        try await reopened.close()

        return [
            "session-jsonl-row-rebuild",
            "sqlite-watch-and-row-history",
            "plan-commit-accepted-duplicate-reopen",
            "planner-rejection-retry-and-unavailable-fail-closed",
            "memory-routine-grant-read-only-info",
            "runtime-context-read",
            "fish-production-presentation-activity-ttl",
        ]
    }

    private static func progressEvent(id: String, time: Int64, percent: Int) -> BotEvent {
        BotEvent(type: "card.presented", eventId: id, time: time,
                 origin: .local(source: "card-bridge"), traceId: "trace-\(id)",
                 principal: BotPrincipal(botId: "main", sessionId: "main", kind: "chat"),
                 causationId: nil, correlationId: nil,
                 data: .object(["card": .object([
                    "cardType": .string("progress"), "cardKey": .string("production-check"),
                    "title": .string("真实进度"), "state": .string(percent == 100 ? "done" : "running"),
                    "percent": .number(Double(percent)),
                 ])]))
    }

    private static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw BotProductionCheckFailure(description: message) }
    }
}
#endif
