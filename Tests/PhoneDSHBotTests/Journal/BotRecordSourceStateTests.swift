// SPDX-License-Identifier: MIT

import CryptoKit
import XCTest
@testable import PhoneDSHBot

/// P lane (G-1): every observation must expose a real `content-sha256` of the
/// source's readable text; non-observation records carry no source version;
/// erased/unresolved records are explained by the provenance state instead of
/// an invented digest.
final class BotRecordSourceStateTests: XCTestCase {
    private var root: URL!
    private var store: SQLiteDomainStore!
    private var gateway: BotGateway!
    private var service: BotRecordService!

    private let userTime: Int64 = 1_760_000_003_000
    private let observationTime: Int64 = 1_760_000_005_000
    private let observationText = "Example Domain"
    private let userRef = "record://session/gb-main#3"
    private let observationRef = "record://session/gb-main#5"

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("bot-record-source-\(UUID().uuidString)", isDirectory: true)
        for session in ["gb-main", "gb-other"] {
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent("materialized/home/sessions/\(session)", isDirectory: true),
                withIntermediateDirectories: true)
        }
        store = try SQLiteDomainStore(
            fileURL: root.appendingPathComponent("domain.sqlite"), now: { 1_000 })
        gateway = BotGateway(now: { 1_000 })
        try await gateway.issueSession(botId: "bot-a", sessionId: "gb-main", kind: .chat)
        try await gateway.issueSession(botId: "bot-b", sessionId: "gb-other", kind: .chat)
        service = BotRecordService(
            store: store, gateway: gateway, workspaceRoot: root, now: { 1_000 })
    }

    override func tearDown() async throws {
        try? await store?.close()
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    func testObservationVersionIsContentSHA256OfReadableText() async throws {
        try writeSessionLog()
        try await appendToolCallEvent()
        let states = try await service.sourceStates(
            for: [observationRef, " " + observationRef + " "],
            callerBotID: "bot-a", callerSessionID: "gb-main")
        XCTAssertEqual(states.count, 1, "canonical duplicates collapse to one entry")
        let state = try XCTUnwrap(states.first)
        XCTAssertEqual(state.ref, observationRef)
        XCTAssertTrue(state.resolved)
        XCTAssertFalse(state.erased)
        XCTAssertEqual(state.observedAtMS, observationTime)
        XCTAssertEqual(state.recordType, "tool/result")
        XCTAssertEqual(state.trust, .observation)
        let version = try XCTUnwrap(state.version?.known)
        XCTAssertEqual(version.kind, .contentSHA256)
        XCTAssertEqual(version.value, "sha256:" + sha256Hex(observationText))
        XCTAssertEqual(version.observedAtMS, observationTime)
        XCTAssertEqual(version.basisRef, observationRef)
        XCTAssertEqual(version.subject, .recordText,
                       "a readable-text digest must be marked record-text")

        let again = try await service.sourceStates(
            for: [observationRef], callerBotID: "bot-a", callerSessionID: "gb-main")
        XCTAssertEqual(try XCTUnwrap(again.first).version, state.version,
                       "the same immutable record must resolve to the same digest")
    }

    func testNonObservationRecordCarriesNoSourceVersion() async throws {
        try writeSessionLog()
        try await appendToolCallEvent()
        let states = try await service.sourceStates(
            for: [userRef], callerBotID: "bot-a", callerSessionID: "gb-main")
        let state = try XCTUnwrap(states.first)
        XCTAssertTrue(state.resolved)
        XCTAssertEqual(state.trust, .user)
        XCTAssertNil(state.version,
                     "G-1 §2.2: a user message may omit sourceVersion")
    }

    func testEnvelopeBodyIsDigestedWithoutTheHeader() async throws {
        let envelope = try XCTUnwrap(BotObservationEnvelope(
            source: "web", origin: "https://example.com/a", at: "2026-11-11T07:00:00.000Z",
            owner: "unknown", reference: BotRecordReference.session(sessionID: "gb-main", seq: 5),
            text: observationText))
        try writeSessionLog(toolResultText: envelope.encoded())
        try await appendToolCallEvent()
        let states = try await service.sourceStates(
            for: [observationRef], callerBotID: "bot-a", callerSessionID: "gb-main")
        let version = try XCTUnwrap(try XCTUnwrap(states.first).version?.known)
        XCTAssertEqual(version.value, "sha256:" + sha256Hex(observationText),
                       "the envelope header is not part of the source's readable text")
    }

    func testEventObservationVersionMatchesReadableText() async throws {
        try writeSessionLog()
        try await appendToolCallEvent()
        let sequence = try await appendEvent(
            type: "conversation.tool_result", botID: "bot-a", sessionID: "gb-main",
            originSeq: 7, data: .object([
                "message": .object([
                    "toolCallId": .string("call-1"),
                    "content": .array([.object([
                        "type": .string("text"),
                        "text": .string(observationText),
                    ])]),
                ]),
            ]))
        let reference = "record://event/\(sequence)"
        let states = try await service.sourceStates(
            for: [reference], callerBotID: "bot-a", callerSessionID: "gb-main")
        let state = try XCTUnwrap(states.first)
        XCTAssertEqual(state.trust, .observation)
        let version = try XCTUnwrap(state.version?.known)
        XCTAssertEqual(version.kind, .contentSHA256)
        XCTAssertEqual(version.value, "sha256:" + sha256Hex(observationText))
        XCTAssertEqual(version.basisRef, reference)
    }

    func testEvidenceSnapshotKeepsItsShapeAndCarriesTheObservationVersion() async throws {
        try writeSessionLog()
        try await appendToolCallEvent()
        let snapshot = try await service.evidenceSnapshot(
            for: [observationRef], callerBotID: "bot-a", callerSessionID: "gb-main")
        let point = try XCTUnwrap(snapshot.point(for: observationRef))
        XCTAssertTrue(point.resolved)
        XCTAssertEqual(point.observedAtMS, observationTime)
        XCTAssertEqual(point.version?.known?.kind, .contentSHA256)
        let userPoint = try await service.evidenceSnapshot(
            for: [userRef], callerBotID: "bot-a", callerSessionID: "gb-main")
            .point(for: userRef)
        XCTAssertNil(userPoint?.version)
    }

    func testErasedSessionObservationHasNoVersion() async throws {
        try writeSessionLog()
        try await appendToolCallEvent()
        let tombstone = try BotSessionErasureTombstone.line(
            sessionID: "gb-main", seq: 5, time: observationTime, erasureID: "erasure-test")
        try writeLog(sessionID: "gb-main", lines: [
            headerLine(), userLine(),
            toolCallLine(),
            String(decoding: tombstone, as: UTF8.self),
        ])
        let states = try await service.sourceStates(
            for: [observationRef], callerBotID: "bot-a", callerSessionID: "gb-main")
        let state = try XCTUnwrap(states.first)
        XCTAssertTrue(state.resolved, "an erased record still resolves")
        XCTAssertTrue(state.erased)
        XCTAssertEqual(state.observedAtMS, observationTime)
        XCTAssertNil(state.version)
    }

    func testErasedEventObservationHasNoVersion() async throws {
        try writeSessionLog()
        try await appendToolCallEvent()
        let sequence = try await appendEvent(
            type: "conversation.tool_result", botID: "bot-a", sessionID: "gb-main",
            originSeq: 8, data: .object([
                "message": .object([
                    "toolCallId": .string("call-1"),
                    "content": .array([.object([
                        "type": .string("text"), "text": .string("erase me"),
                    ])]),
                ]),
            ]))
        let erasure = BotErasureEventData(
            erasureId: "source-state-erasure",
            reason: "memory-path-erase",
            atMS: 1_760_000_000_700,
            targets: [BotErasureEventData.Target(
                kind: "memory", scope: "agent", path: "agent/notes/unrelated.md")])
        let event = BotEvent(
            type: "erasure", eventId: "source-state-erasure", time: 1_760_000_000_700,
            origin: .local(source: "user"), traceId: "source-state-erasure",
            principal: BotPrincipal(botId: "bot-a", sessionId: "gb-main", kind: "chat"),
            causationId: nil, correlationId: nil,
            data: try BotJSONValue.parse(JSONEncoder().encode(erasure)))
        _ = try await store.erasePayloads(
            [sequence], erasureEvent: event, atMS: 1_760_000_000_700)
        let states = try await service.sourceStates(
            for: ["record://event/\(sequence)"], callerBotID: "bot-a",
            callerSessionID: "gb-main")
        let state = try XCTUnwrap(states.first)
        XCTAssertTrue(state.resolved, "an erased event still resolves")
        XCTAssertTrue(state.erased)
        XCTAssertNil(state.version)
    }

    func testContextObservedCarriesItsStructuredSourceVersion() async throws {
        let sequence = try await appendEvent(
            type: "context.observed", botID: "bot-a", sessionID: nil,
            originSeq: 9, ignorable: true, data: .object([
                "schema": .string("bot-context-observed/v1"),
                "source": .string("calendar"),
                "kind": .string("event"),
                "observed_at_ms": .number(1_760_000_009_000),
                "owner_bot_id": .string("bot-a"),
                "consent_generation": .number(1),
                "source_version": .object([
                    "basis": .string("etag"),
                    "value": .string("etag:calendar-1"),
                    "observed_at_ms": .number(1_760_000_009_000),
                ]),
                "payload": .object(["title": .string("Standup")]),
                "dedupe_key": .string("calendar:standup"),
                "delivery": .string("would"),
                "wake_requested": .bool(false),
            ]))
        let reference = "record://event/\(sequence)"
        let states = try await service.sourceStates(
            for: [reference], callerBotID: "bot-a", callerSessionID: "gb-main")
        let state = try XCTUnwrap(states.first)
        XCTAssertEqual(state.recordType, "context.observed")
        XCTAssertEqual(state.trust, .observation)
        XCTAssertEqual(state.observedAtMS, 1_760_000_009_000)
        let version = try XCTUnwrap(state.version?.known)
        XCTAssertEqual(version.kind, .etag)
        XCTAssertEqual(version.value, "etag:calendar-1")
        XCTAssertEqual(version.basisRef, reference)
        XCTAssertNil(version.subject, "native bases do not carry a content subject")
    }

    func testToolResultEnvelopeWithoutADurableCallIsAnObservation() async throws {
        let envelope = try XCTUnwrap(BotObservationEnvelope(
            source: "web", origin: "https://example.com/a",
            at: "2026-11-11T07:00:00.000Z", owner: "unknown",
            reference: BotRecordReference.event(commitSeq: 999),
            text: observationText))
        let sequence = try await appendEvent(
            type: "conversation.tool_result", botID: "bot-a", sessionID: "gb-main",
            originSeq: 10, data: .object([
                "message": .object([
                    "toolCallId": .string("call-missing"),
                    "content": .array([.object([
                        "type": .string("text"),
                        "text": .string(envelope.encoded()),
                    ])]),
                ]),
            ]))
        let reference = "record://event/\(sequence)"
        let states = try await service.sourceStates(
            for: [reference], callerBotID: "bot-a", callerSessionID: "gb-main")
        let state = try XCTUnwrap(states.first)
        XCTAssertEqual(state.trust, .observation,
                       "the envelope itself is the structural observation marker")
        XCTAssertEqual(state.version?.known?.value,
                       "sha256:" + sha256Hex(observationText))
    }

    func testUnresolvedReferencesHaveNoVersion() async throws {
        try writeSessionLog()
        try writeLog(sessionID: "gb-other", lines: [headerLine(sessionID: "gb-other")])
        let foreign = "record://session/gb-other#0"
        let missing = "record://session/gb-main#99"
        let invalid = "not-a-record"

        let states = try await service.sourceStates(
            for: [foreign, missing, invalid], callerBotID: "bot-a",
            callerSessionID: "gb-main")
        XCTAssertEqual(states.map(\.ref), [foreign, missing, invalid])
        XCTAssertEqual(states.map(\.resolved), [false, false, false])
        XCTAssertEqual(states.map(\.version), [nil, nil, nil])
        XCTAssertNil(states[0].observedAtMS)
        XCTAssertNil(states[0].trust)
    }

    func testBatchPreservesFirstSeenOrderAndRejectsOverTheCeiling() async throws {
        try writeSessionLog()
        try await appendToolCallEvent()
        let sequence = try await appendEvent(
            type: "conversation.assistant_message", botID: "bot-a", sessionID: "gb-main",
            originSeq: 9, data: .object(["text": .string("noted")]))
        let second = "record://event/\(sequence)"
        let states = try await service.sourceStates(
            for: [observationRef, second, observationRef],
            callerBotID: "bot-a", callerSessionID: "gb-main")
        XCTAssertEqual(states.map(\.ref), [observationRef, second])

        let tooMany = (0..<513).map { "record://session/gb-main#\($0)" }
        do {
            _ = try await service.sourceStates(
                for: tooMany, callerBotID: "bot-a", callerSessionID: "gb-main")
            XCTFail("513 distinct references must be rejected")
        } catch let error as BotRecordServiceError {
            XCTAssertEqual(error, .invalidArguments)
        }
    }

    func testSourceStateJSONKeepsKnownAndUnknownMutuallyExclusive() throws {
        let known = BotSourceState(
            ref: observationRef, resolved: true, erased: false,
            observedAtMS: observationTime, recordType: "tool/result", trust: .observation,
            version: .known(BotKnownSourceVersion(
                kind: .contentSHA256, value: "sha256:abc", observedAtMS: observationTime,
                basisRef: observationRef)))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let knownData = try encoder.encode(known)
        let knownObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: knownData) as? [String: Any])
        let knownVersion = try XCTUnwrap(knownObject["version"] as? [String: Any])
        XCTAssertEqual(knownVersion["basis"] as? String, "content-sha256")
        XCTAssertEqual(knownVersion["value"] as? String, "sha256:abc")
        XCTAssertEqual((knownVersion["observed_at_ms"] as? NSNumber)?.int64Value, observationTime)
        XCTAssertEqual(knownVersion["basis_ref"] as? String, observationRef)
        XCTAssertNil(knownVersion["reason"])
        XCTAssertEqual(try JSONDecoder().decode(BotSourceState.self, from: knownData), known)

        let unknown = BotSourceState(
            ref: "record://event/9", resolved: true, erased: false,
            observedAtMS: nil, recordType: "tool/result", trust: .observation,
            version: .unknown(.recordWithoutContent))
        let unknownData = try encoder.encode(unknown)
        let unknownObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: unknownData) as? [String: Any])
        let unknownVersion = try XCTUnwrap(unknownObject["version"] as? [String: Any])
        XCTAssertEqual(unknownVersion["reason"] as? String, "record-without-content")
        XCTAssertNil(unknownVersion["basis"])
        XCTAssertTrue(unknownObject["observed_at_ms"] is NSNull)
        XCTAssertEqual(try JSONDecoder().decode(BotSourceState.self, from: unknownData), unknown)

        let nonObservation = BotSourceState(
            ref: userRef, resolved: true, erased: false,
            observedAtMS: userTime, recordType: "user/message", trust: .user,
            version: nil)
        let nonObservationData = try encoder.encode(nonObservation)
        let nonObservationObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: nonObservationData) as? [String: Any])
        XCTAssertNil(nonObservationObject["version"],
                     "non-observation records omit the optional version member")
        XCTAssertEqual(try JSONDecoder().decode(BotSourceState.self, from: nonObservationData),
                       nonObservation)

        let mixed = Data(#"{"basis":"content-sha256","value":"sha256:abc","reason":"record-erased"}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(BotSourceVersion.self, from: mixed),
                             "a version cannot be known and unknown at once")
    }

    func testWriteTimeBaselinesCoverObservationAndHintOnlyRefs() async throws {
        try writeSessionLog()
        try await appendToolCallEvent()
        let states = try await service.sourceStates(
            for: [observationRef, userRef], callerBotID: "bot-a", callerSessionID: "gb-main")
        let baselines = try BotSourceBaselineBuilder.baselines(
            evidence: [observationRef, userRef, observationRef],
            reviewRefs: [observationRef],
            states: states)
        XCTAssertEqual(baselines.map(\.record), [observationRef, userRef, observationRef],
                       "roles keep the observation and user evidence distinct")
        XCTAssertEqual(baselines.map(\.role), [.evidence, .evidence, .review])
        XCTAssertEqual(baselines[0].sourceVersion?.known?.value,
                       "sha256:" + sha256Hex(observationText))
        XCTAssertNil(baselines[1].sourceVersion,
                     "a user message is not an observation and carries no sourceVersion")

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(baselines)
        let array = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        XCTAssertEqual(array.count, 3)
        XCTAssertEqual(array[0]["record"] as? String, observationRef)
        XCTAssertEqual(array[0]["role"] as? String, "evidence")
        let known = try XCTUnwrap(array[0]["sourceVersion"] as? [String: Any])
        XCTAssertEqual(known["basis"] as? String, "content-sha256")
        XCTAssertEqual(known["value"] as? String, "sha256:" + sha256Hex(observationText))
        XCTAssertNil(array[1]["sourceVersion"])
        XCTAssertEqual(array[2]["role"] as? String, "review")
        XCTAssertEqual(try JSONDecoder().decode([BotSourceBaseline].self, from: data), baselines)

        do {
            _ = try BotSourceBaselineBuilder.baselines(
                for: ["record://event/404"], states: [])
            XCTFail("a missing resolver state must not be papered over")
        } catch let error as BotSourceBaselineError {
            XCTAssertEqual(error, .missingState("record://event/404"))
        }
    }

    func testUnknownVersionReasonVocabulary() {
        XCTAssertEqual(BotSourceVersionUnknownReason.recordUnresolved.rawValue, "record-unresolved")
        XCTAssertEqual(BotSourceVersionUnknownReason.recordErased.rawValue, "record-erased")
        XCTAssertEqual(BotSourceVersionUnknownReason.recordWithoutContent.rawValue, "record-without-content")
        XCTAssertEqual(BotSourceVersionUnknownReason.sourceUnversioned.rawValue, "source-unversioned")
        XCTAssertEqual(BotSourceVersionUnknownReason.invalidReference.rawValue, "invalid-reference")
        XCTAssertNil(BotSourceVersion.known(BotKnownSourceVersion(
            kind: .contentSHA256, value: "sha256:00", observedAtMS: 1, basisRef: nil)).unknownReason)
        XCTAssertEqual(BotSourceVersion.unknown(.recordErased).known, nil)
    }

    // MARK: - Helpers

    private func sha256Hex(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func headerLine(sessionID: String = "gb-main") -> String {
        let header: [String: Any] = [
            "type": "session", "version": 4, "id": sessionID,
            "createdAt": 1_760_000_000_000, "isSeeded": false, "delegationDepth": 0,
        ]
        return String(decoding: try! JSONSerialization.data(
            withJSONObject: header, options: [.sortedKeys]), as: UTF8.self)
    }

    private func userLine() -> String {
        let event: [String: Any] = [
            "type": "user/message", "seq": 3, "time": userTime,
            "data": [
                "message": ["role": "user", "content": [
                    ["type": "text", "text": "remember AMBER_9"]]],
                "source": ["kind": "user", "rpcId": "bot-1"],
            ],
        ]
        return String(decoding: try! JSONSerialization.data(
            withJSONObject: event, options: [.sortedKeys]), as: UTF8.self)
    }

    private func toolCallLine() -> String {
        let event: [String: Any] = [
            "type": "tool/call", "seq": 4, "time": 1_760_000_004_000,
            "data": ["callId": "call-1", "name": "web_fetch",
                     "arguments": "{\"url\":\"https://example.com/a\"}"],
        ]
        return String(decoding: try! JSONSerialization.data(
            withJSONObject: event, options: [.sortedKeys]), as: UTF8.self)
    }

    private func toolResultLine(text: String) -> String {
        let event: [String: Any] = [
            "type": "tool/result", "seq": 5, "time": observationTime,
            "data": [
                "message": ["role": "tool", "toolCallId": "call-1",
                            "content": [["type": "text", "text": text]],
                            "isError": false],
                "source": ["kind": "tool", "callId": "call-1"],
            ],
        ]
        return String(decoding: try! JSONSerialization.data(
            withJSONObject: event, options: [.sortedKeys]), as: UTF8.self)
    }

    private func writeSessionLog(toolResultText: String? = nil) throws {
        try writeLog(sessionID: "gb-main", lines: [
            headerLine(), userLine(), toolCallLine(),
            toolResultLine(text: toolResultText ?? observationText),
        ])
    }

    private func writeLog(sessionID: String, lines: [String]) throws {
        let url = root.appendingPathComponent(
            "materialized/home/sessions/\(sessionID)/session.v4.jsonl")
        try (lines.joined(separator: "\n") + "\n")
            .write(to: url, atomically: true, encoding: .utf8)
    }

    private func appendToolCallEvent() async throws {
        _ = try await appendEvent(
            type: "conversation.tool_call", botID: "bot-a", sessionID: "gb-main",
            originSeq: 4, data: .object([
                "callId": .string("call-1"),
                "name": .string("web_fetch"),
                "arguments": .string("{\"url\":\"https://example.com/a\"}"),
            ]))
    }

    private func appendEvent(type: String, botID: String, sessionID: String?,
                             originSeq: Int, ignorable: Bool = false,
                             data: BotJSONValue) async throws -> Int {
        let event = BotEvent(
            type: type, eventId: "\(type):\(sessionID ?? "none"):\(originSeq):\(UUID().uuidString)",
            time: 1_760_000_000_000 + Int64(originSeq),
            origin: sessionID.map { .dsh(sessionId: $0, seq: originSeq) } ?? .local(source: "runtime"),
            traceId: "trace:\(sessionID ?? "none"):\(originSeq)",
            principal: BotPrincipal(botId: botID, sessionId: sessionID, kind: "chat"),
            causationId: nil, correlationId: sessionID, ignorable: ignorable ? true : nil, data: data)
        return try await store.append(event)
    }
}
