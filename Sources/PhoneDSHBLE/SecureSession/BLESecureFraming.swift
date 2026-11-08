// SPDX-License-Identifier: MIT
// §7.1 framing inside the TLS application-data stream: u16 little-endian
// length (1...4096) followed by the payload. Record and SDU boundaries carry
// no meaning.
import Foundation

public enum BLESecureFrameError: String, Error, Equatable, Sendable {
    /// Length 0 or > 4096, known as soon as both length bytes arrive.
    case limit
    /// Bytes left over at close_notify, EOF or disconnect.
    case truncated
}

/// Buffers at most one incomplete frame (≤ 4098 bytes) and never delivers a
/// payload twice. After an error it stays failed and delivers nothing more.
public struct BLESecureFrameDecoder: Sendable {
    public static let maxPayload = 4096
    private var buffer: [UInt8] = []
    public private(set) var error: BLESecureFrameError?

    public init() {}

    /// Feeds one chunk. Returns the payloads completed before any error in
    /// stream order, and the error if this chunk produced one.
    public mutating func push(_ chunk: [UInt8]) -> (payloads: [[UInt8]], error: BLESecureFrameError?) {
        guard error == nil else { return ([], error) }
        var out: [[UInt8]] = []
        var offset = 0
        while offset < chunk.count {
            if buffer.count < 2 {
                buffer.append(chunk[offset]); offset += 1
                if buffer.count == 2, !(1...Self.maxPayload).contains(Self.length(buffer)) {
                    buffer = []; error = .limit
                    return (out, .limit)
                }
                continue
            }
            let size = Self.length(buffer)
            let take = min(size + 2 - buffer.count, chunk.count - offset)
            buffer.append(contentsOf: chunk[offset..<offset + take]); offset += take
            if buffer.count == size + 2 {
                out.append(Array(buffer[2...])); buffer.removeAll(keepingCapacity: true)
            }
        }
        return (out, nil)
    }

    /// Stream end. A buffered partial frame is `truncated` and discarded.
    public mutating func finish() -> BLESecureFrameError? {
        if let error { return error }
        guard buffer.isEmpty else { buffer = []; error = .truncated; return .truncated }
        return nil
    }

    private static func length(_ b: [UInt8]) -> Int { Int(b[0]) | Int(b[1]) << 8 }
}

public enum BLESecureFrameEncoder {
    public static func frame(_ payload: [UInt8]) throws -> [UInt8] {
        guard (1...BLESecureFrameDecoder.maxPayload).contains(payload.count) else { throw BLESecureFrameError.limit }
        return [UInt8(payload.count & 0xff), UInt8(payload.count >> 8)] + payload
    }
}
