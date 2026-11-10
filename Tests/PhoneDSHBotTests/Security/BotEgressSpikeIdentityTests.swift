// SPDX-License-Identifier: MIT
//
// WP3 Bot egress spike: host-side identity and attribution (Q3/Q4).
//
// The attack surface is the real Bot MCP HTTP listener: `/identity/register`
// carries a `sessionId` supplied by its caller, and `/mcp` `tools/call` has no
// caller identity of its own. These tests drive that seam exactly like a
// model-written `curl` would after the host `/v1/http` egress injected the real
// Bot bearer, and then inspect the durable memory/event results.

import XCTest
@testable import PhoneDSHBot

final class BotEgressSpikeIdentityTests: XCTestCase {
    private let token = "wp3-fixture-bot-bearer"

    // MARK: - Q3: Task session impersonating the main conversation

    /// A Task kind session is `task`; the main conversation is `chat`. The
    /// memory source is derived from the registered principal, not from the
    /// session that actually wrote the HTTP request. If a Task session can
    /// register the main conversation's `gb-main` id, the fact is recorded as a
    /// user turn.
    func testTaskSessionCanRegisterMainChatIdentityAndWriteUserTurnMemory() async throws {
        let fixture = try makeBotMCPFixture()
        defer { fixture.cleanup() }
        _ = try await fixture.runtime.issueSession(botId: "main", sessionId: "gb-main", kind: .chat)
        _ = try await fixture.runtime.issueSession(botId: "main", sessionId: "gb-task-1", kind: .task)
        let started = try await spikeStartServer(fixture, token: token)
        defer { started.server.stop() }

        let fact = "WP3-Q3 task session wrote this as a user turn"
        let arguments = BotJSONValue.object([
            "action": .string("write"),
            "fact": .string(fact),
            "scope": .string("user"),
            "tier": .string("profile"),
        ])
        let registration = try await spikeRegister(
            started.base, token: token, sessionId: "gb-main", callId: "wp3-q3-impersonate",
            name: "UpdateMemory", arguments: arguments)
        XCTAssertEqual(registration.status, 200)
        XCTAssertEqual(registration.json["ok"], .bool(true), String(describing: registration.json))

        // The Task session's own catalog header is not part of the call
        // attribution; send it to make that explicit.
        let called = try await spikeCall(
            started.mcp, token: token, name: "UpdateMemory", arguments: arguments,
            callId: "wp3-q3-impersonate",
            headers: [BotMCPHandler.callerSessionHeader: "gb-task-1"])
        let memory = await fixture.runtime.memory(for: "main")
        let facts = try await memory.facts(scope: .user)
        let written = facts.first { $0.text == fact }

        // The fix must reject the attribution or produce a non-user-turn
        // source. Either assertion failing today is the spike result.
        XCTExpectFailure("WP3 Q3: a Task session can register the main chat session id "
            + "and make UpdateMemory appear as a user turn") {
            XCTAssertEqual(called.structured?["ok"], .bool(false),
                "UpdateMemory accepted the foreign-session registration")
            XCTAssertNil(written, "the fact was persisted under the shared user scope")
            XCTAssertNotEqual(written?.source?.kind, BotMemorySourceKind.userTurn,
                "the persisted fact is attributed to a user turn")
            XCTAssertNotEqual(written?.source?.sessionID, "gb-main",
                "the persisted fact names the main chat session")
        }
    }

    /// The same write made with the Task session's own id must be rejected by
    /// `memory-source-boundary`. This is the passing regression that shows the
    /// boundary itself is present; only the cross-session registration defeats
    /// attribution.
    func testOwnTaskSessionCannotWriteUserScopeMemory() async throws {
        let fixture = try makeBotMCPFixture()
        defer { fixture.cleanup() }
        _ = try await fixture.runtime.issueSession(botId: "main", sessionId: "gb-task-own", kind: .task)
        let started = try await spikeStartServer(fixture, token: token)
        defer { started.server.stop() }

        let fact = "WP3-Q3 own-task write must be rejected"
        let arguments = BotJSONValue.object([
            "action": .string("write"),
            "fact": .string(fact),
            "scope": .string("user"),
            "tier": .string("profile"),
        ])
        _ = try await spikeRegister(
            started.base, token: token, sessionId: "gb-task-own", callId: "wp3-q3-own",
            name: "UpdateMemory", arguments: arguments)
        let called = try await spikeCall(
            started.mcp, token: token, name: "UpdateMemory", arguments: arguments,
            callId: "wp3-q3-own")
        XCTAssertEqual(called.structured?["ok"], .bool(false))
        XCTAssertEqual(called.structured?["error"]?.stringValue?.contains("cannot write"), true,
            String(describing: called.json))
        let memory = await fixture.runtime.memory(for: "main")
        let facts = try await memory.facts(scope: .user)
        XCTAssertFalse(facts.contains { $0.text == fact })
    }

