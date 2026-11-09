// SPDX-License-Identifier: MIT
// Optional real-device recovery replay. Skipped unless PDSH_WAL_REPLAY_DIR
// points at a copy of a phone's chat-host workspace (the directory that holds
// `manifest.json` and `wal/`). The test runs on a temporary copy and never
// edits the source directory.

import Foundation
import XCTest
@testable import PhoneDSHLog

final class WALRealDeviceReplayTests: XCTestCase {
    func testReplayRealDeviceWorkspaceWhenConfigured() throws {
        guard let sourcePath = ProcessInfo.processInfo.environment["PDSH_WAL_REPLAY_DIR"],
              !sourcePath.isEmpty else {
            throw XCTSkip("PDSH_WAL_REPLAY_DIR is not set; real-device replay is opt-in")
        }
        let source = URL(fileURLWithPath: sourcePath, isDirectory: true)
        guard FileManager.default.fileExists(
            atPath: source.appendingPathComponent("manifest.json").path) else {
            XCTFail("PDSH_WAL_REPLAY_DIR must name the workspace root holding manifest.json: \(sourcePath)")
            return
        }

        let sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdsh-wal-replay-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let root = sandbox.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: source, to: root)

        let walSizeBefore = try walBytes(in: root)
        let verifications = LockedValues<Bool>()
        var manager = RecoveryManager(
            configuration: LogTestSupport.configuration(root: root),
            bootID: LogTestSupport.bootID(0x7A))
        manager.verificationObserver = { verifications.append(true) }
        let started = Date()
        let report = try manager.recover()
        let seconds = Date().timeIntervalSince(started)
        let walSizeAfter = try walBytes(in: root)
        let reclaimed = max(0, walSizeBefore - walSizeAfter)

        print("PDSH_WAL_REPLAY_DIR=\(sourcePath)")
        print(String(format: "recovery_seconds=%.3f", seconds))
        print("fast_path=\(verifications.values.isEmpty)")
        print("replayed_records=\(report.replayedRecords)")
        print("dropped_segments=\(report.droppedSegments.sorted().joined(separator: ","))")
        print("reclaimed_bytes=\(reclaimed)")
        print("wal_bytes_before=\(walSizeBefore) wal_bytes_after=\(walSizeAfter)")
        print("materialized_upto_mseq=\(report.materializedUptoMseq)")
        print("acked_mseq=\(report.ackedMseq)")
        XCTAssertGreaterThanOrEqual(walSizeAfter, 0)
        XCTAssertLessThanOrEqual(reclaimed, walSizeBefore)
    }

    private func walBytes(in root: URL) throws -> Int {
        let directory = WorkspacePaths(root: root).walDirectory
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return try names
            .filter { $0.hasSuffix(".xlwal") }
            .reduce(0) { partial, name in
                let path = directory.appendingPathComponent(name).path
                let attributes = try FileManager.default.attributesOfItem(atPath: path)
                return partial + ((attributes[.size] as? NSNumber)?.intValue ?? 0)
            }
    }
}
