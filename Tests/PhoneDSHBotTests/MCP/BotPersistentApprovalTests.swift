// SPDX-License-Identifier: MIT

import Foundation
import XCTest
@testable import PhoneDSHBot

/// Durable approval semantics from spec/bot/v1 §2.7. The interactive card
/// tests stay in BotApprovalCancelTests; these drive the non-interactive path
/// without a live Worker.
final class BotPersistentApprovalTests: XCTestCase {
    private func forgetArguments(_ fact: String) -> BotJSONValue {
        .object([
            "action": .string("forget"), "scope": .string("user"), "fact": .string(fact),
        ])
    }

    private func issue(_ runtime: BotMCPRuntime, sessionId: String,
                       kind: BotSessionKind) async throws {
        _ = try await runtime.issueSession(botId: "main", sessionId: sessionId, kind: kind)
    }

    private func requestApproval(
        _ runtime: BotMCPRuntime, sessionId: String, callId: String,
        fact: String
    ) async throws -> (digest: String, outcome: BotApprovalOutcome) {
        let args = forgetArguments(fact)
        _ = try await runtime.registerIdentity(
            runtimeId: BotMCPRuntime.defaultRuntimeID, sessionId: sessionId,
            callId: callId, name: "UpdateMemory", arguments: args)
        let digest = try BotArgumentsDigest.string(for: args)
        let outcome = await runtime.approve(
            runtimeId: BotMCPRuntime.defaultRuntimeID, sessionId: sessionId,
            callId: callId, name: "UpdateMemory", action: "Forget a memory",
            detail: "durable approval test", command: "", argsDigest: digest,
            alwaysScope: "until", askAction: "tool-call")
        return (digest, outcome)
    }

    func testRoutineApprovalReturnsPendingImmediatelyAndDoesNotTimeOut() async throws {
        let fixture = try makeBotMCPFixture(
            approvalTimeoutMs: 60,
            approvalExpiryMs: 60_000)
        defer { fixture.cleanup() }
        try await issue(fixture.runtime, sessionId: "gb-routine", kind: .routine)

        let (digest, outcome) = try await requestApproval(
            fixture.runtime, sessionId: "gb-routine", callId: "routine-call", fact: "alpha")
        XCTAssertTrue(outcome.ok, outcome.message ?? "")
        XCTAssertTrue(outcome.pending)
        XCTAssertFalse(outcome.allowed)
        XCTAssertNotNil(outcome.approvalId)

        // Longer than the interactive timeout. A durable todo stays pending and
        // no deny/expiry decision exists yet.
        try await Task.sleep(nanoseconds: 200_000_000)
        let pending = await fixture.runtime.approvals.pendingIDs
        XCTAssertEqual(pending, [outcome.approvalId!])
        let events = try await botEvents(fixture.store)
        XCTAssertFalse(events.contains {
            $0.type == "approval.decided" && $0.data["approvalID"] == .string(outcome.approvalId!)
        })

        let resolved = await fixture.runtime.approvals.resolve(
            approvalId: outcome.approvalId!, decision: .allowOnce, digest: digest)
        XCTAssertEqual(resolved, .resolved)
        let grants = await fixture.runtime.grants.list(botId: "main")
        XCTAssertTrue(grants.contains {
            $0.operation == "memory.forget" && $0.scope == .once && $0.decision == .allow
        })
        let decided = try await botEvents(fixture.store)
        XCTAssertTrue(decided.contains {
            $0.type == "approval.decided"
                && $0.data["approvalID"] == .string(outcome.approvalId!)
                && $0.data["status"] == .string("allowed")
                && $0.data["persistent"] == .bool(true)
        })
    }

    func testInteractiveForegroundApprovalStillTimesOut() async throws {
        let fixture = try makeBotMCPFixture(approvalTimeoutMs: 60)
        defer { fixture.cleanup() }
        try await issue(fixture.runtime, sessionId: "gb-main", kind: .chat)
        await beginUserTurn(fixture.runtime)

        let (_, outcome) = try await requestApproval(
            fixture.runtime, sessionId: "gb-main", callId: "interactive-call", fact: "beta")
        XCTAssertFalse(outcome.allowed)
        XCTAssertFalse(outcome.pending)
        XCTAssertEqual(outcome.message, "approval timed out")
        let remaining = await fixture.runtime.approvals.pendingIDs
        XCTAssertTrue(remaining.isEmpty)
        let events = try await botEvents(fixture.store)
        XCTAssertTrue(events.contains {
            $0.type == "approval.decided"
                && $0.data["approvalID"] == .string(outcome.approvalId ?? "")
                && $0.data["status"] == .string("denied")
                && $0.data["timedOut"] == .bool(true)
        })
    }

