// SPDX-License-Identifier: MIT

import CryptoKit
import XCTest
@testable import PhoneDSHBot

/// P lane: bridge record facts into L's provenance resolver without copying
/// L's identity/current logic. P supplies only resolved/erased/time/type/trust
/// and the observation source version.
final class BotRecordProvenanceFactTests: XCTestCase {
    private var root: URL!
    private var store: SQLiteDomainStore!
    private var gateway: BotGateway!
    private var service: BotRecordService!

    private let observationText = "Example Domain"
    private let observationTime: Int64 = 1_760_000_005_000
    private let observationRef = "record://session/gb-main#5"
    private let userRef = "record://session/gb-main#3"

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("provenance-facts-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("materialized/home/sessions/gb-main", isDirectory: true),
            withIntermediateDirectories: true)
        try writeSessionLog()
        store = try SQLiteDomainStore(
            fileURL: root.appendingPathComponent("domain.sqlite"), now: { 1_000 })
        gateway = BotGateway(now: { 1_000 })
        try await gateway.issueSession(botId: "bot-a", sessionId: "gb-main", kind: .chat)
        service = BotRecordService(
            store: store, gateway: gateway, workspaceRoot: root, now: { 1_000 })
        _ = try await store.append(BotEvent(
            type: "conversation.tool_call",
            eventId: "conversation.tool_call:\(UUID().uuidString)", time: 1_000,
            origin: .local(source: "runtime"), traceId: "trace-\(UUID().uuidString)",
            principal: BotPrincipal(botId: "bot-a", sessionId: "gb-main", kind: "chat"),
            causationId: nil, correlationId: "gb-main",
            data: .object([
                "callId": .string("call-1"),
                "name": .string("web_fetch"),
                "arguments": .string("{\"url\":\"https://example.com/a\"}"),
            ])))
    }

    override func tearDown() async throws {
        try? await store?.close()
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    func testSourceFactsMapObservationAndNonObservationRecords() async throws {
        let facts = await service.sourceFacts(
            for: [observationRef, userRef, "record://session/gb-main#99"],
            botID: "bot-a", sessionID: "gb-main")
        XCTAssertEqual(facts.count, 3)

        let observation = try XCTUnwrap(facts[observationRef])
        XCTAssertTrue(observation.resolved)
        XCTAssertFalse(observation.erased)
        XCTAssertEqual(observation.observedAtMS, observationTime)
        XCTAssertEqual(observation.recordType, "tool/result")
        XCTAssertEqual(observation.trust, "observation")
        guard case let .known(basis, value, at, basisRef) = try XCTUnwrap(observation.version) else {
            return XCTFail("observation must carry a known version")
        }
        XCTAssertEqual(basis, .contentSHA256)
        XCTAssertEqual(value, "sha256:" + sha256Hex(observationText))
        XCTAssertEqual(at, observationTime)
        XCTAssertEqual(basisRef, observationRef)

        let user = try XCTUnwrap(facts[userRef])
        XCTAssertTrue(user.resolved)
        XCTAssertEqual(user.trust, "user")
        XCTAssertNil(user.version)

        let missing = try XCTUnwrap(facts["record://session/gb-main#99"])
        XCTAssertFalse(missing.resolved)
        XCTAssertFalse(missing.erased)
        XCTAssertNil(missing.version)
    }

    func testSourceFactsMatchTheStateResolver() async throws {
        let states = try await service.sourceStates(
            for: [observationRef, userRef], callerBotID: "bot-a", callerSessionID: "gb-main")
        let facts = await service.sourceFacts(
            for: [observationRef, userRef], botID: "bot-a", sessionID: "gb-main")
        for state in states {
            let fact = try XCTUnwrap(facts[state.ref])
            XCTAssertEqual(fact.resolved, state.resolved)
            XCTAssertEqual(fact.erased, state.erased)
            XCTAssertEqual(fact.observedAtMS, state.observedAtMS)
            XCTAssertEqual(fact.recordType, state.recordType)
            XCTAssertEqual(fact.trust, state.trust?.rawValue)
            XCTAssertEqual(fact.version?.knownValue, state.version?.known?.value)
        }
    }

    func testErasedRecordFactCarriesErasedFlagAndNoVersion() async throws {
        let tombstone = try BotSessionErasureTombstone.line(
            sessionID: "gb-main", seq: 5, time: observationTime, erasureID: "fact-test")
        try writeSessionLog(tombstone: tombstone)
        let facts = await service.sourceFacts(
            for: [observationRef], botID: "bot-a", sessionID: "gb-main")
        let fact = try XCTUnwrap(facts[observationRef])
        XCTAssertTrue(fact.resolved, "an erased record still resolves")
        XCTAssertTrue(fact.erased)
        XCTAssertNil(fact.version)
    }

    func testContextObservedResolvesFromOwnerOnlyFacts() async throws {
        let sequence = try await store.append(BotEvent(
            type: "context.observed",
            eventId: "context-observed:owner-only:\(UUID().uuidString)", time: 1_760_000_009_000,
            origin: .local(source: "runtime"), traceId: "trace-context",
            principal: BotPrincipal(botId: "bot-a", sessionId: nil, kind: "proactive"),
            causationId: nil, correlationId: "calendar:standup", ignorable: true,
            data: .object([
                "schema": .string("bot-context-observed/v1"),
                "source": .string("calendar"),
                "kind": .string("event"),
                "observed_at_ms": .number(1_760_000_009_000),
                "owner_bot_id": .string("bot-a"),
                "source_version": .object([
                    "basis": .string("etag"),
                    "value": .string("etag:calendar-1"),
                    "observed_at_ms": .number(1_760_000_009_000),
                ]),
                "resource": .object([
                    "kind": .string("context-source"),
                    "key": .string("calendar-event-1"),
                    "owner": .string("bot-a"),
                ]),
                "payload": .object(["title": .string("Standup")]),
                "dedupe_key": .string("calendar:standup"),
                "delivery": .string("would"),
                "wake_requested": .bool(false),
            ])))
        let cases = await service.sourceFacts(
            for: ["record://event/\(sequence)"], botID: "bot-a", sessionID: nil)
        let fact = try XCTUnwrap(cases["record://event/\(sequence)"])
        XCTAssertTrue(fact.resolved)
        XCTAssertEqual(fact.recordType, "context.observed")
        XCTAssertEqual(fact.trust, "observation")
        guard case let .known(basis, value, _, _) = try XCTUnwrap(fact.version) else {
            return XCTFail("context.observed must carry its structured version")
        }
        XCTAssertEqual(basis, .etag)
        XCTAssertEqual(value, "etag:calendar-1")
    }

    func testMissingCallerIdentityReturnsNoFactsInsteadOfGuessing() async throws {
        let unknownBot = await service.sourceFacts(
            for: [observationRef], botID: nil, sessionID: "gb-main")
        XCTAssertTrue(unknownBot.isEmpty)
        let unknownSession = await service.sourceFacts(
            for: [observationRef], botID: "bot-a", sessionID: nil)
        XCTAssertTrue(unknownSession.isEmpty)
        let empty = await service.sourceFacts(for: [], botID: "bot-a", sessionID: "gb-main")
        XCTAssertTrue(empty.isEmpty)
    }

    // MARK: - Helpers

    private func sha256Hex(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func writeSessionLog(tombstone: Data? = nil) throws {
        let header: [String: Any] = [
            "type": "session", "version": 4, "id": "gb-main",
            "createdAt": 1_760_000_000_000, "isSeeded": false, "delegationDepth": 0,
        ]
        let user: [String: Any] = [
            "type": "user/message", "seq": 3, "time": 1_760_000_003_000,
            "data": [
                "message": ["role": "user", "content": [
                    ["type": "text", "text": "remember the domain"]]],
                "source": ["kind": "user", "rpcId": "bot-1"],
            ],
        ]
        let call: [String: Any] = [
            "type": "tool/call", "seq": 4, "time": 1_760_000_004_000,
            "data": ["callId": "call-1", "name": "web_fetch",
                     "arguments": "{\"url\":\"https://example.com/a\"}"],
        ]
        var lines = [header, user, call].map {
            String(decoding: try! JSONSerialization.data(
                withJSONObject: $0, options: [.sortedKeys]), as: UTF8.self)
        }
        if let tombstone {
            lines.append(String(decoding: tombstone, as: UTF8.self))
        } else {
            let result: [String: Any] = [
                "type": "tool/result", "seq": 5, "time": observationTime,
                "data": [
                    "message": ["role": "tool", "toolCallId": "call-1",
                                "content": [["type": "text", "text": observationText]],
                                "isError": false],
                    "source": ["kind": "tool", "callId": "call-1"],
                ],
            ]
            lines.append(String(decoding: try! JSONSerialization.data(
                withJSONObject: result, options: [.sortedKeys]), as: UTF8.self))
        }
        try (lines.joined(separator: "\n") + "\n").write(
            to: root.appendingPathComponent(
                "materialized/home/sessions/gb-main/session.v4.jsonl"),
            atomically: true, encoding: .utf8)
    }
}
