// SPDX-License-Identifier: MIT
// Materializer: every wal.md §6 operation, D9 replay idempotence and deferral.

import Foundation
import XCTest
@testable import PhoneDSHLog
import PhoneDSHWire

final class MaterializerTests: XCTestCase {
    private func makeMaterializer(_ test: XCTestCase) throws -> (Materializer, URL) {
        let root = LogTestSupport.root(for: test)
        return (try Materializer(root: root), root)
    }

    private func fileURL(_ root: URL, _ vfsPath: String) -> URL {
        let relative = String(vfsPath.dropFirst("/dsh/".count))
        return WorkspacePaths(root: root).materializedDirectory.appendingPathComponent(relative)
    }

    private func contents(_ root: URL, _ vfsPath: String) throws -> String {
        try String(contentsOf: fileURL(root, vfsPath), encoding: .utf8)
    }

    func testCompleteWriteCreatesParentsAndMode() throws {
        let (materializer, root) = try makeMaterializer(self)
        let record = try WALRecord(mseq: 1, mutation: LogTestSupport.write(
            "/dsh/workspace/deep/nested/file.txt", data: "hello", mode: 0o640))
        let outcome = try materializer.apply(record)
        XCTAssertEqual(outcome, .applied)
        XCTAssertEqual(try contents(root, "/dsh/workspace/deep/nested/file.txt"), "hello")
        XCTAssertEqual(try LogFile.fileMode(fileURL(root, "/dsh/workspace/deep/nested/file.txt")),
                       0o640)
        XCTAssertEqual(materializer.materializedUptoMseq, 1)
        try materializer.fsyncEpoch()
    }

    func testMkdirAndChmod() throws {
        let (materializer, root) = try makeMaterializer(self)
        XCTAssertEqual(try materializer.apply(
            try WALRecord(mseq: 1, mutation: LogTestSupport.mkdir(
                "/dsh/home/dir/sub", mode: 0o750))), .applied)
        XCTAssertEqual(try LogFile.fileMode(fileURL(root, "/dsh/home/dir/sub")), 0o750)

        XCTAssertEqual(try materializer.apply(
            try WALRecord(mseq: 2, mutation: LogTestSupport.write(
                "/dsh/home/dir/sub/a.txt", data: "x", mode: 0o644))), .applied)
        XCTAssertEqual(try materializer.apply(
            try WALRecord(mseq: 3, mutation: LogTestSupport.chmod(
                "/dsh/home/dir/sub/a.txt", mode: 0o600))), .applied)
        XCTAssertEqual(try LogFile.fileMode(fileURL(root, "/dsh/home/dir/sub/a.txt")), 0o600)
        XCTAssertEqual(materializer.materializedUptoMseq, 3)
    }

    func testChmodOfMissingPathFailsLoud() throws {
        let (materializer, _) = try makeMaterializer(self)
        let record = try WALRecord(mseq: 1, mutation: LogTestSupport.chmod(
            "/dsh/workspace/missing.txt", mode: 0o600))
        XCTAssertThrowsError(try materializer.apply(record)) { error in
            guard case LogError.materializationFailed = error else {
                return XCTFail("expected materializationFailed, got \(error)")
            }
        }
    }

