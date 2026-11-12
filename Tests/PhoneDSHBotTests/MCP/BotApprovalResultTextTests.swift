// SPDX-License-Identifier: MIT

import Foundation
import XCTest
@testable import PhoneDSHBot

/// The model sees a tool result as text and tends to repeat it. `RequestApproval`
/// must therefore lead with one plain Chinese sentence, with the structured
/// fields after it, instead of returning only the JSON that leaked
/// `allowed` / `decision` / `scope` / `approval-…` into user-visible prose.
final class BotApprovalResultTextTests: XCTestCase {
    func testRequestApprovalResultStartsWithAHumanSentence() async throws {
        let fixture = try makeBotMCPFixture()
        defer { fixture.cleanup() }
        _ = try await fixture.runtime.issueSession(
            botId: "main", sessionId: "gb-main", kind: .chat)
        await beginUserTurn(fixture.runtime)
        let arguments = BotJSONValue.object([
            "action": .string("审批回执测试"),
            "detail": .string("只验证工具结果文案"),
        ])
        let callId = "approval-result-text"
        _ = try await fixture.runtime.registerIdentity(
            runtimeId: BotMCPRuntime.defaultRuntimeID, sessionId: "gb-main",
            callId: callId, name: "RequestApproval", arguments: arguments)
        let digest = try BotArgumentsDigest.string(for: arguments)
        let execution = Task {
            await fixture.runtime.execute(
                name: "RequestApproval", arguments: arguments,
                context: BotMCPRequestContext(callId: callId))
        }

        var approvalID: String?
        for _ in 0..<200 {
            if let first = await fixture.runtime.approvals.pendingIDs.first {
                approvalID = first
                break
            }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        let id = try XCTUnwrap(approvalID)
        let resolved = await fixture.runtime.approvals.resolve(
            approvalId: id, decision: .always, digest: digest)
        XCTAssertEqual(resolved, .resolved)

        let result = await execution.value
        let text = try XCTUnwrap(result.content.first?["text"]?.stringValue)
        let firstLine = text.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? ""
        XCTAssertEqual(firstLine, "用户已允许，本次对话内都有效。", text)
        for leaked in ["allowed", "decision", "scope", "session", "approval-"] {
            XCTAssertFalse(firstLine.contains(leaked), "first line leaked \(leaked): \(text)")
        }
        // The structured fields stay available (after the sentence) so the
        // card/row projection and diagnostics keep their contract.
        XCTAssertEqual(result.structuredContent?["allowed"], .bool(true))
        XCTAssertEqual(result.structuredContent?["scope"], .string("session"))
        let structured = try XCTUnwrap(result.structuredContent)
        let encoded = try XCTUnwrap(String(data: try structured.encoded(), encoding: .utf8))
        XCTAssertTrue(text.hasSuffix(encoded), "structured payload moved to the end")
    }

    func testDeniedApprovalResultAlsoStartsWithAHumanSentence() async throws {
        let fixture = try makeBotMCPFixture()
        defer { fixture.cleanup() }
        _ = try await fixture.runtime.issueSession(
            botId: "main", sessionId: "gb-main", kind: .chat)
        await beginUserTurn(fixture.runtime)
        let arguments = BotJSONValue.object([
            "action": .string("拒绝回执测试"),
            "detail": .string("只验证工具结果文案"),
        ])
        let callId = "approval-denied-text"
        _ = try await fixture.runtime.registerIdentity(
            runtimeId: BotMCPRuntime.defaultRuntimeID, sessionId: "gb-main",
            callId: callId, name: "RequestApproval", arguments: arguments)
        let digest = try BotArgumentsDigest.string(for: arguments)
        let execution = Task {
            await fixture.runtime.execute(
                name: "RequestApproval", arguments: arguments,
                context: BotMCPRequestContext(callId: callId))
        }

        var approvalID: String?
        for _ in 0..<200 {
            if let first = await fixture.runtime.approvals.pendingIDs.first {
                approvalID = first
                break
            }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        let id = try XCTUnwrap(approvalID)
        _ = await fixture.runtime.approvals.resolve(
            approvalId: id, decision: .deny, digest: digest)

        let result = await execution.value
        let text = try XCTUnwrap(result.content.first?["text"]?.stringValue)
        let firstLine = text.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? ""
        XCTAssertEqual(firstLine, "这次请求没有获得允许，已经停止。", text)
        XCTAssertEqual(result.structuredContent?["allowed"], .bool(false))
    }
}
