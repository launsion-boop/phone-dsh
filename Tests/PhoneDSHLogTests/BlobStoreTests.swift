// SPDX-License-Identifier: MIT
// W6 (wal.md §14): the content-addressed blob store, blob-write records,
// materialization, the live-set GC and the WAL quota that counts live blobs.

import Darwin
import Foundation
import XCTest
@testable import PhoneDSHLog
import PhoneDSHWire

final class BlobStoreTests: XCTestCase {
    private func store(_ root: URL) -> WorkspaceBlobStore {
        WorkspaceBlobStore(root: root)
    }

    // MARK: - Store layout / immutability

    func testWriteUsesContentAddressAndReusesExistingBlob() throws {
        let root = LogTestSupport.root(for: self)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let bytes = Data(repeating: 0x5A, count: 70_000)
        let digest = SHA256.hash(bytes)

        let first = try store(root).write(bytes)
        XCTAssertEqual(first.sha256, digest)
        XCTAssertEqual(first.byteCount, bytes.count)
        let expected = root
            .appendingPathComponent("blobs/sha256/\(digest.prefix(2))")
            .appendingPathComponent(digest)
        XCTAssertEqual(try store(root).blobURL(for: digest), expected)
        XCTAssertEqual(try Data(contentsOf: expected), bytes)
        XCTAssertEqual(try LogFile.fileMode(expected), 0o600)

        // A second write of the same bytes reuses the immutable file.
        let second = try store(root).write(bytes)
        XCTAssertEqual(second.sha256, digest)
        XCTAssertEqual(try store(root).read(digest: digest, expectedLength: bytes.count), bytes)
    }

    func testReadRejectsWrongLengthAndMissingBlob() throws {
        let root = LogTestSupport.root(for: self)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let bytes = Data(repeating: 0x11, count: 32)
        let ref = try store(root).write(bytes)
        XCTAssertThrowsError(try store(root).read(digest: ref.sha256,
                                                  expectedLength: bytes.count + 1))
        let missing = String(repeating: "a", count: 64)
        XCTAssertThrowsError(try store(root).read(digest: missing, expectedLength: 1))
    }

    func testGarbageCollectionKeepsLiveAndRemovesOrphans() throws {
        let root = LogTestSupport.root(for: self)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let live = try store(root).write(Data(repeating: 0x01, count: 8))
        let orphan = try store(root).write(Data(repeating: 0x02, count: 8))

        let removed = try store(root).collectGarbage(liveDigests: [live.sha256])
        XCTAssertEqual(removed, [orphan.sha256])
        XCTAssertEqual(try store(root).verifyLength(digest: live.sha256,
                                                    expectedLength: 8).lastPathComponent,
                       live.sha256)
        XCTAssertThrowsError(try store(root).verifyLength(digest: orphan.sha256,
                                                          expectedLength: 8))
    }

    // MARK: - WAL writer / materializer

    func testLargeWriteBecomesBlobRecordAndMaterializes() async throws {
        let root = LogTestSupport.root(for: self)
        let configuration = LogTestSupport.configuration(root: root)
        let writer = try WALWriter(configuration: configuration,
                                   bootID: LogTestSupport.bootID())
        let big = Data(repeating: 0x7F, count: WireLimits.walBlobWriteThresholdBytes)
        _ = try await writer.append(LogTestSupport.write("/dsh/workspace/big.bin", bytes: big))
        _ = try await writer.flush()

        let records = try LogTestSupport.records(in: root)
        let record = try XCTUnwrap(records.first)
        XCTAssertTrue(record.isBlobWrite)
        let blob = try XCTUnwrap(try record.blobWrite())
        XCTAssertEqual(Int(blob.blobLength), big.count)
        XCTAssertEqual(try store(root).read(digest: blob.sha256Hex,
                                            expectedLength: big.count), big)

        let materializer = try Materializer(root: root)
        _ = try materializer.apply(records: [record])
        let target = root.appendingPathComponent("materialized/workspace/big.bin")
        XCTAssertEqual(try Data(contentsOf: target), big)
        // §14.4: clone/copy produces an independent inode, never a hard link.
        var blobStat = stat()
        var fileStat = stat()
        lstat(try store(root).blobURL(for: blob.sha256Hex).path, &blobStat)
        lstat(target.path, &fileStat)
        XCTAssertNotEqual(blobStat.st_ino, fileStat.st_ino)
    }

