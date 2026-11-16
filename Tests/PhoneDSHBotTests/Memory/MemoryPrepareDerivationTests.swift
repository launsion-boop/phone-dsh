// SPDX-License-Identifier: MIT

import CryptoKit
import XCTest
@testable import PhoneDSHBot

/// P lane Plan A mechanism: L's `prepareDerivation` fills the real resource
/// identity; P persists the resulting `sources` verbatim through
/// `BotMemoryWriteRequest.sourceBaselines`. No identity is guessed by P.
final class MemoryPrepareDerivationTests: XCTestCase {
    private var root: URL!
    private var store: SQLiteDomainStore!
    private var gateway: BotGateway!
    private var records: BotRecordService!
    private var memory: BotMemory!
    private var provenance: BotProvenanceService!
    private let now: Int64 = 1_760_000_060_000
    private let observationText = "Example Domain"

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("memory-prepare-derivation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = try SQLiteDomainStore(
            fileURL: root.appendingPathComponent("domain.sqlite"), now: { 1_000 })
        gateway = BotGateway(now: { 1_000 })
        try await gateway.issueSession(botId: "bot-a", sessionId: "gb-main", kind: .chat)
        records = BotRecordService(
            store: store, gateway: gateway, workspaceRoot: root, now: { 1_000 })
        memory = BotMemory(
            store: SQLiteBotMemoryDocumentStore(eventLog: store, botID: "bot-a", now: { self.now }),
            botID: "bot-a", now: { self.now })
        provenance = BotProvenanceService(eventLog: store, resolver: records)
    }

    override func tearDown() async throws {
        try? await store?.close()
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    func testPreparedSourcesCarryTheCarrierResourceIntoTheWrite() async throws {
        let reference = try await appendEnvelopeObservation()
        let facts = await records.sourceFacts(
            for: [reference], botID: "bot-a", sessionID: "gb-main")
        let fact = try XCTUnwrap(facts[reference])
        XCTAssertEqual(fact.trust, "observation")
        let prepared = try await provenance.prepareDerivation(
            artifact: BotDerivedRef(kind: .memory, id: "agent/notes/prepared.md", version: 1),
            sources: [BotDerivationSource(
                record: reference, role: .evidence, sourceVersion: fact.version)])
        let sources = try decodeSources(prepared)
        XCTAssertEqual(sources.count, 1)
        let source = try XCTUnwrap(sources.first)
        XCTAssertEqual(source.record, reference)
        XCTAssertEqual(source.role, .evidence)
        XCTAssertEqual(source.resource?.kind, "web-url")
        XCTAssertEqual(source.resource?.key, "https://example.com/a")
        XCTAssertEqual(source.sourceVersion?.known?.subject, .recordText)
        XCTAssertEqual(source.sourceVersion?.known?.value,
                       "sha256:" + sha256Hex(observationText))
        let mapped = source.provenanceSource()
        XCTAssertEqual(mapped.role, .evidence)
        XCTAssertEqual(mapped.sourceVersion?.subject, .recordText,
                       "P→L mapping must carry the r13 subject")

        let result = try await memory.write(
            BotMemoryWriteRequest(
                action: .write, path: "agent/notes/prepared.md",
                content: "observed", expectedVersion: 0,
                evidence: [reference], sourceBaselines: sources),
            context: context())
        XCTAssertTrue(result.ok, "\(String(describing: result.code))")
        let event = try await documentWrittenEvent(path: "agent/notes/prepared.md", version: 1)
        let stored = try XCTUnwrap(event.data["derivation"]?["sources"]?.arrayValue)
        XCTAssertEqual(stored.count, 1)
        XCTAssertEqual(stored[0]["resource"]?["kind"]?.stringValue, "web-url")
        XCTAssertEqual(stored[0]["resource"]?["key"]?.stringValue, "https://example.com/a")
        XCTAssertEqual(stored[0]["sourceVersion"]?["subject"]?.stringValue, "record-text")
    }

    func testObservationWithoutIdentityFailsClosedBeforePersistence() async throws {
        let sequence = try await store.append(BotEvent(
            type: "conversation.assistant_message",
            eventId: "no-identity:\(UUID().uuidString)", time: 1_000,
            origin: .local(source: "runtime"), traceId: "trace-no-identity",
            principal: BotPrincipal(botId: "bot-a", sessionId: "gb-main", kind: "chat"),
            causationId: nil, correlationId: "gb-main",
            data: .object(["text": .string("not an observation carrier")])))
        let reference = "record://event/\(sequence)"
        let version = BotProvenanceSourceVersion.known(
            basis: .contentSHA256,
            value: "sha256:" + sha256Hex("not an observation carrier"),
            observedAtMS: 1_000, basisRef: reference, subject: .recordText)
        do {
            _ = try await provenance.prepareDerivation(
                artifact: BotDerivedRef(kind: .memory, id: "agent/notes/no-id.md", version: 1),
                sources: [BotDerivationSource(
                    record: reference, role: .evidence, sourceVersion: version)])
            XCTFail("an observation without a resource identity must fail closed")
        } catch {
            // expected
        }
        let before = try await documentWrittenEvents(path: "agent/notes/no-id.md")
        XCTAssertTrue(before.isEmpty)
    }

    // MARK: - Helpers

    private struct Prepared: Decodable {
        let sources: [BotSourceBaseline]
    }

    private func decodeSources(_ value: BotJSONValue) throws -> [BotSourceBaseline] {
        let data = try value.encoded()
        return try JSONDecoder().decode(Prepared.self, from: data).sources
    }

    private func context() -> BotMemoryWriteContext {
        BotMemoryWriteContext(
            botID: "bot-a", sessionID: "gb-main", authorKind: .chat,
            source: BotMemorySource(kind: .userTurn, sessionID: "gb-main"),
            trust: .observation, isMainBot: true)
    }

    private func sha256Hex(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func appendEnvelopeObservation() async throws -> String {
        let envelope = try XCTUnwrap(BotObservationEnvelope(
            source: "web", origin: "https://example.com/a",
            at: "2026-11-11T07:00:00.000Z", owner: "unknown",
            reference: BotRecordReference.event(commitSeq: 501),
            text: observationText))
        let event = BotEvent(
            type: "conversation.tool_result",
            eventId: "conversation.tool_result:\(UUID().uuidString)", time: 1_000,
            origin: .local(source: "runtime"), traceId: "trace-\(UUID().uuidString)",
            principal: BotPrincipal(botId: "bot-a", sessionId: "gb-main", kind: "chat"),
            causationId: nil, correlationId: "gb-main",
            data: .object([
                "message": .object([
                    "toolCallId": .string("call-1"),
                    "content": .array([.object([
                        "type": .string("text"),
                        "text": .string(envelope.encoded()),
                    ])]),
                ]),
            ]))
        return "record://event/\(try await store.append(event))"
    }

    private func documentWrittenEvents(path: String) async throws -> [BotEvent] {
        let events = try await store.events(after: 0, limit: 100)
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
}
