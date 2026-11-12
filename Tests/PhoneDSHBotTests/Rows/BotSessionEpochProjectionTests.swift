// SPDX-License-Identifier: MIT

import XCTest
@testable import PhoneDSHBot

final class BotSessionEpochProjectionTests: XCTestCase {
    func testEpochChainKeepsOldRowsAndSkipsTombstones() throws {
        let header = BotDSHSessionEvent(
            type: "session", seq: 0, time: 1_760_000_000_000,
            data: ["version": .number(4), "id": .string("gb-main")])
        let oldUser = BotDSHSessionEvent(
            type: "user/message", seq: 1, time: 1_760_000_001_000,
            data: [
                "message": .object([
                    "role": .string("user"),
                    "content": .array([.object([
                        "type": .string("text"), "text": .string("old but unerased")])]),
                ]),
                "source": .object(["kind": .string("user"), "rpcId": .string("bot-1")]),
            ], surfaceOp: .append)
        let tombstone = BotDSHSessionEvent(
            type: BotSessionErasureTombstone.type, seq: 2, time: 1_760_000_002_000,
            data: ["erased": .bool(true)])
        let newUser = BotDSHSessionEvent(
            type: "user/message", seq: 1, time: 1_760_000_010_000,
            data: [
                "message": .object([
                    "role": .string("user"),
                    "content": .array([.object([
                        "type": .string("text"), "text": .string("new epoch message")])]),
                ]),
                "source": .object(["kind": .string("user"), "rpcId": .string("bot-2")]),
            ], surfaceOp: .append)
        let epochs = [
            BotSessionEpochProjection(
                sessionID: "gb-main", events: [header, oldUser, tombstone]),
            BotSessionEpochProjection(
                sessionID: "gb-new", events: [
                    BotDSHSessionEvent(type: "session", seq: 0, time: 1_760_000_009_000),
                    newUser,
                ]),
        ]
        let snapshot = BotSessionLogProjector().project(
            botID: "main", epochs: epochs, uiEvents: [])
        XCTAssertEqual(snapshot.rows.count, 2)
        XCTAssertEqual(snapshot.rows.map(\.id), ["e-gb-main-1", "e-gb-new-1"])
        XCTAssertTrue(snapshot.rows[0].body.textValue == "old but unerased")
        XCTAssertTrue(snapshot.rows[1].body.textValue == "new epoch message")
    }

    func testContinuationBlockIsModelContextButNotAUserBubble() throws {
        let marker = BotSessionErasureTombstone.marker
        let raw = marker + "\nPrevious context\n</session_continuation>\n\nhello"
        XCTAssertEqual(BotSessionContinuation.strip(raw), "hello")
        XCTAssertEqual(BotSessionContinuation.strip("hello"), "hello")
        let user = BotDSHSessionEvent(
            type: "user/message", seq: 1, time: 1_760_000_001_000,
            data: [
                "message": .object([
                    "role": .string("user"),
                    "content": .array([.object([
                        "type": .string("text"), "text": .string(raw)])]),
                ]),
                "source": .object(["kind": .string("user"), "rpcId": .string("bot-1")]),
            ], surfaceOp: .append)
        let snapshot = BotSessionLogProjector().project(
            botID: "main",
            epochs: [BotSessionEpochProjection(sessionID: "gb-main", events: [user])],
            uiEvents: [])
        XCTAssertEqual(snapshot.rows.count, 1)
        XCTAssertEqual(snapshot.rows[0].body.textValue, "hello")
    }
}

private extension BotRowBody {
    var textValue: String? { additionalProperties["text"]?.stringValue }
}
