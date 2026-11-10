// SPDX-License-Identifier: MIT

import XCTest
@testable import PhoneDSHBot

final class BotFishReactionTests: XCTestCase {
    private let now: Int64 = 12_000

    func testUpstreamVocabularyAndDurations() {
        XCTAssertEqual(BotFishReactionVocabulary.actions, [
            "waving", "bowing", "clapping", "kiss", "cheering", "shy", "smug", "crying",
            "sighing", "shaking-head", "stretching", "yawning", "high-five", "nod",
            "celebrate", "dancing",
        ])
        XCTAssertEqual(BotFishReactionVocabulary.expressions, [
            "happy", "sad", "surprised", "confused", "laughing", "love", "angry", "wink",
        ])
        XCTAssertEqual(BotFishReactionVocabulary.kind(for: "waving"), .action)
        XCTAssertEqual(BotFishReactionVocabulary.kind(for: "happy"), .expression)
        XCTAssertNil(BotFishReactionVocabulary.kind(for: "moonwalk"))
        XCTAssertEqual(BotFishReactionVocabulary.durationMs(for: "waving"), 1_600)
        XCTAssertEqual(BotFishReactionVocabulary.durationMs(for: "dancing"), 1_800)
        XCTAssertEqual(BotFishReactionVocabulary.durationMs(for: "yawning"), 4_800)
        XCTAssertEqual(BotFishReactionVocabulary.durationMs(for: "happy"),
                       BotFishReactionVocabulary.expressionDurationMs)
        XCTAssertEqual(BotFishReactionVocabulary.expressionDurationMs, 4_000)
    }

    func testActionPlaysOneClipPeriodAndThenEnds() throws {
        let reaction = try XCTUnwrap(BotFishReaction.reaction(
            from: BotFishToolCall(id: "call-1", botID: "main", name: "mcp__phone__FishAction",
                                  arguments: .object(["action": .string("bowing")]),
                                  time: now),
            now: now))
        XCTAssertEqual(reaction.id, "call-1")
        XCTAssertEqual(reaction.botID, "main")
        XCTAssertEqual(reaction.kind, .action)
        XCTAssertEqual(reaction.name, "bowing")
        XCTAssertEqual(reaction.startedAt, now)
        XCTAssertEqual(reaction.durationMs, 2_800)
        XCTAssertEqual(reaction.endsAt, now + 2_800)
        XCTAssertEqual(reaction.lifecycle, .bowing)
        XCTAssertTrue(reaction.isActive(at: now + 2_799))
        XCTAssertFalse(reaction.isActive(at: now + 2_800))
    }

    func testExpressionOnlyChangesTheFaceForFourSeconds() throws {
        let reaction = try XCTUnwrap(BotFishReaction.reaction(
            from: BotFishToolCall(id: "call-2", name: "FishAction",
                                  arguments: .object(["action": .string("love")]),
                                  time: 0),
            now: now))
        XCTAssertEqual(reaction.kind, .expression)
        XCTAssertEqual(reaction.name, "love")
        XCTAssertEqual(reaction.startedAt, now)
        XCTAssertEqual(reaction.durationMs, 4_000)
        XCTAssertEqual(reaction.endsAt, now + 4_000)
        XCTAssertEqual(reaction.lifecycle, .love)
    }

    func testArgumentsMayArriveAsTheSessionLogJSONString() throws {
        let encoded = try JSONEncoder().encode(BotJSONValue.object(["action": .string("nod")]))
        let arguments = BotJSONValue.string(String(decoding: encoded, as: UTF8.self))
        let reaction = try XCTUnwrap(BotFishReaction.reaction(
            from: BotFishToolCall(id: "call-3", name: "FishAction",
                                  arguments: arguments, time: now)))
        XCTAssertEqual(reaction.name, "nod")
        XCTAssertEqual(reaction.kind, .action)
    }

    func testUnknownActionAndOtherToolsAreIgnored() {
        XCTAssertNil(BotFishReaction.reaction(from: BotFishToolCall(
            id: "call-4", name: "FishAction",
            arguments: .object(["action": .string("moonwalk")]), time: now)))
        XCTAssertNil(BotFishReaction.reaction(from: BotFishToolCall(
            id: "call-5", name: "FishAction", arguments: .object([:]), time: now)))
        XCTAssertNil(BotFishReaction.reaction(from: BotFishToolCall(
            id: "call-6", name: "SendToUser",
            arguments: .object(["action": .string("happy")]), time: now)))
    }

    func testReactionCanBeBuiltFromEitherRealEventSource() throws {
        let session = BotDSHSessionEvent(
            type: "tool/call", seq: 42, time: now,
            data: [
                "name": .string("mcp__phone__FishAction"),
                "callId": .string("session-call"),
                "arguments": .string(#"{"action":"waving"}"#),
            ],
            eventID: "dsh-event-1")
        let sessionReaction = try XCTUnwrap(BotFishReaction.reaction(
            from: XCTUnwrap(BotFishToolCall(sessionEvent: session))))
        XCTAssertEqual(sessionReaction.id, "dsh-event-1")
        XCTAssertEqual(sessionReaction.name, "waving")

        let event = BotEvent(
            type: "conversation.tool_call", eventId: "bot-event-1", time: now,
            origin: .local(source: "runtime"), traceId: "trace-1",
            principal: BotPrincipal(botId: "main", sessionId: "gb-main", kind: "chat"),
            causationId: nil, correlationId: nil,
            data: .object([
                "name": .string("FishAction"),
                "callId": .string("bot-call"),
                "arguments": .object(["action": .string("wink")]),
            ]))
        let toolCall = try XCTUnwrap(BotFishToolCall(botEvent: event))
        let botReaction = try XCTUnwrap(BotFishReaction.reaction(from: toolCall))
        XCTAssertEqual(botReaction.id, "bot-event-1")
        XCTAssertEqual(botReaction.botID, "main")
        XCTAssertEqual(botReaction.name, "wink")
        XCTAssertEqual(botReaction.kind, .expression)
    }

    func testFallbackIDIsStableWhenTheEventHasNoID() throws {
        let call = BotFishToolCall(
            id: "", botID: "bot-b", name: "FishAction",
            arguments: .object(["action": .string("celebrate")]), time: 7)
        let first = try XCTUnwrap(BotFishReaction.reaction(from: call))
        let second = try XCTUnwrap(BotFishReaction.reaction(from: call))
        XCTAssertEqual(first.id, second.id)
        XCTAssertEqual(first.id, "bot-b:7:celebrate")
    }
}
