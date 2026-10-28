// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — PhoneDSHWire: binary channel payloads.
//
// PLAN §2.2 and spec/v1/channel.md §3. Binary payloads use network
// byte order. VFS mutation bodies are shared with the WAL (wal.md §3), which
// stores the same body without the leading mseq.

import Foundation

/// VFS mutation operations (channel.md §3.1).
public enum VfsOp: UInt8, CaseIterable, Codable, Sendable {
    case write = 1
    case mkdir = 2
    case remove = 3
    case chmod = 4
}

/// VFS mutation flags (channel.md §3.1): bit0 entryChanged, bit1 appended.
public struct VfsMutationFlags: OptionSet, Codable, Equatable, Sendable {
    public let rawValue: UInt8

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    public static let entryChanged = VfsMutationFlags(rawValue: 1 << 0)
    public static let appended = VfsMutationFlags(rawValue: 1 << 1)
    /// Bits 2–7 are reserved by the format and must be zero.
    public static let all: VfsMutationFlags = [.entryChanged, .appended]

    /// `true` when only defined bits are set.
    public var isWellFormed: Bool {
        rawValue & ~Self.all.rawValue == 0
    }
}

/// One VFS mutation without the host-allocated `mseq` (channel.md §3.1).
///
/// The wire frame prefixes this body with `mseq`; the WAL stores exactly this
/// body next to the record's `mseq`.
public struct VfsMutationBody: Equatable, Sendable {
    public var op: VfsOp
    /// Permission bits for write/mkdir/chmod; 0 for remove.
    public var mode: UInt32
    public var mflags: VfsMutationFlags
    /// Byte offset the appended suffix starts at; 0 unless `.appended` is set.
    public var appendFrom: UInt64
    /// Absolute path under `/dsh/home/` or `/dsh/workspace/`.
    public var path: String
    /// File bytes for a write; empty for mkdir/remove/chmod.
    public var data: Data

    public init(op: VfsOp, mode: UInt32, mflags: VfsMutationFlags = [],
                appendFrom: UInt64 = 0, path: String, data: Data = Data()) {
        self.op = op
        self.mode = mode
        self.mflags = mflags
        self.appendFrom = appendFrom
        self.path = path
        self.data = data
    }

    /// Structural validation from channel.md §8 and wal.md §3.
    public func validate() throws {
        guard WireValidation.isValidMutationPath(path) else {
            throw PhoneWireError(code: .badPath, message: "mutation path is outside the VFS sink")
        }
        guard mflags.isWellFormed else {
            throw PhoneWireError(code: .badPayload, message: "reserved mutation flags are set")
        }
        guard mode <= 0o7777 else {
            throw PhoneWireError(code: .badPayload, message: "mode exceeds 0o7777")
        }
        guard data.count <= WireLimits.maxMutationDataBytes else {
            throw PhoneWireError(
                code: .badPayload,
                message: "mutation data exceeds \(WireLimits.maxMutationDataBytes) bytes"
            )
        }
        switch op {
        case .write:
            if !mflags.contains(.appended) {
                guard appendFrom == 0 else {
                    throw PhoneWireError(
                        code: .badPayload,
                        message: "a complete write must have append_from = 0"
                    )
                }
            }
        case .mkdir, .chmod:
            guard mflags.isEmpty, appendFrom == 0 else {
                throw PhoneWireError(
                    code: .badPayload,
                    message: "\(op) carries no flags or offset"
                )
            }
            guard data.isEmpty else {
                throw PhoneWireError(code: .badPayload, message: "\(op) carries no data")
            }
        case .remove:
            guard mode == 0 else {
                throw PhoneWireError(code: .badPayload, message: "remove has mode 0")
            }
            guard mflags.isEmpty, appendFrom == 0 else {
                throw PhoneWireError(code: .badPayload, message: "remove carries no flags or offset")
            }
            guard data.isEmpty else {
                throw PhoneWireError(code: .badPayload, message: "remove carries no data")
            }
        }
    }

    /// Encodes the body of channel.md §3.1, without the leading `mseq`.
    public func encoded() throws -> Data {
        try validate()
        let pathBytes = Data(path.utf8)
        guard pathBytes.count <= WireLimits.maxPathBytes else {
            throw PhoneWireError(code: .badPath, message: "path exceeds u16 length")
        }
        guard data.count <= Int(UInt32.max) else {
            throw PhoneWireError(code: .badPayload, message: "mutation data exceeds u32")
        }
        var writer = ByteWriter()
        writer.writeUInt8(op.rawValue)
        writer.writeUInt32(mode)
        writer.writeUInt8(mflags.rawValue)
        writer.writeUInt64(appendFrom)
        writer.writeUInt16(UInt16(pathBytes.count))
        writer.writeData(pathBytes)
        writer.writeUInt32(UInt32(data.count))
        writer.writeData(data)
        return writer.data
    }

