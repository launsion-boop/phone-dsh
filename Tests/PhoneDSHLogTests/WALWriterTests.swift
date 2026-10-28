// SPDX-License-Identifier: MIT
// WALWriter: group commit, acks, epochs, rotation, torn tails, quota.

import Foundation
import XCTest
@testable import PhoneDSHLog
import PhoneDSHWire

final class WALWriterTests: XCTestCase {
    func testAppendAssignsConsecutiveMseqAndPersists() async throws {
        let root = LogTestSupport.root(for: self)
        let configuration = LogTestSupport.configuration(root: root)
        let writer = try WALWriter(configuration: configuration, bootID: LogTestSupport.bootID())

        let first = try await writer.append(LogTestSupport.write("/dsh/workspace/a.txt", data: "one"))
        let second = try await writer.append(LogTestSupport.write("/dsh/workspace/b.txt", data: "two"))
        let third = try await writer.append(LogTestSupport.mkdir("/dsh/workspace/sub"))
        XCTAssertEqual([first, second, third], [1, 2, 3])
        let nextMseq = await writer.nextMseq
        let lastMseq = await writer.lastMseq
        XCTAssertEqual(nextMseq, 4)
        XCTAssertEqual(lastMseq, 3)

        let records = try LogTestSupport.records(in: root)
        XCTAssertEqual(records.map(\.mseq), [1, 2, 3])
        XCTAssertEqual(try records[0].mutationBody().path, "/dsh/workspace/a.txt")
        XCTAssertEqual(try records[1].mutationBody().data, Data("two".utf8))
    }

    func testGroupCommitBatchesConcurrentAppendsIntoOneWrite() async throws {
        let root = LogTestSupport.root(for: self)
        var configuration = LogTestSupport.configuration(root: root)
        configuration.groupCommitDelay = 0.2
        let writer = try WALWriter(configuration: configuration, bootID: LogTestSupport.bootID())

        let mseqs = try await withThrowingTaskGroup(of: UInt64.self) { group in
            for index in 0..<5 {
                group.addTask {
                    try await writer.append(
                        LogTestSupport.write("/dsh/workspace/f\(index).txt",
                                             data: "payload-\(index)"))
                }
            }
            var result: [UInt64] = []
            for try await mseq in group {
                result.append(mseq)
            }
            return result.sorted()
        }
        XCTAssertEqual(mseqs, [1, 2, 3, 4, 5])
        let batchCount = await writer.batchCount
        let writeCount = await writer.recordWriteCount
        XCTAssertEqual(batchCount, 1)
        XCTAssertEqual(writeCount, 1,
                       "one write() must cover the whole group-commit batch")
    }

    func testGroupCommittedRotationNeverExceedsTheSegmentCap() async throws {
        let root = LogTestSupport.root(for: self)
        var configuration = LogTestSupport.configuration(root: root)
        configuration.segmentRollBytes = 260
        configuration.groupCommitDelay = 0.2
        let writer = try WALWriter(configuration: configuration,
                                   bootID: LogTestSupport.bootID())
        let mseqs = try await withThrowingTaskGroup(of: UInt64.self) { group in
            for index in 0..<4 {
                group.addTask {
                    try await writer.append(LogTestSupport.write(
                        "/dsh/workspace/r\(index)",
                        data: String(repeating: "r", count: 120)))
                }
            }
            var result: [UInt64] = []
            for try await mseq in group { result.append(mseq) }
            return result.sorted()
        }
        XCTAssertEqual(mseqs, [1, 2, 3, 4])
        let segments = try LogTestSupport.segments(in: root)
        XCTAssertGreaterThanOrEqual(segments.count, 4)
        for segment in segments {
            XCTAssertLessThanOrEqual(segment.byteCount,
                                     configuration.segmentRollBytes,
                                     "a rotation inside one group-commit batch respected the cap")
        }
        XCTAssertEqual(try LogTestSupport.records(in: root).map(\.mseq), [1, 2, 3, 4])
    }

