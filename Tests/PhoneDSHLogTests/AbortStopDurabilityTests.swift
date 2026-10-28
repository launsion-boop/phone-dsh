// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — G2-A09 abort/failed-stop durability regression.
//
// The real-model batch exposed a P0 defect: a 16 MiB file that had been
// written, boundary-confirmed and re-verified during the run was absent from
// the final materialized copy while later partial writes from the hung call
// were present, and the manifest listed one header-only segment with
// `first_mseq: 1, last_mseq: 0` against `last_mseq: 138`.
//
// The root cause was not a scenario detail: the WAL segment lifecycle had no
// single owner. An abort that never reached the epoch close left a manifest
// whose `last_mseq` and `materialized_upto_mseq` described an unlisted open
// epoch, and the next recovery classified those real segments as stale and
// unlinked them — or rebuilt the materialized copy from an incomplete view.
//
// These tests drive the real `WorkspaceLog` / `WALWriter` / `RecoveryManager`
// with the exact data shape the run had (a chunked 16 MiB completed write, a
// later partial write, then an abort/cold-boot teardown). They contain no
// scenario, prompt or file-name branch; every path is arbitrary.
//
// Before the fix:
//   * the open epoch is absent from `manifest.segments` (first red assertion);
//   * recovery unlinks its acknowledged records;
//   * a missing manifest deletes the materialized copy before it validates
//     that the retained WAL can rebuild it;
//   * a WAL hole leaves the watermark silently short.

import Foundation
import XCTest
@testable import PhoneDSHLog
import PhoneDSHWire

final class AbortStopDurabilityTests: XCTestCase {
    private static let chunkBytes = 1024 * 1024
    private static let earlyChunks = 16
    private static let lateChunks = 3

    // MARK: - Fixtures

    private func configuration(_ root: URL,
                               segmentRollBytes: Int = WorkspaceLogConfiguration.defaultSegmentRollBytes)
        -> WorkspaceLogConfiguration {
        LogTestSupport.configuration(root: root, segmentRollBytes: segmentRollBytes)
    }

    private func chunk(_ index: Int) -> Data {
        Data(repeating: UInt8(0x41 + (index % 26)), count: Self.chunkBytes)
    }

    private func expectedContent(chunks: Int) -> Data {
        var data = Data()
        for index in 0..<chunks { data.append(chunk(index)) }
        return data
    }

    /// Publishes a large completed write exactly as the Worker sink does: one
    /// complete write followed by appended suffixes (ENG-07). Returns the full
    /// expected content.
    @discardableResult
    private func writeChunked(_ log: WorkspaceLog,
                              path: String,
                              chunks: Int) async throws -> Data {
        var expected = Data()
        for index in 0..<chunks {
            let bytes = chunk(index)
            if index == 0 {
                _ = try await log.append(VfsMutationBody(
                    op: .write, mode: 0o644, path: path, data: bytes))
            } else {
                _ = try await log.append(VfsMutationBody(
                    op: .write, mode: 0o644,
                    mflags: .appended, appendFrom: UInt64(expected.count),
                    path: path, data: bytes))
            }
            expected.append(bytes)
        }
        return expected
    }

    private func materializedURL(_ root: URL, _ vfsPath: String) -> URL {
        var url = WorkspacePaths(root: root).materializedDirectory
        for component in vfsPath.split(separator: "/").dropFirst(1) {
            url.appendPathComponent(String(component))
        }
        return url
    }

    private func readMaterialized(_ root: URL, _ vfsPath: String) throws -> Data {
        try Data(contentsOf: materializedURL(root, vfsPath))
    }