    func testRemoveFileAndWholeDirectoryTree() throws {
        let (materializer, root) = try makeMaterializer(self)
        _ = try materializer.apply(try WALRecord(mseq: 1, mutation: LogTestSupport.write(
            "/dsh/workspace/tree/a.txt", data: "a")))
        _ = try materializer.apply(try WALRecord(mseq: 2, mutation: LogTestSupport.write(
            "/dsh/workspace/tree/sub/b.txt", data: "b")))
        _ = try materializer.apply(try WALRecord(mseq: 3, mutation: LogTestSupport.remove(
            "/dsh/workspace/tree")))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fileURL(root, "/dsh/workspace/tree").path))
        // A missing path is a replayable tombstone, not an error.
        XCTAssertEqual(try materializer.apply(
            try WALRecord(mseq: 4, mutation: LogTestSupport.remove(
                "/dsh/workspace/tree"))), .applied)
        XCTAssertEqual(materializer.materializedUptoMseq, 4)
    }

    func testRenameIsExpressedAsRemovePlusWrite() throws {
        let (materializer, root) = try makeMaterializer(self)
        _ = try materializer.apply(try WALRecord(mseq: 1, mutation: LogTestSupport.write(
            "/dsh/workspace/old.txt", data: "moving")))
        _ = try materializer.apply(try WALRecord(mseq: 2, mutation: LogTestSupport.mkdir(
            "/dsh/workspace/dir")))
        _ = try materializer.apply(try WALRecord(mseq: 3, mutation: LogTestSupport.write(
            "/dsh/workspace/dir/new.txt", data: "moving", mode: 0o600)))
        _ = try materializer.apply(try WALRecord(mseq: 4, mutation: LogTestSupport.remove(
            "/dsh/workspace/old.txt")))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fileURL(root, "/dsh/workspace/old.txt").path))
        XCTAssertEqual(try contents(root, "/dsh/workspace/dir/new.txt"), "moving")
        XCTAssertEqual(try LogFile.fileMode(fileURL(root, "/dsh/workspace/dir/new.txt")), 0o600)
    }

    func testAppendedFastPathAndIdempotentSkip() throws {
        let (materializer, root) = try makeMaterializer(self)
        _ = try materializer.apply(try WALRecord(mseq: 1, mutation: LogTestSupport.write(
            "/dsh/workspace/log.txt", data: "hello")))
        let appended = try WALRecord(mseq: 2, mutation: LogTestSupport.append(
            "/dsh/workspace/log.txt", from: 5, data: " world"))
        XCTAssertEqual(try materializer.apply(appended), .applied)
        XCTAssertEqual(try contents(root, "/dsh/workspace/log.txt"), "hello world")
        XCTAssertEqual(materializer.materializedUptoMseq, 2)

        // Replaying the same record and the same byte range is the D9 skip.
        XCTAssertEqual(try materializer.apply(appended), .skipped)
        XCTAssertEqual(materializer.materializedUptoMseq, 2)
    }

    func testConsecutiveAppendsReplayIdempotently() throws {
        let (materializer, root) = try makeMaterializer(self)
        _ = try materializer.apply(try WALRecord(mseq: 1, mutation: LogTestSupport.write(
            "/dsh/workspace/log.txt", data: "aaaaaa")))
        let second = try WALRecord(mseq: 2, mutation: LogTestSupport.append(
            "/dsh/workspace/log.txt", from: 6, data: "bbbbbb"))
        let third = try WALRecord(mseq: 3, mutation: LogTestSupport.append(
            "/dsh/workspace/log.txt", from: 12, data: "cccccc"))
        XCTAssertEqual(try materializer.apply(second), .applied)
        XCTAssertEqual(try materializer.apply(third), .applied)
        XCTAssertEqual(try contents(root, "/dsh/workspace/log.txt"), "aaaaaabbbbbbcccccc")
        let replay = try materializer.apply(records: [second, third])
        XCTAssertEqual(replay.skipped, 2)
        XCTAssertEqual(replay.materializedUptoMseq, 3)
    }

    func testBaseMismatchDefersAndStallsWatermark() throws {
        let (materializer, root) = try makeMaterializer(self)
        _ = try materializer.apply(try WALRecord(mseq: 1, mutation: LogTestSupport.write(
            "/dsh/workspace/log.txt", data: "hello")))
        let mismatch = try WALRecord(mseq: 2, mutation: LogTestSupport.append(
            "/dsh/workspace/log.txt", from: 6, data: "world"))
        XCTAssertEqual(try materializer.apply(mismatch),
                       .baseMismatch("/dsh/workspace/log.txt"))
        XCTAssertEqual(materializer.materializedUptoMseq, 1)
        XCTAssertEqual(materializer.needsResyncPaths, ["/dsh/workspace/log.txt"])

        // Another path may still be applied, but the contiguous watermark
        // cannot cross the deferred record.
        _ = try materializer.apply(try WALRecord(mseq: 3, mutation: LogTestSupport.write(
            "/dsh/workspace/other.txt", data: "other")))
        XCTAssertEqual(try contents(root, "/dsh/workspace/other.txt"), "other")
        XCTAssertEqual(materializer.materializedUptoMseq, 1)
        XCTAssertEqual(materializer.deferredRecordCount, 1)
    }

    func testRepairCompleteWriteSettlesDeferredAppends() throws {
        let (materializer, root) = try makeMaterializer(self)
        _ = try materializer.apply(try WALRecord(mseq: 1, mutation: LogTestSupport.write(
            "/dsh/workspace/log.txt", data: "hello")))
        _ = try materializer.apply(try WALRecord(mseq: 2, mutation: LogTestSupport.append(
            "/dsh/workspace/log.txt", from: 6, data: "world")))
        XCTAssertEqual(materializer.materializedUptoMseq, 1)

        // The worker's complete write is already the joined content.
        _ = try materializer.apply(try WALRecord(mseq: 3, mutation: LogTestSupport.write(
            "/dsh/workspace/log.txt", data: "hello world")))
        XCTAssertEqual(try contents(root, "/dsh/workspace/log.txt"), "hello world")
        XCTAssertEqual(materializer.materializedUptoMseq, 3)
        XCTAssertTrue(materializer.needsResyncPaths.isEmpty)
        XCTAssertEqual(materializer.deferredRecordCount, 0)
    }

    func testRepairBaseThenDeferredAppendActuallyAppends() throws {
        let (materializer, root) = try makeMaterializer(self)
        _ = try materializer.apply(try WALRecord(mseq: 1, mutation: LogTestSupport.write(
            "/dsh/workspace/log.txt", data: "hello")))
        _ = try materializer.apply(try WALRecord(mseq: 2, mutation: LogTestSupport.append(
            "/dsh/workspace/log.txt", from: 6, data: "world")))
        // Repair base is exactly the six bytes the appended record expects.
        _ = try materializer.apply(try WALRecord(mseq: 3, mutation: LogTestSupport.write(
            "/dsh/workspace/log.txt", data: "hello ")))
        XCTAssertEqual(try contents(root, "/dsh/workspace/log.txt"), "hello world")
        XCTAssertEqual(materializer.materializedUptoMseq, 3)
    }

    func testEpochCloseRecordNeverAdvancesWatermark() throws {
        let (materializer, _) = try makeMaterializer(self)
        _ = try materializer.apply(try WALRecord(mseq: 1, mutation: LogTestSupport.write(
            "/dsh/workspace/a", data: "a")))
        let close = try WALRecord(epochClose: 1_700_000_000_000, durableUpto: 1)
        XCTAssertEqual(try materializer.apply(close), .skipped)
        XCTAssertEqual(materializer.materializedUptoMseq, 1)
    }

    func testShortFileIsABaseMismatchNotAnError() throws {
        let (materializer, root) = try makeMaterializer(self)
        _ = try materializer.apply(try WALRecord(mseq: 1, mutation: LogTestSupport.write(
            "/dsh/workspace/a.txt", data: "abcdef")))
        let appended = try WALRecord(mseq: 2, mutation: LogTestSupport.append(
            "/dsh/workspace/a.txt", from: 2, data: "ZZ"))
        XCTAssertEqual(try materializer.apply(appended), .baseMismatch("/dsh/workspace/a.txt"))
        XCTAssertEqual(try contents(root, "/dsh/workspace/a.txt"), "abcdef")
        XCTAssertEqual(materializer.materializedUptoMseq, 1)
    }
}
