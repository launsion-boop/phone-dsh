// SPDX-License-Identifier: MIT
// W0 skeleton checks for PhoneDSHLog (PLAN §2.3).

import Foundation
import XCTest
import PhoneDSHLog

final class WorkspaceLogSkeletonTests: XCTestCase {
    func testConfigurationDefaultsMatchPlanQuotas() {
        let configuration = WorkspaceLogConfiguration(
            root: FileManager.default.temporaryDirectory.appendingPathComponent("workspace"))
        XCTAssertEqual(configuration.walQuotaBytes, 512 * 1024 * 1024)
        XCTAssertEqual(configuration.journalQuotaBytes, 64 * 1024 * 1024)
        XCTAssertEqual(configuration.responseLogQuotaBytes, 128 * 1024 * 1024)
        XCTAssertEqual(configuration.segmentRollBytes, 8 * 1024 * 1024)
        XCTAssertEqual(configuration.epochIntervalSeconds, 45)
    }

    func testAckLevelsMatchTheChannel() {
        XCTAssertEqual(AckLevel.write.rawValue, 1)
        XCTAssertEqual(AckLevel.epochFsync.rawValue, 2)
        XCTAssertEqual(AckLevel.allCases.count, 2)
        XCTAssertEqual(AckLevel.epochFsync.wireLevel, .epochFsync)
        XCTAssertEqual(WorkspaceLogAck(level: .write, uptoMseq: 7).wireBody.uptoMseq, 7)
    }

    func testRecoveryDefaultsAreEmptyWorkspace() {
        let recovery = WorkspaceLogRecovery(
            materializedUptoMseq: 0, nextMseq: 1, durableMseq: 0,
            lastDurableEpoch: 0, truncatedTornTail: false)
        XCTAssertEqual(recovery.nextMseq, 1)
        XCTAssertEqual(recovery.materializedUptoMseq, 0)
    }
}
