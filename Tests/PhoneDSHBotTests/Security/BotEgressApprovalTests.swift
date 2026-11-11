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
            message: "no live Bot session can own the network write"))
        let events = try await botEvents(fixture.store)
        XCTAssertEqual(events.filter { $0.type == "approval.requested" }.count, 0)
    }

    func testUnattributedWriteWithOneBotSessionAsksThatBot() async throws {
        let fixture = try makeBotMCPFixture()
        defer { fixture.cleanup() }
        _ = try await fixture.runtime.issueSessionToken(
            botId: "main", sessionId: "gb-main", kind: .chat)

        let approval = Task { await fixture.runtime.approveEgress(
            method: "POST", host: host, scheme: "http", port: 8787) }
        let event = try await waitForApproval(fixture.store)
        let requested = try XCTUnwrap(event)
        let effects = requested.data["effects"]?.arrayValue ?? []
        XCTAssertEqual(effects.count, 1)
        XCTAssertEqual(effects.first?["operation"]?.stringValue, "egress.post")
        XCTAssertEqual(effects.first?["resource"]?.stringValue, "host=127.0.0.1")
        XCTAssertEqual(requested.data["command"]?.stringValue,
                       "background network write with no live shell registration")
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
            message: "more than one Bot session is active; the network write is not attributable"))
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

    func testAlwaysCreatesAReusableHostAndMethodGrant() async throws {
        let fixture = try makeBotMCPFixture()
        defer { fixture.cleanup() }
        let issued = try await fixture.runtime.issueSessionToken(
            botId: "main", sessionId: "gb-main", kind: .chat)
        try await registerBash(fixture.runtime, command: "curl -X POST http://127.0.0.1:8787/a",
                               callId: "always-first", token: issued.token)

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
            message: "more than one Bot session is active; the network write is not attributable"))
        let events = try await botEvents(fixture.store)
        XCTAssertEqual(events.filter { $0.type == "approval.requested" }.count, 0)
    }

    func testConsumerCancellationCancelsThePendingCard() async throws {
        let fixture = try makeBotMCPFixture()
        defer { fixture.cleanup() }
        let issued = try await fixture.runtime.issueSessionToken(
            botId: "main", sessionId: "gb-main", kind: .chat)
        try await registerBash(fixture.runtime, command: "curl -X POST http://127.0.0.1:8787/a",
                               callId: "cancel-me", token: issued.token)
        let approval = Task { await fixture.runtime.approveEgress(
            method: "POST", host: host, scheme: "http", port: 8787) }
        let pending = try await waitForApproval(fixture.store)
        _ = try XCTUnwrap(pending)
        approval.cancel()
        let outcome = await approval.value
        if case .denied(let code, _) = outcome {
            XCTAssertEqual(code, "egress_approval_denied")
        } else {
            XCTFail("cancelled egress approval must fail closed: \(outcome)")
        }
        let decided = try await botEvents(fixture.store).filter { $0.type == "approval.decided" }
        XCTAssertEqual(decided.last?.data["status"]?.stringValue, "cancelled")
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
