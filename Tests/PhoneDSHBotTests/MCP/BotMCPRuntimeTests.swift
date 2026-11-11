// SPDX-License-Identifier: MIT

import Foundation
import XCTest
@testable import PhoneDSHBot

private final class BotRuntimeClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Int64
    init(_ value: Int64) { self.value = value }
    func now() -> Int64 { lock.withLock { value } }
    func advance(_ milliseconds: Int64) { lock.withLock { value += milliseconds } }
}

final class BotMCPRuntimeTests: XCTestCase {
    func testCardMemoryTaskAndRoutineCallsUseClaimedSessionAndSQLite() async throws {
        let fixture = try makeBotMCPFixture(taskExecutor: StubBotTaskExecutor())
        defer { fixture.cleanup() }
        _ = try await fixture.runtime.issueSession(botId: "main", sessionId: "gb-main", kind: .chat)

        let question = try await registerAndExecute(fixture.runtime, name: "ask_user", arguments: .object([
            "question": .string("继续吗？"),
            "options": .array([.object(["label": .string("继续")]), .object(["label": .string("停止")])]),
        ]))
        XCTAssertEqual(question.isError, nil)
        XCTAssertEqual(question.structuredContent?["card"]?["cardType"], .string("question"))

        let running = try await registerAndExecute(fixture.runtime, name: "show_progress", arguments: .object([
            "title": .string("Generate"), "cardKey": .string("job-1"), "state": .string("running"),
        ]))
        let done = try await registerAndExecute(fixture.runtime, name: "show_progress", arguments: .object([
            "title": .string("Generate"), "cardKey": .string("job-1"), "state": .string("done"),
        ]))
        XCTAssertEqual(running.structuredContent?["card"]?["cardKey"], done.structuredContent?["card"]?["cardKey"])

        let memory = try await registerAndExecute(fixture.runtime, name: "UpdateMemory", arguments: .object([
            "action": .string("write"), "path": .string("agent/notes/tone.md"),
            "content": .string("我喜欢简短回答"), "expected_version": .number(0),
        ]))
        XCTAssertEqual(memory.structuredContent?["ok"], .bool(true))
        let recalled = try await registerAndExecute(fixture.runtime, name: "RecallMemory", arguments: .object([
            "query": .string("简短"),
        ]))
        XCTAssertEqual(recalled.structuredContent?["count"], .number(1))

        await beginUserTurn(fixture.runtime)
        let created = try await registerAndExecute(fixture.runtime, name: "UpdateRoutine", arguments: .object([
            "action": .string("create"), "title": .string("Morning"), "prompt": .string("Report once"),
            "schedule": .string("@every 60m"),
        ]))
        await fixture.runtime.endTurn(sessionId: "gb-main")
        XCTAssertNotNil(created.structuredContent?["id"]?.stringValue)
        let routines = try await registerAndExecute(fixture.runtime, name: "ListRoutines")
        XCTAssertEqual(routines.structuredContent?["count"], .number(1))

        let task = try await registerAndExecute(fixture.runtime, name: "Task", arguments: .object([
            "task_title": .string("Investigate"), "task_description": .string("inspect"), "async": .bool(true),
        ]))
        let taskId = try XCTUnwrap(task.structuredContent?["task_id"]?.stringValue)
        XCTAssertEqual(task.structuredContent?["status"], .string("running"))
        let awaited = try await registerAndExecute(fixture.runtime, name: "AwaitTask", arguments: .object([
            "task_id": .string(taskId),
        ]))
        XCTAssertEqual(awaited.structuredContent?["status"], .string("completed"))
        let stopped = try await registerAndExecute(fixture.runtime, name: "StopSubagent", arguments: .object([
            "task_id": .string(taskId),
        ]))
        XCTAssertEqual(stopped.structuredContent?["status"], .string("stopped"))

        await fixture.runtime.beginTurn(sessionId: "gb-main", hidden: false)
        let sent = try await registerAndExecute(fixture.runtime, name: "SendToUser", arguments: .object([
            "message": .string("Done"),
        ]))
        XCTAssertEqual(sent.structuredContent?["ok"], .bool(true))
        let events = try await botEvents(fixture.store)
        XCTAssertTrue(events.contains { $0.type == "card.presented" && $0.data["cardKey"] == .string("job-1") })
        XCTAssertTrue(events.contains { $0.type == "memory.document_written" })
        XCTAssertTrue(events.contains { $0.type == "ui.send_to_user" && $0.data["text"] == .string("Done") })
    }

