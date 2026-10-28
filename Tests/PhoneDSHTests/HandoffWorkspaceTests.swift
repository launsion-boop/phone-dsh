// SPDX-License-Identifier: MIT
// Snapshot and WAL tail source tests (spec/v1/handoff.md §2–§4).

import XCTest
import PhoneDSH
import PhoneDSHLog
import PhoneDSHWire

final class HandoffWorkspaceTests: XCTestCase {
    private func mutations() -> [VfsMutationBody] {
        [
            HandoffMutations.write("/dsh/workspace/notes.txt", "hello"),
            HandoffMutations.mkdir("/dsh/workspace/sub"),
            HandoffMutations.write("/dsh/workspace/late.txt", "late"),
            HandoffMutations.write("/dsh/home/sessions/s.json", "{}"),
        ]
    }

    func testSnapshotterPackagesMaterializedBaseAndWALTail() async throws {
        let directory = try HandoffTemporaryDirectory("snapshotter")
        defer { directory.cleanUp() }
        let root = directory.url.appendingPathComponent("phone")
        try HandoffWorkspaceFixture.makeOfflineLaggingWorkspace(
            root: root,
            mutations: mutations(),
            materializedCount: 2)
        let source = HandoffWorkspaceSnapshotter(
            root: root,
            configuration: WorkspaceLogConfiguration(root: root),
            scratchDirectory: directory.url.appendingPathComponent("scratch"))
        let upload = try await source.prepareHandoff()
        XCTAssertEqual(upload.baseMseq, 2)
        XCTAssertEqual(upload.walSeq, 4)
        // The single segment starts below the base (straddling); the remote
        // replays it idempotently and the phone skips mseq <= base.
        XCTAssertEqual(upload.segments.map(\.firstMseq), [1])
        XCTAssertEqual(upload.segments.map(\.lastMseq), [4])
        let snapshotSHA = try SHA256.hashFile(upload.snapshotURL)
        let segmentsSHA = try SHA256.hashFile(upload.segmentsURL)
        XCTAssertEqual(upload.snapshotSHA256, snapshotSHA)
        XCTAssertEqual(upload.segmentsSHA256, segmentsSHA)

        // The snapshot is the materialized copy at base 2: it contains the
        // mutations 1...2 and neither the WAL tail nor tmp/WAL/manifest.
        let snapshotEntries = try HandoffTar.read(from: upload.snapshotURL)
        let names = Set(snapshotEntries.map(\.name))
        XCTAssertTrue(names.contains("workspace/notes.txt"))
        XCTAssertTrue(names.contains("workspace/sub/"))
        XCTAssertTrue(names.contains("home/"))
        XCTAssertFalse(names.contains("workspace/late.txt"))
        XCTAssertFalse(names.contains("home/sessions/s.json"))
        for name in names {
            XCTAssertFalse(name.contains("tmp"))
            XCTAssertFalse(name.hasPrefix("wal/"))
            XCTAssertFalse(name.contains("manifest"))
        }
        let decoded = try HandoffSegmentArchive.read(from: upload.segmentsURL)
        let validated = try HandoffSegmentArchive.validate(files: decoded,
                                                           descriptors: upload.segments)
        let records = try HandoffSegmentArchive.mutationRecords(
            validated, baseMseq: upload.baseMseq, walSeq: upload.walSeq)
        XCTAssertEqual(records.map(\.mseq), [3, 4])
        let kinds = records.compactMap { $0.body.first }
        XCTAssertEqual(kinds, [VfsOp.write.rawValue, VfsOp.write.rawValue])

        await source.cleanUp(upload)
        for url in upload.temporaryFiles {
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        }
    }

