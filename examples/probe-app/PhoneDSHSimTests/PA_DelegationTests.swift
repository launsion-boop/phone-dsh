// SPDX-License-Identifier: MIT

import Foundation
import ProbeKit
import XCTest

final class PA_DelegationTests: XCTestCase {
    func testExpiredChangedGrantAndOutOfScopeTokensAreRejected() async throws {
        let root = paTemporaryRoot()
        let tokens = try MandateTokenStore(root: root)
        let breaker = try CircuitBreaker(root: root)
        let gate = DefaultWriteGate(tokens: tokens, breaker: breaker,
                                    evidenceAudits: try EvidenceAuditStore(root: root), now: { paFixedDate })
        let tool = paTool(name: "github.issue.comment", connectorID: "github", effect: .write, action: .githubComment)
        let mandate = paMandate(actions: [.read, .githubComment])
        let grant = paGrant(connectorID: "github")

        let expired = try await tokens.issue(mandate: mandate, grant: grant, validFor: 1,
                                             now: paFixedDate.addingTimeInterval(-10))
        let expiredDecision = await gate.authorize(tool: tool, argumentsJSON: paGitHubArguments(),
                                                   caller: .delegatedDSH(mandateToken: expired), grant: grant)
        XCTAssertEqual(paDenial(expiredDecision)?.code, "mandate_token_invalid")

        let changedGrantToken = try await tokens.issue(mandate: mandate, grant: grant, now: paFixedDate)
        let changed = await gate.authorize(tool: tool, argumentsJSON: paGitHubArguments(),
                                           caller: .delegatedDSH(mandateToken: changedGrantToken),
                                           grant: paGrant(connectorID: "github", version: 2))
        XCTAssertEqual(paDenial(changed)?.code, "mandate_token_invalid")

        let token = try await tokens.issue(mandate: mandate, grant: grant, now: paFixedDate)
        let outside = await gate.authorize(tool: tool, argumentsJSON: paGitHubArguments(repository: "attacker/repo"),
                                           caller: .delegatedDSH(mandateToken: token), grant: grant)
        XCTAssertEqual(paDenial(outside)?.code, "repository_outside_mandate")

        let allowed = await gate.authorize(tool: tool, argumentsJSON: paGitHubArguments(),
                                           caller: .delegatedDSH(mandateToken: token), grant: grant)
        guard case .allow = allowed else { return XCTFail("范围内 token 应放行一次：\(allowed)") }
        let replay = await gate.authorize(tool: tool, argumentsJSON: paGitHubArguments(),
                                          caller: .delegatedDSH(mandateToken: token), grant: grant)
        XCTAssertEqual(paDenial(replay)?.code, "mandate_token_invalid")
    }

    func testReadTokenIsAlsoSingleUse() async throws {
        let root = paTemporaryRoot()
        let tokens = try MandateTokenStore(root: root)
        let gate = DefaultWriteGate(tokens: tokens, breaker: try CircuitBreaker(root: root),
                                    evidenceAudits: try EvidenceAuditStore(root: root), now: { paFixedDate })
        let mandate = paMandate(actions: [.read])
        let token = try await tokens.issue(mandate: mandate, grant: paGrant(), now: paFixedDate)
        let tool = paTool(name: "gmail.search", effect: .read, action: .read)
        let first = await gate.authorize(tool: tool, argumentsJSON: "{}",
                                         caller: .delegatedDSH(mandateToken: token), grant: paGrant())
        guard case .allow = first else { return XCTFail("首次只读委派应放行：\(first)") }
        let replay = await gate.authorize(tool: tool, argumentsJSON: "{}",
                                          caller: .delegatedDSH(mandateToken: token), grant: paGrant())
        XCTAssertEqual(paDenial(replay)?.code, "mandate_token_invalid")
    }

