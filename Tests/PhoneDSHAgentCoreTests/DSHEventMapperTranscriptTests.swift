// SPDX-License-Identifier: MIT
// PhoneDSHAgentCore transcript-mapping tests.
//
// G2-FIX-79 and G2-FIX-124: the scenario transcript must be able to rebuild
// the model-visible user input and the original DSH `turn/end` label from the
// mapped harness events alone. These fixtures are hand-built DSH session
// journal records, so the tests need no network, model, or Apple UI.

import Foundation
import XCTest
@testable import PhoneDSHAgentCore

final class DSHEventMapperTranscriptTests: XCTestCase {
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    // MARK: - G2-FIX-79: user-visible input

    func testUserMessageAndInboxSpliceMapNonEmptyInputWithOrderedSeqAndTime() throws {
        let user = DSHEventMapper.map(makeEvent(
            "user/message", seq: 3, time: 3_000,
            data: .object([
                "role": .string("user"),
                "id": .string("message-1"),
                "source": .object(["kind": .string("user")]),
                "content": .array([.object([
                    "type": .string("text"),
                    "text": .string("Run the transcript scenario."),
                ])]),
            ])))
        let spliced = DSHEventMapper.map(makeEvent(
            "agent/inbox/spliced", seq: 4, time: 4_000,
            data: .object([
                "target": .string("queued"),
                "start": .number(0),
                "inserted": .array([
                    .object([
                        "role": .string("user"),
                        "id": .string("message-2"),
                        "source": .object(["kind": .string("goal")]),
                        "content": .array([.object([
                            "type": .string("text"),
                            "text": .string("Continue the goal round."),
                        ])]),
                    ]),
                    .object([
                        "role": .string("user"),
                        "id": .string("message-3"),
                        "source": .object(["kind": .string("webhook")]),
                        "content": .array([.object([
                            "type": .string("text"),
                            "text": .string("A webhook supplied this prompt."),
                        ])]),
                    ]),
                ]),
            ])))

        XCTAssertEqual(user.count, 1)
        XCTAssertEqual(spliced.count, 1)
        let mapped = user + spliced

        guard case .userMessage(let userText, let userSource) = mapped[0].kind else {
            return XCTFail("user/message must map to a userMessage projection: \(mapped[0])")
        }
        XCTAssertEqual(userText, "Run the transcript scenario.")
        XCTAssertFalse(userText.isEmpty)
        XCTAssertEqual(userSource, "user")

        guard case .inboxSpliced(let inserted) = mapped[1].kind else {
            return XCTFail("agent/inbox/spliced must map to an inboxSpliced projection: \(mapped[1])")
        }
        XCTAssertEqual(inserted, [
            HarnessUserInput(text: "Continue the goal round.", source: "goal"),
            HarnessUserInput(text: "A webhook supplied this prompt.", source: "webhook"),
        ])
        XCTAssertTrue(inserted.allSatisfy { !$0.text.isEmpty })

        let seqs = mapped.compactMap(\.seq)
        XCTAssertEqual(seqs, [24, 32],
                       "DSH seq 3/4 part 0 keeps the harness sequence dense and ordered")
        XCTAssertEqual(mapped[0].time.timeIntervalSince1970, 3.0, accuracy: 0.000_001)
        XCTAssertEqual(mapped[1].time.timeIntervalSince1970, 4.0, accuracy: 0.000_001)
        XCTAssertEqual(seqs, seqs.sorted())

        // The transcript is JSONL of HarnessEvent values; every mapped user
        // projection must survive that round trip, not just the in-memory kind.
        let decoded = try roundTrip(mapped)
        XCTAssertEqual(decoded, mapped)
    }

    func testNonTextOnlyUserMessageDoesNotEmitAnEmptyInput() {
        let mapped = DSHEventMapper.map(makeEvent(
            "user/message", seq: 5, time: 1_005,
            data: .object([
                "role": .string("user"),
                "source": .object(["kind": .string("user")]),
                "content": .array([.object([
                    "type": .string("image"),
                    "mediaType": .string("image/png"),
                    "data": .string("AA=="),
                ])]),
            ])))
        XCTAssertTrue(mapped.isEmpty, "an image-only message has no text to reconstruct")
    }

    // MARK: - G2-FIX-124: raw turn/end labels

