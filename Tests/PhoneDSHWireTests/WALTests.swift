// SPDX-License-Identifier: MIT
// WAL v1 header/record/segment golden and CRC tests.

import Foundation
import XCTest
import PhoneDSHWire

final class WALTests: XCTestCase {
    private func header(fixture: [String: Any]) throws -> (fields: [String: Any], data: Data, value: WALSegmentHeader) {
        let fields = try WireTestSupport.headerFields(fixture)
        let data = try WireTestSupport.data(hex: try WireTestSupport.string(fields, "header_hex"))
        let value = try WALSegmentHeader(
            firstMseq: try WireTestSupport.uint64(fields["first_mseq"], "first_mseq"),
            bootID: try WireTestSupport.data(hex: try WireTestSupport.string(fields, "boot_id_hex"))
        )
        return (fields, data, value)
    }

    private func record(fixtureRecord: [String: Any]) throws -> WALRecord {
        let kind = try WireTestSupport.string(fixtureRecord, "kind")
        let fields = try WireTestSupport.fields(fixtureRecord)
        switch kind {
        case "mutation":
            return try WALRecord(
                mseq: try WireTestSupport.uint64(fields["mseq"], "mseq"),
                mutation: try WireTestSupport.mutationBody(fields)
            )
        case "blob_write":
            // W6 (wal.md §14.2): the mutation's data is named by digest.
            return try WALRecord(
                mseq: try WireTestSupport.uint64(fields["mseq"], "mseq"),
                blobWrite: try WALBlobWrite(
                    mode: try WireTestSupport.uint32(fields["mode"], "mode"),
                    mflags: VfsMutationFlags(
                        rawValue: try WireTestSupport.uint8(fields["mflags"], "mflags")),
                    appendFrom: try WireTestSupport.uint64(fields["append_from"], "append_from"),
                    blobLength: try WireTestSupport.uint32(fields["blob_len"], "blob_len"),
                    blobSHA256: try WireTestSupport.data(
                        hex: try WireTestSupport.string(fields, "blob_sha256")),
                    path: try WireTestSupport.string(fields, "path")
                )
            )
        case "epoch_close":
            return try WALRecord(
                epochClose: try WireTestSupport.uint64(fields["wall_ms"], "wall_ms"),
                durableUpto: try WireTestSupport.uint64(fields["durable_upto"], "durable_upto")
            )
        default:
            throw WireTestSupport.FixtureError(description: "unknown WAL record kind \(kind)")
        }
    }

    private func segment(_ name: String) throws -> (fixture: [String: Any],
                                                    header: WALSegmentHeader,
                                                    records: [WALRecord],
                                                    data: Data) {
        let fixture = try WireTestSupport.loadWAL(name)
        let (_, _, header) = try header(fixture: fixture)
        let records = try WireTestSupport.records(fixture).map { try record(fixtureRecord: $0) }
        let data = try WireTestSupport.data(hex: try WireTestSupport.string(fixture, "file_hex"))
        return (fixture, header, records, data)
    }

    // MARK: - Header

    func testWALHeaderHandComputedConstant() throws {
        let header = try WALSegmentHeader(firstMseq: 1, bootID: Data(count: 16))
        XCTAssertEqual(header.headerCRC32C, 0x0B0F_9536)
        XCTAssertEqual(
            WireTestSupport.hex(header.encoded()),
            "584c57414c310000000100000000000000000001000000000000000000000000000000000b0f9536"
        )
    }

    func testWALHeaderGoldenRoundTrip() throws {
        for name in try WireTestSupport.walFiles() {
            let fixture = try WireTestSupport.loadWAL(name)
            let (fields, headerData, expected) = try header(fixture: fixture)
            XCTAssertEqual(WireTestSupport.hex(expected.encoded()),
                           try WireTestSupport.string(fields, "header_hex"), name)
            XCTAssertEqual(expected.headerCRC32C,
                           try WireTestSupport.uint32(fields["header_crc32c"], "header_crc32c"), name)
            XCTAssertEqual(expected.format, 1, name)
            XCTAssertEqual(expected.reserved, 0, name)
            XCTAssertEqual(try WALSegmentHeader.decode(headerData), expected, name)
        }
    }

    func testWALHeaderRejectsBadCRC() throws {
        let fixture = try WireTestSupport.loadWAL("segment-1.json")
        var bytes = [UInt8](try WireTestSupport.data(hex: try WireTestSupport.string(
            try WireTestSupport.headerFields(fixture), "header_hex")))
        bytes[13] ^= 0xFF
        XCTAssertThrowsError(try WALSegmentHeader.decode(Data(bytes))) { error in
            guard case .headerCRCMismatch = error as? WALError else {
                return XCTFail("expected headerCRCMismatch, got \(error)")
            }
        }
    }

    func testWALHeaderRejectsBadMagic() throws {
        let fixture = try WireTestSupport.loadWAL("segment-1.json")
        var bytes = [UInt8](try WireTestSupport.data(hex: try WireTestSupport.string(
            try WireTestSupport.headerFields(fixture), "header_hex")))
        bytes[0] = 0x00
        XCTAssertThrowsError(try WALSegmentHeader.decode(Data(bytes))) { error in
            XCTAssertEqual(error as? WALError, .badMagic)
        }
    }

