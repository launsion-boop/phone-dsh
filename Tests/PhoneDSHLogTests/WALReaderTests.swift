// SPDX-License-Identifier: MIT
// WALReader: golden vectors, cross-segment iteration, verified records.

import Foundation
import XCTest
@testable import PhoneDSHLog
import PhoneDSHWire

final class WALReaderTests: XCTestCase {
    func testGoldenWALSegmentsAreReadable() throws {
        for name in ["segment-1.json", "segment-epoch-only.json"] {
            let root = LogTestSupport.root(for: self, name: UUID().uuidString)
            let fixture = try LogTestSupport.installGoldenSegment(name, in: root)
            let scan = try WALReader.scan(directory: LogTestSupport.walDirectory(root))
            XCTAssertEqual(scan.segments.count, 1, name)
            let segment = try XCTUnwrap(scan.segments.first)
            let header = try LogTestSupport.dictionary(fixture, "header")
            XCTAssertEqual(segment.header.firstMseq,
                           try LogTestSupport.uint64(header["first_mseq"], "first_mseq"), name)
            XCTAssertEqual(LogTestSupport.hex(segment.header.bootID),
                           try LogTestSupport.string(header, "boot_id_hex"), name)
            let records = fixture["records"] as? [[String: Any]] ?? []
            XCTAssertEqual(segment.records.count, records.count, name)
            for (index, recordFixture) in records.enumerated() {
                XCTAssertEqual(LogTestSupport.hex(segment.records[index].encoded()),
                               try LogTestSupport.string(recordFixture, "record_hex"), name)
            }
            if let close = segment.records.last, close.isEpochClose {
                let fields = try LogTestSupport.dictionary(records.last ?? [:], "fields")
                let value = try XCTUnwrap(segment.epochClose)
                XCTAssertEqual(value.wallMs,
                               try LogTestSupport.uint64(fields["wall_ms"], "wall_ms"), name)
                XCTAssertEqual(value.durableUpto,
                               try LogTestSupport.uint64(fields["durable_upto"], "durable_upto"), name)
            }
        }
    }

    func testRecordsAcrossSegmentsFromAGivenMseq() async throws {
        let root = LogTestSupport.root(for: self)
        var configuration = LogTestSupport.configuration(root: root)
        configuration.segmentRollBytes = 220
        let writer = try WALWriter(configuration: configuration, bootID: LogTestSupport.bootID())
        for index in 0..<5 {
            _ = try await writer.append(
                LogTestSupport.write("/dsh/workspace/f\(index).txt",
                                     data: String(repeating: "z", count: 100)))
        }
        let segments = try LogTestSupport.segments(in: root)
        XCTAssertGreaterThan(segments.count, 1)

        let all = try WALReader.records(directory: LogTestSupport.walDirectory(root), fromMseq: 1)
        XCTAssertEqual(all.map(\.mseq), [1, 2, 3, 4, 5])
        let tail = try WALReader.records(directory: LogTestSupport.walDirectory(root), fromMseq: 3)
        XCTAssertEqual(tail.map(\.mseq), [3, 4, 5])
        let last = WALReader.records(in: segments, fromMseq: 5)
        XCTAssertEqual(last.map(\.mseq), [5])
    }

    func testRecordsIncludeEpochCloseOnlyWhenRequested() async throws {
        let root = LogTestSupport.root(for: self)
        let writer = try WALWriter(configuration: LogTestSupport.configuration(root: root),
                                   bootID: LogTestSupport.bootID())
        _ = try await writer.append(LogTestSupport.write("/dsh/workspace/a", data: "a"))
        _ = try await writer.closeEpoch()
        let withoutClose = try WALReader.records(
            directory: LogTestSupport.walDirectory(root), fromMseq: 1)
        XCTAssertEqual(withoutClose.count, 1)
        let withClose = try WALReader.records(
            directory: LogTestSupport.walDirectory(root), fromMseq: 1, includeEpochClose: true)
        XCTAssertEqual(withClose.count, 2)
        XCTAssertTrue(withClose.last?.isEpochClose ?? false)
    }

    func testScanRejectsMissingHeaderCRCOfANonTailSegment() throws {
        let root = LogTestSupport.root(for: self)
        let directory = LogTestSupport.walDirectory(root)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let first = try WALSegmentHeader(firstMseq: 1, bootID: LogTestSupport.bootID())
        let second = try WALSegmentHeader(firstMseq: 2, bootID: LogTestSupport.bootID())
        let third = try WALSegmentHeader(firstMseq: 3, bootID: LogTestSupport.bootID())
        try first.encoded().write(to: directory.appendingPathComponent("00000001.000000.xlwal"))
        try second.encoded().write(to: directory.appendingPathComponent("00000001.000001.xlwal"))
        try third.encoded().write(to: directory.appendingPathComponent("00000001.000002.xlwal"))
        var corrupt = [UInt8](second.encoded())
        corrupt[16] ^= 0x7F
        try Data(corrupt).write(to: directory.appendingPathComponent("00000001.000001.xlwal"))
        XCTAssertThrowsError(try WALReader.scan(directory: directory)) { error in
            guard case LogError.corrupt = error else {
                return XCTFail("expected WAL_CORRUPT, got \(error)")
            }
        }
    }

    func testTornHeaderOfNewestSegmentIsDiscardedByTruncation() throws {
        let root = LogTestSupport.root(for: self)
        let directory = LogTestSupport.walDirectory(root)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let header = try WALSegmentHeader(firstMseq: 1, bootID: LogTestSupport.bootID())
        try header.encoded().write(to: directory.appendingPathComponent("00000001.000000.xlwal"))
        let partial = directory.appendingPathComponent("00000001.000001.xlwal")
        try Data([0x58, 0x4C, 0x57]).write(to: partial)

        let scan = try WALReader.scan(directory: directory, truncateTornTail: true)
        XCTAssertTrue(scan.truncatedTornTail)
        XCTAssertEqual(scan.tornHeaderFileName, "00000001.000001.xlwal")
        XCTAssertFalse(FileManager.default.fileExists(atPath: partial.path))
        XCTAssertEqual(scan.segments.count, 1)
    }
}