    func testInterruptedTurnEndKeepsRawKindWhileProjectingCancelled() throws {
        let end = try singleTurnEnd(reason: .object(["kind": .string("interrupted")]))

        XCTAssertEqual(end.kind, .turnEnded(turnID: "1", reason: .cancelled),
                       "the existing compatibility projection must not change")
        XCTAssertEqual(end.rawTurnEndKind, "interrupted")
        XCTAssertNil(end.rawTurnEndCause)

        let line = try transcriptLine(for: end)
        XCTAssertTrue(line.contains(#""rawTurnEndKind":"interrupted""#),
                      "the transcript line must show the original DSH label: \(line)")
        XCTAssertTrue(line.contains(#""cancelled""#),
                      "the compatibility projection remains visible beside the raw label: \(line)")
    }

    func testAbortedTurnEndKeepsRawKindAndCauseWhileProjectingCancelled() throws {
        let end = try singleTurnEnd(reason: .object([
            "kind": .string("aborted"),
            "reason": .object(["kind": .string("user")]),
        ]))

        XCTAssertEqual(end.kind, .turnEnded(turnID: "1", reason: .cancelled))
        XCTAssertEqual(end.rawTurnEndKind, "aborted")
        XCTAssertEqual(end.rawTurnEndCause, #"{"kind":"user"}"#,
                       "the abort cause is preserved as stable compact JSON")

        let line = try transcriptLine(for: end)
        XCTAssertTrue(line.contains(#""rawTurnEndKind":"aborted""#), line)
        XCTAssertTrue(line.contains(#""rawTurnEndCause":"{\"kind\":\"user\"}""#), line)
    }

    func testCompletedTurnEndAndLegacyTranscriptLineStillDecode() throws {
        let completed = try singleTurnEnd(reason: .object(["kind": .string("completed")]))
        XCTAssertEqual(completed.kind, .turnEnded(turnID: "1", reason: .completed))
        XCTAssertEqual(completed.rawTurnEndKind, "completed")
        XCTAssertNil(completed.rawTurnEndCause)

        // A transcript line written before the raw fields existed (the shape in
        // the checked-in scenario evidence) has neither key. It must still
        // decode, with both raw fields nil.
        let legacy = #"{"kind":{"turnEnded":{"reason":{"completed":{}},"turnID":"2"}},"seq":16,"time":"2024-01-01T00:00:00Z"}"#
        let decoded = try decoder.decode(HarnessEvent.self, from: Data(legacy.utf8))
        XCTAssertEqual(decoded.seq, 16)
        XCTAssertEqual(decoded.kind, .turnEnded(turnID: "2", reason: .completed))
        XCTAssertNil(decoded.rawTurnEndKind)
        XCTAssertNil(decoded.rawTurnEndCause)
    }

    func testUnknownTurnEndKindIsPreservedNotInvented() throws {
        let end = try singleTurnEnd(reason: .object(["kind": .string("paused-by-host")]))
        XCTAssertEqual(end.kind, .turnEnded(turnID: "1", reason: .failed("paused-by-host")))
        XCTAssertEqual(end.rawTurnEndKind, "paused-by-host")
    }

    // MARK: - Fixtures

    private func makeEvent(_ type: String, seq: Int, time: Int, data: JSONValue) -> JSONValue {
        .object([
            "type": .string(type),
            "seq": .number(Double(seq)),
            "time": .number(Double(time)),
            "data": data,
        ])
    }

    private func singleTurnEnd(reason: JSONValue) throws -> HarnessEvent {
        let mapped = DSHEventMapper.map(makeEvent(
            "turn/end", seq: 5, time: 1_005,
            data: .object(["turn": .number(1), "reason": reason])))
        XCTAssertEqual(mapped.count, 1)
        return try XCTUnwrap(mapped.first)
    }

    private func transcriptLine(for event: HarnessEvent) throws -> String {
        let data = try encoder.encode(event)
        return String(decoding: data, as: UTF8.self)
    }

    private func roundTrip(_ events: [HarnessEvent]) throws -> [HarnessEvent] {
        let lines = try events.map { event -> String in
            let data = try encoder.encode(event)
            return String(decoding: data, as: UTF8.self)
        }
        return try lines.map { try decoder.decode(HarnessEvent.self, from: Data($0.utf8)) }
    }
}
