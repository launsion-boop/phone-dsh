// SPDX-License-Identifier: MIT

import XCTest
@testable import PhoneDSHBot

final class BotDSHRemoteRuntimeTests: XCTestCase {
    func testRealTurnWritesEveryUsageFieldToSQLiteLedger() async throws {
        let fixture = try makeBotMCPFixture()
        defer { fixture.cleanup() }
        let transport = BotScriptedRemoteTransport(scripts: [
            "gb-main": [[
                .turn(), .delta("hello"), .assistant("hello"), .end(),
            ]],
        ])
        let remote = try await BotDSHRemoteRuntime(transport: transport, runtime: fixture.runtime)
        let result = try await remote.sendUserMessage("hello")
        XCTAssertEqual(result.status, "completed")
        XCTAssertEqual(result.text, "hello")
        let prompt = try XCTUnwrap(transport.prompts["gb-main"])
        XCTAssertEqual(prompt.mode, "queue")
        let records = try await BotLLMLedger(eventLog: fixture.store).records()
        XCTAssertEqual(records.count, 1)
        let record = try XCTUnwrap(records.first)
        XCTAssertEqual(record.purpose, .frontTurn)
        XCTAssertEqual(record.inputTokens, 10)
        XCTAssertEqual(record.outputTokens, 5)
        XCTAssertEqual(record.cacheReadTokens, 4)
        XCTAssertEqual(record.cacheWriteTokens, 2)
        XCTAssertEqual(record.ttftMs, 5)
        XCTAssertEqual(record.durationMs, 10)
        XCTAssertEqual(record.cacheHitRatio, 4.0 / 16.0, accuracy: 1e-12)
        let events = try await botEvents(fixture.store)
        XCTAssertTrue(events.contains { $0.type == "conversation.assistant_message" && $0.data["text"] == .string("hello") })
        XCTAssertTrue(events.contains { $0.type == "ledger.usage_recorded" })
        XCTAssertTrue(events.contains { $0.eventId.contains("dsh:gb-main:3:conversation.assistant_message") })
    }

    func testBotSessionsAreNamespacedAndClaimedBeforeTurns() async throws {
        let fixture = try makeBotMCPFixture()
        defer { fixture.cleanup() }
        let transport = BotScriptedRemoteTransport(scripts: [
            "gb-main": [[.turn(), .assistant("main"), .end()]],
            "gb-created-1": [[.turn(), .assistant("task"), .end()]],
        ])
        let remote = try await BotDSHRemoteRuntime(transport: transport, runtime: fixture.runtime)
        let main = try await remote.sendUserMessage("hello")
        XCTAssertEqual(main.sessionId, "gb-main")
        XCTAssertEqual(transport.requestedSessionIds, ["gb-main"])
        XCTAssertEqual(transport.claimedSessions, ["gb-main"])

        let parent = try await makeParent(fixture.runtime)
        let task = try await remote.start(request: BotTaskRequest(
            parent: parent, title: "Namespaced task", prompt: "inspect",
            asynchronous: false, timeoutMs: 1_000))
        XCTAssertEqual(task.status, "completed")
        XCTAssertEqual(transport.requestedSessionIds.count, 2)
        XCTAssertTrue(transport.requestedSessionIds[1].hasPrefix("gb-task-"),
                      "task session must use the Bot namespace: \(transport.requestedSessionIds[1])")
        XCTAssertTrue(transport.claimedSessions.contains(task.sessionId),
                      "the created task session must be claimed before its turn")
    }

