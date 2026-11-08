// SPDX-License-Identifier: MIT

import XCTest
@testable import PhoneDSHBot

final class BotEventTests: XCTestCase {
    func testEventEnvelopeRoundTrip() throws {
        let event = BotEvent(type: "routine.run_started", eventId: "evt-1", commitSeq: 1, time: 1_760_000_000_000,
                             origin: .local(source: "scheduler"), traceId: "trace-1",
                             principal: BotPrincipal(botId: "main", sessionId: "gb-main--routine-daily", kind: "routine"),
                             causationId: nil, correlationId: "daily", runId: "run-1", attempt: 1,
                             data: .object(["routineId": .string("daily")]))
        let data = try JSONEncoder().encode(event)
        XCTAssertEqual(try JSONDecoder().decode(BotEvent.self, from: data), event)
    }

    func testFrozenEventGoldenUsesRealCodable() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let url = root.appendingPathComponent("spec/bot/v1/golden/event-envelope.json")
        let fixture = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        let valid = fixture["valid"] as! [String: Any]
        let data = try JSONSerialization.data(withJSONObject: valid["event"] as! [String: Any])
        let event = try JSONDecoder().decode(BotEvent.self, from: data)
        XCTAssertEqual(event.eventId, "evt:routine-1")
        XCTAssertEqual(event.origin, .local(source: "scheduler"))
        XCTAssertEqual(event.commitSeq, 1)
        XCTAssertEqual(try JSONDecoder().decode(BotEvent.self, from: JSONEncoder().encode(event)), event)
    }

    func testOriginRejectsUnknownKind() throws {
        let data = Data("{\"kind\":\"future\",\"source\":\"scheduler\"}".utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(BotEventOrigin.self, from: data))
    }

    func testEffectCarriesFrozenRetryPolicy() throws {
        let effect = BotEffect(effectKey: "effect-1", operation: "notify", canonicalResource: "row-1",
                               argsDigest: "digest", logicalKey: "row-1", idempotent: true,
                               retryPolicy: "network-idempotent")
        XCTAssertEqual(effect.kind, "generic")
        XCTAssertEqual(effect.target, "row-1")
        XCTAssertEqual(effect.payloadDigest, "digest")
        XCTAssertEqual(effect.maxAttempts, 5)
    }

    func testUnimplementedStoreFailsClosed() async {
        let store = UnimplementedBotEventLog()
        let event = BotEvent(type: "ui.notice", eventId: "evt-2", time: 1,
                             origin: .local(source: "user"), traceId: "trace-2",
                             principal: BotPrincipal(botId: "main", sessionId: nil, kind: "ipc"),
                             causationId: nil, correlationId: nil, data: .object([:]))
        do {
            _ = try await store.append(event)
            XCTFail("unimplemented store must not accept writes")
        } catch {
            XCTAssertEqual(error as? BotEventStoreError, .unimplemented)
        }
    }
}
