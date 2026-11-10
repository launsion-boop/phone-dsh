// SPDX-License-Identifier: MIT
// §9 durable-epoch truncation and the §10 recovery fast path.
//
// Every shared lifecycle vector under `spec/v1/golden/wal/lifecycle` becomes a
// real workspace: its manifest, its segment bytes and a materialized copy built
// by the production Materializer from the records at or below the checkpoint
// watermark. `RecoveryManager.recover()` then runs the production scan, replay,
// verification and truncation. Nothing here copies the rule's expected values
// into the implementation input.

import Foundation
import XCTest
@testable import PhoneDSHLog
import PhoneDSHWire

final class RecoveryDurableEpochTruncationTests: XCTestCase {
    private struct SegmentFixture: Decodable {
        var file: String
        var fileHex: String
        var firstMseq: UInt64
        var lastMseq: UInt64
        var hasEpochClose: Bool

        enum CodingKeys: String, CodingKey {
            case file
            case fileHex = "file_hex"
            case firstMseq = "first_mseq"
            case lastMseq = "last_mseq"
            case hasEpochClose = "has_epoch_close"
        }

        var fileName: String {
            URL(fileURLWithPath: file).lastPathComponent
        }
    }

    private struct Expected: Decodable {
        var fastPath: Bool
        var verificationPass: Bool
        var hasUnclosedHistory: Bool
        var replayRecords: Int
        var materializedUptoMseq: UInt64
        var newestCloseSegment: String?
        var droppedSegments: [String]
        var retainedSegments: [String]
        var relistedSegments: [String]
        var adoptedTailSegments: [String]

        enum CodingKeys: String, CodingKey {
            case fastPath = "fast_path"
            case verificationPass = "verification_pass"
            case hasUnclosedHistory = "has_unclosed_history"
            case replayRecords = "replay_records"
            case materializedUptoMseq = "materialized_upto_mseq"
            case newestCloseSegment = "newest_close_segment"
            case droppedSegments = "dropped_segments"
            case retainedSegments = "retained_segments"
            case relistedSegments = "relisted_segments"
            case adoptedTailSegments = "adopted_tail_segments"
        }
    }

    private struct LifecycleVector: Decodable {
        var id: String
        var title: String
        var manifest: Manifest
        var segments: [SegmentFixture]
        var expected: Expected
    }

    // MARK: - Shared runners

    private func loadVectors() throws -> [LifecycleVector] {
        let directory = try LogTestSupport.goldenLifecycleDirectory()
        let files = try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        XCTAssertEqual(files.count, 5,
                       "expected the five frozen lifecycle vectors, found \(files.count)")
        return try files.map { file in
            try JSONDecoder().decode(LifecycleVector.self, from: Data(contentsOf: file))
        }
    }

    /// Installs the vector and builds the durable copy by replaying exactly the
    /// mutations the manifest watermark claims are materialized.
    @discardableResult
    private func install(_ vector: LifecycleVector,
                         in root: URL) throws -> WALScan {
        let paths = WorkspacePaths(root: root)
        try paths.createDirectories()
        try ManifestStore(paths: paths).write(vector.manifest)
        for segment in vector.segments {
            let data = try LogTestSupport.data(hex: segment.fileHex)
            try data.write(to: paths.walDirectory.appendingPathComponent(segment.fileName))
        }
        let scan = try WALReader.scan(directory: paths.walDirectory)
        let durable = scan.allRecords
            .filter { !$0.isEpochClose && $0.mseq <= vector.manifest.materializedUptoMseq }
            .sorted { $0.mseq < $1.mseq }
        let materializer = try Materializer(root: root,
                                            materializedUptoMseq: 0)
        _ = try materializer.apply(records: durable)
        try materializer.fsyncEpoch()
        return scan
    }

    private func recover(root: URL,
                         boot: UInt8) throws -> (RecoveryReport, Int) {
        let verifications = LockedValues<Bool>()
        var manager = RecoveryManager(
            configuration: LogTestSupport.configuration(root: root),
            bootID: LogTestSupport.bootID(boot))
        manager.verificationObserver = { verifications.append(true) }
        let report = try manager.recover()
        return (report, verifications.values.count)
    }