    /// `manifest.segments` must equal the real WAL: every segment that holds a
    /// record is listed with its header `first_mseq` and real `last_mseq`, no
    /// range is inverted for a segment with mutations, and `last_mseq` covers
    /// the WAL tail. This is the invariant the evidence's inverted manifest
    /// violated.
    private func assertManifestMatchesWAL(_ root: URL,
                                          file: StaticString = #filePath,
                                          line: UInt = #line) throws {
        let manifest = try XCTUnwrap(try ManifestStore(root: root).read(),
                                     "the workspace has no manifest", file: file, line: line)
        let segments = try LogTestSupport.segments(in: root)
        let nonEmpty = segments.filter { !$0.records.isEmpty }
        let listed = Dictionary(uniqueKeysWithValues: manifest.segments.map { ($0.file, $0) })
        XCTAssertEqual(listed.keys.sorted(),
                       nonEmpty.map(\.manifestFile).sorted(),
                       "manifest.segments must list every non-empty wal/ segment (manifest: \(manifest.segments), wal: \(nonEmpty.map(\.manifestFile)))",
                       file: file, line: line)
        for segment in nonEmpty {
            guard let entry = listed[segment.manifestFile] else { continue }
            XCTAssertEqual(entry.epoch, segment.epoch, file: file, line: line)
            XCTAssertEqual(entry.firstMseq, segment.header.firstMseq,
                           "manifest first_mseq must equal the segment header",
                           file: file, line: line)
            XCTAssertEqual(entry.lastMseq, segment.lastMutationMseq,
                           "manifest last_mseq must equal the real highest mutation mseq",
                           file: file, line: line)
            if segment.lastMutationMseq > 0 {
                XCTAssertLessThanOrEqual(entry.firstMseq, entry.lastMseq,
                                         "a segment with mutations must not have an inverted range",
                                         file: file, line: line)
            }
        }
        XCTAssertLessThanOrEqual(manifest.materializedUptoMseq, manifest.lastMseq,
                                 "materialized_upto_mseq must never exceed last_mseq",
                                 file: file, line: line)
        let walTail = nonEmpty.compactMap(\.lastMutationMseq).max() ?? 0
        XCTAssertGreaterThanOrEqual(manifest.lastMseq, walTail,
                                    "manifest.last_mseq must cover the real WAL tail",
                                    file: file, line: line)
    }

    // MARK: - Manifest / segment lifecycle on the abort path

    /// The evidence's manifest: a header-only segment listed against a WAL that
    /// had already advanced. The non-empty open-epoch segment must be listed
    /// with its real range.
    func testOpenEpochSegmentsAreListedWithTheirRealRange() async throws {
        let root = LogTestSupport.root(for: self, name: "abort-manifest")
        let log = try WorkspaceLog(configuration: configuration(root),
                                   bootID: LogTestSupport.bootID(0xA1))
        // A durable checkpoint first, so the manifest has a closed epoch whose
        // entries used to mask the open epoch.
        _ = try await log.append(LogTestSupport.write("/dsh/workspace/seed.txt",
                                                      data: "seed"))
        _ = try await log.closeEpoch()

        let early = try await writeChunked(log,
                                           path: "/dsh/workspace/early.bin",
                                           chunks: Self.earlyChunks)
        XCTAssertEqual(early.count, 16 * 1024 * 1024)
        _ = try await writeChunked(log,
                                   path: "/dsh/workspace/late.bin",
                                   chunks: Self.lateChunks)
        let accepted = await log.positions().ackedMseq
        _ = try await log.barrier(level: .write, upto: accepted)

        // The abort: no epoch close. The manifest still has to name the real
        // WAL segments; this is the assertion that fails on the old head.
        try assertManifestMatchesWAL(root)
        let manifest = try XCTUnwrap(try ManifestStore(root: root).read())
        XCTAssertEqual(manifest.materializedUptoMseq, accepted)

        // Cold recovery after the failed stop keeps the same content and a
        // manifest that matches the retained WAL.
        let recovered = try WorkspaceLog(configuration: configuration(root),
                                         bootID: LogTestSupport.bootID(0xA2))
        let positions = await recovered.positions()
        XCTAssertGreaterThanOrEqual(positions.ackedMseq, accepted)
        XCTAssertEqual(try readMaterialized(root, "/dsh/workspace/early.bin"), early)
        XCTAssertEqual(try readMaterialized(root, "/dsh/workspace/late.bin"),
                       expectedContent(chunks: Self.lateChunks))
        try assertManifestMatchesWAL(root)
    }

