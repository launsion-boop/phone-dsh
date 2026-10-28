// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — PhoneDSHLog: verified WAL iteration.
//
// PLAN §2.3 (D11/D19) and spec/v1/wal.md §1–§4, §10. A reader scans
// every `wal/*.xlwal` file of a workspace, verifies each segment header and
// every record CRC32C, tolerates a torn tail only in the newest segment and
// yields records in mseq order. It never mutates a file unless the caller asks
// for torn-tail truncation.

import Foundation
import PhoneDSHWire

/// One parsed segment file of a workspace.
public struct WALSegmentFile: Equatable, Sendable {
    public let name: WALSegmentName
    public let url: URL
    public let header: WALSegmentHeader
    /// Verified records in file order (epoch close last when present).
    public let records: [WALRecord]
    /// File size on disk at scan time.
    public let byteCount: Int
    /// Bytes that belong to complete, verified records (header included).
    public let validByteCount: Int
    /// Trailing bytes dropped by the D19 torn-tail rule.
    public let tornTailBytes: Int

    public init(name: WALSegmentName,
                url: URL,
                header: WALSegmentHeader,
                records: [WALRecord],
                byteCount: Int,
                validByteCount: Int,
                tornTailBytes: Int) {
        self.name = name
        self.url = url
        self.header = header
        self.records = records
        self.byteCount = byteCount
        self.validByteCount = validByteCount
        self.tornTailBytes = tornTailBytes
    }

    public var epoch: UInt64 { name.epoch }
    public var segment: UInt64 { name.segment }
    public var fileName: String { name.fileName }
    public var manifestFile: String { name.manifestFile }

    /// Highest mutation mseq in the segment; 0 when it holds only headers or a
    /// close record (wal.md §7 `last_mseq`).
    public var lastMutationMseq: UInt64 {
        records.reduce(0) { partial, record in
            record.isEpochClose ? partial : max(partial, record.mseq)
        }
    }

    /// Lowest mutation mseq in the segment, when it has a mutation.
    public var firstMutationMseq: UInt64? {
        records.first(where: { !$0.isEpochClose })?.mseq
    }

    public var mutationCount: Int {
        records.reduce(0) { $0 + ($1.isEpochClose ? 0 : 1) }
    }

    /// The verified epoch-close value, when the segment closed its epoch.
    public var epochClose: WALEpochClose? {
        for record in records where record.isEpochClose {
            if let value = try? record.epochClose() {
                return value
            }
        }
        return nil
    }

    public var hasEpochClose: Bool { epochClose != nil }

    /// The manifest view of this segment (wal.md §7).
    public var manifestSegment: ManifestSegment {
        ManifestSegment(file: manifestFile,
                        epoch: epoch,
                        firstMseq: header.firstMseq,
                        lastMseq: lastMutationMseq)
    }
}

/// Result of scanning a `wal/` directory.
public struct WALScan: Equatable, Sendable {
    /// Complete, verified segments in `<epoch, segment>` order.
    public var segments: [WALSegmentFile]
    /// A torn tail was observed in the newest segment (D19, not an error).
    public var truncatedTornTail: Bool
    /// Bytes dropped by the torn-tail rule.
    public var discardedBytes: Int
    /// A newest segment whose header was torn (power loss during segment
    /// creation); it is excluded from `segments` and unlinked by truncation.
    public var tornHeaderURL: URL?

    public init(segments: [WALSegmentFile],
                truncatedTornTail: Bool = false,
                discardedBytes: Int = 0,
                tornHeaderURL: URL? = nil) {
        self.segments = segments
        self.truncatedTornTail = truncatedTornTail
        self.discardedBytes = discardedBytes
        self.tornHeaderURL = tornHeaderURL
    }

    /// File name of the torn-header segment, when there is one.
    public var tornHeaderFileName: String? { tornHeaderURL?.lastPathComponent }

    public var allRecords: [WALRecord] {
        segments.flatMap(\.records)
    }

    /// Structural check used by recovery: a mutation mseq appears at most once.
    public var mutationMseqs: [UInt64] {
        segments.flatMap { segment in
            segment.records.compactMap { $0.isEpochClose ? nil : $0.mseq }
        }
    }

    /// Highest retained mutation mseq, 0 when there is none.
    public var lastMutationMseq: UInt64 {
        mutationMseqs.max() ?? 0
    }

    /// Highest `durable_upto` among verified epoch-close records (D7, §10).
    public var durableMseq: UInt64 {
        segments.compactMap { $0.epochClose?.durableUpto }.max() ?? 0
    }

