// SPDX-License-Identifier: MIT

import Foundation
import XCTest
@testable import PhoneDSHBot

private final class BotLiveFrameRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var received: [BotLiveTurnFrame] = []

    func record(_ frame: BotLiveTurnFrame) {
        lock.withLock { received.append(frame) }
    }

    var count: Int { lock.withLock { received.count } }

    var textDeltas: [String] {
        lock.withLock {
            received.compactMap { frame in
                guard case .textDelta(let text) = frame.kind else { return nil }
                return text
            }
        }
    }
}

private final class RecordingBotTeamToolHandler: BotTeamToolHandling, @unchecked Sendable {
    private let lock = NSLock()
    private let names: Set<String>
    private var recorded:
        [(name: String, arguments: BotJSONValue, principal: BotGatewayPrincipal, context: BotMCPRequestContext)] = []

    init(names: Set<String>) {
        self.names = names
    }

    func handles(_ toolName: String) -> Bool { names.contains(toolName) }

    func execute(name: String, arguments: BotJSONValue, principal: BotGatewayPrincipal,
                 context: BotMCPRequestContext) async -> BotMCPCallResult {
        lock.withLock {
            recorded.append((name, arguments, principal, context))
        }
        return .success(.object(["routed": .string(name)]))
    }

    var calls:
        [(name: String, arguments: BotJSONValue, principal: BotGatewayPrincipal, context: BotMCPRequestContext)] {
        lock.withLock { recorded }
    }
}

final class BotRuntimeMultiplexingTests: XCTestCase {
    func testTaskToolsRouteByPrincipalBotIdAndUseThatBotsWorkspace() async throws {
        let fixture = try makeBotMCPFixture()
        defer { fixture.cleanup() }
        let transportA = BotScriptedRemoteTransport(mainId: "gb-a-main", scripts: [
            "gb-a-main": [[.turn(), .assistant("a main"), .end()]],
            "gb-created-1": [[.turn(), .assistant("task a"), .end()]],
        ])
        let transportB = BotScriptedRemoteTransport(mainId: "gb-b-main", scripts: [
            "gb-b-main": [[.turn(), .assistant("b main"), .end()]],
        ])
        let remoteA = try await BotDSHRemoteRuntime(
            transport: transportA, runtime: fixture.runtime, botId: "bot-a")
        let remoteB = try await BotDSHRemoteRuntime(
            transport: transportB, runtime: fixture.runtime, botId: "bot-b")

        _ = try await remoteA.sendUserMessage("a")
        _ = try await remoteB.sendUserMessage("b")
        let rootA = BotWorkspaceLayout.botRoot(botId: "bot-a")
        let rootB = BotWorkspaceLayout.botRoot(botId: "bot-b")
        XCTAssertEqual(transportA.createdCwd("gb-a-main"), rootA)
        XCTAssertEqual(transportB.createdCwd("gb-b-main"), rootB)

        transportA.pause("gb-created-1")
        let started = try await registerAndExecute(
            fixture.runtime, name: "Task",
            arguments: .object([
                "task_title": .string("A task"), "prompt": .string("inspect"),
                "async": .bool(true),
            ]),
            sessionId: "gb-a-main")
        let taskId = try XCTUnwrap(started.structuredContent?["task_id"]?.stringValue)
        XCTAssertEqual(started.structuredContent?["sessionId"], .string("gb-created-1"))
        XCTAssertEqual(transportA.createdCwd("gb-created-1"), rootA,
                       "A's task session must be created under A's Bot root")
        XCTAssertEqual(transportB.createCount, 1, "B's executor must not create A's task session")
        transportA.resume("gb-created-1")

        let completed = try await registerAndExecute(
            fixture.runtime, name: "AwaitTask",
            arguments: .object(["task_id": .string(taskId), "timeout_ms": .number(1_000)]),
            sessionId: "gb-a-main")
        XCTAssertEqual(completed.structuredContent?["status"], .string("completed"))
        XCTAssertEqual(completed.structuredContent?["result"], .string("task a"))

        // B can never read A's task through its own executor.
        let crossAwait = try await registerAndExecute(
            fixture.runtime, name: "AwaitTask",
            arguments: .object(["task_id": .string(taskId), "timeout_ms": .number(100)]),
            sessionId: "gb-b-main")
        XCTAssertEqual(crossAwait.isError, true)
        XCTAssertEqual(crossAwait.structuredContent?["error"]?["code"], .string("invalid_arguments"))

        let created = try await botEvents(fixture.store)
            .filter { $0.type == "task.created" }
        XCTAssertEqual(created.count, 1)
        XCTAssertEqual(created.first?.principal.botId, "bot-a")
        XCTAssertEqual(created.first?.data["sessionId"], .string("gb-created-1"))
    }