    func testLevelOneAcksAreCumulativeAndOrdered() async throws {
        let root = LogTestSupport.root(for: self)
        var configuration = LogTestSupport.configuration(root: root)
        configuration.groupCommitDelay = 0.05
        let writer = try WALWriter(configuration: configuration, bootID: LogTestSupport.bootID())
        let collector = AckCollector(writer.acks())

        _ = try await writer.append(LogTestSupport.write("/dsh/workspace/a", data: "a"))
        _ = try await writer.append(LogTestSupport.write("/dsh/workspace/b", data: "b"))
        let acks = await collector.waitForCount(1)
        XCTAssertFalse(acks.isEmpty)
        XCTAssertTrue(acks.allSatisfy { $0.level == .write })
        let uptos = acks.map(\.uptoMseq)
        XCTAssertEqual(uptos, uptos.sorted())
        XCTAssertLessThanOrEqual(uptos.last ?? 0, 2)
    }

    func testLevelTwoAckAppearsOnlyAfterCloseEpoch() async throws {
        let root = LogTestSupport.root(for: self)
        let writer = try WALWriter(configuration: LogTestSupport.configuration(root: root),
                                   bootID: LogTestSupport.bootID())
        let collector = AckCollector(writer.acks())

        _ = try await writer.append(LogTestSupport.write("/dsh/workspace/a", data: "a"))
        _ = await collector.waitForCount(1)
        XCTAssertTrue(collector.values.allSatisfy { $0.level == .write })
        let noDurable = await writer.lastLevel2Ack
        XCTAssertNil(noDurable)

        let result = try await writer.closeEpoch()
        XCTAssertEqual(result.durableUpto, 1)
        XCTAssertEqual(result.epoch, 1)
        XCTAssertEqual(result.nextEpoch, 2)
        let currentEpoch = await writer.currentEpoch
        let lastDurableEpoch = await writer.lastDurableEpoch
        XCTAssertEqual(currentEpoch, 2)
        XCTAssertEqual(lastDurableEpoch, 1)
        let acks = await collector.waitForCount(2)
        XCTAssertEqual(acks.last?.level, .epochFsync)
        XCTAssertEqual(acks.last?.uptoMseq, 1)
    }

    func testEpochIncrementsAndSegmentsRotateWithFirstMseq() async throws {
        let root = LogTestSupport.root(for: self)
        var configuration = LogTestSupport.configuration(root: root)
        configuration.segmentRollBytes = 200
        let writer = try WALWriter(configuration: configuration, bootID: LogTestSupport.bootID())

        for index in 0..<4 {
            _ = try await writer.append(
                LogTestSupport.write("/dsh/workspace/file\(index).txt",
                                     data: String(repeating: "x", count: 120)))
        }
        let segments = try LogTestSupport.segments(in: root)
        XCTAssertGreaterThan(segments.count, 1, "the segment cap must force a rotation")
        XCTAssertEqual(segments.first?.header.firstMseq, 1)
        for pair in zip(segments, segments.dropFirst()) {
            XCTAssertLessThan(pair.0.name, pair.1.name)
            XCTAssertEqual(pair.1.header.firstMseq, (pair.0.lastMutationMseq) + 1)
        }
        let records = try LogTestSupport.records(in: root)
        XCTAssertEqual(records.map(\.mseq), [1, 2, 3, 4])

        _ = try await writer.closeEpoch()
        let currentEpoch = await writer.currentEpoch
        XCTAssertEqual(currentEpoch, 2)
        let afterClose = try LogTestSupport.segments(in: root)
        XCTAssertEqual(afterClose.filter { $0.epoch == 1 }.count, segments.count)
        XCTAssertEqual(afterClose.filter { $0.epoch == 2 }.count, 1)
        let manifest = try XCTUnwrap(try ManifestStore(root: root).read())
        XCTAssertEqual(manifest.segments.count, segments.count,
                       "every durable segment of the epoch is listed, not only the close record's")
        XCTAssertEqual(manifest.lastDurableEpoch, 1)
    }

    func testIdleEpochCloseWritesTheEpochOnlySegment() async throws {
        let root = LogTestSupport.root(for: self)
        let writer = try WALWriter(configuration: LogTestSupport.configuration(root: root),
                                   bootID: LogTestSupport.bootID())
        let idle = try await writer.closeEpoch()
        XCTAssertEqual(idle.durableUpto, 0)
        var segments = try LogTestSupport.segments(in: root)
        let epochOne = segments.filter { $0.epoch == 1 }
        XCTAssertEqual(epochOne.count, 1)
        let close = try XCTUnwrap(epochOne.first?.epochClose)
        XCTAssertEqual(close.durableUpto, 0)
        let next = try await writer.append(LogTestSupport.write("/dsh/workspace/a", data: "a"))
        XCTAssertEqual(next, 1)
        let second = try await writer.closeEpoch()
        XCTAssertEqual(second.durableUpto, 1)
        segments = try LogTestSupport.segments(in: root)
        XCTAssertEqual(segments.filter { $0.epoch == 2 }.count, 1)
        XCTAssertEqual(try LogTestSupport.records(in: root).map(\.mseq), [1])
    }

