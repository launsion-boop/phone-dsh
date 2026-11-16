// SPDX-License-Identifier: MIT

import CryptoKit
import XCTest
@testable import PhoneDSHBot

/// P lane (G-1 §3.2): every memory document write captures the source baseline
/// for observations in the same batch and persists it in the durable
/// `memory.document_written` event data. A write whose baseline cannot be
/// captured fails instead of producing an unverifiable version.
final class MemorySourceBaselineTests: XCTestCase {
    private var root: URL!
    private var store: SQLiteDomainStore!
    private var gateway: BotGateway!
    private var records: BotRecordService!
    private var memory: BotMemory!
    private let now: Int64 = 1_760_000_020_000
    private let observationTime: Int64 = 1_760_000_005_000
    private let observationRef = "record://session/gb-main#5"
    private let userRef = "record://session/gb-main#3"

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("memory-source-baseline-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("materialized/home/sessions/gb-main", isDirectory: true),
            withIntermediateDirectories: true)
        try writeSessionLog()
        store = try SQLiteDomainStore(
            fileURL: root.appendingPathComponent("domain.sqlite"), now: { 1_000 })
        gateway = BotGateway(now: { 1_000 })
        try await gateway.issueSession(botId: "bot-a", sessionId: "gb-main", kind: .chat)
        records = BotRecordService(
            store: store, gateway: gateway, workspaceRoot: root, now: { 1_000 })
        try await appendToolCallEvent()
        memory = makeMemory(sourceStates: records)
    }

    override func tearDown() async throws {
        try? await store?.close()
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    func testWritePersistsBaselineForObservationsInTheSameEvent() async throws {
        let eventText = "baseline event observation"
        let eventRef = try await appendToolResultEvent(text: eventText)
        let path = "agent/notes/baseline.md"
        let review = BotMemoryReview(
            state: .verified, basis: .observation, refs: [observationRef])
        let result = try await memory.write(
            BotMemoryWriteRequest(
                action: .write, path: path, content: "based on the observation",
                expectedVersion: 0, evidence: [observationRef, eventRef], review: review),
            context: context())
        XCTAssertTrue(result.ok, "\(String(describing: result.code))")

        let event = try await documentWrittenEvent(path: path, version: 1)
        let derivation = try XCTUnwrap(event.data["derivation"]?.objectValue)
        let artifact = try XCTUnwrap(derivation["artifact"]?.objectValue)
        XCTAssertEqual(artifact["kind"]?.stringValue, "memory")
        XCTAssertEqual(artifact["id"]?.stringValue, path)
        XCTAssertEqual(artifact["version"]?.intValue, 1)
        let sources = try XCTUnwrap(derivation["sources"]?.arrayValue)
        XCTAssertEqual(sources.count, 3,
                       "two evidence observations plus the review observation")
        XCTAssertEqual(sources.compactMap { $0["role"]?.stringValue },
                       ["evidence", "evidence", "review"])
        XCTAssertEqual(sources.map { $0["record"]?.stringValue },
                       [observationRef, eventRef, observationRef])

        let states = try await records.sourceStates(
            for: [observationRef, eventRef], callerBotID: "bot-a", callerSessionID: "gb-main")
        let byRef = Dictionary(uniqueKeysWithValues: states.map { ($0.ref, $0) })
        for source in sources {
            let ref = try XCTUnwrap(source["record"]?.stringValue)
            let version = try XCTUnwrap(source["sourceVersion"]?.objectValue)
            XCTAssertEqual(version["basis"]?.stringValue, "content-sha256")
            XCTAssertEqual(version["value"]?.stringValue, byRef[ref]?.version?.known?.value)
            XCTAssertEqual(version["observed_at_ms"]?.intValue,
                           byRef[ref]?.observedAtMS.map(Int.init))
            XCTAssertEqual(version["basis_ref"]?.stringValue, ref)
        }
        let eventVersion = try XCTUnwrap(
            sources.first { $0["record"]?.stringValue == eventRef }?["sourceVersion"]?.objectValue)
        XCTAssertEqual(eventVersion["value"]?.stringValue,
                       "sha256:" + sha256Hex(eventText))
    }

    func testNonObservationEvidenceHasNoBaselineVersion() async throws {
        let path = "agent/notes/non-observation.md"
        let result = try await memory.write(
            BotMemoryWriteRequest(
                action: .write, path: path, content: "user said so",
                expectedVersion: 0, evidence: [userRef]),
            context: context())
        XCTAssertTrue(result.ok, "\(String(describing: result.code))")
        let event = try await documentWrittenEvent(path: path, version: 1)
        let sources = try XCTUnwrap(event.data["derivation"]?["sources"]?.arrayValue)
        XCTAssertEqual(sources.count, 1)
        XCTAssertEqual(sources.first?["record"]?.stringValue, userRef)
        XCTAssertNil(sources.first?["sourceVersion"],
                     "G-1 §2.2: a user message is not an observation and carries no sourceVersion")
    }

    func testRestoreCapturesTheInheritedObservationsBaseline() async throws {
        let path = "agent/notes/restore-baseline.md"
        let review = BotMemoryReview(
            state: .verified, basis: .observation, refs: [observationRef])
        let first = try await memory.write(
            BotMemoryWriteRequest(
                action: .write, path: path, content: "one",
                expectedVersion: 0, evidence: [observationRef], review: review),
            context: context())
        XCTAssertTrue(first.ok)
        _ = try await memory.write(
            BotMemoryWriteRequest(
                action: .write, path: path, content: "two", expectedVersion: 1),
            context: context())
        let restored = try await memory.write(
            BotMemoryWriteRequest(
                action: .restore, path: path, expectedVersion: 2, restoreVersion: 1),
            context: context())
        XCTAssertTrue(restored.ok, "\(String(describing: restored.code))")

        let event = try await documentWrittenEvent(path: path, version: 3)
        let sources = try XCTUnwrap(
            event.data["derivation"]?["sources"]?.arrayValue)
        XCTAssertEqual(sources.map { $0["record"]?.stringValue },
                       [observationRef, observationRef])
        XCTAssertEqual(sources.map { $0["role"]?.stringValue }, ["evidence", "review"])
        XCTAssertEqual(sources.first?["sourceVersion"]?["basis"]?.stringValue,
                       "content-sha256",
                       "restore inherits the restored version's sources and re-captures their baseline")
        XCTAssertEqual(sources.first?["sourceVersion"]?["observed_at_ms"]?.intValue,
                       Int(observationTime))
    }

    func testRestoreAfterErasedObservationWritesExplicitUnknownBaseline() async throws {
        let path = "agent/notes/restore-erased.md"
        let review = BotMemoryReview(
            state: .verified, basis: .observation, refs: [observationRef])
        let first = try await memory.write(
            BotMemoryWriteRequest(
                action: .write, path: path, content: "one",
                expectedVersion: 0, evidence: [observationRef], review: review),
            context: context())
        XCTAssertTrue(first.ok, "\(String(describing: first.code))")

        try writeErasedSessionLog()
        let restored = try await memory.write(
            BotMemoryWriteRequest(
                action: .restore, path: path, expectedVersion: 1, restoreVersion: 1),
            context: context())
        XCTAssertTrue(restored.ok, "\(String(describing: restored.code))")

        let event = try await documentWrittenEvent(path: path, version: 2)
        let sources = try XCTUnwrap(event.data["derivation"]?["sources"]?.arrayValue)
        XCTAssertEqual(sources.map { $0["record"]?.stringValue },
                       [observationRef, observationRef])
        for source in sources {
            let version = try XCTUnwrap(source["sourceVersion"]?.objectValue)
            XCTAssertEqual(version["reason"]?.stringValue, "record-erased",
                           "an erased observation must not look like a non-observation source")
        }
        let states = try await records.sourceStates(
            for: [observationRef], callerBotID: "bot-a", callerSessionID: "gb-main")
        XCTAssertTrue(try XCTUnwrap(states.first).erased)
    }

    func testUncapturableBaselineFailsTheWriteWithoutAnEvent() async throws {
        let failing = BotMemory(
            store: SQLiteBotMemoryDocumentStore(eventLog: store, botID: "bot-a", now: { self.now }),
            botID: "bot-a", now: { self.now },
            sourceStates: FailingSourceStates())
        let path = "agent/notes/baseline-fails.md"
        let before = try await documentWrittenEvents(path: path).count
        let result = try await failing.write(
            BotMemoryWriteRequest(
                action: .write, path: path, content: "x",
                expectedVersion: 0, evidence: [observationRef]),
            context: context())
        XCTAssertFalse(result.ok)
        XCTAssertEqual(result.code, "memory-source-baseline-unavailable")
        let after = try await documentWrittenEvents(path: path).count
        XCTAssertEqual(after, before, "a failed baseline must not append the document event")
        guard case .failure = try await failing.read(path: path) else {
            return XCTFail("the document must not exist after a failed baseline write")
        }
    }

    func testWriteWithoutAResolverKeepsTheOldShape() async throws {
        let legacy = BotMemory(
            store: SQLiteBotMemoryDocumentStore(eventLog: store, botID: "bot-a", now: { self.now }),
            botID: "bot-a", now: { self.now })
        let path = "agent/notes/legacy-no-resolver.md"
        let result = try await legacy.write(
            BotMemoryWriteRequest(
                action: .write, path: path, content: "x",
                expectedVersion: 0, evidence: [observationRef]),
            context: context())
        XCTAssertTrue(result.ok)
        let event = try await documentWrittenEvent(path: path, version: 1)
        XCTAssertNil(event.data["derivation"],
                     "a caller with no resolver keeps the pre-freeze event shape")
    }

    func testErasedObservationKeepsTheHistoricalBaselineButStopsResolving() async throws {
        let text = "erase me"
        let eventRef = try await appendToolResultEvent(text: text)
        let sequence = try XCTUnwrap(
            Int(eventRef.dropFirst("record://event/".count)))
        let path = "agent/notes/erased-baseline.md"
        _ = try await memory.write(
            BotMemoryWriteRequest(
                action: .write, path: path, content: "x",
                expectedVersion: 0, evidence: [eventRef]),
            context: context())
        let written = try await documentWrittenEvent(path: path, version: 1)
        let baseline = try XCTUnwrap(
            written.data["derivation"]?["sources"]?.arrayValue?.first?["sourceVersion"])
        XCTAssertEqual(baseline["value"]?.stringValue, "sha256:" + sha256Hex(text))

        let erasure = BotErasureEventData(
            erasureId: "baseline-erasure", reason: "memory-path-erase",
            atMS: now,
            targets: [BotErasureEventData.Target(
                kind: "memory", scope: "agent", path: "agent/notes/unrelated.md")])
        let erasureEvent = BotEvent(
            type: "erasure", eventId: "baseline-erasure", time: now,
            origin: .local(source: "user"), traceId: "baseline-erasure",
            principal: BotPrincipal(botId: "bot-a", sessionId: "gb-main", kind: "chat"),
            causationId: nil, correlationId: nil,
            data: try BotJSONValue.parse(JSONEncoder().encode(erasure)))
        _ = try await store.erasePayloads(
            [sequence], erasureEvent: erasureEvent, atMS: now)

        let states = try await records.sourceStates(
            for: [eventRef], callerBotID: "bot-a", callerSessionID: "gb-main")
        let state = try XCTUnwrap(states.first)
        XCTAssertTrue(state.erased)
        XCTAssertNil(state.version)
        // The historical event is append-only: its baseline still records what
        // was observed; the read view (L) is what reports erased.
        let unchanged = try await documentWrittenEvent(path: path, version: 1)
        XCTAssertEqual(
            unchanged.data["derivation"]?["sources"]?.arrayValue?.first?["sourceVersion"]?["value"]?.stringValue,
            "sha256:" + sha256Hex(text))
    }

    // MARK: - Helpers

    private final class FailingSourceStates: BotSourceStateResolving, @unchecked Sendable {
        func sourceStates(for references: [String], callerBotID: String,
                          callerSessionID: String) async throws -> [BotSourceState] {
            throw BotRecordServiceError.unavailable("simulated baseline failure")
        }
    }

    private func sha256Hex(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func context() -> BotMemoryWriteContext {
        BotMemoryWriteContext(
            botID: "bot-a", sessionID: "gb-main", authorKind: .chat,
            source: BotMemorySource(kind: .userTurn, sessionID: "gb-main"),
            trust: .observation, isMainBot: true)
    }

    private func makeMemory(sourceStates: (any BotSourceStateResolving)?) -> BotMemory {
        BotMemory(
            store: SQLiteBotMemoryDocumentStore(eventLog: store, botID: "bot-a", now: { self.now }),
            botID: "bot-a", now: { self.now }, sourceStates: sourceStates)
    }

    private func documentWrittenEvents(path: String) async throws -> [BotEvent] {
        let events = try await store.events(after: 0, limit: 200)
        return events.filter {
            $0.type == "memory.document_written" && $0.data["path"]?.stringValue == path
        }
    }

    private func documentWrittenEvent(path: String, version: Int) async throws -> BotEvent {
        let events = try await documentWrittenEvents(path: path)
        guard let event = events.first(where: { $0.data["version"]?.intValue == version }) else {
            throw BotMemoryTestError.seedFailed("\(path) has no version \(version) event")
        }
        return event
    }

    private func appendToolCallEvent() async throws {
        _ = try await store.append(BotEvent(
            type: "conversation.tool_call",
            eventId: "conversation.tool_call:\(UUID().uuidString)", time: now,
            origin: .local(source: "runtime"), traceId: "trace-\(UUID().uuidString)",
            principal: BotPrincipal(botId: "bot-a", sessionId: "gb-main", kind: "chat"),
            causationId: nil, correlationId: "gb-main",
            data: .object([
                "callId": .string("call-1"),
                "name": .string("web_fetch"),
                "arguments": .string("{\"url\":\"https://example.com/a\"}"),
            ])))
    }

    private func appendToolResultEvent(text: String) async throws -> String {
        let event = BotEvent(
            type: "conversation.tool_result",
            eventId: "conversation.tool_result:\(UUID().uuidString)", time: now,
            origin: .local(source: "runtime"), traceId: "trace-\(UUID().uuidString)",
            principal: BotPrincipal(botId: "bot-a", sessionId: "gb-main", kind: "chat"),
            causationId: nil, correlationId: "gb-main",
            data: .object([
                "message": .object([
                    "toolCallId": .string("call-1"),
                    "content": .array([.object([
                        "type": .string("text"), "text": .string(text),
                    ])]),
                ]),
            ]))
        let sequence = try await store.append(event)
        return "record://event/\(sequence)"
    }

    private func writeErasedSessionLog() throws {
        let header: [String: Any] = [
            "type": "session", "version": 4, "id": "gb-main",
            "createdAt": 1_760_000_000_000, "isSeeded": false, "delegationDepth": 0,
        ]
        let user: [String: Any] = [
            "type": "user/message", "seq": 3, "time": 1_760_000_003_000,
            "data": [
                "message": ["role": "user", "content": [
                    ["type": "text", "text": "remember the baseline"]]],
                "source": ["kind": "user", "rpcId": "bot-1"],
            ],
        ]
        let call: [String: Any] = [
            "type": "tool/call", "seq": 4, "time": 1_760_000_004_000,
            "data": ["callId": "call-1", "name": "web_fetch",
                     "arguments": "{\"url\":\"https://example.com/a\"}"],
        ]
        let tombstone = try! BotSessionErasureTombstone.line(
            sessionID: "gb-main", seq: 5, time: observationTime,
            erasureID: "baseline-test-erasure")
        let lines = [header, user, call].map {
            String(decoding: try! JSONSerialization.data(
                withJSONObject: $0, options: [.sortedKeys]), as: UTF8.self)
        } + [String(decoding: tombstone, as: UTF8.self)]
        try (lines.joined(separator: "\n") + "\n").write(
            to: root.appendingPathComponent(
                "materialized/home/sessions/gb-main/session.v4.jsonl"),
            atomically: true, encoding: .utf8)
    }

    private func writeSessionLog() throws {
        let header: [String: Any] = [
            "type": "session", "version": 4, "id": "gb-main",
            "createdAt": 1_760_000_000_000, "isSeeded": false, "delegationDepth": 0,
        ]
        let user: [String: Any] = [
            "type": "user/message", "seq": 3, "time": 1_760_000_003_000,
            "data": [
                "message": ["role": "user", "content": [
                    ["type": "text", "text": "remember the baseline"]]],
                "source": ["kind": "user", "rpcId": "bot-1"],
            ],
        ]
        let call: [String: Any] = [
            "type": "tool/call", "seq": 4, "time": 1_760_000_004_000,
            "data": ["callId": "call-1", "name": "web_fetch",
                     "arguments": "{\"url\":\"https://example.com/a\"}"],
        ]
        let result: [String: Any] = [
            "type": "tool/result", "seq": 5, "time": observationTime,
            "data": [
                "message": ["role": "tool", "toolCallId": "call-1",
                            "content": [["type": "text", "text": "Example Domain"]],
                            "isError": false],
                "source": ["kind": "tool", "callId": "call-1"],
            ],
        ]
        let lines = [header, user, call, result].map {
            String(decoding: try! JSONSerialization.data(
                withJSONObject: $0, options: [.sortedKeys]), as: UTF8.self)
        }
        try (lines.joined(separator: "\n") + "\n").write(
            to: root.appendingPathComponent(
                "materialized/home/sessions/gb-main/session.v4.jsonl"),
            atomically: true, encoding: .utf8)
    }
}
