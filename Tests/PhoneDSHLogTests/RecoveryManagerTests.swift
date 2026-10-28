// SPDX-License-Identifier: MIT
// RecoveryManager: manifest rules, tail replay, cold boot, reconcile.

import Foundation
import XCTest
@testable import PhoneDSHLog
import PhoneDSHWire

final class RecoveryManagerTests: XCTestCase {
    private func write(_ path: String, _ text: String) -> VfsMutationBody {
        LogTestSupport.write(path, data: text)
    }

    private func materializedContents(_ root: URL, _ vfsPath: String) throws -> String {
        let relative = String(vfsPath.dropFirst("/dsh/".count))
        let url = WorkspacePaths(root: root).materializedDirectory
            .appendingPathComponent(relative)
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// A durable workspace with one materialized file and a listed WAL. The
    /// epoch close leaves a legal header-only next-epoch segment, exactly like
    /// a parked host.
    private func makeDurableWorkspace(_ root: URL, boot: UInt8 = 0x90) async throws {
        let configuration = LogTestSupport.configuration(root: root)
        do {
            let log = try WorkspaceLog(configuration: configuration,
                                       bootID: LogTestSupport.bootID(boot))
            _ = try await log.append(write("/dsh/workspace/keep.txt", "keep"))
            _ = try await log.closeEpoch()
        }
    }

    func testRecoveryReplaysTheWALTailAndReportsColdBoot() async throws {
        let root = LogTestSupport.root(for: self)
        let configuration = LogTestSupport.configuration(root: root)
        let bootA = LogTestSupport.bootID(0xAA)
        let writer = try WALWriter(configuration: configuration, bootID: bootA)
        _ = try await writer.append(write("/dsh/workspace/one.txt", "one"))
        try await writer.recordMaterializedUpto(1)
        _ = try await writer.append(write("/dsh/workspace/two.txt", "two"))
        _ = try await writer.append(write("/dsh/home/three.txt", "three"))

        let bootB = LogTestSupport.bootID(0xBB)
        let manager = RecoveryManager(configuration: configuration, bootID: bootB)
        let report = try manager.recover()
        XCTAssertTrue(report.coldRecovery)
        XCTAssertEqual(report.materializedUptoMseq, 3)
        XCTAssertEqual(report.nextMseq, 4)
        XCTAssertEqual(report.ackedMseq, 3)
        XCTAssertEqual(report.nextEpoch, 2)
        XCTAssertEqual(report.replayedRecords, 2)
        XCTAssertEqual(try materializedContents(root, "/dsh/workspace/two.txt"), "two")
        XCTAssertEqual(try materializedContents(root, "/dsh/home/three.txt"), "three")

        let manifest = try XCTUnwrap(try ManifestStore(root: root).read())
        XCTAssertEqual(manifest.materializedUptoMseq, 3)
        XCTAssertEqual(manifest.lastMseq, 3)
        XCTAssertEqual(manifest.bootID, LogTestSupport.hex(bootB))

        // Opening again with the same boot id is not a cold recovery.
        let second = try RecoveryManager(configuration: configuration, bootID: bootB).recover()
        XCTAssertFalse(second.coldRecovery)
        XCTAssertEqual(second.materializedUptoMseq, 3)
    }

    func testRecoveryRebuildsWhenTheManifestIsMissing() async throws {
        let root = LogTestSupport.root(for: self)
        let configuration = LogTestSupport.configuration(root: root)
        let writer = try WALWriter(configuration: configuration,
                                   bootID: LogTestSupport.bootID(0x01))
        _ = try await writer.append(write("/dsh/workspace/a.txt", "alpha"))
        _ = try await writer.append(write("/dsh/workspace/b.txt", "beta"))
        _ = try await writer.closeEpoch()
        try FileManager.default.removeItem(at: WorkspacePaths(root: root).manifestURL)

        let report = try RecoveryManager(configuration: configuration,
                                         bootID: LogTestSupport.bootID(0x02)).recover()
        XCTAssertEqual(report.materializedUptoMseq, 2)
        XCTAssertEqual(report.nextMseq, 3)
        XCTAssertTrue(report.coldRecovery)
        XCTAssertEqual(try materializedContents(root, "/dsh/workspace/a.txt"), "alpha")
        XCTAssertEqual(try materializedContents(root, "/dsh/workspace/b.txt"), "beta")
        XCTAssertNotNil(try ManifestStore(root: root).read())
    }

    func testMissingManifestWithoutMseqOneFailsLoud() throws {
        let root = LogTestSupport.root(for: self)
        _ = try LogTestSupport.installGoldenSegment("segment-1.json", in: root)
        let manager = RecoveryManager(configuration: LogTestSupport.configuration(root: root),
                                      bootID: LogTestSupport.bootID())
        XCTAssertThrowsError(try manager.recover()) { error in
            guard case LogError.corrupt = error else {
                return XCTFail("expected WAL_CORRUPT, got \(error)")
            }
        }
    }

    func testRecoveryDropsFullyMaterializedDurableEpochs() async throws {
        let root = LogTestSupport.root(for: self)
        var configuration = LogTestSupport.configuration(root: root)
        configuration.segmentRollBytes = 260
        let writer = try WALWriter(configuration: configuration,
                                   bootID: LogTestSupport.bootID())
        for index in 0..<4 {
            _ = try await writer.append(
                write("/dsh/workspace/e1-\(index)", String(repeating: "a", count: 120)))
        }
        try await writer.recordMaterializedUpto(4)
        _ = try await writer.closeEpoch()
        for index in 0..<2 {
            _ = try await writer.append(
                write("/dsh/workspace/e2-\(index)", String(repeating: "b", count: 120)))
        }
        try await writer.recordMaterializedUpto(6)
        _ = try await writer.closeEpoch()
        _ = try await writer.append(write("/dsh/workspace/e3", "tail"))
        let epochOneSegments = try LogTestSupport.segments(in: root).filter { $0.epoch == 1 }
        XCTAssertGreaterThan(epochOneSegments.count, 1)

        let report = try RecoveryManager(configuration: configuration,
                                         bootID: LogTestSupport.bootID(0x55)).recover()
        XCTAssertEqual(report.materializedUptoMseq, 7)
        XCTAssertEqual(report.nextMseq, 8)
        XCTAssertFalse(report.droppedSegments.isEmpty)
        let remaining = try LogTestSupport.segments(in: root)
        XCTAssertTrue(remaining.allSatisfy { $0.epoch != 1 })
        for segment in epochOneSegments {
            XCTAssertFalse(FileManager.default.fileExists(atPath: segment.url.path))
        }
        XCTAssertEqual(try materializedContents(root, "/dsh/workspace/e3"), "tail")
    }

    func testTruncatedWALTailBelowTheMaterializedWatermarkIsLegal() async throws {
        let root = LogTestSupport.root(for: self)
        let configuration = LogTestSupport.configuration(root: root)
        let writer = try WALWriter(configuration: configuration,
                                   bootID: LogTestSupport.bootID(0x66))
        _ = try await writer.append(write("/dsh/workspace/a.txt", "alpha"))
        _ = try await writer.append(write("/dsh/workspace/b.txt", "beta"))
        try await writer.recordMaterializedUpto(2)
        _ = try await writer.closeEpoch()
        let materializer = try Materializer(root: root)
        _ = try materializer.apply(records: try LogTestSupport.records(in: root))
        try materializer.fsyncEpoch()
        for segment in try LogTestSupport.segments(in: root) {
            try FileManager.default.removeItem(at: segment.url)
        }

        let report = try RecoveryManager(configuration: configuration,
                                         bootID: LogTestSupport.bootID(0x67)).recover()
        XCTAssertEqual(report.materializedUptoMseq, 2)
        XCTAssertEqual(report.ackedMseq, 2, "last_mseq survives truncation (D17)")
        XCTAssertEqual(report.nextMseq, 3)
        XCTAssertEqual(try materializedContents(root, "/dsh/workspace/a.txt"), "alpha")
        XCTAssertEqual(try materializedContents(root, "/dsh/workspace/b.txt"), "beta")
    }

    func testRecoveryReportsATornTail() async throws {
        let root = LogTestSupport.root(for: self)
        let configuration = LogTestSupport.configuration(root: root)
        let writer = try WALWriter(configuration: configuration,
                                   bootID: LogTestSupport.bootID())
        _ = try await writer.append(write("/dsh/workspace/a.txt", "a"))
        _ = try await writer.append(write("/dsh/workspace/b.txt", "b"))
        let segmentURL = try XCTUnwrap(try LogTestSupport.segments(in: root).last?.url)
        let handle = try FileHandle(forWritingTo: segmentURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data([0x00, 0x00]))
        try handle.close()

        let report = try RecoveryManager(configuration: configuration,
                                         bootID: LogTestSupport.bootID(0x77)).recover()
        XCTAssertTrue(report.truncatedTornTail)
        XCTAssertEqual(report.materializedUptoMseq, 2)
        XCTAssertEqual(try materializedContents(root, "/dsh/workspace/b.txt"), "b")
    }

    func testReconcileSnapshotReportsEveryDifferenceKind() throws {
        let root = LogTestSupport.root(for: self)
        let materializer = try Materializer(root: root)
        _ = try materializer.apply(try WALRecord(mseq: 1, mutation: write(
            "/dsh/workspace/a.txt", "abc")))
        _ = try materializer.apply(try WALRecord(mseq: 2, mutation: write(
            "/dsh/home/sessions/s.txt", "12345")))
        _ = try materializer.apply(try WALRecord(mseq: 3, mutation: write(
            "/dsh/home/other.txt", "xy")))
        _ = try materializer.apply(try WALRecord(mseq: 4, mutation: LogTestSupport.mkdir(
            "/dsh/workspace/dir")))

        let manager = RecoveryManager(configuration: LogTestSupport.configuration(root: root),
                                      bootID: LogTestSupport.bootID())
        let snapshot = [
            SnapshotEntry(path: "/dsh/workspace/a.txt", size: 3,
                          sha256: SHA256.hash(Data("abc".utf8))),
            SnapshotEntry(path: "/dsh/home/sessions/s.txt", size: 5,
                          sha256: SHA256.hash(Data("wrong".utf8))),
            SnapshotEntry(path: "/dsh/workspace/dir", size: 0,
                          sha256: SHA256.hash(Data())),
            SnapshotEntry(path: "/dsh/workspace/ghost.txt", size: 7,
                          sha256: SHA256.hash(Data("ghost".utf8))),
        ]
        let differences = try manager.reconcile(snapshot: snapshot)
        let byPath = Dictionary(uniqueKeysWithValues: differences.map { ($0.path, $0.kind) })
        XCTAssertNil(byPath["/dsh/workspace/a.txt"])
        XCTAssertEqual(byPath["/dsh/home/sessions/s.txt"], .digestMismatch)
        XCTAssertEqual(byPath["/dsh/workspace/dir"], .typeMismatch)
        XCTAssertEqual(byPath["/dsh/workspace/ghost.txt"], .missingOnDisk)
        XCTAssertEqual(byPath["/dsh/home/other.txt"], .missingInSnapshot)
    }

    func testReconcileMarkerTriggersAStagedReconcile() async throws {
        let root = LogTestSupport.root(for: self)
        let configuration = LogTestSupport.configuration(root: root)
        let writer = try WALWriter(configuration: configuration,
                                   bootID: LogTestSupport.bootID())
        _ = try await writer.append(write("/dsh/workspace/one.txt", "one"))
        _ = try await writer.append(write("/dsh/workspace/two.txt", "two"))
        try await writer.recordMaterializedUpto(1)

        let materializer = try Materializer(root: root, materializedUptoMseq: 1)
        _ = try materializer.apply(try WALRecord(mseq: 1, mutation: write(
            "/dsh/workspace/one.txt", "one")))
        let marker = WorkspacePaths(root: root).reconcileMarkerURL
        try Data("{\"boot_id\":\"ignored\"}".utf8).write(to: marker)

        let report = try RecoveryManager(configuration: configuration,
                                         bootID: LogTestSupport.bootID(0x33)).recover()
        XCTAssertTrue(report.reconciled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        XCTAssertEqual(report.materializedUptoMseq, 2)
        XCTAssertEqual(try materializedContents(root, "/dsh/workspace/two.txt"), "two")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: WorkspacePaths(root: root).stagingDirectory.path))
    }

