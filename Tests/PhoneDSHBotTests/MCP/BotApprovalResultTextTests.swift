// SPDX-License-Identifier: MIT

import Foundation
import XCTest
@testable import PhoneDSHBot

/// The model sees a tool result as text and tends to repeat it. `RequestApproval`
/// must therefore lead with one plain Chinese sentence, with the structured
/// fields after it, instead of returning only the JSON that leaked
/// `allowed` / `decision` / `scope` / `approval-…` into user-visible prose.
///
/// `PC-20261114-approval-once-scope`: `RequestApproval` always contributes an
/// unclassified effect (`approval.weak-action`, `known:false`), so an `always`
/// answer is a consumed one-shot — the user is asked again next time. The
/// standing-scope sentences are still contract data and are asserted below on a
/// standing-eligible image effect, which keeps `until`/`session` from silently
/// degrading to one-shot copy.
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
        XCTAssertEqual(firstLine, "用户已允许，可以继续。", text)
        for leaked in ["allowed", "decision", "scope", "session", "approval-"] {
            XCTAssertFalse(firstLine.contains(leaked), "first line leaked \(leaked): \(text)")
        }
        // The structured fields stay available (after the sentence) so the
        // card/row projection and diagnostics keep their contract. The weak
        // action is unclassified, so `always` is a consumed one-shot.
        XCTAssertEqual(result.structuredContent?["allowed"], .bool(true))
        XCTAssertEqual(result.structuredContent?["scope"], .string("once"))
        let structured = try XCTUnwrap(result.structuredContent)
        let encoded = try XCTUnwrap(String(data: try structured.encoded(), encoding: .utf8))
        XCTAssertTrue(text.hasSuffix(encoded), "structured payload moved to the end")
    }

    /// A standing-eligible image effect still yields a real standing grant, and
    /// the model-facing sentence still names it. This is the scenario that must
    /// not be collapsed into the one-shot copy.
    func testImageToolStandingApprovalKeepsTheStandingSentence() async throws {
        let fixture = try makeBotMCPFixture()
        defer { fixture.cleanup() }
        _ = try await fixture.runtime.issueSession(
            botId: "main", sessionId: "gb-main", kind: .chat)
        await beginUserTurn(fixture.runtime)
        let arguments = BotJSONValue.object(["path": .string("model/photo.png")])
        let callId = "image-standing-approval"
        _ = try await fixture.runtime.registerIdentity(
            runtimeId: BotMCPRuntime.defaultRuntimeID, sessionId: "gb-main",
            callId: callId, name: "read_image", arguments: arguments)
        let digest = try BotArgumentsDigest.string(for: arguments)
        let execution = Task {
            await fixture.runtime.approve(
                runtimeId: BotMCPRuntime.defaultRuntimeID, sessionId: "gb-main",
                callId: callId, name: "read_image", action: "把图片发送给模型",
                detail: "", command: "", argsDigest: digest, alwaysScope: "until",
                askAction: "tool-call")
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

        let outcome = await execution.value
        XCTAssertEqual(outcome.decision, .always)
        XCTAssertEqual(outcome.scope, "until",
                       "an external-send image effect must keep its standing grant")
        XCTAssertEqual(BotApprovalReceipt.label(for: "always", scope: outcome.scope),
                       "已总是允许")
        XCTAssertEqual(BotMCPRuntime.approvalResultSummary(outcome),
                       "用户已总是允许，之后同类操作不必再问。")
    }

    /// The standing-scope sentence table is contract copy: every branch stays
    /// present even though most phone tools can no longer reach `session`.
    func testApprovalResultSentenceTableKeepsTheStandingBranches() {
        XCTAssertEqual(
            BotMCPRuntime.approvalResultSummary(
                BotApprovalOutcome(ok: true, allowed: true, decision: .always, scope: "session")),
            "用户已允许，本次对话内都有效。")
        XCTAssertEqual(
            BotMCPRuntime.approvalResultSummary(
                BotApprovalOutcome(ok: true, allowed: true, decision: .always, scope: "until")),
            "用户已总是允许，之后同类操作不必再问。")
        XCTAssertEqual(
            BotMCPRuntime.approvalResultSummary(
                BotApprovalOutcome(ok: true, allowed: true, decision: .allowOnce, scope: "once")),
            "用户已允许这一次，可以继续。")
        XCTAssertEqual(
            BotMCPRuntime.approvalResultSummary(
                BotApprovalOutcome(ok: true, allowed: true, decision: .always, scope: "once")),
            "用户已允许，可以继续。")
        XCTAssertEqual(
            BotMCPRuntime.approvalResultSummary(
                BotApprovalOutcome(ok: true, allowed: false, message: "approval denied")),
            "这次请求没有获得允许，已经停止。")
        XCTAssertEqual(
            BotMCPRuntime.approvalResultSummary(
                BotApprovalOutcome(ok: true, allowed: false, pending: true)),
            "审批请求已经发出，正在等用户确认。")
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
