// SPDX-License-Identifier: MIT
// spec/device/v1/tonolink-board.md §4.1: the shared cases judge the real event
// parser, packet parser and listen command builder.

import Foundation
import XCTest
@testable import PhoneDSHBLE

final class TonoLinkVoiceTests: XCTestCase {
    private func cases() throws -> [String: Any] {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("spec/device/v1/golden/tonolink-voice.json"))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func hex(_ text: String) -> Data {
        var bytes: [UInt8] = []
        var index = text.startIndex
        while index < text.endIndex {
            let next = text.index(index, offsetBy: 2)
            bytes.append(UInt8(text[index..<next], radix: 16)!)
            index = next
        }
        return Data(bytes)
    }

    func testConstantsMatchTheCode() throws {
        let constants = try XCTUnwrap(try cases()["constants"] as? [String: Int])
        XCTAssertEqual(constants["header_bytes"], TonoLinkVoicePacket.headerBytes)
        XCTAssertEqual(constants["opus_max_bytes"], TonoLinkVoicePacket.opusMaxBytes)
    }

    func testEvents() throws {
        let events = try XCTUnwrap(try cases()["events"] as? [[String: Any]])
        XCTAssertGreaterThan(events.count, 10)
        for event in events {
            let line = try XCTUnwrap(event["line"] as? String)
            let parsed = TonoLinkVoiceEvent.parse(line)
            guard let expect = event["expect"] as? [String: Any] else {
                XCTAssertNil(parsed, line); continue
            }
            switch expect["kind"] as? String {
            case "wake":
                XCTAssertEqual(parsed, .wake(n: UInt32(expect["n"] as! Int), upMs: UInt32(expect["up_ms"] as! Int)), line)
            case "listen_end":
                let reason = try XCTUnwrap(TonoLinkVoiceEvent.Reason(rawValue: expect["reason"] as! String))
                XCTAssertEqual(parsed, .listenEnd(n: UInt32(expect["n"] as! Int), frames: UInt32(expect["frames"] as! Int),
                                                  reason: reason), line)
            default:
                XCTFail("unknown kind in \(line)")
            }
        }
    }

    func testListenCommands() throws {
        let commands = try XCTUnwrap(try cases()["listen_commands"] as? [[String: Any]])
        for command in commands {
            let data = try TonoLinkVoiceCommand.listen(seq: UInt16(command["seq"] as! Int), id: UInt32(command["id"] as! Int))
            XCTAssertEqual(String(decoding: data, as: UTF8.self), command["line"] as? String)
        }
        XCTAssertThrowsError(try TonoLinkVoiceCommand.listen(seq: 1, id: 0))
    }

    func testPackets() throws {
        let packets = try XCTUnwrap(try cases()["packets"] as? [[String: Any]])
        for packet in packets {
            let turn = UInt32(packet["turn_id"] as! Int)
            let data: Data
            if let repeatSpec = packet["hex_repeat"] as? [String: Any] {
                data = hex(repeatSpec["prefix"] as! String)
                    + Data(repeating: hex(repeatSpec["byte"] as! String)[0], count: repeatSpec["count"] as! Int)
            } else {
                data = hex(packet["hex"] as! String)
            }
            let parsed = TonoLinkVoicePacket.parse(data, turnID: turn)
            guard let expect = packet["expect"] as? [String: Any] else {
                XCTAssertNil(parsed, "\(packet)"); continue
            }
            let value = try XCTUnwrap(parsed, "\(packet)")
            XCTAssertEqual(Int(value.seq), expect["seq"] as? Int)
            XCTAssertEqual(value.first, expect["first"] as? Bool)
            XCTAssertEqual(value.last, expect["last"] as? Bool)
            XCTAssertEqual(value.opus, hex(expect["opus_hex"] as! String))
        }
    }

    func testTallyCountsGapsAndDrops() {
        var tally = TonoLinkVoiceTally()
        for seq: UInt16 in [0, 1, 3] { tally.record(TonoLinkVoicePacket(seq: seq, first: seq == 0, last: false, opus: Data([1]))) }
        tally.record(nil)
        XCTAssertEqual(tally.packets, 3)
        XCTAssertEqual(tally.gaps, 1)
        XCTAssertEqual(tally.dropped, 1)
    }
}
