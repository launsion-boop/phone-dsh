// SPDX-License-Identifier: MIT
//
// WP3 Bot egress spike: host-side identity and attribution (Q3/Q4).
//
// The attack surface is the real Bot MCP HTTP listener: `/identity/register`
// carries a `sessionId` supplied by its caller, and `/mcp` `tools/call` has no
// caller identity of its own. These tests drive that seam exactly like a
// model-written `curl` would after the host `/v1/http` egress injected the real
// Bot bearer, and then inspect the durable memory/event results.
//
// After WPF2 the bearer alone is not identity evidence: the caller also has to
// present the session token the App issued for that exact incarnation.

import XCTest
@testable import PhoneDSHBot

final class BotEgressSpikeIdentityTests: XCTestCase {
    private let token = "wp3-fixture-bot-bearer"

    // MARK: - Q3: Task session impersonating the main conversation

    /// A Task kind session is `task`; the main conversation is `chat`. Its own
    /// token must not register `gb-main`, and a request with no token at all
    /// must be rejected before any registration exists.
    func testTaskSessionCannotRegisterMainChatIdentityOrWriteUserTurnMemory() async throws {
        let fixture = try makeBotMCPFixture()
        defer { fixture.cleanup() }
        let main = try await fixture.runtime.issueSessionToken(
            botId: "main", sessionId: "gb-main", kind: .chat)
        let task = try await fixture.runtime.issueSessionToken(
            botId: "main", sessionId: "gb-task-1", kind: .task)
        await fixture.runtime.beginTurn(
            sessionId: "gb-main", hidden: false,
            origin: BotTurnOrigin(rpcId: "user-action:wp3-q3-impersonate"))
        let started = try await spikeStartServer(fixture, token: token)
        defer { started.server.stop() }

        let fact = "WP3-Q3 task session wrote this as a user turn"
        let arguments = BotJSONValue.object([
            "action": .string("write"),
            "path": .string("user/profile.md"),
            "content": .string(fact),
            "expected_version": .number(0),
        ])
        for credential in [task.token, nil] as [String?] {
            let registration = try await spikeRegister(
                started.base, token: token, sessionId: "gb-main", callId: "wp3-q3-impersonate",
                name: "UpdateMemory", arguments: arguments, sessionToken: credential)
            XCTAssertEqual(registration.status, 200)
            XCTAssertEqual(registration.json["ok"], .bool(false),
                           "a Task/none credential must not register the main chat: \(registration.json)")
            XCTAssertEqual(registration.json["error"], .string("unauthorized"))
        }

        let called = try await spikeCall(
            started.mcp, token: token, name: "UpdateMemory", arguments: arguments,
            callId: "wp3-q3-impersonate",
            headers: [BotMCPHandler.callerSessionHeader: "gb-task-1"])
        XCTAssertEqual(called.isError, true, String(describing: called.json))
        XCTAssertEqual(called.structured?["error"]?["code"], .string("unattributed"),
                       String(describing: called.json))
        let memory = await fixture.runtime.memory(for: "main")
        let documents = try await memory.documents(scope: .user)
        XCTAssertFalse(documents.contains { $0.content == fact })

        // The main session's own current token still registers normally.
        let own = try await spikeRegister(
            started.base, token: token, sessionId: "gb-main", callId: "wp3-q3-own",
            name: "UpdateMemory", arguments: arguments, sessionToken: main.token)
        XCTAssertEqual(own.json["ok"], .bool(true), String(describing: own.json))
    }

