// SPDX-License-Identifier: MIT
//
// Host-side Bot egress approval at the `/v1/http` exit.
//
// These tests drive the real `BotMCPRuntime` registration and approval
// coordinator, not a copy of its rules: one live `bash` identity registration
// stands in for the Worker shell call that is executing a model-written
// command. The command text is deliberately the WP3 bypass spelling, because
// the host decision must not depend on it.

import XCTest
@testable import PhoneDSHBot

final class BotEgressApprovalTests: XCTestCase {
    private let host = "127.0.0.1"

    @discardableResult
    private func registerBash(
        _ runtime: BotMCPRuntime, command: String, callId: String,
        sessionId: String = "gb-main", token: String
    ) async throws -> BotAttribution {
        let arguments = BotJSONValue.object(["command": .string(command)])
        return try await runtime.registerIdentity(
            runtimeId: BotMCPRuntime.defaultRuntimeID, sessionId: sessionId,
            callId: callId, name: "bash", arguments: arguments, sessionToken: token)
    }

    private func waitForApproval(
        _ store: SQLiteDomainStore, minimumCount: Int = 1,
        timeoutSeconds: TimeInterval = 2
    ) async throws -> BotEvent? {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            let requests = try await botEvents(store).filter { $0.type == "approval.requested" }
            if requests.count >= minimumCount { return requests.last }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        return nil
    }

    private func resolve(
        _ runtime: BotMCPRuntime, event: BotEvent, decision: BotApprovalDecision
    ) async throws {
        let approvalID = try XCTUnwrap(event.data["approvalID"]?.stringValue)
        let digest = try XCTUnwrap(event.data["digest"]?.stringValue)
        let resolution = await runtime.approvals.resolve(
            approvalId: approvalID, decision: decision, digest: digest)
        XCTAssertEqual(resolution, .resolved)
    }

    /// WP3's three bypass spellings all reduce to the same host-visible write:
    /// one POST to one host. The host must ask for approval and must not send
    /// anything when the user denies.
    func testEveryBypassSpellingIsApprovedAtTheHostEgressExit() async throws {
        let commands = [
            "curl -sS -X POST --data-raw '{}' http://127.0.0.1:8787/identity/register",
            "printf '%s\\n' 'curl -sS -X POST --data-raw \"{}\" http://127.0.0.1:8787/identity/register' "
                + "> /tmp/wp3.sh; bash /tmp/wp3.sh",
            "c=cur; l=\"${c}l\"; \"$l\" -sS -X POST --data-raw '{}' http://127.0.0.1:8787/identity/register",
            "python3 /tmp/wp3.py",
        ]
        for (index, command) in commands.enumerated() {
            let fixture = try makeBotMCPFixture()
            defer { fixture.cleanup() }
            let issued = try await fixture.runtime.issueSessionToken(
                botId: "main", sessionId: "gb-main", kind: .chat)
            try await registerBash(fixture.runtime, command: command,
                                   callId: "wp3-egress-\(index)", token: issued.token)
            await beginUserTurn(fixture.runtime)

            let approval = Task { await fixture.runtime.approveEgress(
                method: "POST", host: host, scheme: "http", port: 8787) }
            let event = try await waitForApproval(fixture.store)
            let requested = try XCTUnwrap(event, "\(command): no approval.requested event")
            let effects = requested.data["effects"]?.arrayValue ?? []
            XCTAssertEqual(effects.count, 1, "\(command): \(requested.data)")
            XCTAssertEqual(effects.first?["tool"]?.stringValue, BotEgressEffects.toolName)
            XCTAssertEqual(effects.first?["operation"]?.stringValue, "egress.post")
            XCTAssertEqual(effects.first?["resource"]?.stringValue, "host=127.0.0.1")
            XCTAssertEqual(requested.data["command"]?.stringValue, command)

            try await resolve(fixture.runtime, event: requested, decision: .deny)
            let outcome = await approval.value
            XCTAssertEqual(outcome, .denied(
                code: "egress_approval_denied", message: "approval denied"),
                "\(command): \(outcome)")
        }
    }

    func testWorkbenchTurnKeepsTheWorkbenchBehaviour() async throws {
        let fixture = try makeBotMCPFixture()
        defer { fixture.cleanup() }
        _ = try await fixture.runtime.issueSessionToken(
            botId: "main", sessionId: "gb-main", kind: .chat)
        await fixture.runtime.installWorkbenchTurnProbe { true }
        let outcome = await fixture.runtime.approveEgress(
            method: "POST", host: host, scheme: "http", port: 8787)
        XCTAssertEqual(outcome, .notBot)
        let events = try await botEvents(fixture.store)
        XCTAssertEqual(events.filter { $0.type == "approval.requested" }.count, 0)
    }

