// SPDX-License-Identifier: MIT
// phone-dsh — PhoneDSHBLE: wire pieces for debugging and updating a TonoLink
// board over its paired BLE ctrl service (tonolink `agent/venus-demo` 6bb4df8,
// `main/ble_debug.c`), so it works wherever the board is plugged in.
//
// Lines go to `cmd` (write), replies come back as `status` notifications:
//   `<seq> con <console cmd>` → `<seq> out <text>` × N, then `ack <seq> ok|err …`
//   `<seq> log <since>`       → `<seq> log <n> <text>` × N, `<seq> logend <last>`, ack
//   `<seq> ota_begin <size> <crc32 8hex>` / `ota_end` / `ota_abort` / `ota_confirm` → ack
// Image bytes go to `ota_data` (write without response) as `offset u32le | 1…240
// bytes`. The board notifies `ota at <written>` about every 4 KB and when it
// sees a gap; `ota err <why>` aborts. At most 8 KB may be in flight.
import Foundation

public enum TonoLinkBLEDebugService {
    /// `ota_data`, GATT layout 4. Shares the 7A1C9E52 UUID family with audio/call.
    public static let otaData = "7A1C9E52-3B6D-4F08-9C2E-5D4B8A61F0A5"
    public static let lineMax = 200
}

/// One `status` notification, classified.
public enum TonoLinkCtrlLine: Equatable, Sendable {
    case ack(TonoLinkCtrlAck)
    case out(seq: UInt16, text: String)
    case log(seq: UInt16, index: UInt32, text: String)
    case logEnd(seq: UInt16, last: UInt32)
    case otaAt(UInt32)
    case otaError(String)
    case other(String)

    public static func parse(_ data: Data) -> TonoLinkCtrlLine {
        let text = String(decoding: data, as: UTF8.self)
        if let ack = TonoLinkCtrlAck.parse(data) { return .ack(ack) }
        if text.hasPrefix("ota at "), let value = UInt32(text.dropFirst(7).trimmingCharacters(in: .whitespacesAndNewlines)) { return .otaAt(value) }
        if text.hasPrefix("ota err ") { return .otaError(String(text.dropFirst(8)).trimmingCharacters(in: .whitespacesAndNewlines)) }
        // `<seq> <tag> <rest>`; the rest keeps its spaces (console output is free text).
        let head = text.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false)
        guard head.count >= 2, let seq = UInt16(head[0]) else { return .other(text) }
        let rest = head.count == 3 ? String(head[2]) : ""
        switch head[1] {
        case "out": return .out(seq: seq, text: rest)
        case "logend": return UInt32(rest).map { .logEnd(seq: seq, last: $0) } ?? .other(text)
        case "log":
            let parts = rest.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
            guard let index = parts.first.flatMap({ UInt32($0) }) else { return .other(text) }
            return .log(seq: seq, index: index, text: parts.count == 2 ? String(parts[1]) : "")
        default: return .other(text)
        }
    }

    /// The request this line answers, if any.
    public var seq: UInt16? {
        switch self {
        case .ack(let ack): return ack.seq
        case .out(let seq, _), .log(let seq, _, _), .logEnd(let seq, _): return seq
        default: return nil
        }
    }
}

public enum TonoLinkBLECommand {
    public static func console(seq: UInt16, _ command: String) throws -> Data {
        let command = command.trimmingCharacters(in: .whitespaces)
        guard !command.isEmpty, !command.contains(where: \.isNewline) else { throw TonoLinkUSBOTAError("console command must be one non-empty line") }
        return try line("\(seq) con \(command)")
    }
    public static func log(seq: UInt16, since: UInt32) throws -> Data { try line("\(seq) log \(since)") }
    public static func otaBegin(seq: UInt16, size: Int, crc32: UInt32) throws -> Data {
        try line("\(seq) ota_begin \(size) \(TonoLinkCRC32.header(crc32))")
    }
    public static func otaEnd(seq: UInt16) throws -> Data { try line("\(seq) ota_end") }
    public static func otaAbort(seq: UInt16) throws -> Data { try line("\(seq) ota_abort") }
    public static func otaConfirm(seq: UInt16) throws -> Data { try line("\(seq) ota_confirm") }

    static func line(_ text: String) throws -> Data {
        guard text.utf8.count <= TonoLinkBLEDebugService.lineMax else { throw TonoLinkUSBOTAError("BLE line longer than \(TonoLinkBLEDebugService.lineMax) bytes") }
        return Data(text.utf8)
    }
}

public struct TonoLinkLogPage: Equatable, Sendable {
    public var lines: [(index: UInt32, text: String)]
    /// Pass as `since` for the next page.
    public var last: UInt32
    public static func == (a: Self, b: Self) -> Bool {
        a.last == b.last && a.lines.map(\.index) == b.lines.map(\.index) && a.lines.map(\.text) == b.lines.map(\.text)
    }
}

/// Sender side of the BLE OTA flow control. Packets always start at multiples
/// of `chunk`, so a resend from any reported position lines up with what the
/// board has received (its position is always a packet boundary).
public struct TonoLinkBLEOTASender: Sendable {
    public static let headerSize = 4
    public static let maxChunk = 240
    public static let window = 8 * 1024

    public let image: Data
    public let chunk: Int
    /// Highest byte count the board reported (`ota at`).
    public private(set) var acked = 0
    /// Next offset to send.
    public private(set) var next = 0
    public private(set) var resends = 0

    /// `writeLimit` is CoreBluetooth's maximum write-without-response length.
    public init(image: Data, writeLimit: Int) throws {
        let chunk = min(Self.maxChunk, writeLimit - Self.headerSize)
        guard chunk >= 16 else { throw TonoLinkUSBOTAError("BLE write limit \(writeLimit) too small for OTA") }
        self.image = image; self.chunk = chunk
    }

    public var total: Int { image.count }
    public var isComplete: Bool { acked >= total }
    public var inFlight: Int { next - acked }

    /// The next packet if the window allows one.
    public mutating func nextPacket() -> Data? {
        guard next < total, next + min(chunk, total - next) - acked <= Self.window else { return nil }
        let end = min(next + chunk, total)
        var packet = withUnsafeBytes(of: UInt32(next).littleEndian) { Data($0) }
        packet.append(image[image.startIndex + next ..< image.startIndex + end])
        next = end
        return packet
    }

    /// `ota at <position>`. Progress and gap reports look the same; a gap
    /// shows up as no further progress, which `stalled()` recovers from.
    public mutating func board(at position: Int) {
        if position <= total, position > acked { acked = position }
    }

    /// No progress for a while: resend everything not yet acknowledged. The
    /// board ignores packets it already has, so this is always safe.
    public mutating func stalled() { if next > acked { rewind(to: acked - acked % chunk) } }

    private mutating func rewind(to position: Int) { next = position; resends += 1 }
}
