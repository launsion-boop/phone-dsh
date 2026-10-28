// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — PhoneDSHWire: WAL v1 header and records.
//
// PLAN §2.3 (D7/D17/D19) and spec/v1/wal.md §2–§4. The WAL is the
// recovery log of the in-memory VFS: segment header (40 bytes), records
// (`len|crc32c|mseq|body`) and the epoch-close record whose mseq is
// `durable_upto`. This file only encodes and verifies bytes; epoch fsync,
// materialization and recovery are PhoneDSHLog (W1-LOG).

import Foundation

/// WAL errors. CRC and truncation failures are values, not crashes.
public enum WALError: Error, Equatable, Sendable {
    case truncated(expected: Int, actual: Int)
    case badMagic
    case unsupportedFormat(UInt16)
    case nonZeroReserved(UInt16)
    case invalidFirstMseq(UInt64)
    case invalidBootIDLength(Int)
    case headerCRCMismatch(expected: UInt32, actual: UInt32)
    case recordLengthMismatch(expected: UInt32, actual: Int)
    case recordCRCMismatch(expected: UInt32, actual: UInt32)
    case invalidRecord(String)
    case invalidEpochClose(String)
    case invalidSegment(String)
}

extension WALError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .truncated(let expected, let actual):
            return "truncated WAL data: need \(expected), have \(actual)"
        case .badMagic:
            return "WAL segment magic is not XLWAL1\\0\\0"
        case .unsupportedFormat(let format):
            return "unsupported WAL format \(format)"
        case .nonZeroReserved(let value):
            return "WAL reserved field is \(value), expected 0"
        case .invalidFirstMseq(let value):
            return "WAL first_mseq \(value) is invalid"
        case .invalidBootIDLength(let count):
            return "WAL boot_id has \(count) bytes, expected 16"
        case .headerCRCMismatch(let expected, let actual):
            return "WAL header CRC32C mismatch: expected \(expected), got \(actual)"
        case .recordLengthMismatch(let expected, let actual):
            return "WAL record length \(expected) does not match \(actual) bytes"
        case .recordCRCMismatch(let expected, let actual):
            return "WAL record CRC32C mismatch: expected \(expected), got \(actual)"
        case .invalidRecord(let reason):
            return "invalid WAL record: \(reason)"
        case .invalidEpochClose(let reason):
            return "invalid WAL epoch-close record: \(reason)"
        case .invalidSegment(let reason):
            return "invalid WAL segment: \(reason)"
        }
    }
}

/// The 40-byte WAL segment header (wal.md §2).
public struct WALSegmentHeader: Equatable, Sendable {
    /// `XLWAL1\0\0`.
    public static let magic = Data([0x58, 0x4C, 0x57, 0x41, 0x4C, 0x31, 0x00, 0x00])
    /// Header size fixed by wal.md §2.
    public static let byteCount = WireLimits.walHeaderBytes

    public let format: UInt16
    public let reserved: UInt16
    /// `next_mseq` at segment creation; the first mutation of the segment gets it.
    public let firstMseq: UInt64
    /// Raw 16 boot-id bytes; the hex text form is used by HELLO.
    public let bootID: Data
    /// CRC32C over the first 36 header bytes.
    public let headerCRC32C: UInt32

    /// Builds a format-1 header and computes its CRC.
    public init(firstMseq: UInt64, bootID: Data) throws {
        guard firstMseq >= 1 else {
            throw WALError.invalidFirstMseq(firstMseq)
        }
        guard bootID.count == 16 else {
            throw WALError.invalidBootIDLength(bootID.count)
        }
        self.format = WireLimits.walFormat
        self.reserved = 0
        self.firstMseq = firstMseq
        self.bootID = bootID
        self.headerCRC32C = CRC32C.checksum(Self.prefix(firstMseq: firstMseq, bootID: bootID))
    }

