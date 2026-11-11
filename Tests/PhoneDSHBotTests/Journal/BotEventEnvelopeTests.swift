// SPDX-License-Identifier: MIT

import XCTest
@testable import PhoneDSHBot

final class BotEventEnvelopeTests: XCTestCase {
    func testFrozenGoldenValidEventUsesRealEncoderAndDecoder() throws {
        let fixture = try loadFixture()
        let valid = fixture["valid"] as! [String: Any]
        let data = try JSONSerialization.data(withJSONObject: valid["event"] as! [String: Any])
        let codec = BotEventEnvelopeCodec()
        let decoded = try codec.decode(data)
        XCTAssertEqual(decoded.eventId, "evt:routine-1")
        XCTAssertEqual(decoded.origin, .local(source: "scheduler"))
        XCTAssertEqual(decoded.commitSeq, 1)

        let encoded = try codec.encode(decoded)
        let object = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        XCTAssertEqual((object["origin"] as! [String: Any])["kind"] as? String, "local")
        XCTAssertEqual(try codec.decode(encoded), decoded)
    }

    func testFrozenGoldenInvalidEventsFailClosedWithFrozenCodes() throws {
        let fixture = try loadFixture()
        let invalid = fixture["invalid"] as! [[String: Any]]
        XCTAssertEqual(invalid.count, 4)
        let codec = BotEventEnvelopeCodec()
        for vector in invalid {
            let data = try JSONSerialization.data(withJSONObject: vector["event"] as! [String: Any])
            let validation = vector["validation"] as! [String: Any]
            let errors = validation["errors"] as! [[String: Any]]
            let expectedCode = errors[0]["code"] as! String
            XCTAssertThrowsError(try codec.decode(data)) { error in
                guard let validationError = error as? BotEventValidationError else {
                    return XCTFail("unexpected error: \(error)")
                }
                XCTAssertEqual(validationError.code, expectedCode)
            }
        }
    }

    func testPhoneGoldenDurableCasesUseRealEncoderAndDecoder() throws {
        let fixture = try loadPhoneFixture()
        let valid = try XCTUnwrap(fixture["validCases"] as? [[String: Any]])
        XCTAssertGreaterThanOrEqual(valid.count, 5)
        let codec = BotEventEnvelopeCodec()
        for vector in valid {
            let data = try JSONSerialization.data(withJSONObject: vector["event"] as! [String: Any])
            let decoded = try codec.decode(data)
            let encoded = try codec.encode(decoded)
            XCTAssertEqual(try codec.decode(encoded), decoded)
            // Explicit-null input is a reader vector: the Swift writer
            // canonicalises it to the absent bytes. Every vector without an
            // explicit envelope null must match the golden bytes exactly.
            let eventObject = vector["event"] as! [String: Any]
            if !hasExplicitEnvelopeNull(eventObject) {
                XCTAssertEqual(encoded, try canonicalEventData(eventObject),
                               "validCases[\(vector["name"] ?? "?")] bytes")
            }
        }

        let invalid = try XCTUnwrap(fixture["invalidCases"] as? [[String: Any]])
        XCTAssertGreaterThanOrEqual(invalid.count, 2)
        for vector in invalid {
            let data = try JSONSerialization.data(withJSONObject: vector["event"] as! [String: Any])
            let validation = vector["validation"] as! [String: Any]
            let errors = validation["errors"] as! [[String: Any]]
            let expectedCode = errors[0]["code"] as! String
            let expectedField = errors[0]["field"] as! String
            XCTAssertThrowsError(try codec.decode(data)) { error in
                guard let validationError = error as? BotEventValidationError else {
                    return XCTFail("unexpected error: \(error)")
                }
                XCTAssertEqual(validationError.code, expectedCode)
                XCTAssertEqual(validationError.field, expectedField)
            }
        }
    }

    func testPhoneGoldenAbsentAndExplicitNullAreTheSameEvent() throws {
        let fixture = try loadPhoneFixture()
        let valid = try XCTUnwrap(fixture["validCases"] as? [[String: Any]])
        let absent = try XCTUnwrap(valid.first { $0["name"] as? String == "durable-absent-nil-members" })
        let explicitNull = try XCTUnwrap(valid.first { $0["name"] as? String == "durable-explicit-null-members" })
        let codec = BotEventEnvelopeCodec()
        let absentEvent = try codec.decode(
            JSONSerialization.data(withJSONObject: absent["event"] as! [String: Any]))
        let nullEvent = try codec.decode(
            JSONSerialization.data(withJSONObject: explicitNull["event"] as! [String: Any]))
        XCTAssertEqual(absentEvent, nullEvent)

        // Swift's synthesized Codable omits a nil optional. The Kotlin writer
        // must produce these same bytes; explicit null is reader-only input.
        let encoded = try codec.encode(nullEvent)
        XCTAssertEqual(try codec.encode(absentEvent), encoded)
        let text = try XCTUnwrap(String(data: encoded, encoding: .utf8))
        XCTAssertFalse(text.contains("\"causationId\""))
        XCTAssertFalse(text.contains("\"correlationId\""))
        XCTAssertFalse(text.contains("\"botId\""))
        XCTAssertFalse(text.contains("\"sessionId\""))
    }

