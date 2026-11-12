// SPDX-License-Identifier: MIT

import Foundation
import UIKit
import XCTest
import PhoneDSH
import PhoneDSHADB
import PhoneDSHAgentCore
import PhoneDSHBot
import PhoneDSHEngine
import PhoneDSHHarness
@testable import BotE2EApp

@MainActor
final class BotCompositionE2ETests: XCTestCase {
    func testProductionCompositionUsesRealHostAndWorker() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("bot-production-composition-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SQLiteDomainStore(fileURL: root.appendingPathComponent("domain.sqlite"))
        // The routine scheduler defaults to the production quiet window
        // 23:00–08:00. A test run at 04:42 would defer the due routine to
        // 08:00 (the second-round rerun did exactly that: effects=[] runs=[]),
        // so pin the production scheduler clock to local noon — the same
        // deterministic start the eval runner uses — instead of changing any
        // product default.
        let schedulerNow = Self.deterministicNoon()
        let launch = try await BotRuntimeComposition.prepare(
            store: store, now: { schedulerNow })
        let environment = launch.environment
        let mock = MockModelUpstream()
        mock.script = .generic(command: "printf BOT_TOOL", toolText: "BOT_TOOL", finalText: "BOT_COMPOSITION_OK")
        let mockURL = try mock.start()
        defer { mock.stop() }
        guard let worker = Bundle.main.url(forResource: "worker", withExtension: nil) else {
            return XCTFail("the real packed Worker is absent")
        }
        let bundle = PhoneDSHBundleLocation(staticDirectory: worker)
        XCTAssertTrue(bundle.exists())
        let mcpPolicy = MCPEgressPolicy()
        try mcpPolicy.grantBotRuntimeEndpoint(
            try XCTUnwrap(launch.composition.server.url), token: launch.composition.server.token)
        let baseCredentials = StaticCredentialProvider([
            CredentialScope(service: "127.0.0.1"): Credential(
                kind: .apiKey(header: "x-api-key"), value: "composition-test-fixture"),
        ])
        // The same production assembly the App's ChatModel boots, including
        // nativeMCP and the Bot Worker environment.
        let configuration = ChatHostConfiguration.makeProduction(
            workspaceRoot: root.appendingPathComponent("workspace", isDirectory: true),
            bundle: bundle,
            allowedModelHosts: [mockURL.absoluteString],
            egressAllowHosts: [],
            // The production App (ChatModel) marks its profile's standard
            // model endpoints replay-safe, so the gateway treats those POSTs as
            // model traffic instead of Bot egress writes. Without it the
            // mock model's inference POST opens an approval.requested card
            // that nobody can approve, and the Worker times out after 5 s.
            replaySafeModelEndpoints: PhoneDSHConfiguration.standardModelEndpoints(
                baseURL: mockURL),
            credentialProvider: PhoneMCPCredentialProvider(policy: mcpPolicy, base: baseCredentials),
            egressAuthorizer: mcpPolicy,
            workerEnvironment: launch.workerEnvironment.merging([
                "DEEPSEEK_BASE_URL": mockURL.absoluteString,
                "DEEPSEEK_API_KEY": "composition-test-placeholder",
                "DSH_TELEMETRY_DISABLED": "1",
                "PDSH_LLM_DELIVERY_IDLE_TIMEOUT_MS": "5000",
            ]) { _, new in new },
            nativeMCP: ADBMCPServer.shared,
            drainDeadline: 2, helloTimeout: 60)
        let app = try XCTUnwrap(UIApplication.shared.delegate as? AppDelegate)
        let engineHolder = BotCompositionEngineHolder()
        let host = PhoneDSHHost(configuration: configuration) { configuration in
            await engineHolder.attach(configuration, to: app.anchor)
        }
        var activeHost = host
        try await launch.composition.start(host: host)
        let mainSessionID = await launch.composition.remote.mainSessionIdentifier()
        let sessionID = try XCTUnwrap(mainSessionID)
        XCTAssertFalse(sessionID.isEmpty)

        let direct = try await launch.composition.remote.sendUserMessage("请给出结果")
        XCTAssertEqual(direct.status, "completed", direct.error ?? "no error")
        XCTAssertTrue(direct.text.contains("BOT_COMPOSITION_OK"),
                      "text=\(direct.text); requests=\(mock.requestCount)")
        let transport = try await host.makeTransport()
        var workerToolNames: [String] = []
        for _ in 0..<40 {
            let inventory = try await transport.call("phone/listTools", args: .object([:]))
            workerToolNames = (inventory["tools"]?.arrayValue ?? []).compactMap {
                $0["name"]?.stringValue
            }
            if workerToolNames.contains("mcp__phone__Task") { break }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        XCTAssertTrue(workerToolNames.contains("mcp__phone__Task"),
                      "Bot MCP Task must be visible in the Worker tools/list: \(workerToolNames)")
        XCTAssertTrue(workerToolNames.contains("mcp__phone__BotVolatileContext"),
                      "Bot MCP volatile tool must be visible in the Worker tools/list")

        let rows = BotProductionRowService(environment: environment)
        let action = BotUserAction(nonce: "composition-chat", botID: "main", kind: .chat, text: "请给出结果")
        let accepted = try await rows.perform(action)
        XCTAssertEqual(accepted, .accepted(eventID: "action:composition-chat"))
        let events = try await BotProductionEventReader.all(domain: store)
        let replies = events.filter { $0.type == "conversation.assistant_message" }
        XCTAssertTrue(replies.contains { $0.data["text"]?.stringValue?.contains("BOT_COMPOSITION_OK") == true })
        XCTAssertTrue(events.contains { $0.type == "ledger.usage_recorded" })

        let unauthorized = try await post(
            url: try XCTUnwrap(launch.composition.server.url), token: "wrong-token",
            body: Data(#"{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}"#.utf8))
        XCTAssertEqual(unauthorized.status, 401)
        let list = try await post(
            url: try XCTUnwrap(launch.composition.server.url), token: launch.composition.server.token,
            body: Data(#"{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}"#.utf8))
        XCTAssertEqual(list.status, 200)
        XCTAssertNotNil(list.json["result"]?["tools"]?.arrayValue)

        let volatileArguments: PhoneDSHBot.BotJSONValue = .object(["sessionId": .string(sessionID)])
        _ = try await launch.composition.runtime.registerIdentity(
            runtimeId: BotMCPRuntime.defaultRuntimeID, sessionId: sessionID,
            callId: "volatile-context", name: BotToolCatalog.volatileContextName,
            arguments: volatileArguments)
        let volatile = await launch.composition.handler.rpc(
            method: "tools/call",
            params: .object([
                "name": .string(BotToolCatalog.volatileContextName),
                "arguments": volatileArguments,
            ]), id: .string("volatile-context"))
        XCTAssertEqual(volatile["result"]?["structuredContent"]?["schemaVersion"]?.intValue, 1)
        XCTAssertTrue(volatile["result"]?["structuredContent"]?["blocks"]?["persona"]?.stringValue?
            .contains("大肥鱼") == true)

        let approvalArguments: BotJSONValue = .object(["command": .string("printf BOT_TOOL")])
        let approvalRegistration = try await launch.composition.runtime.registerIdentity(
            runtimeId: BotMCPRuntime.defaultRuntimeID, sessionId: sessionID,
            callId: "approval-smoke", name: "bash", arguments: approvalArguments)
        let approval = await launch.composition.runtime.approve(
            runtimeId: BotMCPRuntime.defaultRuntimeID, callId: approvalRegistration.callId,
            name: "bash", action: "run command", detail: "fixture", command: "printf BOT_TOOL",
            argsDigest: approvalRegistration.argsDigest, alwaysScope: "until", askAction: "run-command")
        print("APPROVAL_E2E \(approval)")
        XCTAssertTrue(approval.allowed)

        _ = try await launch.composition.runtime.registerIdentity(
            runtimeId: BotMCPRuntime.defaultRuntimeID, sessionId: sessionID,
            callId: "direct-task-parent", name: "mcp__phone__Task", arguments: .object([:]))
        let directParentIdentity = await launch.composition.runtime.identityForApproval(
            runtimeId: BotMCPRuntime.defaultRuntimeID, callId: "direct-task-parent")
        let directParent = try XCTUnwrap(directParentIdentity)
        mock.script = .generic(command: "printf TASK_TOOL", toolText: "TASK_TOOL", finalText: "BOT_TASK_OK")
        let directTask = try await launch.composition.remote.start(request: BotTaskRequest(
            parent: directParent, title: "独立 Task", prompt: "完成独立任务",
            asynchronous: false, timeoutMs: 15_000))
        print("DIRECT_TASK_E2E \(directTask)")
        XCTAssertEqual(directTask.status, "completed", directTask.error ?? "no error")
        XCTAssertTrue(directTask.result?.contains("BOT_TASK_OK") == true)

        mock.scriptForRequest = { body in
            guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                  let messages = object["messages"] as? [[String: Any]],
                  let prompt = messages.last(where: { message in
                      guard message["role"] as? String == "user",
                            let content = message["content"] as? [[String: Any]] else { return false }
                      return content.contains { $0["type"] as? String == "text" }
                  }), let content = prompt["content"] as? [[String: Any]] else { return nil }
            // The Task child receives the authorization + task-contract
            // envelope followed by the delegated text, not the bare prompt.
            // Match the real request shape (the parent turn and the direct
            // Task carry no `<task_authorization>` block) instead of requiring
            // the first text block to equal "完成委派" exactly; a mismatch
            // made the child fall back to the parent's `.sequence` script and
            // produce TASK_PARENT_DONE.
            let text = content.compactMap { $0["text"] as? String }.joined(separator: "\n")
            return text.contains("<task_authorization>") && text.contains("完成委派")
                ? .generic(command: "printf TASK_TOOL", toolText: "TASK_TOOL", finalText: "BOT_TASK_OK")
                : nil
        }
        mock.script = .sequence(
            tools: [MockModelToolCall(
                name: "mcp__phone__Task",
                arguments: .object(["task_title": .string("真实 Task"), "prompt": .string("完成委派")]))],
            finalText: "TASK_PARENT_DONE")
        let taskAction = BotUserAction(nonce: "composition-task", botID: "main", kind: .chat, text: "委派一个任务")
        let taskResult = try await rows.perform(taskAction)
        XCTAssertEqual(taskResult, .accepted(eventID: "action:composition-task"))
        let taskEvents = try await BotProductionEventReader.all(domain: store)
        print("TASK_E2E result=\(taskResult); modelRequests=\(mock.requestCount); toolResults=\(taskEvents.filter { $0.type == "conversation.tool_result" }.map(\.data))")
        let delegatedTasks = taskEvents.filter {
            $0.type == "task.created" && $0.data["task_id"]?.stringValue != directTask.taskId
        }
        XCTAssertEqual(delegatedTasks.count, 1)
        let task = try XCTUnwrap(delegatedTasks.first)
        let taskID = try XCTUnwrap(task.data["task_id"]?.stringValue)
        let taskSessionID = try XCTUnwrap(task.data["sessionId"]?.stringValue)
        XCTAssertNotEqual(taskSessionID, sessionID)
        XCTAssertFalse(taskSessionID.isEmpty)
        let settled = try XCTUnwrap(taskEvents.first {
            $0.type == "task.settled" && $0.data["task_id"]?.stringValue == taskID
        })
        XCTAssertEqual(settled.data["status"]?.stringValue, "completed")
        XCTAssertTrue(settled.data["result"]?.stringValue?.contains("BOT_TASK_OK") == true)
        // `rows.perform` returns when the user action is accepted; the turn's
        // post-tool-result model call (and the Task-settled parent wake) write
        // their assistant message afterwards. Reading the event log once here
        // raced that write in the second-round rerun, so poll the durable log
        // instead of asserting on the first snapshot.
        var parentEvents = taskEvents
        let parentDeadline = ContinuousClock.now.advanced(by: .seconds(20))
        while !parentEvents.contains(where: {
            $0.type == "conversation.assistant_message"
                && $0.data["text"]?.stringValue?.contains("TASK_PARENT_DONE") == true
        }), ContinuousClock.now < parentDeadline {
            try await Task.sleep(for: .milliseconds(100))
            parentEvents = try await BotProductionEventReader.all(domain: store)
        }
        XCTAssertTrue(parentEvents.contains {
            $0.type == "conversation.assistant_message"
                && $0.data["text"]?.stringValue?.contains("TASK_PARENT_DONE") == true
        }, "the parent turn/wake must persist TASK_PARENT_DONE; messages="
            + "\(parentEvents.filter { $0.type == "conversation.assistant_message" }.map(\.data))")

        mock.script = .generic(command: "printf BOT_TOOL", toolText: "BOT_TOOL", finalText: "BOT_ROUTINE_OK")
        let routine = try await launch.composition.runtime.routineMachine.create(
            botId: "main", title: "生产组合根 routine", prompt: "生成固定结果",
            schedule: .interval(everyMinutes: 1, timezone: "UTC"),
            now: schedulerNow - 120_000, id: "composition-routine")
        XCTAssertTrue(routine.enabled)
        // The Task parent turn/wake must finish before a routine may run
        // (`RoutineScheduler.busy` skips a busy main chat). The assistant
        // message above is durable before the turn fully settles, so wait for
        // the remote turn state instead of ticking into a busy session.
        let turnIdleDeadline = ContinuousClock.now.advanced(by: .seconds(20))
        while await launch.composition.remote.isMainTurnBusy(),
              ContinuousClock.now < turnIdleDeadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        let clock = ContinuousClock()
        let deliveryDeadline = clock.now.advanced(by: .seconds(5))
        var deliveries = try await store.effects(state: .acked)
        while !deliveries.contains(where: { $0.effect.kind == BotRoutineOutbox.kind }),
              clock.now < deliveryDeadline {
            try await launch.composition.scheduler.tick()
            await launch.composition.scheduler.waitForIdle()
            try await Task.sleep(for: .milliseconds(100))
            deliveries = try await store.effects(state: .acked)
        }
        let routineEvents = try await BotProductionEventReader.all(domain: store)
        print("ROUTINE_E2E effects=\(deliveries.map { [$0.effect.kind, $0.state.rawValue] }); runs=\(routineEvents.filter { $0.type == "routine.run_finished" || $0.type == "conversation.automation_run" }.map(\.data))")
        XCTAssertTrue(deliveries.contains { $0.effect.kind == BotRoutineOutbox.kind })
        XCTAssertTrue(routineEvents.contains {
            $0.type == "conversation.automation_run" && $0.data["text"]?.stringValue?.contains("BOT_ROUTINE_OK") == true
        })
        await launch.composition.scheduler.stop()
        await launch.composition.outbox.stop()

        let requestCount = mock.requestCount
        let duplicate = try await rows.perform(action)
        XCTAssertEqual(duplicate, .duplicate(eventID: "action:composition-chat"))
        XCTAssertEqual(mock.requestCount, requestCount)

        try await host.plannedRestart(reason: "bot-production-composition")
        let resumed = try await launch.composition.remote.sendUserMessage("重启后的继续对话")
        XCTAssertEqual(resumed.status, "completed")
        XCTAssertTrue(resumed.text.contains("BOT_ROUTINE_OK"))
        let recoveredDuplicate = try await rows.perform(action)
        XCTAssertEqual(recoveredDuplicate, .duplicate(eventID: "action:composition-chat"))

        // A Host rebuild (ChatModel.stop -> start / restartEngine) must rebind
        // the same Bot runtime instead of refusing a different Host.
        try await activeHost.stop()
        let rebuilt = PhoneDSHHost(configuration: configuration) { configuration in
            await engineHolder.attach(configuration, to: app.anchor)
        }
        try await launch.composition.start(host: rebuilt)
        activeHost = rebuilt
        let rebuiltSessionID = await launch.composition.remote.mainSessionIdentifier()
        XCTAssertEqual(rebuiltSessionID, sessionID)
        let afterRebuild = try await launch.composition.remote.sendUserMessage("Host 重建后的继续对话")
        XCTAssertEqual(afterRebuild.status, "completed", afterRebuild.error ?? "no error")
        XCTAssertTrue(afterRebuild.text.contains("BOT_ROUTINE_OK"))

        // Foreground resume: the Host parks (the Worker page is destroyed) and
        // resumes into a fresh Worker with an empty session-credential map.
        // The new HELLO boot id must make the composition re-claim the session
        // before the next turn; otherwise the Worker's bash registration is
        // rejected as `unauthorized` and never self-heals.
        mock.script = .generic(command: "printf AFTER_RESUME", toolText: "AFTER_RESUME",
                               finalText: "AFTER_RESUME_OK")
        var sawWorkerRecovery = false
        launch.composition.onStateChange = { state in
            if state == .recovering { sawWorkerRecovery = true }
        }
        try await activeHost.park()
        try await activeHost.resume()
        let recoveryDeadline = Date().addingTimeInterval(20)
        while Date() < recoveryDeadline {
            if sawWorkerRecovery && launch.composition.state == .ready { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertTrue(sawWorkerRecovery && launch.composition.state == .ready,
                      "the Bot composition must rebind after the resumed Worker's new HELLO")
        let afterResume = try await launch.composition.remote.sendUserMessage("锁屏后继续")
        XCTAssertEqual(afterResume.status, "completed", afterResume.error ?? "no error")
        XCTAssertTrue(afterResume.text.contains("AFTER_RESUME_OK"),
                      "text=\(afterResume.text); requests=\(mock.requestCount)")
        let resumeEvents = try await BotProductionEventReader.all(domain: store)
        let resumeToolResults = resumeEvents.filter { $0.type == "conversation.tool_result" }
        let resumeResultText = String(describing: resumeToolResults.map(\.data))
        XCTAssertTrue(resumeResultText.contains("AFTER_RESUME"),
                      "the resumed turn must execute bash: \(resumeResultText)")
        XCTAssertFalse(resumeResultText.contains("identity-bridge"),
                       "a resumed Worker must not fail identity registration: \(resumeResultText)")
        XCTAssertFalse(resumeResultText.contains("unauthorized"),
                       "a resumed Worker must not stay unauthorized: \(resumeResultText)")

        await launch.composition.stop()
        try await activeHost.stop()
        try await store.close()
    }

    /// A wall-clock-hour-independent scheduler start: local noon on the test
    /// day. Mirrors `EvalSchedulerClock.deterministicStart`.
    private static func deterministicNoon(now: Date = Date()) -> Int64 {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        var components = calendar.dateComponents([.year, .month, .day], from: now)
        components.hour = 12
        components.minute = 0
        components.second = 0
        components.nanosecond = 0
        let date = calendar.date(from: components) ?? now
        return Int64(date.timeIntervalSince1970 * 1_000)
    }

    /// The old DEBUG-only production checks now live here instead of the App
    /// target; this drives the same real row/projection/services code paths.
    func testProductionServicesChecks() async throws {
        let passed = try await BotProductionChecks.run()
        XCTAssertTrue(passed.contains("session-jsonl-row-rebuild"))
        XCTAssertTrue(passed.contains("info-refresh-reads-new-routine"))
        XCTAssertTrue(passed.contains("plan-commit-accepted-duplicate-reopen"))
        XCTAssertTrue(passed.contains("fish-production-presentation-activity-ttl"))
    }

    /// F3/F4 end to end: the real `BotSessionEpochEraser` parks the host,
    /// rewrites the closed session, switches the main session and appends the
    /// continuation notice. The row service must rebuild to the new epoch and
    /// the notice must be visible; a cold start that rebuilds the composition
    /// from the same durable store must land on the same projection. The old
    /// session log and the projection cache must no longer carry the erased
    /// text (including the `agent/inbox/spliced` copy).
    func testSessionEpochErasureProjectsContinuationNoticeAndColdStart() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("bot-erasure-ui-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspaceRoot = root.appendingPathComponent("workspace", isDirectory: true)
        let store = try SQLiteDomainStore(fileURL: root.appendingPathComponent("domain.sqlite"))
        let profileStore = BotProfileStore(directory: root.appendingPathComponent("profiles"))
        let schedulerNow = Self.deterministicNoon()
        let launch = try await BotRuntimeComposition.prepare(
            store: store, profileStore: profileStore,
            workspaceRoot: workspaceRoot, now: { schedulerNow })
        let composition = launch.composition
        let mock = MockModelUpstream()
        mock.script = .generic(command: "printf ERASE_TOOL", toolText: "ERASE_TOOL",
                               finalText: "ERASE_DONE")
        let mockURL = try mock.start()
        defer { mock.stop() }
        guard let worker = Bundle.main.url(forResource: "worker", withExtension: nil) else {
            return XCTFail("the real packed Worker is absent")
        }
        let bundle = PhoneDSHBundleLocation(staticDirectory: worker)
        let app = try XCTUnwrap(UIApplication.shared.delegate as? AppDelegate)
        let engineHolder = BotCompositionEngineHolder()

        func makeHost(_ composition: BotRuntimeComposition) throws -> PhoneDSHHost {
            let mcpPolicy = MCPEgressPolicy()
            try mcpPolicy.grantBotRuntimeEndpoint(
                try XCTUnwrap(composition.server.url), token: composition.server.token)
            let baseCredentials = StaticCredentialProvider([
                CredentialScope(service: "127.0.0.1"): Credential(
                    kind: .apiKey(header: "x-api-key"), value: "erasure-test-fixture"),
            ])
            let configuration = ChatHostConfiguration.makeProduction(
                workspaceRoot: workspaceRoot,
                bundle: bundle,
                allowedModelHosts: [mockURL.absoluteString],
                egressAllowHosts: [],
                replaySafeModelEndpoints: PhoneDSHConfiguration.standardModelEndpoints(
                    baseURL: mockURL),
                credentialProvider: PhoneMCPCredentialProvider(
                    policy: mcpPolicy, base: baseCredentials),
                egressAuthorizer: mcpPolicy,
                workerEnvironment: composition.workerEnvironment.merging([
                    "DEEPSEEK_BASE_URL": mockURL.absoluteString,
                    "DEEPSEEK_API_KEY": "erasure-test-placeholder",
                    "DSH_TELEMETRY_DISABLED": "1",
                    "PDSH_LLM_DELIVERY_IDLE_TIMEOUT_MS": "5000",
                ]) { _, new in new },
                nativeMCP: ADBMCPServer.shared,
                drainDeadline: 2, helloTimeout: 60)
            return PhoneDSHHost(configuration: configuration) { configuration in
                await engineHolder.attach(configuration, to: app.anchor)
            }
        }

        let host = try makeHost(composition)
        try await composition.start(host: host)
        let oldSessionValue = await composition.remote.mainSessionIdentifier()
        let oldSession = try XCTUnwrap(oldSessionValue)
        let kept = try await composition.remote.sendUserMessage("请保留 KEEP_ERASE_UI 这一句")
        XCTAssertEqual(kept.status, "completed", kept.error ?? "no error")
        let erasedTurn = try await composition.remote.sendUserMessage("请移除 ERASE_ME_UI 这一句")
        XCTAssertEqual(erasedTurn.status, "completed", erasedTurn.error ?? "no error")

        // Read the log through the production environment, not a fresh global
        // locator: this composition writes into its own temporary workspace
        // and the locator must scan that root (`BotProductionServices`).
        let snapshot = await launch.environment.sessionSnapshot()
        XCTAssertEqual(snapshot.sessionID, oldSession,
                       "the environment must resolve the composition's main session")
        let oldLog = try XCTUnwrap(snapshot.logURL,
                                   "the locator did not find the session log in the composition workspace")
        let lines = BotSessionLogReader.lines(from: try Data(contentsOf: oldLog))
        let erasedLine = try XCTUnwrap(lines.last {
            $0.type == "user/message" && $0.allText.contains("ERASE_ME_UI")
        })
        XCTAssertTrue(lines.contains {
            $0.type == "agent/inbox/spliced" && $0.allText.contains("ERASE_ME_UI")
        }, "fixture precondition: the turn must have an inbox splice copy")

        // The projection cache is a derived copy; seed it with the erased text
        // so the erasure proof has to remove it.
        let projectionCache = workspaceRoot.appendingPathComponent(
            "materialized/home/storages/session_projcache/sessions/\(oldSession).json")
        try FileManager.default.createDirectory(
            at: projectionCache.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{\"marker\":\"ERASE_ME_UI\"}".utf8).write(to: projectionCache)

        let memory = await composition.runtime.memory(for: "main")
        let write = try await memory.write(
            BotMemoryWriteRequest(
                path: "user/preferences/erase-ui.md",
                content: "ERASE_ME_UI preference",
                expectedVersion: 0,
                evidence: ["record://session/\(oldSession)#\(erasedLine.seq)"]),
            context: BotMemoryWriteContext(
                botID: "main", sessionID: oldSession, authorKind: .chat,
                source: BotMemorySource(kind: .userTurn, sessionID: oldSession),
                trust: .user))
        XCTAssertTrue(write.ok, write.error ?? "memory write failed")

        let unit = try await composition.ensureUnit(for: "main")
        try await unit.info.eraseMemory(path: "user/preferences/erase-ui.md")

        let newSessionValue = await composition.remote.mainSessionIdentifier()
        let newSession = try XCTUnwrap(newSessionValue)
        XCTAssertNotEqual(newSession, oldSession)
        try await unit.rows.start()
        let batch = try await unit.rows.watch(after: 0)
        try assertErasureProjection(
            rows: batch.rows, newSession: newSession,
            checksNewEpoch: true,
            oldSessionLog: oldLog, projectionCache: projectionCache)

        // Cold start: a fresh composition reads the durable main-session
        // pointer and the same row authority.
        await composition.stop()
        try await host.stop()
        let cold = try await BotRuntimeComposition.prepare(
            store: store, profileStore: profileStore,
            workspaceRoot: workspaceRoot, now: { schedulerNow })
        let coldHost = try makeHost(cold.composition)
        try await cold.composition.start(host: coldHost)
        let coldSessionValue = await cold.composition.remote.mainSessionIdentifier()
        XCTAssertEqual(coldSessionValue, newSession)
        let coldUnit = try await cold.composition.ensureUnit(for: "main")
        try await coldUnit.rows.start()
        let coldBatch = try await coldUnit.rows.watch(after: 0)
        try assertErasureProjection(
            rows: coldBatch.rows, newSession: newSession,
            checksNewEpoch: false,
            oldSessionLog: nil, projectionCache: nil)
        // The cold projection still carries the unerased old-epoch line.
        XCTAssertTrue(coldBatch.rows.contains {
            $0.body["text"]?.stringValue?.contains("KEEP_ERASE_UI") == true
        }, "the non-erased old epoch line disappeared after cold start")
        await cold.composition.stop()
        try await coldHost.stop()
        try await store.close()
    }

    private func assertErasureProjection(
        rows: [BotRow], newSession: String, checksNewEpoch: Bool,
        oldSessionLog: URL?, projectionCache: URL?
    ) throws {
        let texts = rows.compactMap { $0.body["text"]?.stringValue }
        XCTAssertTrue(texts.contains {
            $0.contains("对话已接续到新会话")
        }, "the durable ui.notice was not projected into the new epoch rows")
        XCTAssertFalse(texts.contains {
            $0.contains("ERASE_ME_UI")
        }, "erased text was projected back into the rows")
        XCTAssertTrue(texts.contains {
            $0.contains("KEEP_ERASE_UI")
        }, "the non-erased old epoch row is missing")
        if checksNewEpoch {
            XCTAssertTrue(rows.contains {
                $0.id.hasPrefix("e-\(newSession)-")
            }, "no row belongs to the new session epoch")
        }
        if let oldSessionLog {
            let data = try Data(contentsOf: oldSessionLog)
            let text = String(decoding: data, as: UTF8.self)
            XCTAssertFalse(text.contains("ERASE_ME_UI"),
                           "the rewritten session log still contains the erased text")
            XCTAssertTrue(text.contains("KEEP_ERASE_UI"),
                          "the rewrite removed a non-erased line")
            let rewritten = BotSessionLogReader.lines(from: data)
            XCTAssertFalse(rewritten.contains {
                $0.type == "agent/inbox/spliced" && $0.allText.contains("ERASE_ME_UI")
            }, "the agent/inbox/spliced copy survived the rewrite")
            XCTAssertGreaterThanOrEqual(
                rewritten.filter { $0.type == BotSessionErasureTombstone.type }.count, 2,
                "the canonical line and its splice copy must both be tombstones")
        }
        if let projectionCache {
            XCTAssertFalse(FileManager.default.fileExists(atPath: projectionCache.path),
                           "the derived session projection cache survived the rewrite")
        }
    }


    private func post(url: URL, token: String, body: Data) async throws -> (status: Int, json: PhoneDSHBot.BotJSONValue) {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        let (data, response) = try await URLSession.shared.data(for: request)
        return ((response as? HTTPURLResponse)?.statusCode ?? -1,
                (try? PhoneDSHBot.BotJSONValue.parse(data)) ?? .null)
    }
}

@MainActor
private final class BotCompositionEngineHolder {
    var engine: WebEngine?

    func attach(_ configuration: WebEngineConfiguration, to anchor: UIView) -> WebEngine {
        let engine = WebEngine(configuration: configuration)
        engine.attach(to: anchor)
        self.engine = engine
        return engine
    }
}
