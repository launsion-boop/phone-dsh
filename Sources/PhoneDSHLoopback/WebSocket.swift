// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — PhoneDSHLoopback: RFC 6455 WebSocket server.
//
// One binary WebSocket carries the ordered channel (spec/v1
// channel.md §1). This file owns the handshake accept value, the server-side
// frame codec (client masking required, fragmentation, ping/pong, close codes)
// and the 16 MiB message cap. It never fragments outbound channel messages.

import Foundation

/// One complete WebSocket data message.
public enum WebSocketMessage: Equatable, Sendable {
    case binary(Data)
    case text(String)
}

/// WebSocket-level failures. A protocol violation is answered with a close
/// frame before the connection is torn down.
public enum WebSocketError: Error, Equatable, Sendable {
    case protocolViolation(String)
    case messageTooLarge
    case invalidText
    case closed

    var closeCode: Int {
        switch self {
        case .protocolViolation: return 1002
        case .messageTooLarge: return 1009
        case .invalidText: return 1007
        case .closed: return 1000
        }
    }
}

/// RFC 6455 handshake helpers.
public enum WebSocketHandshake {
    static let magicGUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

    /// `Sec-WebSocket-Accept` for a client key.
    public static func acceptValue(for key: String) -> String {
        let digest = SHA1.digest(Data((key + magicGUID).utf8))
        return digest.base64EncodedString()
    }

    /// Whether the request headers describe an upgrade to this server.
    public static func isUpgrade(headers: [String: String]) -> Bool {
        guard let upgrade = headers["upgrade"]?.lowercased(), upgrade == "websocket" else {
            return false
        }
        guard let connection = headers["connection"]?.lowercased() else { return false }
        return connection.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            .contains("upgrade")
    }
}

