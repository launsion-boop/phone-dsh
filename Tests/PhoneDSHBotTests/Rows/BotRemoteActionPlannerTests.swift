// SPDX-License-Identifier: MIT

import PhoneDSHAgentCore
import XCTest
@testable import PhoneDSHBot

private struct BotUnavailableRemoteTransport: DSHRemoteTransport {
    func call(_ endpoint: String, args: BotJSONValue) async throws -> BotJSONValue {
        throw BotMCPError.unavailable("DSH is unavailable")
    }

    func openMux() async throws -> any DSHMuxConnection {
        throw BotMCPError.unavailable("DSH is unavailable")
    }

    func authenticationFailed() async {}
}

final class BotRemoteActionPlannerTests: XCTestCase {
    private struct Harness {
        let fixture: BotMCPTestFixture
        let transport: BotScriptedRemoteTransport?
        let dispatcher: BotUserActionDispatcher
        let planner: BotRemoteActionPlanner
    }

    private func makeHarness(scripts: [[BotScriptedEvent]] = []) async throws -> Harness {
        let transport = BotScriptedRemoteTransport(scripts: ["gb-main": scripts])
        return try await makeHarness(transport: transport, scripted: transport)
    }

    private func makeHarness(transport: any DSHRemoteTransport,
                             scripted: BotScriptedRemoteTransport? = nil) async throws -> Harness {
        let fixture = try makeBotMCPFixture()
        _ = try await fixture.runtime.issueSession(botId: "main", sessionId: "gb-main", kind: .chat)
        let remote = try await BotDSHRemoteRuntime(transport: transport, runtime: fixture.runtime)
        let handler = BotMCPHandler(runtime: fixture.runtime)
        let planner = BotRemoteActionPlanner(
            remote: remote, runtime: fixture.runtime, handler: handler,
            store: fixture.store, botID: "main", now: { 1_000 })
        let dispatcher = BotUserActionDispatcher(store: fixture.store, planner: planner)
        return Harness(fixture: fixture, transport: scripted, dispatcher: dispatcher, planner: planner)
    }

    private func presentCard(_ harness: Harness, tool: String,
                             arguments: BotJSONValue) async throws -> BotEvent {
        let call = try await registerAndExecute(harness.fixture.runtime, name: tool, arguments: arguments)
        XCTAssertNotEqual(call.isError, true, String(describing: call.structuredContent))
        let events = try await botEvents(harness.fixture.store)
        return try XCTUnwrap(events.last {
            $0.type == "card.presented"
                && ($0.data["tool"]?.stringValue == tool || $0.data["cardType"]?.stringValue == (tool == "ask_user" ? "question" : "steps"))
        })
    }

    private func cardID(_ event: BotEvent) throws -> String {
        try XCTUnwrap(event.data["id"]?.stringValue)
    }

    private func optionIDs(_ event: BotEvent) -> [String] {
        let key = event.data["cardType"]?.stringValue == "steps" ? "steps" : "options"
        return (event.data[key]?.arrayValue ?? []).compactMap { $0["id"]?.stringValue }
    }

    private func questionCard(_ harness: Harness, question: String = "保存到哪里？") async throws -> BotEvent {
        try await presentCard(harness, tool: "ask_user", arguments: .object([
            "question": .string(question),
            "options": .array([
                .object(["label": .string("保存到文档库"), "value": .string("library"), "recommended": .bool(true)]),
                .object(["label": .string("导出 PDF"), "value": .string("pdf")]),
            ]),
        ]))
    }

    func testAnswersRealQuestionAndStepsCardsWithHostOptionIDs() async throws {
        let harness = try await makeHarness(scripts: [
            [.turn(), .assistant("answered question"), .end()],
            [.turn(2), .assistant("answered steps"), .end(turn: 2)],
        ])
        defer { harness.fixture.cleanup() }

        let question = try await questionCard(harness)
        let questionID = try cardID(question)
        XCTAssertEqual(optionIDs(question), ["o0", "o1"])

        let answer = BotUserAction(
            nonce: "answer-question", botID: "main", kind: .cardAnswer,
            cardID: questionID, optionID: "o0")
        let accepted = try await harness.dispatcher.dispatch(answer)
        XCTAssertEqual(accepted.status, "accepted")
        XCTAssertEqual(harness.transport?.promptHistory.last?.text, "library")
        var events = try await botEvents(harness.fixture.store)
        XCTAssertTrue(events.contains {
            $0.type == "card.answered"
                && $0.data["cardID"] == .string(questionID)
                && $0.data["optionID"] == .string("o0")
                && $0.data["value"] == .string("library")
        })
        let answeredAgain = try await harness.dispatcher.dispatch(
            BotUserAction(nonce: "answer-question-again", botID: "main", kind: .cardAnswer,
                          cardID: questionID, optionID: "o0"))
        XCTAssertEqual(answeredAgain, .stale(reason: "already_answered"))

        let steps = try await presentCard(harness, tool: "show_next_steps", arguments: .object([
            "steps": .array([
                .object(["label": .string("查看结果"), "value": .string("review")]),
                .string("稍后再说"),
            ]),
        ]))
        let stepsID = try cardID(steps)
        XCTAssertEqual(optionIDs(steps), ["o0", "o1"])
        let stepsAccepted = try await harness.dispatcher.dispatch(
            BotUserAction(nonce: "answer-steps", botID: "main", kind: .cardAnswer,
                          cardID: stepsID, optionID: "o1"))
        XCTAssertEqual(stepsAccepted.status, "accepted")
        XCTAssertEqual(harness.transport?.promptHistory.last?.text, "稍后再说")
        events = try await botEvents(harness.fixture.store)
        XCTAssertTrue(events.contains {
            $0.type == "card.answered" && $0.data["cardID"] == .string(stepsID)
                && $0.data["optionID"] == .string("o1")
        })
    }

