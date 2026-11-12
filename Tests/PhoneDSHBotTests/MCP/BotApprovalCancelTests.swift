// SPDX-License-Identifier: MIT

import Foundation
import XCTest
@testable import PhoneDSHBot

final class BotApprovalCancelTests: XCTestCase {
    private func query(_ fact: String) -> BotJSONValue {
        .object([
            "action": .string("forget"), "scope": .string("user"), "fact": .string(fact),
        ])
    }

    @discardableResult
    private func issueChat(_ runtime: BotMCPRuntime, botID: String) async throws -> BotGatewayPrincipal {
        try await runtime.issueSession(botId: botID, sessionId: "gb-\(botID)", kind: .chat)
    }

    private func beginApproval(_ runtime: BotMCPRuntime, botID: String,
                               callID: String, fact: String) async throws
        -> (Task<BotApprovalOutcome, Never>, String) {
        let args = query(fact)
        // These tests cover the interactive 300 s card (worker restart must
        // cancel it). Durable approvals are covered by
        // BotPersistentApprovalTests.
        await runtime.beginTurn(
            sessionId: "gb-\(botID)", hidden: false,
            origin: BotTurnOrigin(rpcId: "bot-test"))
        _ = try await runtime.registerIdentity(
            runtimeId: BotMCPRuntime.defaultRuntimeID, sessionId: "gb-\(botID)",
            callId: callID, name: "UpdateMemory", arguments: args)
        let digest = try BotArgumentsDigest.string(for: args)
        let task = Task {
            await runtime.approve(
                runtimeId: BotMCPRuntime.defaultRuntimeID, sessionId: "gb-\(botID)",
                callId: callID, name: "UpdateMemory", action: "Forget",
                detail: "test", command: "", argsDigest: digest,
                alwaysScope: "until", askAction: "tool-call")
        }
        return (task, digest)
    }

    private func waitForPending(_ coordinator: BotApprovalCoordinator,
                                _ expected: Int) async throws -> [String] {
        for _ in 0..<200 {
            let ids = await coordinator.pendingIDs
            if ids.count == expected { return ids }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        return await coordinator.pendingIDs
    }

    func testCancelAllForOneBotLeavesTheOtherApprovalApprovable() async throws {
        let fixture = try makeBotMCPFixture()
        defer { fixture.cleanup() }
        try await issueChat(fixture.runtime, botID: "bot-a")
        try await issueChat(fixture.runtime, botID: "bot-b")

        let (first, firstDigest) = try await beginApproval(
            fixture.runtime, botID: "bot-a", callID: "call-a", fact: "alpha")
        let (second, secondDigest) = try await beginApproval(
            fixture.runtime, botID: "bot-b", callID: "call-b", fact: "beta")
        let pending = try await waitForPending(fixture.runtime.approvals, 2)
        XCTAssertEqual(pending.count, 2)

        let cancelled = await fixture.runtime.approvals.cancelAll(
            botID: "bot-a", reason: "bot_deleted")
        XCTAssertEqual(cancelled, 1)

        let firstOutcome = await first.value
        XCTAssertFalse(firstOutcome.allowed)
        XCTAssertEqual(firstOutcome.message, "approval unavailable")

        let remaining = await fixture.runtime.approvals.pendingIDs
        XCTAssertEqual(remaining.count, 1)
        let resolved = await fixture.runtime.approvals.resolve(
            approvalId: remaining[0], decision: .allowOnce, digest: secondDigest)
        XCTAssertEqual(resolved, .resolved)
        let secondOutcome = await second.value
        XCTAssertTrue(secondOutcome.allowed, secondOutcome.message ?? "")
        XCTAssertNotEqual(secondDigest, firstDigest)

        let events = try await botEvents(fixture.store)
        let cancelledDecisions = events.filter {
            $0.type == "approval.decided" && $0.data["status"] == .string("cancelled")
        }
        XCTAssertEqual(cancelledDecisions.count, 1)
        XCTAssertEqual(cancelledDecisions.first?.principal.botId, "bot-a")
        XCTAssertEqual(cancelledDecisions.first?.data["reason"], .string("bot_deleted"))

        let notices = events.filter { $0.type == "ui.notice" }
        XCTAssertEqual(notices.count, 1)
        XCTAssertEqual(notices.first?.principal.botId, "bot-a")
        XCTAssertEqual(notices.first?.data["kind"], .string("approval_cancelled"))
        XCTAssertEqual(notices.first?.data["reason"], .string("bot_deleted"))
        XCTAssertEqual(notices.first?.data["text"], .string("Bot 已删除时取消。"))

        let botADecisions = events.filter {
            $0.type == "approval.decided" && $0.principal.botId == "bot-a"
        }
        XCTAssertEqual(botADecisions.count, 1)
        let botBAllowed = events.filter {
            $0.type == "approval.decided" && $0.principal.botId == "bot-b"
                && $0.data["status"] == .string("allowed")
        }
        XCTAssertEqual(botBAllowed.count, 1)

        let again = await fixture.runtime.approvals.cancelAll(
            botID: "bot-a", reason: "bot_deleted")
        XCTAssertEqual(again, 0)
        let remainingAfterRetry = await fixture.runtime.approvals.pendingIDs
        XCTAssertTrue(remainingAfterRetry.isEmpty)
    }

    func testGlobalCancelAllStillCancelsEveryBotsApproval() async throws {
        let fixture = try makeBotMCPFixture()
        defer { fixture.cleanup() }
        try await issueChat(fixture.runtime, botID: "bot-a")
        try await issueChat(fixture.runtime, botID: "bot-b")

        let (first, firstDigest) = try await beginApproval(
            fixture.runtime, botID: "bot-a", callID: "global-a", fact: "alpha")
        let (second, secondDigest) = try await beginApproval(
            fixture.runtime, botID: "bot-b", callID: "global-b", fact: "beta")
        _ = try await waitForPending(fixture.runtime.approvals, 2)
        XCTAssertNotEqual(firstDigest, secondDigest)

        let cancelled = await fixture.runtime.approvals.cancelAll(reason: "worker_restarted")
        XCTAssertEqual(cancelled, 2)
        let firstOutcome = await first.value
        let secondOutcome = await second.value
        XCTAssertFalse(firstOutcome.allowed)
        XCTAssertFalse(secondOutcome.allowed)
        XCTAssertEqual(firstOutcome.message, "approval unavailable")
        XCTAssertEqual(secondOutcome.message, "approval unavailable")
        let remainingAfterGlobalCancel = await fixture.runtime.approvals.pendingIDs
        XCTAssertTrue(remainingAfterGlobalCancel.isEmpty)

        let events = try await botEvents(fixture.store)
        let notices = events.filter { $0.type == "ui.notice" }
        XCTAssertEqual(notices.count, 2)
        XCTAssertEqual(Set(notices.compactMap(\.principal.botId)), Set(["bot-a", "bot-b"]))
        XCTAssertTrue(notices.allSatisfy {
            $0.data["reason"] == .string("worker_restarted")
        })
        XCTAssertTrue(notices.allSatisfy {
            $0.data["text"] == .string("App 重启时取消。")
        }, "\(notices.map(\.data))")
    }
}