    func testRecoveryNextEpochNeverReusesAnExistingSegmentEpoch() async throws {
        let root = LogTestSupport.root(for: self)
        let configuration = LogTestSupport.configuration(root: root)
        let writer = try WALWriter(configuration: configuration,
                                   bootID: LogTestSupport.bootID())
        _ = try await writer.append(write("/dsh/workspace/a", "a"))
        _ = try await writer.closeEpoch()
        let report = try RecoveryManager(configuration: configuration,
                                         bootID: LogTestSupport.bootID(0x44)).recover()
        let highest = try LogTestSupport.segments(in: root).map(\.epoch).max() ?? 0
        XCTAssertGreaterThan(report.nextEpoch, highest)
        // The writer's empty open epoch segment must not be dropped as stale
        // before its epoch number is consumed.
        XCTAssertEqual(report.materializedUptoMseq, 1)
    }

    // MARK: - Decoded-but-impossible manifest (G2-FIX-127)

    /// A schema-valid manifest that decodes but whose watermark is above the
    /// acknowledged tail is `WAL_CORRUPT`, not a missing manifest. Before the
    /// fix the read and the structural validation shared one `do/catch`, so
    /// this checkpoint was treated as absent and rebuildable.
    func testImpossibleManifestWatermarkFailsLoudInsteadOfRebuilding() throws {
        let root = LogTestSupport.root(for: self)
        let boot = LogTestSupport.bootID(0x81)
        let invalid = Manifest(bootID: LogTestSupport.hex(boot),
                               materializedUptoMseq: 2,
                               lastMseq: 1,
                               lastDurableEpoch: 0,
                               segments: [])
        try ManifestStore(root: root).write(invalid)

        XCTAssertThrowsError(try RecoveryManager(
            configuration: LogTestSupport.configuration(root: root),
            bootID: LogTestSupport.bootID(0x82)).recover()) { error in
            guard case LogError.corrupt(let detail) = error else {
                return XCTFail("expected WAL_CORRUPT for the impossible manifest, got \(error)")
            }
            XCTAssertTrue(detail.contains("materialized_upto_mseq"),
                          "the fail-loud reason must name the invalid checkpoint: \(detail)")
        }
        XCTAssertEqual(try ManifestStore(root: root).read(), invalid,
                       "the impossible checkpoint must not be rebuilt as a new workspace")
    }