    func testUnattributedWriteWithNoWorkbenchTurnFailsClosedWhenNoBotSessionExists() async throws {
        let fixture = try makeBotMCPFixture()
        defer { fixture.cleanup() }
        let outcome = await fixture.runtime.approveEgress(
            method: "POST", host: host, scheme: "http", port: 8787)
        XCTAssertEqual(outcome, .denied(
            code: "bot_egress_unattributed",
            message: "没有活动的 Bot 会话可以承接这次网络写入"))
        let events = try await botEvents(fixture.store)
        XCTAssertEqual(events.filter { $0.type == "approval.requested" }.count, 0)
    }

    func testTaskWithoutNetworkWriteAuthorizationIsDeniedBeforeAnyCard() async throws {
        let fixture = try makeBotMCPFixture()
        defer { fixture.cleanup() }
        let authorization = try BotTaskAuthorization.resolve(
            requestedDirectories: ["notes"],
            workspaceRoot: BotWorkspaceLayout.botRoot(botId: "main"))
        XCTAssertFalse(authorization.canNetworkWrite)
        let issued = try await fixture.runtime.issueSessionToken(
            botId: "main", sessionId: "gb-task-egress", kind: .task,
            capabilities: authorization.capabilities)
        try await registerBash(
            fixture.runtime, command: "curl -sS -X POST --data-raw '{}' http://127.0.0.1:8787/x",
            callId: "task-egress-denied", sessionId: "gb-task-egress", token: issued.token)
        // A standing Grant may not widen the subset the host issued at task
        // creation: the Task is refused before the coordinator is consulted.
        _ = try await fixture.runtime.grants.add(BotGrant(
            botId: "main", tool: BotEgressEffects.toolName, operation: "egress.post",
            resource: "host=127.0.0.1", scope: .until, sessionId: "gb-task-egress",
            createdAt: 1_000, source: "test", decision: .allow))

        let outcome = await fixture.runtime.approveEgress(
            method: "POST", host: host, scheme: "http", port: 8787)
        XCTAssertEqual(outcome, .denied(
            code: "task_network_write_denied",
            message: "Task 子任务没有网络写权限（未授权 task.network-write），这次请求没有发出"))

        let events = try await botEvents(fixture.store)
        XCTAssertEqual(events.filter { $0.type == "approval.requested" }.count, 0,
                       "a Task subset denial must not create an approval card")
        let pending = await fixture.runtime.approvals.pendingIDs
        XCTAssertTrue(pending.isEmpty)
    }

    func testUnattributedWriteWithOnlyATaskSessionIsDeniedBeforeAnyCard() async throws {
        let fixture = try makeBotMCPFixture()
        defer { fixture.cleanup() }
        let authorization = try BotTaskAuthorization.resolve(
            requestedDirectories: [], workspaceRoot: BotWorkspaceLayout.botRoot(botId: "main"))
        _ = try await fixture.runtime.issueSessionToken(
            botId: "main", sessionId: "gb-task-only", kind: .task,
            capabilities: authorization.capabilities)

        let outcome = await fixture.runtime.approveEgress(
            method: "POST", host: host, scheme: "http", port: 8787)
        XCTAssertEqual(outcome, .denied(
            code: "task_network_write_denied",
            message: "Task 子任务没有网络写权限（未授权 task.network-write），这次请求没有发出"))
        let events = try await botEvents(fixture.store)
        XCTAssertEqual(events.filter { $0.type == "approval.requested" }.count, 0)
    }