    private func segmentFiles(in root: URL) throws -> Set<String> {
        let names = try FileManager.default.contentsOfDirectory(
            atPath: WorkspacePaths(root: root).walDirectory.path)
        return Set(names.filter { $0.hasSuffix(".xlwal") }.map { "wal/" + $0 })
    }

    // MARK: - Golden vectors

    func testEveryLifecycleVectorDrivesRealRecovery() throws {
        for vector in try loadVectors() {
            let root = LogTestSupport.root(for: self, name: vector.id)
            try install(vector, in: root)
            let (report, verificationRuns) = try recover(root: root, boot: 0x5A)

            XCTAssertEqual(report.materializedUptoMseq,
                           vector.expected.materializedUptoMseq,
                           "\(vector.id): watermark")
            XCTAssertEqual(report.replayedRecords,
                           vector.expected.replayRecords,
                           "\(vector.id): replayed records")
            XCTAssertEqual(Set(report.droppedSegments),
                           Set(vector.expected.droppedSegments),
                           "\(vector.id): dropped segments")
            XCTAssertEqual(verificationRuns,
                           vector.expected.verificationPass ? 1 : 0,
                           "\(vector.id): full verification pass")
            XCTAssertTrue(report.needsResync.isEmpty,
                          "\(vector.id): no resync in these vectors")

            let remaining = try segmentFiles(in: root)
            XCTAssertEqual(remaining,
                           Set(vector.expected.retainedSegments),
                           "\(vector.id): files left in wal/")
            let manifest = try XCTUnwrap(ManifestStore(root: root).read())
            XCTAssertEqual(Set(manifest.segments.map(\.file)),
                           Set(vector.expected.retainedSegments),
                           "\(vector.id): manifest segments")
            XCTAssertEqual(manifest.materializedUptoMseq,
                           vector.expected.materializedUptoMseq,
                           "\(vector.id): manifest watermark")
            for relisted in vector.expected.relistedSegments {
                XCTAssertTrue(manifest.segments.contains { $0.file == relisted },
                              "\(vector.id): \(relisted) must be re-listed")
            }
            if let newest = vector.expected.newestCloseSegment {
                XCTAssertTrue(remaining.contains(newest),
                              "\(vector.id): the newest close segment stays")
            }
            if !vector.expected.adoptedTailSegments.isEmpty {
                XCTAssertGreaterThan(report.replayedRecords, 0,
                                     "\(vector.id): the adopted tail is replayed")
            }
        }
    }

    /// A stale segment is only re-listed by the recovery that first sees it.
    /// Once a later durable epoch has advanced `last_durable_epoch`, the next
    /// boot may drop it under the same §9 rule as any other listed old epoch.
    func testRelistedStaleSegmentIsDroppableAfterALaterDurableEpoch() throws {
        let vector = try XCTUnwrap(try loadVectors()
            .first { $0.id == "unlisted-stale-relisted" })
        let root = LogTestSupport.root(for: self, name: "relisted-then-dropped")
        try install(vector, in: root)

        let (first, firstVerification) = try recover(root: root, boot: 0x61)
        XCTAssertEqual(firstVerification, 1)
        let staleFile = try XCTUnwrap(vector.expected.relistedSegments.first)
        XCTAssertFalse(first.droppedSegments.contains(staleFile),
                       "the recovery that re-lists a stale segment must not unlink it")
        XCTAssertTrue(try segmentFiles(in: root).contains(staleFile))

        // The next close after that boot is above the stale epoch. The index is
        // synthetic but follows the manifest contract: last_durable_epoch is
        // the only marker and no close record is required for an older epoch.
        let paths = WorkspacePaths(root: root)
        var manifest = try XCTUnwrap(ManifestStore(paths: paths).read())
        manifest.lastDurableEpoch = max(manifest.lastDurableEpoch, 220)
        try ManifestStore(paths: paths).write(manifest)

        let (second, secondVerification) = try recover(root: root, boot: 0x62)
        XCTAssertEqual(secondVerification, 0,
                       "after the marker advances the clean checkpoint takes the fast path")
        XCTAssertTrue(second.droppedSegments.contains(staleFile),
                      "a listed unclosed epoch at or below last_durable_epoch is droppable")
        XCTAssertFalse(try segmentFiles(in: root).contains(staleFile))
    }

