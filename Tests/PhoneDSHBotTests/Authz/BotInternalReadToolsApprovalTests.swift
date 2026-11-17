// SPDX-License-Identifier: MIT

import Foundation
import XCTest
@testable import PhoneDSHBot

/// One host-side consistency regression for every internal read-only tool the
/// Worker gate calls. Each host `effectsForApproval` case must stay empty, so
/// `approve(alwaysScope: "until")` takes the auto-policy branch before any card
/// is created. `ReadMemory` is the historical example of the same
/// `stale:always_scope` mismatch; this test covers the current internal group.
final class BotInternalReadToolsApprovalTests: XCTestCase {
    private let cases: [(name: String, args: BotJSONValue)] = [
        ("BotVolatileContext", .object(["sessionId": .string("gb-main")])),
        ("BotDecisionContext", .object([
            "schema": .string("bot-decision-context-request/v1"),
            "session_id": .string("gb-main"),
            "turn_id": .string("gb-main#1"),
            "step": .number(1),
            "stage": .string("pre_step"),
            "query": .string("probe"),
            "scopes": .array([.string("user")]),
            "limits": .object([
                "max_materials": .number(4), "max_characters": .number(1600),
                "max_snippet_characters": .number(240), "deadline_ms": .number(1500),
            ]),
        ])),
    ]

    func testHostAutoAllowsEveryInternalReadWithoutACard() async throws {
        let fixture = try makeBotMCPFixture()
        defer { fixture.cleanup() }
        _ = try await fixture.runtime.issueSession(
            botId: "main", sessionId: "gb-main", kind: .chat)

        for (index, item) in cases.enumerated() {
            let callId = "internal-read-approval-\(index)"
            let digest = try BotArgumentsDigest.string(for: item.args)
            _ = try await fixture.runtime.registerIdentity(
                runtimeId: BotMCPRuntime.defaultRuntimeID, sessionId: "gb-main",
                callId: callId, name: "mcp__phone__\(item.name)", arguments: item.args)
            let outcome = await fixture.runtime.approve(
                runtimeId: BotMCPRuntime.defaultRuntimeID, sessionId: "gb-main",
                callId: callId, name: "mcp__phone__\(item.name)",
                action: "Read internal context", detail: "probe", command: "",
                argsDigest: digest, alwaysScope: "until", askAction: "tool-call")
            XCTAssertTrue(outcome.ok, "\(item.name): \(String(describing: outcome.message))")
            XCTAssertTrue(outcome.allowed, "\(item.name) must be auto-allowed")
            XCTAssertEqual(outcome.message, "auto-policy", item.name)
            XCTAssertNil(outcome.approvalId, "\(item.name) must not create a card")
        }
        let pending = await fixture.runtime.approvals.pendingIDs
        XCTAssertTrue(pending.isEmpty, "internal read tools left pending approvals: \(pending)")
    }
}