    func testTaskWithNetworkWriteAuthorizationStillAsksForApproval() async throws {
        let fixture = try makeBotMCPFixture()
        defer { fixture.cleanup() }
        let authorization = try BotTaskAuthorization.resolve(
            requestedDirectories: [], workspaceRoot: BotWorkspaceLayout.botRoot(botId: "main"),
            canNetworkWrite: true)
        XCTAssertTrue(authorization.canNetworkWrite)
        let issued = try await fixture.runtime.issueSessionToken(
            botId: "main", sessionId: "gb-task-network", kind: .task,
            capabilities: authorization.capabilities)
        try await registerBash(
            fixture.runtime, command: "curl -sS -X POST --data-raw '{}' http://127.0.0.1:8787/x",
            callId: "task-egress-ask", sessionId: "gb-task-network", token: issued.token)

        // A Task session is background work: the write becomes a durable todo
        // instead of waiting five minutes.
        let outcome = await fixture.runtime.approveEgress(
            method: "POST", host: host, scheme: "http", port: 8787)
        guard case .denied(let code, let message) = outcome else {
            XCTFail("expected a durable pending denial: \(outcome)")
            return
        }
        XCTAssertEqual(code, "egress_approval_denied")
        XCTAssertTrue(message.contains("用户决定后会继续"))
        let requested = try await waitForApproval(fixture.store)
        let event = try XCTUnwrap(requested)
        let effects = event.data["effects"]?.arrayValue ?? []
        XCTAssertEqual(effects.first?["tool"]?.stringValue, BotEgressEffects.toolName)
        XCTAssertEqual(effects.first?["operation"]?.stringValue, "egress.post")
        XCTAssertEqual(event.data["persistent"], .bool(true))
        XCTAssertEqual(event.data["origin"], .string("egress"))
        try await resolve(fixture.runtime, event: event, decision: .allowOnce)

        // The once Grant survives the failed first attempt; the resumed task's
        // retry consumes it and is allowed.
        let grants = await fixture.runtime.grants.list(botId: "main")
        XCTAssertTrue(grants.contains {
            $0.operation == "egress.post" && $0.scope == .once && $0.decision == .allow
        })
        let retry = await fixture.runtime.approveEgress(
            method: "POST", host: host, scheme: "http", port: 8787)
        XCTAssertEqual(retry, .allowed)
        let events = try await botEvents(fixture.store)
        XCTAssertTrue(events.contains { $0.type == "grant.consumed" },
                      "the resumed retry must consume the once grant")
    }

    func testChatSessionWithoutTaskAuthorizationStillAsksForApproval() async throws {
        let fixture = try makeBotMCPFixture()
        defer { fixture.cleanup() }
        let issued = try await fixture.runtime.issueSessionToken(
            botId: "main", sessionId: "gb-main", kind: .chat)
        try await registerBash(
            fixture.runtime, command: "curl -sS -X POST --data-raw '{}' http://127.0.0.1:8787/x",
            callId: "chat-egress-ask", token: issued.token)
        await beginUserTurn(fixture.runtime)

        let approval = Task { await fixture.runtime.approveEgress(
            method: "POST", host: host, scheme: "http", port: 8787) }
        let requested = try await waitForApproval(fixture.store)
        let event = try XCTUnwrap(requested)
        try await resolve(fixture.runtime, event: event, decision: .deny)
        let outcome = await approval.value
        XCTAssertEqual(outcome, .denied(
            code: "egress_approval_denied", message: "approval denied"))
    }

    func testUnattributedWriteWithOneBotSessionAsksThatBot() async throws {
        let fixture = try makeBotMCPFixture()
        defer { fixture.cleanup() }
        _ = try await fixture.runtime.issueSessionToken(
            botId: "main", sessionId: "gb-main", kind: .chat)
        await beginUserTurn(fixture.runtime)

        let approval = Task { await fixture.runtime.approveEgress(
            method: "POST", host: host, scheme: "http", port: 8787) }
        let event = try await waitForApproval(fixture.store)
        let requested = try XCTUnwrap(event)
        let effects = requested.data["effects"]?.arrayValue ?? []
        XCTAssertEqual(effects.count, 1)
        XCTAssertEqual(effects.first?["operation"]?.stringValue, "egress.post")
        XCTAssertEqual(effects.first?["resource"]?.stringValue, "host=127.0.0.1")
        XCTAssertEqual(requested.data["command"]?.stringValue,
                       "后台网络写入找不到仍然活动的命令登记")
        try await resolve(fixture.runtime, event: requested, decision: .deny)
        let outcome = await approval.value
        XCTAssertEqual(outcome, .denied(
            code: "egress_approval_denied", message: "approval denied"))
    }

    func testUnattributedWriteWithSeveralActiveBotsIsAmbiguous() async throws {
        let fixture = try makeBotMCPFixture()
        defer { fixture.cleanup() }
        _ = try await fixture.runtime.issueSessionToken(
            botId: "bot-a", sessionId: "gb-a", kind: .chat)
        _ = try await fixture.runtime.issueSessionToken(
            botId: "bot-b", sessionId: "gb-b", kind: .chat)
        let outcome = await fixture.runtime.approveEgress(
            method: "POST", host: host, scheme: "http", port: 8787)
        XCTAssertEqual(outcome, .denied(
            code: "bot_egress_ambiguous",
            message: "同时有多个 Bot 会话在运行，无法判断这次网络写入属于谁"))
        let events = try await botEvents(fixture.store)
        XCTAssertEqual(events.filter { $0.type == "approval.requested" }.count, 0)
    }