    /// The same split also keeps a duplicate `segments[]` entry from being
    /// silently discarded as a schema-invalid (= missing) manifest.
    func testDuplicateManifestSegmentFailsLoudInsteadOfRebuilding() throws {
        let root = LogTestSupport.root(for: self)
        let boot = LogTestSupport.bootID(0x83)
        let segment = ManifestSegment(file: "wal/00000001.000000.xlwal",
                                      epoch: 1,
                                      firstMseq: 1,
                                      lastMseq: 1)
        let invalid = Manifest(bootID: LogTestSupport.hex(boot),
                               materializedUptoMseq: 1,
                               lastMseq: 1,
                               lastDurableEpoch: 0,
                               segments: [segment, segment])
        try ManifestStore(root: root).write(invalid)

        XCTAssertThrowsError(try RecoveryManager(
            configuration: LogTestSupport.configuration(root: root),
            bootID: LogTestSupport.bootID(0x84)).recover()) { error in
            guard case LogError.corrupt(let detail) = error else {
                return XCTFail("expected WAL_CORRUPT for the duplicate segment, got \(error)")
            }
            XCTAssertTrue(detail.contains("twice"),
                          "the fail-loud reason must name the duplicate: \(detail)")
        }
        XCTAssertEqual(try ManifestStore(root: root).read(), invalid,
                       "the duplicate checkpoint must not be rebuilt as a new workspace")
    }