    private init(format: UInt16, reserved: UInt16, firstMseq: UInt64,
                 bootID: Data, headerCRC32C: UInt32) {
        self.format = format
        self.reserved = reserved
        self.firstMseq = firstMseq
        self.bootID = bootID
        self.headerCRC32C = headerCRC32C
    }

    /// The full 40-byte header.
    public func encoded() -> Data {
        var data = Self.prefix(firstMseq: firstMseq, bootID: bootID)
        data.appendBigEndian(headerCRC32C)
        return data
    }

    /// Decodes and verifies a 40-byte segment header.
    public static func decode(_ data: Data) throws -> WALSegmentHeader {
        guard data.count == byteCount else {
            throw WALError.truncated(expected: byteCount, actual: data.count)
        }
        try verifyPrefix(data)
        let format = data.readUInt16(at: 8)
        let reserved = data.readUInt16(at: 10)
        let firstMseq = data.readUInt64(at: 12)
        let bootID = Data(data[data.index(data.startIndex, offsetBy: 20)..<data.index(data.startIndex, offsetBy: 36)])
        let storedCRC = data.readUInt32(at: 36)
        let computedCRC = CRC32C.checksum(data.prefix(36))
        guard storedCRC == computedCRC else {
            throw WALError.headerCRCMismatch(expected: storedCRC, actual: computedCRC)
        }
        return WALSegmentHeader(
            format: format,
            reserved: reserved,
            firstMseq: firstMseq,
            bootID: bootID,
            headerCRC32C: storedCRC
        )
    }

    /// Parses a header at the start of `data` and returns the implied offset.
    static func decodePrefix(_ data: Data) throws -> (header: WALSegmentHeader, consumed: Int) {
        let prefix = Data(data.prefix(byteCount))
        let header = try decode(prefix)
        return (header, byteCount)
    }

    private static func verifyPrefix(_ data: Data) throws {
        guard data.count >= 36 else {
            throw WALError.truncated(expected: 36, actual: data.count)
        }
        guard Data(data.prefix(magic.count)) == magic else {
            throw WALError.badMagic
        }
        let format = data.readUInt16(at: 8)
        guard format == WireLimits.walFormat else {
            throw WALError.unsupportedFormat(format)
        }
        let reserved = data.readUInt16(at: 10)
        guard reserved == 0 else {
            throw WALError.nonZeroReserved(reserved)
        }
        let firstMseq = data.readUInt64(at: 12)
        guard firstMseq >= 1 else {
            throw WALError.invalidFirstMseq(firstMseq)
        }
        guard data.count >= 36 else {
            throw WALError.truncated(expected: 36, actual: data.count)
        }
    }

    private static func prefix(firstMseq: UInt64, bootID: Data) -> Data {
        var data = Data(capacity: 36)
        data.append(magic)
        data.appendBigEndian(WireLimits.walFormat)
        data.appendBigEndian(UInt16(0))
        data.appendBigEndian(firstMseq)
        data.append(bootID)
        return data
    }
}

/// Epoch-close body (wal.md §4): `op 0xFF | wall_ms | durable_upto`.
public struct WALEpochClose: Equatable, Sendable {
    public var wallMs: UInt64
    public var durableUpto: UInt64

    public init(wallMs: UInt64, durableUpto: UInt64) {
        self.wallMs = wallMs
        self.durableUpto = durableUpto
    }

    /// 17-byte body: op byte, then two u64.
    public func encoded() -> Data {
        var data = Data(capacity: 17)
        data.append(WireLimits.walEpochCloseOp)
        data.appendBigEndian(wallMs)
        data.appendBigEndian(durableUpto)
        return data
    }

    public static func decode(_ body: Data) throws -> WALEpochClose {
        guard body.count == 17 else {
            throw WALError.invalidEpochClose("body is \(body.count) bytes, expected 17")
        }
        guard body.readUInt8(at: 0) == WireLimits.walEpochCloseOp else {
            throw WALError.invalidEpochClose("body does not start with op 0xFF")
        }
        return WALEpochClose(wallMs: body.readUInt64(at: 1), durableUpto: body.readUInt64(at: 9))
    }
}

