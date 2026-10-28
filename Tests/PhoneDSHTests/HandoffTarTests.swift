// SPDX-License-Identifier: MIT
// ustar codec and golden WAL interop tests (spec/v1/golden/wal).

import XCTest
import PhoneDSH
import PhoneDSHLog
import PhoneDSHWire

final class HandoffTarTests: XCTestCase {
    // MARK: - ustar

    func testTarRoundTripPreservesFilesModesAndDirectories() throws {
        let entries = [
            HandoffTarEntry(name: "home/", mode: 0o755, kind: .directory),
            HandoffTarEntry(name: "home/sessions/a.txt", mode: 0o600,
                            data: Data("hello".utf8)),
            HandoffTarEntry(name: "workspace/sub/", mode: 0o750, kind: .directory),
            HandoffTarEntry(name: "workspace/sub/b.bin", mode: 0o644,
                            data: Data([0x00, 0xFF, 0x10])),
        ]
        let archive = try HandoffTar.encode(entries)
        XCTAssertEqual(archive.count % 512, 0)
        let decoded = try HandoffTar.decode(archive)
        XCTAssertEqual(decoded, entries)
    }

    func testTarRoundTripThroughFile() throws {
        let directory = try HandoffTemporaryDirectory("tar-file")
        defer { directory.cleanUp() }
        let url = directory.url.appendingPathComponent("archive.tar")
        let entries = [HandoffTarEntry(name: "wal/00000001.000000.xlwal",
                                       data: Data(repeating: 7, count: 61))]
        let written = try HandoffTar.write(entries, to: url)
        XCTAssertGreaterThan(written, 0)
        let readBack = try HandoffTar.read(from: url)
        XCTAssertEqual(readBack, entries)
    }

    func testTarRejectsUnsafeEntryNames() {
        XCTAssertThrowsError(try HandoffTar.encode([
            HandoffTarEntry(name: "../escape", data: Data()),
        ]))
        XCTAssertThrowsError(try HandoffTar.encode([
            HandoffTarEntry(name: "/absolute", data: Data()),
        ]))
        XCTAssertThrowsError(try HandoffTar.encode([
            HandoffTarEntry(name: "home/../../escape", data: Data()),
        ]))
    }

    func testTarDecoderRejectsDuplicateEntries() throws {
        let entry = HandoffTarEntry(name: "wal/00000001.000000.xlwal",
                                    data: Data(repeating: 1, count: 40))
        let archive = try HandoffTar.encode([entry, entry])
        XCTAssertThrowsError(try HandoffTar.decode(archive))
    }

    func testTarDecoderRejectsCorruptChecksum() throws {
        var archive = try HandoffTar.encode([
            HandoffTarEntry(name: "wal/00000001.000000.xlwal",
                            data: Data(repeating: 1, count: 40)),
        ])
        archive[0] = archive[0] ^ 0xFF
        XCTAssertThrowsError(try HandoffTar.decode(archive))
    }

    // MARK: - Segment archives

    func testSegmentArchiveRoundTripAndDescriptors() throws {
        let bootID = Data(repeating: 0x33, count: 16)
        let first = try makeSegmentFile(
            epoch: 1, segment: 0, bootID: bootID, firstMseq: 1,
            records: [
                try WALRecord(mseq: 1, mutation: HandoffMutations.write(
                    "/dsh/workspace/a.txt", "a")),
                try WALRecord(mseq: 2, mutation: HandoffMutations.write(
                    "/dsh/workspace/b.txt", "b")),
            ])
        let second = try makeSegmentFile(
            epoch: 1, segment: 1, bootID: bootID, firstMseq: 3,
            records: [
                try WALRecord(mseq: 3, mutation: HandoffMutations.mkdir(
                    "/dsh/workspace/sub")),
                try WALRecord(epochClose: 1_792_800_000_123, durableUpto: 3),
            ])
        let files = [
            try HandoffSegmentFile(file: "wal/" + first.fileName,
                                   bytes: try encodeSegment(first)),
            try HandoffSegmentFile(file: "wal/" + second.fileName,
                                   bytes: try encodeSegment(second)),
        ]
        let archive = try HandoffSegmentWriter.archive(files)
        let decoded = try HandoffSegmentArchive.decode(archive)
        XCTAssertEqual(decoded.map(\.file), files.map(\.file))
        let descriptors = try files.map { try $0.descriptor() }
        XCTAssertEqual(descriptors.map(\.firstMseq), [1, 3])
        XCTAssertEqual(descriptors.map(\.lastMseq), [2, 3])
        let validated = try HandoffSegmentArchive.validate(files: decoded,
                                                           descriptors: descriptors)
        let records = try HandoffSegmentArchive.mutationRecords(
            validated, baseMseq: 0, walSeq: 3)
        XCTAssertEqual(records.map(\.mseq), [1, 2, 3])
    }

