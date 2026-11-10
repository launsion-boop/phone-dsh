// SPDX-License-Identifier: MIT
// phone-dsh — PhoneDSHBLE: the TonoLink board's voice turn on the ctrl service
// (spec/device/v1/tonolink-board.md §4.1; cases golden/tonolink-voice.json).
//
//   status notify  `ev wake n=<u32> up=<u32>`                       board heard 你好小智
//   cmd write      `<seq> listen <id>`                              record one turn
//   audio notify   `[seq u16 LE][flags][id & 0xFF][Opus 20 ms]`     one frame per packet
//   status notify  `ev listen_end n=<id> frames=<u32> reason=<r>`   the turn ended
import Foundation

public enum TonoLinkVoiceEvent: Equatable, Sendable {
    public enum Reason: String, Sendable {
        case vad, noSpeech = "no_speech", max, cancel, error
    }

    case wake(n: UInt32, upMs: UInt32)
    case listenEnd(n: UInt32, frames: UInt32, reason: Reason)

    /// A `status` line, or nil when it is not one of the two events (§4.1: ignored).
    public static func parse(_ line: String) -> TonoLinkVoiceEvent? {
        let tokens = line.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ")
        guard tokens.count >= 2, tokens[0] == "ev" else { return nil }
        var members: [Substring: Substring] = [:]
        for token in tokens.dropFirst(2) {
            guard let equals = token.firstIndex(of: "=") else { return nil }
            let key = token[..<equals]
            if members[key] == nil { members[key] = token[token.index(after: equals)...] }
        }
        switch tokens[1] {
        case "wake":
            guard let n = decimal(members["n"]), let up = decimal(members["up"]) else { return nil }
            return .wake(n: n, upMs: up)
        case "listen_end":
            guard let n = decimal(members["n"]), let frames = decimal(members["frames"]),
                  let raw = members["reason"], let reason = Reason(rawValue: String(raw)) else { return nil }
            return .listenEnd(n: n, frames: frames, reason: reason)
        default:
            return nil
        }
    }

    /// Plain decimal digits only: `+1`, `-1`, `0x1` and empty are rejected.
    static func decimal(_ value: Substring?) -> UInt32? {
        guard let value, !value.isEmpty, value.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return UInt32(value)
    }
}

/// One `audio` notification of the current turn.
public struct TonoLinkVoicePacket: Equatable, Sendable {
    public static let headerBytes = 4
    public static let opusMaxBytes = 160

    public var seq: UInt16
    public var first: Bool
    public var last: Bool
    /// The raw Opus frame, forwarded unchanged; empty only on a last packet.
    public var opus: Data

    /// Nil when the packet is malformed or belongs to another turn (§4.1: dropped).
    public static func parse(_ data: Data, turnID: UInt32) -> TonoLinkVoicePacket? {
        let bytes = [UInt8](data)
        guard bytes.count >= headerBytes, bytes.count <= headerBytes + opusMaxBytes,
              bytes[3] == UInt8(truncatingIfNeeded: turnID) else { return nil }
        let flags = bytes[2]
        let packet = TonoLinkVoicePacket(seq: UInt16(bytes[0]) | UInt16(bytes[1]) << 8,
                                         first: flags & 0x01 != 0, last: flags & 0x02 != 0,
                                         opus: Data(bytes[headerBytes...]))
        guard !packet.opus.isEmpty || packet.last else { return nil }
        return packet
    }
}

public enum TonoLinkVoiceCommand {
    /// `<seq> listen <id>`; id 0 would let the board number the turn, so it is not allowed here.
    public static func listen(seq: UInt16, id: UInt32) throws -> Data {
        guard id != 0 else { throw TonoLinkUSBOTAError("listen id must be 1…4294967295") }
        return try TonoLinkBLECommand.line("\(seq) listen \(id)")
    }
}

/// Counts what arrived in one turn, for diagnostics (`seq` gaps are counted, not filled).
public struct TonoLinkVoiceTally: Equatable, Sendable {
    public private(set) var packets = 0
    public private(set) var gaps = 0
    public private(set) var dropped = 0
    private var nextSeq: UInt16?

    public init() {}

    public mutating func record(_ packet: TonoLinkVoicePacket?) {
        guard let packet else { dropped += 1; return }
        if let expected = nextSeq, packet.seq != expected { gaps += 1 }
        nextSeq = packet.seq &+ 1
        packets += 1
    }
}