    func testL2UpgradeToL3ReusesOwnerAndCompletedStepsWithoutRepeatingExecution() async throws {
        let root = paTemporaryRoot()
        let adapter = try DSHTaskAdapter(tokens: MandateTokenStore(root: root), root: root, now: { paFixedDate })
        let mandate = paMandate(actions: [.read])
        let grant = paGrant(actions: [.read, .githubPush], connectorID: "github")
        let requestID = UUID()
        let calls = PACounter()
        let first = try await adapter.delegate(owner: "personal-agent", requestID: requestID,
                                               mandate: mandate, grant: grant, dshSessionID: "dsh-1",
                                               completedSteps: ["read-pr"]) { delegation in
            XCTAssertTrue(delegation.prompt.contains("read-pr"))
            XCTAssertNotNil(delegation.mandateToken)
            await calls.increment()
            return ["create-branch"]
        }
        XCTAssertFalse(first.reused)
        XCTAssertEqual(first.record.permissions.allowedActions, [.read])
        XCTAssertTrue(first.record.permissions.repositories.contains("octo/repo"))
        XCTAssertEqual(first.record.completedStepIDs, ["create-branch", "read-pr"])

        let second = try await adapter.delegate(owner: "personal-agent", requestID: requestID,
                                                mandate: mandate, grant: grant, dshSessionID: "dsh-1") { _ in
            await calls.increment()
            return ["duplicate"]
        }
        XCTAssertTrue(second.reused)
        XCTAssertEqual(second.record.taskRunID, first.record.taskRunID)
        paAssertEqual(await calls.value, 1)
        do {
            _ = try await adapter.delegate(owner: "attacker", requestID: requestID, mandate: mandate,
                                           grant: grant, dshSessionID: "dsh-2")
            XCTFail("同一 requestID 不允许第二个 owner")
        } catch {
            XCTAssertEqual(error as? DSHTaskAdapterError, .ownerConflict(requestID))
        }
    }

    func testDSHDirectWriteRequiresApproval() async throws {
        let gate = try DefaultWriteGate(root: paTemporaryRoot(), now: { paFixedDate })
        let decision = await gate.authorize(tool: paTool(), argumentsJSON: paReplyArguments(),
                                            caller: .dshDirect, grant: paGrant())
        XCTAssertEqual(decision, .requireDSHApproval)
    }

    func testDSHAttentionContainsOnlyApprovalUnknownAndFailedRecoveryItems() async throws {
        let source = DSHAttentionSource()
        var iterator = source.items().makeAsyncIterator()
        paAssertEqual(await iterator.next()?.count, 0)
        let approvalID = UUID()
        await source.recordApproval(id: approvalID, toolName: "gmail.message.reply",
                                    sessionID: "dsh-1", origin: .direct)
        paAssertEqual(await iterator.next()?.first?.id, approvalID)

        let unknown = OperationRecord(intent: paIntent(digest: "unknown"), phase: .unknown,
                                      failureReason: "等待对账")
        let failed = OperationRecord(intent: paIntent(digest: "failed"), phase: .failed,
                                     failureReason: "等待恢复")
        let committed = OperationRecord(intent: paIntent(digest: "committed"), phase: .committed)
        await source.synchronize(operations: [
            DSHOperationAttention(operation: unknown, origin: .delegated(requestID: UUID()), sessionID: "dsh-2"),
            DSHOperationAttention(operation: failed, origin: .direct, sessionID: "dsh-1"),
            DSHOperationAttention(operation: committed, origin: .direct, sessionID: "dsh-1"),
        ])
        let items = await source.currentItems()
        XCTAssertEqual(Set(items.map(\.id)), Set([approvalID, unknown.id, failed.id]))
        XCTAssertTrue(items.allSatisfy { $0.route == .dsh(sessionID: "dsh-1", approvalID: nil)
            || $0.route == .dsh(sessionID: "dsh-2", approvalID: nil)
            || $0.route == .dsh(sessionID: "dsh-1", approvalID: approvalID.uuidString) })
        await source.resolve(id: approvalID)
        paAssertNil(await source.currentItems().first(where: { $0.id == approvalID }))
    }
}