    /// Recovery may not unlink an epoch that was never closed in the D18 order
    /// merely because its mutations are below the materialized watermark: the
    /// watermark alone does not prove the copy, and the segments are the only
    /// audit trail. Truncation requires a durable epoch (D18/D11).
    func testRecoveryNeverUnlinksAnUnclosedEpoch() async throws {
        let root = LogTestSupport.root(for: self, name: "abort-unlinked")
        let log = try WorkspaceLog(configuration: configuration(root),
                                   bootID: LogTestSupport.bootID(0xB1))
        _ = try await log.append(LogTestSupport.write("/dsh/workspace/seed.txt",
                                                      data: "seed"))
        _ = try await log.closeEpoch()
        let early = try await writeChunked(log,
                                           path: "/dsh/workspace/early.bin",
                                           chunks: 2)
        let accepted = await log.positions().ackedMseq
        let allSegments = try LogTestSupport.segments(in: root)
        let openEpoch = try XCTUnwrap(allSegments.map(\.epoch).max())
        let openEpochSegments = allSegments.filter { $0.epoch == openEpoch }
        XCTAssertFalse(openEpochSegments.isEmpty)

        // Simulate the failed stop: a plain cold recovery, no graceful close.
        let report = try RecoveryManager(configuration: configuration(root),
                                          bootID: LogTestSupport.bootID(0xB2)).recover()
        XCTAssertEqual(report.materializedUptoMseq, accepted)
        let records = try LogTestSupport.records(in: root)
        XCTAssertEqual(records.map(\.mseq).sorted(), Array(1...accepted),
                       "recovery must not unlink acknowledged records of an epoch that never closed")
        for segment in openEpochSegments {
            XCTAssertTrue(FileManager.default.fileExists(atPath: segment.url.path),
                          "unclosed epoch segment \(segment.fileName) was unlinked")
        }
        XCTAssertEqual(try readMaterialized(root, "/dsh/workspace/early.bin"), early)
        try assertManifestMatchesWAL(root)
    }