    func testSecondMessageSteersTheOnlyCollectorAndNextTurnGetsANewAttempt() async throws {
        let fixture = try makeBotMCPFixture()
        defer { fixture.cleanup() }
        let transport = BotScriptedRemoteTransport(scripts: [
            "gb-main": [[.turn(), .assistant("combined"), .end()]],
        ])
        transport.pause("gb-main")
        let remote = try await BotDSHRemoteRuntime(transport: transport, runtime: fixture.runtime)
        let first = Task { try await remote.sendUserMessage("first") }
        try await waitUntil { transport.promptHistory.count == 1 }
        let second = Task { try await remote.sendUserMessage("second") }
        try await waitUntil { transport.promptHistory.count == 2 }
        XCTAssertEqual(transport.openMuxCount, 1)
        XCTAssertEqual(transport.promptHistory.map(\.mode), ["queue", "steer"])
        transport.resume("gb-main")
        let results = try await [first.value, second.value]
        XCTAssertEqual(results.map(\.text), ["combined", "combined"])
        XCTAssertEqual(results.map(\.turnId), ["1", "1"])
        transport.queue(sessionId: "gb-main", events: [.turn(2), .assistant("third result"), .end(turn: 2)])
        let third = try await remote.sendUserMessage("third")
        XCTAssertEqual(third.text, "third result")
        XCTAssertEqual(transport.openMuxCount, 2)
        XCTAssertEqual(transport.promptHistory.last?.mode, "queue")
    }

    func testMainSessionRecoversFromSQLiteAndFailedPageCreatesOnce() async throws {
        let fixture = try makeBotMCPFixture()
        defer { fixture.cleanup() }
        let firstTransport = BotScriptedRemoteTransport(scripts: [
            "gb-main": [[.turn(), .assistant("first"), .end()]],
        ])
        let first = try await BotDSHRemoteRuntime(transport: firstTransport, runtime: fixture.runtime)
        _ = try await first.sendUserMessage("first")
        XCTAssertEqual(firstTransport.claimedSessions, ["gb-main"])

        let resumedTransport = BotScriptedRemoteTransport(mainId: "gb-new", scripts: [
            "gb-main": [[.turn(2), .assistant("resumed"), .end(turn: 2)]],
        ])
        let resumed = try await BotDSHRemoteRuntime(transport: resumedTransport, runtime: fixture.runtime)
        let resumedResult = try await resumed.sendUserMessage("resume")
        XCTAssertEqual(resumedResult.sessionId, "gb-main")
        XCTAssertEqual(resumedResult.text, "resumed")
        XCTAssertEqual(resumedTransport.createCount, 0)
        XCTAssertEqual(resumedTransport.claimedSessions, ["gb-main"],
                       "a legacy/recovered main session id must be claimed explicitly")
        let recoveredID = await resumed.mainSessionId
        XCTAssertEqual(recoveredID, "gb-main")

        let replacementTransport = BotScriptedRemoteTransport(mainId: "gb-new", scripts: [
            "gb-new": [[.turn(), .assistant("replacement"), .end()]],
        ])
        replacementTransport.failPage("gb-main")
        let replacement = try await BotDSHRemoteRuntime(transport: replacementTransport, runtime: fixture.runtime)
        let replaced = try await replacement.sendUserMessage("replace")
        XCTAssertEqual(replaced.sessionId, "gb-new")
        XCTAssertEqual(replaced.text, "replacement")
        XCTAssertEqual(replacementTransport.createCount, 1)
        XCTAssertEqual(replacementTransport.claimedSessions, ["gb-new"])
    }

    func testAttachTransportRevalidatesThePersistedMainSession() async throws {
        let fixture = try makeBotMCPFixture()
        defer { fixture.cleanup() }
        let firstTransport = BotScriptedRemoteTransport(scripts: [
            "gb-main": [[.turn(), .assistant("first"), .end()]],
        ])
        let remote = try await BotDSHRemoteRuntime(transport: firstTransport, runtime: fixture.runtime)
        _ = try await remote.sendUserMessage("first")
        let replacement = BotScriptedRemoteTransport(scripts: [
            "gb-main": [[.turn(2), .assistant("resumed"), .end(turn: 2)]],
        ])
        await remote.attachTransport(replacement)
        let pending = await remote.mainSessionIdentifier()
        XCTAssertNil(pending)
        let recovered = try await remote.startMainSession()
        XCTAssertEqual(recovered, "gb-main")
        XCTAssertEqual(replacement.createCount, 0)
        let result = try await remote.sendUserMessage("resumed")
        XCTAssertEqual(result.text, "resumed")
    }