    func testSmallWriteStaysInline() async throws {
        let root = LogTestSupport.root(for: self)
        let writer = try WALWriter(configuration: LogTestSupport.configuration(root: root),
                                   bootID: LogTestSupport.bootID())
        _ = try await writer.append(LogTestSupport.write("/dsh/workspace/small.txt",
                                                          data: "hello\n"))
        _ = try await writer.flush()
        let record = try XCTUnwrap(try LogTestSupport.records(in: root).first)
        XCTAssertFalse(record.isBlobWrite)
        XCTAssertEqual(try record.mutationBody().data, Data("hello\n".utf8))
    }

    func testAppendedBlobWriteMaterializesTheSuffix() async throws {
        let root = LogTestSupport.root(for: self)
        let writer = try WALWriter(configuration: LogTestSupport.configuration(root: root),
                                   bootID: LogTestSupport.bootID())
        let first = Data(repeating: 0x41, count: WireLimits.walBlobWriteThresholdBytes)
        let suffix = Data(repeating: 0x42, count: WireLimits.walBlobWriteThresholdBytes)
        _ = try await writer.append(LogTestSupport.write("/dsh/workspace/big.bin", bytes: first))
        _ = try await writer.append(LogTestSupport.append("/dsh/workspace/big.bin",
                                                           from: UInt64(first.count),
                                                           data: suffix))
        _ = try await writer.flush()
        let records = try LogTestSupport.records(in: root)
        XCTAssertEqual(records.count, 2)
        XCTAssertTrue(records.allSatisfy(\.isBlobWrite))

        let materializer = try Materializer(root: root)
        _ = try materializer.apply(records: records)
        let target = root.appendingPathComponent("materialized/workspace/big.bin")
        XCTAssertEqual(try Data(contentsOf: target), first + suffix)
    }

    func testCloseDropsSegmentsAndCollectsUnreferencedBlobs() async throws {
        let root = LogTestSupport.root(for: self)
        let configuration = LogTestSupport.configuration(root: root)
        let writer = try WALWriter(configuration: configuration,
                                   bootID: LogTestSupport.bootID())
        let big = Data(repeating: 0x33, count: WireLimits.walBlobWriteThresholdBytes)
        _ = try await writer.append(LogTestSupport.write("/dsh/workspace/big.bin", bytes: big))
        _ = try await writer.closeEpoch()
        // The first epoch's segment is droppable after a later close moves the
        // durable watermark; a directly-written orphan is still reclaimed.
        let orphan = try store(root).write(Data(repeating: 0x44, count: 16))
        _ = try await writer.compactDroppableSegments()
        XCTAssertThrowsError(try store(root).verifyLength(digest: orphan.sha256,
                                                          expectedLength: 16))
        let live = Set(await writer.liveBlobDigests())
        XCTAssertFalse(live.isEmpty)
    }

    func testQuotaCountsLiveBlobs() async throws {
        let root = LogTestSupport.root(for: self)
        let configuration = LogTestSupport.configuration(root: root)
        let writer = try WALWriter(configuration: configuration,
                                   bootID: LogTestSupport.bootID())
        let before = await writer.walByteCount
        let big = Data(repeating: 0x66, count: WireLimits.walBlobWriteThresholdBytes)
        _ = try await writer.append(LogTestSupport.write("/dsh/workspace/big.bin", bytes: big))
        _ = try await writer.flush()
        let after = await writer.walByteCount
        XCTAssertGreaterThan(after, before + big.count)
    }
}