    func testTaskToolsFailForABotWithoutAnExecutorInsteadOfBorrowingMain() async throws {
        let fixture = try makeBotMCPFixture(taskExecutor: StubBotTaskExecutor())
        defer { fixture.cleanup() }
        _ = try await fixture.runtime.issueSession(botId: "main", sessionId: "gb-main", kind: .chat)
        _ = try await fixture.runtime.issueSession(botId: "ghost", sessionId: "gb-ghost", kind: .chat)

        let attempts: [(name: String, arguments: BotJSONValue)] = [
            ("Task", BotJSONValue.object([
                "task_title": .string("ghost task"), "prompt": .string("nope"),
                "async": .bool(true),
            ])),
            ("AwaitTask", BotJSONValue.object(["task_id": .string("task-unknown")])),
            ("StopSubagent", BotJSONValue.object(["task_id": .string("task-unknown")])),
        ]
        for (name, arguments) in attempts {
            let result = try await registerAndExecute(
                fixture.runtime, name: name, arguments: arguments, sessionId: "gb-ghost")
            XCTAssertEqual(result.isError, true, "\(name) must fail without a ghost executor")
            XCTAssertEqual(result.structuredContent?["error"]?["code"], .string("unavailable"))
            XCTAssertTrue(
                result.structuredContent?["error"]?["message"]?.stringValue?.contains("ghost") == true,
                "error must name the missing Bot: \(String(describing: result.structuredContent))")
        }
        let created = try await botEvents(fixture.store).filter { $0.type == "task.created" }
        XCTAssertTrue(created.isEmpty)
    }

    func testDetachRemovesOnlyThatBotsExecutor() async throws {
        let fixture = try makeBotMCPFixture()
        defer { fixture.cleanup() }
        _ = try await fixture.runtime.issueSession(botId: "main", sessionId: "gb-main", kind: .chat)
        _ = try await fixture.runtime.issueSession(botId: "bot-b", sessionId: "gb-bot-b", kind: .chat)
        let stub = StubBotTaskExecutor()
        await fixture.runtime.attachTaskExecutor(stub, botID: "bot-b")

        let routed = try await registerAndExecute(
            fixture.runtime, name: "Task",
            arguments: .object([
                "task_title": .string("stub task"), "prompt": .string("inspect"),
                "async": .bool(false),
            ]),
            sessionId: "gb-bot-b")
        XCTAssertNotEqual(routed.isError, true)
        XCTAssertEqual(routed.structuredContent?["status"], .string("completed"))

        await fixture.runtime.detachTaskExecutor(botID: "bot-b")
        let afterDetach = try await registerAndExecute(
            fixture.runtime, name: "Task",
            arguments: .object([
                "task_title": .string("no executor"), "prompt": .string("inspect"),
                "async": .bool(false),
            ]),
            sessionId: "gb-bot-b")
        XCTAssertEqual(afterDetach.isError, true)
        XCTAssertEqual(afterDetach.structuredContent?["error"]?["code"], .string("unavailable"))
    }

    func testRestorePersistedTasksOnlyRevivesTheOwnersBot() async throws {
        let fixture = try makeBotMCPFixture()
        defer { fixture.cleanup() }
        let transportA = BotScriptedRemoteTransport(mainId: "gb-a-main", scripts: [
            "gb-a-main": [[.turn(), .assistant("a main"), .end()]],
        ])
        let transportB = BotScriptedRemoteTransport(mainId: "gb-b-main", scripts: [
            "gb-b-main": [[.turn(), .assistant("b main"), .end()]],
        ])
        let remoteA = try await BotDSHRemoteRuntime(
            transport: transportA, runtime: fixture.runtime, botId: "bot-a")
        let remoteB = try await BotDSHRemoteRuntime(
            transport: transportB, runtime: fixture.runtime, botId: "bot-b")
        _ = try await remoteA.sendUserMessage("a")
        _ = try await remoteB.sendUserMessage("b")

        transportA.pause("gb-created-1")
        transportA.queue(sessionId: "gb-created-1", events: [
            .turn(), .assistant("late a task"), .end(),
        ])
        let started = try await registerAndExecute(
            fixture.runtime, name: "Task",
            arguments: .object([
                "task_title": .string("owned by a"), "prompt": .string("inspect"),
                "async": .bool(true),
            ]),
            sessionId: "gb-a-main")
        let taskId = try XCTUnwrap(started.structuredContent?["task_id"]?.stringValue)

        // A fresh app process builds one executor per Bot. Each must restore
        // only the tasks whose durable snapshot names its own bot.
        let restoredA = try await BotDSHRemoteRuntime(
            transport: BotScriptedRemoteTransport(scripts: [:]),
            runtime: fixture.runtime, botId: "bot-a")
        let restoredB = try await BotDSHRemoteRuntime(
            transport: BotScriptedRemoteTransport(scripts: [:]),
            runtime: fixture.runtime, botId: "bot-b")

        let parentA = try await makeParent(
            fixture.runtime, botId: "bot-a", sessionId: "gb-a-main")
        let restoredRecord = try await restoredA.await(
            taskId: taskId, timeoutMs: 100, parent: parentA)
        XCTAssertEqual(restoredRecord.status, "interrupted")
        XCTAssertEqual(restoredRecord.error, "worker_restarted")

        let parentB = try await makeParent(
            fixture.runtime, botId: "bot-b", sessionId: "gb-b-main")
        do {
            _ = try await restoredB.await(taskId: taskId, timeoutMs: 100, parent: parentB)
            XCTFail("bot-b must not restore bot-a's task")
        } catch let error as BotMCPError {
            guard case .invalidRequest = error else {
                return XCTFail("expected unknown task, got \(error)")
            }
        } catch {
            XCTFail("unexpected error: \(error)")
        }

        transportA.resume("gb-created-1")
        try await Task.sleep(nanoseconds: 100_000_000)
    }