    func testFakeOptionIDIsStale() async throws {
        let harness = try await makeHarness()
        defer { harness.fixture.cleanup() }
        let card = try await questionCard(harness)
        let result = try await harness.dispatcher.dispatch(
            BotUserAction(nonce: "fake-option", botID: "main", kind: .cardAnswer,
                          cardID: try cardID(card), optionID: "o99"))
        XCTAssertEqual(result, .stale(reason: "unknown_option"))
        XCTAssertEqual(harness.transport?.promptHistory.count, 0)
    }

    func testDismissWritesDurableEventWithoutModelTurnAndDeliversHeldItem() async throws {
        let harness = try await makeHarness()
        defer { harness.fixture.cleanup() }
        let card = try await questionCard(harness, question: "要继续吗？")
        let cardID = try cardID(card)

        let dismissed = try await harness.dispatcher.dispatch(
            BotUserAction(nonce: "dismiss-card", botID: "main", kind: .cardDismiss, cardID: cardID))
        XCTAssertEqual(dismissed.status, "accepted")
        XCTAssertEqual(harness.transport?.promptHistory.count, 0)
        let events = try await botEvents(harness.fixture.store)
        XCTAssertTrue(events.contains {
            $0.type == "card.dismissed" && $0.data["cardID"] == .string(cardID)
        })
        XCTAssertFalse(events.contains { $0.type == "conversation.turn_started" })

        let inbox = WakeInbox(store: SQLiteWakeInboxStore(domainStore: harness.fixture.store, botId: "main"))
        let items = try await inbox.items()
        XCTAssertEqual(items.map(\.kind), ["card-dismissed"])
        XCTAssertEqual(items.first?.title, "要继续吗？")
        XCTAssertTrue(HeldMessages.block(items: items).contains("[card-dismissed]"))
        XCTAssertTrue(HeldMessages.block(items: items).contains("要继续吗？"))

        let dismissedAgain = try await harness.dispatcher.dispatch(
            BotUserAction(nonce: "answer-dismissed", botID: "main", kind: .cardAnswer,
                          cardID: cardID, optionID: "o0"))
        XCTAssertEqual(dismissedAgain, .stale(reason: "card_dismissed"))
        let repeatedDismiss = try await harness.dispatcher.dispatch(
            BotUserAction(nonce: "dismiss-again", botID: "main", kind: .cardDismiss, cardID: cardID))
        XCTAssertEqual(repeatedDismiss, .stale(reason: "card_dismissed"))
    }

    func testDismissStillCommitsWhenDSHIsUnavailable() async throws {
        let harness = try await makeHarness(transport: BotUnavailableRemoteTransport())
        defer { harness.fixture.cleanup() }
        let card = try await questionCard(harness)
        let result = try await harness.dispatcher.dispatch(
            BotUserAction(nonce: "dismiss-offline", botID: "main", kind: .cardDismiss,
                          cardID: try cardID(card)))
        XCTAssertEqual(result.status, "accepted")
        let events = try await botEvents(harness.fixture.store)
        XCTAssertTrue(events.contains { $0.type == "card.dismissed" })
    }

    func testStepsCardDismissIsRejected() async throws {
        let harness = try await makeHarness()
        defer { harness.fixture.cleanup() }
        let steps = try await presentCard(harness, tool: "show_next_steps", arguments: .object([
            "steps": .array([.string("A"), .string("B")]),
        ]))
        let result = try await harness.dispatcher.dispatch(
            BotUserAction(nonce: "dismiss-steps", botID: "main", kind: .cardDismiss,
                          cardID: try cardID(steps)))
        XCTAssertEqual(result, .rejected(reason: "only_question_cards_can_be_dismissed"))
        let events = try await botEvents(harness.fixture.store)
        XCTAssertFalse(events.contains { $0.type == "card.dismissed" })
    }

