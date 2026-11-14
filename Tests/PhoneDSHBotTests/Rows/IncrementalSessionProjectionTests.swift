// SPDX-License-Identifier: MIT
import XCTest
@testable import PhoneDSHBot

final class IncrementalSessionProjectionTests: XCTestCase {
    func testEveryAppendMatchesFullProjectionAndReducesEachEventOnce() {
        let projector = BotSessionLogProjector()
        var cache = BotSessionLogProjector.IncrementalCache()
        var events: [BotDSHSessionEvent] = []
        for index in 0..<200 {
            let turn = index / 4 + 1
            switch index % 4 {
            case 0: events.append(BotDSHSessionEvent(type: "turn/start", seq: index, time: Int64(index),
                                                    data: ["turn": .number(Double(turn))]))
            case 1: events.append(RowTestSupport.dshText(seq: index, time: Int64(index), role: "user", text: "question", turn: turn))
            case 2: events.append(RowTestSupport.dshText(seq: index, time: Int64(index), role: "assistant", text: "answer", turn: turn))
            default: events.append(BotDSHSessionEvent(type: "turn/end", seq: index, time: Int64(index),
                data: ["turn": .number(Double(turn)), "reason": .object(["kind": .string("completed")])]))
            }
            let epochs = [BotSessionEpochProjection(sessionID: "main", events: events)]
            XCTAssertEqual(projector.project(botID: "main", epochs: epochs, uiEvents: [],
                                              heldRequestNonces: [:], cache: &cache),
                           projector.project(botID: "main", epochs: epochs, uiEvents: []))
        }
        XCTAssertEqual(cache.processedEvents, events.count)
    }

    func testRewriteTruncationEpochSwitchAndUIOutcomesMatchOracle() {
        let projector = BotSessionLogProjector()
        var cache = BotSessionLogProjector.IncrementalCache()
        let first = RowTestSupport.dshText(seq: 1, time: 1, role: "assistant", text: "before")
        let rewritten = RowTestSupport.dshText(seq: 1, time: 1, role: "assistant", text: "after")
        let cases: [[BotSessionEpochProjection]] = [
            [.init(sessionID: "main", events: [first])],
            [.init(sessionID: "main", events: [rewritten])],
            [.init(sessionID: "main", events: [])],
            [.init(sessionID: "main", events: [first]), .init(sessionID: "next", events: [rewritten])],
            [.init(sessionID: "next", events: [rewritten])],
        ]
        for epochs in cases {
            for ui in [[], [RowTestSupport.progress(id: "progress", commitSeq: 1, time: 1, percent: 30)],
                       [RowTestSupport.progress(id: "progress", commitSeq: 1, time: 1, percent: 100)]] {
                for held in [[:], ["request": "nonce"]] {
                    XCTAssertEqual(projector.project(botID: "main", epochs: epochs, uiEvents: ui,
                                                      heldRequestNonces: held, cache: &cache),
                                   projector.project(botID: "main", epochs: epochs, uiEvents: ui,
                                                     heldRequestNonces: held))
                }
            }
        }
    }

    func testApprovalToolStateAndDuplicateIDsSurviveBatchBoundaries() {
        let events = [
            BotDSHSessionEvent(type: "tool/call", seq: 1, time: 1, data: [
                "name": .string("mcp__phone__RequestApproval"), "callId": .string("call"),
                "arguments": .string("{\"action\":\"write\",\"command\":\"touch file\"}")], eventID: "call-event"),
            BotDSHSessionEvent(type: "tool/result", seq: 2, time: 2, data: [
                "callId": .string("call"), "message": .object(["toolCallId": .string("call"),
                    "content": .array([.object(["type": .string("text"),
                                              "text": .string("{\"allowed\":false,\"decision\":\"denied\"}")])])])]),
        ]
        let projector = BotSessionLogProjector()
        var cache = BotSessionLogProjector.IncrementalCache()
        for records in [[events[0]], events, events + [events[0]]] {
            let epochs = [BotSessionEpochProjection(sessionID: "main", events: records)]
            XCTAssertEqual(projector.project(botID: "main", epochs: epochs, uiEvents: [],
                                              heldRequestNonces: [:], cache: &cache),
                           projector.project(botID: "main", epochs: epochs, uiEvents: []))
        }
    }
}
