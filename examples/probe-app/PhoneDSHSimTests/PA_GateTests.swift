// SPDX-License-Identifier: MIT

import Foundation
import ProbeKit
import XCTest

final class PA_GateTests: XCTestCase {
    func testReadAndValidWriteUseRealGateAndCanonicalDigest() async throws {
        let gate = try DefaultWriteGate(root: paTemporaryRoot(), now: { paFixedDate })
        let read = await gate.authorize(tool: paTool(effect: .read, action: .read), argumentsJSON: "{}",
                                        caller: .dshDirect, grant: paGrant())
        guard case .allow = read else { return XCTFail("只读调用应放行：\(read)") }

        let arguments = paReplyArguments(evidence: nil)
        let write = await gate.authorize(tool: paTool(), argumentsJSON: arguments,
                                         caller: .personalAgent(mandate: paMandate()), grant: paGrant())
        guard case let .allow(intent) = write else { return XCTFail("合法写入应放行：\(write)") }
        XCTAssertEqual(intent.digest.count, 64)
        XCTAssertEqual(intent.argumentsJSON, arguments)

        let structured = await gate.authorize(
            tool: paTool(), argumentsJSON: arguments,
            caller: .personalAgent(mandate: paMandate(origin: .structuredFilter)), grant: paGrant())
        guard case .allow = structured else { return XCTFail("结构化条件目标应允许范围内写入：\(structured)") }
    }

    func testGrantDenialBranches() async throws {
        let gate = try DefaultWriteGate(root: paTemporaryRoot(), now: { paFixedDate })
        let caller = ToolCaller.personalAgent(mandate: paMandate())
        let paused = await gate.authorize(tool: paTool(), argumentsJSON: paReplyArguments(),
                                          caller: caller, grant: paGrant(paused: true))
        XCTAssertEqual(paDenial(paused)?.code, "grant_paused")

        let mismatch = await gate.authorize(tool: paTool(), argumentsJSON: paReplyArguments(),
                                            caller: caller, grant: paGrant(connectorID: "github"))
        XCTAssertEqual(paDenial(mismatch)?.code, "grant_mismatch")

        let notGranted = await gate.authorize(tool: paTool(), argumentsJSON: paReplyArguments(),
                                              caller: caller, grant: paGrant(actions: [.read]))
        XCTAssertEqual(paDenial(notGranted)?.code, "action_not_granted")

        let unmapped = await gate.authorize(tool: paTool(action: nil), argumentsJSON: paReplyArguments(),
                                            caller: caller, grant: paGrant())
        XCTAssertEqual(paDenial(unmapped)?.code, "unmapped_write_action")
    }

    func testMandateActionExpiryOriginAndMalformedArgumentsFailClosed() async throws {
        let gate = try DefaultWriteGate(root: paTemporaryRoot(), now: { paFixedDate })
        let notInMandate = await gate.authorize(
            tool: paTool(), argumentsJSON: paReplyArguments(),
            caller: .personalAgent(mandate: paMandate(actions: [.read])), grant: paGrant())
        XCTAssertEqual(paDenial(notInMandate)?.code, "action_not_in_mandate")

        let expired = await gate.authorize(
            tool: paTool(), argumentsJSON: paReplyArguments(),
            caller: .personalAgent(mandate: paMandate(validUntil: paFixedDate)), grant: paGrant())
        XCTAssertEqual(paDenial(expired)?.code, "mandate_expired")

        let inferred = await gate.authorize(
            tool: paTool(), argumentsJSON: paReplyArguments(),
            caller: .personalAgent(mandate: paMandate(origin: .modelInferred)), grant: paGrant())
        guard case .requireTargetSelection = inferred else { return XCTFail("模型推断目标不能自动写") }

        let malformed = await gate.authorize(tool: paTool(), argumentsJSON: "not-json",
                                             caller: .personalAgent(mandate: paMandate()), grant: paGrant())
        XCTAssertEqual(paDenial(malformed)?.code, "invalid_arguments")
    }

    func testGitHubRepositoryAndIssueMustMatchMandateAndGrant() async throws {
        let gate = try DefaultWriteGate(root: paTemporaryRoot(), now: { paFixedDate })
        let tool = paTool(name: "github.issue.comment", connectorID: "github", effect: .write, action: .githubComment)
        let mandate = paMandate(actions: [.read, .githubComment])
        let grant = paGrant(connectorID: "github")
        let wrongRepo = await gate.authorize(tool: tool, argumentsJSON: paGitHubArguments(repository: "octo/other"),
                                             caller: .personalAgent(mandate: mandate), grant: grant)
        XCTAssertEqual(paDenial(wrongRepo)?.code, "repository_outside_mandate")
        let wrongIssue = await gate.authorize(tool: tool, argumentsJSON: paGitHubArguments(number: 2),
                                              caller: .personalAgent(mandate: mandate), grant: grant)
        XCTAssertEqual(paDenial(wrongIssue)?.code, "issue_outside_mandate")
        let outsideGrant = await gate.authorize(tool: tool, argumentsJSON: paGitHubArguments(),
                                                caller: .personalAgent(mandate: mandate),
                                                grant: paGrant(connectorID: "github", repositories: ["octo/allowed"]))
        XCTAssertEqual(paDenial(outsideGrant)?.code, "repository_outside_mandate")
    }

