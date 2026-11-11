// SPDX-License-Identifier: MIT
// phone-dsh Bot eval runner — negative-direction assertion test.
//
// The self-check catalog proves both directions end-to-end through the mock
// upstream. This test additionally mutates one value per assertion against the
// same EvalSnapshot, so a future evaluator change that makes a predicate always
// true fails without needing a Worker boot. It is the "人为改坏每种断言" evidence.

import Foundation
import XCTest
import PhoneDSHBot
import PhoneDSHAgentCore

final class BotEvalAssertionMutationTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("bot-eval-assertions-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testEveryAssertionHasBothDirections() throws {
        let workspace = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try Data("hello world\n".utf8).write(to: workspace.appendingPathComponent("a.txt"))
        try Data(#"{"totals":{"error":null,"ok":1}}"#.utf8)
            .write(to: workspace.appendingPathComponent("out.json"))
        try Data("bye\n".utf8).write(to: workspace.appendingPathComponent("b.txt"))

        let event = try BotEvent(
            type: "demo.event", eventId: "demo-1", time: 1,
            origin: .local(source: "test"), traceId: "trace-1",
            principal: BotPrincipal(botId: "main", sessionId: "session", kind: "chat"),
            causationId: nil, correlationId: nil,
            data: .object(["text": .string("hello"), "count": .number(2)]))
        let approval = try BotEvent(
            type: "approval.requested", eventId: "approval-1", time: 2,
            origin: .local(source: "test"), traceId: "trace-2",
            principal: BotPrincipal(botId: "main", sessionId: "session", kind: "chat"),
            causationId: nil, correlationId: nil,
            data: .object(["approvalID": .string("approval-1")]))
        let memory = BotMemoryDocument(
            path: "user/profile.md", scope: .user, content: "likes tea",
            version: 1, updatedAtMS: 1,
            author: BotMemoryAuthor(botID: "main", sessionID: "session", kind: .chat),
            evidence: [], trust: "user",
            source: BotMemorySource(kind: .userTurn, sessionID: "session"))
        let snapshot = EvalSnapshot(
            mainBotID: "main",
            botIDs: ["side": "bot-side"],
            events: [event, approval],
            replies: [EvalReply(botID: "main", text: "hello world", turnNumber: 1, actionIndex: 1)],
            toolCalls: [EvalToolCallRecord(
                botID: "main", name: "mcp__phone__bash", arguments: #"{"command":"printf hi"}"#)],
            memories: ["main": [memory], "bot-side": []],
            workspaces: ["main": workspace, "bot-side": workspace],
            scratchRoot: root.appendingPathComponent("scratch", isDirectory: true),
            echoRequests: [EvalEchoRequest(method: "POST", path: "/probe")],
            advertisedTools: ["bash", "read", "todo_write"],
            advertisedToolsBySession: [
                "main": ["bash", "read", "todo_write"],
                "task": ["bash", "read", "write"],
                "verifier": ["bash", "glob", "grep", "read"],
            ])
        try FileManager.default.createDirectory(
            at: snapshot.scratchRoot, withIntermediateDirectories: true)

        let cases: [(pass: EvalAssertion, fail: EvalAssertion)] = [
            (EvalAssertion(type: "reply_contains", value: "hello"),
             EvalAssertion(type: "reply_contains", value: "not in the reply")),
            (EvalAssertion(type: "reply_not_contains", value: "absent"),
             EvalAssertion(type: "reply_not_contains", value: "hello")),
            (EvalAssertion(type: "bot_event", event: "demo.event"),
             EvalAssertion(type: "bot_event", event: "never.happened")),
            (EvalAssertion(type: "bot_event", event: "demo.event",
                           whereFields: ["text": .string("hello")]),
             EvalAssertion(type: "bot_event", event: "demo.event",
                           whereFields: ["text": .string("mutated")])),
            (EvalAssertion(type: "bot_event", event: "demo.event",
                           payloadContains: "hello"),
             EvalAssertion(type: "bot_event", event: "demo.event",
                           payloadContains: "mutated")),
            (EvalAssertion(type: "no_bot_event", event: "never.happened"),
             EvalAssertion(type: "no_bot_event", event: "demo.event")),
            (EvalAssertion(type: "tool_called", name: "bash"),
             EvalAssertion(type: "tool_called", name: "NeverCalled")),
            (EvalAssertion(type: "no_tool_call", name: "NeverCalled"),
             EvalAssertion(type: "no_tool_call", name: "bash")),
            (EvalAssertion(type: "memory_contains", value: "tea", scope: "user"),
             EvalAssertion(type: "memory_contains", value: "coffee")),
            (EvalAssertion(type: "memory_absent", value: "coffee"),
             EvalAssertion(type: "memory_absent", value: "tea", scope: "user")),
            (EvalAssertion(type: "approval_count", equals: 1),
             EvalAssertion(type: "approval_count", equals: 0)),
            (EvalAssertion(type: "approval_count", max: 1),
             EvalAssertion(type: "approval_count", max: 0)),
            (EvalAssertion(type: "echo_requests", path: "/probe", method: "POST", equals: 1),
             EvalAssertion(type: "echo_requests", path: "/probe", method: "GET", equals: 1)),
            (EvalAssertion(type: "echo_requests", path: "/absent", equals: 0),
             EvalAssertion(type: "echo_requests", path: "/probe", equals: 0)),
            (EvalAssertion(type: "tool_surface", present: ["bash", "read"],
                           absent: ["subagent", "schedule_create"]),
             EvalAssertion(type: "tool_surface", present: ["subagent"])),
            (EvalAssertion(type: "tool_surface", absent: ["subagent", "skill"]),
             EvalAssertion(type: "tool_surface", absent: ["bash"])),
            (EvalAssertion(type: "tool_surface", session: "verifier",
                           exactly: ["bash", "glob", "grep", "read"]),
             EvalAssertion(type: "tool_surface", session: "verifier",
                           exactly: ["bash", "glob", "grep", "read", "write"])),
            (EvalAssertion(type: "tool_surface", session: "main",
                           present: ["bash"], absent: ["grep"]),
             EvalAssertion(type: "tool_surface", session: "main", present: ["grep"])),
            (EvalAssertion(type: "tool_surface", session: "verifier", present: ["grep"]),
             EvalAssertion(type: "tool_surface", session: "maintainer", present: ["bash"])),
            (EvalAssertion(type: "file_exists", path: "a.txt"),
             EvalAssertion(type: "file_exists", path: "missing.txt")),
            (EvalAssertion(type: "no_file", path: "missing.txt"),
             EvalAssertion(type: "no_file", path: "a.txt")),
            (EvalAssertion(type: "file_contains", value: "hello", path: "a.txt"),
             EvalAssertion(type: "file_contains", value: "mutated", path: "a.txt")),
            (EvalAssertion(type: "file_regex", value: "hel+o", path: "a.txt"),
             EvalAssertion(type: "file_regex", value: "^goodbye$", path: "a.txt")),
            (EvalAssertion(type: "file_json_path", value: "totals.ok", path: "out.json"),
             EvalAssertion(type: "file_json_path", value: "totals.error", path: "out.json")),
            (EvalAssertion(type: "workspace_command", command: "test -f a.txt"),
             EvalAssertion(type: "workspace_command", command: "test -f missing.txt")),
        ]

        for (index, pair) in cases.enumerated() {
            let pass = EvalAssertions.evaluate(pair.pass, snapshot: snapshot)
            let fail = EvalAssertions.evaluate(pair.fail, snapshot: snapshot)
            XCTAssertTrue(pass.ok, "case \(index) \(pair.pass.type) should pass: \(pass.detail)")
            XCTAssertFalse(fail.ok, "case \(index) \(pair.fail.type) should fail: \(fail.detail)")
        }
    }

    func testReplyPredicatesDoNotPassWithoutAReply() throws {
        let workspace = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let snapshot = EvalSnapshot(
            mainBotID: "main", botIDs: [:], events: [], replies: [],
            toolCalls: [], memories: [:], workspaces: ["main": workspace],
            scratchRoot: root.appendingPathComponent("scratch-empty", isDirectory: true))
        try FileManager.default.createDirectory(
            at: snapshot.scratchRoot, withIntermediateDirectories: true)
        let positive = EvalAssertions.evaluate(
            EvalAssertion(type: "reply_contains", value: "anything"), snapshot: snapshot)
        let negative = EvalAssertions.evaluate(
            EvalAssertion(type: "reply_not_contains", value: "anything"), snapshot: snapshot)
        XCTAssertFalse(positive.ok)
        XCTAssertFalse(negative.ok)
    }

    func testBotScopedAssertionsOnlySeeTheRequestedBot() throws {
        let workspace = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let mainEvent = try BotEvent(
            type: "demo.event", eventId: "main-1", time: 1,
            origin: .local(source: "test"), traceId: "trace",
            principal: BotPrincipal(botId: "main", sessionId: "s", kind: "chat"),
            causationId: nil, correlationId: nil, data: .object([:]))
        let snapshot = EvalSnapshot(
            mainBotID: "main", botIDs: ["side": "bot-side"],
            events: [mainEvent], replies: [],
            toolCalls: [], memories: [:], workspaces: ["main": workspace, "bot-side": workspace],
            scratchRoot: root.appendingPathComponent("scratch-scope", isDirectory: true))
        let mainOnly = EvalAssertions.evaluate(
            EvalAssertion(type: "bot_event", bot: "main", event: "demo.event"),
            snapshot: snapshot)
        let side = EvalAssertions.evaluate(
            EvalAssertion(type: "bot_event", bot: "side", event: "demo.event"),
            snapshot: snapshot)
        XCTAssertTrue(mainOnly.ok)
        XCTAssertFalse(side.ok)
    }
}
