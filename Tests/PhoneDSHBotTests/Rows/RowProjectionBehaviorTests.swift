// SPDX-License-Identifier: MIT

import XCTest
@testable import PhoneDSHBot

final class RowProjectionBehaviorTests: XCTestCase {
    func testSuccessfulQuestionSuppressesWrapUpUntilTurnEnd() {
        let call = BotDSHSessionEvent(type: "tool/call", seq: 1, time: 1, data: [
            "name": .string("mcp__bot__ask_user"), "callId": .string("question-1"), "arguments": .string("{}")
        ])
        let result = BotDSHSessionEvent(type: "tool/result", seq: 2, time: 2, data: [
            "message": .object([
                "toolCallId": .string("question-1"),
                "content": .array([.object(["type": .string("text"), "text": .string("已顯示問題卡片")])])
            ])
        ])
        let wrapUp = RowTestSupport.dshText(seq: 3, time: 3, role: "assistant", text: "不应显示的收尾")
        let end = BotDSHSessionEvent(type: "turn/end", seq: 4, time: 4,
                                     data: ["reason": .object(["kind": .string("completed")])])
        let nextTurn = RowTestSupport.dshText(seq: 5, time: 5, role: "assistant", text: "下一回合")
        let snapshot = BotSessionLogProjector().project(botID: "main", sessionID: "main",
                                                        sessionEvents: [call, result, wrapUp, end, nextTurn], uiEvents: [])
        XCTAssertEqual(snapshot.rows.map(\.id), ["e-main-5"])
        XCTAssertEqual(snapshot.rows.first?.body["text"], .string("下一回合"))
    }

    func testSystemEventWhitelistAlsoAppliesToProjectedRows() {
        let renamed = RowTestSupport.uiEvent(type: "ui.system_event", id: "evt-renamed", commitSeq: 1, time: 1,
                                             data: ["event": .string("renamed"), "botName": .string("新名字")])
        let freeText = RowTestSupport.uiEvent(type: "ui.system_event", id: "evt-other", commitSeq: 2, time: 2,
                                              data: ["event": .string("other"), "text": .string("free text")])
        let snapshot = BotSessionLogProjector().project(botID: "main", sessionID: "main",
                                                        sessionEvents: [], uiEvents: [renamed, freeText])
        XCTAssertEqual(snapshot.rows.count, 2)
        let visible = BotDisplayContract.project(snapshot.rows[0])
        let hidden = BotDisplayContract.project(snapshot.rows[1])
        XCTAssertEqual(visible.surface, "system-event")
        XCTAssertTrue(visible.renderable)
        XCTAssertEqual(visible.wire, BotWireRecord(kind: "event", type: "renamed"))
        XCTAssertEqual(hidden.surface, BotDisplayContract.hidden)
        XCTAssertFalse(hidden.renderable)
    }

    func testApprovalDecisionUpdatesSameRowAndBecomesVisible() {
        let requested = RowTestSupport.uiEvent(type: "approval.requested", id: "evt-ask", commitSeq: 1, time: 1,
                                               data: ["requestId": .string("approval-1"), "action": .string("删除文件")])
        let decided = RowTestSupport.uiEvent(type: "approval.decided", id: "evt-decision", commitSeq: 2, time: 2,
                                             data: ["requestId": .string("approval-1"), "action": .string("删除文件"),
                                                    "decision": .string("deny")])
        let snapshot = BotSessionLogProjector().project(botID: "main", sessionID: "main",
                                                        sessionEvents: [], uiEvents: [requested, decided])
        XCTAssertEqual(snapshot.rows.count, 1)
        let row = snapshot.rows[0]
        XCTAssertEqual(row.id, "e-main-approval-approval-1")
        XCTAssertEqual(row.body["status"], .string("denied"))
        XCTAssertEqual(row.provenance.eventIDs, ["evt-ask", "evt-decision"])
        XCTAssertTrue(BotDisplayContract.project(row).renderable)
    }

    func testIPCOriginCannotSelfDeclareDirectUserTrust() {
        let ipc = BotEvent(type: "ui.notice", eventId: "evt-ipc", commitSeq: 1, time: 1,
                           origin: .local(source: "ipc"), traceId: "trace-ipc",
                           principal: BotPrincipal(botId: "main", sessionId: "main", kind: "ipc"),
                           causationId: nil, correlationId: nil,
                           data: .object(["tone": .string("error"), "text": .string("IPC")]))
        let user = BotEvent(type: "ui.notice", eventId: "evt-user", commitSeq: 2, time: 2,
                            origin: .local(source: "user"), traceId: "trace-user",
                            principal: BotPrincipal(botId: "main", sessionId: "main", kind: "ipc"),
                            causationId: nil, correlationId: nil,
                            data: .object(["tone": .string("error"), "text": .string("user")]))
        let snapshot = BotSessionLogProjector().project(botID: "main", sessionID: "main",
                                                        sessionEvents: [], uiEvents: [ipc, user])
        XCTAssertEqual(snapshot.rows.map(\.provenance.trust), [BotRowProvenance.model, BotRowProvenance.ownerDirect])
    }

    func testCardAnswerAndDismissalPersistAcrossRebuild() {
        let answeredCard = RowTestSupport.uiEvent(type: "card.presented", id: "evt-card-answered", commitSeq: 1, time: 1,
                                                  data: [
                                                    "id": .string("card-answered"),
                                                    "cardType": .string("question"),
                                                    "question": .string("保存到哪里？"),
                                                    "options": .array([.object(["id": .string("o0"), "label": .string("文档库")]),
                                                                       .object(["id": .string("o1"), "label": .string("PDF")])])
                                                  ])
        let answer = RowTestSupport.uiEvent(type: "card.answered", id: "evt-card-answer", commitSeq: 2, time: 2,
                                            data: ["cardID": .string("card-answered"), "optionID": .string("o1")])
        let dismissedCard = RowTestSupport.uiEvent(type: "card.presented", id: "evt-card-dismissed", commitSeq: 3, time: 3,
                                                   data: [
                                                    "id": .string("card-dismissed"),
                                                    "cardType": .string("question"),
                                                    "question": .string("继续吗？"),
                                                    "options": .array([.object(["id": .string("o0"), "label": .string("继续")]),
                                                                       .object(["id": .string("o1"), "label": .string("停止")])])
                                                   ])
        let dismissal = RowTestSupport.uiEvent(type: "card.dismissed", id: "evt-card-dismiss", commitSeq: 4, time: 4,
                                               data: ["cardID": .string("card-dismissed")])
        let snapshot = BotSessionLogProjector().project(
            botID: "main", sessionID: "main", sessionEvents: [],
            uiEvents: [answeredCard, answer, dismissedCard, dismissal])
        XCTAssertEqual(snapshot.rows.map(\.id), ["card-answered"])
        XCTAssertEqual(snapshot.rows.first?.body["status"], .string("answered"))
        XCTAssertEqual(snapshot.rows.first?.body["answeredOptionID"], .string("o1"))
    }
}
