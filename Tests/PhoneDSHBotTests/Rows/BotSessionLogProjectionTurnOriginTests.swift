// SPDX-License-Identifier: MIT

import XCTest
@testable import PhoneDSHBot

final class BotSessionLogProjectionTurnOriginTests: XCTestCase {
    private let projector = BotSessionLogProjector()

    private func project(_ events: [BotDSHSessionEvent]) -> [BotRow] {
        projector.project(botID: "main", sessionID: "gb-main",
                          sessionEvents: events, uiEvents: []).rows
    }

    func testUserTextStartingWithTheHiddenMarkerStillProjectsWhenSourceIsUser() throws {
        let text = "[SAND_HIDDEN_PROMPT] this is a real user sentence"
        let row = try XCTUnwrap(project([
            RowTestSupport.dshText(seq: 1, time: 1_000, role: "user", text: text,
                                   sourceKind: "user", rpcId: "user-action:nonce-1"),
        ]).first)
        XCTAssertEqual(row.body["text"], .string(text))
        XCTAssertEqual(row.chatActionNonce, "nonce-1")
    }

    func testUserTextContainingAHeldTagIsShownVerbatim() throws {
        let text = "<held_agent_messages>\n- [agent] Bee: hello\n</held_agent_messages>\nand my question"
        let row = try XCTUnwrap(project([
            RowTestSupport.dshText(seq: 1, time: 1_000, role: "user", text: text,
                                   sourceKind: "user", rpcId: "user-action:nonce-2"),
        ]).first)
        XCTAssertEqual(row.body["text"], .string(text))
    }

    func testOnlyAHeldOriginStripsTheHeldBlock() throws {
        let text = "<held_agent_messages>\n- [routine] report: done\n</held_agent_messages>\nand my question"
        let rows = project([
            RowTestSupport.dshText(seq: 1, time: 1_000, role: "user", text: text,
                                   sourceKind: "user", rpcId: "held:digest-1"),
        ])
        let row = try XCTUnwrap(rows.first)
        XCTAssertEqual(row.body["text"], .string("and my question"))
    }

    func testAgentOriginDoesNotProjectAsAUserBubble() throws {
        let rows = project([
            RowTestSupport.dshText(seq: 1, time: 1_000, role: "user",
                                   text: "[agent] Bee (id: bot-b): hello",
                                   sourceKind: "user", rpcId: "agent:call_1"),
        ])
        XCTAssertTrue(rows.isEmpty)
    }

    func testHiddenOriginsRemainHiddenWhileAssistantRowsFollowTheTurn() throws {
        for (index, rpcId) in ["routine:run-1", "task-turn:task-1",
                               "task-settled:task-1", "task-interrupted:task-1"].enumerated() {
            let seq = index * 3
            let rows = project([
                BotDSHSessionEvent(type: "turn/start", seq: seq, time: 1_000,
                                   data: ["turn": .number(1)]),
                RowTestSupport.dshText(seq: seq + 1, time: 1_001, role: "user",
                                       text: "[SAND_HIDDEN_PROMPT] wake",
                                       turn: 1, sourceKind: "user", rpcId: rpcId),
                RowTestSupport.dshText(seq: seq + 2, time: 1_002, role: "assistant",
                                       text: "hidden answer", turn: 1),
            ])
            XCTAssertTrue(rows.isEmpty, rpcId)
        }
    }

    func testLegacyBareCallIDSourceIsVisibleUnknown() throws {
        let text = "[agent] Bee (id: bot-b): pre-WP4 bot message"
        let row = try XCTUnwrap(project([
            RowTestSupport.dshText(seq: 1, time: 1_000, role: "user", text: text,
                                   sourceKind: "user", rpcId: "call_01J8Z9K3Q4W5X6Y7Z8A9B0C1D2"),
        ]).first)
        XCTAssertEqual(row.body["text"], .string(text))
        XCTAssertNil(row.chatActionNonce)
    }

    func testSourceMissingRecordsFollowTheUnknownRule() throws {
        // A pre-source injected runtime context stays suppressed by the
        // text fallback, but unknown turn text is visible, never hidden.
        let injected = RowTestSupport.dshText(
            seq: 1, time: 1_000, role: "user", text: "Current runtime context. snapshot")
        let legacyBotMessage = RowTestSupport.dshText(
            seq: 2, time: 1_001, role: "user", text: "[SAND_HIDDEN_PROMPT] legacy")
        let oldCallID = RowTestSupport.dshText(
            seq: 3, time: 1_002, role: "user", text: "old bot message")
        let rows = project([injected, legacyBotMessage, oldCallID])
        XCTAssertEqual(rows.map { $0.body["text"] }, [
            .string("[SAND_HIDDEN_PROMPT] legacy"), .string("old bot message"),
        ])
    }
}