/// Server side of one WebSocket connection.
public actor WebSocketConnection {
    /// Largest accepted or emitted message (PLAN W1-LOOPBACK: 16 MiB).
    public static let maxMessageBytes = 16 * 1024 * 1024

    private let channel: ConnectionChannel
    private var buffer = Data()
    private var fragmented: Data?
    private var fragmentedIsText = false
    private var closeSent = false
    private var finished = false

    init(channel: ConnectionChannel, initialBuffer: Data = Data()) {
        self.channel = channel
        self.buffer = initialBuffer
    }

    /// Receives the next data message; `nil` after a close handshake.
    public func receive() async throws -> WebSocketMessage? {
        if finished { return nil }
        do {
            while true {
                let frame = try await nextFrame()
                guard let frame else {
                    finished = true
                    return nil
                }
                switch frame.opcode {
                case 0x0:
                    guard let pending = fragmented else {
                        throw WebSocketError.protocolViolation("continuation without a message")
                    }
                    if pending.count + frame.payload.count > Self.maxMessageBytes {
                        try await failClose(.messageTooLarge)
                    }
                    fragmented?.append(frame.payload)
                    if frame.fin {
                        let data = fragmented ?? Data()
                        fragmented = nil
                        if fragmentedIsText {
                            guard let text = String(data: data, encoding: .utf8) else {
                                try await failClose(.invalidText)
                            }
                            return .text(text)
                        }
                        return .binary(data)
                    }
                case 0x1, 0x2:
                    guard fragmented == nil else {
                        throw WebSocketError.protocolViolation("new data frame inside fragmentation")
                    }
                    guard frame.payload.count <= Self.maxMessageBytes else {
                        try await failClose(.messageTooLarge)
                    }
                    if frame.fin {
                        if frame.opcode == 0x1 {
                            guard let text = String(data: frame.payload, encoding: .utf8) else {
                                try await failClose(.invalidText)
                            }
                            return .text(text)
                        }
                        return .binary(frame.payload)
                    }
                    fragmented = frame.payload
                    fragmentedIsText = frame.opcode == 0x1
                case 0x8:
                    let code = closeCode(from: frame.payload)
                    if !closeSent {
                        closeSent = true
                        try? await sendFrame(opcode: 0x8, payload: frame.payload)
                    }
                    finished = true
                    await channel.cancel()
                    _ = code
                    return nil
                case 0x9:
                    try? await sendFrame(opcode: 0xA, payload: frame.payload)
                case 0xA:
                    break
                default:
                    throw WebSocketError.protocolViolation("unknown opcode \(frame.opcode)")
                }
            }
        } catch let error as WebSocketError {
            if !closeSent {
                try? await failClose(error)
            } else {
                finished = true
                await channel.cancel()
            }
            throw error
        } catch {
            finished = true
            await channel.cancel()
            throw error
        }
    }

    /// Sends one binary message (one WebSocket data frame, never fragmented).
    public func send(binary data: Data) async throws {
        guard !finished, !closeSent else { throw WebSocketError.closed }
        guard data.count <= Self.maxMessageBytes else { throw WebSocketError.messageTooLarge }
        try await sendFrame(opcode: 0x2, payload: data)
    }

    /// Whether the codec still holds bytes of an inbound message that has not
    /// been delivered. A drain close may only report a clean end when this is
    /// false: closing with a fragmented message or a partial frame buffered
    /// would silently drop the rest of an accepted write.
    public func hasPendingInboundData() async -> Bool {
        fragmented != nil || !buffer.isEmpty
    }

    /// Sends one text message. The ordered channel itself treats inbound text
    /// as a protocol error; this exists for raw test handlers and probes.
    public func send(text: String) async throws {
        guard !finished, !closeSent else { throw WebSocketError.closed }
        let data = Data(text.utf8)
        guard data.count <= Self.maxMessageBytes else { throw WebSocketError.messageTooLarge }
        try await sendFrame(opcode: 0x1, payload: data)
    }

    /// Sends a ping control frame (the peer's pong is consumed by `receive`).
    public func ping(_ payload: Data = Data()) async throws {
        guard !finished, !closeSent else { throw WebSocketError.closed }
        guard payload.count <= 125 else {
            throw WebSocketError.protocolViolation("a ping payload is at most 125 bytes")
        }
        try await sendFrame(opcode: 0x9, payload: payload)
    }

    /// Closes the connection. Idempotent.
    public func close(code: Int = 1000, reason: String = "") async {
        guard !closeSent else { return }
        closeSent = true
        var payload = Data()
        payload.append(UInt8((code >> 8) & 0xFF))
        payload.append(UInt8(code & 0xFF))
        payload.append(Data(reason.utf8.prefix(123)))
        try? await sendFrame(opcode: 0x8, payload: payload)
        finished = true
        // Let the close frame reach the transport before cancelling.
        try? await Task.sleep(nanoseconds: 2_000_000)
        await channel.cancel()
    }

    /// Drops the connection without a close handshake.
    public func abort() async {
        finished = true
        await channel.cancel()
    }

    // MARK: - Frame codec

    private struct Frame {
        var fin: Bool
        var opcode: UInt8
        var payload: Data
    }

    private func nextFrame() async throws -> Frame? {
        while true {
            guard try await ensure(2) else { return nil }
            let first = buffer[buffer.startIndex]
            let second = buffer[buffer.index(after: buffer.startIndex)]
            let fin = first & 0x80 != 0
            guard first & 0x70 == 0 else {
                throw WebSocketError.protocolViolation("reserved bits are set")
            }
            let opcode = first & 0x0F
            let masked = second & 0x80 != 0
            var length = Int(second & 0x7F)
            var offset = 2
            if length == 126 {
                guard try await ensure(4) else { return nil }
                length = Int(readUInt16(at: buffer.startIndex + 2))
                offset = 4
            } else if length == 127 {
                guard try await ensure(10) else { return nil }
                let value = readUInt64(at: buffer.startIndex + 2)
                guard value <= UInt64(Self.maxMessageBytes) else {
                    throw WebSocketError.messageTooLarge
                }
                length = Int(value)
                offset = 10
            }
            guard masked else {
                throw WebSocketError.protocolViolation("client frames must be masked")
            }
            if opcode >= 0x8 {
                guard fin else {
                    throw WebSocketError.protocolViolation("control frames must not fragment")
                }
                guard length <= 125 else {
                    throw WebSocketError.protocolViolation("control frames are at most 125 bytes")
                }
            }
            if opcode <= 0x2, length > Self.maxMessageBytes {
                throw WebSocketError.messageTooLarge
            }
            guard try await ensure(offset + 4 + length) else { return nil }
            var mask = [UInt8]()
            mask.reserveCapacity(4)
            for index in 0..<4 {
                mask.append(buffer[buffer.startIndex + offset + index])
            }
            let payloadStart = buffer.startIndex + offset + 4
            var payload = Data(buffer[payloadStart..<(payloadStart + length)])
            if length > 0 {
                payload.withUnsafeMutableBytes { raw in
                    let bytes = raw.bindMemory(to: UInt8.self)
                    for index in 0..<bytes.count {
                        bytes[index] ^= mask[index % 4]
                    }
                }
            }
            buffer.removeSubrange(buffer.startIndex..<buffer.index(buffer.startIndex,
                                                                 offsetBy: offset + 4 + length))
            guard isKnownOpcode(opcode) else {
                throw WebSocketError.protocolViolation("unknown opcode \(opcode)")
            }
            return Frame(fin: fin, opcode: opcode, payload: payload)
        }
    }

    private func isKnownOpcode(_ opcode: UInt8) -> Bool {
        (0x0...0x2).contains(opcode) || (0x8...0xA).contains(opcode)
    }

    private func closeCode(from payload: Data) -> Int {
        guard payload.count >= 2 else { return 1005 }
        return (Int(payload[payload.startIndex]) << 8) | Int(payload[payload.index(after: payload.startIndex)])
    }

    private func failClose(_ error: WebSocketError) async throws -> Never {
        if !closeSent {
            closeSent = true
            var payload = Data()
            let code = error.closeCode
            payload.append(UInt8((code >> 8) & 0xFF))
            payload.append(UInt8(code & 0xFF))
            try? await sendFrame(opcode: 0x8, payload: payload)
        }
        finished = true
        try? await Task.sleep(nanoseconds: 2_000_000)
        await channel.cancel()
        throw error
    }

    private func sendFrame(opcode: UInt8, payload: Data) async throws {
        var frame = Data(capacity: payload.count + 10)
        frame.append(0x80 | opcode)
        let length = payload.count
        if length < 126 {
            frame.append(UInt8(length))
        } else if length <= 0xFFFF {
            frame.append(126)
            frame.append(UInt8((length >> 8) & 0xFF))
            frame.append(UInt8(length & 0xFF))
        } else {
            frame.append(127)
            var value = UInt64(length)
            for _ in 0..<8 {
                frame.append(UInt8(value & 0xFF))
                value >>= 8
            }
            // The loop above wrote little-endian; rewrite the eight bytes.
            let start = frame.count - 8
            value = UInt64(length)
            for index in (0..<8).reversed() {
                frame[frame.index(frame.startIndex, offsetBy: start + index)] = UInt8(value & 0xFF)
                value >>= 8
            }
        }
        frame.append(payload)
        try await channel.send(frame)
    }

    private func ensure(_ count: Int) async throws -> Bool {
        while buffer.count < count {
            let chunk = try await channel.receive()
            guard let chunk else { return false }
            if !chunk.isEmpty { buffer.append(chunk) }
        }
        return true
    }

    private func readUInt16(at offset: Data.Index) -> UInt16 {
        (UInt16(buffer[offset]) << 8) | UInt16(buffer[buffer.index(after: offset)])
    }

    private func readUInt64(at offset: Data.Index) -> UInt64 {
        var value: UInt64 = 0
        var index = offset
        for _ in 0..<8 {
            value = (value << 8) | UInt64(buffer[index])
            index = buffer.index(after: index)
        }
        return value
    }
}