    func testUnknownP1UnattributedAndCrossSessionCallsFailClosed() async throws {
        let fixture = try makeBotMCPFixture()
        defer { fixture.cleanup() }
        _ = try await fixture.runtime.issueSession(botId: "main", sessionId: "gb-main", kind: .chat)
        let unknown = await fixture.runtime.execute(
            name: "show_table", arguments: .object([:]),
            context: BotMCPRequestContext(callId: "unknown"))
        XCTAssertEqual(unknown.isError, true)
        XCTAssertEqual(unknown.structuredContent?["error"]?["code"], .string("unknown_tool"))
        let unattributed = await fixture.runtime.execute(
            name: "ListRoutines", arguments: .object([:]),
            context: BotMCPRequestContext(callId: "missing"))
        XCTAssertEqual(unattributed.structuredContent?["error"]?["code"], .string("unattributed"))

        do {
            _ = try await fixture.runtime.registerIdentity(
                runtimeId: BotMCPRuntime.defaultRuntimeID, sessionId: "gb-main",
                callId: "volatile-cross", name: "BotVolatileContext",
                arguments: .object(["sessionId": .string("gb-other")]))
            let cross = await fixture.runtime.execute(
                name: "BotVolatileContext", arguments: .object(["sessionId": .string("gb-other")]),
                context: BotMCPRequestContext(callId: "volatile-cross"))
            XCTAssertEqual(cross.structuredContent?["error"]?["code"], .string("cross_session_read_denied"))
        }
    }