    // MARK: - The pure §9 rule

    func testDroppableRuleRequiresManifestListingAndDurableEpoch() {
        let candidate = WALSegmentLifecycleRecord(
            file: "wal/00000215.000000.xlwal", epoch: 215, segment: 0,
            firstMseq: 1, lastMutationMseq: 2,
            hasRecords: true, hasEpochClose: false)
        let newest = WALSegmentLifecycleRecord(
            file: "wal/00000217.000000.xlwal", epoch: 217, segment: 0,
            firstMseq: 4, lastMutationMseq: 4,
            hasRecords: true, hasEpochClose: true)
        func droppable(listed: Set<String> = [candidate.file],
                       durable: UInt64 = 217,
                       watermark: UInt64 = 4,
                       newestClose: WALSegmentLifecycleRecord? = newest,
                       current: Bool = false,
                       mutationsBelow: Bool = true) -> Bool {
            WALSegmentLifecycle.isDroppable(
                candidate,
                listedFiles: listed,
                lastDurableEpoch: durable,
                materializedUptoMseq: watermark,
                newestEpochClose: newestClose,
                isCurrent: current,
                allMutationsAtOrBelowWatermark: mutationsBelow)
        }
        XCTAssertTrue(droppable(), "listed + epoch <= marker + below watermark")
        XCTAssertFalse(droppable(listed: []), "an unlisted segment is never droppable")
        XCTAssertFalse(droppable(durable: 214), "an epoch above the marker is the crash tail")
        XCTAssertFalse(droppable(watermark: 1), "a mutation above the watermark blocks it")
        XCTAssertFalse(droppable(current: true), "the open segment is never droppable")
        XCTAssertFalse(droppable(newestClose: candidate),
                       "the newest epoch-close segment is never droppable")
    }

    // MARK: - Zero-length segments (§7.2)

    func testUnlistedZeroLengthSegmentIsDroppedAfterTheCheckpoint() throws {
        let vector = try XCTUnwrap(try loadVectors()
            .first { $0.id == "unclosed-epoch-below-watermark" })
        let root = LogTestSupport.root(for: self, name: "zero-length-unlisted")
        try install(vector, in: root)
        _ = try recover(root: root, boot: 0x71)

        let paths = WorkspacePaths(root: root)
        let zero = paths.walDirectory.appendingPathComponent("00000099.000000.xlwal")
        try Data().write(to: zero)

        let (second, _) = try recover(root: root, boot: 0x72)
        XCTAssertTrue(second.droppedSegments.contains("wal/00000099.000000.xlwal"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: zero.path))
    }

    func testListedZeroLengthSegmentAboveTheWatermarkStillFailsLoud() throws {
        let vector = try XCTUnwrap(try loadVectors()
            .first { $0.id == "unclosed-epoch-below-watermark" })
        let root = LogTestSupport.root(for: self, name: "zero-length-listed")
        try install(vector, in: root)
        _ = try recover(root: root, boot: 0x73)

        let paths = WorkspacePaths(root: root)
        let zeroName = "wal/00000099.000000.xlwal"
        let zero = paths.walDirectory.appendingPathComponent("00000099.000000.xlwal")
        try Data().write(to: zero)
        var manifest = try XCTUnwrap(ManifestStore(paths: paths).read())
        let ghostMseq = manifest.materializedUptoMseq + 1
        manifest.lastMseq = max(manifest.lastMseq, ghostMseq)
        manifest.segments.append(ManifestSegment(file: zeroName,
                                                 epoch: 99,
                                                 firstMseq: ghostMseq,
                                                 lastMseq: ghostMseq))
        try ManifestStore(paths: paths).write(manifest)

        XCTAssertThrowsError(try RecoveryManager(
            configuration: LogTestSupport.configuration(root: root),
            bootID: LogTestSupport.bootID(0x74)).recover()) { error in
            guard case LogError.corrupt(let detail) = error else {
                return XCTFail("expected WAL_CORRUPT, got \(error)")
            }
            XCTAssertTrue(detail.contains("above the watermark"), detail)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: zero.path),
                      "a listed zero-length file above the watermark is not blindly dropped")
    }
}