    func testQuotaCompactsDroppableEpochsBeforeFailing() async throws {
        let root = LogTestSupport.root(for: self)
        var configuration = LogTestSupport.configuration(root: root, walQuotaBytes: 850)
        configuration.segmentRollBytes = 260
        let writer = try WALWriter(configuration: configuration,
                                   bootID: LogTestSupport.bootID())
        for index in 0..<4 {
            _ = try await writer.append(
                LogTestSupport.write("/dsh/workspace/e1-\(index)",
                                     data: String(repeating: "a", count: 120)))
        }
        try await writer.recordMaterializedUpto(4)
        _ = try await writer.closeEpoch()
        for index in 0..<2 {
            _ = try await writer.append(
                LogTestSupport.write("/dsh/workspace/e2-\(index)",
                                     data: String(repeating: "b", count: 120)))
        }
        try await writer.recordMaterializedUpto(6)
        _ = try await writer.closeEpoch()

        let before = await writer.walByteCount
        XCTAssertGreaterThan(before, 700)
        let next = try await writer.append(LogTestSupport.write(
            "/dsh/workspace/e3", data: String(repeating: "c", count: 120)))
        XCTAssertEqual(next, 7)
        let after = await writer.walByteCount
        XCTAssertLessThan(after, before, "compaction must run before the quota error")
    }

    func testOpenTruncatesTornTailAndReportsIt() async throws {
        let root = LogTestSupport.root(for: self)
        let configuration = LogTestSupport.configuration(root: root)
        let bootID = LogTestSupport.bootID()

        let firstWriter = try WALWriter(configuration: configuration, bootID: bootID)
        _ = try await firstWriter.append(LogTestSupport.write("/dsh/workspace/a", data: "alpha"))
        _ = try await firstWriter.append(LogTestSupport.write("/dsh/workspace/b", data: "beta"))
        let segmentURL = try XCTUnwrap(try LogTestSupport.segments(in: root).first?.url)
        let handle = try FileHandle(forWritingTo: segmentURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data([0x00, 0x00, 0x00, 0x40, 0xFF, 0xEE]))
        try handle.close()

        let secondWriter = try WALWriter(configuration: configuration, bootID: bootID)
        let truncated = await secondWriter.truncatedTornTail
        XCTAssertTrue(truncated)
        XCTAssertEqual(try LogTestSupport.records(in: root).map(\.mseq), [1, 2])
        let size = try LogFile.size(segmentURL)
        let scanned = try LogTestSupport.segments(in: root)
        let firstSegment = try XCTUnwrap(scanned.first(where: { $0.url == segmentURL }))
        XCTAssertEqual(size, firstSegment.validByteCount)
    }

    func testOpenRejectsCorruptRecordBeforeTheTail() throws {
        let root = LogTestSupport.root(for: self)
        let fixture = try LogTestSupport.installGoldenSegment("segment-1.json", in: root)
        let segmentURL = LogTestSupport.walDirectory(root)
            .appendingPathComponent("00000001.000000.xlwal")
        var bytes = [UInt8](try LogTestSupport.data(
            hex: try LogTestSupport.string(fixture, "file_hex")))
        // Flip a byte inside the first record's body; the later records are
        // still complete, so this is a non-tail CRC failure (D19).
        bytes[40 + 24] ^= 0xFF
        try Data(bytes).write(to: segmentURL)
        XCTAssertThrowsError(try WALReader.scan(directory: LogTestSupport.walDirectory(root))) { error in
            guard case LogError.corrupt = error else {
                return XCTFail("expected WAL_CORRUPT, got \(error)")
            }
        }
    }

