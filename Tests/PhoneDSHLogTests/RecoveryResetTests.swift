// SPDX-License-Identifier: MIT
// PhoneDSHLog: the mid-materialization reset keeps the tree and drops the WAL.

import Foundation
import XCTest
@testable import PhoneDSHLog

final class RecoveryResetTests: XCTestCase {
    private func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdsh-reset-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("wal"),
                                                withIntermediateDirectories: true)
        return root
    }

    func testAdoptMaterializedTreeDropsTheRetainedWAL() throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let wal = root.appendingPathComponent("wal")
        let retained = wal.appendingPathComponent("00000001.000000.xlwal")
        let openEpoch = wal.appendingPathComponent("00000002.000000.xlwal")
        try Data([1, 2, 3]).write(to: retained)
        try Data([4, 5, 6]).write(to: openEpoch)

        let store = ManifestStore(root: root)
        let manifest = Manifest(bootID: "9a2a4dccccb58486fed0c3f9dd6fbff6",
                                materializedUptoMseq: 17,
                                lastMseq: 19,
                                lastDurableEpoch: 1,
                                segments: [ManifestSegment(file: "wal/00000001.000000.xlwal",
                                                           epoch: 1, firstMseq: 1, lastMseq: 5)])
        try store.write(manifest)

        let watermark = try RecoveryReset.adoptMaterializedTree(root: root)
        XCTAssertEqual(watermark, 17)
        XCTAssertFalse(FileManager.default.fileExists(atPath: retained.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: openEpoch.path))
        let rewritten = try XCTUnwrap(store.read())
        XCTAssertEqual(rewritten.segments, [])
        XCTAssertEqual(rewritten.materializedUptoMseq, 17)
        XCTAssertEqual(rewritten.lastMseq, 19)
    }

    func testOnlyTheMaterializedDivergenceIsRecognised() {
        XCTAssertTrue(LogError.corrupt(
            "materialized copy diverges from the retained WAL: contentMismatch x")
            .isMaterializedDivergence)
        XCTAssertFalse(LogError.corrupt("manifest.json is not valid").isMaterializedDivergence)
        XCTAssertFalse(LogError.quotaExceeded(resource: .wal, limit: 1, used: 2)
            .isMaterializedDivergence)
    }
}