    /// Epoch number of the most recently closed epoch, 0 when none.
    public var lastDurableEpoch: UInt64 {
        segments.filter(\.hasEpochClose).map(\.epoch).max() ?? 0
    }

    /// Highest epoch number that has any segment on disk.
    public var highestEpoch: UInt64 {
        segments.map(\.epoch).max() ?? 0
    }

    /// The highest epoch-close record present; never droppable (wal.md §9).
    public var newestEpochCloseSegment: WALSegmentFile? {
        segments.filter(\.hasEpochClose).max { lhs, rhs in
            if lhs.epoch != rhs.epoch { return lhs.epoch < rhs.epoch }
            return lhs.segment < rhs.segment
        }
    }
}

/// Verified WAL iteration (PLAN §2.3 `WALReader`).
public enum WALReader {
    /// Scans a `wal/` directory. With `truncateTornTail`, the newest segment is
    /// physically truncated to its last complete record (D19) and a torn
    /// header file is unlinked; the returned scan already reflects that.
    public static func scan(directory: URL, truncateTornTail: Bool = false) throws -> WALScan {
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        let names = entries.compactMap(WALSegmentName.init(fileName:)).sorted()
        var segments: [WALSegmentFile] = []
        var tornHeaderURL: URL?
        var discarded = 0
        var sawTornTail = false

        for (index, name) in names.enumerated() {
            let isNewest = index == names.count - 1
            let url = name.url(in: directory)
            let data: Data
            do {
                data = try LogFile.readAll(url)
            } catch {
                throw LogError.corrupt("unreadable WAL segment \(name.fileName)")
            }
            switch try parse(name: name, url: url, data: data, isNewest: isNewest) {
            case .complete(let segment):
                segments.append(segment)
                if segment.tornTailBytes > 0 {
                    sawTornTail = true
                    discarded += segment.tornTailBytes
                }
            case .tornHeader(let bytes):
                guard isNewest else {
                    throw LogError.corrupt("WAL header of \(name.fileName) is corrupt")
                }
                tornHeaderURL = url
                sawTornTail = true
                discarded += bytes
            }
        }

        let result = WALScan(segments: segments,
                             truncatedTornTail: sawTornTail,
                             discardedBytes: discarded,
                             tornHeaderURL: tornHeaderURL)
        if truncateTornTail {
            return try WALReader.truncateTornTail(result)
        }
        return result
    }

    /// Applies the D19 torn-tail truncation described by `scan` and returns a
    /// scan whose last segment reflects the truncated file size.
    @discardableResult
    public static func truncateTornTail(_ scan: WALScan) throws -> WALScan {
        var updated = scan
        if let tornHeaderURL = scan.tornHeaderURL {
            try LogFile.unlink(tornHeaderURL)
        }
        if var last = updated.segments.last, last.tornTailBytes > 0,
           updated.truncatedTornTail {
            try LogFile.truncate(last.url, to: last.validByteCount)
            last = WALSegmentFile(name: last.name,
                                  url: last.url,
                                  header: last.header,
                                  records: last.records,
                                  byteCount: last.validByteCount,
                                  validByteCount: last.validByteCount,
                                  tornTailBytes: 0)
            updated.segments[updated.segments.count - 1] = last
        }
        return updated
    }

    /// Reads every verified mutation record with `mseq >= fromMseq` across all
    /// segments, ascending. Epoch-close records are excluded by default.
    public static func records(directory: URL,
                               fromMseq: UInt64,
                               includeEpochClose: Bool = false) throws -> [WALRecord] {
        let scan = try scan(directory: directory)
        return records(in: scan.segments, fromMseq: fromMseq, includeEpochClose: includeEpochClose)
    }

    public static func records(in segments: [WALSegmentFile],
                               fromMseq: UInt64,
                               includeEpochClose: Bool = false) -> [WALRecord] {
        var result: [WALRecord] = []
        for segment in segments {
            for record in segment.records {
                if record.isEpochClose {
                    if includeEpochClose && record.mseq >= fromMseq {
                        result.append(record)
                    }
                    continue
                }
                if record.mseq >= fromMseq {
                    result.append(record)
                }
            }
        }
        return result
    }

    /// Reads the complete records of one segment file (header verified).
    public static func segment(at url: URL) throws -> WALSegmentFile {
        guard let name = WALSegmentName(fileName: url.lastPathComponent) else {
            throw LogError.corrupt("not a WAL segment name")
        }
        let data = try LogFile.readAll(url)
        switch try parse(name: name, url: url, data: data, isNewest: true) {
        case .complete(let segment):
            return segment
        case .tornHeader:
            throw LogError.corrupt("WAL header is torn")
        }
    }