    /// Decodes a body of channel.md §3.1 (without the leading `mseq`).
    public static func decode(_ payload: Data) throws -> VfsMutationBody {
        var reader = ByteReader(data: payload)
        let opByte = try reader.readUInt8()
        guard let op = VfsOp(rawValue: opByte) else {
            throw PhoneWireError(code: .badPayload, message: "unknown VFS op \(opByte)")
        }
        let mode = try reader.readUInt32()
        let rawFlags = try reader.readUInt8()
        let appendFrom = try reader.readUInt64()
        let pathLength = Int(try reader.readUInt16())
        let path = try reader.readString(count: pathLength)
        let dataLength = Int(try reader.readUInt32())
        let data = try reader.readData(count: dataLength)
        try reader.requireEnd()
        let body = VfsMutationBody(
            op: op,
            mode: mode,
            mflags: VfsMutationFlags(rawValue: rawFlags),
            appendFrom: appendFrom,
            path: path,
            data: data
        )
        try body.validate()
        return body
    }
}

/// VFS_MUT payload helper: host-allocated `mseq` followed by the mutation body
/// (channel.md §3.1). The frame payload and the WAL record share the body; only
/// the channel payload carries this leading mseq.
public enum VfsMutationPayload {
    /// Encodes `mseq ‖ body`.
    public static func encode(mseq: UInt64, body: VfsMutationBody) throws -> Data {
        guard mseq >= 1 else {
            throw PhoneWireError(code: .badMseq, message: "mseq starts at 1")
        }
        var data = Data(capacity: 8 + 28 + body.path.utf8.count + body.data.count)
        data.appendBigEndian(mseq)
        data.append(try body.encoded())
        return data
    }

    /// Decodes `mseq ‖ body`.
    public static func decode(_ payload: Data) throws -> (mseq: UInt64, body: VfsMutationBody) {
        guard payload.count >= 8 else {
            throw PhoneWireError(code: .badPayload, message: "VFS_MUT payload is truncated")
        }
        let mseq = payload.readUInt64(at: 0)
        guard mseq >= 1 else {
            throw PhoneWireError(code: .badMseq, message: "mseq starts at 1")
        }
        let body = try VfsMutationBody.decode(Data(payload.dropFirst(8)))
        return (mseq, body)
    }
}

/// Acknowledgement level of WAL and journal writes (channel.md §3.2, §3.6).
public enum AckLevel: UInt8, CaseIterable, Codable, Sendable {
    /// The process wrote the bytes; a kill does not lose them.
    case write = 1
    /// The epoch closed with `F_FULLFSYNC` (D18).
    case epochFsync = 2
}

/// VFS_ACK payload (channel.md §3.2).
public struct VfsAckBody: Equatable, Sendable {
    public var level: AckLevel
    public var uptoMseq: UInt64

    public init(level: AckLevel, uptoMseq: UInt64) {
        self.level = level
        self.uptoMseq = uptoMseq
    }

    public func encoded() -> Data {
        var writer = ByteWriter()
        writer.writeUInt8(level.rawValue)
        writer.writeUInt64(uptoMseq)
        return writer.data
    }

    public static func decode(_ payload: Data) throws -> VfsAckBody {
        var reader = ByteReader(data: payload)
        let rawLevel = try reader.readUInt8()
        guard let level = AckLevel(rawValue: rawLevel) else {
            throw PhoneWireError(code: .badPayload, message: "invalid ack level \(rawLevel)")
        }
        let upto = try reader.readUInt64()
        try reader.requireEnd()
        return VfsAckBody(level: level, uptoMseq: upto)
    }
}

/// VFS_BARRIER payload (channel.md §3.3).
public struct VfsBarrierBody: Equatable, Sendable {
    public var wantLevel: AckLevel
    public var uptoMseq: UInt64

    public init(wantLevel: AckLevel, uptoMseq: UInt64) {
        self.wantLevel = wantLevel
        self.uptoMseq = uptoMseq
    }

    public func encoded() -> Data {
        var writer = ByteWriter()
        writer.writeUInt8(wantLevel.rawValue)
        writer.writeUInt64(uptoMseq)
        return writer.data
    }