    // MARK: - Records

    func testWALMutationRecordsGolden() throws {
        for name in try WireTestSupport.walFiles() {
            let fixture = try WireTestSupport.loadWAL(name)
            for recordFixture in try WireTestSupport.records(fixture)
            where (try WireTestSupport.string(recordFixture, "kind")) == "mutation" {
                let expectedRecord = try record(fixtureRecord: recordFixture)
                let recordHex = try WireTestSupport.string(recordFixture, "record_hex")
                XCTAssertEqual(WireTestSupport.hex(expectedRecord.encoded()), recordHex, name)
                XCTAssertEqual(expectedRecord.crc32c,
                               try WireTestSupport.uint32(recordFixture["crc32c"], "crc32c"), name)
                XCTAssertFalse(expectedRecord.isEpochClose)
                XCTAssertEqual(try WALRecord.decode(try WireTestSupport.data(hex: recordHex)),
                               expectedRecord, name)
            }
        }
    }

    func testWALEpochCloseRecordsGolden() throws {
        for name in try WireTestSupport.walFiles() {
            let fixture = try WireTestSupport.loadWAL(name)
            for recordFixture in try WireTestSupport.records(fixture)
            where (try WireTestSupport.string(recordFixture, "kind")) == "epoch_close" {
                let expectedRecord = try record(fixtureRecord: recordFixture)
                let recordHex = try WireTestSupport.string(recordFixture, "record_hex")
                XCTAssertEqual(WireTestSupport.hex(expectedRecord.encoded()), recordHex, name)
                XCTAssertTrue(expectedRecord.isEpochClose)
                let close = try XCTUnwrap(try expectedRecord.epochClose())
                XCTAssertEqual(expectedRecord.mseq, close.durableUpto)
                XCTAssertEqual(try WALRecord.decode(try WireTestSupport.data(hex: recordHex)),
                               expectedRecord, name)
            }
        }
    }

    func testWALBlobWriteRecordsGolden() throws {
        var seen = 0
        for name in try WireTestSupport.walFiles() {
            let fixture = try WireTestSupport.loadWAL(name)
            for recordFixture in try WireTestSupport.records(fixture)
            where (try WireTestSupport.string(recordFixture, "kind")) == "blob_write" {
                seen += 1
                let expected = try record(fixtureRecord: recordFixture)
                let recordHex = try WireTestSupport.string(recordFixture, "record_hex")
                XCTAssertEqual(WireTestSupport.hex(expected.encoded()), recordHex, name)
                XCTAssertTrue(expected.isBlobWrite)
                XCTAssertFalse(expected.isEpochClose)
                let blob = try XCTUnwrap(try expected.blobWrite())
                XCTAssertEqual(WireTestSupport.hex(Data(blob.encoded().prefix(1))), "fe", name)
                XCTAssertThrowsError(try expected.mutationBody())
                XCTAssertEqual(try WALRecord.decode(try WireTestSupport.data(hex: recordHex)),
                               expected, name)
            }
        }
        XCTAssertGreaterThan(seen, 0, "no blob_write golden record")
    }

    func testWALBlobWriteBodyLayout() throws {
        let digest = Data(repeating: 0xAB, count: 32)
        let blob = try WALBlobWrite(mode: 0o644,
                                    mflags: [.entryChanged],
                                    appendFrom: 0,
                                    blobLength: 65_536,
                                    blobSHA256: digest,
                                    path: "/dsh/workspace/big.bin")
        XCTAssertEqual(blob.encoded().first, 0xFE)
        XCTAssertEqual(blob.encoded().count, WALBlobWrite.fixedBytes + blob.path.utf8.count)
        XCTAssertEqual(try WALBlobWrite.decode(blob.encoded()), blob)
        XCTAssertEqual(blob.sha256Hex, String(repeating: "ab", count: 32))
    }

    func testWALBlobWriteRejectsInvalidShapes() throws {
        let digest = Data(repeating: 0x01, count: 32)
        XCTAssertThrowsError(try WALBlobWrite(mode: 0o644, mflags: [], appendFrom: 4,
                                              blobLength: 1, blobSHA256: digest,
                                              path: "/dsh/workspace/a"))
        XCTAssertThrowsError(try WALBlobWrite(mode: 0o10000, mflags: [], appendFrom: 0,
                                              blobLength: 1, blobSHA256: digest,
                                              path: "/dsh/workspace/a"))
        XCTAssertThrowsError(try WALBlobWrite(mode: 0o644, mflags: [],
                                              appendFrom: 0, blobLength: 0,
                                              blobSHA256: digest, path: "/dsh/workspace/a"))
        XCTAssertThrowsError(try WALBlobWrite(mode: 0o644, mflags: [],
                                              appendFrom: 0, blobLength: 1,
                                              blobSHA256: Data(count: 31),
                                              path: "/dsh/workspace/a"))
    }