    func testPhoneGoldenGrantSnapshotUsesTheSwiftPayloadAndCodec() throws {
        let fixture = try loadPhoneFixture()
        let valid = try XCTUnwrap(fixture["validCases"] as? [[String: Any]])
        let vector = try XCTUnwrap(valid.first { $0["name"] as? String == "authz-grant-snapshot" })
        let eventObject = vector["event"] as! [String: Any]
        let codec = BotEventEnvelopeCodec()
        let event = try codec.decode(JSONSerialization.data(withJSONObject: eventObject))
        XCTAssertEqual(event.type, "authz.grant_snapshot")
        XCTAssertEqual(event.ignorable, true)
        XCTAssertNil(event.principal.botId)
        XCTAssertNil(event.principal.sessionId)
        XCTAssertEqual(try codec.encode(event), try canonicalEventData(eventObject))

        let grants = try BotGrantSnapshot.decode(event, now: 0)
        XCTAssertEqual(grants.map(\.id), ["grant-fixture-allow", "grant-fixture-deny"])
        XCTAssertEqual(grants[0].scope, .session)
        XCTAssertEqual(grants[0].sessionId, "session-fixture")
        XCTAssertNil(grants[0].expiresAt)
        XCTAssertEqual(grants[1].scope, .until)
        XCTAssertNil(grants[1].sessionId)
        XCTAssertEqual(grants[1].expiresAt, 1_760_003_600_000)
    }

    func testPhoneGoldenEphemeralEnvelopeIsSeparateAndHasNoCommitSeq() throws {
        let fixture = try loadPhoneFixture()
        let codec = BotEventEnvelopeCodec()
        let valid = try XCTUnwrap(fixture["ephemeralValidCases"] as? [[String: Any]])
        XCTAssertFalse(valid.isEmpty)
        for vector in valid {
            let data = try JSONSerialization.data(withJSONObject: vector["event"] as! [String: Any])
            let decoded = try codec.decode(data)
            XCTAssertNil(decoded.commitSeq)
            XCTAssertTrue(BotEventEnvelopeCodec.isEphemeral(decoded.type))
            let encoded = try codec.encode(decoded)
            let text = try XCTUnwrap(String(data: encoded, encoding: .utf8))
            XCTAssertFalse(text.contains("commitSeq"))
            XCTAssertEqual(try codec.decode(encoded), decoded)
        }

        let invalid = try XCTUnwrap(fixture["ephemeralInvalidCases"] as? [[String: Any]])
        XCTAssertTrue(invalid.contains { ($0["event"] as? [String: Any])?["commitSeq"] != nil })
        for vector in invalid {
            let data = try JSONSerialization.data(withJSONObject: vector["event"] as! [String: Any])
            let validation = vector["validation"] as! [String: Any]
            let errors = validation["errors"] as! [[String: Any]]
            let expectedCode = errors[0]["code"] as! String
            let expectedField = errors[0]["field"] as! String
            XCTAssertThrowsError(try codec.decode(data)) { error in
                guard let validationError = error as? BotEventValidationError else {
                    return XCTFail("unexpected error: \(error)")
                }
                XCTAssertEqual(validationError.code, expectedCode)
                XCTAssertEqual(validationError.field, expectedField)
            }
        }
    }

    private func canonicalEventData(_ object: [String: Any]) throws -> Data {
        try BotJSONValue.parse(JSONSerialization.data(withJSONObject: object)).encoded()
    }

    private func hasExplicitEnvelopeNull(_ event: [String: Any]) -> Bool {
        if event["causationId"] is NSNull || event["correlationId"] is NSNull {
            return true
        }
        guard let principal = event["principal"] as? [String: Any] else { return false }
        return principal["botId"] is NSNull || principal["sessionId"] is NSNull
    }

    func testAppendValidationRejectsCallerAssignedSequence() throws {
        let event = BotEvent(
            type: "ui.notice", eventId: "evt-assigned", commitSeq: 1, time: 1,
            origin: .local(source: "user"), traceId: "trace-assigned",
            principal: BotPrincipal(botId: nil, sessionId: nil, kind: "ipc"),
            causationId: nil, correlationId: nil, data: .object([:]))
        XCTAssertThrowsError(try BotEventEnvelopeCodec.validate(event, mode: .append)) { error in
            XCTAssertEqual((error as? BotEventValidationError)?.code, "COMMIT_SEQ_ASSIGNED_BY_STORE")
        }
    }

    private func loadFixture() throws -> [String: Any] {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let url = root.appendingPathComponent("spec/bot/v1/golden/event-envelope.json")
        return try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
    }

    private func loadPhoneFixture() throws -> [String: Any] {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let url = root.appendingPathComponent("spec/bot/v1/golden/event-envelope.phone.json")
        return try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
    }
}
