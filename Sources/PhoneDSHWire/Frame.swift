// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — PhoneDSHWire: ordered-channel frames.
//
// PLAN §2.2 (D1/D5) and spec/v1/channel.md §1, §2 and §7. One binary
// WebSocket carries all frame types; this file provides the 16-byte header, the
// streaming decoder that works on arbitrary byte slices, and the encoder.

import Foundation

/// Frame types of phone-dsh-v1 (channel.md §2).
public enum FrameType: UInt8, CaseIterable, Codable, Sendable {
    case hello = 0x01
    case vfsMutation = 0x10
    case vfsAck = 0x11
    case vfsBarrier = 0x12
    case vfsResync = 0x13
    case execRequest = 0x20
    case execEvent = 0x21
    case execControl = 0x22
    case journal = 0x30
    case journalAck = 0x31
    case apiRequest = 0x40
    case apiResponse = 0x41
    case apiEnd = 0x42
    case apiAbort = 0x43
    case lifecycle = 0x50
    case console = 0x60
    case fence = 0x70
    case error = 0x7F

    /// The normative name from the channel.md §2 table.
    public var wireName: String {
        switch self {
        case .hello: return "HELLO"
        case .vfsMutation: return "VFS_MUT"
        case .vfsAck: return "VFS_ACK"
        case .vfsBarrier: return "VFS_BARRIER"
        case .vfsResync: return "VFS_RESYNC"
        case .execRequest: return "EXEC_REQ"
        case .execEvent: return "EXEC_EVT"
        case .execControl: return "EXEC_CTL"
        case .journal: return "JOURNAL"
        case .journalAck: return "JOURNAL_ACK"
        case .apiRequest: return "API_REQ"
        case .apiResponse: return "API_RES"
        case .apiEnd: return "API_END"
        case .apiAbort: return "API_ABORT"
        case .lifecycle: return "LIFECYCLE"
        case .console: return "CONSOLE"
        case .fence: return "FENCE"
        case .error: return "ERROR"
        }
    }

    /// Whether the payload is canonical JSON rather than a binary body.
    public var carriesJSONPayload: Bool {
        switch self {
        case .hello, .execRequest, .execEvent, .execControl,
             .lifecycle, .console, .fence, .error:
            return true
        default:
            return false
        }
    }

    /// Resolves a frame name from the channel.md §2 table.
    public init?(wireName: String) {
        guard let match = Self.allCases.first(where: { $0.wireName == wireName }) else {
            return nil
        }
        self = match
    }
}

/// One decoded frame: type byte, connection-local sequence number, payload.
public struct Frame: Equatable, Sendable {
    public var type: FrameType
    public var seq: UInt64
    public var payload: Data

    public init(type: FrameType, seq: UInt64, payload: Data) {
        self.type = type
        self.seq = seq
        self.payload = payload
    }
}

/// Encodes frames with the fixed 16-byte header of channel.md §1.
public enum FrameEncoder {
    /// Encodes one complete frame.
    ///
    /// - Throws: `PhoneWireError(.badPayload)` for an empty or oversized
    ///   payload, and `PhoneWireError(.badSeq)` for `seq = 0`.
    public static func encode(_ frame: Frame) throws -> Data {
        try encode(type: frame.type, seq: frame.seq, payload: frame.payload)
    }

    /// Encodes one frame from its parts.
    public static func encode(type: FrameType, seq: UInt64, payload: Data) throws -> Data {
        let header = try header(type: type, seq: seq, payloadLength: payload.count)
        var data = header
        data.append(payload)
        return data
    }

    /// Encodes only the 16-byte header; exposed for framing tests and for
    /// transports that write the header before the body.
    public static func header(type: FrameType, seq: UInt64, payloadLength: Int) throws -> Data {
        guard seq >= 1 else {
            throw PhoneWireError(code: .badSeq, message: "frame seq starts at 1")
        }
        guard payloadLength >= 1 else {
            throw PhoneWireError(code: .badPayload, message: "frame payload must not be empty")
        }
        guard payloadLength <= WireLimits.maxFramePayloadBytes else {
            throw PhoneWireError(
                code: .badPayload,
                message: "frame payload exceeds \(WireLimits.maxFramePayloadBytes) bytes"
            )
        }
        var data = Data(capacity: WireLimits.headerBytes)
        data.append(UInt8((WireLimits.magic >> 8) & 0xFF))
        data.append(UInt8(WireLimits.magic & 0xFF))
        data.append(type.rawValue)
        data.append(0) // flags
        data.appendBigEndian(seq)
        data.appendBigEndian(UInt32(payloadLength))
        return data
    }
}

/// Streaming frame decoder.
///
/// Feed it arbitrary slices (a byte at a time, sticky packets or random
/// chunks); it buffers a partial header or payload and emits only complete
/// frames. A bad header is terminal for the connection. `seq` monotonicity is
/// optional because golden vectors are independent examples, not one stream;
/// the channel layer enables it for a live connection.
public struct FrameDecoder: Sendable {
    /// Decoder options.
    public struct Configuration: Equatable, Sendable {
        /// Enforce the per-direction sequence rule of channel.md §7: the first
        /// frame is 1 and every later frame is previous + 1. Defaults to off,
        /// because a standalone golden vector starts at an arbitrary seq.
        public var enforceMonotonicSequence: Bool

        public init(enforceMonotonicSequence: Bool = false) {
            self.enforceMonotonicSequence = enforceMonotonicSequence
        }
    }