    func testReopenStartsNewEpochAndNeverReusesMseq() async throws {
        let root = LogTestSupport.root(for: self)
        let configuration = LogTestSupport.configuration(root: root)
        let bootID = LogTestSupport.bootID()
        do {
            let writer = try WALWriter(configuration: configuration, bootID: bootID)
            _ = try await writer.append(LogTestSupport.write("/dsh/workspace/a", data: "a"))
            _ = try await writer.append(LogTestSupport.write("/dsh/workspace/b", data: "b"))
            _ = try await writer.closeEpoch()
        }
        let writer = try WALWriter(configuration: configuration, bootID: bootID)
        let nextMseq = await writer.nextMseq
        let currentEpoch = await writer.currentEpoch
        XCTAssertEqual(nextMseq, 3)
        XCTAssertEqual(currentEpoch, 3)
        let mseq = try await writer.append(LogTestSupport.write("/dsh/workspace/c", data: "c"))
        XCTAssertEqual(mseq, 3)
        XCTAssertEqual(try LogTestSupport.records(in: root).map(\.mseq), [1, 2, 3])
    }

    func testQuotaExceededIsThrownWhenNothingIsDroppable() async throws {
        let root = LogTestSupport.root(for: self)
        let configuration = LogTestSupport.configuration(root: root,
                                                         segmentRollBytes: 4096,
                                                         walQuotaBytes: 520)
        let writer = try WALWriter(configuration: configuration, bootID: LogTestSupport.bootID())
        _ = try await writer.append(
            LogTestSupport.write("/dsh/workspace/a", data: String(repeating: "x", count: 250)))
        do {
            _ = try await writer.append(
                LogTestSupport.write("/dsh/workspace/b", data: String(repeating: "y", count: 250)))
            XCTFail("expected quotaExceeded")
        } catch let error as LogError {
            guard case .quotaExceeded(let resource, let limit, let used) = error else {
                return XCTFail("unexpected error \(error)")
            }
            XCTAssertEqual(resource, .wal)
            XCTAssertEqual(limit, 520)
            XCTAssertGreaterThan(used, limit)
        }
    }

    func testCompactionDropsClosedSegmentsBelowTheWatermark() async throws {
        let root = LogTestSupport.root(for: self)
        var configuration = LogTestSupport.configuration(root: root)
        configuration.segmentRollBytes = 260
        let writer = try WALWriter(configuration: configuration, bootID: LogTestSupport.bootID())

        for index in 0..<4 {
            _ = try await writer.append(
                LogTestSupport.write("/dsh/workspace/e1-\(index)",
                                     data: String(repeating: "a", count: 120)))
        }
        try await writer.recordMaterializedUpto(4)
        _ = try await writer.closeEpoch()

        let epochOne = try LogTestSupport.segments(in: root).filter { $0.epoch == 1 }
        XCTAssertGreaterThan(epochOne.count, 1)

        for index in 0..<2 {
            _ = try await writer.append(
                LogTestSupport.write("/dsh/workspace/e2-\(index)",
                                     data: String(repeating: "b", count: 120)))
        }
        try await writer.recordMaterializedUpto(6)
        _ = try await writer.closeEpoch()

        let before = await writer.walByteCount
        let dropped = try await writer.compactDroppableSegments()
        XCTAssertFalse(dropped.isEmpty)
        let after = await writer.walByteCount
        XCTAssertLessThan(after, before)
        let remaining = try LogTestSupport.segments(in: root)
        XCTAssertTrue(remaining.allSatisfy { $0.epoch != 1 })
    }

    func testManifestIsWrittenWithSortedKeysAndContiguousWatermark() async throws {
        let root = LogTestSupport.root(for: self)
        let writer = try WALWriter(configuration: LogTestSupport.configuration(root: root),
                                   bootID: LogTestSupport.bootID())
        _ = try await writer.append(LogTestSupport.write("/dsh/workspace/a", data: "a"))
        try await writer.recordMaterializedUpto(1)
        let manifest = try XCTUnwrap(try ManifestStore(root: root).read())
        XCTAssertEqual(manifest.format, 1)
        XCTAssertEqual(manifest.materializedUptoMseq, 1)
        XCTAssertEqual(manifest.lastMseq, 1)
        XCTAssertEqual(manifest.bootID, LogTestSupport.hex(LogTestSupport.bootID()))
        let raw = try String(contentsOf: WorkspacePaths(root: root).manifestURL, encoding: .utf8)
        XCTAssertTrue(raw.contains("\"materialized_upto_mseq\":1"))
        XCTAssertTrue(raw.contains("\"last_mseq\":1"))
    }
}
