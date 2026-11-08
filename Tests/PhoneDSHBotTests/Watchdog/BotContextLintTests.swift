// SPDX-License-Identifier: MIT

import XCTest
@testable import PhoneDSHBot

final class BotContextLintTests: XCTestCase {
    func testFrozenToolDefinitionGoldenMatchesRealDeterministicLint() throws {
        let fixture = try botGolden("context-lint")
        let expected = try botDecode([BotContextLintFinding].self, fixture["valid"]!)
        let tools = try botJSONValue([
            ["name": "example", "description": "example tool", "inputSchema": ["type": "object"]],
        ])
        var thresholds = BotContextLintThresholds.default
        thresholds.toolCountWarn = 1
        thresholds.toolDefTokensWarn = 1
        thresholds.toolDefTokensError = 10_000
        let findings = BotContextLint.lint(tools: tools, thresholds: thresholds, sessionId: "gb-main")
        XCTAssertEqual(findings, expected)
        XCTAssertEqual(findings[0].evidence, "1 tool definitions, ~23 tokens / 79 chars (token warn 1, error 10000; count warn 1)")
    }

    func testSystemToolResultAndOrphanRulesUseSchemaNamesAndStableOrder() {
        var thresholds = BotContextLintThresholds.default
        thresholds.personaCharsWarn = 10
        thresholds.personaCharsError = 30
        thresholds.toolResultTokensWarn = 5
        thresholds.toolResultTokensError = 8
        let events = [
            BotContextLintEvent(type: "turn/start", seq: 1, data: ["turn": .number(1)]),
            BotContextLintEvent(type: "system/message", seq: 2, data: [
                "message": .object(["content": .string(String(repeating: "x", count: 20))]),
            ]),
            BotContextLintEvent(type: "tool/call", seq: 3, data: [
                "turn": .number(1), "callId": .string("call-1"), "name": .string("read"),
            ]),
            BotContextLintEvent(type: "tool/result", seq: 4, data: [
                "turn": .number(1), "callId": .string("call-1"),
                "message": .object(["content": .string(String(repeating: "x", count: 30))]),
            ]),
            BotContextLintEvent(type: "tool/call", seq: 5, data: [
                "turn": .number(1), "callId": .string("call-2"), "name": .string("write"),
            ]),
            BotContextLintEvent(type: "tool/result", seq: 6, data: [
                "turn": .number(1), "callId": .string("call-3"), "result": .string("missing"),
            ]),
        ]
        let findings = BotContextLint.lint(events: events, thresholds: thresholds, sessionId: "session")
        XCTAssertEqual(findings.map(\.rule), [
            .toolResultBloat, .orphanToolCall, .orphanToolResult, .systemPromptBloat,
        ])
        XCTAssertEqual(findings.map(\.severity), [.error, .error, .error, .warn])
        XCTAssertEqual(BotContextLintSupport.object(findings[0].location)["tool"], .string("read"))
    }

    func testSpillNoticeSuppressesOnlyOversizedResultFinding() {
        var thresholds = BotContextLintThresholds.default
        thresholds.toolResultTokensWarn = 1
        let text = String(repeating: "payload", count: 20) + " Omitted 12,000 bytes. Full formatted result stored at: /tmp/result"
        let event = BotContextLintEvent(type: "tool/result", seq: 1, data: [
            "callId": .string("call"), "result": .string(text),
        ])
        let findings = BotContextLint.lint(events: [event], thresholds: thresholds)
        XCTAssertFalse(findings.map(\.rule).contains(.toolResultBloat))
    }

    func testDuplicateRuntimeAndLargeMessageRulesAreDeterministic() {
        var thresholds = BotContextLintThresholds.default
        thresholds.maxRuntimeContextsPerTurn = 2
        thresholds.repeatedTextChars = 20
        let repeated = String(repeating: "shared context ", count: 3)
        let runtime = (1...3).map { index in
            BotContextLintEvent(type: "user/message", seq: index, data: [
                "turn": .number(1), "source": .object(["kind": .string("runtime-context")]),
                "content": .string(index == 3 ? repeated + String(repeating: "x", count: 210) : repeated),
            ])
        }
        let ordinary = [4, 5].map { index in
            BotContextLintEvent(type: "assistant/message", seq: index, data: [
                "turn": .number(1), "message": .object(["content": .string(repeated)]),
            ])
        }
        let first = BotContextLint.lint(events: runtime + ordinary, thresholds: thresholds, sessionId: "session")
        let second = BotContextLint.lint(events: runtime + ordinary, thresholds: thresholds, sessionId: "session")
        XCTAssertEqual(first, second)
        XCTAssertEqual(first.map(\.rule), [.duplicateContext, .duplicateContext, .duplicateContext, .duplicateContext])
        XCTAssertTrue(first.contains { $0.evidence.contains("3 runtime-context snapshots") })
        XCTAssertTrue(first.contains { $0.evidence.contains("snapshot repeated") })
        XCTAssertTrue(first.contains { $0.evidence.contains("embeds the earlier snapshot") })
        XCTAssertTrue(first.contains { $0.evidence.contains("appears in 2 messages") })
    }

    func testAssistantToolCallPairsAndLatestRequestHeaderTools() throws {
        var thresholds = BotContextLintThresholds.default
        thresholds.toolCountWarn = 1
        let events = [
            BotContextLintEvent(type: "assistant/message", seq: 1, data: [
                "message": .object(["content": .array([
                    .object(["type": .string("tool-call"), "id": .string("call"), "name": .string("read")]),
                ])]),
            ]),
            BotContextLintEvent(type: "tool/result", seq: 2, data: [
                "callId": .string("call"), "result": .string("ok"),
            ]),
            BotContextLintEvent(type: "request/header", seq: 3, data: [
                "header": .object(["tools": .array([try botJSONValue(["name": "example"])])]),
            ]),
        ]
        let findings = BotContextLint.lint(events: events, thresholds: thresholds, sessionId: "session")
        XCTAssertEqual(findings.map(\.rule), [.toolDefBloat])
        XCTAssertEqual(BotContextLintSupport.object(findings[0].location)["source"], .string("request/header"))
    }
}