    // MARK: - Parsing

    private enum ParseResult {
        case complete(WALSegmentFile)
        case tornHeader(Int)
    }

    private static func parse(name: WALSegmentName,
                              url: URL,
                              data: Data,
                              isNewest: Bool) throws -> ParseResult {
        let headerBytes = WALSegmentHeader.byteCount
        if data.count < headerBytes {
            if isNewest { return .tornHeader(data.count) }
            throw LogError.corrupt("WAL segment \(name.fileName) is shorter than its header")
        }
        let header: WALSegmentHeader
        do {
            header = try WALSegmentHeader.decode(Data(data.prefix(headerBytes)))
        } catch {
            if isNewest { return .tornHeader(data.count) }
            throw LogError.corrupt("WAL header of \(name.fileName) failed verification")
        }

        var records: [WALRecord] = []
        var offset = headerBytes
        var tornBytes = 0

        recordLoop: while offset < data.count {
            let remaining = data.count - offset
            if remaining < 8 {
                tornBytes = remaining
                break
            }
            let length = Int(data.uint32BigEndian(at: offset))
            guard length >= 8 else {
                if isNewest && !hasCompleteRecord(in: data, after: offset) {
                    tornBytes = remaining
                    break
                }
                throw LogError.corrupt("WAL record len \(length) in \(name.fileName)")
            }
            let total = 8 + length
            guard total <= remaining else {
                if isNewest && !hasCompleteRecord(in: data, after: offset) {
                    tornBytes = remaining
                    break
                }
                throw LogError.corrupt("WAL record length runs past \(name.fileName)")
            }
            let recordData = data.subdata(in: offset..<(offset + total))
            do {
                records.append(try WALRecord.decode(recordData))
                offset += total
            } catch {
                let classification = classifyCorruption(error)
                switch classification {
                case .tornTail:
                    // D19: a len/CRC failure is a torn tail only when no
                    // complete record follows it.
                    if isNewest && !hasCompleteRecord(in: data, after: offset) {
                        tornBytes = remaining
                        break recordLoop
                    }
                    throw LogError.corrupt("WAL record at the end of \(name.fileName) is torn")
                case .corrupt:
                    throw LogError.corrupt("WAL record body failure in \(name.fileName)")
                }
            }
        }

        // Within a segment, mutations must continue from first_mseq and the
        // epoch-close record must be last (wal.md §2–§4).
        do {
            _ = try WALSegment(header: header, records: records)
        } catch {
            throw LogError.corrupt("WAL segment \(name.fileName) violates record ordering")
        }

        let validBytes = offset
        return .complete(WALSegmentFile(name: name,
                                        url: url,
                                        header: header,
                                        records: records,
                                        byteCount: data.count,
                                        validByteCount: validBytes,
                                        tornTailBytes: tornBytes))
    }

    private enum CorruptionClass {
        case tornTail
        case corrupt
    }

    private static func classifyCorruption(_ error: Error) -> CorruptionClass {
        guard let walError = error as? WALError else { return .corrupt }
        switch walError {
        case .truncated:
            return .tornTail
        case .recordCRCMismatch:
            return .tornTail
        default:
            return .corrupt
        }
    }

    /// Heuristic required by D19: a CRC or length failure is a torn tail only
    /// when no complete, verified record follows it. A record is written as one
    /// contiguous chunk, so the next record normally starts at the claimed end;
    /// a bounded byte scan covers a corrupted `len` field.
    private static func hasCompleteRecord(in data: Data, after offset: Int) -> Bool {
        let byteCount = data.count
        guard byteCount >= 8, offset + 8 <= byteCount else { return false }
        if byteCount - offset >= 8 {
            let length = Int(data.uint32BigEndian(at: offset))
            if length >= 8, 8 + length <= byteCount - offset {
                if (try? WALRecord.decode(data.subdata(in: offset..<(offset + 8 + length)))) != nil {
                    return true
                }
            }
        }
        var candidate = offset + 1
        let limit = min(byteCount - 8, offset + 1_048_576)
        while candidate <= limit {
            let length = Int(data.uint32BigEndian(at: candidate))
            if length >= 8, candidate + 8 + length <= byteCount {
                let end = candidate + 8 + length
                if (try? WALRecord.decode(data.subdata(in: candidate..<end))) != nil {
                    return true
                }
            }
            candidate += 1
        }
        return false
    }
}