    public static func decode(_ payload: Data) throws -> VfsBarrierBody {
        var reader = ByteReader(data: payload)
        let rawLevel = try reader.readUInt8()
        guard let level = AckLevel(rawValue: rawLevel) else {
            throw PhoneWireError(code: .badPayload, message: "invalid barrier level \(rawLevel)")
        }
        let upto = try reader.readUInt64()
        try reader.requireEnd()
        return VfsBarrierBody(wantLevel: level, uptoMseq: upto)
    }
}

/// VFS_RESYNC payload (channel.md §3.4).
public struct VfsResyncBody: Equatable, Sendable {
    public var path: String

    public init(path: String) {
        self.path = path
    }

    public func encoded() throws -> Data {
        guard WireValidation.isValidMutationPath(path) else {
            throw PhoneWireError(code: .badPath, message: "resync path is outside the VFS sink")
        }
        let pathBytes = Data(path.utf8)
        guard pathBytes.count <= WireLimits.maxPathBytes else {
            throw PhoneWireError(code: .badPath, message: "path exceeds u16 length")
        }
        var writer = ByteWriter()
        writer.writeUInt16(UInt16(pathBytes.count))
        writer.writeData(pathBytes)
        return writer.data
    }

    public static func decode(_ payload: Data) throws -> VfsResyncBody {
        var reader = ByteReader(data: payload)
        let path = try reader.readString(count: Int(try reader.readUInt16()))
        try reader.requireEnd()
        guard WireValidation.isValidMutationPath(path) else {
            throw PhoneWireError(code: .badPath, message: "resync path is outside the VFS sink")
        }
        return VfsResyncBody(path: path)
    }
}

/// JOURNAL payload (channel.md §3.5).
public struct JournalBody: Equatable, Sendable {
    public var jseq: UInt64
    public var sessionID: String
    public var record: Data

    public init(jseq: UInt64, sessionID: String, record: Data) {
        self.jseq = jseq
        self.sessionID = sessionID
        self.record = record
    }

    public func validate() throws {
        guard jseq >= 1 else {
            throw PhoneWireError(code: .badPayload, message: "journal jseq starts at 1")
        }
        guard WireValidation.isValidIdentifier(sessionID) else {
            throw PhoneWireError(code: .badPayload, message: "invalid journal session_id")
        }
        guard !record.isEmpty else {
            throw PhoneWireError(code: .badPayload, message: "journal record must not be empty")
        }
    }

    public func encoded() throws -> Data {
        try validate()
        let sessionBytes = Data(sessionID.utf8)
        guard sessionBytes.count <= WireLimits.maxPathBytes else {
            throw PhoneWireError(code: .badPayload, message: "session_id exceeds u16 length")
        }
        guard record.count <= Int(UInt32.max) else {
            throw PhoneWireError(code: .badPayload, message: "journal record exceeds u32")
        }
        var writer = ByteWriter()
        writer.writeUInt64(jseq)
        writer.writeUInt16(UInt16(sessionBytes.count))
        writer.writeData(sessionBytes)
        writer.writeData(record)
        return writer.data
    }

    public static func decode(_ payload: Data) throws -> JournalBody {
        var reader = ByteReader(data: payload)
        let jseq = try reader.readUInt64()
        let sessionID = try reader.readString(count: Int(try reader.readUInt16()))
        let record = try reader.readRest()
        let body = JournalBody(jseq: jseq, sessionID: sessionID, record: record)
        try body.validate()
        return body
    }
}

/// JOURNAL_ACK payload (channel.md §3.6).
public struct JournalAckBody: Equatable, Sendable {
    public var level: AckLevel
    public var sessionID: String
    public var uptoJseq: UInt64

    public init(level: AckLevel, sessionID: String, uptoJseq: UInt64) {
        self.level = level
        self.sessionID = sessionID
        self.uptoJseq = uptoJseq
    }

    public func validate() throws {
        guard WireValidation.isValidIdentifier(sessionID) else {
            throw PhoneWireError(code: .badPayload, message: "invalid journal session_id")
        }
    }

    public func encoded() throws -> Data {
        try validate()
        let sessionBytes = Data(sessionID.utf8)
        guard sessionBytes.count <= WireLimits.maxPathBytes else {
            throw PhoneWireError(code: .badPayload, message: "session_id exceeds u16 length")
        }
        var writer = ByteWriter()
        writer.writeUInt8(level.rawValue)
        writer.writeUInt16(UInt16(sessionBytes.count))
        writer.writeData(sessionBytes)
        writer.writeUInt64(uptoJseq)
        return writer.data
    }