    func testMultipleLiveFrameSubscribersAreIndependent() async throws {
        let fixture = try makeBotMCPFixture()
        defer { fixture.cleanup() }
        let transport = BotScriptedRemoteTransport(scripts: [
            "gb-main": [
                [.turn(), .delta("hel"), .assistant("hello"), .end()],
                [.turn(2), .delta("wor"), .assistant("world"), .end(turn: 2)],
            ],
        ])
        let remote = try await BotDSHRemoteRuntime(transport: transport, runtime: fixture.runtime)
        let first = BotLiveFrameRecorder()
        let second = BotLiveFrameRecorder()
        let firstToken = await remote.subscribeLiveFrames { first.record($0) }
        let secondToken = await remote.subscribeLiveFrames { second.record($0) }

        _ = try await remote.sendUserMessage("one")
        XCTAssertGreaterThan(first.count, 0)
        XCTAssertEqual(first.count, second.count)
        XCTAssertEqual(first.textDeltas, ["hel"])
        XCTAssertEqual(second.textDeltas, ["hel"])
        let firstCountAfterOne = first.count
        let secondCountAfterOne = second.count

        await remote.unsubscribeLiveFrames(firstToken)
        _ = try await remote.sendUserMessage("two")
        XCTAssertEqual(first.count, firstCountAfterOne,
                       "removing one observer must not affect another")
        XCTAssertGreaterThan(second.count, secondCountAfterOne)
        XCTAssertEqual(first.textDeltas, ["hel"])
        XCTAssertEqual(second.textDeltas, ["hel", "wor"])

        // A second unsubscribe is harmless and the remaining token still works.
        await remote.unsubscribeLiveFrames(firstToken)
        XCTAssertGreaterThan(second.count, secondCountAfterOne)
        await remote.unsubscribeLiveFrames(secondToken)
    }

    func testRegisteredTeamToolRoutesAfterNormalAuthorizationAndUnregisteredNamesStayRejected() async throws {
        let fixture = try makeBotMCPFixture()
        defer { fixture.cleanup() }
        _ = try await fixture.runtime.issueSession(botId: "main", sessionId: "gb-main", kind: .chat)

        let beforeRegistration = await fixture.runtime.execute(
            name: "SendToAgent", arguments: .object([:]),
            context: BotMCPRequestContext(callId: "unregistered"))
        XCTAssertEqual(beforeRegistration.isError, true)
        XCTAssertEqual(beforeRegistration.structuredContent?["error"]?["code"], .string("unknown_tool"))
        do {
            _ = try await fixture.runtime.registerIdentity(
                runtimeId: BotMCPRuntime.defaultRuntimeID, sessionId: "gb-main",
                callId: "unregistered", name: "SendToAgent",
                arguments: .object([:]))
            XCTFail("an unregistered team tool must not register identity")
        } catch BotMCPError.unknownTool {}

        let handler = RecordingBotTeamToolHandler(names: ["SendToAgent"])
        await fixture.runtime.registerTeamTools(handler)
        let arguments = BotJSONValue.object([
            "to": .string("bot-b"), "message": .string("hello from main"),
        ])
        let callId = "team-call"
        _ = try await fixture.runtime.registerIdentity(
            runtimeId: BotMCPRuntime.defaultRuntimeID, sessionId: "gb-main",
            callId: callId, name: "SendToAgent", arguments: arguments)
        let effect = BotToolEffectClassifier.effect(for: "SendToAgent", arguments: arguments)
        _ = try await fixture.runtime.grants.add(BotGrant(
            botId: "main", tool: effect.tool, operation: effect.operation,
            resource: effect.resource, scope: .until, decision: .allow))
        let routed = await fixture.runtime.execute(
            name: "SendToAgent", arguments: arguments,
            context: BotMCPRequestContext(callId: callId))
        XCTAssertNotEqual(routed.isError, true, String(describing: routed.structuredContent))
        XCTAssertEqual(routed.structuredContent?["routed"], .string("SendToAgent"))
        let calls = handler.calls
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.principal.botId, "main")
        XCTAssertEqual(calls.first?.context.callId, callId)
        XCTAssertEqual(calls.first?.arguments, arguments)

