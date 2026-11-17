// SPDX-License-Identifier: MIT

import XCTest
@testable import PhoneDSHBot

private final class FixedBodyWebTransport: BotWebRecheckTransport, @unchecked Sendable {
    var body: Data
    var status: Int = 200
    var headers: [String: String] = [:]
    init(body: String) { self.body = Data(body.utf8) }
    func perform(_ request: BotWebRecheckHTTPRequest) async throws -> BotWebRecheckHTTPResponse {
        BotWebRecheckHTTPResponse(status: status, headers: headers, body: body)
    }
}

/// A write-time baseline and a later artifact-scoped status read use the same
/// normalized digest. No new observation event is seeded between reads.
final class BotWebProvenanceFreshnessTests: XCTestCase {
    private func sha(_ text: String) -> String {
        "sha256:" + BotWebSourceRechecker.sha256(Data(text.utf8))
    }

    func testSameAndChangedUseArtifactBaselineWithoutSeedRefresh() async throws {
        let (store, root) = try makeMemoryTestStore()
        defer { cleanupMemoryTestStore(root); Task { try? await store.close() } }
        let transport = FixedBodyWebTransport(body: "  alpha\r\nbeta\r\n")
        let adapter = BotWebProvenanceRecheckAdapter(transport: transport)
        let provenance = BotProvenanceService(eventLog: store, rechecker: adapter)
        let envelope = try XCTUnwrap(BotObservationEnvelope(
            source: "web", origin: "https://example.com/article",
            at: "2026-11-16T08:00:00.000Z", owner: "main",
            reference: BotRecordReference.session(sessionID: "gb-main", seq: 1),
            text: "alpha\nbeta"))
        let sequence = try await store.append(BotEvent(
            type: "conversation.tool_result", eventId: "web-freshness:observation",
            time: 1_760_000_000_000, origin: .local(source: "runtime"),
            traceId: "trace-web-freshness",
            principal: BotPrincipal(botId: "main", sessionId: "gb-main", kind: "chat"),
            causationId: nil, correlationId: "gb-main",
            data: .object(["message": .object([
                "role": .string("tool"),
                "content": .array([.object([
                    "type": .string("text"),
                    "text": .string(envelope.encoded()),
                ])]),
            ])])))
        let ref = "record://event/\(sequence)"
        let baseline = BotSourceBaseline(
            record: ref, role: .evidence,
            sourceVersion: .known(BotKnownSourceVersion(
                kind: .contentSHA256, value: sha("alpha\nbeta"),
                observedAtMS: 1_760_000_000_000, basisRef: ref,
                subject: .recordText)),
            resource: BotMemoryResource(
                kind: "web-url", key: "https://example.com/article",
                owner: "main", scope: "agent"))
        let memory = makeMemory(store: store, botID: "main")
        let written = try await memory.write(
            BotMemoryWriteRequest(
                action: .write, path: "agent/notes/web-freshness.md",
                content: "observed web text", expectedVersion: 0,
                evidence: [ref], sourceBaselines: [baseline]),
            context: BotMemoryWriteContext(
                botID: "main", sessionID: "gb-main", authorKind: .chat,
                source: BotMemorySource(kind: .userTurn, sessionID: "gb-main"),
                trust: .observation, isMainBot: true))
        XCTAssertTrue(written.ok, "\(String(describing: written.code))")

        let artifact = BotDerivedRef(kind: .memory, id: "agent/notes/web-freshness.md", version: 1)
        let current = try await provenance.sourceStatuses(for: artifact)
        XCTAssertEqual(current.first?.state, .current,
                       "normalized CRLF/outer whitespace must compare unchanged")

        transport.body = Data("alpha beta".utf8)
        let refreshed = BotProvenanceService(eventLog: store, rechecker: adapter)
        let changed = try await refreshed.sourceStatuses(for: artifact)
        XCTAssertEqual(changed.first?.state, .changed)
        XCTAssertNotEqual(changed.first?.state, .current)

        // The body is never persisted: no event carries the web body text.
        let events = try await store.events(after: 0, limit: 200)
        let encoded = try events.map {
            String(decoding: try JSONEncoder().encode($0.data), as: UTF8.self)
        }.joined(separator: " ")
        XCTAssertFalse(encoded.contains("alpha beta"))
    }
}
