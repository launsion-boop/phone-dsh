// SPDX-License-Identifier: MIT
// PhoneDSHController: fence issue/validate/handoff/reclaim tests.

import Foundation
import XCTest
@testable import PhoneDSHController
import PhoneDSHLog
import PhoneDSHWire

final class FenceAuthorityTests: XCTestCase {
    private func makeAuthority(_ test: XCTestCase, root: URL? = nil) throws -> FenceAuthority {
        try FenceAuthority(root: root ?? ControllerTestSupport.root(for: test))
    }

    func testInitialFenceIsPersisted() async throws {
        let root = ControllerTestSupport.root(for: self)
        let authority = try makeAuthority(self, root: root)
        let current = await authority.current
        XCTAssertEqual(current, FenceToken(owner: "phone", generation: 0, walSeq: 0))
        let json = try ControllerTestSupport.readJSON(
            root.appendingPathComponent("fence.json"))
        let fence = try XCTUnwrap(json["fence"] as? [String: Any])
        XCTAssertEqual(fence["owner"] as? String, "phone")
        XCTAssertEqual(fence["generation"] as? Int, 0)
        XCTAssertEqual(fence["wal_seq"] as? Int, 0)
    }

    func testValidateAcceptsCurrentGeneration() async throws {
        let authority = try makeAuthority(self)
        try await authority.validate(FenceToken(owner: "phone", generation: 0, walSeq: 0))
        try await authority.validate(Fence(owner: "phone", generation: 0, walSeq: 0))
    }

    func testStaleGenerationIsRejected() async throws {
        let authority = try makeAuthority(self)
        _ = try await authority.issue(owner: "phone", walSeq: 5)
        do {
            try await authority.validate(FenceToken(owner: "phone", generation: 0,
                                                    walSeq: 5))
            XCTFail("a stale generation must be rejected")
        } catch {
            XCTAssertEqual(error as? FenceAuthorityError,
                           .staleGeneration(current: 1, presented: 0))
        }
        try await authority.validate(FenceToken(owner: "phone", generation: 1, walSeq: 5))
    }

    func testOwnerMismatchIsRejected() async throws {
        let authority = try makeAuthority(self)
        do {
            try await authority.validate(FenceToken(owner: "remote", generation: 0,
                                                    walSeq: 0))
            XCTFail("a different owner at the same generation is FENCE_STALE")
        } catch {
            XCTAssertEqual(error as? FenceAuthorityError,
                           .ownerMismatch(current: "phone", presented: "remote"))
        }
    }

    func testIssueIncrementsGenerationAndPersists() async throws {
        let root = ControllerTestSupport.root(for: self)
        let authority = try makeAuthority(self, root: root)
        let issued = try await authority.issue(owner: "phone", walSeq: 12)
        XCTAssertEqual(issued, FenceToken(owner: "phone", generation: 1, walSeq: 12))

        let reloaded = try makeAuthority(self, root: root)
        let current = await reloaded.current
        XCTAssertEqual(current, issued)
    }

    func testRecordWalSeqNeverLowersTheWatermark() async throws {
        let authority = try makeAuthority(self)
        _ = try await authority.recordWalSeq(9)
        do {
            _ = try await authority.recordWalSeq(8)
            XCTFail("wal_seq never decreases")
        } catch {
            XCTAssertEqual(error as? FenceAuthorityError,
                           .walSeqRegression(current: 9, presented: 8))
        }
        let current = await authority.current
        XCTAssertEqual(current.walSeq, 9)
        XCTAssertEqual(current.generation, 0)
    }

    func testHandOffInstallsGenerationPlusOneAndKeepsTokenHashed() async throws {
        let root = ControllerTestSupport.root(for: self)
        let authority = try makeAuthority(self, root: root)
        _ = try await authority.recordWalSeq(41)
        let grant = try await authority.handOff(to: "remote", walSeq: 41)
        XCTAssertEqual(grant.fence,
                       FenceToken(owner: "remote", generation: 1, walSeq: 41))
        XCTAssertEqual(grant.reclaimToken.count, 32)
        let hexCharacters = Set("0123456789abcdef")
        XCTAssertTrue(grant.reclaimToken.allSatisfy { hexCharacters.contains($0) })
        let digest = await authority.reclaimTokenDigest
        XCTAssertEqual(digest, PhoneDSHLog.SHA256.hash(Data(grant.reclaimToken.utf8)))

        let raw = try String(contentsOf: root.appendingPathComponent("fence.json"),
                             encoding: .utf8)
        XCTAssertFalse(raw.contains(grant.reclaimToken),
                       "the plaintext reclaim token must never be persisted")
        XCTAssertTrue(raw.contains("reclaim_token_sha256"))
    }