    /// The same write made with the Task session's own id must be rejected by
    /// `memory-source-boundary`. This is the passing regression that shows the
    /// boundary itself is present; only a foreign-session registration could
    /// defeat attribution.
    func testOwnTaskSessionCannotWriteUserScopeMemory() async throws {
        let fixture = try makeBotMCPFixture()
        defer { fixture.cleanup() }
        let task = try await fixture.runtime.issueSessionToken(
            botId: "main", sessionId: "gb-task-own", kind: .task)
        let started = try await spikeStartServer(fixture, token: token)
        defer { started.server.stop() }

        let fact = "WP3-Q3 own-task write must be rejected"
        let arguments = BotJSONValue.object([
            "action": .string("write"),
            "path": .string("user/profile.md"),
            "content": .string(fact),
            "expected_version": .number(0),
        ])
        let registration = try await spikeRegister(
            started.base, token: token, sessionId: "gb-task-own", callId: "wp3-q3-own",
            name: "UpdateMemory", arguments: arguments, sessionToken: task.token)
        XCTAssertEqual(registration.json["ok"], .bool(true), String(describing: registration.json))
        let called = try await spikeCall(
            started.mcp, token: token, name: "UpdateMemory", arguments: arguments,
            callId: "wp3-q3-own")
        XCTAssertEqual(called.structured?["ok"], .bool(false))
        XCTAssertEqual(called.structured?["code"], .string("memory-scope-denied"),
            String(describing: called.json))
        let memory = await fixture.runtime.memory(for: "main")
        let documents = try await memory.documents(scope: .user)
        XCTAssertFalse(documents.contains { $0.content == fact })
    }

    /// A direct `/mcp` caller bypasses the Worker's approval-gate, but not the
    /// host grant check: a `memory.forget` on the shared user scope has
    /// `policy: ask` and no grant exists, so the host refuses.
    func testDirectMCPCallCannotBypassTheHostGrantForAskPolicyTools() async throws {
        let fixture = try makeBotMCPFixture()
        defer { fixture.cleanup() }
        let main = try await fixture.runtime.issueSessionToken(
            botId: "main", sessionId: "gb-main", kind: .chat)
        let started = try await spikeStartServer(fixture, token: token)
        defer { started.server.stop() }

        let arguments = BotJSONValue.object([
            "action": .string("delete"),
            "path": .string("user/private.md"),
            "expected_version": .number(0),
        ])
        _ = try await spikeRegister(
            started.base, token: token, sessionId: "gb-main", callId: "wp3-q3-forget",
            name: "UpdateMemory", arguments: arguments, sessionToken: main.token)
        let called = try await spikeCall(
            started.mcp, token: token, name: "UpdateMemory", arguments: arguments,
            callId: "wp3-q3-forget")
        XCTAssertEqual(called.isError, true, String(describing: called.json))
        XCTAssertEqual(called.structured?["error"]?["code"], .string("permission_denied"),
            String(describing: called.json))
    }

    func testTaskAndRoutineSessionsRegisterOnlyTheirOwnCredentials() async throws {
        let fixture = try makeBotMCPFixture()
        defer { fixture.cleanup() }
        let task = try await fixture.runtime.issueSessionToken(
            botId: "main", sessionId: "gb-task-1", kind: .task)
        let routine = try await fixture.runtime.issueSessionToken(
            botId: "main", sessionId: "gb-routine-1", kind: .routine)
        let started = try await spikeStartServer(fixture, token: token)
        defer { started.server.stop() }

        let arguments = BotJSONValue.object([:])
        for (sessionId, issued) in [("gb-task-1", task), ("gb-routine-1", routine)] {
            let own = try await spikeRegister(
                started.base, token: token, sessionId: sessionId, callId: "own-\(sessionId)",
                name: "ListRoutines", arguments: arguments, sessionToken: issued.token)
            XCTAssertEqual(own.json["ok"], .bool(true), String(describing: own.json))
            let foreign = try await spikeRegister(
                started.base, token: token, sessionId: sessionId, callId: "foreign-\(sessionId)",
                name: "ListRoutines", arguments: arguments,
                sessionToken: sessionId == "gb-task-1" ? routine.token : task.token)
            XCTAssertEqual(foreign.json["ok"], .bool(false), String(describing: foreign.json))
            XCTAssertEqual(foreign.json["error"], .string("unauthorized"))
        }
    }

    // MARK: - Q4: one Bot using another Bot's session id

