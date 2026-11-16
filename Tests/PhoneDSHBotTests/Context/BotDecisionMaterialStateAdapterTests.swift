// SPDX-License-Identifier: MIT

import Foundation
import XCTest
@testable import PhoneDSHBot

final class BotDecisionMaterialStateAdapterTests: XCTestCase {
    private func status(_ state: BotProvenanceStatus,
                        reason: BotProvenanceReason? = nil,
                        ref: String? = nil) -> BotSourceStatus {
        BotSourceStatus(
            ref: ref ?? "record://event/\(state.rawValue)",
            roles: ["evidence"],
            resolved: state != .unavailable,
            erased: state == .erased,
            state: state,
            reasons: reason.map { [$0] } ?? [])
    }

    private func request(_ evidence: [String]) -> BotDecisionContextService.BotMaterialStateRequest {
        BotDecisionContextService.BotMaterialStateRequest(
            botID: "bot-a", sessionID: "gb-main", path: "user/profile.md",
            version: 2, evidence: evidence)
    }

    private func adapter(
        _ statuses: [String: BotSourceStatus]
    ) -> BotDecisionMaterialStateAdapter {
        BotDecisionMaterialStateAdapter { _, _ in
            statuses.map { ref, status in
                var copy = status
                copy.ref = ref
                return copy
            }
        }
    }

    func testEmptyEvidenceIsNoBaselineUnknown() async {
        let state = await adapter([:]).state(for: request([]))
        XCTAssertEqual(state.0, .unknown)
        XCTAssertEqual(state.1, .noBaseline)
    }

    func testAllCurrentIsCurrentWithoutReason() async {
        let e1 = "record://event/1"
        let e2 = "record://event/2"
        let state = await adapter([
            e1: status(.current),
            e2: status(.current),
        ]).state(for: request([e1, e2]))
        XCTAssertEqual(state.0, .current)
        XCTAssertNil(state.1)
    }

    func testChangedWinsOverCurrentAndKeepsSourceChanged() async {
        let e1 = "record://event/1"
        let e2 = "record://event/2"
        let state = await adapter([
            e1: status(.current),
            e2: status(.changed, reason: .sourceChanged),
        ]).state(for: request([e1, e2]))
        XCTAssertEqual(state.0, .changed)
        XCTAssertEqual(state.1, .sourceChanged)
    }

    func testWorstStatePrecedenceUsesLG1Severity() async {
        let erased = "record://event/1"
        let revoked = "record://event/2"
        let unavailable = "record://event/3"
        let state = await adapter([
            erased: status(.erased, reason: .recordErased),
            revoked: status(.revoked, reason: .grantRevoked),
            unavailable: status(.unavailable),
        ]).state(for: request([erased, revoked, unavailable]))
        XCTAssertEqual(state.0, .erased)
        XCTAssertEqual(state.1, .recordErased)

        let revokedWins = await adapter([
            revoked: status(.revoked, reason: .grantRevoked),
            unavailable: status(.unavailable),
        ]).state(for: request([revoked, unavailable]))
        XCTAssertEqual(revokedWins.0, .revoked)
        XCTAssertEqual(revokedWins.1, .grantRevoked)
    }

    func testUnknownUsesItsKnownReasonOrTheNarrowedFallback() async {
        let e1 = "record://event/1"
        let e2 = "record://event/2"
        let known = await adapter([
            e1: status(.unknown, reason: .sourceVersionUnknown),
        ]).state(for: request([e1]))
        XCTAssertEqual(known.0, .unknown)
        XCTAssertEqual(known.1, .sourceVersionUnknown)

        // G-1 has more reasons than G-2's material schema; a reason outside the
        // closed G-2 set must fall back, not invent an unknown G-2 value.
        let narrowed = await adapter([
            e1: status(.unknown, reason: .refreshUnavailable),
        ]).state(for: request([e1]))
        XCTAssertEqual(narrowed.0, .unknown)
        XCTAssertEqual(narrowed.1, .sourceVersionUnknown)
    }

    func testResolverFailureAndMissingReferenceAreNotCurrent() async {
        let failed = BotDecisionMaterialStateAdapter { _, _ in
            throw BotRecordServiceError.unavailable("probe")
        }
        let failedState = await failed.state(for: request(["record://event/1"]))
        XCTAssertEqual(failedState.0, .unknown)
        XCTAssertEqual(failedState.1, .sourceVersionUnknown)

        let missing = await adapter([:]).state(for: request(["record://event/1"]))
        XCTAssertEqual(missing.0, .unknown)
        XCTAssertEqual(missing.1, .recordUnresolved)
    }

    func testDuplicateEvidenceIsResolvedOnce() async {
        let e1 = "record://event/1"
        var artifacts: [BotDerivedRef] = []
        let adapter = BotDecisionMaterialStateAdapter { artifact, _ in
            artifacts.append(artifact)
            return [self.status(.current, ref: e1)]
        }
        let state = await adapter.state(for: request([e1, e1]))
        XCTAssertEqual(state.0, .current)
        XCTAssertEqual(artifacts.count, 1)
        XCTAssertEqual(artifacts.first?.id, "user/profile.md")
        XCTAssertEqual(artifacts.first?.version, 2)
    }
}