    func testMainRecoveryWaitsForTheColdSessionBeforeCreatingAnother() async throws {
        let fixture = try makeBotMCPFixture()
        defer { fixture.cleanup() }
        let firstTransport = BotScriptedRemoteTransport(scripts: [
            "gb-main": [[.turn(), .assistant("first"), .end()]],
        ])
        let remote = try await BotDSHRemoteRuntime(transport: firstTransport, runtime: fixture.runtime)
        _ = try await remote.sendUserMessage("first")
        let replacement = BotScriptedRemoteTransport(scripts: [
            "gb-main": [[.turn(2), .assistant("resumed"), .end(turn: 2)]],
        ])
        replacement.failPage("gb-main", times: 2)
        await remote.attachTransport(replacement)
        let recovered = try await remote.startMainSession()
        XCTAssertEqual(recovered, "gb-main")
        XCTAssertEqual(replacement.createCount, 0)
    }

    func testQuestionSuppressesModelWrapUpAndSendToUser() async throws {
        let fixture = try makeBotMCPFixture()
        defer { fixture.cleanup() }
        _ = try await fixture.runtime.issueSession(botId: "main", sessionId: "gb-main", kind: .chat)
        let transport = BotScriptedRemoteTransport(scripts: [
            "gb-main": [[
                .turn(), .toolCall("mcp__phone__ask_user"), .toolResult(), .assistant("must not escape"), .end(),
            ]],
        ])
        let remote = try await BotDSHRemoteRuntime(transport: transport, runtime: fixture.runtime)
        let result = try await remote.sendUserMessage("choose")
        XCTAssertEqual(result.text, "")
        let sent = try await registerAndExecute(
            fixture.runtime, name: "SendToUser", arguments: .object(["message": .string("must not escape")]))
        XCTAssertEqual(sent.isError, true)
        let events = try await botEvents(fixture.store)
        XCTAssertFalse(events.contains { $0.type == "conversation.assistant_message" && $0.data["text"] == .string("must not escape") })
        XCTAssertTrue(events.contains { $0.eventId.contains("dsh:gb-main:3:conversation.tool_result") })
    }

    func testAsyncTaskUsesCreatedSessionAndWakesParentWithHiddenTurn() async throws {
        let fixture = try makeBotMCPFixture()
        defer { fixture.cleanup() }
        let parent = try await makeParent(fixture.runtime)
        let transport = BotScriptedRemoteTransport(scripts: [
            "gb-main": [
                [.turn(), .assistant("parent"), .end()],
                [.turn(2), .assistant("hidden result must not render"), .end(turn: 2)],
            ],
        ])
        let remote = try await BotDSHRemoteRuntime(transport: transport, runtime: fixture.runtime)
        _ = try await remote.sendUserMessage("parent")
        transport.pause("gb-created-1")
        transport.queue(sessionId: "gb-created-1", events: [.turn(), .assistant("done"), .end()])
        let started = try await remote.start(request: BotTaskRequest(
            parent: parent, title: "Investigate", prompt: "inspect", asynchronous: true, timeoutMs: 1_000))
        XCTAssertEqual(started.status, "running")
        XCTAssertEqual(started.sessionId, "gb-created-1")
        XCTAssertNotEqual(started.sessionId, parent.sessionId)
        let taskId = started.taskId
        let taskSession = started.sessionId
        let waiting = Task { try await remote.await(taskId: taskId, timeoutMs: 1_000, parent: parent) }
        transport.resume(taskSession)
        let settled = try await waiting.value
        XCTAssertEqual(settled.status, "completed")
        let parentPrompt = try XCTUnwrap(transport.prompts["gb-main"])
        XCTAssertTrue(parentPrompt.text.hasPrefix("[SAND_HIDDEN_PROMPT][subagent]"))
        XCTAssertFalse(parentPrompt.text.contains("hidden result must not render"))
        XCTAssertEqual(transport.promptRequestIds.last?.requestId, "task-settled:\(taskId)")
        let records = try await BotLLMLedger(eventLog: fixture.store).records()
        XCTAssertEqual(Set(records.map(\.purpose)), [.frontTurn, .workerTurn])
        let events = try await botEvents(fixture.store)
        XCTAssertTrue(events.contains { $0.type == "task.settled" })
        XCTAssertFalse(events.contains { $0.type == "conversation.assistant_message" && $0.data["text"] == .string("hidden result must not render") })
    }