    func testGetAndHeadAreNeverApprovalRequests() async throws {
        let fixture = try makeBotMCPFixture()
        defer { fixture.cleanup() }
        let issued = try await fixture.runtime.issueSessionToken(
            botId: "main", sessionId: "gb-main", kind: .chat)
        try await registerBash(fixture.runtime, command: "curl -sS http://127.0.0.1:8787/x",
                               callId: "get", token: issued.token)
        for method in ["GET", "HEAD"] {
            let outcome = await fixture.runtime.approveEgress(
                method: method, host: host, scheme: "http", port: 8787)
            XCTAssertEqual(outcome, .notBot)
        }
        let events = try await botEvents(fixture.store)
        XCTAssertEqual(events.filter { $0.type == "approval.requested" }.count, 0)
    }

    func testHeartbeatRefreshExtendsARegistrationPastTheOriginalTTL() async throws {
        final class Clock: @unchecked Sendable {
            var value: Int64
            init(_ value: Int64) { self.value = value }
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let clock = Clock(1_000)
        let store = try SQLiteDomainStore(
            fileURL: directory.appendingPathComponent("domain.sqlite"))
        let runtime = BotMCPRuntime(store: store, now: { clock.value })
        defer { try? FileManager.default.removeItem(at: directory) }
        let issued = try await runtime.issueSessionToken(
            botId: "main", sessionId: "gb-main", kind: .chat)
        let arguments = BotJSONValue.object(["command": .string("curl -X POST http://127.0.0.1/a")])
        await beginUserTurn(runtime)
        let first = try await runtime.registerIdentity(
            runtimeId: BotMCPRuntime.defaultRuntimeID, sessionId: "gb-main",
            callId: "heartbeat-refresh", name: "bash", arguments: arguments,
            sessionToken: issued.token)
        clock.value += 300_000
        let refreshed = try await runtime.registerIdentity(
            runtimeId: BotMCPRuntime.defaultRuntimeID, sessionId: "gb-main",
            callId: "heartbeat-refresh", name: "bash", arguments: arguments,
            sessionToken: issued.token)
        XCTAssertEqual(refreshed.id, first.id, "the same job must keep one attribution id")
        XCTAssertGreaterThan(refreshed.expiresAt, first.expiresAt)

        // The original expiry has passed, but the refreshed registration is
        // still live: an egress write must reach the approval card instead of
        // falling through to the workbench fallback.
        clock.value = first.expiresAt + 1
        let approval = Task { await runtime.approveEgress(
            method: "POST", host: host, scheme: "http", port: 8787) }
        let event = try await waitForApproval(store)
        let requested = try XCTUnwrap(event)
        try await resolve(runtime, event: requested, decision: .deny)
        let outcome = await approval.value
        XCTAssertEqual(outcome, .denied(
            code: "egress_approval_denied", message: "approval denied"))
    }

    func testChatEgressCompletesTheSameRequestWhenTheUserAnswersInsideTheWindow() async throws {
        let fixture = try makeBotMCPFixture()
        defer { fixture.cleanup() }
        await fixture.runtime.setEgressInteractiveWaitMilliseconds(2_000)
        let issued = try await fixture.runtime.issueSessionToken(
            botId: "main", sessionId: "gb-main", kind: .chat)
        try await registerBash(
            fixture.runtime, command: "curl -X POST http://127.0.0.1:8787/x",
            callId: "same-request", token: issued.token)
        await beginUserTurn(fixture.runtime)

        let approval = Task { await fixture.runtime.approveEgress(
            method: "POST", host: host, scheme: "http", port: 8787) }
        let eventRequest = try await waitForApproval(fixture.store)
        let event = try XCTUnwrap(eventRequest)
        try await resolve(fixture.runtime, event: event, decision: .allowOnce)
        let outcome = await approval.value

        // A present user completes the original request; the gateway then
        // sends it with this `.allowed` answer.
        XCTAssertEqual(outcome, .allowed)
        let grants = await fixture.runtime.grants.list(botId: "main")
        XCTAssertFalse(grants.contains { $0.scope == .once },
                       "the live request consumes its once Grant before writing")
        let requests = try await botEvents(fixture.store)
            .filter { $0.type == "approval.requested" }
        XCTAssertEqual(requests.count, 1)
    }

    func testChatEgressReturnsPendingBeforeTheClientAbortAndRetryReusesTheCard() async throws {
        let fixture = try makeBotMCPFixture()
        defer { fixture.cleanup() }
        // Simulate the user taking longer than the caller's fetch budget: the
        // host must answer with the human pending sentence, keep the card, and
        // let the approved retry consume the once Grant.
        await fixture.runtime.setEgressInteractiveWaitMilliseconds(0)
        let issued = try await fixture.runtime.issueSessionToken(
            botId: "main", sessionId: "gb-main", kind: .chat)
        try await registerBash(
            fixture.runtime, command: "curl -X POST http://127.0.0.1:8787/x",
            callId: "slow-approval", token: issued.token)
        await beginUserTurn(fixture.runtime)

        let clock = Date()
        let first = await fixture.runtime.approveEgress(
            method: "POST", host: host, scheme: "http", port: 8787)
        let elapsed = Date().timeIntervalSince(clock)
        guard case .denied(let code, let message) = first else {
            XCTFail("expected the pending denial: \(first)")
            return
        }
        XCTAssertEqual(code, "egress_approval_denied")
        XCTAssertTrue(message.contains("已提交审批，批准后请重试"),
                      "the caller must get a human pending sentence: \(message)")
        XCTAssertLessThan(elapsed, 0.5, "the pending answer must not wait for the user")
        let pendingIDs = await fixture.runtime.approvals.pendingIDs
        XCTAssertEqual(pendingIDs.count, 1)
        let eventRequest = try await waitForApproval(fixture.store)
        let event = try XCTUnwrap(eventRequest)

        // A retry while the card is pending reuses it instead of stacking a
        // second card.
        let duplicate = await fixture.runtime.approveEgress(
            method: "POST", host: host, scheme: "http", port: 8787)
        guard case .denied(_, let duplicateMessage) = duplicate else {
            XCTFail("expected the same pending answer: \(duplicate)")
            return
        }
        XCTAssertTrue(duplicateMessage.contains("批准后请重试"))
        let requests = try await botEvents(fixture.store)
            .filter { $0.type == "approval.requested" }
        XCTAssertEqual(requests.count, 1, "one pending card per session+method+host")

        try await resolve(fixture.runtime, event: event, decision: .allowOnce)
        let retry = await fixture.runtime.approveEgress(
            method: "POST", host: host, scheme: "http", port: 8787)
        XCTAssertEqual(retry, .allowed, "the approved retry consumes the once Grant")
        let grants = await fixture.runtime.grants.list(botId: "main")
        XCTAssertFalse(grants.contains { $0.scope == .once })
    }

    func testRoutineAndEgressCardsCancelIndependently() async throws {
        let fixture = try makeBotMCPFixture()
        defer { fixture.cleanup() }
        let issued = try await fixture.runtime.issueSessionToken(
            botId: "main", sessionId: "gb-main", kind: .chat)

        // No beginTurn: the routine change is a non-user turn and gets a card.
        let routine = Task {
            try await registerAndExecute(
                fixture.runtime, name: "UpdateRoutine", arguments: .object([
                    "action": .string("create"), "title": .string("Shared coordinator"),
                    "prompt": .string("Report once"), "schedule": .string("@every 60m"),
                ]))
        }
        let first = try await waitForApproval(fixture.store)
        let firstEvent = try XCTUnwrap(first)
        let firstID = try XCTUnwrap(firstEvent.data["approvalID"]?.stringValue)

        try await registerBash(
            fixture.runtime, command: "curl -sS -X POST --data-raw '{}' http://127.0.0.1:8787/x",
            callId: "egress-shared-coordinator", token: issued.token)
        let egressApproval = Task { await fixture.runtime.approveEgress(
            method: "POST", host: host, scheme: "http", port: 8787) }
        _ = try await waitForApproval(fixture.store, minimumCount: 2)

        let requests = try await botEvents(fixture.store)
            .filter { $0.type == "approval.requested" }
        let egressEvent = try XCTUnwrap(requests.first {
            $0.data["effects"]?.arrayValue?.first?["tool"]?.stringValue == "egress"
        })
        let routineEvent = try XCTUnwrap(requests.first {
            $0.data["effects"]?.arrayValue?.first?["operation"]?.stringValue == "routine.authorize"
        })
        XCTAssertEqual(routineEvent.data["approvalID"]?.stringValue, firstID)
        XCTAssertNotEqual(egressEvent.data["approvalID"]?.stringValue, firstID,
                          "each card must get its own approval id")
        XCTAssertEqual(routineEvent.data["effects"]?.arrayValue?.first?["label"]?.stringValue,
                       "确认更新例行工作")
        XCTAssertTrue(
            (egressEvent.data["effects"]?.arrayValue?.first?["label"]?.stringValue ?? "")
                .contains("POST"),
            "the egress card keeps its own host+method wording")

        let egressID = try XCTUnwrap(egressEvent.data["approvalID"]?.stringValue)
        // The egress card is a durable todo now: an interactive cancel (worker
        // restart / consumer disconnect) must not throw away the user's chance
        // to authorize the retried write.
        let cancelled = await fixture.runtime.approvals.cancel(approvalId: egressID)
        XCTAssertFalse(cancelled, "a durable egress card survives interactive cancellation")
        let pending = await fixture.runtime.approvals.pendingIDs
        XCTAssertTrue(pending.contains(egressID))
        let egressDigest = try XCTUnwrap(egressEvent.data["digest"]?.stringValue)
        let egressResolved = await fixture.runtime.approvals.resolve(
            approvalId: egressID, decision: .allowOnce, digest: egressDigest)
        XCTAssertEqual(egressResolved, .resolved)
        let egressOutcome = await egressApproval.value
        XCTAssertEqual(egressOutcome, .allowed)

        // The routine card is still pending and can be answered after the
        // egress decision.
        let routineDigest = try XCTUnwrap(
            routineEvent.data["digest"]?.stringValue)
        let resolved = await fixture.runtime.approvals.resolve(
            approvalId: firstID, decision: .allowOnce, digest: routineDigest)
        XCTAssertEqual(resolved, .resolved)
        let routineResult = try await routine.value
        XCTAssertNotEqual(routineResult.isError, true, String(describing: routineResult))
        let created = try await fixture.runtime.routineMachine.list(botId: "main")
            .contains { $0.title == "Shared coordinator" }
        XCTAssertTrue(created, "resolving the egress card must not consume the routine card")

        let decisions = try await botEvents(fixture.store)
            .filter { $0.type == "approval.decided" }
        let egressDecision = decisions.first {
            $0.data["approvalID"]?.stringValue == egressID
        }
        let routineDecision = decisions.first {
            $0.data["approvalID"]?.stringValue == firstID
        }
        XCTAssertEqual(egressDecision?.data["status"]?.stringValue, "allowed")
        XCTAssertEqual(routineDecision?.data["status"]?.stringValue, "allowed")
    }

    func testRoutineAndEgressCardsExpireIndependently() async throws {
        let fixture = try makeBotMCPFixture()
        defer { fixture.cleanup() }
        let issued = try await fixture.runtime.issueSessionToken(
            botId: "main", sessionId: "gb-main", kind: .chat)
        let arguments = BotJSONValue.object(["command": .string("curl -X POST http://127.0.0.1/a")])
        let attribution = try await fixture.runtime.registerIdentity(
            runtimeId: BotMCPRuntime.defaultRuntimeID, sessionId: "gb-main",
            callId: "timeout-card", name: "bash", arguments: arguments,
            sessionToken: issued.token)
        let lookedUp = await fixture.runtime.gateway.tokens.lookupSession("gb-main")
        let principal = try XCTUnwrap(lookedUp)
        let call = try XCTUnwrap(BotResolvedToolCall(
            sessionId: "gb-main", callId: "timeout-card", agentId: "main",
            principal: principal, attribution: attribution))

        // A short timeout keeps the two cards' deadline handling observable
        // without changing production's 300 s default.
        let grants = await fixture.runtime.grants
        let eventWriter = await fixture.runtime.eventWriter
        let coordinator = BotApprovalCoordinator(
            grants: grants, eventWriter: eventWriter, approvalTimeoutMs: 300)
        let routineEffect = BotToolEffect(
            tool: "UpdateRoutine", operation: "routine.authorize",
            resource: "routine=create", mutability: .write, policy: .ask,
            label: "确认更新例行工作", known: false, isMcp: true)
        let egressEffect = BotEgressEffects.egressEffect(
            method: "POST", host: "api.example.test",
            target: "https://api.example.test/upload")
        let routine = Task {
            await coordinator.request(
                call: call, effects: [routineEffect], action: "UpdateRoutine",
                detail: "", command: "", alwaysScope: "none")
        }
        let egress = Task {
            await coordinator.request(
                call: call, effects: [egressEffect], action: "egress",
                detail: "", command: "", alwaysScope: "until")
        }
        var pending: [String] = []
        for _ in 0..<200 {
            pending = await coordinator.pendingIDs
            if pending.count == 2 { break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertEqual(pending.count, 2)

        let requests = try await botEvents(fixture.store)
            .filter { $0.type == "approval.requested" }
        let routineEvent = try XCTUnwrap(requests.first {
            $0.data["effects"]?.arrayValue?.first?["operation"]?.stringValue == "routine.authorize"
        })
        let routineID = try XCTUnwrap(routineEvent.data["approvalID"]?.stringValue)
        let routineDigest = try XCTUnwrap(routineEvent.data["digest"]?.stringValue)
        let resolved = await coordinator.resolve(
            approvalId: routineID, decision: .allowOnce, digest: routineDigest)
        XCTAssertEqual(resolved, .resolved)

        let routineOutcome = await routine.value
        XCTAssertTrue(routineOutcome.allowed, routineOutcome.message ?? "")
        let egressOutcome = await egress.value
        XCTAssertFalse(egressOutcome.allowed)
        XCTAssertEqual(egressOutcome.message, "approval timed out")

        let decisions = try await botEvents(fixture.store)
            .filter { $0.type == "approval.decided" }
        let routineDecision = decisions.first {
            $0.data["approvalID"]?.stringValue == routineID
        }
        XCTAssertEqual(routineDecision?.data["status"]?.stringValue, "allowed")
        let timedOut = decisions.first {
            $0.data["approvalID"]?.stringValue != routineID
                && $0.data["timedOut"] == .bool(true)
        }
        XCTAssertNotNil(timedOut, "the unresolved egress card alone must time out")
    }

    func testAlwaysCreatesAReusableHostAndMethodGrant() async throws {
        let fixture = try makeBotMCPFixture()
        defer { fixture.cleanup() }
        let issued = try await fixture.runtime.issueSessionToken(
            botId: "main", sessionId: "gb-main", kind: .chat)
        try await registerBash(fixture.runtime, command: "curl -X POST http://127.0.0.1:8787/a",
                               callId: "always-first", token: issued.token)
        await beginUserTurn(fixture.runtime)

        let first = Task { await fixture.runtime.approveEgress(
            method: "POST", host: host, scheme: "http", port: 8787) }
        let firstEvent = try await waitForApproval(fixture.store)
        let event = try XCTUnwrap(firstEvent)
        try await resolve(fixture.runtime, event: event, decision: .always)
        let firstOutcome = await first.value
        XCTAssertEqual(firstOutcome, .allowed)

        let second = await fixture.runtime.approveEgress(
            method: "POST", host: host, scheme: "http", port: 8787)
        XCTAssertEqual(second, .allowed, "the standing host+method grant must be reused")
        let events = try await botEvents(fixture.store)
        XCTAssertEqual(events.filter { $0.type == "approval.requested" }.count, 1)

        // A different method is a different Grant, so it still asks.
        let put = Task { await fixture.runtime.approveEgress(
            method: "PUT", host: host, scheme: "http", port: 8787) }
        let pendingSecond = try await waitForApproval(fixture.store, minimumCount: 2)
        let secondEvent = try XCTUnwrap(pendingSecond)
        XCTAssertNotEqual(secondEvent.eventId, event.eventId)
        try await resolve(fixture.runtime, event: secondEvent, decision: .deny)
        let putOutcome = await put.value
        XCTAssertEqual(putOutcome, .denied(
            code: "egress_approval_denied", message: "approval denied"))
    }

    func testTwoLiveShellCallsFromTheSameBotAreOneOwner() async throws {
        let fixture = try makeBotMCPFixture()
        defer { fixture.cleanup() }
        let issued = try await fixture.runtime.issueSessionToken(
            botId: "main", sessionId: "gb-main", kind: .chat)
        try await registerBash(fixture.runtime, command: "curl -X POST http://127.0.0.1:8787/a",
                               callId: "same-bot-a", token: issued.token)
        try await registerBash(fixture.runtime, command: "curl -X POST http://127.0.0.1:8787/b",
                               callId: "same-bot-b", token: issued.token)
        await beginUserTurn(fixture.runtime)
        let approval = Task { await fixture.runtime.approveEgress(
            method: "POST", host: host, scheme: "http", port: 8787) }
        let event = try await waitForApproval(fixture.store)
        let requested = try XCTUnwrap(event)
        try await resolve(fixture.runtime, event: requested, decision: .deny)
        let outcome = await approval.value
        XCTAssertEqual(outcome, .denied(
            code: "egress_approval_denied", message: "approval denied"))
    }

    func testDifferentBotsWithoutAHostTiebreakFailClosed() async throws {
        let fixture = try makeBotMCPFixture()
        defer { fixture.cleanup() }
        let first = try await fixture.runtime.issueSessionToken(
            botId: "bot-a", sessionId: "gb-a", kind: .chat)
        let second = try await fixture.runtime.issueSessionToken(
            botId: "bot-b", sessionId: "gb-b", kind: .chat)
        try await registerBash(fixture.runtime, command: "curl -X POST http://other.test/a",
                               callId: "ambiguous-a", sessionId: "gb-a", token: first.token)
        try await registerBash(fixture.runtime, command: "curl -X POST http://other.test/b",
                               callId: "ambiguous-b", sessionId: "gb-b", token: second.token)
        let ambiguous = await fixture.runtime.approveEgress(
            method: "POST", host: host, scheme: "http", port: 8787)
        XCTAssertEqual(ambiguous, .denied(
            code: "bot_egress_ambiguous",
            message: "同时有多个 Bot 会话在运行，无法判断这次网络写入属于谁"))
        let events = try await botEvents(fixture.store)
        XCTAssertEqual(events.filter { $0.type == "approval.requested" }.count, 0)
    }

    func testConsumerCancellationKeepsTheDurableEgressCard() async throws {
        let fixture = try makeBotMCPFixture()
        defer { fixture.cleanup() }
        await fixture.runtime.setEgressInteractiveWaitMilliseconds(0)
        let issued = try await fixture.runtime.issueSessionToken(
            botId: "main", sessionId: "gb-main", kind: .chat)
        try await registerBash(fixture.runtime, command: "curl -X POST http://127.0.0.1:8787/a",
                               callId: "cancel-me", token: issued.token)
        await beginUserTurn(fixture.runtime)

        // The /v1/http consumer can abort (curl --max-time) while the user is
        // deciding. The card is durable and the allowOnce Grant must survive
        // for the retried request instead of being consumed by the dead one.
        let outcome = await fixture.runtime.approveEgress(
            method: "POST", host: host, scheme: "http", port: 8787)
        guard case .denied(let code, let message) = outcome else {
            XCTFail("expected the durable pending denial: \(outcome)")
            return
        }
        XCTAssertEqual(code, "egress_approval_denied")
        XCTAssertTrue(message.contains("批准后请重试"))
        let pendingRequest = try await waitForApproval(fixture.store)
        let pending = try XCTUnwrap(pendingRequest)
        let approvalID = try XCTUnwrap(pending.data["approvalID"]?.stringValue)
        let cancelled = await fixture.runtime.approvals.cancel(approvalId: approvalID)
        XCTAssertFalse(cancelled, "consumer cancellation must not cancel a durable egress card")

        let digest = try XCTUnwrap(pending.data["digest"]?.stringValue)
        let resolved = await fixture.runtime.approvals.resolve(
            approvalId: approvalID, decision: .allowOnce, digest: digest)
        XCTAssertEqual(resolved, .resolved)
        let retry = await fixture.runtime.approveEgress(
            method: "POST", host: host, scheme: "http", port: 8787)
        XCTAssertEqual(retry, .allowed, "the retry consumes the preserved once Grant")
        let grants = await fixture.runtime.grants.list(botId: "main")
        XCTAssertFalse(grants.contains { $0.scope == .once },
                       "the retried write consumed the once Grant")
        let decided = try await botEvents(fixture.store).filter { $0.type == "approval.decided" }
        XCTAssertEqual(decided.last?.data["status"]?.stringValue, "allowed")
    }

    func testFileWriteEffectIsDirectoryGranularAndWorkspaceScoped() {
        let root = "/dsh/workspace/.dshbot/agents/main"
        let inside = BotEgressEffects.fileEffects(
            tool: "write",
            arguments: .object(["file_path": .string("notes/local.txt"), "content": .string("x")]),
            workspaceRoot: root)
        XCTAssertEqual(inside, [])

        let outside = BotEgressEffects.fileEffects(
            tool: "write",
            arguments: .object([
                "file_path": .string("/dsh/workspace/other/a.txt"), "content": .string("x"),
            ]),
            workspaceRoot: root)
        XCTAssertEqual(outside.count, 1)
        XCTAssertEqual(outside[0].operation, "file.write")
        XCTAssertEqual(outside[0].resource, "dir=/dsh/workspace/other")
        XCTAssertEqual(outside[0].policy, .ask)
        XCTAssertTrue(outside[0].known)
        XCTAssertEqual(outside[0].grantResource, "dir=/dsh/workspace/other")
        XCTAssertTrue(outside[0].canUseStandingGrant)

        let sibling = BotEgressEffects.fileEffects(
            tool: "edit",
            arguments: .object([
                "file_path": .string("/dsh/workspace/other/b.txt"),
                "old_string": .string("x"), "new_string": .string("y"),
            ]),
            workspaceRoot: root)
        XCTAssertEqual(sibling[0].resource, "dir=/dsh/workspace/other",
                       "the same directory must reuse one Grant")
        XCTAssertEqual(sibling[0].operation, "file.edit")

        let traversal = BotEgressEffects.fileEffects(
            tool: "write",
            arguments: .object([
                "file_path": .string("notes/../../outside.txt"), "content": .string("x"),
            ]),
            workspaceRoot: root)
        XCTAssertEqual(traversal.first?.resource, "dir=/dsh/workspace/.dshbot/agents")
    }
}
