// SPDX-License-Identifier: MIT
import XCTest
@testable import PhoneDSHBLE

final class TonoLinkBLEDebugProtocolTests: XCTestCase {
    func testParsesEveryLineKind() {
        func parse(_ text: String) -> TonoLinkCtrlLine { .parse(Data(text.utf8)) }
        XCTAssertEqual(parse("ack 9 ok"), .ack(TonoLinkCtrlAck(seq: 9, error: nil)))
        XCTAssertEqual(parse("9 out fw 0.1.0-m21  slot ota_0"), .out(seq: 9, text: "fw 0.1.0-m21  slot ota_0"))
        XCTAssertEqual(parse("9 out "), .out(seq: 9, text: ""))
        XCTAssertEqual(parse("9 log 3201 I (256324) hid: subscribe kbd=1"), .log(seq: 9, index: 3201, text: "I (256324) hid: subscribe kbd=1"))
        XCTAssertEqual(parse("9 logend 3255"), .logEnd(seq: 9, last: 3255))
        XCTAssertEqual(parse("ota at 12288"), .otaAt(12288))
        XCTAssertEqual(parse("ota err crc"), .otaError("crc"))
        XCTAssertEqual(parse("st bat=90 hid=1"), .other("st bat=90 hid=1"))
        XCTAssertEqual(parse("9 logend x"), .other("9 logend x"))
        XCTAssertEqual(parse("9 out x").seq, 9)
        XCTAssertNil(parse("ota at 5").seq)
    }

    func testCommands() throws {
        XCTAssertEqual(try TonoLinkBLECommand.console(seq: 3, " info "), Data("3 con info".utf8))
        XCTAssertEqual(try TonoLinkBLECommand.log(seq: 3, since: 77), Data("3 log 77".utf8))
        XCTAssertEqual(try TonoLinkBLECommand.otaBegin(seq: 3, size: 1000, crc32: 0xab), Data("3 ota_begin 1000 000000ab".utf8))
        XCTAssertEqual(try TonoLinkBLECommand.otaEnd(seq: 3), Data("3 ota_end".utf8))
        XCTAssertEqual(try TonoLinkBLECommand.otaConfirm(seq: 3), Data("3 ota_confirm".utf8))
        XCTAssertThrowsError(try TonoLinkBLECommand.console(seq: 3, ""))
        XCTAssertThrowsError(try TonoLinkBLECommand.console(seq: 3, "a\nb"))
        XCTAssertThrowsError(try TonoLinkBLECommand.console(seq: 3, String(repeating: "x", count: 200)))
    }

    func testSenderPacketsWindowAndResend() throws {
        let image = Data((0..<20_000).map { UInt8($0 & 0xff) })
        var sender = try TonoLinkBLEOTASender(image: image, writeLimit: 182)
        XCTAssertEqual(sender.chunk, 178)
        XCTAssertEqual(try TonoLinkBLEOTASender(image: image, writeLimit: 512).chunk, 240)
        XCTAssertThrowsError(try TonoLinkBLEOTASender(image: image, writeLimit: 10))

        let first = try XCTUnwrap(sender.nextPacket())
        XCTAssertEqual(Array(first.prefix(4)), [0, 0, 0, 0])
        XCTAssertEqual(first.dropFirst(4), image.prefix(178))
        let second = try XCTUnwrap(sender.nextPacket())
        XCTAssertEqual(Array(second.prefix(4)), [178, 0, 0, 0])

        while sender.nextPacket() != nil {}
        XCTAssertLessThanOrEqual(sender.inFlight, TonoLinkBLEOTASender.window)
        XCTAssertGreaterThan(sender.inFlight, TonoLinkBLEOTASender.window - 178)

        sender.board(at: 4096)
        XCTAssertEqual(sender.acked, 4096)
        XCTAssertNotNil(sender.nextPacket(), "progress opens the window")
        sender.board(at: 100)   // stale report never moves backwards
        XCTAssertEqual(sender.acked, 4096)

        sender.stalled()
        XCTAssertEqual(sender.next, 4096 - 4096 % 178, "resend restarts on a packet boundary at or before the ack")
        XCTAssertEqual(sender.resends, 1)

        sender.board(at: image.count)
        XCTAssertTrue(sender.isComplete)
    }
}

// MARK: - Simulated board (ble_debug.c semantics)

@MainActor final class SimBLEBoard: TonoLinkBLEDebugLink {
    var onLine: ((TonoLinkCtrlLine) -> Void)?
    var otaWriteLimit: Int? = 185
    var connected = false
    var log: [String] = []
    var dropOnce: Set<Int> = []        // packet offsets lost once in the air
    var received = Data(), total = 0, crc: UInt32 = 0, receiving = false
    var written = 0, nextAck = 4096, gapTold = false
    var running = Data(repeating: 1, count: 10), confirmed = false
    var consoleOutput = ["fw 0.1.0-m21", "slot ota_0"]
    var endRejects = false

    func connect(timeout: Duration) async throws { connected = true; log.append("connect") }
    func disconnect() { if connected { log.append("disconnect") }; connected = false }
    func command(_ line: Data, seq: UInt16, timeout: Duration) async throws -> TonoLinkCtrlAck {
        try await request(line, seq: seq, timeout: timeout).ack
    }

