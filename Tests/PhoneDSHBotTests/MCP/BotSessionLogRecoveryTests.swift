// SPDX-License-Identifier: MIT

import Foundation
import XCTest
@testable import PhoneDSHBot

final class BotSessionLogRecoveryTests: XCTestCase {
    private func line(_ object: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: object)
        return String(decoding: data, as: UTF8.self)
    }

    private func event(_ type: String, _ data: [String: Any]) -> String {
        line(["type": type, "seq": 1, "data": data])
    }

    func testOpenTurnWithPendingCallIsReported() {
        let lines = [
            event("turn/start", ["turn": 8]),
            event("tool/call", ["turn": 8, "callId": "call-a"]),
            event("tool/result", ["toolCallId": "call-other"]),
            event("tool/call", ["turn": 8, "callId": "call-b"]),
        ]
        let report = BotSessionLogRecovery.inspect(lines: lines)
        XCTAssertEqual(report, BotOpenTurnReport(turn: 8, pendingCallIDs: ["call-a", "call-b"]))
    }

    func testClosedTurnIsNotReported() {
        let lines = [
            event("turn/start", ["turn": 8]),
            event("tool/call", ["turn": 8, "callId": "call-a"]),
            event("tool/result", ["toolCallId": "call-a"]),
            event("turn/end", ["turn": 8, "reason": ["kind": "completed"]]),
        ]
        XCTAssertNil(BotSessionLogRecovery.inspect(lines: lines))
    }

    func testResultClosesCallInsideOpenTurn() {
        let lines = [
            event("turn/start", ["turn": 3]),
            event("tool/call", ["turn": 3, "callId": "call-a"]),
            event("tool/result", ["message": ["toolCallId": "call-a"]]),
            event("tool/call", ["turn": 3, "callId": "call-b"]),
        ]
        XCTAssertEqual(BotSessionLogRecovery.inspect(lines: lines)?.pendingCallIDs, ["call-b"])
    }

    func testMalformedLinesAndToolsOutsideATurnAreIgnored() {
        let lines = [
            "not json",
            event("tool/call", ["callId": "outside"]),
            event("turn/start", ["turn": 2]),
        ]
        XCTAssertEqual(BotSessionLogRecovery.inspect(lines: lines)?.turn, 2)
        XCTAssertEqual(BotSessionLogRecovery.inspect(lines: lines)?.pendingCallIDs, [])
    }

    func testTailReadDropsPartialFirstLine() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("session-recovery-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("session.v4.jsonl")
        let padding = String(repeating: "x", count: 1024)
        let body = [
            line(["type": "session", "version": 4, "id": "gb-main"]),
            event("turn/start", ["turn": 1]),
            event("tool/call", ["callId": "call-pad"]),
            event("turn/end", ["turn": 1]),
            padding,
            event("turn/start", ["turn": 2]),
            event("tool/call", ["callId": "call-open"]),
        ].joined(separator: "\n") + "\n"
        try body.write(to: url, atomically: true, encoding: .utf8)
        let report = BotSessionLogRecovery.openTurn(at: url, maximumBytes: 512)
        XCTAssertEqual(report?.turn, 2)
        XCTAssertEqual(report?.pendingCallIDs, ["call-open"])
    }
}