    /// A completed, boundary-acknowledged write that is missing from the copy
    /// while later writes survive is repaired from the full WAL, not silently
    /// accepted. This is the G2-A09 materialized-copy shape.
    func testCompletedWriteLostFromTheCopyIsRebuiltFromTheWAL() async throws {
        let root = LogTestSupport.root(for: self, name: "abort-repair")
        let log = try WorkspaceLog(configuration: configuration(root),
                                   bootID: LogTestSupport.bootID(0xC1))
        _ = try await log.append(LogTestSupport.write("/dsh/workspace/seed.txt",
                                                      data: "seed"))
        _ = try await log.closeEpoch()
        let early = try await writeChunked(log,
                                           path: "/dsh/workspace/early.bin",
                                           chunks: 4)
        let late = try await writeChunked(log,
                                          path: "/dsh/workspace/late.bin",
                                          chunks: 2)
        let accepted = await log.positions().ackedMseq
        _ = try await log.barrier(level: .write, upto: accepted)

        // The losing step produced a materialized copy where the completed
        // early file was gone while the later file was still there. Recovery
        // must prove the copy against the WAL and rebuild it, never present
        // the loss as a normal workspace.
        try FileManager.default.removeItem(at: materializedURL(root,
                                                               "/dsh/workspace/early.bin"))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: materializedURL(root, "/dsh/workspace/early.bin").path))

        let recovered = try WorkspaceLog(configuration: configuration(root),
                                         bootID: LogTestSupport.bootID(0xC2))
        XCTAssertEqual(try readMaterialized(root, "/dsh/workspace/early.bin"), early,
                       "the completed early write must be restored from the acknowledged WAL")
        XCTAssertEqual(try readMaterialized(root, "/dsh/workspace/late.bin"), late)
        let positions = await recovered.positions()
        XCTAssertEqual(positions.ackedMseq, accepted)
        let recoveredManifest = try XCTUnwrap(try ManifestStore(root: root).read())
        XCTAssertEqual(recoveredManifest.materializedUptoMseq, accepted)
        try assertManifestMatchesWAL(root)
    }

    // MARK: - Destructive recovery paths

    /// A missing manifest with a retained history that does not start at mseq 1
    /// cannot be rebuilt from the WAL. Recovery must fail loud *before* it
    /// touches the materialized copy; deleting it first is the silent-loss step.
    func testMissingManifestWithTruncatedWALPreservesTheMaterializedCopy() async throws {
        let root = LogTestSupport.root(for: self, name: "abort-missing-manifest")
        let log = try WorkspaceLog(
            configuration: configuration(root, segmentRollBytes: 8 * 1024 * 1024),
            bootID: LogTestSupport.bootID(0xE1))
        let early = try await writeChunked(log,
                                           path: "/dsh/workspace/early.bin",
                                           chunks: Self.earlyChunks)
        _ = try await log.closeEpoch()
        let segments = try LogTestSupport.segments(in: root)
        XCTAssertGreaterThanOrEqual(segments.count, 2, "the 16 MiB write must roll a segment")
        try FileManager.default.removeItem(at: WorkspacePaths(root: root).manifestURL)
        // Simulate a legal truncation that removed the oldest segments; the
        // earliest retained segment now starts above mseq 1.
        let first = try XCTUnwrap(segments.first)
        try FileManager.default.removeItem(at: first.url)
        let earliest = try XCTUnwrap(try LogTestSupport.segments(in: root).first)
        XCTAssertGreaterThan(earliest.header.firstMseq, 1)

        XCTAssertThrowsError(try RecoveryManager(configuration: configuration(root),
                                                 bootID: LogTestSupport.bootID(0xE2)).recover()) { error in
            guard case LogError.corrupt = error else {
                return XCTFail("expected WAL_CORRUPT, got \(error)")
            }
        }
        XCTAssertEqual(try readMaterialized(root, "/dsh/workspace/early.bin"), early,
                       "a failed recovery must not delete the last durable materialized state")
    }

    /// No manifest and no WAL but a materialized copy with content: the old
    /// "new workspace" branch deleted the copy and reported a clean empty
    /// workspace. It must fail loud instead.
    func testMissingManifestWithoutWALPreservesTheMaterializedCopy() async throws {
        let root = LogTestSupport.root(for: self, name: "abort-missing-all")
        let log = try WorkspaceLog(configuration: configuration(root),
                                   bootID: LogTestSupport.bootID(0xF1))
        let early = try await writeChunked(log,
                                           path: "/dsh/workspace/early.bin",
                                           chunks: 2)
        _ = try await log.closeEpoch()
        try FileManager.default.removeItem(at: WorkspacePaths(root: root).manifestURL)
        for segment in try LogTestSupport.segments(in: root) {
            try FileManager.default.removeItem(at: segment.url)
        }

        XCTAssertThrowsError(try RecoveryManager(configuration: configuration(root),
                                                 bootID: LogTestSupport.bootID(0xF2)).recover()) { error in
            guard case LogError.corrupt = error else {
                return XCTFail("expected WAL_CORRUPT, got \(error)")
            }
        }
        XCTAssertEqual(try readMaterialized(root, "/dsh/workspace/early.bin"), early,
                       "the materialized copy is the last durable state and must be preserved")
    }

    // MARK: - Strictly contiguous watermark

    /// A hole in the accepted mseq sequence must fail loud. Before the fix,
    /// recovery replayed what existed, left `materialized_upto_mseq` short and
    /// reported success, so the missing mutation could never be re-requested.
    func testRecoveryRejectsAnMseqHole() async throws {
        let root = LogTestSupport.root(for: self, name: "abort-hole")
        let configuration = self.configuration(root, segmentRollBytes: 300)
        let writer = try WALWriter(configuration: configuration,
                                   bootID: LogTestSupport.bootID(0x31))
        for index in 0..<3 {
            _ = try await writer.append(LogTestSupport.write(
                "/dsh/workspace/h\(index).bin",
                bytes: Data(repeating: UInt8(0x30 + index), count: 250)))
        }
        _ = try await writer.closeEpoch()
        let segments = try LogTestSupport.segments(in: root)
            .filter { !$0.records.isEmpty }
        XCTAssertEqual(segments.count, 3,
                       "each mutation must occupy its own segment for the hole fixture")
        let first = try XCTUnwrap(segments.first(where: { $0.lastMutationMseq == 1 }))
        let remaining = segments.filter { $0.fileName != first.fileName }
        try FileManager.default.removeItem(at: first.url)
        // A checkpoint that never covered mseq 1 (the state a torn manifest can
        // leave behind) makes the hole fall inside the replay window.
        let manifest = Manifest(bootID: LogTestSupport.hex(LogTestSupport.bootID(0x32)),
                                materializedUptoMseq: 0,
                                lastMseq: 3,
                                lastDurableEpoch: 1,
                                segments: remaining.map(\.manifestSegment))
        try ManifestStore(root: root).write(manifest)

        XCTAssertThrowsError(try RecoveryManager(configuration: configuration,
                                                 bootID: LogTestSupport.bootID(0x33)).recover()) { error in
            guard case LogError.corrupt = error else {
                return XCTFail("expected WAL_CORRUPT for the mseq hole, got \(error)")
            }
        }
    }

    // MARK: - Empty-segment lifecycle (G2-FIX-69/120 family)

    /// A mid-epoch rollover keeps real ranges; an idle close registers the
    /// close-only segment; a terminal seal leaves no header-only orphan.
    func testSegmentLifecycleRangesAndEmptySegmentClose() async throws {
        let root = LogTestSupport.root(for: self, name: "abort-lifecycle")
        let log = try WorkspaceLog(configuration: configuration(root,
                                                                segmentRollBytes: 300),
                                   bootID: LogTestSupport.bootID(0x41))
        for index in 0..<5 {
            _ = try await log.append(LogTestSupport.write(
                "/dsh/workspace/l\(index).bin",
                bytes: Data(repeating: UInt8(0x40 + index), count: 250)))
        }
        try assertManifestMatchesWAL(root)
        let manifest = try XCTUnwrap(try ManifestStore(root: root).read())
        XCTAssertEqual(manifest.materializedUptoMseq, 5)
        XCTAssertEqual(manifest.lastMseq, 5)
        XCTAssertGreaterThanOrEqual(manifest.segments.count, 5,
                                    "every rolled segment with a record must be listed")

        // Close the mutation epoch, then close the empty one: the idle close
        // writes a close-only segment and lists it (wal.md §1/§7).
        _ = try await log.closeEpoch()
        try assertManifestMatchesWAL(root)
        _ = try await log.closeEpoch()
        try assertManifestMatchesWAL(root)
        let afterClose = try XCTUnwrap(try ManifestStore(root: root).read())
        XCTAssertEqual(afterClose.lastDurableEpoch, 2)
        let idle = try XCTUnwrap(try LogTestSupport.segments(in: root)
            .first { $0.epoch == 2 })
        XCTAssertTrue(idle.hasEpochClose)
        XCTAssertEqual(idle.lastMutationMseq, 0)
    }

    /// A park closes the epoch but keeps the log alive; the next epoch's
    /// header-only segment is legal and unlisted. Resume then appends to that
    /// same file, so it is reused instead of becoming a permanently unlisted
    /// orphan (the G2-FIX-69/120 shape). A terminal stop is the case that
    /// discards the header-only tail, covered by AbortStopSealTests.
    func testParkResumeReusesHeaderOnlyTailSegmentWithoutOrphan() async throws {
        let root = LogTestSupport.root(for: self, name: "abort-park-resume")
        let log = try WorkspaceLog(configuration: configuration(root),
                                   bootID: LogTestSupport.bootID(0x42))
        _ = try await log.append(LogTestSupport.write("/dsh/workspace/seed.txt",
                                                      data: "seed"))
        // The park seal: the mutation epoch closes and the next epoch starts
        // with a legal header-only segment.
        _ = try await log.closeEpoch()
        let parked = try LogTestSupport.segments(in: root)
        let tail = try XCTUnwrap(parked.first { $0.records.isEmpty },
                                 "a park must leave the next epoch's header-only segment: \(parked.map(\.fileName))")
        XCTAssertFalse(tail.hasEpochClose)
        let parkedManifest = try XCTUnwrap(try ManifestStore(root: root).read())
        XCTAssertFalse(parkedManifest.segments.contains { $0.file == tail.manifestFile },
                       "a header-only segment is not content and must not be listed")

        // Resume keeps the same WorkspaceLog; the next mutation reuses the
        // existing header-only segment instead of creating a new epoch.
        let resumedMseq = try await log.append(LogTestSupport.write(
            "/dsh/workspace/resumed.txt", data: "resumed"))
        XCTAssertEqual(resumedMseq, 2)
        let resumed = try LogTestSupport.segments(in: root)
        let reused = try XCTUnwrap(resumed.first { $0.fileName == tail.fileName },
                                   "resume must reuse the parked header-only segment")
        XCTAssertEqual(reused.records.filter { !$0.isEpochClose }.map(\.mseq), [2])
        XCTAssertFalse(resumed.contains { $0.records.isEmpty },
                       "resume must not leave a header-only orphan behind: \(resumed.map(\.fileName))")
        try assertManifestMatchesWAL(root)
        let resumedManifest = try XCTUnwrap(try ManifestStore(root: root).read())
        XCTAssertTrue(resumedManifest.segments.contains {
            $0.file == tail.manifestFile && $0.lastMseq == 2
        }, "the reused segment must be listed once it holds the mutation")
    }
}