/// One WAL record (wal.md §3): `len u32 | crc32c u32 | mseq u64 | body`.
public struct WALRecord: Equatable, Sendable {
    /// `len` covers `mseq` and the body, excluding `len` and `crc32c`.
    public let length: UInt32
    /// CRC32C over `mseq ‖ body`.
    public let crc32c: UInt32
    /// Alias of `length`, using the field name of wal.md §3.
    public var len: UInt32 { length }
    public let mseq: UInt64
    /// Mutation body (channel.md §3.1 without mseq) or epoch-close body.
    public let body: Data

    /// Builds a mutation record and validates the body.
    public init(mseq: UInt64, body: Data) throws {
        guard mseq >= 1 else {
            throw WALError.invalidRecord("mutation mseq must be at least 1")
        }
        let validated = try WALRecord.validateBody(body, mseq: mseq)
        self = try WALRecord.unchecked(mseq: mseq, body: validated)
    }

    /// Builds a mutation record from a VFS mutation body.
    public init(mseq: UInt64, mutation: VfsMutationBody) throws {
        let body = try mutation.encoded()
        try self.init(mseq: mseq, body: body)
    }

    /// Builds the epoch-close record; its mseq field is `durable_upto` (D7).
    public init(epochClose wallMs: UInt64, durableUpto: UInt64) throws {
        let epoch = WALEpochClose(wallMs: wallMs, durableUpto: durableUpto)
        self = try WALRecord.unchecked(mseq: durableUpto, body: epoch.encoded())
    }

    private init(length: UInt32, crc32c: UInt32, mseq: UInt64, body: Data) {
        self.length = length
        self.crc32c = crc32c
        self.mseq = mseq
        self.body = body
    }

    private static func unchecked(mseq: UInt64, body: Data) throws -> WALRecord {
        guard body.count <= Int(UInt32.max) - 8 else {
            throw WALError.invalidRecord("record body exceeds u32 length")
        }
        let payload = CRCInput.make(mseq: mseq, body: body)
        return WALRecord(
            length: UInt32(payload.count),
            crc32c: CRC32C.checksum(payload),
            mseq: mseq,
            body: body
        )
    }

    /// `true` for the D7 epoch-close record.
    public var isEpochClose: Bool {
        body.first == WireLimits.walEpochCloseOp
    }

    /// Decodes the epoch-close body; `nil` for a mutation record.
    public func epochClose() throws -> WALEpochClose? {
        guard isEpochClose else { return nil }
        let close = try WALEpochClose.decode(body)
        guard mseq == close.durableUpto else {
            throw WALError.invalidEpochClose("mseq does not equal durable_upto")
        }
        return close
    }

    /// Decodes the mutation body; throws for the epoch-close record.
    public func mutationBody() throws -> VfsMutationBody {
        guard !isEpochClose else {
            throw WALError.invalidRecord("epoch-close record has no mutation body")
        }
        return try VfsMutationBody.decode(body)
    }

    /// The full record bytes.
    public func encoded() -> Data {
        var data = Data(capacity: 8 + Int(length))
        data.appendBigEndian(length)
        data.appendBigEndian(crc32c)
        data.appendBigEndian(mseq)
        data.append(body)
        return data
    }

    /// Decodes one complete record and verifies its length and CRC32C.
    public static func decode(_ data: Data) throws -> WALRecord {
        guard data.count >= 8 else {
            throw WALError.truncated(expected: 8, actual: data.count)
        }
        guard let result = try decodePrefix(data) else {
            let expected = 8 + Int(data.readUInt32(at: 0))
            throw WALError.truncated(expected: expected, actual: data.count)
        }
        guard result.consumed == data.count else {
            throw WALError.recordLengthMismatch(
                expected: UInt32(result.consumed),
                actual: data.count
            )
        }
        return result.record
    }

