// SPDX-License-Identifier: MIT
// phone-dsh — PhoneDSHBLE: console, log paging and OTA for a TonoLink board
// over BLE alone (no Wi-Fi, no USB network). Wire format in
// `TonoLinkBLEDebugProtocol.swift`.
//
// OTA: `ota_begin` → stream `ota_data` keeping ≤ 8 KB beyond the last
// `ota at` → wait until the board reports every byte → `ota_end` (board checks
// the CRC, switches slots and reboots) → reconnect → `ota_confirm`.
import Foundation

public struct TonoLinkCtrlReply: Equatable, Sendable {
    public let ack: TonoLinkCtrlAck
    /// Every `<seq> …` line received before the ack, in order.
    public let lines: [TonoLinkCtrlLine]
    public init(ack: TonoLinkCtrlAck, lines: [TonoLinkCtrlLine]) { self.ack = ack; self.lines = lines }
}

@MainActor public protocol TonoLinkBLEDebugLink: TonoLinkCtrlLink {
    func request(_ line: Data, seq: UInt16, timeout: Duration) async throws -> TonoLinkCtrlReply
    /// Lines that answer no request (`ota at`, `ota err`, status).
    var onLine: ((TonoLinkCtrlLine) -> Void)? { get set }
    var otaWriteLimit: Int? { get }
    func writeOTA(_ packet: Data) async throws
}

public struct TonoLinkBLEOTAReport: Equatable, Sendable {
    public let bytes: Int
    public let transfer: Duration
    public let total: Duration
    public let resends: Int
    public let chunk: Int
    public var bytesPerSecond: Double {
        let seconds = Double(transfer.components.seconds) + Double(transfer.components.attoseconds) / 1e18
        return seconds > 0 ? Double(bytes) / seconds : 0
    }
}

@MainActor public final class TonoLinkBLEDebug {
    public struct Timing: Sendable {
        public var connect: Duration = .seconds(20)
        public var reconnect: Duration = .seconds(60)
        public var command: Duration = .seconds(10)
        public var otaEnd: Duration = .seconds(15)
        public var stall: Duration = .milliseconds(800)
        public var rebootSettle: Duration = .seconds(4)
        public var maxResends = 200
        public init() {}
    }

    private let link: TonoLinkBLEDebugLink
    private let clock: TonoLinkOTAClock
    private let timing: Timing
    private var seq: UInt16
    private var otaEvents: [TonoLinkCtrlLine] = []
    public var onEvent: ((TonoLinkOTAEvent) -> Void)?

    public init(link: TonoLinkBLEDebugLink, clock: TonoLinkOTAClock? = nil, timing: Timing = Timing(),
                firstSeq: UInt16 = UInt16.random(in: 1...50_000)) {
        self.link = link; self.clock = clock ?? SystemTonoLinkOTAClock(); self.timing = timing; self.seq = firstSeq
    }

    /// Runs one console command (`info`, `wifi`, `reboot`, …) and returns its output lines.
    public func console(_ command: String) async throws -> [String] {
        try await link.connect(timeout: timing.connect)
        let id = nextSeq()
        let reply = try await send(try TonoLinkBLECommand.console(seq: id, command), seq: id, what: "con")
        return reply.lines.compactMap { if case .out(_, let text) = $0 { return text } else { return nil } }
    }

    /// One page of the board log after `since`; continue with `page.last`.
    public func log(since: UInt32) async throws -> TonoLinkLogPage {
        try await link.connect(timeout: timing.connect)
        let id = nextSeq()
        let reply = try await send(try TonoLinkBLECommand.log(seq: id, since: since), seq: id, what: "log")
        var page = TonoLinkLogPage(lines: [], last: since)
        for line in reply.lines {
            switch line {
            case .log(_, let index, let text): page.lines.append((index, text))
            case .logEnd(_, let last): page.last = last
            default: break
            }
        }
        return page
    }

    /// Writes `image` to the other slot over BLE, reboots into it and confirms it.
    public func ota(image: TonoLinkFirmwareImage) async throws -> TonoLinkBLEOTAReport {
        let started = clock.now
        try await link.connect(timeout: timing.connect)
        guard let limit = link.otaWriteLimit else { throw TonoLinkUSBOTAError("Board has no BLE ota_data characteristic (firmware before GATT layout 4)") }
        var sender = try TonoLinkBLEOTASender(image: image.data, writeLimit: limit)
        otaEvents = []
        link.onLine = { [weak self] line in
            switch line {
            case .otaAt, .otaError: self?.otaEvents.append(line)
            default: break
            }
        }
        defer { link.onLine = nil }

        emit(.step("BLE OTA: \(image.data.count) bytes in \(sender.chunk)-byte packets"))
        let begin = nextSeq()
        _ = try await send(try TonoLinkBLECommand.otaBegin(seq: begin, size: image.data.count, crc32: image.crc32), seq: begin, what: "ota_begin")
        let transferStart = clock.now
        var lastProgress = clock.now
        var reported = 0
        do {
            while !sender.isComplete {
                for event in otaEvents {
                    switch event {
                    case .otaAt(let position): sender.board(at: Int(position))
                    case .otaError(let why): throw TonoLinkUSBOTAError("Board aborted the BLE OTA: \(why)")
                    default: break
                    }
                }
                otaEvents = []
                if sender.acked > reported {
                    reported = sender.acked; lastProgress = clock.now
                    emit(.uploadProgress(Double(sender.acked) / Double(sender.total)))
                }
                if let packet = sender.nextPacket() {
                    try await link.writeOTA(packet)
                    continue
                }
                if clock.now - lastProgress > timing.stall {
                    guard sender.resends < timing.maxResends else { throw TonoLinkUSBOTAError("BLE OTA stalled at \(sender.acked) bytes") }
                    sender.stalled(); lastProgress = clock.now
                }
                try await clock.sleep(for: .milliseconds(10))
            }
        } catch {
            let abort = nextSeq()
            _ = try? await link.request(try TonoLinkBLECommand.otaAbort(seq: abort), seq: abort, timeout: timing.command)
            throw error
        }
        let transfer = clock.now - transferStart
        emit(.step("Transferred in \(transfer); \(sender.resends) resends; finishing"))

        let end = nextSeq()
        _ = try await send(try TonoLinkBLECommand.otaEnd(seq: end), seq: end, what: "ota_end", timeout: timing.otaEnd)
        emit(.step("Board verified the image; rebooting"))
        link.disconnect()
        try await clock.sleep(for: timing.rebootSettle)
        try await link.connect(timeout: timing.reconnect)
        let confirm = nextSeq()
        _ = try await send(try TonoLinkBLECommand.otaConfirm(seq: confirm), seq: confirm, what: "ota_confirm")
        emit(.step("Confirmed over BLE"))
        return TonoLinkBLEOTAReport(bytes: image.data.count, transfer: transfer, total: clock.now - started,
                                    resends: sender.resends, chunk: sender.chunk)
    }

    public func disconnect() { link.disconnect() }

    private func send(_ line: Data, seq: UInt16, what: String, timeout: Duration? = nil) async throws -> TonoLinkCtrlReply {
        let reply = try await link.request(line, seq: seq, timeout: timeout ?? timing.command)
        guard reply.ack.ok else { throw TonoLinkUSBOTAError("BLE \(what) rejected: \(reply.ack.error ?? "?")") }
        return reply
    }

    private func nextSeq() -> UInt16 {
        seq = seq == UInt16.max ? 1 : seq + 1
        return seq
    }

    private func emit(_ event: TonoLinkOTAEvent) { onEvent?(event) }
}