    func testNewChoiceCardExpiresOlderOpenQuestion() async throws {
        let harness = try await makeHarness(scripts: [
            [.turn(), .assistant("answered second"), .end()],
        ])
        defer { harness.fixture.cleanup() }
        let first = try await questionCard(harness, question: "第一张？")
        let firstID = try cardID(first)
        let second = try await questionCard(harness, question: "第二张？")
        let secondID = try cardID(second)

        let answerExpired = try await harness.dispatcher.dispatch(
            BotUserAction(nonce: "answer-expired", botID: "main", kind: .cardAnswer,
                          cardID: firstID, optionID: "o0"))
        XCTAssertEqual(answerExpired, .stale(reason: "card_expired"))
        let dismissExpired = try await harness.dispatcher.dispatch(
            BotUserAction(nonce: "dismiss-expired", botID: "main", kind: .cardDismiss, cardID: firstID))
        XCTAssertEqual(dismissExpired, .stale(reason: "card_expired"))
        let opened = try await harness.dispatcher.dispatch(
            BotUserAction(nonce: "answer-open", botID: "main", kind: .cardAnswer,
                          cardID: secondID, optionID: "o1"))
        XCTAssertEqual(opened.status, "accepted")
    }

    func testCardAnswerWithTextIsRejectedByValidationAndDecoder() async throws {
        let harness = try await makeHarness()
        defer { harness.fixture.cleanup() }
        let card = try await questionCard(harness)
        let rejected = try await harness.dispatcher.dispatch(
            BotUserAction(nonce: "answer-text", botID: "main", kind: .cardAnswer,
                          text: "自定义回答", cardID: try cardID(card), optionID: "o0"))
        XCTAssertEqual(rejected, .rejected(reason: "unexpected_card_answer_field"))
        XCTAssertEqual(harness.transport?.promptHistory.count, 0)

        let data = try JSONSerialization.data(withJSONObject: [
            "nonce": "answer-text-wire", "botID": "main", "kind": "cardAnswer",
            "cardID": "card-1", "optionID": "o0", "text": "自定义回答",
        ])
        XCTAssertThrowsError(try JSONDecoder().decode(BotUserAction.self, from: data))
        let custom = try JSONSerialization.data(withJSONObject: [
            "nonce": "answer-custom-wire", "botID": "main", "kind": "cardAnswer",
            "cardID": "card-1", "optionID": "o0", "customText": "自定义回答",
        ])
        XCTAssertThrowsError(try JSONDecoder().decode(BotUserAction.self, from: custom))
    }

    func testChatAndCardAnswerUseDeterministicRequestIds() async throws {
        let harness = try await makeHarness(scripts: [
            [.turn(), .assistant("chat reply"), .end()],
            [.turn(2), .assistant("card reply"), .end(turn: 2)],
        ])
        defer { harness.fixture.cleanup() }
        let chat = try await harness.dispatcher.dispatch(
            BotUserAction(nonce: "chat-request", botID: "main", kind: .chat, text: "继续"))
        XCTAssertEqual(chat.status, "accepted")
        XCTAssertEqual(harness.transport?.promptRequestIds.last?.requestId,
                       "user-action:chat-request")

        let card = try await questionCard(harness)
        let answer = try await harness.dispatcher.dispatch(
            BotUserAction(nonce: "answer-request", botID: "main", kind: .cardAnswer,
                          cardID: try cardID(card), optionID: "o0"))
        XCTAssertEqual(answer.status, "accepted")
        XCTAssertEqual(harness.transport?.promptRequestIds.last?.requestId,
                       "card-answer:answer-request")
    }

    /// R1: the actor is re-entrant while resolving the durable card and while
    /// the remote turn runs. Two concurrent plans for the same card must start
    /// exactly one turn; the loser is stale before any side effect.
    func testConcurrentCardAnswersStartOnlyOneTurn() async throws {
        let harness = try await makeHarness(scripts: [
            [.turn(), .assistant("answered once"), .end()],
        ])
        defer { harness.fixture.cleanup() }
        let card = try await questionCard(harness)
        let cardID = try cardID(card)
        let first = BotUserAction(nonce: "concurrent-a", botID: "main", kind: .cardAnswer,
                                  cardID: cardID, optionID: "o0")
        let second = BotUserAction(nonce: "concurrent-b", botID: "main", kind: .cardAnswer,
                                   cardID: cardID, optionID: "o0")

        async let firstOutcome = harness.planner.plan(first, trust: .ownerDirect)
        async let secondOutcome = harness.planner.plan(second, trust: .ownerDirect)
        let outcomes = try await [firstOutcome, secondOutcome]

        var committed = 0
        var staleReasons: [String] = []
        for outcome in outcomes {
            switch outcome {
            case .commit: committed += 1
            case .stale(let reason): staleReasons.append(reason)
            case .rejected(let reason): XCTFail("unexpected rejection: \(reason)")
            }
        }
        XCTAssertEqual(committed, 1)
        XCTAssertEqual(staleReasons, ["answer_in_flight"])
        XCTAssertEqual(harness.transport?.promptHistory.count, 1)
    }
}
