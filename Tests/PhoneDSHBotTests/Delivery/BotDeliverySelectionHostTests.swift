// SPDX-License-Identifier: MIT

import Foundation
import XCTest
@testable import PhoneDSHBot

/// D A04: the host-side selection chain runs on the real store, the real
/// workspace material service and the shared row projector. No hand-written
/// UI row stands in for the producer.
final class BotDeliverySelectionHostTests: XCTestCase {
    private let now: Int64 = 1_794_801_600_000

    // MARK: - Producer and durable binding

    func testProducerBuildsWorkspaceCandidatesAndSelectionBindsNextRevision() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanup() }
        let offer = try requireValue(await fixture.offer(botID: "main", approvalID: "approval-main",
                                                      sessionID: "gb-main"))
        XCTAssertEqual(offer.draft.revision, 1)
        XCTAssertEqual(offer.draft.resources.count, 2)
        XCTAssertTrue(offer.draft.selectedIDs.isEmpty)
        XCTAssertEqual(offer.draft.parameters.map(\.label), ["动作", "说明"])

        try await fixture.appendApproval(offer, action: "发送周报给张三",
                                         detail: "给张三的周报", botID: "main",
                                         sessionID: "gb-main")
        let before = try await fixture.rows(botID: "main")
        XCTAssertEqual(before.count, 1)
        XCTAssertEqual(before[0].body["delivery"]?["revision"]?.intValue, 1)
        XCTAssertEqual(before[0].body["status"]?.stringValue, "pending")

        let r1 = try XCTUnwrap(offer.draft.resources.first?.id)
        let result = await fixture.apply(
            nonce: "n1", botID: "main", rowID: before[0].id,
            draftID: offer.draft.draftID, expectedRevision: 1, selected: [r1])
        guard case .accepted(let eventID, let draft) = result else {
            return XCTFail("selection should be accepted: \(result)")
        }
        XCTAssertEqual(draft.revision, 2)
        XCTAssertEqual(draft.selectedIDs, [r1])
        XCTAssertTrue(eventID.hasPrefix("delivery-selection:"))
        XCTAssertNotEqual(draft.digest, offer.draft.digest)

        // Same durable approval row, next revision and digest: this is the
        // shared projector, not a second row store.
        let after = try await fixture.rows(botID: "main")
        XCTAssertEqual(after.count, 1, "selection must update the same row")
        XCTAssertEqual(after[0].id, before[0].id)
        XCTAssertEqual(after[0].body["delivery"]?["revision"]?.intValue, 2)
        XCTAssertEqual(after[0].body["digest"]?.stringValue, draft.digest)
        XCTAssertEqual(after[0].body["status"]?.stringValue, "pending")
        let resources = try XCTUnwrap(after[0].body["delivery"]?["resources"]?.arrayValue)
        let selectedResource = try XCTUnwrap(resources.first {
            $0["id"]?.stringValue == r1
        })
        XCTAssertEqual(selectedResource["selected"]?.boolValue, true)
    }

    func testProducerCarriesSourceVersionAndHumanVersionLabel() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanup() }
        let offer = try requireValue(await fixture.offer(botID: "main", approvalID: "approval-version",
                                                      sessionID: "gb-main"))
        let resource = try XCTUnwrap(offer.draft.resources.first {
            $0.workspacePath == "docs/guide.md"
        })
        XCTAssertEqual(resource.state, .current)
        XCTAssertEqual(resource.source.trust, "observation")
        XCTAssertEqual(resource.source.kind, "file")
        XCTAssertTrue(resource.source.ref.hasPrefix("workspace:"))
        XCTAssertNotNil(resource.source.observedAtMS)
        XCTAssertNotNil(resource.source.versionLabel)
        let version = try XCTUnwrap(resource.source.sourceVersion?.knownValue)
        XCTAssertEqual(version, WorkspaceDecisionContextService.workspaceDigest(
            fromRef: resource.source.ref))
        XCTAssertEqual(resource.workspacePath, "docs/guide.md")
    }

    func testDigestMatchesG2Golden() {
        let parameters = [
            BotDeliverySelectionParameter(label: "收件人", value: "张三"),
            BotDeliverySelectionParameter(label: "主题", value: "周报"),
        ]
        XCTAssertEqual(
            BotDeliverySelectionDigest.approvalDigest(
                draftID: "draft-1", revision: 3,
                selectedResourceIDs: ["r1"], parameters: parameters),
            "sha256:34bb49134465e38e88ba891e590e0fa01692431bbb559fae031274fa97c1f856")
    }

    // MARK: - Idempotency / remove all / history

    func testDuplicateSubmissionIsIdempotentAndHistoryStaysReadable() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanup() }
        let offer = try requireValue(await fixture.offer(botID: "main", approvalID: "approval-dup",
                                                      sessionID: "gb-main"))
        let event = try await fixture.appendApproval(offer, action: "发送资料", detail: "",
                                                     botID: "main", sessionID: "gb-main")
        let rowID = "e-main-approval-\(offer.draft.approvalID)"
        let r1 = try XCTUnwrap(offer.draft.resources.first?.id)
        let first = await fixture.apply(nonce: "dup-1", botID: "main", rowID: rowID,
                                        draftID: offer.draft.draftID, expectedRevision: 1,
                                        selected: [r1])
        guard case .accepted = first else { return XCTFail("first submit: \(first)") }
        let countAfterFirst = try await fixture.store.events(after: 0, limit: 1_000).count

        let second = await fixture.apply(nonce: "dup-1", botID: "main", rowID: rowID,
                                         draftID: offer.draft.draftID, expectedRevision: 1,
                                         selected: [r1])
        guard case .duplicate(let eventID, let draft) = second else {
            return XCTFail("same nonce must be a duplicate: \(second)")
        }
        XCTAssertEqual(eventID, "delivery-selection:dup-1")
        XCTAssertEqual(draft.revision, 2)
        let countAfterSecond = try await fixture.store.events(after: 0, limit: 1_000).count
        XCTAssertEqual(countAfterFirst, countAfterSecond, "duplicate must not write")

        let removed = await fixture.apply(nonce: "dup-2", botID: "main", rowID: rowID,
                                          draftID: offer.draft.draftID, expectedRevision: 2,
                                          selected: [])
        guard case .accepted(let removeID, let emptyDraft) = removed else {
            return XCTFail("remove all: \(removed)")
        }
        XCTAssertEqual(emptyDraft.revision, 3)
        XCTAssertTrue(emptyDraft.selectedIDs.isEmpty)
        XCTAssertEqual(removeID, "delivery-selection:dup-2")
        let history = try await fixture.host.drafts(botID: "main")
        XCTAssertEqual(history.first?.revision, 3)

        // The first selection event is still a readable historical revision.
        let events = try await fixture.store.events(after: 0, limit: 1_000)
        let revisions = events.compactMap { event -> Int? in
            guard event.type == "approval.requested",
                  event.data["deliverySelection"]?.boolValue == true else { return nil }
            return event.data["delivery"]?["revision"]?.intValue
        }
        XCTAssertEqual(revisions, [2, 3])
        XCTAssertEqual(event.eventId, "approval-request-\(offer.draft.approvalID)")
    }

    func testStaleRevisionAndUnknownResourceAreRejected() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanup() }
        let offer = try requireValue(await fixture.offer(botID: "main", approvalID: "approval-stale",
                                                      sessionID: "gb-main"))
        try await fixture.appendApproval(offer, action: "发送资料", detail: "",
                                         botID: "main", sessionID: "gb-main")
        let rowID = "e-main-approval-approval-stale"
        let stale = await fixture.apply(nonce: "stale-1", botID: "main", rowID: rowID,
                                        draftID: offer.draft.draftID, expectedRevision: 0,
                                        selected: [])
        guard case .stale(let reason) = stale else {
            return XCTFail("stale revision should fail: \(stale)")
        }
        XCTAssertEqual(reason, "draft_revision_mismatch")
        let unknown = await fixture.apply(nonce: "stale-2", botID: "main", rowID: rowID,
                                          draftID: offer.draft.draftID, expectedRevision: 1,
                                          selected: ["missing"])
        if case .stale = unknown {
            // thrown errors are checked below through the throwing variant
        } else {
            XCTFail("unknown resource must not be accepted: \(unknown)")
        }
    }

    // MARK: - Source recheck before confirmation

    func testRevokedSourceCannotBeSelected() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanup() }
        await fixture.modeBox.set(.revoked)
        let offer = try requireValue(await fixture.offer(
            botID: "main", approvalID: "approval-revoked", sessionID: "gb-main"))
        try await fixture.appendApproval(offer, action: "发送资料", detail: "",
                                         botID: "main", sessionID: "gb-main")
        let rowID = "e-main-approval-approval-revoked"
        let r1 = try XCTUnwrap(offer.draft.resources.first?.id)
        do {
            _ = try await fixture.host.apply(
                BotDeliverySelectionSubmission(
                    nonce: "revoked-1", botID: "main", rowID: rowID,
                    draftID: offer.draft.draftID, expectedRevision: 1,
                    selectedResourceIDs: [r1]))
            XCTFail("revoked resource must be rejected")
        } catch let failure as BotDeliverySelectionFailure {
            XCTAssertEqual(failure, .resourceUnavailable(r1))
        }
    }

    func testChangedSourceNeedsReconfirmationAtExecution() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanup() }
        let offer = try requireValue(await fixture.offer(botID: "main", approvalID: "approval-changed",
                                                      sessionID: "gb-main"))
        try await fixture.appendApproval(offer, action: "发送资料", detail: "",
                                         botID: "main", sessionID: "gb-main")
        let rowID = "e-main-approval-approval-changed"
        let r1 = try XCTUnwrap(offer.draft.resources.first {
            $0.workspacePath == "docs/guide.md"
        }?.id)
        let result = await fixture.apply(nonce: "changed-1", botID: "main", rowID: rowID,
                                         draftID: offer.draft.draftID, expectedRevision: 1,
                                         selected: [r1])
        guard case .accepted = result else { return XCTFail("selection: \(result)") }
        try await fixture.appendDecision(approvalID: offer.draft.approvalID, status: "allowed",
                                         botID: "main", sessionID: "gb-main")
        try fixture.write("docs/guide.md", content: "a newer guide", botID: "main")

        let confirmation = try await fixture.host.confirm(
            name: "show_attachment",
            arguments: .object(["path": .string("docs/guide.md")]),
            botID: "main", sessionID: "gb-main", nowMS: now)
        guard case .rejected(let code, _) = confirmation else {
            return XCTFail("changed source must be refused at execution: \(confirmation)")
        }
        XCTAssertEqual(code, "delivery_source_changed")
    }

    func testRevokedBeforeConfirmationIsRefused() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanup() }
        let offer = try requireValue(await fixture.offer(
            botID: "main", approvalID: "approval-revoked-exec", sessionID: "gb-main"))
        try await fixture.appendApproval(offer, action: "发送资料", detail: "",
                                         botID: "main", sessionID: "gb-main")
        let rowID = "e-main-approval-approval-revoked-exec"
        let r1 = try XCTUnwrap(offer.draft.resources.first {
            $0.workspacePath == "docs/guide.md"
        }?.id)
        let result = await fixture.apply(nonce: "revoked-exec-1", botID: "main",
                                         rowID: rowID,
                                         draftID: offer.draft.draftID,
                                         expectedRevision: 1, selected: [r1])
        guard case .accepted = result else { return XCTFail("selection: \(result)") }
        // The user selected while the source was readable; the grant is
        // revoked before the approval decision and the send.
        await fixture.modeBox.set(.revoked)
        try await fixture.appendDecision(approvalID: offer.draft.approvalID,
                                         status: "allowed", botID: "main",
                                         sessionID: "gb-main")
        let revokedDraft = try await fixture.host.drafts(botID: "main").first
        XCTAssertEqual(revokedDraft?.selectedResources.map(\.workspacePath),
                       ["docs/guide.md"], "selected resource before confirm")
        let confirmation = try await fixture.host.confirm(
            name: "show_attachment",
            arguments: .object(["path": .string("docs/guide.md")]),
            botID: "main", sessionID: "gb-main", nowMS: now)
        guard case .rejected(let code, _) = confirmation else {
            return XCTFail("revoked source must be refused: \(confirmation)")
        }
        XCTAssertEqual(code, "delivery_source_revoked")
    }

    func testExpiredApprovalIsRefused() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanup() }
        let offer = try requireValue(await fixture.offer(botID: "main", approvalID: "approval-expired",
                                                      sessionID: "gb-main"))
        try await fixture.appendApproval(offer, action: "发送资料", detail: "",
                                         botID: "main", sessionID: "gb-main",
                                         expiresAt: now - 1)
        let rowID = "e-main-approval-approval-expired"
        let r1 = try XCTUnwrap(offer.draft.resources.first?.id)
        do {
            _ = try await fixture.host.apply(
                BotDeliverySelectionSubmission(
                    nonce: "expired-1", botID: "main", rowID: rowID,
                    draftID: offer.draft.draftID, expectedRevision: 1,
                    selectedResourceIDs: [r1]),
                nowMS: now)
            XCTFail("expired approval must be rejected")
        } catch let failure as BotDeliverySelectionFailure {
            XCTAssertEqual(failure, .approvalExpired)
        }
    }

    // MARK: - Execution point

    func testExecutionUsesOnlySelectedResources() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanup() }
        let offer = try requireValue(await fixture.offer(botID: "main", approvalID: "approval-exec",
                                                      sessionID: "gb-main"))
        try await fixture.appendApproval(offer, action: "发送资料", detail: "",
                                         botID: "main", sessionID: "gb-main")
        let rowID = "e-main-approval-approval-exec"
        let guide = try XCTUnwrap(offer.draft.resources.first {
            $0.workspacePath == "docs/guide.md"
        })
        let report = try XCTUnwrap(offer.draft.resources.first {
            $0.workspacePath == "docs/report.md"
        })
        let result = await fixture.apply(nonce: "exec-1", botID: "main", rowID: rowID,
                                         draftID: offer.draft.draftID, expectedRevision: 1,
                                         selected: [guide.id])
        guard case .accepted = result else { return XCTFail("selection: \(result)") }

        // Before the user allows it, the delivery tool is refused.
        let pending = try await fixture.host.confirm(
            name: "show_attachment",
            arguments: .object(["path": .string("docs/guide.md")]),
            botID: "main", sessionID: "gb-main", nowMS: now)
        guard case .rejected(let pendingCode, _) = pending else {
            return XCTFail("pending selection must block delivery: \(pending)")
        }
        XCTAssertEqual(pendingCode, "delivery_selection_not_approved")

        try await fixture.appendDecision(approvalID: offer.draft.approvalID,
                                         status: "allowed", botID: "main", sessionID: "gb-main")
        let selected = try await fixture.host.confirm(
            name: "show_attachment",
            arguments: .object(["path": .string("docs/guide.md")]),
            botID: "main", sessionID: "gb-main", nowMS: now)
        XCTAssertTrue(selected.isAllowed, "selected current resource must pass: \(selected)")

        let unselected = try await fixture.host.confirm(
            name: "show_attachment",
            arguments: .object(["path": .string("docs/report.md")]),
            botID: "main", sessionID: "gb-main", nowMS: now)
        guard case .rejected(let unselectedCode, _) = unselected else {
            return XCTFail("unselected resource must be refused: \(unselected)")
        }
        XCTAssertEqual(unselectedCode, "delivery_resource_not_selected")

        let ownFile = try await fixture.host.confirm(
            name: "show_attachment",
            arguments: .object(["path": .string("docs/model-created.md")]),
            botID: "main", sessionID: "gb-main", nowMS: now)
        XCTAssertTrue(ownFile.isAllowed, "a file outside the suggestions is not gated: \(ownFile)")

        let modelFacing = try requireValue(await fixture.host.approvedSelectionJSON(
            approvalID: offer.draft.approvalID, botID: "main"))
        let selectedPaths = modelFacing["selected"]?.arrayValue?.compactMap {
            $0["path"]?.stringValue
        }
        XCTAssertEqual(selectedPaths, ["docs/guide.md"])
        XCTAssertEqual(modelFacing["revision"]?.intValue, 2)
        _ = report
    }

    func testAllSourcesRemovedAtExecutionIsRefused() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanup() }
        let offer = try requireValue(await fixture.offer(botID: "main", approvalID: "approval-empty",
                                                      sessionID: "gb-main"))
        try await fixture.appendApproval(offer, action: "发送资料", detail: "",
                                         botID: "main", sessionID: "gb-main")
        let rowID = "e-main-approval-approval-empty"
        let r1 = try XCTUnwrap(offer.draft.resources.first?.id)
        _ = await fixture.apply(nonce: "empty-1", botID: "main", rowID: rowID,
                                draftID: offer.draft.draftID, expectedRevision: 1,
                                selected: [r1])
        _ = await fixture.apply(nonce: "empty-2", botID: "main", rowID: rowID,
                                draftID: offer.draft.draftID, expectedRevision: 2,
                                selected: [])
        try await fixture.appendDecision(approvalID: offer.draft.approvalID,
                                         status: "allowed", botID: "main", sessionID: "gb-main")
        let confirmation = try await fixture.host.confirm(
            name: "show_attachment",
            arguments: .object(["path": .string("docs/guide.md")]),
            botID: "main", sessionID: "gb-main", nowMS: now)
        guard case .rejected(let code, _) = confirmation else {
            return XCTFail("removed resource must not be delivered: \(confirmation)")
        }
        XCTAssertEqual(code, "delivery_resource_not_selected")
    }

    // MARK: - Isolation

    func testOtherBotAndOtherDraftAreIsolated() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanup() }
        let mainOffer = try requireValue(await fixture.offer(botID: "main", approvalID: "approval-main-iso",
                                                          sessionID: "gb-main"))
        let otherOffer = try requireValue(await fixture.offer(botID: "other", approvalID: "approval-other-iso",
                                                           sessionID: "gb-other"))
        try await fixture.appendApproval(mainOffer, action: "发送资料", detail: "",
                                         botID: "main", sessionID: "gb-main")
        try await fixture.appendApproval(otherOffer, action: "发送资料", detail: "",
                                         botID: "other", sessionID: "gb-other")
        let mainOther = try await fixture.host.draft(
            botID: "main", rowID: "e-other-approval-approval-other-iso")
        XCTAssertNil(mainOther)
        let mainDrafts = try await fixture.host.drafts(botID: "main")
        let otherDrafts = try await fixture.host.drafts(botID: "other")
        XCTAssertEqual(mainDrafts.count, 1)
        XCTAssertEqual(otherDrafts.count, 1)

        let otherRow = "e-other-approval-\(otherOffer.draft.approvalID)"
        let otherResource = try XCTUnwrap(otherOffer.draft.resources.first?.id)
        let otherResult = await fixture.apply(
            nonce: "iso-other-1", botID: "other", rowID: otherRow,
            draftID: otherOffer.draft.draftID, expectedRevision: 1,
            selected: [otherResource])
        guard case .accepted = otherResult else {
            return XCTFail("other bot selection: \(otherResult)")
        }
        let mainAfterOther = try await fixture.host.drafts(botID: "main")
        let otherAfterOther = try await fixture.host.drafts(botID: "other")
        XCTAssertEqual(mainAfterOther.first?.revision, 1,
                       "another Bot's selection must not move this draft")
        XCTAssertEqual(otherAfterOther.first?.revision, 2)

        // Two drafts of the same Bot keep independent revisions.
        let secondMaterials = await fixture.materials(botID: "main")
        let secondOffer = try requireValue(await fixture.host.offer(
            approvalID: "approval-main-second", botID: "main", sessionID: "gb-main",
            action: "发送另一份", detail: "", command: "",
            materials: secondMaterials, nowMS: now))
        try await fixture.appendApproval(secondOffer, action: "发送另一份", detail: "",
                                         botID: "main", sessionID: "gb-main")
        let firstRow = "e-main-approval-approval-main-iso"
        let firstResult = await fixture.apply(
            nonce: "iso-main-1", botID: "main", rowID: firstRow,
            draftID: mainOffer.draft.draftID, expectedRevision: 1,
            selected: [try XCTUnwrap(mainOffer.draft.resources.first?.id)])
        guard case .accepted = firstResult else { return XCTFail("main: \(firstResult)") }
        let secondDraft = try await fixture.host.draft(
            approvalID: "approval-main-second", botID: "main")
        let firstDraft = try await fixture.host.draft(
            approvalID: "approval-main-iso", botID: "main")
        XCTAssertEqual(secondDraft?.revision, 1)
        XCTAssertEqual(firstDraft?.revision, 2)
    }

    // MARK: - Persistent approval restart

    func testPersistentApprovalRestoresTheSelectedDigestAfterRestart() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanup() }
        let offer = try requireValue(await fixture.offer(
            botID: "main", approvalID: "approval-restart", sessionID: "gb-main"))
        let data = await fixture.host.approvalEventData(
            offer: offer, action: "发送资料", detail: "", command: "",
            alwaysScope: "none", deferConsumption: false, effects: [],
            persistent: true, kind: "chat", origin: "structural",
            requestedAtMS: now, expiresAtMS: now + 600_000)
        let request = BotEvent(
            type: "approval.requested", eventId: "approval-request-restart",
            time: now, origin: .local(source: "mcp"),
            traceId: "approval-request-restart",
            principal: BotPrincipal(botId: "main", sessionId: "gb-main", kind: "chat"),
            causationId: nil, correlationId: nil, data: data)
        try await fixture.store.append(request)

        let grants = BotGrantStore(domainStore: fixture.store, now: { self.now })
        let writer = BotMCPEventWriter(eventLog: fixture.store, now: { self.now })
        let coordinator = BotApprovalCoordinator(
            grants: grants, eventWriter: writer, eventLog: fixture.store,
            now: { self.now })
        await coordinator.restoreDurable()
        let restored = await coordinator.pendingDigest(approvalId: "approval-restart")
        XCTAssertEqual(restored, BotDeliverySelectionHost.digestKey(offer.draft.digest))
        await fixture.host.installApprovalBridge(BotDeliveryApprovalBridge(
            pendingDigest: { id in await coordinator.pendingDigest(approvalId: id) },
            rebindDigest: { id, expected, digest, delivery in
                await coordinator.rebindPendingDigest(
                    approvalId: id, expectedDigest: expected,
                    digest: digest, delivery: delivery)
            }))

        let guide = try requireValue(offer.draft.resources.first {
            $0.workspacePath == "docs/guide.md"
        })
        let applied = try await fixture.host.apply(BotDeliverySelectionSubmission(
            nonce: "restart-1", botID: "main",
            rowID: "e-main-approval-approval-restart",
            draftID: offer.draft.draftID, expectedRevision: 1,
            selectedResourceIDs: [guide.id]))
        guard case .accepted = applied else { return XCTFail("apply: \(applied)") }
        let selected = try requireValue(try await fixture.host.draft(
            botID: "main", rowID: "e-main-approval-approval-restart"))
        // A fresh coordinator restores the selection event's prefixed digest
        // and normalizes it to the bare form its pending entry uses.
        let restarted = BotApprovalCoordinator(
            grants: BotGrantStore(domainStore: fixture.store, now: { self.now }),
            eventWriter: BotMCPEventWriter(eventLog: fixture.store, now: { self.now }),
            eventLog: fixture.store, now: { self.now })
        await restarted.restoreDurable()
        let afterRestart = await restarted.pendingDigest(approvalId: "approval-restart")
        XCTAssertEqual(afterRestart, BotDeliverySelectionHost.digestKey(selected.digest))

        let resolved = await coordinator.resolve(
            approvalId: "approval-restart", decision: .allowOnce,
            digest: selected.digest)
        XCTAssertEqual(resolved, .resolved)

        let confirmation = try await fixture.host.confirm(
            name: "show_attachment",
            arguments: .object(["path": .string("docs/guide.md")]),
            botID: "main", sessionID: "gb-main", nowMS: now)
        XCTAssertTrue(confirmation.isAllowed, "restored approval: \(confirmation)")
    }

    // MARK: - A02 delivery evidence

    func testDeliveryEvidenceExportsSelectedSourceAndVersion() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanup() }
        let offer = try requireValue(await fixture.offer(
            botID: "main", approvalID: "approval-evidence", sessionID: "gb-main"))
        try await fixture.appendApproval(offer, action: "发送资料", detail: "",
                                         botID: "main", sessionID: "gb-main")
        let guide = try requireValue(offer.draft.resources.first {
            $0.workspacePath == "docs/guide.md"
        })
        _ = await fixture.apply(nonce: "evidence-1", botID: "main",
                                rowID: "e-main-approval-approval-evidence",
                                draftID: offer.draft.draftID,
                                expectedRevision: 1, selected: [guide.id])
        try await fixture.appendDecision(approvalID: "approval-evidence",
                                         status: "allowed", botID: "main",
                                         sessionID: "gb-main")
        let evidence = try requireValue(try await fixture.host.evidence(
            approvalID: "approval-evidence", botID: "main"))
        XCTAssertEqual(evidence.revision, 2)
        XCTAssertEqual(evidence.status, "allowed")
        XCTAssertEqual(evidence.sources.count, 1)
        let source = evidence.sources[0]
        XCTAssertEqual(source.resourceID, guide.id)
        XCTAssertEqual(source.workspacePath, "docs/guide.md")
        XCTAssertEqual(source.ref, guide.source.ref)
        XCTAssertEqual(source.role, "evidence")
        XCTAssertNotNil(source.version)
        XCTAssertEqual(source.version?.knownValue, guide.source.sourceVersion?.knownValue)
    }

    func testSourceJSONCarriesRecordEvidenceAndRole() throws {
        let version = BotProvenanceSourceVersion.known(
            basis: .etag, value: "etag:creator-1", observedAtMS: 1_000)
        let evidence = BotDeliveryEvidenceRef(
            record: "record://event/8", role: "creator", sourceVersion: version)
        let source = BotDeliverySelectionSource(
            ref: "workspace:docs/周报.md@sha256:" + String(repeating: "a", count: 64),
            label: "周报.md", sourceVersion: version,
            evidenceSources: [evidence], role: "creator")
        let parsed = try requireValue(BotDeliverySelectionSource.parse(source.json))
        XCTAssertEqual(parsed.role, "creator")
        XCTAssertEqual(parsed.evidenceSources, [evidence])
        XCTAssertEqual(parsed.evidenceSources[0].record, "record://event/8")
        XCTAssertEqual(parsed.evidenceSources[0].role, "creator")
        XCTAssertEqual(parsed.evidenceSources[0].sourceVersion?.knownValue, "etag:creator-1")
    }

    // MARK: - Fail-closed corrupt records

    func testCorruptDeliveryRecordBlocksSelectionAndConfirmation() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanup() }
        let offer = try requireValue(await fixture.offer(botID: "main",
                                                      approvalID: "approval-ok",
                                                      sessionID: "gb-main"))
        try await fixture.appendApproval(offer, action: "发送资料", detail: "",
                                         botID: "main", sessionID: "gb-main")
        let corrupt = BotEvent(
            type: "approval.requested", eventId: "corrupt-delivery",
            time: now, origin: .local(source: "card-bridge"),
            traceId: "corrupt-delivery",
            principal: BotPrincipal(botId: "main", sessionId: "gb-main", kind: "chat"),
            causationId: nil, correlationId: nil,
            data: .object([
                "approvalID": .string("approval-corrupt"),
                "status": .string("pending"),
                "deliverySelection": .bool(true),
                "delivery": .object(["revision": .number(1)]),
            ]))
        try await fixture.store.append(corrupt)

        // A delivery block that claims a binding but omits the required
        // turn_id is corrupt, not "no constraint".
        var badBindingDelivery = offer.deliveryJSON.objectValue ?? [:]
        badBindingDelivery["binding"] = .object([
            "approval_id": .string("approval-corrupt-binding"),
        ])
        let badBinding = BotEvent(
            type: "approval.requested", eventId: "corrupt-binding",
            time: now, origin: .local(source: "card-bridge"),
            traceId: "corrupt-binding",
            principal: BotPrincipal(botId: "main", sessionId: "gb-main", kind: "chat"),
            causationId: nil, correlationId: nil,
            data: .object([
                "approvalID": .string("approval-corrupt-binding"),
                "status": .string("pending"),
                "deliverySelection": .bool(true),
                "delivery": .object(badBindingDelivery),
            ]))
        try await fixture.store.append(badBinding)

        do {
            _ = try await fixture.host.apply(BotDeliverySelectionSubmission(
                nonce: "corrupt-1", botID: "main",
                rowID: "e-main-approval-approval-corrupt", draftID: "unknown",
                expectedRevision: 1, selectedResourceIDs: []))
            XCTFail("corrupt delivery must not be treated as an empty draft")
        } catch let failure as BotDeliverySelectionFailure {
            guard case .corruptRecord = failure else {
                return XCTFail("unexpected failure: \(failure)")
            }
        }
        let confirmation = try await fixture.host.confirm(
            name: "show_attachment",
            arguments: .object(["path": .string("docs/guide.md")]),
            botID: "main", sessionID: "gb-main", nowMS: now)
        guard case .rejected(let code, _) = confirmation else {
            return XCTFail("corrupt record must fail closed: \(confirmation)")
        }
        XCTAssertEqual(code, "delivery_selection_corrupt")
    }

    // MARK: - Turn/goal binding and isolation

    func testTurnAndGoalBindingSeparateDraftsAndRetireOldTurns() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanup() }
        let all = await fixture.materials(botID: "main")
        let guideOnly = all.filter { $0.ref.contains("guide.md") }
        let reportOnly = all.filter { $0.ref.contains("report.md") }
        let firstValue = await fixture.host.offer(
            approvalID: "approval-turn-1", botID: "main", sessionID: "gb-main",
            action: "发送 A", detail: "", command: "", materials: guideOnly,
            turnID: "gb-main#1", goalDigest: "goal-a", nowMS: now)
        let secondValue = await fixture.host.offer(
            approvalID: "approval-turn-2", botID: "main", sessionID: "gb-main",
            action: "发送 B", detail: "", command: "", materials: reportOnly,
            turnID: "gb-main#1", goalDigest: "goal-b", nowMS: now)
        let first = try requireValue(firstValue)
        let second = try requireValue(secondValue)
        try await fixture.appendApproval(first, action: "发送 A", detail: "",
                                         botID: "main", sessionID: "gb-main")
        try await fixture.appendApproval(second, action: "发送 B", detail: "",
                                         botID: "main", sessionID: "gb-main")
        let guide = try XCTUnwrap(first.draft.resources.first {
            $0.workspacePath == "docs/guide.md"
        })
        let firstRow = "e-main-approval-approval-turn-1"
        let applied = await fixture.apply(
            nonce: "turn-1", botID: "main", rowID: firstRow,
            draftID: first.draft.draftID, expectedRevision: 1,
            selected: [guide.id])
        guard case .accepted = applied else { return XCTFail("selection: \(applied)") }
        try await fixture.appendDecision(approvalID: "approval-turn-1",
                                         status: "allowed", botID: "main",
                                         sessionID: "gb-main")

        let sameTurn = try await fixture.host.confirm(
            name: "show_attachment",
            arguments: .object(["path": .string("docs/guide.md")]),
            botID: "main", sessionID: "gb-main", turnID: "gb-main#1",
            goalDigest: "goal-a", nowMS: now)
        XCTAssertTrue(sameTurn.isAllowed, "current turn/goal selected file: \(sameTurn)")

        // The other draft owns report.md under another goal: it must not be
        // treated as a model-created file, nor as approved by the first draft.
        let otherDraft = try await fixture.host.confirm(
            name: "show_attachment",
            arguments: .object(["path": .string("docs/report.md")]),
            botID: "main", sessionID: "gb-main", turnID: "gb-main#1",
            goalDigest: "goal-a", nowMS: now)
        guard case .rejected(let otherCode, _) = otherDraft else {
            return XCTFail("another draft's file must not pass: \(otherDraft)")
        }
        XCTAssertEqual(otherCode, "delivery_selection_stale")

        // A next turn does not inherit the old approval.
        let nextTurn = try await fixture.host.confirm(
            name: "show_attachment",
            arguments: .object(["path": .string("docs/guide.md")]),
            botID: "main", sessionID: "gb-main", turnID: "gb-main#2",
            goalDigest: "goal-a", nowMS: now)
        guard case .rejected(let nextCode, _) = nextTurn else {
            return XCTFail("old turn selection must not authorize a new turn: \(nextTurn)")
        }
        XCTAssertEqual(nextCode, "delivery_selection_stale")

        // A genuinely unrelated new file is not owned by any draft.
        let newFile = try await fixture.host.confirm(
            name: "show_attachment",
            arguments: .object(["path": .string("docs/model-created.md")]),
            botID: "main", sessionID: "gb-main", turnID: "gb-main#2",
            goalDigest: "goal-a", nowMS: now)
        XCTAssertTrue(newFile.isAllowed, "unrelated new file: \(newFile)")

        // Text has no resource set; an old attachment draft must not gate an
        // unrelated SendToUser in the next turn.
        let text = try await fixture.host.confirm(
            name: "SendToUser",
            arguments: .object(["message": .string("另一件事的说明")]),
            botID: "main", sessionID: "gb-main", turnID: "gb-main#2",
            goalDigest: "goal-a", nowMS: now)
        XCTAssertTrue(text.isAllowed, "unrelated text: \(text)")
    }

    // MARK: - Concurrent submit while the provider is paused

    func testConcurrentSubmissionsOnlyOneRebindsTheApproval() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanup() }
        let offer = try requireValue(await fixture.offer(
            botID: "main", approvalID: "approval-concurrent",
            sessionID: "gb-main"))
        try await fixture.appendApproval(offer, action: "发送资料", detail: "",
                                         botID: "main", sessionID: "gb-main")
        let rowID = "e-main-approval-approval-concurrent"
        let guide = try XCTUnwrap(offer.draft.resources.first {
            $0.workspacePath == "docs/guide.md"
        })
        let report = try XCTUnwrap(offer.draft.resources.first {
            $0.workspacePath == "docs/report.md"
        })
        await fixture.gate.pause()
        async let first = fixture.apply(
            nonce: "concurrent-a", botID: "main", rowID: rowID,
            draftID: offer.draft.draftID, expectedRevision: 1,
            selected: [guide.id])
        async let second = fixture.apply(
            nonce: "concurrent-b", botID: "main", rowID: rowID,
            draftID: offer.draft.draftID, expectedRevision: 1,
            selected: [report.id])
        try await waitForGateWaiters(fixture.gate, 2)
        await fixture.gate.release()
        let firstResult = await first
        let secondResult = await second
        let results = [firstResult, secondResult]
        let accepted = results.filter {
            if case .accepted = $0 { return true }
            return false
        }
        let rejected = results.filter {
            if case .stale(let reason) = $0 { return reason == "concurrent_selection" }
            return false
        }
        XCTAssertEqual(accepted.count, 1, "exactly one concurrent submit: \(results)")
        XCTAssertEqual(rejected.count, 1, "the loser must be stale: \(results)")
        let rebinds = await fixture.bridge.rebinds
        XCTAssertEqual(rebinds.count, 1, "only one CAS rebind may succeed")
    }

    func testConcurrentSameNonceReturnsDuplicate() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanup() }
        let offer = try requireValue(await fixture.offer(
            botID: "main", approvalID: "approval-same-nonce",
            sessionID: "gb-main"))
        try await fixture.appendApproval(offer, action: "发送资料", detail: "",
                                         botID: "main", sessionID: "gb-main")
        let rowID = "e-main-approval-approval-same-nonce"
        let guide = try requireValue(offer.draft.resources.first {
            $0.workspacePath == "docs/guide.md"
        })
        await fixture.gate.pause()
        async let first = fixture.apply(
            nonce: "same-nonce", botID: "main", rowID: rowID,
            draftID: offer.draft.draftID, expectedRevision: 1,
            selected: [guide.id])
        async let second = fixture.apply(
            nonce: "same-nonce", botID: "main", rowID: rowID,
            draftID: offer.draft.draftID, expectedRevision: 1,
            selected: [guide.id])
        try await waitForGateWaiters(fixture.gate, 2)
        await fixture.gate.release()
        let firstResult = await first
        let secondResult = await second
        let accepted = [firstResult, secondResult].filter {
            if case .accepted = $0 { return true }
            return false
        }
        let duplicates = [firstResult, secondResult].filter {
            if case .duplicate = $0 { return true }
            return false
        }
        XCTAssertEqual(accepted.count, 1, "one append: \(firstResult) / \(secondResult)")
        XCTAssertEqual(duplicates.count, 1, "same nonce duplicate: \(firstResult) / \(secondResult)")
    }

    func testRevocationWhileProviderIsPausedIsNotAccepted() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanup() }
        let offer = try requireValue(await fixture.offer(
            botID: "main", approvalID: "approval-paused", sessionID: "gb-main"))
        try await fixture.appendApproval(offer, action: "发送资料", detail: "",
                                         botID: "main", sessionID: "gb-main")
        let rowID = "e-main-approval-approval-paused"
        let guide = try XCTUnwrap(offer.draft.resources.first {
            $0.workspacePath == "docs/guide.md"
        })
        await fixture.gate.pause()
        let task = Task {
            await fixture.apply(nonce: "paused-1", botID: "main", rowID: rowID,
                                draftID: offer.draft.draftID, expectedRevision: 1,
                                selected: [guide.id])
        }
        try await waitForGateWaiters(fixture.gate, 1)
        await fixture.modeBox.set(.revoked)
        await fixture.gate.release()
        let result = await task.value
        guard case .stale(let reason) = result else {
            return XCTFail("revoked during recheck must not be accepted: \(result)")
        }
        XCTAssertEqual(reason, "resource_unavailable")
        let after = try await fixture.host.drafts(botID: "main")
        XCTAssertEqual(after.first?.revision, 1)
    }

    // MARK: - Confirmation racing a selection change

    func testConfirmationPausedWhileSourceIsRevokedIsRejected() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanup() }
        let offer = try requireValue(await fixture.offer(
            botID: "main", approvalID: "approval-race", sessionID: "gb-main"))
        try await fixture.appendApproval(offer, action: "发送资料", detail: "",
                                         botID: "main", sessionID: "gb-main")
        let rowID = "e-main-approval-approval-race"
        let guide = try requireValue(offer.draft.resources.first {
            $0.workspacePath == "docs/guide.md"
        })
        let report = try requireValue(offer.draft.resources.first {
            $0.workspacePath == "docs/report.md"
        })
        _ = await fixture.apply(nonce: "race-1", botID: "main", rowID: rowID,
                                draftID: offer.draft.draftID, expectedRevision: 1,
                                selected: [guide.id])
        try await fixture.appendDecision(approvalID: "approval-race",
                                         status: "allowed", botID: "main",
                                         sessionID: "gb-main")

        // Pause the confirmation's own recheck, revoke the selected source
        // while the provider call is suspended, then release. The confirmation
        // must observe the revoke, not return the pre-pause `ok`.
        await fixture.gate.pauseOnce()
        let confirmation = Task {
            try await fixture.host.confirm(
                name: "show_attachment",
                arguments: .object(["path": .string("docs/guide.md")]),
                botID: "main", sessionID: "gb-main", nowMS: now)
        }
        try await waitForGateWaiters(fixture.gate, 1)
        await fixture.modeBox.set(.revoked)
        await fixture.gate.release()
        let result = try await confirmation.value
        guard case .rejected(let code, _) = result else {
            return XCTFail("confirmation must see the revoked source: \(result)")
        }
        XCTAssertEqual(code, "delivery_source_revoked")
        _ = report
    }

    // MARK: - Path spellings

    func testCanonicalPathSpellingsUseTheSameSelection() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanup() }
        let offer = try requireValue(await fixture.offer(
            botID: "main", approvalID: "approval-paths", sessionID: "gb-main"))
        try await fixture.appendApproval(offer, action: "发送资料", detail: "",
                                         botID: "main", sessionID: "gb-main")
        let rowID = "e-main-approval-approval-paths"
        let guide = try XCTUnwrap(offer.draft.resources.first {
            $0.workspacePath == "docs/guide.md"
        })
        _ = await fixture.apply(nonce: "paths-1", botID: "main", rowID: rowID,
                                draftID: offer.draft.draftID, expectedRevision: 1,
                                selected: [guide.id])
        try await fixture.appendDecision(approvalID: "approval-paths",
                                         status: "allowed", botID: "main",
                                         sessionID: "gb-main")
        for spelling in ["docs/guide.md", "./docs/guide.md",
                         "/dsh/workspace/docs/guide.md",
                         "docs/%67uide.md"] {
            let result = try await fixture.host.confirm(
                name: "show_attachment",
                arguments: .object(["path": .string(spelling)]),
                botID: "main", sessionID: "gb-main", nowMS: now)
            XCTAssertTrue(result.isAllowed, "\(spelling) must resolve to the selected file: \(result)")
        }
        for spelling in ["/tmp/guide.md", "docs/../docs/guide.md", "docs//guide.md"] {
            let result = try await fixture.host.confirm(
                name: "show_attachment",
                arguments: .object(["path": .string(spelling)]),
                botID: "main", sessionID: "gb-main", nowMS: now)
            guard case .rejected(let code, _) = result else {
                return XCTFail("\(spelling) must not bypass the selected path: \(result)")
            }
            XCTAssertEqual(code, "delivery_path_unverifiable", spelling)
        }
        let unselected = try await fixture.host.confirm(
            name: "show_attachment",
            arguments: .object(["path": .string("./docs/report.md")]),
            botID: "main", sessionID: "gb-main", nowMS: now)
        guard case .rejected(let code, _) = unselected else {
            return XCTFail("unselected alias: \(unselected)")
        }
        XCTAssertEqual(code, "delivery_resource_not_selected")
    }

    private func waitForGateWaiters(_ gate: RecheckGate, _ count: Int) async throws {
        for _ in 0..<200 {
            if await gate.waiterCount() >= count { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("gate did not hold \(count) rechecks")
    }

    // MARK: - Fixture

    private struct Fixture {
        let directory: URL
        let store: SQLiteDomainStore
        let catalog: BotWorkspaceDirectoryCatalog
        let workspace: WorkspaceDecisionContextService
        let host: BotDeliverySelectionHost
        let bridge: DigestBridge
        let modeBox: WorkspaceModeBox
        let gate: RecheckGate
        let clock: Int64

        func cleanup() { try? FileManager.default.removeItem(at: directory) }

        func materials(botID: String) async -> [BotDecisionMaterial] {
            await workspace.selection(
                query: "guide report", botID: botID,
                materialPrefix: "a04", limits: .init()).materials
        }

        func offer(botID: String, approvalID: String, sessionID: String,
                   turnID: String? = nil,
                   goalDigest: String? = nil) async
            -> BotDeliverySelectionOffer? {
            let materials = await materials(botID: botID)
            return await host.offer(
                approvalID: approvalID, botID: botID, sessionID: sessionID,
                action: "发送周报给张三", detail: "给张三的周报", command: "",
                materials: materials, turnID: turnID, goalDigest: goalDigest,
                nowMS: clock)
        }

        @discardableResult
        func appendApproval(_ offer: BotDeliverySelectionOffer, action: String,
                            detail: String, botID: String, sessionID: String,
                            expiresAt: Int64? = nil) async throws -> BotEvent {
            let data = await host.approvalEventData(
                offer: offer, action: action, detail: detail, command: "",
                alwaysScope: "none", deferConsumption: false, effects: [],
                persistent: expiresAt != nil, kind: "chat", origin: "structural",
                requestedAtMS: clock, expiresAtMS: expiresAt)
            let event = BotEvent(
                type: "approval.requested",
                eventId: "approval-request-\(offer.draft.approvalID)",
                time: clock, origin: .local(source: "mcp"),
                traceId: "approval-request-\(offer.draft.approvalID)",
                principal: BotPrincipal(botId: botID, sessionId: sessionID, kind: "chat"),
                causationId: nil, correlationId: nil, data: data)
            try await store.append(event)
            await bridge.setPending(offer.draft.digest, approvalID: offer.draft.approvalID)
            return event
        }

        func appendDecision(approvalID: String, status: String,
                            botID: String, sessionID: String) async throws {
            let event = BotEvent(
                type: "approval.decided", eventId: "decided:\(approvalID)",
                time: clock, origin: .local(source: "card-bridge"),
                traceId: "decided:\(approvalID)",
                principal: BotPrincipal(botId: botID, sessionId: sessionID, kind: "chat"),
                causationId: nil, correlationId: nil,
                data: .object([
                    "approvalID": .string(approvalID),
                    "status": .string(status),
                    "decision": .string(status == "allowed" ? "allowOnce" : "deny"),
                ]))
            try await store.append(event)
            if status != "allowed" {
                await bridge.setPending(nil, approvalID: approvalID)
            }
        }

        func apply(nonce: String, botID: String, rowID: String, draftID: String,
                   expectedRevision: Int, selected: [String]) async
            -> BotDeliverySelectionApplyResult {
            do {
                return try await host.apply(BotDeliverySelectionSubmission(
                    nonce: nonce, botID: botID, rowID: rowID, draftID: draftID,
                    expectedRevision: expectedRevision, selectedResourceIDs: selected),
                    nowMS: clock)
            } catch let failure as BotDeliverySelectionFailure {
                return .stale(failure.code)
            } catch {
                return .rejected(String(describing: error))
            }
        }

        func rows(botID: String) async throws -> [BotRow] {
            let events = try await store.events(after: 0, limit: 1_000)
            let history = BotRowHistory()
            _ = try await history.rebuild(
                botID: botID, epochs: [], uiEvents: events, heldRequestNonces: [:])
            return await history.history()
        }

        func write(_ path: String, content: String, botID: String) throws {
            let url = directory
                .appendingPathComponent("materialized/workspace", isDirectory: true)
                .appendingPathComponent(".dshbot/agents/\(botID)", isDirectory: true)
                .appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try content.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    enum WorkspaceMode { case current, revoked, changed }

    private func makeFixture() async throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("a04-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let clock = now
        let catalog = BotWorkspaceDirectoryCatalog(workspaceRoot: directory)
        let workspace = WorkspaceDecisionContextService(catalog: catalog, now: { clock })
        let store = try SQLiteDomainStore(
            fileURL: directory.appendingPathComponent("domain.sqlite"), now: { clock })
        let bridge = DigestBridge()
        let modeBox = WorkspaceModeBox()
        let gate = RecheckGate()
        let resolver: BotDeliverySelectionHost.WorkspaceStateResolver = { ref, botID in
            await gate.arrive()
            let mode = await modeBox.current()
            switch mode {
            case .revoked:
                return .revoked()
            case .changed:
                return .changed(.known(basis: .contentSHA256, value: "sha256:" + String(repeating: "0", count: 64),
                                       observedAtMS: clock, subject: .fileBytes))
            case .current:
                guard let expected = WorkspaceDecisionContextService.workspaceDigest(fromRef: ref) else {
                    return .unknown()
                }
                guard let current = await workspace.currentContentSHA256(
                    forWorkspaceRef: ref, botID: botID) else {
                    return .unavailable()
                }
                if current == expected {
                    return BotDeliveryWorkspaceState(
                        state: .current,
                        currentVersion: .known(basis: .contentSHA256, value: current,
                                               observedAtMS: clock, subject: .fileBytes))
                }
                return .changed(.known(basis: .contentSHA256, value: current,
                                       observedAtMS: clock, subject: .fileBytes))
            }
        }
        let host = BotDeliverySelectionHost(eventLog: store, workspaceState: resolver,
                                             now: { clock })
        await host.installApprovalBridge(bridge.bridge())
        let fixture = Fixture(directory: directory, store: store, catalog: catalog,
                              workspace: workspace, host: host, bridge: bridge,
                              modeBox: modeBox, gate: gate, clock: clock)
        try fixture.write("docs/guide.md", content: "weekly guide", botID: "main")
        try fixture.write("docs/report.md", content: "weekly report", botID: "main")
        try fixture.write("docs/guide.md", content: "other weekly guide", botID: "other")
        try fixture.write("docs/report.md", content: "other weekly report", botID: "other")
        return fixture
    }
}

/// One mutable pending digest shared by the host and the test, standing in for
/// the coordinator's in-memory pending entry. Production installs the same two
/// closures over `BotApprovalCoordinator.pendingDigest/rebindPendingDigest`.
actor DigestBridge {
    private var pending: [String: String] = [:]
    private(set) var rebinds: [(String, String)] = []

    func setPending(_ digest: String?, approvalID: String) {
        pending[approvalID] = digest
    }

    func digest(approvalID: String) -> String? { pending[approvalID] }

    func rebind(approvalID: String, expected: String, digest: String,
                delivery: BotJSONValue?) -> Bool {
        guard pending[approvalID] == expected else { return false }
        pending[approvalID] = digest
        rebinds.append((approvalID, digest))
        _ = delivery
        return true
    }

    nonisolated func bridge() -> BotDeliveryApprovalBridge {
        BotDeliveryApprovalBridge(
            pendingDigest: { [self] approvalID in await digest(approvalID: approvalID) },
            rebindDigest: { [self] approvalID, expected, digest, delivery in
                await rebind(approvalID: approvalID, expected: expected,
                             digest: digest, delivery: delivery)
            })
    }
}

/// Tests can move the host's recheck result without replacing the store,
/// catalog or state machine; production resolves this from the real file.
actor WorkspaceModeBox {
    private var mode: BotDeliverySelectionHostTests.WorkspaceMode = .current
    func set(_ next: BotDeliverySelectionHostTests.WorkspaceMode) { mode = next }
    func current() -> BotDeliverySelectionHostTests.WorkspaceMode { mode }
}

private func requireValue<T>(_ value: T?, file: StaticString = #filePath,
                             line: UInt = #line) throws -> T {
    try XCTUnwrap(value, file: file, line: line)
}

/// Lets one test hold the host inside its source recheck while another
/// selection/confirmation reaches the same actor.
actor RecheckGate {
    private var paused = false
    private var pauseNext = false
    private var arrivals = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func pause() { paused = true }

    /// Hold only the next recheck; subsequent rechecks proceed. Lets one test
    /// pause a confirmation while a selection changes underneath it.
    func pauseOnce() {
        paused = false
        pauseNext = true
    }

    func arrive() async {
        arrivals += 1
        let shouldWait = paused || pauseNext
        if pauseNext { pauseNext = false }
        guard shouldWait else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        paused = false
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }

    func arrivalCount() -> Int { arrivals }
    func waiterCount() -> Int { waiters.count }
}