    func testCrossBotIdentityCannotWriteOrReadAnotherBotsAgentMemory() async throws {
        let fixture = try makeBotMCPFixture()
        defer { fixture.cleanup() }
        let botAToken = try await fixture.runtime.issueSessionToken(
            botId: "bot-a", sessionId: "gb-bot-a", kind: .chat)
        _ = try await fixture.runtime.issueSessionToken(
            botId: "bot-b", sessionId: "gb-bot-b", kind: .chat)
        let started = try await spikeStartServer(fixture, token: token)
        defer { started.server.stop() }

        let fact = "WP3-Q4 bot-a wrote this into bot-b's agent memory"
        let writeArguments = BotJSONValue.object([
            "action": .string("write"),
            "path": .string("agent/notes/spike.md"),
            "content": .string(fact),
            "expected_version": .number(0),
        ])
        let writeRegistration = try await spikeRegister(
            started.base, token: token, sessionId: "gb-bot-b", callId: "wp3-q4-write",
            name: "UpdateMemory", arguments: writeArguments, sessionToken: botAToken.token)
        XCTAssertEqual(writeRegistration.json["ok"], .bool(false),
                       String(describing: writeRegistration.json))
        XCTAssertEqual(writeRegistration.json["error"], .string("unauthorized"))
        let write = try await spikeCall(
            started.mcp, token: token, name: "UpdateMemory", arguments: writeArguments,
            callId: "wp3-q4-write")

        let recallArguments = BotJSONValue.object([
            "query": .string("WP3-Q4"),
            "scope": .string("agent"),
        ])
        let recallRegistration = try await spikeRegister(
            started.base, token: token, sessionId: "gb-bot-b", callId: "wp3-q4-read",
            name: "RecallMemory", arguments: recallArguments, sessionToken: botAToken.token)
        XCTAssertEqual(recallRegistration.json["ok"], .bool(false),
                       String(describing: recallRegistration.json))
        let recall = try await spikeCall(
            started.mcp, token: token, name: "RecallMemory", arguments: recallArguments,
            callId: "wp3-q4-read")

        let botB = await fixture.runtime.memory(for: "bot-b")
        let botA = await fixture.runtime.memory(for: "bot-a")
        let botBDocuments = try await botB.documents(scope: .agent)
        let botADocuments = try await botA.documents(scope: .agent)

        XCTAssertEqual(write.isError, true, String(describing: write.json))
        XCTAssertEqual(write.structured?["ok"], .bool(false))
        XCTAssertEqual(recall.isError, true, String(describing: recall.json))
        XCTAssertFalse(botBDocuments.contains { $0.content == fact },
                       "the fact was persisted in bot-b's agent memory")
        XCTAssertFalse(botADocuments.contains { $0.content == fact },
                       "the fact must not fall back into bot-a's memory")
    }

    /// A legitimately attributed non-main caller sees no `CreateTeammate` in
    /// `tools/list` and `tools/call` refuses it from the same per-caller
    /// catalog before the team handler runs.
    func testToolsCallEnforcesThePerCallerCatalog() async throws {
        let fixture = try makeBotMCPFixture()
        defer { fixture.cleanup() }
        _ = try await fixture.runtime.issueSessionToken(
            botId: "bot-a", sessionId: "gb-bot-a", kind: .chat)
        let botB = try await fixture.runtime.issueSessionToken(
            botId: "bot-b", sessionId: "gb-bot-b", kind: .chat)
        let host = FakeBotTeamHost(roster: botTeamRoster())
        await fixture.runtime.registerTeamTools(BotTeamTools(host: host))
        let started = try await spikeStartServer(fixture, token: token)
        defer { started.server.stop() }

        let nonMainTools = try await spikeListTools(started.mcp, token: token, session: "gb-bot-b")
        XCTAssertFalse(nonMainTools.contains("CreateTeammate"),
            "a non-main caller must not be shown CreateTeammate")

        let arguments = BotJSONValue.object(["name": .string("Spike teammate")])
        let registration = try await spikeRegister(
            started.base, token: token, sessionId: "gb-bot-b", callId: "wp3-q4-team-nonmain",
            name: "CreateTeammate", arguments: arguments, sessionToken: botB.token)
        XCTAssertEqual(registration.json["ok"], .bool(true), String(describing: registration.json))
        let nonMain = try await spikeCall(
            started.mcp, token: token, name: "CreateTeammate", arguments: arguments,
            callId: "wp3-q4-team-nonmain")
        XCTAssertEqual(nonMain.isError, true, String(describing: nonMain.json))
        XCTAssertEqual(nonMain.structured?["error"]?["code"], .string("permission_denied"),
            String(describing: nonMain.json))
        let created = await host.created
        XCTAssertTrue(created.isEmpty)
    }

