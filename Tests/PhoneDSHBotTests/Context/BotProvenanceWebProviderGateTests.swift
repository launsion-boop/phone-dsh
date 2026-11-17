// SPDX-License-Identifier: MIT

import Foundation
import XCTest
@testable import PhoneDSHBot

private actor CountingWebTransport: BotWebRecheckTransport {
    private(set) var calls = 0

    func callCount() -> Int { calls }

    func perform(_ request: BotWebRecheckHTTPRequest) async throws
        -> BotWebRecheckHTTPResponse {
        calls += 1
        return BotWebRecheckHTTPResponse(
            status: 304, headers: ["etag": "\"a\""], body: Data())
    }
}

/// A03/A08: after an erasure or a known-revoked grant, the L facts gate must
/// return before R's web adapter can touch the transport. The normal source
/// still goes through the real adapter and transport.
final class BotProvenanceWebProviderGateTests: XCTestCase {
    private func sourceEvent(_ log: BotProvenanceTestLog,
                             id: String) async throws -> Int {
        try await log.append(ProvenanceTest.toolResultEvent(
            eventId: id, source: "web", origin: "https://gate.example/a",
            owner: "bot-a", at: 1_000))
    }

    private func memoryEvent(path: String, source: String,
                             grantId: String?, eventId: String) -> BotEvent {
        var sourceObject: [String: BotJSONValue] = [
            "record": .string(source), "role": .string("evidence"),
            "sourceVersion": .object([
                "basis": .string("etag"), "value": .string("etag:a"),
                "observed_at_ms": .number(1_000),
            ]),
        ]
        if let grantId { sourceObject["grantId"] = .string(grantId) }
        return ProvenanceTest.event(
            type: "memory.document_written", eventId: eventId,
            data: .object([
                "path": .string(path), "version": .number(1),
                "derivation": .object([
                    "artifact": .object([
                        "kind": .string("memory"), "id": .string(path),
                        "version": .number(1),
                    ]),
                    "sources": .array([.object(sourceObject)]),
                ]),
            ]), principalKind: "chat", botID: "bot-a", sessionID: "gb-bot-a")
    }

    private func service(_ log: BotProvenanceTestLog,
                         transport: CountingWebTransport) -> BotProvenanceService {
        BotProvenanceService(
            eventLog: log,
            rechecker: BotProvenanceWebRecheckAdapter(transport: transport))
    }

    func testNormalSourceCallsTransport() async throws {
        let log = BotProvenanceTestLog()
        let source = try await sourceEvent(log, id: "web-normal")
        _ = try await log.append(memoryEvent(
            path: "agent/web.md", source: "record://event/\(source)",
            grantId: nil, eventId: "web-normal-memory"))
        let transport = CountingWebTransport()
        let statuses = try await service(log, transport: transport).sourceStatuses(
            for: BotDerivedRef(kind: .memory, id: "agent/web.md", version: 1),
            botID: "bot-a")
        XCTAssertEqual(statuses.first?.state, .current)
        let calls = await transport.callCount()
        XCTAssertEqual(calls, 1)
    }

    func testErasedSourceDoesNotCallTransport() async throws {
        let log = BotProvenanceTestLog()
        let source = try await sourceEvent(log, id: "web-erased")
        _ = try await log.append(memoryEvent(
            path: "agent/erased.md", source: "record://event/\(source)",
            grantId: nil, eventId: "web-erased-memory"))
        _ = try await log.append(ProvenanceTest.erasureEvent(
            erasureId: "web-erased", eventRecords: ["record://event/\(source)"]),
            )
        let transport = CountingWebTransport()
        let status = try await service(log, transport: transport).currentState(
            for: BotDerivedRef(kind: .memory, id: "agent/erased.md", version: 1),
            botID: "bot-a")
        XCTAssertEqual(status.state, .erased)
        let calls = await transport.callCount()
        XCTAssertEqual(calls, 0)
    }

    func testRevokedGrantDoesNotCallTransport() async throws {
        let log = BotProvenanceTestLog()
        let source = try await sourceEvent(log, id: "web-revoked")
        _ = try await log.append(ProvenanceTest.event(
            type: "grant.revoked", eventId: "web-revoke",
            data: .object(["grantId": .string("g1")])))
        _ = try await log.append(memoryEvent(
            path: "agent/revoked.md", source: "record://event/\(source)",
            grantId: "g1", eventId: "web-revoked-memory"))
        let transport = CountingWebTransport()
        let status = try await service(log, transport: transport).currentState(
            for: BotDerivedRef(kind: .memory, id: "agent/revoked.md", version: 1),
            botID: "bot-a")
        XCTAssertEqual(status.state, .revoked)
        let calls = await transport.callCount()
        XCTAssertEqual(calls, 0)
    }
}