        let stillUnknown = await fixture.runtime.execute(
            name: "CreateTeammate", arguments: .object([:]),
            context: BotMCPRequestContext(callId: "still-unknown"))
        XCTAssertEqual(stillUnknown.structuredContent?["error"]?["code"], .string("unknown_tool"))
    }

    func testWakeWithHeldMessagesOpensOnlyOneIdleTurnAndCarriesTheBlock() async throws {
        let fixture = try makeBotMCPFixture()
        defer { fixture.cleanup() }
        let transport = BotScriptedRemoteTransport(scripts: [
            "gb-main": [
                [.turn(), .assistant("established"), .end()],
                [.turn(2), .assistant("woken"), .end(turn: 2)],
                [.turn(3), .assistant("still running"), .end(turn: 3)],
            ],
        ])
        let inbox = WakeInbox(store: SQLiteWakeInboxStore(
            domainStore: fixture.store, botId: "main"))
        let remote = try await BotDSHRemoteRuntime(
            transport: transport, runtime: fixture.runtime, wakeInbox: inbox, now: { 1_000 })
        _ = try await remote.sendUserMessage("establish")

        let firstItem = try WakeInboxItem(
            id: "held-wake-1", kind: "agent-held", fromAgentId: "bot-b",
            fromAgentName: "Bee", text: "first held message", createdAt: 1_000)
        _ = try await inbox.enqueue(firstItem)
        try await remote.wakeWithHeldMessages()
        let expected = HeldMessages.block(items: [firstItem]) + "\n\n"
        XCTAssertEqual(transport.prompts["gb-main"]?.text, expected)
        let expectedID = "held:" + (try BotArgumentsDigest.string(for: .array([.string(firstItem.id)])))
        XCTAssertEqual(transport.promptRequestIds.last?.requestId, expectedID)
        let afterWake = try await inbox.items()
        XCTAssertTrue(afterWake.isEmpty)

        // While a chat turn is running the wake is a no-op: no second prompt,
        // and the item remains pending for the next user turn.
        transport.pause("gb-main")
        let running = Task { try await remote.sendUserMessage("running") }
        for _ in 0..<200 {
            if transport.promptHistory.count >= 3 { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertEqual(transport.promptHistory.count, 3)
        let secondItem = try WakeInboxItem(
            id: "held-wake-2", kind: "agent-held", fromAgentId: "bot-b",
            fromAgentName: "Bee", text: "second held message", createdAt: 2_000)
        _ = try await inbox.enqueue(secondItem)
        try await remote.wakeWithHeldMessages()
        XCTAssertEqual(transport.promptHistory.count, 3)
        let pending = try await inbox.items()
        XCTAssertEqual(pending.map(\.id), [secondItem.id])
        XCTAssertEqual(pending.first?.state, .pending)
        transport.resume("gb-main")
        _ = try await running.value
    }

    private func makeParent(_ runtime: BotMCPRuntime, botId: String,
                            sessionId: String) async throws -> BotResolvedToolCall {
        let principal = try await runtime.issueSession(
            botId: botId, sessionId: sessionId, kind: .chat)
        let callId = UUID().uuidString
        let arguments = BotJSONValue.object(["prompt": .string("parent")])
        let attribution = try await runtime.registerIdentity(
            runtimeId: BotMCPRuntime.defaultRuntimeID, sessionId: sessionId,
            callId: callId, name: "Task", arguments: arguments)
        guard let call = BotResolvedToolCall(
            sessionId: sessionId, callId: callId, agentId: botId,
            principal: principal, attribution: attribution) else {
            throw BotMCPError.unauthorized
        }
        return call
    }
}