    func testGmailRecipientsThreadsEvidenceAndAttachmentsAreVerified() async throws {
        let root = paTemporaryRoot()
        let gate = try DefaultWriteGate(root: root, now: { paFixedDate })
        let caller = ToolCaller.personalAgent(mandate: paMandate())
        let wrongRecipient = await gate.authorize(
            tool: paTool(), argumentsJSON: paReplyArguments(recipients: ["attacker@example.com"]),
            caller: caller, grant: paGrant())
        XCTAssertEqual(paDenial(wrongRecipient)?.code, "recipient_outside_mandate")

        let wrongThread = await gate.authorize(tool: paTool(), argumentsJSON: paReplyArguments(thread: "attacker-thread"),
                                               caller: caller, grant: paGrant())
        XCTAssertEqual(paDenial(wrongThread)?.code, "thread_outside_mandate")

        let tooMany = await gate.authorize(
            tool: paTool(), argumentsJSON: paReplyArguments(recipients: ["alice@example.com"]),
            caller: caller, grant: paGrant(maxRecipients: 0))
        XCTAssertEqual(paDenial(tooMany)?.code, "recipient_outside_mandate")

        let attachment = await gate.authorize(
            tool: paTool(), argumentsJSON: paReplyArguments(attachmentBytes: 1_001),
            caller: caller, grant: paGrant())
        XCTAssertEqual(paDenial(attachment)?.code, "attachment_limit_exceeded")

        let allowedEvidence = EvidenceRef(id: "thread-safe", kind: "gmail", locator: "gmail://thread-safe")
        let outsideEvidence = EvidenceRef(id: "memory-secret", kind: "memory", locator: "memory://secret")
        let evidenceMandate = paMandate(evidence: [allowedEvidence])
        let evidenceDecision = await gate.authorize(
            tool: paTool(),
            argumentsJSON: #"{"threadID":"thread-safe","recipients":["alice@example.com"],"evidenceRefs":[{"id":"memory-secret","kind":"memory","locator":"memory://secret"}]}"#,
            caller: .personalAgent(mandate: evidenceMandate), grant: paGrant())
        XCTAssertEqual(paDenial(evidenceDecision)?.code, "evidence_outside_mandate")
        XCTAssertEqual(outsideEvidence.kind, "memory")

        let audited = await gate.authorize(
            tool: paTool(), argumentsJSON: paReplyArguments(evidence: ["thread-safe"]),
            caller: .personalAgent(mandate: evidenceMandate), grant: paGrant())
        guard case let .allow(intent) = audited else { return XCTFail("允许的证据应通过：\(audited)") }
        let audits = try EvidenceAuditStore(root: root)
        let records = await audits.all()
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.operationID, intent.id)
        XCTAssertEqual(records.first?.evidenceRefs, [allowedEvidence])
    }

    func testDeviceSourceDefaultsToReadOnlyUnlessExplicitlyEnabled() async throws {
        let deviceMandate = paMandate(source: .device)
        let deniedGate = try DefaultWriteGate(root: paTemporaryRoot(), now: { paFixedDate })
        let denied = await deniedGate.authorize(tool: paTool(), argumentsJSON: paReplyArguments(),
                                                caller: .personalAgent(mandate: deviceMandate), grant: paGrant())
        XCTAssertEqual(paDenial(denied)?.code, "device_external_write_disabled")

        let enabledGate = try DefaultWriteGate(root: paTemporaryRoot(), deviceExternalWritePrincipals: ["user"],
                                               now: { paFixedDate })
        let allowed = await enabledGate.authorize(tool: paTool(), argumentsJSON: paReplyArguments(),
                                                  caller: .personalAgent(mandate: deviceMandate), grant: paGrant())
        guard case .allow = allowed else { return XCTFail("显式开启 externalWrite 后应通过：\(allowed)") }
    }

    func testDSHDirectWriteRequiresApprovalAndDoesNotInheritChatGrant() async throws {
        let gate = try DefaultWriteGate(root: paTemporaryRoot(), now: { paFixedDate })
        let decision = await gate.authorize(tool: paTool(), argumentsJSON: paReplyArguments(),
                                            caller: .dshDirect, grant: paGrant())
        XCTAssertEqual(decision, .requireDSHApproval)
    }
}