    func testTaskStopFencesLateCompletionAndParentOwnership() async throws {
        let fixture = try makeBotMCPFixture()
        defer { fixture.cleanup() }
        let parent = try await makeParent(fixture.runtime)
        let transport = BotScriptedRemoteTransport(scripts: [
            "gb-main": [[.turn(), .assistant("parent"), .end()]],
        ])
        let remote = try await BotDSHRemoteRuntime(transport: transport, runtime: fixture.runtime)
        _ = try await remote.sendUserMessage("parent")
        transport.pause("gb-created-1")
        transport.queue(sessionId: "gb-created-1", events: [
            .turn(), .assistant("late completion"), .end(),
        ])
        let started = try await remote.start(request: BotTaskRequest(
            parent: parent, title: "Stop me", prompt: "inspect", asynchronous: true, timeoutMs: 1_000))
        let stopping = Task { try await remote.stop(taskId: started.taskId, parent: parent) }
        try await waitUntil { transport.cancellations == [started.sessionId] }
        transport.resume(started.sessionId)
        let stopped = try await stopping.value
        XCTAssertEqual(stopped.status, "stopped")
        let awaited = try await remote.await(taskId: started.taskId, timeoutMs: 1_000, parent: parent)
        XCTAssertEqual(awaited.status, "stopped")
        XCTAssertNil(awaited.result)
        XCTAssertEqual(transport.promptHistory.filter { $0.sessionId == "gb-main" }.count, 1)
        let events = try await botEvents(fixture.store)
        let settled = events.filter { $0.type == "task.settled" }
        XCTAssertEqual(settled.count, 1)
        XCTAssertEqual(settled.first?.data["status"], .string("stopped"))

        let other = try await makeParent(fixture.runtime, sessionId: "gb-other", callId: "other-parent")
        await assertUnauthorized { try await remote.await(taskId: started.taskId, timeoutMs: 1_000, parent: other) }
        await assertUnauthorized { try await remote.stop(taskId: started.taskId, parent: other) }
        // A reissued incarnation is the same logical conversation after a
        // restart; it may read the terminal record (the status is explicit).
        let nextIncarnation = try await makeParent(fixture.runtime, callId: "next-incarnation")
        let recovered = try await remote.await(taskId: started.taskId, timeoutMs: 1_000, parent: nextIncarnation)
        XCTAssertEqual(recovered.status, "stopped")
    }

    func testCancelOnlyCancelsCurrentSessionTurn() async throws {
        let fixture = try makeBotMCPFixture()
        defer { fixture.cleanup() }
        let transport = BotScriptedRemoteTransport(scripts: [
            "gb-main": [[.turn(), .end("aborted")]],
        ])
        transport.pause("gb-main")
        let remote = try await BotDSHRemoteRuntime(transport: transport, runtime: fixture.runtime)
        let running = Task { try await remote.sendUserMessage("stop") }
        try await waitUntil { transport.openMuxCount == 1 }
        let cancelling = Task { try await remote.cancelMainTurn() }
        try await waitUntil { transport.cancellations == ["gb-main"] }
        transport.resume("gb-main")
        try await cancelling.value
        let result = try await running.value
        XCTAssertEqual(result.status, "cancelled")
        XCTAssertEqual(transport.cancellations, ["gb-main"])
    }