    func testApprovalGrantIsConsumedOnlyAtExecution() async throws {
        let fixture = try makeBotMCPFixture()
        defer { fixture.cleanup() }
        _ = try await fixture.runtime.issueSession(botId: "main", sessionId: "gb-main", kind: .chat)
        let args = BotJSONValue.object([
            "action": .string("delete"), "path": .string("user/private.md"),
            "expected_version": .number(0),
        ])
        let callId = "approval-call"
        let digest = try BotArgumentsDigest.string(for: args)
        _ = try await fixture.runtime.registerIdentity(
            runtimeId: BotMCPRuntime.defaultRuntimeID, sessionId: "gb-main",
            callId: callId, name: "UpdateMemory", arguments: args)
        let approvalTask = Task {
            await fixture.runtime.approve(
                runtimeId: BotMCPRuntime.defaultRuntimeID,
                callId: callId, name: "UpdateMemory", action: "Forget shared memory", detail: "test",
                command: "", argsDigest: digest, alwaysScope: "until", askAction: "tool-call")
        }
        var approvalId: String?
        for _ in 0..<100 {
            let ids = await fixture.runtime.approvals.pendingIDs
            if let first = ids.first { approvalId = first; break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        let id = try XCTUnwrap(approvalId)
        let resolved = await fixture.runtime.approvals.resolve(
            approvalId: id, decision: .allowOnce, digest: digest)
        XCTAssertEqual(resolved, .resolved)
        let outcome = await approvalTask.value
        XCTAssertTrue(outcome.allowed)
        let executed = await fixture.runtime.execute(
            name: "UpdateMemory", arguments: args, context: BotMCPRequestContext(callId: callId))
        XCTAssertNotEqual(executed.isError, true)
        let events = try await botEvents(fixture.store)
        XCTAssertTrue(events.contains { $0.type == "approval.requested" })
        XCTAssertTrue(events.contains { $0.type == "approval.decided" })
        XCTAssertTrue(events.contains { $0.type == "grant.consumed" })
    }

    func testRoutineAndTaskSessionsCannotSendToUser() async throws {
        let fixture = try makeBotMCPFixture()
        defer { fixture.cleanup() }
        _ = try await fixture.runtime.issueSession(botId: "main", sessionId: "gb-routine", kind: .routine)
        let result = try await registerAndExecute(
            fixture.runtime, name: "SendToUser", arguments: .object(["message": .string("hidden")]),
            sessionId: "gb-routine")
        XCTAssertEqual(result.isError, true)
    }

    func testApprovalRejectsStaleDigestAndIgnoresSuppliedUnclassifiedEffects() async throws {
        let fixture = try makeBotMCPFixture()
        defer { fixture.cleanup() }
        _ = try await fixture.runtime.issueSession(botId: "main", sessionId: "gb-main", kind: .chat)
        let args = BotJSONValue.object([
            "action": .string("delete"), "path": .string("user/private.md"),
            "expected_version": .number(0),
        ])
        let digest = try BotArgumentsDigest.string(for: args)
        let callId = "digest-approval"
        _ = try await fixture.runtime.registerIdentity(
            runtimeId: BotMCPRuntime.defaultRuntimeID, sessionId: "gb-main",
            callId: callId, name: "mcp__phone__UpdateMemory", arguments: args)
        let wrong = await fixture.runtime.approve(
            runtimeId: BotMCPRuntime.defaultRuntimeID, callId: callId,
            name: "mcp__phone__UpdateMemory", action: "Forget", detail: "test", command: "",
            argsDigest: String(repeating: "0", count: 64), alwaysScope: "until", askAction: "tool-call")
        XCTAssertEqual(wrong.message, "stale:digest_mismatch")
        let approvalTask = Task {
            await fixture.runtime.approve(
                runtimeId: BotMCPRuntime.defaultRuntimeID, callId: callId,
                name: "mcp__phone__UpdateMemory", action: "Forget", detail: "test", command: "",
                argsDigest: digest, alwaysScope: "until", askAction: "tool-call",
                suppliedEffects: [BotToolEffect(
                    tool: "untrusted", operation: "tool.unclassified", resource: "safe",
                    mutability: .read, policy: .auto, known: false)])
        }
        var approvalId: String?
        for _ in 0..<100 {
            if let first = await fixture.runtime.approvals.pendingIDs.first { approvalId = first; break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        let id = try XCTUnwrap(approvalId)
        let requested = try await botEvents(fixture.store).first { $0.type == "approval.requested" }
        XCTAssertEqual(requested?.data["digest"], .string(digest))
        XCTAssertEqual(requested?.data["alwaysScope"], .string("until"))
        XCTAssertEqual(requested?.data["effects"]?.arrayValue?.first?["operation"], .string("memory.forget"))
        let stale = await fixture.runtime.approvals.resolve(
            approvalId: id, decision: .allowOnce, digest: String(repeating: "1", count: 64))
        XCTAssertEqual(stale, .stale(reason: "digest_mismatch"))
        let remainingApprovals = await fixture.runtime.approvals.pendingIDs
        XCTAssertEqual(remainingApprovals, [id])
        let resolved = await fixture.runtime.approvals.resolve(
            approvalId: id, decision: .allowOnce, digest: digest)
        XCTAssertEqual(resolved, .resolved)
        let outcome = await approvalTask.value
        XCTAssertTrue(outcome.allowed)
        let executed = await fixture.runtime.execute(
            name: "UpdateMemory", arguments: args, context: BotMCPRequestContext(callId: callId))
        XCTAssertNotEqual(executed.isError, true)
    }

    func testIdentityAndApprovalUseSessionScopedCallIDs() async throws {
        let fixture = try makeBotMCPFixture()
        defer { fixture.cleanup() }
        _ = try await fixture.runtime.issueSession(botId: "main", sessionId: "parent", kind: .chat)
        _ = try await fixture.runtime.issueSession(botId: "main", sessionId: "child", kind: .task)
        let arguments: BotJSONValue = .object(["task_title": .string("same"), "prompt": .string("same")])
        let first = try await fixture.runtime.registerIdentity(
            runtimeId: BotMCPRuntime.defaultRuntimeID, sessionId: "parent",
            callId: "shared", name: "mcp__phone__Task", arguments: arguments)
        let second = try await fixture.runtime.registerIdentity(
            runtimeId: BotMCPRuntime.defaultRuntimeID, sessionId: "child",
            callId: "shared", name: "mcp__phone__Task", arguments: arguments)
        XCTAssertNotEqual(first.id, second.id)
        let parent = await fixture.runtime.identityForApproval(
            runtimeId: BotMCPRuntime.defaultRuntimeID, sessionId: "parent", callId: "shared")
        let child = await fixture.runtime.identityForApproval(
            runtimeId: BotMCPRuntime.defaultRuntimeID, sessionId: "child", callId: "shared")
        let ambiguous = await fixture.runtime.identityForApproval(
            runtimeId: BotMCPRuntime.defaultRuntimeID, callId: "shared")
        XCTAssertEqual(parent?.sessionId, "parent")
        XCTAssertEqual(child?.sessionId, "child")
        XCTAssertNil(ambiguous)
        let digest = try BotArgumentsDigest.string(for: arguments)
        let outcome = await fixture.runtime.approve(
            runtimeId: BotMCPRuntime.defaultRuntimeID, sessionId: "child", callId: "shared",
            name: "mcp__phone__Task", action: "Delegate", detail: "test", command: "",
            argsDigest: digest, alwaysScope: "until", askAction: "tool-call")
        XCTAssertTrue(outcome.allowed)
        let handler = BotMCPHandler(runtime: fixture.runtime)
        let missingSession = await handler.approval(.object([
            "callId": .string("shared"), "tool": .string("mcp__phone__Task"),
            "argsDigest": .string(digest), "alwaysScope": .string("until"),
        ]))
        XCTAssertEqual(missingSession["ok"], .bool(false))
    }

    func testApprovalTimeoutAndWebContentLossDenyWithoutGrant() async throws {
        let fixture = try makeBotMCPFixture()
        defer { fixture.cleanup() }
        _ = try await fixture.runtime.issueSession(botId: "main", sessionId: "gb-main", kind: .chat)
        let args = BotJSONValue.object([
            "action": .string("delete"), "path": .string("user/private.md"),
            "expected_version": .number(0),
        ])
        _ = try await fixture.runtime.registerIdentity(
            runtimeId: BotMCPRuntime.defaultRuntimeID, sessionId: "gb-main",
            callId: "timeout-call", name: "UpdateMemory", arguments: args)
        let resolvedCall = await fixture.runtime.identityForApproval(
            runtimeId: BotMCPRuntime.defaultRuntimeID, callId: "timeout-call")
        let call = try XCTUnwrap(resolvedCall)
        let coordinator = await BotApprovalCoordinator(
            grants: fixture.runtime.grants, eventWriter: fixture.runtime.eventWriter,
            now: { 1_000 }, approvalTimeoutMs: 10)
        let effect = BotToolEffectClassifier.effect(for: "UpdateMemory", arguments: args)
        let timedOut = await coordinator.request(
            call: call, effects: [effect], action: "Forget", detail: "test",
            command: "", alwaysScope: "until")
        XCTAssertFalse(timedOut.allowed)
        XCTAssertEqual(timedOut.message, "approval timed out")
        let cancelled = Task {
            await coordinator.request(
                call: call, effects: [effect], action: "Forget", detail: "test",
                command: "", alwaysScope: "until")
        }
        for _ in 0..<100 {
            let ids = await coordinator.pendingIDs
            if !ids.isEmpty { break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        await coordinator.cancelAll()
        let lost = await cancelled.value
        XCTAssertFalse(lost.allowed)
        XCTAssertEqual(lost.message, "approval unavailable")
        let remaining = await coordinator.pendingIDs
        XCTAssertTrue(remaining.isEmpty)
        let grants = await fixture.runtime.grants.list(botId: "main")
        XCTAssertFalse(grants.contains { $0.decision == .allow })
    }

    func testWorkerRestartInvalidatesRegistrationsAndApprovals() async throws {
        let fixture = try makeBotMCPFixture()
        defer { fixture.cleanup() }
        _ = try await fixture.runtime.issueSession(botId: "main", sessionId: "gb-main", kind: .chat)
        let args = BotJSONValue.object([
            "action": .string("delete"), "path": .string("user/private.md"),
            "expected_version": .number(0),
        ])
        let digest = try BotArgumentsDigest.string(for: args)
        _ = try await fixture.runtime.registerIdentity(
            runtimeId: BotMCPRuntime.defaultRuntimeID, sessionId: "gb-main",
            callId: "old-call", name: "UpdateMemory", arguments: args)
        let pending = Task {
            await fixture.runtime.approve(
                runtimeId: BotMCPRuntime.defaultRuntimeID, callId: "old-call",
                name: "UpdateMemory", action: "Forget", detail: "test", command: "",
                argsDigest: digest, alwaysScope: "until", askAction: "tool-call")
        }
        var approvalId: String?
        for _ in 0..<100 {
            if let first = await fixture.runtime.approvals.pendingIDs.first { approvalId = first; break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        _ = try XCTUnwrap(approvalId)
        _ = await fixture.runtime.workerRestarted()
        let outcome = await pending.value
        XCTAssertFalse(outcome.allowed)
        let staleApproval = await fixture.runtime.approve(
            runtimeId: BotMCPRuntime.defaultRuntimeID, callId: "old-call",
            name: "UpdateMemory", action: "Forget", detail: "test", command: "",
            argsDigest: digest, alwaysScope: "until", askAction: "tool-call")
        XCTAssertEqual(staleApproval.message, "unattributed")
        let staleExecution = await fixture.runtime.execute(
            name: "UpdateMemory", arguments: args,
            context: BotMCPRequestContext(callId: "old-call"))
        XCTAssertEqual(staleExecution.structuredContent?["error"]?["code"], .string("unattributed"))
        let events = try await botEvents(fixture.store)
        XCTAssertTrue(events.contains { $0.type == "approval.decided" && $0.data["status"] == .string("cancelled") })
        XCTAssertTrue(events.contains { $0.type == "ui.notice" && $0.data["kind"] == .string("approval_cancelled") })

        // The new generation accepts a fresh registration and claims it.
        let freshArgs = BotJSONValue.object([:])
        _ = try await fixture.runtime.registerIdentity(
            runtimeId: BotMCPRuntime.defaultRuntimeID, sessionId: "gb-main",
            callId: "new-call", name: "ListRoutines", arguments: freshArgs)
        let fresh = await fixture.runtime.execute(
            name: "ListRoutines", arguments: freshArgs,
            context: BotMCPRequestContext(callId: "new-call"))
        XCTAssertNotEqual(fresh.isError, true, String(describing: fresh.structuredContent))
    }

    func testExpiredRegistrationCannotApproveAndIsPruned() async throws {
        XCTAssertGreaterThanOrEqual(BotAttributionRegistry.defaultTTLMilliseconds,
                                    BotApprovalCoordinator.defaultTimeoutMilliseconds)
        let clock = BotRuntimeClock(1_000)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SQLiteDomainStore(fileURL: directory.appendingPathComponent("domain.sqlite"),
                                          now: { clock.now() })
        let runtime = BotMCPRuntime(store: store, now: { clock.now() })
        _ = try await runtime.issueSession(botId: "main", sessionId: "gb-main", kind: .chat)
        let args = BotJSONValue.object(["query": .string("x")])
        _ = try await runtime.registerIdentity(
            runtimeId: BotMCPRuntime.defaultRuntimeID, sessionId: "gb-main",
            callId: "expiring", name: "RecallMemory", arguments: args)
        let live = await runtime.identityForApproval(
            runtimeId: BotMCPRuntime.defaultRuntimeID, callId: "expiring")
        XCTAssertNotNil(live)
        clock.advance(BotAttributionRegistry.defaultTTLMilliseconds + 1)
        let expired = await runtime.identityForApproval(
            runtimeId: BotMCPRuntime.defaultRuntimeID, callId: "expiring")
        XCTAssertNil(expired)
        let stale = await runtime.approve(
            runtimeId: BotMCPRuntime.defaultRuntimeID, callId: "expiring",
            name: "RecallMemory", action: "Read", detail: "test", command: "",
            argsDigest: try BotArgumentsDigest.string(for: args),
            alwaysScope: "until", askAction: "tool-call")
        XCTAssertEqual(stale.message, "unattributed")
    }

    func testMemoryWriteUsesResolvedPrincipalAndCurrentTurn() async throws {
        let fixture = try makeBotMCPFixture()
        defer { fixture.cleanup() }
        _ = try await fixture.runtime.issueSession(botId: "main", sessionId: "gb-main", kind: .chat)
        await fixture.runtime.beginTurn(
            sessionId: "gb-main", hidden: false,
            origin: BotTurnOrigin(rpcId: "user-action:memory-turn"))
        await fixture.runtime.updateTurn(sessionId: "gb-main", turnId: "42")
        let evidence = BotJSONValue.array([.string("record://session/gb-main#1")])
        let first = try await registerAndExecute(fixture.runtime, name: "UpdateMemory", arguments: .object([
            "action": .string("write"), "path": .string("user/profile.md"),
            "content": .string("likes concise replies"), "expected_version": .number(0),
            "evidence": evidence,
        ]))
        XCTAssertEqual(first.structuredContent?["ok"], .bool(true), String(describing: first.structuredContent))
        let second = try await registerAndExecute(fixture.runtime, name: "UpdateMemory", arguments: .object([
            "action": .string("write"), "path": .string("user/preferences/tone.md"),
            "content": .string("prefers short summaries"), "expected_version": .number(0),
            "evidence": evidence,
        ]))
        XCTAssertEqual(second.structuredContent?["ok"], .bool(true), String(describing: second.structuredContent))
        let memory = await fixture.runtime.memory(for: "main")
        let documents = try await memory.documents(scope: .user)
        XCTAssertEqual(documents.filter { !$0.path.hasSuffix("INDEX.md") }.count, 2)
        let profile = try XCTUnwrap(documents.first { $0.path == "user/profile.md" })
        XCTAssertEqual(profile.trust, "user")
        XCTAssertEqual(profile.source?.sessionID, "gb-main")
        XCTAssertEqual(profile.source?.turnID, "42")
        XCTAssertEqual(profile.source?.kind, .userTurn)
        XCTAssertEqual(profile.evidence, ["record://session/gb-main#1"])
    }


    func testCardAnswerTurnWritesSharedMemoryAsUserTurn() async throws {
        let fixture = try makeBotMCPFixture()
        defer { fixture.cleanup() }
        _ = try await fixture.runtime.issueSession(botId: "main", sessionId: "gb-main", kind: .chat)
        await fixture.runtime.beginTurn(
            sessionId: "gb-main", hidden: false,
            origin: BotTurnOrigin(rpcId: BotTurnOrigin.cardAnswerRequestId(nonce: "answer-1")))
        await fixture.runtime.updateTurn(sessionId: "gb-main", turnId: "43")
        let evidence = BotJSONValue.array([.string("record://session/gb-main#1")])
        let shared = try await registerAndExecute(fixture.runtime, name: "UpdateMemory", arguments: .object([
            "action": .string("write"), "path": .string("user/notes/card.md"),
            "content": .string("card answer user fact"), "expected_version": .number(0),
            "evidence": evidence,
        ]))
        XCTAssertEqual(shared.structuredContent?["ok"], .bool(true),
                       String(describing: shared.structuredContent))
        let profile = try await registerAndExecute(fixture.runtime, name: "UpdateMemory", arguments: .object([
            "action": .string("write"), "path": .string("user/profile.md"),
            "content": .string("card answer profile fact"), "expected_version": .number(0),
            "evidence": evidence,
        ]))
        XCTAssertEqual(profile.structuredContent?["ok"], .bool(true),
                       String(describing: profile.structuredContent))

        let memory = await fixture.runtime.memory(for: "main")
        let documents = try await memory.documents(scope: .user)
            .filter { !$0.path.hasSuffix("INDEX.md") }
        XCTAssertEqual(Set(documents.map(\.content)),
                       ["card answer user fact", "card answer profile fact"])
        XCTAssertTrue(documents.allSatisfy { $0.source?.kind == .userTurn })
        XCTAssertTrue(documents.allSatisfy { $0.source?.turnID == "43" })
    }


    func testTurnWithoutRegisteredOriginCannotWriteSharedMemory() async throws {
        let fixture = try makeBotMCPFixture()
        defer { fixture.cleanup() }
        _ = try await fixture.runtime.issueSession(botId: "main", sessionId: "gb-main", kind: .chat)
        await fixture.runtime.beginTurn(sessionId: "gb-main", hidden: false)
        let shared = try await registerAndExecute(fixture.runtime, name: "UpdateMemory", arguments: .object([
            "action": .string("write"), "path": .string("user/notes/no-origin.md"),
            "content": .string("no origin claim"), "expected_version": .number(0),
        ]))
        XCTAssertEqual(shared.structuredContent?["ok"], .bool(false))
        XCTAssertEqual(shared.structuredContent?["code"], .string("memory-source-boundary"))

        let own = try await registerAndExecute(fixture.runtime, name: "UpdateMemory", arguments: .object([
            "action": .string("write"), "path": .string("agent/notes/no-origin.md"),
            "content": .string("no origin private"), "expected_version": .number(0),
        ]))
        XCTAssertEqual(own.structuredContent?["ok"], .bool(true))
        let memory = await fixture.runtime.memory(for: "main")
        let documents = try await memory.documents(scope: .agent)
        let privateNote = try XCTUnwrap(documents.first { $0.path == "agent/notes/no-origin.md" })
        XCTAssertEqual(privateNote.source?.kind, .agentMessage)
        let userNotes = try await memory.documents(scope: .user)
            .filter { !$0.path.hasSuffix("INDEX.md") }
        XCTAssertTrue(userNotes.isEmpty)
    }


    func testAgentTurnCannotWriteSharedMemoryButCanWriteItsOwnAgentScope() async throws {
        let fixture = try makeBotMCPFixture()
        defer { fixture.cleanup() }
        let transport = BotScriptedRemoteTransport(scripts: [
            "gb-main": [[.turn(), .assistant("agent reply"), .end()]],
        ])
        transport.pause("gb-main")
        defer { transport.resume("gb-main") }
        let remote = try await BotDSHRemoteRuntime(transport: transport, runtime: fixture.runtime)
        let running = Task {
            try await remote.sendAgentMessage("hello", requestId: "agent:call_1")
        }
        for _ in 0..<200 where transport.promptRequestIds.isEmpty {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        let prompt = try XCTUnwrap(transport.promptRequestIds.first)
        XCTAssertEqual(prompt.requestId, "agent:call_1")
        XCTAssertEqual(prompt.mode, "queue")

        let shared = try await registerAndExecute(fixture.runtime, name: "UpdateMemory", arguments: .object([
            "action": .string("write"), "path": .string("user/notes/agent-claim.md"),
            "content": .string("agent claims user trust"), "expected_version": .number(0),
        ]))
        XCTAssertEqual(shared.structuredContent?["ok"], .bool(false))
        XCTAssertEqual(shared.structuredContent?["code"], .string("memory-source-boundary"))

        let own = try await registerAndExecute(fixture.runtime, name: "UpdateMemory", arguments: .object([
            "action": .string("write"), "path": .string("agent/notes/agent-private.md"),
            "content": .string("agent private note"), "expected_version": .number(0),
        ]))
        XCTAssertEqual(own.structuredContent?["ok"], .bool(true))

        transport.resume("gb-main")
        let result = try await running.value
        XCTAssertEqual(result.status, "completed")
        let memory = await fixture.runtime.memory(for: "main")
        let agentDocuments = try await memory.documents(scope: .agent)
        let note = try XCTUnwrap(agentDocuments.first { $0.path == "agent/notes/agent-private.md" })
        XCTAssertEqual(note.source?.kind, .agentMessage)
        let userNotes = try await memory.documents(scope: .user)
            .filter { !$0.path.hasSuffix("INDEX.md") }
        XCTAssertTrue(userNotes.isEmpty)
    }


    func testUnknownTurnOriginCannotWriteSharedMemory() async throws {
        let fixture = try makeBotMCPFixture()
        defer { fixture.cleanup() }
        _ = try await fixture.runtime.issueSession(botId: "main", sessionId: "gb-main", kind: .chat)
        await fixture.runtime.beginTurn(
            sessionId: "gb-main", hidden: false,
            origin: BotTurnOrigin(rpcId: "call_01J8Z9K3Q4W5X6Y7Z8A9B0C1D2"))
        let result = try await registerAndExecute(fixture.runtime, name: "UpdateMemory", arguments: .object([
            "action": .string("write"), "path": .string("user/notes/legacy.md"),
            "content": .string("legacy claim"), "expected_version": .number(0),
        ]))
        XCTAssertEqual(result.structuredContent?["ok"], .bool(false))
        let own = try await registerAndExecute(fixture.runtime, name: "UpdateMemory", arguments: .object([
            "action": .string("write"), "path": .string("agent/notes/legacy.md"),
            "content": .string("legacy private"), "expected_version": .number(0),
        ]))
        XCTAssertEqual(own.structuredContent?["ok"], .bool(true))
        let memory = await fixture.runtime.memory(for: "main")
        let documents = try await memory.documents(scope: .agent)
        let note = try XCTUnwrap(documents.first { $0.path == "agent/notes/legacy.md" })
        XCTAssertEqual(note.source?.kind, .agentMessage)
    }


    func testRemoteExecutorDrivesTaskAndAwaitThroughProductionToolSurface() async throws {
        let fixture = try makeBotMCPFixture()
        defer { fixture.cleanup() }
        let transport = BotScriptedRemoteTransport(scripts: [
            "gb-main": [[.turn(), .assistant("parent"), .end()]],
        ])
        let remote = try await BotDSHRemoteRuntime(transport: transport, runtime: fixture.runtime)
        _ = try await remote.sendUserMessage("parent")
        transport.pause("gb-created-1")
        transport.queue(sessionId: "gb-created-1", events: [.turn(), .assistant("done"), .end()])
        let started = try await registerAndExecute(fixture.runtime, name: "Task", arguments: .object([
            "task_title": .string("Investigate"), "prompt": .string("inspect"), "async": .bool(true),
        ]))
        let id = try XCTUnwrap(started.structuredContent?["task_id"]?.stringValue)
        XCTAssertEqual(started.structuredContent?["sessionId"], .string("gb-created-1"))
        transport.resume("gb-created-1")
        let completed = try await registerAndExecute(fixture.runtime, name: "AwaitTask", arguments: .object([
            "task_id": .string(id), "timeout_ms": .number(1_000),
        ]))
        XCTAssertEqual(completed.structuredContent?["status"], .string("completed"), String(describing: completed.structuredContent))
        XCTAssertEqual(completed.structuredContent?["result"], .string("done"), String(describing: completed.structuredContent))
        let routines = try await fixture.runtime.routineMachine.list(botId: "main")
        XCTAssertTrue(routines.isEmpty)
    }

    func testRoutineUsesSQLiteStore() async throws {
        let fixture = try makeBotMCPFixture()
        defer { fixture.cleanup() }
        _ = try await fixture.runtime.issueSession(botId: "main", sessionId: "gb-main", kind: .chat)
        await beginUserTurn(fixture.runtime)
        _ = try await registerAndExecute(fixture.runtime, name: "UpdateRoutine", arguments: .object([
            "action": .string("create"), "title": .string("Morning"),
            "prompt": .string("Report"), "schedule": .string("@every 60m"),
        ]))
        await fixture.runtime.endTurn(sessionId: "gb-main")
        let recovered = RoutineMachine(store: SQLiteRoutineStore(domainStore: fixture.store))
        let routines = try await recovered.list(botId: "main")
        XCTAssertEqual(routines.map(\.title), ["Morning"])
    }

    func testSandboxEscalationUsesDedicatedEffectAndConsumesOnce() async throws {
        let fixture = try makeBotMCPFixture()
        defer { fixture.cleanup() }
        _ = try await fixture.runtime.issueSession(botId: "main", sessionId: "gb-main", kind: .chat)
        let args = BotJSONValue.object(["command": .string("printf safe")])
        let digest = try BotArgumentsDigest.string(for: args)
        _ = try await fixture.runtime.registerIdentity(
            runtimeId: BotMCPRuntime.defaultRuntimeID, sessionId: "gb-main",
            callId: "sandbox-approval", name: "bash", arguments: args)
        let effect = BotToolEffect(
            tool: "bash", operation: "sandbox-escalation", resource: "escalate sandbox to danger-full-access: artifact",
            mutability: .write, policy: .ask)
        let approvalTask = Task {
            await fixture.runtime.approve(
                runtimeId: BotMCPRuntime.defaultRuntimeID, callId: "sandbox-approval",
                name: "bash", action: "Escalate sandbox", detail: "artifact", command: "printf safe",
                argsDigest: digest, alwaysScope: "none", askAction: "sandbox-escalation",
                suppliedEffects: [effect])
        }
        var approvalId: String?
        for _ in 0..<100 {
            if let first = await fixture.runtime.approvals.pendingIDs.first { approvalId = first; break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        let id = try XCTUnwrap(approvalId)
        let requested = try await botEvents(fixture.store).first { $0.type == "approval.requested" }
        XCTAssertEqual(requested?.data["alwaysScope"], .string("none"))
        XCTAssertEqual(requested?.data["effects"]?.arrayValue?.first?["operation"], .string("sandbox-escalation"))
        _ = await fixture.runtime.approvals.resolve(approvalId: id, decision: .allowOnce, digest: digest)
        let outcome = await approvalTask.value
        XCTAssertTrue(outcome.allowed)
        let events = try await botEvents(fixture.store)
        XCTAssertTrue(events.contains { $0.type == "grant.consumed" })
    }
}