    func testWALRecordRejectsCRCMismatch() throws {
        let fixture = try WireTestSupport.loadFrame("vfs-mut-write-1.json")
        let body = try WireTestSupport.mutationBody(try WireTestSupport.fields(fixture))
        let record = try WALRecord(mseq: 42, mutation: body)
        var bytes = [UInt8](record.encoded())
        bytes[bytes.count - 1] ^= 0xFF
        XCTAssertThrowsError(try WALRecord.decode(Data(bytes))) { error in
            guard case .recordCRCMismatch = error as? WALError else {
                return XCTFail("expected recordCRCMismatch, got \(error)")
            }
        }
    }

    func testWALRecordRejectsTruncatedRecord() throws {
        let fixture = try WireTestSupport.loadFrame("vfs-mut-write-1.json")
        let body = try WireTestSupport.mutationBody(try WireTestSupport.fields(fixture))
        let record = try WALRecord(mseq: 42, mutation: body)
        let bytes = record.encoded().dropLast()
        XCTAssertThrowsError(try WALRecord.decode(Data(bytes))) { error in
            guard case .truncated = error as? WALError else {
                return XCTFail("expected truncated, got \(error)")
            }
        }
    }

    func testWALRecordRejectsTrailingBytes() throws {
        let record = try WALRecord(epochClose: 1000, durableUpto: 7)
        XCTAssertThrowsError(try WALRecord.decode(record.encoded() + Data([0x00]))) { error in
            guard case .recordLengthMismatch = error as? WALError else {
                return XCTFail("expected recordLengthMismatch, got \(error)")
            }
        }
    }

    func testEpochCloseMseqMayBeZero() throws {
        let record = try WALRecord(epochClose: 1234, durableUpto: 0)
        XCTAssertEqual(record.mseq, 0)
        XCTAssertEqual(try record.epochClose(), WALEpochClose(wallMs: 1234, durableUpto: 0))
        XCTAssertEqual(try WALRecord.decode(record.encoded()), record)
    }

    func testEpochCloseBodyLayout() throws {
        let close = WALEpochClose(wallMs: 0x0102_0304_0506_0708, durableUpto: 9)
        XCTAssertEqual(WireTestSupport.hex(close.encoded()),
                       "ff01020304050607080000000000000009")
        XCTAssertEqual(try WALEpochClose.decode(close.encoded()), close)
    }

    // MARK: - Segments

    func testWALSegmentGoldenRoundTrip() throws {
        for name in try WireTestSupport.walFiles() {
            let (fixture, header, records, data) = try segment(name)
            let expectedRecords = try WireTestSupport.records(fixture).map { try record(fixtureRecord: $0) }
            XCTAssertEqual(records, expectedRecords, name)
            let parsedHeader = try WALSegmentHeader.decode(Data(data.prefix(WALSegmentHeader.byteCount)))
            XCTAssertEqual(parsedHeader, header, name)
            let segment = try WALSegment(header: header, records: expectedRecords)
            XCTAssertEqual(segment.encoded(), data, name)
            let decoded = try WALSegment.decode(data)
            XCTAssertEqual(decoded, segment, name)
        }
    }

    func testWALSegmentRejectsMutationHole() throws {
        let body = VfsMutationBody(op: .write, mode: 0o644, mflags: [.entryChanged],
                                   path: "/dsh/home/x", data: Data("x".utf8))
        let header = try WALSegmentHeader(firstMseq: 5, bootID: Data(count: 16))
        let record = try WALRecord(mseq: 6, mutation: body)
        XCTAssertThrowsError(try WALSegment(header: header, records: [record])) { error in
            guard case .invalidSegment = error as? WALError else {
                return XCTFail("expected invalidSegment, got \(error)")
            }
        }
    }

    func testWALSegmentRejectsTornTail() throws {
        let (_, _, _, data) = try segment("segment-1.json")
        XCTAssertThrowsError(try WALSegment.decode(data.dropLast())) { error in
            guard case .truncated = error as? WALError else {
                return XCTFail("expected truncated, got \(error)")
            }
        }
    }

    func testWALSegmentRejectsRecordAfterEpochClose() throws {
        let fixture = try WireTestSupport.loadWAL("segment-1.json")
        let (_, header, records, _) = try segment("segment-1.json")
        let body = VfsMutationBody(op: .mkdir, mode: 0o755,
                                   path: "/dsh/workspace/late", data: Data())
        let late = try WALRecord(mseq: header.firstMseq + UInt64(records.count), mutation: body)
        XCTAssertThrowsError(try WALSegment(header: header, records: records + [late])) { error in
            guard case .invalidSegment = error as? WALError else {
                return XCTFail("expected invalidSegment for \(fixture), got \(error)")
            }
        }
    }

    func testWALRecordMutationBodyRoundTrip() throws {
        let body = VfsMutationBody(op: .write, mode: 0o600, mflags: [.appended],
                                   appendFrom: 12, path: "/dsh/workspace/a.txt",
                                   data: Data("suffix".utf8))
        let record = try WALRecord(mseq: 9, mutation: body)
        XCTAssertEqual(try record.mutationBody(), body)
        XCTAssertEqual(try WALRecord.decode(record.encoded()).mutationBody(), body)
    }
}