    func request(_ line: Data, seq: UInt16, timeout: Duration) async throws -> TonoLinkCtrlReply {
        guard connected else { throw TonoLinkUSBOTAError("not connected") }
        let parts = String(decoding: line, as: UTF8.self).split(separator: " ")
        XCTAssertEqual(parts[0], "\(seq)")
        let verb = String(parts[1])
        log.append(verb)
        func ok(_ lines: [TonoLinkCtrlLine] = []) -> TonoLinkCtrlReply { TonoLinkCtrlReply(ack: TonoLinkCtrlAck(seq: seq, error: nil), lines: lines) }
        func err(_ why: String) -> TonoLinkCtrlReply { TonoLinkCtrlReply(ack: TonoLinkCtrlAck(seq: seq, error: why), lines: []) }
        switch verb {
        case "con": return ok(consoleOutput.map { .out(seq: seq, text: $0) })
        case "log":
            let since = UInt32(parts[2])!
            return ok([.log(seq: seq, index: since + 1, text: "I (1) a"), .log(seq: seq, index: since + 2, text: "I (2) b"), .logEnd(seq: seq, last: since + 2)])
        case "ota_begin":
            total = Int(parts[2])!; crc = UInt32(parts[3], radix: 16)!
            received = Data(); written = 0; nextAck = 4096; receiving = true
            return ok()
        case "ota_end":
            guard receiving, received.count == total, !endRejects, TonoLinkCRC32.checksum(received) == crc else { return err("range") }
            receiving = false; running = received; confirmed = false
            return ok()
        case "ota_abort": receiving = false; return ok()
        case "ota_confirm": confirmed = true; return ok()
        default: return err("parse")
        }
    }

    func writeOTA(_ packet: Data) async throws {
        guard connected, receiving else { return }
        let offset = Int(packet.prefix(4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).littleEndian })
        if dropOnce.remove(offset) != nil { return }
        let data = packet.dropFirst(4)
        if offset < received.count {
            if offset + data.count > received.count { gap() }
            return
        }
        guard offset == received.count, data.count <= total - received.count else { gap(); return }
        received.append(data); gapTold = false
        written = received.count   // the flash task keeps up in this model
        if written >= nextAck || written == total {
            onLine?(.otaAt(UInt32(written))); nextAck = written + 4096
        }
    }

    private func gap() {
        if !gapTold { onLine?(.otaAt(UInt32(received.count))); gapTold = true }
    }
}

@MainActor final class TonoLinkBLEDebugFlowTests: XCTestCase {
    func makeImage(size: Int = 40_000) throws -> TonoLinkFirmwareImage {
        var data = PhoneDSHBLETests.makeImage(version: "dbg", sha: 0x5a, size: size)
        for i in 300..<size { data[i] = UInt8((i * 7) & 0xff) }
        return try TonoLinkFirmwareImage(data: data)
    }

    func testConsoleAndLogPages() async throws {
        let board = SimBLEBoard()
        let debug = TonoLinkBLEDebug(link: board, clock: SimClock(), firstSeq: 1)
        let output = try await debug.console("info")
        XCTAssertEqual(output, ["fw 0.1.0-m21", "slot ota_0"])
        let page = try await debug.log(since: 3200)
        XCTAssertEqual(page.last, 3202)
        XCTAssertEqual(page.lines.map(\.index), [3201, 3202])
        XCTAssertEqual(page.lines.map(\.text), ["I (1) a", "I (2) b"])
    }

    func testOTAStreamsVerifiesRebootsAndConfirms() async throws {
        let board = SimBLEBoard()
        let image = try makeImage()
        var progress: [Double] = []
        let debug = TonoLinkBLEDebug(link: board, clock: SimClock(), firstSeq: 1)
        debug.onEvent = { if case .uploadProgress(let value) = $0 { progress.append(value) } }
        let report = try await debug.ota(image: image)
        XCTAssertEqual(board.running, image.data)
        XCTAssertTrue(board.confirmed)
        XCTAssertEqual(report.bytes, image.data.count)
        XCTAssertEqual(report.chunk, 181)
        XCTAssertEqual(report.resends, 0)
        XCTAssertEqual(progress.last, 1)
        XCTAssertEqual(board.log, ["connect", "ota_begin", "ota_end", "disconnect", "connect", "ota_confirm"])
    }

    func testLostPacketIsResentAfterAStall() async throws {
        let board = SimBLEBoard()
        let image = try makeImage()
        board.dropOnce = [181 * 30, 181 * 120]
        let report = try await TonoLinkBLEDebug(link: board, clock: SimClock(), firstSeq: 1).ota(image: image)
        XCTAssertEqual(board.running, image.data)
        XCTAssertGreaterThanOrEqual(report.resends, 2)
        XCTAssertTrue(board.confirmed)
    }

    func testBoardWithoutOTACharacteristicIsRejected() async throws {
        let board = SimBLEBoard()
        board.otaWriteLimit = nil
        do { _ = try await TonoLinkBLEDebug(link: board, clock: SimClock(), firstSeq: 1).ota(image: try makeImage()); XCTFail() }
        catch { XCTAssertTrue(error.localizedDescription.contains("ota_data"), error.localizedDescription) }
    }

    func testRejectedEndAbortsWithoutConfirming() async throws {
        let board = SimBLEBoard()
        board.endRejects = true
        do { _ = try await TonoLinkBLEDebug(link: board, clock: SimClock(), firstSeq: 1).ota(image: try makeImage()); XCTFail() }
        catch { XCTAssertEqual(error.localizedDescription, "BLE ota_end rejected: range") }
        XCTAssertFalse(board.confirmed)
        XCTAssertFalse(board.log.contains("ota_confirm"))
    }
}
