// SPDX-License-Identifier: MIT
// W3 budgets.md §9: the aggregate host-internal view and the five silent or
// user-visible levels. The thresholds are policy defaults, not measurements.

import XCTest
@testable import PhoneDSHController

final class HostStoragePolicyTests: XCTestCase {
    private let mib = 1024 * 1024

    func testLevelZeroIsSilentAndReclaimsDroppableData() {
        let usage = HostStorageUsage(walBytes: 10 * mib, materializedBytes: 20 * mib,
                                     workspaceLogicalBytes: 100 * mib,
                                     availableImportantBytes: 10_000 * mib,
                                     volumeBytes: 64_000 * mib)
        let decision = HostStoragePolicy.standard.decision(for: usage,
                                                           workspaceBucketBytes: 288 * mib)
        XCTAssertEqual(decision.level, .zero)
        XCTAssertTrue(decision.isSilent)
        XCTAssertEqual(decision.actions, [.reclaimDroppable])
    }

    func testLevelOneFiresWhenInternalBytesExceedOnePointThreeTimesWorkspace() {
        let usage = HostStorageUsage(walBytes: 200 * mib, materializedBytes: 100 * mib,
                                     workspaceLogicalBytes: 100 * mib,
                                     availableImportantBytes: 10_000 * mib,
                                     volumeBytes: 64_000 * mib)
        let decision = HostStoragePolicy.standard.decision(for: usage,
                                                           workspaceBucketBytes: 288 * mib)
        XCTAssertEqual(decision.level, .one)
        XCTAssertTrue(decision.isSilent)
        XCTAssertEqual(decision.actions, [.reclaimDroppable, .pruneCaches])
    }

    func testLevelTwoUsesThe512MiBFloorOrTenPercent() {
        let usage = HostStorageUsage(walBytes: 10 * mib, materializedBytes: 10 * mib,
                                     workspaceLogicalBytes: 10 * mib,
                                     availableImportantBytes: 400 * mib,
                                     volumeBytes: 64_000 * mib)
        let decision = HostStoragePolicy.standard.decision(for: usage,
                                                           workspaceBucketBytes: 288 * mib)
        XCTAssertEqual(decision.level, .two)
        XCTAssertTrue(decision.isSilent)
        XCTAssertEqual(decision.actions,
                       [.reclaimDroppable, .pruneCaches, .stopCreatingCaches])
    }

    func testLevelThreeProducesOnlyTheSignal() {
        let usage = HostStorageUsage(walBytes: 4 * mib, materializedBytes: 4 * mib,
                                     workspaceLogicalBytes: 270 * mib,
                                     availableImportantBytes: 10_000 * mib,
                                     volumeBytes: 64_000 * mib)
        let decision = HostStoragePolicy.standard.decision(
            for: usage,
            workspaceBucketBytes: 288 * mib,
            largestFiles: [HostStorageFile(relativePath: "video.mov",
                                           byteCount: 200 * mib)])
        XCTAssertEqual(decision.level, .three)
        XCTAssertEqual(decision.userSurface, .workspaceCard)
        XCTAssertEqual(decision.signal?.largestFiles.first?.relativePath, "video.mov")
        XCTAssertNil(decision.failure)
    }

    func testLevelFourIsTheOnlyNewFailureAndReusesQuotaVocabulary() {
        let usage = HostStorageUsage(walBytes: 10 * mib, materializedBytes: 10 * mib,
                                     workspaceLogicalBytes: 280 * mib,
                                     availableImportantBytes: 100 * mib,
                                     volumeBytes: 64_000 * mib)
        let decision = HostStoragePolicy.standard.decision(for: usage,
                                                           workspaceBucketBytes: 288 * mib,
                                                           writeWouldFail: true)
        XCTAssertEqual(decision.level, .four)
        XCTAssertEqual(decision.userSurface, .quotaError)
        XCTAssertNotNil(decision.failure)
        XCTAssertTrue(decision.failure?.errorDescription?.contains("quota") == true)
    }

    func testRebuildableDataKeepsAWouldFailWriteAtLevelThree() {
        let usage = HostStorageUsage(walBytes: 10 * mib, materializedBytes: 10 * mib,
                                     overlayCacheBytes: 8 * mib,
                                     workspaceLogicalBytes: 280 * mib,
                                     availableImportantBytes: 100 * mib,
                                     volumeBytes: 64_000 * mib)
        let decision = HostStoragePolicy.standard.decision(for: usage,
                                                           workspaceBucketBytes: 288 * mib,
                                                           writeWouldFail: true)
        XCTAssertEqual(decision.level, .three,
                       "a reclaimable cache must be pruned before failing the write")
    }

    func testOutboxAttachmentsCountButAreNeverDeleted() {
        let usage = HostStorageUsage(walBytes: 1 * mib,
                                     outboxAttachmentBytes: 100 * mib,
                                     workspaceLogicalBytes: 10 * mib,
                                     availableImportantBytes: 10_000 * mib,
                                     volumeBytes: 64_000 * mib)
        XCTAssertEqual(usage.hostInternalBytes, 1 * mib)
        XCTAssertEqual(usage.budgetedBytes, 101 * mib)
        let decision = HostStoragePolicy.standard.decision(for: usage,
                                                           workspaceBucketBytes: 288 * mib)
        XCTAssertFalse(decision.actions.contains(.failWrite))
        XCTAssertFalse(decision.actions.contains(.pruneCaches),
                       "the outbox alone must not trigger cache pruning")
    }

    func testCardGateEmitsAtMostOncePerWorkspacePerDay() {
        var gate = WorkspaceQuotaCardGate()
        XCTAssertTrue(gate.shouldEmit(workspaceID: "ws-1", day: "2026-11-12"))
        XCTAssertFalse(gate.shouldEmit(workspaceID: "ws-1", day: "2026-11-12"))
        XCTAssertTrue(gate.shouldEmit(workspaceID: "ws-2", day: "2026-11-12"))
        XCTAssertTrue(gate.shouldEmit(workspaceID: "ws-1", day: "2026-11-13"))
    }
}