    func testSnapshotterRejectsOpenEpoch() async throws {
        let directory = try HandoffTemporaryDirectory("open-epoch")
        defer { directory.cleanUp() }
        let root = directory.url.appendingPathComponent("phone")
        try HandoffWorkspaceFixture.makeOfflineLaggingWorkspace(
            root: root,
            mutations: mutations().prefix(2).map { $0 },
            materializedCount: 2,
            closeEpoch: false)
        let source = HandoffWorkspaceSnapshotter(
            root: root,
            configuration: WorkspaceLogConfiguration(root: root),
            scratchDirectory: directory.url.appendingPathComponent("scratch"))
        do {
            _ = try await source.prepareHandoff()
            XCTFail("a handoff must not snapshot an epoch that is still open")
        } catch let error as HandoffError {
            guard case .notQuiescent = error else {
                return XCTFail("expected notQuiescent, got \(error)")
            }
        }
    }

    func testSegmentPlannerRejectsGap() throws {
        let bootID = Data(repeating: 0x55, count: 16)
        let first = try makeSegmentFile(
            epoch: 1, segment: 0, bootID: bootID, firstMseq: 1,
            records: [
                try WALRecord(mseq: 1, mutation: HandoffMutations.write(
                    "/dsh/workspace/a.txt", "a")),
                try WALRecord(mseq: 2, mutation: HandoffMutations.write(
                    "/dsh/workspace/b.txt", "b")),
                try WALRecord(epochClose: 1, durableUpto: 2),
            ])
        let second = try makeSegmentFile(
            epoch: 1, segment: 1, bootID: bootID, firstMseq: 4,
            records: [
                try WALRecord(mseq: 4, mutation: HandoffMutations.write(
                    "/dsh/workspace/d.txt", "d")),
                try WALRecord(epochClose: 1, durableUpto: 4),
            ])
        XCTAssertThrowsError(try HandoffSegmentPlanner.select(
            segments: [first, second], baseMseq: 0, walSeq: 4)) { error in
            guard case HandoffError.segmentContinuity = error else {
                return XCTFail("expected a continuity error, got \(error)")
            }
        }
        XCTAssertThrowsError(try HandoffSegmentPlanner.select(
            segments: [second], baseMseq: 0, walSeq: 2))
        let selected = try HandoffSegmentPlanner.select(
            segments: [first], baseMseq: 0, walSeq: 2)
        XCTAssertEqual(selected.map(\.fileName), [first.fileName])
        // An empty selection is legal only when base == wal_seq.
        let emptySelection = try HandoffSegmentPlanner.select(
            segments: [first, second], baseMseq: 4, walSeq: 4)
        XCTAssertTrue(emptySelection.isEmpty)
    }

    func testWorkspaceLogSourceClosesEpochAndPacks() async throws {
        let directory = try HandoffTemporaryDirectory("log-source")
        defer { directory.cleanUp() }
        let root = directory.url.appendingPathComponent("phone")
        let log = try await HandoffWorkspaceFixture.makeLiveWorkspace(
            root: root,
            mutations: [
                HandoffMutations.write("/dsh/workspace/a.txt", "alpha"),
                HandoffMutations.mkdir("/dsh/workspace/dir"),
            ],
            closeEpoch: false)
        let source = WorkspaceLogHandoffSource(
            log: log,
            scratchDirectory: directory.url.appendingPathComponent("scratch"))
        let upload = try await source.prepareHandoff()
        XCTAssertEqual(upload.baseMseq, 2)
        XCTAssertEqual(upload.walSeq, 2)
        XCTAssertTrue(upload.segments.isEmpty)
        let snapshotSize = try HandoffFileTestSize.size(upload.snapshotURL)
        XCTAssertEqual(upload.snapshotBytes, snapshotSize)
        let positions = await log.positions()
        XCTAssertEqual(positions.ackedMseq, 2)
        let entries = try HandoffTar.read(from: upload.snapshotURL)
        XCTAssertTrue(entries.map(\.name).contains("workspace/a.txt"))
        await source.cleanUp(upload)
    }
}

/// Small helper that keeps the test target independent of `HandoffFile`.
enum HandoffFileTestSize {
    static func size(_ url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let size = (attributes[.size] as? NSNumber)?.intValue else {
            throw HandoffTestError.fixture("missing file size")
        }
        return size
    }
}