    func testHeldDeliveryRequestIdIsDerivedFromInboxItems() async throws {
        let fixture = try makeBotMCPFixture()
        defer { fixture.cleanup() }
        let transport = BotScriptedRemoteTransport(scripts: [
            "gb-main": [[.turn(), .assistant("held ok"), .end()]],
        ])
        let inbox = WakeInbox(store: SQLiteWakeInboxStore(domainStore: fixture.store, botId: "main"))
        let remote = try await BotDSHRemoteRuntime(transport: transport, runtime: fixture.runtime,
                                                   wakeInbox: inbox, now: { 1_000 })
        _ = try await remote.sendUserMessage("establish")
        _ = try await inbox.enqueue(try WakeInboxItem(
            id: "held-1", kind: "routine-result", text: "held text", createdAt: 1_000))
        transport.queue(sessionId: "gb-main", events: [.turn(2), .assistant("held ok"), .end(turn: 2)])
        _ = try await remote.sendUserMessage("next")
        let expected = try BotArgumentsDigest.string(for: .array([.string("held-1")]))
        XCTAssertEqual(transport.promptRequestIds.last?.requestId, "held:\(expected)")
        XCTAssertTrue(transport.prompts["gb-main"]?.text.contains("held text") == true)
        let remaining = try await inbox.items()
        XCTAssertEqual(remaining.count, 0)

        _ = try await inbox.enqueue(try WakeInboxItem(
            id: "held-2", kind: "routine-result", text: "another result", createdAt: 1_000))
        transport.queue(sessionId: "gb-main", events: [.turn(3), .assistant("held ok"), .end(turn: 3)])
        _ = try await remote.sendUserMessage("another message", requestId: "user-action:nonce-2")
        let digest = try BotArgumentsDigest.string(for: .array([.string("held-2")]))
        let heldRequestID = "held:\(digest)"
        XCTAssertEqual(transport.promptRequestIds.last?.requestId, heldRequestID)
        let live = await remote.heldChatActionNonces(sessionID: "gb-main")
        XCTAssertEqual(live[heldRequestID], "nonce-2")
    }

    func testWorkerRestartInterruptsTaskAndWakesParentOnce() async throws {
        let fixture = try makeBotMCPFixture()
        defer { fixture.cleanup() }
        let parent = try await makeParent(fixture.runtime)
        let transport = BotScriptedRemoteTransport(scripts: [
            "gb-main": [
                [.turn(), .assistant("parent"), .end()],
                [.turn(2), .assistant("woke"), .end(turn: 2)],
            ],
        ])
        let remote = try await BotDSHRemoteRuntime(transport: transport, runtime: fixture.runtime)
        _ = try await remote.sendUserMessage("parent")

        transport.pause("gb-created-1")
        transport.queue(sessionId: "gb-created-1", events: [.turn()])
        let started = try await remote.start(request: BotTaskRequest(
            parent: parent, title: "Interrupt me", prompt: "long work",
            asynchronous: true, timeoutMs: 1_000))
        try await waitUntil { transport.openMuxCount >= 2 }
        await remote.workerRestarted()
        transport.resume("gb-created-1")

        let interrupted = try await remote.await(taskId: started.taskId, timeoutMs: 1_000, parent: parent)
        XCTAssertEqual(interrupted.status, "interrupted")
        XCTAssertEqual(interrupted.error, "worker_restarted")
        let delivered = await remote.deliverInterruptedTaskWakes()
        XCTAssertEqual(delivered, 1)
        XCTAssertEqual(transport.promptRequestIds.last?.requestId, "task-interrupted:\(started.taskId)")
        let second = await remote.deliverInterruptedTaskWakes()
        XCTAssertEqual(second, 0)

        // A new app process restores the same explicit status and does not
        // answer `unauthorized` merely because the principal incarnation moved.
        let restored = try await BotDSHRemoteRuntime(transport: transport, runtime: fixture.runtime)
        let nextParent = try await makeParent(fixture.runtime, callId: "restored-parent")
        let restoredRecord = try await restored.await(taskId: started.taskId, timeoutMs: 1_000, parent: nextParent)
        XCTAssertEqual(restoredRecord.status, "interrupted")
        XCTAssertEqual(restoredRecord.error, "worker_restarted")
        let stopped = try await restored.stop(taskId: started.taskId, parent: nextParent)
        XCTAssertEqual(stopped.status, "interrupted")
    }