    func testSegmentArchiveRejectsGap() throws {
        let bootID = Data(repeating: 0x44, count: 16)
        let segment = try makeSegmentFile(
            epoch: 2, segment: 0, bootID: bootID, firstMseq: 1,
            records: [
                try WALRecord(mseq: 1, mutation: HandoffMutations.write(
                    "/dsh/workspace/a.txt", "a")),
                try WALRecord(epochClose: 1_792_800_000_123, durableUpto: 1),
            ])
        let file = try HandoffSegmentFile(file: "wal/" + segment.fileName,
                                          bytes: encodeSegment(segment))
        let descriptor = try file.descriptor()
        let validated = try HandoffSegmentArchive.validate(files: [file],
                                                           descriptors: [descriptor])
        XCTAssertThrowsError(try HandoffSegmentArchive.mutationRecords(
            validated, baseMseq: 0, walSeq: 2)) { error in
            guard case HandoffError.segmentContinuity = error else {
                return XCTFail("expected a continuity error, got \(error)")
            }
        }
    }

    // MARK: - Golden WAL interop

    func testGoldenSegmentWriterMatchesVector() throws {
        let golden = try goldenWALVector("segment-1")
        let bootID = try XCTUnwrap(hexData(golden.header.bootIDHex))
        let records = try golden.records.map { record in
            try WALRecord.decode(try XCTUnwrap(hexData(record.recordHex)))
        }
        let bytes = try HandoffSegmentWriter.encode(firstMseq: golden.header.firstMseq,
                                                    bootID: bootID,
                                                    records: records)
        XCTAssertEqual(hexString(bytes), golden.fileHex)
        XCTAssertEqual(hexString(bytes), golden.header.headerHex
            + golden.records.map(\.recordHex).joined())
    }

    func testGoldenEpochOnlySegmentWriterMatchesVector() throws {
        let golden = try goldenWALVector("segment-epoch-only")
        let bootID = try XCTUnwrap(hexData(golden.header.bootIDHex))
        let records = try golden.records.map { record in
            try WALRecord.decode(try XCTUnwrap(hexData(record.recordHex)))
        }
        let bytes = try HandoffSegmentWriter.encode(firstMseq: golden.header.firstMseq,
                                                    bootID: bootID,
                                                    records: records)
        XCTAssertEqual(hexString(bytes), golden.fileHex)
    }

    func testGoldenSegmentArchiveEntryPreservesGoldenBytes() throws {
        let golden = try goldenWALVector("segment-1")
        let bytes = try XCTUnwrap(hexData(golden.fileHex))
        let file = try HandoffSegmentFile(file: "wal/00000001.000000.xlwal",
                                          bytes: bytes)
        let descriptor = try file.descriptor()
        XCTAssertEqual(descriptor.firstMseq, golden.header.firstMseq)
        XCTAssertEqual(descriptor.bytes, UInt64(bytes.count))

        let archive = try HandoffSegmentWriter.archive([file])
        let decoded = try HandoffSegmentArchive.decode(archive)
        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded[0].bytes, bytes)
        let validated = try HandoffSegmentArchive.validate(files: decoded,
                                                           descriptors: [descriptor])
        let records = try HandoffSegmentArchive.mutationRecords(
            validated, baseMseq: 41, walSeq: descriptor.lastMseq)
        XCTAssertEqual(records.map(\.mseq), [42, 43, 44, 45, 46])
    }

    // MARK: - Helpers

    private func encodeSegment(_ segment: WALSegmentFile) throws -> Data {
        try HandoffSegmentWriter.encode(firstMseq: segment.header.firstMseq,
                                        bootID: segment.header.bootID,
                                        records: segment.records)
    }

    private func hexData(_ hex: String) -> Data? {
        guard hex.count % 2 == 0 else { return nil }
        var bytes = [UInt8]()
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        return Data(bytes)
    }

    private func hexString(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }
}