    /// Decodes a record at the head of `data`; `nil` when the bytes are an
    /// incomplete record (a torn tail), so callers can stop cleanly.
    static func decodePrefix(_ data: Data) throws -> (record: WALRecord, consumed: Int)? {
        guard data.count >= 8 else { return nil }
        let length = data.readUInt32(at: 0)
        guard length >= 8 else {
            throw WALError.invalidRecord("len \(length) is smaller than mseq")
        }
        let total = 8 + Int(length)
        guard data.count >= total else { return nil }
        let storedCRC = data.readUInt32(at: 4)
        let payload = Data(
            data[data.index(data.startIndex, offsetBy: 8)..<data.index(data.startIndex, offsetBy: total)]
        )
        let computedCRC = CRC32C.checksum(payload)
        guard storedCRC == computedCRC else {
            throw WALError.recordCRCMismatch(expected: storedCRC, actual: computedCRC)
        }
        let mseq = data.readUInt64(at: 8)
        let body = Data(
            data[data.index(data.startIndex, offsetBy: 16)..<data.index(data.startIndex, offsetBy: total)]
        )
        let validatedBody = try validateBody(body, mseq: mseq)
        return (
            WALRecord(length: length, crc32c: storedCRC, mseq: mseq, body: validatedBody),
            total
        )
    }

    private static func validateBody(_ body: Data, mseq: UInt64) throws -> Data {
        if body.first == WireLimits.walEpochCloseOp {
            let close = try WALEpochClose.decode(body)
            guard mseq == close.durableUpto else {
                throw WALError.invalidEpochClose("mseq does not equal durable_upto")
            }
            return body
        }
        _ = try VfsMutationBody.decode(body)
        return body
    }
}

/// A parsed WAL segment: header followed by records until end of file.
public struct WALSegment: Equatable, Sendable {
    public let header: WALSegmentHeader
    public let records: [WALRecord]

    public init(header: WALSegmentHeader, records: [WALRecord]) throws {
        self.header = header
        self.records = records
        try validate()
    }

    /// The full segment file bytes.
    public func encoded() -> Data {
        var data = header.encoded()
        for record in records {
            data.append(record.encoded())
        }
        return data
    }

    /// Parses a complete segment file and verifies every record.
    public static func decode(_ data: Data) throws -> WALSegment {
        guard data.count >= WALSegmentHeader.byteCount else {
            throw WALError.truncated(expected: WALSegmentHeader.byteCount, actual: data.count)
        }
        let (header, consumed) = try WALSegmentHeader.decodePrefix(data)
        var records: [WALRecord] = []
        var offset = consumed
        while offset < data.count {
            let rest = Data(data[data.index(data.startIndex, offsetBy: offset)...])
            guard let result = try WALRecord.decodePrefix(rest) else {
                throw WALError.truncated(expected: data.count, actual: offset)
            }
            records.append(result.record)
            offset += result.consumed
        }
        return try WALSegment(header: header, records: records)
    }

    /// Ordering rules of wal.md §2–§4: mutations are consecutive from
    /// `first_mseq`, and at most one epoch-close record is the last record.
    public func validate() throws {
        var expectedMseq = header.firstMseq
        var sawEpochClose = false
        for record in records {
            if sawEpochClose {
                throw WALError.invalidSegment("record follows the epoch-close record")
            }
            if record.isEpochClose {
                _ = try record.epochClose()
                sawEpochClose = true
                continue
            }
            guard record.mseq == expectedMseq else {
                throw WALError.invalidSegment(
                    "mutation mseq \(record.mseq) does not continue \(expectedMseq)"
                )
            }
            guard expectedMseq < UInt64.max else {
                throw WALError.invalidSegment("mutation mseq overflows u64")
            }
            expectedMseq += 1
            _ = try record.mutationBody()
        }
    }
}

/// `mseq ‖ body`, the exact CRC32C input of a WAL record.
private enum CRCInput {
    static func make(mseq: UInt64, body: Data) -> Data {
        var data = Data(capacity: 8 + body.count)
        data.appendBigEndian(mseq)
        data.append(body)
        return data
    }
}