    /// The tool list is not the only boundary: impersonating the main Bot's
    /// session id fails at identity registration, before the hidden tool can
    /// be attributed.
    func testImpersonatingTheMainBotIsRejectedByTheSessionCredential() async throws {
        let fixture = try makeBotMCPFixture()
        defer { fixture.cleanup() }
        _ = try await fixture.runtime.issueSessionToken(
            botId: "bot-a", sessionId: "gb-bot-a", kind: .chat)
        let botB = try await fixture.runtime.issueSessionToken(
            botId: "bot-b", sessionId: "gb-bot-b", kind: .chat)
        let host = FakeBotTeamHost(roster: botTeamRoster())
        await fixture.runtime.registerTeamTools(BotTeamTools(host: host))
        let started = try await spikeStartServer(fixture, token: token)
        defer { started.server.stop() }

        let nonMainTools = try await spikeListTools(started.mcp, token: token, session: "gb-bot-b")
        XCTAssertFalse(nonMainTools.contains("CreateTeammate"))

        let arguments = BotJSONValue.object(["name": .string("WP3 teammate")])
        let registration = try await spikeRegister(
            started.base, token: token, sessionId: "gb-bot-a", callId: "wp3-q4-team-main",
            name: "CreateTeammate", arguments: arguments, sessionToken: botB.token)
        XCTAssertEqual(registration.json["ok"], .bool(false),
                       String(describing: registration.json))
        XCTAssertEqual(registration.json["error"], .string("unauthorized"))
        let called = try await spikeCall(
            started.mcp, token: token, name: "CreateTeammate", arguments: arguments,
            callId: "wp3-q4-team-main",
            headers: [BotMCPHandler.callerSessionHeader: "gb-bot-b"])
        let created = await host.created

        XCTAssertEqual(called.isError, true, String(describing: called.json))
        XCTAssertEqual(called.structured?["error"]?["code"], .string("unattributed"),
                       String(describing: called.json))
        XCTAssertTrue(created.isEmpty, "the hidden tool created a teammate")
    }

    /// The trusted path is unchanged: the main Bot's own current credential
    /// still executes `CreateTeammate`.
    func testMainBotWithItsOwnCredentialStillCreatesATeammate() async throws {
        let fixture = try makeBotMCPFixture()
        defer { fixture.cleanup() }
        let main = try await fixture.runtime.issueSessionToken(
            botId: "bot-a", sessionId: "gb-bot-a", kind: .chat)
        let host = FakeBotTeamHost(roster: botTeamRoster())
        await fixture.runtime.registerTeamTools(BotTeamTools(host: host))
        let started = try await spikeStartServer(fixture, token: token)
        defer { started.server.stop() }

        let arguments = BotJSONValue.object(["name": .string("Trusted teammate")])
        let registration = try await spikeRegister(
            started.base, token: token, sessionId: "gb-bot-a", callId: "wp3-trusted-team",
            name: "CreateTeammate", arguments: arguments, sessionToken: main.token)
        XCTAssertEqual(registration.json["ok"], .bool(true), String(describing: registration.json))
        let called = try await spikeCall(
            started.mcp, token: token, name: "CreateTeammate", arguments: arguments,
            callId: "wp3-trusted-team")
        XCTAssertNotEqual(called.isError, true, String(describing: called.json))
        let created = await host.created
        XCTAssertEqual(created.map(\.name), ["Trusted teammate"])
    }
}