    // MARK: - Materialized-copy crash leftovers (G2-FIX-127)

    /// A completed workspace can carry a rebuild scratch tree
    /// (`materialized.verify`) and the swap's old tree
    /// (`.materialized.previous`) from the previous boot. Recovery sweeps both
    /// immediately instead of waiting for the next swap to clean them.
    func testStartupSweepRemovesVerifyAndPreviousLeftovers() async throws {
        let root = LogTestSupport.root(for: self)
        try await makeDurableWorkspace(root, boot: 0x91)
        let verify = root.appendingPathComponent("materialized.verify", isDirectory: true)
        let previous = root.appendingPathComponent(".materialized.previous", isDirectory: true)
        try FileManager.default.createDirectory(at: verify, withIntermediateDirectories: true)
        try Data("scratch".utf8).write(to: verify.appendingPathComponent("sentinel"))
        try FileManager.default.createDirectory(at: previous, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: previous.appendingPathComponent("sentinel"))

        let report = try RecoveryManager(
            configuration: LogTestSupport.configuration(root: root),
            bootID: LogTestSupport.bootID(0x92)).recover()
        XCTAssertEqual(report.materializedUptoMseq, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: verify.path),
                       "materialized.verify is a rebuild scratch and must not survive startup")
        XCTAssertFalse(FileManager.default.fileExists(atPath: previous.path),
                       "the redundant previous tree must not survive startup")
        XCTAssertEqual(try materializedContents(root, "/dsh/workspace/keep.txt"), "keep")
    }
}