    func testDurableApprovalSurvivesWorkerAndProcessRestart() async throws {
        let fixture = try makeBotMCPFixture(approvalExpiryMs: 60_000)
        defer { fixture.cleanup() }
        try await issue(fixture.runtime, sessionId: "gb-routine", kind: .routine)
        let (digest, outcome) = try await requestApproval(
            fixture.runtime, sessionId: "gb-routine", callId: "restart-call", fact: "restart")
        let approvalID = try XCTUnwrap(outcome.approvalId)

        // The replaced process restores the same store. This runtime has no
        // in-memory continuation and no old registration; the todo must still
        // be visible and decidable.
        let restored = BotMCPRuntime(
            store: fixture.store, now: { 1_000 },
            approvalTimeoutMs: 60, approvalExpiryMs: 60_000)
        _ = await fixture.runtime.workerRestarted()
        _ = await restored.workerRestarted()
        let restoredPending = await restored.approvals.pendingIDs
        XCTAssertEqual(restoredPending, [approvalID])
        let state = await restored.approvals.durableStatus(approvalId: approvalID)
        XCTAssertEqual(state, .pending)
        let resolved = await restored.approvals.resolve(
            approvalId: approvalID, decision: .deny, digest: digest)
        XCTAssertEqual(resolved, .resolved)
        let after = await restored.approvals.pendingIDs
        XCTAssertTrue(after.isEmpty)
        let events = try await botEvents(fixture.store)
        XCTAssertTrue(events.contains {
            $0.type == "approval.decided"
                && $0.data["approvalID"] == .string(approvalID)
                && $0.data["status"] == .string("denied")
                && $0.data["reason"] == nil
        })
    }

    func testDurableApprovalExpiresAsDenialAndLateDecisionIsStale() async throws {
        let fixture = try makeBotMCPFixture(approvalExpiryMs: 80)
        defer { fixture.cleanup() }
        try await issue(fixture.runtime, sessionId: "gb-routine", kind: .routine)
        let (digest, outcome) = try await requestApproval(
            fixture.runtime, sessionId: "gb-routine", callId: "expiry-call", fact: "expiry")
        let approvalID = try XCTUnwrap(outcome.approvalId)
        XCTAssertNotNil(outcome.expiresAt)

        for _ in 0..<100 {
            let status = await fixture.runtime.approvals.durableStatus(approvalId: approvalID)
            if status == .expired { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let status = await fixture.runtime.approvals.durableStatus(approvalId: approvalID)
        XCTAssertEqual(status, .expired)
        let resolved = await fixture.runtime.approvals.resolve(
            approvalId: approvalID, decision: .allowOnce, digest: digest)
        XCTAssertEqual(resolved, .stale(reason: "expired"))
        let events = try await botEvents(fixture.store)
        XCTAssertTrue(events.contains {
            $0.type == "approval.decided"
                && $0.data["approvalID"] == .string(approvalID)
                && $0.data["status"] == .string("expired")
                && $0.data["reason"] == .string("approval_expired")
                && $0.data["timedOut"] == .bool(false)
        })
        let grants = await fixture.runtime.grants.list(botId: "main")
        XCTAssertFalse(grants.contains { $0.operation == "memory.forget" })
    }

    func testLegacyPendingRequestWithoutPersistentFlagIsClosedOnRestore() async throws {
        let fixture = try makeBotMCPFixture()
        defer { fixture.cleanup() }
        try await issue(fixture.runtime, sessionId: "gb-main", kind: .chat)
        try await fixture.runtime.eventWriter.append(
            type: "approval.requested",
            principal: try await fixture.runtime.gateway.tokens.lookupSession("gb-main")
                ?? BotGatewayPrincipal(
                    botId: "main", sessionId: "gb-main", kind: .chat,
                    expiresAt: Int64.max, incarnation: "legacy"),
            data: .object([
                "approvalID": .string("approval-legacy"), "status": .string("pending"),
                "action": .string("legacy"), "digest": .string("legacy"),
            ]))
        let restored = BotMCPRuntime(store: fixture.store, now: { 1_000 })
        _ = await restored.workerRestarted()
        let events = try await botEvents(fixture.store)
        XCTAssertTrue(events.contains {
            $0.type == "approval.decided"
                && $0.data["approvalID"] == .string("approval-legacy")
                && $0.data["status"] == .string("cancelled")
                && $0.data["reason"] == .string("worker_restarted")
        })
        XCTAssertTrue(events.contains {
            $0.type == "ui.notice"
                && $0.data["approvalID"] == .string("approval-legacy")
                && $0.data["text"] == .string("App 重启时取消。")
        })
        let pending = await restored.approvals.pendingIDs
        XCTAssertTrue(pending.isEmpty)
    }
}