    /// A direct `/mcp` caller bypasses the Worker's approval-gate, but not the
    /// host grant check: a `memory.forget` on the shared user scope has
    /// `policy: ask` and no grant exists, so the host refuses.
    func testDirectMCPCallCannotBypassTheHostGrantForAskPolicyTools() async throws {
        let fixture = try makeBotMCPFixture()
        defer { fixture.cleanup() }
        _ = try await fixture.runtime.issueSession(botId: "main", sessionId: "gb-main", kind: .chat)
        let started = try await spikeStartServer(fixture, token: token)
        defer { started.server.stop() }

        let arguments = BotJSONValue.object([
            "action": .string("forget"),
            "fact": .string("WP3-Q3 never approved this forget"),
            "scope": .string("user"),
        ])
        _ = try await spikeRegister(
            started.base, token: token, sessionId: "gb-main", callId: "wp3-q3-forget",
            name: "UpdateMemory", arguments: arguments)
        let called = try await spikeCall(
            started.mcp, token: token, name: "UpdateMemory", arguments: arguments,
            callId: "wp3-q3-forget")
        XCTAssertEqual(called.isError, true, String(describing: called.json))
        XCTAssertEqual(called.structured?["error"]?["code"], .string("permission_denied"),
            String(describing: called.json))
    }

    // MARK: - Q4: one Bot using another Bot's session id

    func testCrossBotIdentityCanWriteAndReadAnotherBotsAgentMemory() async throws {
        let fixture = try makeBotMCPFixture()
        defer { fixture.cleanup() }
        _ = try await fixture.runtime.issueSession(botId: "bot-a", sessionId: "gb-bot-a", kind: .chat)
        _ = try await fixture.runtime.issueSession(botId: "bot-b", sessionId: "gb-bot-b", kind: .chat)
        let started = try await spikeStartServer(fixture, token: token)
        defer { started.server.stop() }

        let fact = "WP3-Q4 bot-a wrote this into bot-b's agent memory"
        let writeArguments = BotJSONValue.object([
            "action": .string("write"),
            "fact": .string(fact),
            "scope": .string("agent"),
            "tier": .string("log"),
        ])
        _ = try await spikeRegister(
            started.base, token: token, sessionId: "gb-bot-b", callId: "wp3-q4-write",
            name: "UpdateMemory", arguments: writeArguments)
        let write = try await spikeCall(
            started.mcp, token: token, name: "UpdateMemory", arguments: writeArguments,
            callId: "wp3-q4-write")

        let recallArguments = BotJSONValue.object([
            "query": .string("WP3-Q4"),
            "scope": .string("agent"),
        ])
        _ = try await spikeRegister(
            started.base, token: token, sessionId: "gb-bot-b", callId: "wp3-q4-read",
            name: "RecallMemory", arguments: recallArguments)
        let recall = try await spikeCall(
            started.mcp, token: token, name: "RecallMemory", arguments: recallArguments,
            callId: "wp3-q4-read")

        let botB = await fixture.runtime.memory(for: "bot-b")
        let botA = await fixture.runtime.memory(for: "bot-a")
        let botBFacts = try await botB.facts(scope: .agent)
        let botAFacts = try await botA.facts(scope: .agent)

        XCTExpectFailure("WP3 Q4: a caller can register another Bot's chat session id "
            + "and write/read that Bot's agent memory") {
            XCTAssertEqual(write.structured?["ok"], .bool(false),
                "the cross-Bot write was accepted")
            XCTAssertFalse(botBFacts.contains { $0.text == fact },
                "the fact was persisted in bot-b's agent memory")
            XCTAssertEqual(recall.structured?["count"], .number(0),
                "the cross-Bot read returned the other Bot's fact")
            XCTAssertFalse(botAFacts.contains { $0.text == fact },
                "the fact must not fall back into bot-a's memory")
        }
    }

