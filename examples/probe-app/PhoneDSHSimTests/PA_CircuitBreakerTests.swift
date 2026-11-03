// SPDX-License-Identifier: MIT

import Foundation
import ProbeKit
import XCTest

final class PA_CircuitBreakerTests: XCTestCase {
    func testRateLimitTripsBeforeAnotherWrite() async throws {
        let root = paTemporaryRoot()
        let breaker = try CircuitBreaker(root: root)
        let grant = paGrant(maxOperations: 1)
        try await breaker.recordOperation(connectorID: "gmail", at: paFixedDate)
        let gate = DefaultWriteGate(tokens: nil, breaker: breaker,
                                    evidenceAudits: try EvidenceAuditStore(root: root), now: { paFixedDate })
        let decision = await gate.authorize(tool: paTool(), argumentsJSON: paReplyArguments(),
                                            caller: .personalAgent(mandate: paMandate()), grant: grant)
        XCTAssertEqual(paDenial(decision)?.code, "rate_limit_exceeded")
    }

    func testTargetAndRecipientOutsideMandateTripIndependently() async throws {
        let gate = try DefaultWriteGate(root: paTemporaryRoot(), now: { paFixedDate })
        let recipient = await gate.authorize(
            tool: paTool(), argumentsJSON: paReplyArguments(recipients: ["attacker@example.com"]),
            caller: .personalAgent(mandate: paMandate()), grant: paGrant())
        XCTAssertEqual(paDenial(recipient)?.code, "recipient_outside_mandate")

        let githubTool = paTool(name: "github.issue.comment", connectorID: "github",
                                effect: .write, action: .githubComment)
        let target = await gate.authorize(
            tool: githubTool, argumentsJSON: paGitHubArguments(repository: "attacker/repo"),
            caller: .personalAgent(mandate: paMandate(actions: [.read, .githubComment])),
            grant: paGrant(connectorID: "github"))
        XCTAssertEqual(paDenial(target)?.code, "repository_outside_mandate")
    }

    func testAttachmentLimitTrips() async throws {
        let gate = try DefaultWriteGate(root: paTemporaryRoot(), now: { paFixedDate })
        let decision = await gate.authorize(
            tool: paTool(), argumentsJSON: paReplyArguments(attachmentBytes: 100_000),
            caller: .personalAgent(mandate: paMandate()), grant: paGrant())
        XCTAssertEqual(paDenial(decision)?.code, "attachment_limit_exceeded")
    }

    func testThreeConsecutiveProviderFailuresTripAndSuccessResets() async throws {
        let root = paTemporaryRoot()
        let breaker = try CircuitBreaker(root: root)
        for _ in 0..<3 { try await breaker.recordProviderFailure(connectorID: "gmail") }
        let gate = DefaultWriteGate(tokens: nil, breaker: breaker,
                                    evidenceAudits: try EvidenceAuditStore(root: root), now: { paFixedDate })
        let denied = await gate.authorize(tool: paTool(), argumentsJSON: paReplyArguments(),
                                          caller: .personalAgent(mandate: paMandate()), grant: paGrant())
        XCTAssertEqual(paDenial(denied)?.code, "provider_failure_breaker")
        try await breaker.recordProviderSuccess(connectorID: "gmail")
        let allowed = await gate.authorize(tool: paTool(), argumentsJSON: paReplyArguments(),
                                           caller: .personalAgent(mandate: paMandate()), grant: paGrant())
        guard case .allow = allowed else { return XCTFail("恢复后应放行：\(allowed)") }
    }

    func testPausedExpiredAndRevokedGrantsTrip() async throws {
        let root = paTemporaryRoot()
        let breaker = try CircuitBreaker(root: root)
        let gate = DefaultWriteGate(tokens: nil, breaker: breaker,
                                    evidenceAudits: try EvidenceAuditStore(root: root), now: { paFixedDate })
        let caller = ToolCaller.personalAgent(mandate: paMandate())
        let paused = await gate.authorize(tool: paTool(), argumentsJSON: paReplyArguments(),
                                          caller: caller, grant: paGrant(paused: true))
        XCTAssertEqual(paDenial(paused)?.code, "grant_paused")
        let expired = await gate.authorize(tool: paTool(), argumentsJSON: paReplyArguments(),
                                           caller: caller, grant: paGrant(version: 0))
        XCTAssertEqual(paDenial(expired)?.code, "grant_expired_or_revoked")
        try await breaker.revoke(connectorID: "gmail")
        let revoked = await gate.authorize(tool: paTool(), argumentsJSON: paReplyArguments(),
                                           caller: caller, grant: paGrant())
        XCTAssertEqual(paDenial(revoked)?.code, "grant_expired_or_revoked")
        let revokedRead = await gate.authorize(tool: paTool(effect: .read, action: .read), argumentsJSON: "{}",
                                               caller: caller, grant: paGrant())
        XCTAssertEqual(paDenial(revokedRead)?.code, "grant_expired_or_revoked")
    }

    func testUnknownOperationBlocksUntilReconciled() async throws {
        let root = paTemporaryRoot()
        let breaker = try CircuitBreaker(root: root)
        let id = UUID()
        try await breaker.setUnknown(connectorID: "gmail", operationID: id, isUnknown: true)
        let gate = DefaultWriteGate(tokens: nil, breaker: breaker,
                                    evidenceAudits: try EvidenceAuditStore(root: root), now: { paFixedDate })
        let caller = ToolCaller.personalAgent(mandate: paMandate())
        let denied = await gate.authorize(tool: paTool(), argumentsJSON: paReplyArguments(),
                                          caller: caller, grant: paGrant())
        XCTAssertEqual(paDenial(denied)?.code, "unknown_operation_pending")
        try await breaker.setUnknown(connectorID: "gmail", operationID: id, isUnknown: false)
        let allowed = await gate.authorize(tool: paTool(), argumentsJSON: paReplyArguments(),
                                           caller: caller, grant: paGrant())
        guard case .allow = allowed else { return XCTFail("对账完成后应放行：\(allowed)") }
    }
}
