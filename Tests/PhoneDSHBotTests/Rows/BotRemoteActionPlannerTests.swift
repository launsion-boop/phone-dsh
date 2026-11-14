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
        // The planner already committed the answer under this nonce, so the
        // dispatcher reports it as duplicate rather than writing a second event.
        let accepted = try await harness.dispatcher.dispatch(answer)
        XCTAssertEqual(accepted.status, "duplicate")
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
        XCTAssertEqual(stepsAccepted.status, "duplicate")
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
        XCTAssertEqual(opened.status, "duplicate")
    }

    /// The tap is committed *before* the reply it starts. On the device this was
    /// the whole delay: `card.answered` was only written after the turn's last
    /// frame, so the choice landed in the chat a minute after the tap and a
    /// backgrounded app lost it.
    func testCardAnswerIsDurableWhileTheTurnIsStillRunning() async throws {
        let harness = try await makeHarness(scripts: [
            [.turn(), .assistant("answered question"), .end()],
        ])
        defer { harness.fixture.cleanup() }
        let card = try await questionCard(harness)
        let cardID = try cardID(card)
        // Hold the turn open after `turn/start`: no assistant text and no
        // `turn/end` has been delivered yet.
        harness.transport?.pause("gb-main")
        defer { harness.transport?.resume("gb-main") }
        let action = BotUserAction(nonce: "answer-early", botID: "main", kind: .cardAnswer,
                                   cardID: cardID, optionID: "o0")
        let dispatch = Task { try await harness.dispatcher.dispatch(action) }

        let committed = try await Self.waitForEvent(in: harness.fixture.store, type: "card.answered")
        let answered = try XCTUnwrap(committed, "the answer must be durable before the turn ends")
        XCTAssertEqual(answered.eventId, "action:answer-early")
        XCTAssertEqual(answered.data["cardID"], .string(cardID))
        XCTAssertEqual(answered.data["optionID"], .string("o0"))
        XCTAssertEqual(answered.data["value"], .string("library"))
        // The turn id is not known yet, so the answer carries none. The turn's
        // own rows are the record of what happened next.
        XCTAssertNil(answered.turnId)
        XCTAssertEqual(harness.transport?.promptHistory.last?.text, "library")

        harness.transport?.resume("gb-main")
        // The answer was already recorded under this nonce, so the dispatcher
        // reports the same event instead of writing a second one.
        let outcome = try await dispatch.value
        XCTAssertEqual(outcome.status, "duplicate")
        XCTAssertEqual(outcome.eventID, "action:answer-early")
        let events = try await botEvents(harness.fixture.store)
        XCTAssertEqual(events.filter { $0.type == "card.answered" }.count, 1)
    }

    /// A failed delivery must not erase the recorded choice: the answer stays
    /// durable, the turn's failure is the action's status, and a replay of the
    /// same nonce never starts a second turn.
    func testFailedTurnAfterTheAnswerKeepsTheAnswerAndDoesNotReplay() async throws {
        let harness = try await makeHarness(scripts: [
            [.turn(), .end("failed")],
        ])
        defer { harness.fixture.cleanup() }
        let card = try await questionCard(harness)
        let cardID = try cardID(card)
        let action = BotUserAction(nonce: "answer-failed-turn", botID: "main", kind: .cardAnswer,
                                   cardID: cardID, optionID: "o1")
        let rejected = try await harness.dispatcher.dispatch(action)
        XCTAssertEqual(rejected.status, "rejected")
        let events = try await botEvents(harness.fixture.store)
        XCTAssertEqual(events.filter { $0.type == "card.answered" }.count, 1)
        XCTAssertEqual(harness.transport?.promptHistory.count, 1)

        let replay = try await harness.dispatcher.dispatch(action)
        XCTAssertEqual(replay.status, "duplicate")
        XCTAssertEqual(harness.transport?.promptHistory.count, 1)
    }

    /// The projection and the planner must read the same event stream: the card
    /// the page greys out (`status: superseded`) is exactly the card the planner
    /// refuses (`card_expired`), and only the newest one accepts a tap.
    func testProjectionAndPlannerAgreeOnWhichChoiceCardIsStale() async throws {
        let harness = try await makeHarness(scripts: [
            [.turn(), .assistant("answered second"), .end()],
        ])
        defer { harness.fixture.cleanup() }
        let first = try await questionCard(harness, question: "第一张？")
        let firstID = try cardID(first)
        let second = try await questionCard(harness, question: "第二张？")
        let secondID = try cardID(second)

        let events = try await botEvents(harness.fixture.store)
        let snapshot = BotSessionLogProjector().project(
            botID: "main", sessionID: "gb-main", sessionEvents: [], uiEvents: events)
        let firstRow = try XCTUnwrap(snapshot.rows.first { $0.id == firstID })
        XCTAssertEqual(firstRow.body["status"], .string("superseded"))
        XCTAssertEqual(firstRow.body["supersededBy"], .string(secondID))
        let secondRow = try XCTUnwrap(snapshot.rows.first { $0.id == secondID })
        XCTAssertNil(secondRow.body["status"], "the newest card is the one the user can tap")

        let stale = try await harness.dispatcher.dispatch(
            BotUserAction(nonce: "answer-stale", botID: "main", kind: .cardAnswer,
                          cardID: firstID, optionID: "o0"))
        XCTAssertEqual(stale, .stale(reason: "card_expired"))
        let newest = try await harness.dispatcher.dispatch(
            BotUserAction(nonce: "answer-newest", botID: "main", kind: .cardAnswer,
                          cardID: secondID, optionID: "o1"))
        XCTAssertEqual(newest.status, "duplicate")
        let after = try await botEvents(harness.fixture.store)
        XCTAssertEqual(after.filter {
            $0.type == "card.answered" && $0.data["cardID"] == .string(secondID)
        }.count, 1)
        XCTAssertFalse(after.contains {
            $0.type == "card.answered" && $0.data["cardID"] == .string(firstID)
        })
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
        XCTAssertEqual(answer.status, "duplicate")
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

    /// Polls the durable log until `type` appears. Used while a scripted turn is
    /// deliberately held open, so the assertion is about ordering, not timing.
    private static func waitForEvent(in store: SQLiteDomainStore, type: String,
                                     timeout: TimeInterval = 3) async throws -> BotEvent? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let event = try await botEvents(store).first(where: { $0.type == type }) {
                return event
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        return nil
    }
}
