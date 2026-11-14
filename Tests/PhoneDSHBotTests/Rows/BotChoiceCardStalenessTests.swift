// SPDX-License-Identifier: MIT

import XCTest
@testable import PhoneDSHBot

/// The one choice-card staleness rule and the row status the UI greys out from.
/// Before this, the projection had no idea a newer card had replaced an older
/// one: the page kept the old card tappable and the planner then refused the tap
/// with `card_expired`, which the header printed as an error.
final class BotChoiceCardStalenessTests: XCTestCase {
    private func presented(_ id: String, commitSeq: Int, time: Int64, cardType: String = "question",
                           question: String = "保存到哪里？") -> BotEvent {
        RowTestSupport.uiEvent(type: "card.presented", id: "evt-\(id)", commitSeq: commitSeq, time: time,
                               data: [
                                "id": .string(id),
                                "cardType": .string(cardType),
                                "question": .string(question),
                                "options": .array([
                                    .object(["id": .string("o0"), "label": .string("文档库"),
                                             "value": .string("library")]),
                                    .object(["id": .string("o1"), "label": .string("PDF"),
                                             "value": .string("pdf")]),
                                ]),
                               ])
    }

    func testNewerChoiceCardSupersedesEveryOpenOne() {
        let first = presented("card-a", commitSeq: 1, time: 1)
        let second = presented("card-b", commitSeq: 2, time: 2)
        let superseded = BotChoiceCardStaleness.supersededCards(in: [first, second], botID: "main")
        XCTAssertEqual(superseded, ["card-a": "card-b"])
        XCTAssertEqual(BotChoiceCardStaleness.supersededCards(in: [second, first], botID: "main"),
                       ["card-a": "card-b"], "the rule reads the commit order, not the array order")
    }

    func testAnsweringOrDismissingTheNewerCardDoesNotReviveTheOlderOne() {
        let first = presented("card-a", commitSeq: 1, time: 1)
        let second = presented("card-b", commitSeq: 2, time: 2)
        let answer = RowTestSupport.uiEvent(type: "card.answered", id: "evt-answer", commitSeq: 3, time: 3,
                                            data: ["cardID": .string("card-b"), "optionID": .string("o0")])
        let dismissed = RowTestSupport.uiEvent(type: "card.dismissed", id: "evt-dismiss", commitSeq: 4, time: 4,
                                               data: ["cardID": .string("card-c")])
        XCTAssertEqual(
            BotChoiceCardStaleness.supersededCards(in: [first, second, answer, dismissed], botID: "main"),
            ["card-a": "card-b"])
    }

    func testCardClosedBeforeTheNewerOneIsNotSuperseded() {
        let first = presented("card-a", commitSeq: 1, time: 1)
        let answer = RowTestSupport.uiEvent(type: "card.answered", id: "evt-answer", commitSeq: 2, time: 2,
                                            data: ["cardID": .string("card-a"), "optionID": .string("o1")])
        let second = presented("card-b", commitSeq: 3, time: 3)
        XCTAssertTrue(BotChoiceCardStaleness.supersededCards(in: [first, answer, second], botID: "main").isEmpty)
    }

    func testOnlyQuestionAndStepsCardsSupersede() {
        let progress = RowTestSupport.progress(id: "evt-progress", commitSeq: 1, time: 1, percent: 40)
        let first = presented("card-a", commitSeq: 2, time: 2)
        let steps = presented("card-b", commitSeq: 3, time: 3, cardType: "steps", question: "")
        XCTAssertEqual(
            BotChoiceCardStaleness.supersededCards(in: [progress, first, steps], botID: "main"),
            ["card-a": "card-b"])
    }

    func testAnotherBotsCardNeverSupersedesThisBotsCard() {
        let first = presented("card-a", commitSeq: 1, time: 1)
        let other = BotEvent(
            type: "card.presented", eventId: "evt-card-other", commitSeq: 2, time: 2,
            origin: .local(source: "card-bridge"), traceId: "trace-card-other",
            principal: BotPrincipal(botId: "other", sessionId: "other", kind: "chat"),
            causationId: nil, correlationId: nil,
            data: .object(["id": .string("card-other"), "cardType": .string("question")]))
        XCTAssertTrue(BotChoiceCardStaleness.supersededCards(in: [first, other], botID: "main").isEmpty)
    }

    func testOlderCardIsProjectedSupersededByTheNewerOne() throws {
        let first = presented("card-a", commitSeq: 1, time: 1, question: "第一张？")
        let second = presented("card-b", commitSeq: 2, time: 2, question: "第二张？")
        let snapshot = BotSessionLogProjector().project(
            botID: "main", sessionID: "gb-main", sessionEvents: [], uiEvents: [first, second])
        XCTAssertEqual(snapshot.rows.map(\.id), ["card-a", "card-b"])
        let older = try XCTUnwrap(snapshot.rows.first { $0.id == "card-a" })
        XCTAssertEqual(older.body["status"], .string("superseded"))
        XCTAssertEqual(older.body["supersededBy"], .string("card-b"))
        XCTAssertEqual(older.body.cardType, .question)
        let newest = try XCTUnwrap(snapshot.rows.first { $0.id == "card-b" })
        XCTAssertNil(newest.body["status"])
        XCTAssertNil(newest.body["supersededBy"])
    }

    func testAnsweredBeforeTheNewerCardKeepsTheAnsweredStatus() throws {
        let first = presented("card-a", commitSeq: 1, time: 1)
        let answer = RowTestSupport.uiEvent(type: "card.answered", id: "evt-answer", commitSeq: 2, time: 2,
                                            data: ["cardID": .string("card-a"), "optionID": .string("o1")])
        let second = presented("card-b", commitSeq: 3, time: 3)
        let snapshot = BotSessionLogProjector().project(
            botID: "main", sessionID: "gb-main", sessionEvents: [], uiEvents: [first, answer, second])
        let answered = try XCTUnwrap(snapshot.rows.first { $0.id == "card-a" })
        XCTAssertEqual(answered.body["status"], .string("answered"))
        XCTAssertEqual(answered.body["answeredOptionID"], .string("o1"))
        XCTAssertNil(answered.body["supersededBy"])
    }

    /// The tap's optimistic echo is retired by the durable user row through the
    /// in-memory nonce; the nonce comes from the frozen `card-answer:<nonce>`
    /// request id the planner sends.
    func testCardAnswerUserRowCarriesTheCardAnswerNonce() throws {
        let event = RowTestSupport.dshText(
            seq: 1, time: 1, role: "user", text: "library",
            sourceKind: "user", rpcId: "card-answer:0d1f0c9a7b3e")
        let row = try XCTUnwrap(BotSessionLogProjector().project(
            botID: "main", sessionID: "gb-main", sessionEvents: [event], uiEvents: []).rows.first)
        XCTAssertEqual(row.role, "user")
        XCTAssertEqual(row.chatActionNonce, "0d1f0c9a7b3e")
    }

    func testOnlyAUserSourcedCardAnswerMessageIsAUserRowWithTheNonce() throws {
        // `source.kind` other than `user` is not a user transcript row at all
        // (§4.4 step 10), so it can never retire an optimistic echo.
        let event = RowTestSupport.dshText(
            seq: 1, time: 1, role: "user", text: "library",
            sourceKind: "agent", rpcId: "card-answer:0d1f0c9a7b3e")
        let snapshot = BotSessionLogProjector().project(
            botID: "main", sessionID: "gb-main", sessionEvents: [event], uiEvents: [])
        XCTAssertTrue(snapshot.rows.isEmpty)
    }
}