    private var buffer = Data()
    private var expectedSequence: UInt64?
    private let configuration: Configuration

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    /// Bytes retained for the next `feed`.
    public var bufferedByteCount: Int { buffer.count }

    /// Discards buffered bytes; sequence expectations are kept.
    public mutating func resetBuffer() {
        buffer.removeAll(keepingCapacity: false)
    }

    /// Appends bytes and returns every frame that is now complete, in order.
    ///
    /// - Throws: `PhoneWireError(.badMagic)` for a wrong magic and
    ///   `PhoneWireError(.badPayload)` for a non-zero flags byte, `len = 0`,
    ///   `len` above 16 MiB or an unknown type byte. With sequence enforcement
    ///   on, `PhoneWireError(.badSeq)` for a non-monotonic `seq`.
    public mutating func feed(_ bytes: Data) throws -> [Frame] {
        buffer.append(bytes)
        return try drain()
    }

    /// Convenience overload for callers that already hold a byte array.
    public mutating func feed(_ bytes: [UInt8]) throws -> [Frame] {
        try feed(Data(bytes))
    }

    private mutating func drain() throws -> [Frame] {
        var frames: [Frame] = []
        while buffer.count >= WireLimits.headerBytes {
            let magic = buffer.readUInt16(at: 0)
            guard magic == WireLimits.magic else {
                buffer.removeAll(keepingCapacity: false)
                throw PhoneWireError(code: .badMagic, message: "frame magic is not 0x5A4C")
            }
            let typeByte = buffer.readUInt8(at: 2)
            guard let type = FrameType(rawValue: typeByte) else {
                buffer.removeAll(keepingCapacity: false)
                throw PhoneWireError(
                    code: .badPayload,
                    message: "unknown frame type byte \(typeByte)"
                )
            }
            let flags = buffer.readUInt8(at: 3)
            guard flags == 0 else {
                buffer.removeAll(keepingCapacity: false)
                throw PhoneWireError(
                    code: .badPayload,
                    message: "frame flags must be zero, got \(flags)"
                )
            }
            let seq = buffer.readUInt64(at: 4)
            let length = Int(buffer.readUInt32(at: 12))
            guard length >= 1 else {
                buffer.removeAll(keepingCapacity: false)
                throw PhoneWireError(code: .badPayload, message: "frame payload must not be empty")
            }
            guard length <= WireLimits.maxFramePayloadBytes else {
                buffer.removeAll(keepingCapacity: false)
                throw PhoneWireError(
                    code: .badPayload,
                    message: "frame payload exceeds \(WireLimits.maxFramePayloadBytes) bytes"
                )
            }
            let total = WireLimits.headerBytes + length
            guard buffer.count >= total else { break }

            if configuration.enforceMonotonicSequence {
                let expected = expectedSequence ?? 1
                guard seq == expected else {
                    buffer.removeAll(keepingCapacity: false)
                    throw PhoneWireError(
                        code: .badSeq,
                        message: "expected seq \(expected), got \(seq)",
                        refSeq: seq
                    )
                }
                if seq == UInt64.max {
                    expectedSequence = nil
                } else {
                    expectedSequence = seq + 1
                }
            }

            let payloadStart = buffer.index(buffer.startIndex, offsetBy: WireLimits.headerBytes)
            let payloadEnd = buffer.index(payloadStart, offsetBy: length)
            let payload = Data(buffer[payloadStart..<payloadEnd])
            buffer = Data(buffer[payloadEnd...])
            frames.append(Frame(type: type, seq: seq, payload: payload))
        }
        return frames
    }
}

extension Data {
    /// Appends a big-endian unsigned integer; used by every binary codec.
    mutating func appendBigEndian(_ value: UInt16) {
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8(value & 0xFF))
    }

    mutating func appendBigEndian(_ value: UInt32) {
        append(UInt8((value >> 24) & 0xFF))
        append(UInt8((value >> 16) & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8(value & 0xFF))
    }

    mutating func appendBigEndian(_ value: UInt64) {
        append(UInt8((value >> 56) & 0xFF))
        append(UInt8((value >> 48) & 0xFF))
        append(UInt8((value >> 40) & 0xFF))
        append(UInt8((value >> 32) & 0xFF))
        append(UInt8((value >> 24) & 0xFF))
        append(UInt8((value >> 16) & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8(value & 0xFF))
    }

    func readUInt8(at offset: Int) -> UInt8 {
        self[index(startIndex, offsetBy: offset)]
    }

    func readUInt16(at offset: Int) -> UInt16 {
        (UInt16(readUInt8(at: offset)) << 8) | UInt16(readUInt8(at: offset + 1))
    }

    func readUInt32(at offset: Int) -> UInt32 {
        (UInt32(readUInt8(at: offset)) << 24) |
            (UInt32(readUInt8(at: offset + 1)) << 16) |
            (UInt32(readUInt8(at: offset + 2)) << 8) |
            UInt32(readUInt8(at: offset + 3))
    }

    func readUInt64(at offset: Int) -> UInt64 {
        (UInt64(readUInt8(at: offset)) << 56) |
            (UInt64(readUInt8(at: offset + 1)) << 48) |
            (UInt64(readUInt8(at: offset + 2)) << 40) |
            (UInt64(readUInt8(at: offset + 3)) << 32) |
            (UInt64(readUInt8(at: offset + 4)) << 24) |
            (UInt64(readUInt8(at: offset + 5)) << 16) |
            (UInt64(readUInt8(at: offset + 6)) << 8) |
            UInt64(readUInt8(at: offset + 7))
    }
}