    func testTokenIsFreshPerHandOff() async throws {
        let authority = try makeAuthority(self)
        let first = try await authority.handOff(to: "remote", walSeq: 1)
        let second = try await authority.handOff(to: "phone", walSeq: 1)
        XCTAssertNotEqual(first.reclaimToken, second.reclaimToken)
        let current = await authority.current
        XCTAssertEqual(current.generation, 2)
        XCTAssertEqual(current.owner, "phone")
    }

    func testOldFenceIsStaleAfterHandOff() async throws {
        let authority = try makeAuthority(self)
        let grant = try await authority.handOff(to: "remote", walSeq: 3)
        do {
            try await authority.validate(FenceToken(owner: "phone", generation: 0,
                                                    walSeq: 3))
            XCTFail("the old phone generation must be stale")
        } catch {
            XCTAssertEqual(error as? FenceAuthorityError,
                           .staleGeneration(current: grant.fence.generation, presented: 0))
        }
    }

    func testReclaimWithValidTokenBumpsGeneration() async throws {
        let root = ControllerTestSupport.root(for: self)
        let authority = try makeAuthority(self, root: root)
        let grant = try await authority.handOff(to: "remote", walSeq: 7)
        let reclaimed = try await authority.reclaim(token: grant.reclaimToken,
                                                    walSeq: 9)
        XCTAssertEqual(reclaimed,
                       FenceToken(owner: "phone", generation: 2, walSeq: 9))
        let outstanding = await authority.isReclaimOutstanding
        XCTAssertFalse(outstanding)

        let reloaded = try makeAuthority(self, root: root)
        let current = await reloaded.current
        XCTAssertEqual(current, reclaimed)
    }

    func testReclaimIsIdempotentForTheSameToken() async throws {
        let authority = try makeAuthority(self)
        let grant = try await authority.handOff(to: "remote", walSeq: 2)
        let first = try await authority.reclaim(token: grant.reclaimToken, walSeq: 2)
        let second = try await authority.reclaim(token: grant.reclaimToken, walSeq: 2)
        XCTAssertEqual(first, second)
        let current = await authority.current
        XCTAssertEqual(current.generation, 2, "a repeated apply must not bump again")
    }

    func testInvalidReclaimTokenIsRejected() async throws {
        let authority = try makeAuthority(self)
        _ = try await authority.handOff(to: "remote", walSeq: 1)
        for invalid in ["", "xyz", String(repeating: "g", count: 32),
                        String(repeating: "0", count: 32)] {
            do {
                _ = try await authority.reclaim(token: invalid, walSeq: 1)
                XCTFail("invalid token \(invalid) was accepted")
            } catch {
                XCTAssertTrue(error is FenceAuthorityError)
            }
        }
        let current = await authority.current
        XCTAssertEqual(current.owner, "remote")
    }

    func testReclaimCannotLowerWalSeq() async throws {
        let authority = try makeAuthority(self)
        let grant = try await authority.handOff(to: "remote", walSeq: 10)
        do {
            _ = try await authority.reclaim(token: grant.reclaimToken, walSeq: 9)
            XCTFail("reclaim never lowers wal_seq")
        } catch {
            XCTAssertEqual(error as? FenceAuthorityError,
                           .walSeqRegression(current: 10, presented: 9))
        }
    }

    func testInvalidOwnerIsRejected() async throws {
        let authority = try makeAuthority(self)
        do {
            _ = try await authority.handOff(to: "../owner", walSeq: 1)
            XCTFail("invalid fence owner must be rejected")
        } catch {
            XCTAssertEqual(error as? FenceAuthorityError, .invalidOwner("../owner"))
        }
    }

    func testWireFenceMatchesCurrent() async throws {
        let authority = try makeAuthority(self)
        _ = try await authority.issue(owner: "phone", walSeq: 4)
        let wire = await authority.wireFence()
        XCTAssertEqual(wire.owner, "phone")
        XCTAssertEqual(wire.generation, 1)
        XCTAssertEqual(wire.walSeq, 4)
    }

    func testInstallReclaimedFenceClearsStaleIntentWithoutRollingBackWalSeq() async throws {
        let root = ControllerTestSupport.root(for: self)
        let authority = try makeAuthority(self, root: root)
        try await authority.markHandoffAuthorityUncertain(
            expectedGeneration: 0, walSeq: 5,
            endpoint: "https://remote.invalid")
        let grant = try await authority.handOff(to: "remote", walSeq: 5)
        _ = try await authority.reclaim(token: grant.reclaimToken, walSeq: 7)
        // Simulate a crash after the reclaimed fence was written but before
        // the stale intent was removed; local writes may have advanced wal_seq.
        try await authority.installReclaimedFence(
            Fence(owner: "phone", generation: 2, walSeq: 5))
        let current = await authority.current
        XCTAssertEqual(current, FenceToken(owner: "phone", generation: 2, walSeq: 7))
        XCTAssertNil(try FenceAuthority.loadHandoffAuthorityIntent(root: root))
    }

