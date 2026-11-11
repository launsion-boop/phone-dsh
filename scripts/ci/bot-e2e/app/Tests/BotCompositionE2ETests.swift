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
        let launch = try await BotRuntimeComposition.prepare(store: store)
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
                      return content.first?["type"] as? String == "text"
                  }), let content = prompt["content"] as? [[String: Any]] else { return nil }
            return content.first?["text"] as? String == "完成委派"
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
        XCTAssertTrue(taskEvents.contains {
            $0.type == "conversation.assistant_message" && $0.data["text"]?.stringValue?.contains("TASK_PARENT_DONE") == true
        })

        mock.script = .generic(command: "printf BOT_TOOL", toolText: "BOT_TOOL", finalText: "BOT_ROUTINE_OK")
        let routine = try await launch.composition.runtime.routineMachine.create(
            botId: "main", title: "生产组合根 routine", prompt: "生成固定结果",
            schedule: .interval(everyMinutes: 1, timezone: "UTC"),
            now: Int64(Date().timeIntervalSince1970 * 1_000) - 120_000, id: "composition-routine")
        XCTAssertTrue(routine.enabled)
        try await launch.composition.scheduler.tick()
        await launch.composition.scheduler.waitForIdle()
        let clock = ContinuousClock()
        let deliveryDeadline = clock.now.advanced(by: .seconds(5))
        var deliveries = try await store.effects(state: .acked)
        while !deliveries.contains(where: { $0.effect.kind == BotRoutineOutbox.kind }),
              clock.now < deliveryDeadline {
            try await Task.sleep(for: .milliseconds(50))
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

    /// The old DEBUG-only production checks now live here instead of the App
    /// target; this drives the same real row/projection/services code paths.
    func testProductionServicesChecks() async throws {
        let passed = try await BotProductionChecks.run()
        XCTAssertTrue(passed.contains("session-jsonl-row-rebuild"))
        XCTAssertTrue(passed.contains("plan-commit-accepted-duplicate-reopen"))
        XCTAssertTrue(passed.contains("fish-production-presentation-activity-ttl"))
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