    public static func decode(_ payload: Data) throws -> JournalAckBody {
        var reader = ByteReader(data: payload)
        let rawLevel = try reader.readUInt8()
        guard let level = AckLevel(rawValue: rawLevel) else {
            throw PhoneWireError(code: .badPayload, message: "invalid journal ack level \(rawLevel)")
        }
        let sessionID = try reader.readString(count: Int(try reader.readUInt16()))
        let upto = try reader.readUInt64()
        try reader.requireEnd()
        let body = JournalAckBody(level: level, sessionID: sessionID, uptoJseq: upto)
        try body.validate()
        return body
    }
}

/// API_REQ payload (channel.md §3.7): `req_id` + length-prefixed JSON head + body.
public struct ApiRequestFrame: Equatable, Sendable {
    public var reqID: UInt32
    public var head: ApiRequestHead
    public var body: Data

    public init(reqID: UInt32, head: ApiRequestHead, body: Data = Data()) {
        self.reqID = reqID
        self.head = head
        self.body = body
    }

    public func encoded() throws -> Data {
        try head.validate()
        guard body.count <= WireLimits.maxAPIBodyBytes else {
            throw PhoneWireError(
                code: .badPayload,
                message: "API_REQ body exceeds \(WireLimits.maxAPIBodyBytes) bytes"
            )
        }
        let headBytes = try CanonicalJSON.encode(head)
        guard headBytes.count <= Int(UInt32.max) else {
            throw PhoneWireError(code: .badPayload, message: "API_REQ head exceeds u32")
        }
        var writer = ByteWriter()
        writer.writeUInt32(reqID)
        writer.writeUInt32(UInt32(headBytes.count))
        writer.writeData(headBytes)
        writer.writeData(body)
        return writer.data
    }

    public static func decode(_ payload: Data) throws -> ApiRequestFrame {
        var reader = ByteReader(data: payload)
        let reqID = try reader.readUInt32()
        let headLength = Int(try reader.readUInt32())
        guard headLength > 0 else {
            throw PhoneWireError(code: .badPayload, message: "API_REQ head must not be empty")
        }
        let headBytes = try reader.readData(count: headLength)
        let head: ApiRequestHead
        do {
            head = try JSONDecoder().decode(ApiRequestHead.self, from: headBytes)
        } catch let error as PhoneWireError {
            throw error
        } catch {
            throw PhoneWireError(code: .badPayload, message: "invalid API_REQ head JSON")
        }
        let body = try reader.readRest()
        guard body.count <= WireLimits.maxAPIBodyBytes else {
            throw PhoneWireError(
                code: .badPayload,
                message: "API_REQ body exceeds \(WireLimits.maxAPIBodyBytes) bytes"
            )
        }
        let frame = ApiRequestFrame(reqID: reqID, head: head, body: body)
        try head.validate()
        return frame
    }
}

/// API_RES payload (channel.md §3.8): `req_id` + length-prefixed head + body.
///
/// `head` is `nil` for continuation chunks (`head_len = 0`).
public struct ApiResponseFrame: Equatable, Sendable {
    public var reqID: UInt32
    public var head: ApiResponseHead?
    public var body: Data

    public init(reqID: UInt32, head: ApiResponseHead?, body: Data = Data()) {
        self.reqID = reqID
        self.head = head
        self.body = body
    }

    public func encoded() throws -> Data {
        let headBytes: Data
        if let head {
            try head.validate()
            headBytes = try CanonicalJSON.encode(head)
        } else {
            headBytes = Data()
        }
        guard headBytes.count <= Int(UInt32.max) else {
            throw PhoneWireError(code: .badPayload, message: "API_RES head exceeds u32")
        }
        var writer = ByteWriter()
        writer.writeUInt32(reqID)
        writer.writeUInt32(UInt32(headBytes.count))
        writer.writeData(headBytes)
        writer.writeData(body)
        return writer.data
    }

    public static func decode(_ payload: Data) throws -> ApiResponseFrame {
        var reader = ByteReader(data: payload)
        let reqID = try reader.readUInt32()
        let headLength = Int(try reader.readUInt32())
        var head: ApiResponseHead?
        if headLength > 0 {
            let headBytes = try reader.readData(count: headLength)
            do {
                head = try JSONDecoder().decode(ApiResponseHead.self, from: headBytes)
            } catch let error as PhoneWireError {
                throw error
            } catch {
                throw PhoneWireError(code: .badPayload, message: "invalid API_RES head JSON")
            }
            try head?.validate()
        }
        let body = try reader.readRest()
        return ApiResponseFrame(reqID: reqID, head: head, body: body)
    }
}