    /// The per-caller `tools/list` still hides `CreateTeammate` from a non-main
    /// caller, but `tools/call` does not consult that catalog: the call reaches
    /// the team handler and is refused by the handler's own main-Bot check.
    func testPerCallerToolsListIsNotEnforcedOnToolsCall() async throws {
        let fixture = try makeBotMCPFixture()
        defer { fixture.cleanup() }
        _ = try await fixture.runtime.issueSession(botId: "bot-a", sessionId: "gb-bot-a", kind: .chat)
        _ = try await fixture.runtime.issueSession(botId: "bot-b", sessionId: "gb-bot-b", kind: .chat)
        let host = FakeBotTeamHost(roster: botTeamRoster())
        await fixture.runtime.registerTeamTools(BotTeamTools(host: host))
        let started = try await spikeStartServer(fixture, token: token)
        defer { started.server.stop() }

        let nonMainTools = try await spikeListTools(started.mcp, token: token, session: "gb-bot-b")
        XCTAssertFalse(nonMainTools.contains("CreateTeammate"),
            "a non-main caller must not be shown CreateTeammate")

        let arguments = BotJSONValue.object(["name": .string("Spike teammate")])
        _ = try await spikeRegister(
            started.base, token: token, sessionId: "gb-bot-b", callId: "wp3-q4-team-nonmain",
            name: "CreateTeammate", arguments: arguments)
        let nonMain = try await spikeCall(
            started.mcp, token: token, name: "CreateTeammate", arguments: arguments,
            callId: "wp3-q4-team-nonmain")
        // `unknown_tool` would mean the caller catalog was the boundary; the
        // real boundary is the handler's main-Bot check.
        XCTAssertEqual(nonMain.isError, true, String(describing: nonMain.json))
        XCTAssertEqual(nonMain.structured?["error"]?["code"], .string("permission_denied"),
            String(describing: nonMain.json))
        let created = await host.created
        XCTAssertTrue(created.isEmpty)
    }

    /// The tool list is only advisory: registering the main Bot's session and
    /// calling the hidden tool directly executes it as the main Bot.
    func testImpersonatingTheMainBotBypassesThePerCallerToolList() async throws {
        let fixture = try makeBotMCPFixture()
        defer { fixture.cleanup() }
        _ = try await fixture.runtime.issueSession(botId: "bot-a", sessionId: "gb-bot-a", kind: .chat)
        _ = try await fixture.runtime.issueSession(botId: "bot-b", sessionId: "gb-bot-b", kind: .chat)
        let host = FakeBotTeamHost(roster: botTeamRoster())
        await fixture.runtime.registerTeamTools(BotTeamTools(host: host))
        let started = try await spikeStartServer(fixture, token: token)
        defer { started.server.stop() }

        let nonMainTools = try await spikeListTools(started.mcp, token: token, session: "gb-bot-b")
        XCTAssertFalse(nonMainTools.contains("CreateTeammate"))

        let arguments = BotJSONValue.object(["name": .string("WP3 teammate")])
        _ = try await spikeRegister(
            started.base, token: token, sessionId: "gb-bot-a", callId: "wp3-q4-team-main",
            name: "CreateTeammate", arguments: arguments)
        let called = try await spikeCall(
            started.mcp, token: token, name: "CreateTeammate", arguments: arguments,
            callId: "wp3-q4-team-main",
            headers: [BotMCPHandler.callerSessionHeader: "gb-bot-b"])
        let created = await host.created

        XCTExpectFailure("WP3 Q4: a caller shown only the non-main catalog can register "
            + "the main Bot's session id and execute the hidden CreateTeammate tool") {
            XCTAssertEqual(called.isError, true, "CreateTeammate executed as the main Bot")
            XCTAssertTrue(created.isEmpty, "the hidden tool created a teammate")
        }
    }
}