    func testDefiniteRejectionMarkerIsDurableAndClearable() async throws {
        let root = ControllerTestSupport.root(for: self)
        let authority = try makeAuthority(self, root: root)
        try await authority.markHandoffAuthorityUncertain(
            expectedGeneration: 0, walSeq: 12,
            endpoint: "https://remote.invalid")
        try await authority.markHandoffDefinitelyRejected()

        let raw = try FenceAuthority.loadHandoffAuthorityIntent(root: root)
        let persisted = try XCTUnwrap(raw)
        XCTAssertTrue(persisted.isDefiniteRejection)
        XCTAssertEqual(persisted.expectedGeneration, 0)
        XCTAssertEqual(persisted.walSeq, 12)

        // A new process sees the marker and may clean it without a token.
        let reloaded = try makeAuthority(self, root: root)
        let inMemory = await reloaded.handoffAuthorityIntent
        XCTAssertTrue(inMemory?.isDefiniteRejection == true)
        let outcome = try await reloaded.clearDefinitelyRejectedHandoffIntent()
        XCTAssertEqual(outcome, .definiteRejectionRemoved)
        XCTAssertNil(try FenceAuthority.loadHandoffAuthorityIntent(root: root))
    }

    func testFailedDefiniteMarkerWriteKeepsInProcessProofAndCanClear() async throws {
        let root = ControllerTestSupport.root(for: self)
        let authority = try makeAuthority(self, root: root)
        try await authority.markHandoffAuthorityUncertain(
            expectedGeneration: 0, walSeq: 12,
            endpoint: "https://remote.invalid")
        let intentURL = root.appendingPathComponent("handoff-intent.json")
        // Clobber the path so the atomic rewrite fails after the CAS has
        // already returned a definite 409, then verify the in-process proof can
        // still remove the stale path.
        try FileManager.default.removeItem(at: intentURL)
        try FileManager.default.createDirectory(at: intentURL,
                                                withIntermediateDirectories: false)
        do {
            try await authority.markHandoffDefinitelyRejected()
            XCTFail("the clobbered intent path must fail the marker rewrite")
        } catch {
            // Expected; the definite outcome must survive in memory.
        }
        let hasProof = await authority.hasUnsavedDefiniteRejectionProof
        XCTAssertTrue(hasProof)
        let inMemory = await authority.handoffAuthorityIntent
        XCTAssertTrue(inMemory?.isDefiniteRejection == true)

        try await authority.clearDefinitelyRejectedHandoffIntent()
        XCTAssertFalse(FileManager.default.fileExists(atPath: intentURL.path))
        XCTAssertNil(try FenceAuthority.loadHandoffAuthorityIntent(root: root))
        let cleared = await authority.hasUnsavedDefiniteRejectionProof
        XCTAssertFalse(cleared)
    }

    func testNewHandoffReplacesAStaleDefiniteRejectionMarker() async throws {
        let root = ControllerTestSupport.root(for: self)
        let authority = try makeAuthority(self, root: root)
        try await authority.markHandoffAuthorityUncertain(
            expectedGeneration: 0, walSeq: 12,
            endpoint: "https://remote.invalid")
        try await authority.markHandoffDefinitelyRejected()
        try await authority.markHandoffAuthorityUncertain(
            expectedGeneration: 0, walSeq: 13,
            endpoint: "https://remote.invalid")

        let raw = try FenceAuthority.loadHandoffAuthorityIntent(root: root)
        let persisted = try XCTUnwrap(raw)
        XCTAssertFalse(persisted.isDefiniteRejection)
        XCTAssertEqual(persisted.walSeq, 13)
    }

    func testDefiniteRejectionCleanupNeverClearsUnresolvedIntent() async throws {
        let root = ControllerTestSupport.root(for: self)
        let authority = try makeAuthority(self, root: root)
        try await authority.markHandoffAuthorityUncertain(
            expectedGeneration: 0, walSeq: 12,
            endpoint: "https://remote.invalid")
        let outcome = try await authority.clearDefinitelyRejectedHandoffIntent()
        XCTAssertEqual(outcome, .unmarkedIntentPresent)

        let raw = try FenceAuthority.loadHandoffAuthorityIntent(root: root)
        let persisted = try XCTUnwrap(raw)
        XCTAssertFalse(persisted.isDefiniteRejection)
    }
}