    private func makeParent(_ runtime: BotMCPRuntime, sessionId: String = "gb-main",
                            callId: String = UUID().uuidString) async throws -> BotResolvedToolCall {
        let principal = try await runtime.issueSession(botId: "main", sessionId: sessionId, kind: .chat)
        let arguments = BotJSONValue.object(["prompt": .string("parent")])
        let attribution = try await runtime.registerIdentity(
            runtimeId: BotMCPRuntime.defaultRuntimeID, sessionId: sessionId,
            callId: callId, name: "Task", arguments: arguments)
        guard let call = BotResolvedToolCall(
            sessionId: sessionId, callId: callId, agentId: "main",
            principal: principal, attribution: attribution) else {
            throw BotMCPError.unauthorized
        }
        return call
    }

    private func waitUntil(_ condition: @escaping @Sendable () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("condition did not become true")
    }

    private func assertUnauthorized(_ operation: @escaping @Sendable () async throws -> Void) async {
        do {
            try await operation()
            XCTFail("expected cross-parent operation to fail")
        } catch BotMCPError.unauthorized {
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }
    func testChatPromptAppendsTheAttachmentBlockBeforeTheTurn() async throws {
        let fixture = try makeBotMCPFixture()
        defer { fixture.cleanup() }
        let transport = BotScriptedRemoteTransport(scripts: [
            "gb-main": [
                [.turn(), .assistant("first"), .end()],
                [.turn(2), .assistant("second"), .end(turn: 2)],
            ],
        ])
        let remote = try await BotDSHRemoteRuntime(transport: transport, runtime: fixture.runtime)
        let item = BotAttachment(name: "周报.pdf", path: "/dsh/workspace/imports/attachments-att-1/周报.pdf",
                                 size: 2048, mimeType: "application/pdf", kind: "pdf")
        _ = try await remote.sendUserMessage("看看", attachments: [item])
        _ = try await remote.sendUserMessage("", attachments: [item])

        let first = try XCTUnwrap(transport.promptHistory.first?.text)
        XCTAssertTrue(first.hasPrefix("看看\n\n[dshbot-attachments]\n"))
        XCTAssertTrue(first.contains("- {\"name\":\"周报.pdf\",\"path\":\"/dsh/workspace/imports/attachments-att-1/周报.pdf\",\"size\":2048,\"mimeType\":\"application/pdf\",\"kind\":\"pdf\"}"))
        XCTAssertTrue(first.hasSuffix("\n[/dshbot-attachments]"))
        let second = try XCTUnwrap(transport.promptHistory.last?.text)
        XCTAssertTrue(second.hasPrefix("[dshbot-attachments]\n"),
                      "an attachment-only prompt must not start with blank lines: \(second)")
    }

    func testEnsureMainSessionIDCreatesAndReusesTheMainSession() async throws {
        let fixture = try makeBotMCPFixture()
        defer { fixture.cleanup() }
        let transport = BotScriptedRemoteTransport(scripts: ["gb-main": []])
        let remote = try await BotDSHRemoteRuntime(transport: transport, runtime: fixture.runtime)
        let first = try await remote.ensureMainSessionID()
        let second = try await remote.ensureMainSessionID()
        XCTAssertEqual(first, "gb-main")
        XCTAssertEqual(second, first)
        XCTAssertEqual(transport.createCount, 1)
        let current = await remote.mainSessionId
        XCTAssertEqual(current, first)
    }


    func testLegacyMainSessionAtOldCwdIsArchivedAndRebuiltUnderTheBotRoot() async throws {
        let fixture = try makeBotMCPFixture()
        defer { fixture.cleanup() }
        let oldID = "gb-main"
        let oldCwd = "/dsh/workspace"
        let principal = try await fixture.runtime.issueSession(botId: "main", sessionId: oldID, kind: .chat)
        _ = try await fixture.runtime.eventWriter.append(
            type: "runtime.started", principal: principal,
            data: .object(["sessionId": .string(oldID), "botId": .string("main"), "cwd": .string(oldCwd)]))

        let transport = BotScriptedRemoteTransport(
            scripts: [oldID: []], honorRequestedSessionIDs: true)
        transport.setSessionCWD(oldID, cwd: oldCwd)
        let remote = try await BotDSHRemoteRuntime(transport: transport, runtime: fixture.runtime)
        let rebuilt = try await remote.ensureMainSessionID()

        XCTAssertNotEqual(rebuilt, oldID)
        XCTAssertTrue(rebuilt.hasPrefix("gb-main-"), "rebuild must mint a fresh Bot id: \(rebuilt)")
        XCTAssertEqual(transport.createCount, 1)
        XCTAssertEqual(transport.requestedSessionIds, [rebuilt])
        XCTAssertEqual(transport.archivedSessions, [oldID])
        let events = try await botEvents(fixture.store)
        let latest = events.last { $0.type == "runtime.started" }
        XCTAssertEqual(latest?.data["sessionId"], .string(rebuilt))
        XCTAssertEqual(latest?.data["cwd"], .string(BotWorkspaceLayout.botRoot(botId: "main")))

        // A restart reuses the rebuilt session and does not archive/recreate it.
        let resumedTransport = BotScriptedRemoteTransport(scripts: [rebuilt: []])
        let resumed = try await BotDSHRemoteRuntime(transport: resumedTransport, runtime: fixture.runtime)
        let resumedID = try await resumed.startMainSession()
        XCTAssertEqual(resumedID, rebuilt)
        XCTAssertEqual(resumedTransport.createCount, 0)
        XCTAssertTrue(resumedTransport.archivedSessions.isEmpty)
    }

    func testLegacyRuntimeStartedWithoutCwdLooksUpTheSessionCwd() async throws {
        let fixture = try makeBotMCPFixture()
        defer { fixture.cleanup() }
        let oldID = "gb-main"
        let oldCwd = "/dsh/workspace"
        let principal = try await fixture.runtime.issueSession(botId: "main", sessionId: oldID, kind: .chat)
        _ = try await fixture.runtime.eventWriter.append(
            type: "runtime.started", principal: principal,
            data: .object(["sessionId": .string(oldID), "botId": .string("main")]))

        let transport = BotScriptedRemoteTransport(
            scripts: [oldID: []], honorRequestedSessionIDs: true)
        transport.setSessionCWD(oldID, cwd: oldCwd)
        let remote = try await BotDSHRemoteRuntime(transport: transport, runtime: fixture.runtime)
        let rebuilt = try await remote.ensureMainSessionID()
        XCTAssertTrue(rebuilt.hasPrefix("gb-main-"))
        XCTAssertEqual(transport.archivedSessions, [oldID])
    }

    func testFailedRebuildKeepsTheOldSessionArchivableAndUsable() async throws {
        let fixture = try makeBotMCPFixture()
        defer { fixture.cleanup() }
        let oldID = "gb-main"
        let oldCwd = "/dsh/workspace"
        let principal = try await fixture.runtime.issueSession(botId: "main", sessionId: oldID, kind: .chat)
        _ = try await fixture.runtime.eventWriter.append(
            type: "runtime.started", principal: principal,
            data: .object(["sessionId": .string(oldID), "botId": .string("main"), "cwd": .string(oldCwd)]))

        let failing = BotScriptedRemoteTransport(
            scripts: [oldID: []], honorRequestedSessionIDs: true)
        failing.setSessionCWD(oldID, cwd: oldCwd)
        failing.failCreate(times: 1)
        let remote = try await BotDSHRemoteRuntime(transport: failing, runtime: fixture.runtime)
        do {
            _ = try await remote.ensureMainSessionID()
            XCTFail("rebuild should surface the create failure")
        } catch {
            // The old session was never archived before the replacement existed.
            XCTAssertTrue(failing.archivedSessions.isEmpty)
            XCTAssertEqual(failing.createCount, 0)
        }

        // The next attempt still has the old session and can migrate it.
        let retry = BotScriptedRemoteTransport(
            scripts: [oldID: []], honorRequestedSessionIDs: true)
        retry.setSessionCWD(oldID, cwd: oldCwd)
        let resumed = try await BotDSHRemoteRuntime(transport: retry, runtime: fixture.runtime)
        let rebuilt = try await resumed.ensureMainSessionID()
        XCTAssertTrue(rebuilt.hasPrefix("gb-main-"))
        XCTAssertEqual(retry.archivedSessions, [oldID])
    }

}