/// API_END payload (channel.md §3.9): exactly one `req_id`.
public struct ApiEndFrame: Equatable, Sendable {
    public var reqID: UInt32

    public init(reqID: UInt32) {
        self.reqID = reqID
    }

    public func encoded() -> Data {
        var data = Data(capacity: 4)
        data.appendBigEndian(reqID)
        return data
    }

    public static func decode(_ payload: Data) throws -> ApiEndFrame {
        var reader = ByteReader(data: payload)
        let reqID = try reader.readUInt32()
        try reader.requireEnd()
        return ApiEndFrame(reqID: reqID)
    }
}

/// API_ABORT payload (channel.md §3.10): `req_id` + canonical `{"reason":...}`.
public struct ApiAbortFrame: Equatable, Sendable {
    public var reqID: UInt32
    public var reason: String

    public init(reqID: UInt32, reason: String) {
        self.reqID = reqID
        self.reason = reason
    }

    public func encoded() throws -> Data {
        let reasonBytes = try CanonicalJSON.encode(AbortReasonPayload(reason: reason))
        var writer = ByteWriter()
        writer.writeUInt32(reqID)
        writer.writeData(reasonBytes)
        return writer.data
    }

    public static func decode(_ payload: Data) throws -> ApiAbortFrame {
        var reader = ByteReader(data: payload)
        let reqID = try reader.readUInt32()
        let reasonBytes = try reader.readRest()
        let object: AbortReasonPayload
        do {
            object = try JSONDecoder().decode(AbortReasonPayload.self, from: reasonBytes)
        } catch {
            throw PhoneWireError(code: .badPayload, message: "invalid API_ABORT reason JSON")
        }
        return ApiAbortFrame(reqID: reqID, reason: object.reason)
    }
}

private struct AbortReasonPayload: Codable, Equatable, Sendable {
    var reason: String
}

// MARK: - Byte cursors

/// Big-endian writer used by every binary encoder in this module.
struct ByteWriter {
    private(set) var data = Data()

    mutating func writeUInt8(_ value: UInt8) {
        data.append(value)
    }

    mutating func writeUInt16(_ value: UInt16) {
        data.appendBigEndian(value)
    }

    mutating func writeUInt32(_ value: UInt32) {
        data.appendBigEndian(value)
    }

    mutating func writeUInt64(_ value: UInt64) {
        data.appendBigEndian(value)
    }

    mutating func writeData(_ bytes: Data) {
        data.append(bytes)
    }
}

/// Bounds-checked big-endian reader; every failure is BAD_PAYLOAD.
struct ByteReader {
    private let data: Data
    private var offset = 0

    init(data: Data) {
        self.data = data
    }

    var remaining: Int { data.count - offset }

    mutating func readUInt8() throws -> UInt8 {
        try require(1)
        defer { offset += 1 }
        return data[data.index(data.startIndex, offsetBy: offset)]
    }

    mutating func readUInt16() throws -> UInt16 {
        try require(2)
        defer { offset += 2 }
        return data.readUInt16(at: offset)
    }

    mutating func readUInt32() throws -> UInt32 {
        try require(4)
        defer { offset += 4 }
        return data.readUInt32(at: offset)
    }

    mutating func readUInt64() throws -> UInt64 {
        try require(8)
        defer { offset += 8 }
        return data.readUInt64(at: offset)
    }

    mutating func readData(count: Int) throws -> Data {
        guard count >= 0 else {
            throw PhoneWireError(code: .badPayload, message: "negative binary length")
        }
        try require(count)
        let start = data.index(data.startIndex, offsetBy: offset)
        let end = data.index(start, offsetBy: count)
        offset += count
        return Data(data[start..<end])
    }

    mutating func readString(count: Int) throws -> String {
        let bytes = try readData(count: count)
        guard let string = String(data: bytes, encoding: .utf8) else {
            throw PhoneWireError(code: .badPayload, message: "payload is not valid UTF-8")
        }
        return string
    }

    mutating func readRest() throws -> Data {
        try readData(count: remaining)
    }

    func requireEnd() throws {
        guard remaining == 0 else {
            throw PhoneWireError(
                code: .badPayload,
                message: "payload has \(remaining) trailing bytes"
            )
        }
    }

    private func require(_ count: Int) throws {
        guard remaining >= count else {
            throw PhoneWireError(
                code: .badPayload,
                message: "payload truncated: need \(count), have \(remaining)"
            )
        }
    }
}
