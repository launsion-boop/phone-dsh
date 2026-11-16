// SPDX-License-Identifier: MIT

import XCTest
@testable import PhoneDSHBot

final class BotMaintenanceAdaptersTests: XCTestCase {
    private func disputed(
        _ path: String, _ refs: [String], state: String = "active"
    ) -> BotFeedbackDisputedRef {
        BotFeedbackDisputedRef(
            path: path, refs: refs, feedbackID: "fb-\(path)",
            correctedVersion: 2, supersededVersion: 1,
            atMS: 1_760_000_000_000, state: state)
    }

    func testFeedbackAdapterUsesActiveCorrectionsOnly() async throws {
        let adapter = BotFeedbackDisputeAdapter(rawQuery: { paths in
            XCTAssertEqual(paths, ["agent/a.md", "agent/b.md"])
            return [
                "agent/a.md": [
                    self.disputed("agent/a.md", ["record://event/2", "record://event/1"]),
                    self.disputed("agent/a.md", ["record://event/1"], state: "retracted"),
                ],
                "agent/b.md": [
                    self.disputed("agent/b.md", [], state: "active"),
                ],
                "agent/c.md": [
                    self.disputed("agent/c.md", ["record://event/9"], state: "retracted"),
                ],
            ]
        })
        let result = try await adapter.disputedReferences(
            forPaths: ["agent/a.md", "agent/b.md"])
        XCTAssertEqual(result["agent/a.md"], ["record://event/1", "record://event/2"])
        XCTAssertEqual(result["agent/b.md"], [], "active empty refs stay disputed")
        XCTAssertNil(result["agent/c.md"], "a retracted correction is not a dispute")
    }

    private func status(
        _ ref: String, _ state: BotProvenanceStatus,
        reason: BotProvenanceReason? = nil
    ) -> BotSourceStatus {
        BotSourceStatus(
            ref: ref, roles: ["evidence"], resolved: true, erased: state == .erased,
            state: state, reasons: reason.map { [$0] } ?? [],
            observedAtMS: 1_760_000_000_000, recordType: "tool/result",
            trust: "observation", sourceVersion: nil, latestRef: nil,
            baseline: nil, resource: nil, recheckedAtMS: nil)
    }

    func testProvenanceAdapterMapsEveryStateAndNeverTreatsUnknownAsLive() async throws {
        let adapter = BotProvenanceInvalidationAdapter(rawQuery: { request in
            XCTAssertEqual(request.references.count, 6)
            XCTAssertEqual(request.botID, "main")
            XCTAssertEqual(request.artifact.path, "agent/a.md")
            XCTAssertEqual(request.artifact.version, 3)
            return [
                "record://event/1": self.status("record://event/1", .current),
                "record://event/2": self.status(
                    "record://event/2", .changed, reason: .sourceChanged),
                "record://event/3": self.status(
                    "record://event/3", .revoked, reason: .grantRevoked),
                "record://event/4": self.status(
                    "record://event/4", .erased, reason: .recordErased),
                "record://event/5": self.status(
                    "record://event/5", .unavailable, reason: .recordUnresolved),
                "record://event/6": self.status(
                    "record://event/6", .unknown, reason: .noBaseline),
            ]
        })
        let result = try await adapter.invalidationStatuses(
            for: BotMaintenanceInvalidationRequest(
                botID: "main",
                artifact: BotMaintenanceArtifactReference(
                    path: "agent/a.md", version: 3, scope: "agent"),
                references: [
                    "record://event/1", "record://event/2", "record://event/3",
                    "record://event/4", "record://event/5", "record://event/6",
                ]))
        XCTAssertEqual(result["record://event/1"]?.state, .live)
        XCTAssertEqual(result["record://event/2"]?.state, .changed)
        XCTAssertEqual(result["record://event/3"]?.state, .revoked)
        XCTAssertEqual(result["record://event/4"]?.state, .erased)
        XCTAssertEqual(result["record://event/5"]?.state, .unknown)
        XCTAssertEqual(result["record://event/6"]?.state, .unknown)
        XCTAssertEqual(result["record://event/2"]?.reason, "source-changed")
        XCTAssertNotEqual(result["record://event/6"]?.state,
                          .live, "unknown is never live")
    }
}
