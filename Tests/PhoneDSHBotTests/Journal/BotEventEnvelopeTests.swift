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
        XCTAssertEqual(valid.count, 13)
        let codec = BotEventEnvelopeCodec()
        for vector in valid {
            let data = try JSONSerialization.data(withJSONObject: vector["event"] as! [String: Any])
            let decoded = try codec.decode(data)
            switch vector["name"] as? String {
            case "redaction-applied":
                XCTAssertEqual(decoded.type, "redaction.applied")
                XCTAssertEqual(decoded.origin, .dsh(sessionId: "gb-main", seq: 5))
                XCTAssertEqual(decoded.data["record"]?.stringValue, "record://event/7")
                XCTAssertEqual(decoded.data["sessionRecord"]?.stringValue, "record://session/gb-main#5")
            case "erasure-event-envelope":
                XCTAssertEqual(decoded.type, "erasure")
                XCTAssertEqual(decoded.origin, .local(source: "user"))
                XCTAssertEqual(decoded.principal.kind, "ipc")
                XCTAssertEqual(decoded.data["erasureId"]?.stringValue, "erasure-20261112-a")
            case "maintenance-started", "maintenance-finished", "maintenance-rolled-back":
                XCTAssertTrue(decoded.type.hasPrefix("memory.maintenance_"))
                XCTAssertEqual(decoded.origin, .local(source: "memory-service"))
                XCTAssertEqual(decoded.principal.kind, "maintainer")
                XCTAssertEqual(decoded.data["batch_id"]?.stringValue,
                               "mm-0123456789abcdef0123456789abcdef")
            case "verification-reported":
                XCTAssertEqual(decoded.type, "verification.reported")
                XCTAssertEqual(decoded.principal.kind, "verifier")
                XCTAssertEqual(decoded.data["subjectKind"]?.stringValue, "task")
                XCTAssertEqual(decoded.data["verification"]?["verdict"]?.stringValue, "failed")
                XCTAssertEqual(decoded.data["verification"]?["refs"]?.arrayValue?.first?.stringValue,
                               "record://session/gb-task-abc#10")
            case "agent-comm-outbound", "agent-comm-inbound":
                XCTAssertEqual(decoded.type, "agent.comm")
                XCTAssertEqual(decoded.origin, .local(source: "comm-service"))
                XCTAssertEqual(decoded.principal.kind, "team")
            case "durable-absent-nil-members", "durable-explicit-null-members":
                XCTAssertEqual(decoded.type, "ui.notice")
                XCTAssertNil(decoded.principal.botId)
                XCTAssertNil(decoded.causationId)
            case "authz-grant-snapshot":
                XCTAssertEqual(decoded.type, "authz.grant_snapshot")
                XCTAssertEqual(decoded.ignorable, true)
            case "memory-document-written":
                XCTAssertEqual(decoded.type, "memory.document_written")
                XCTAssertTrue(BotEventEnvelopeCodec.isDurable(decoded.type))
                XCTAssertEqual(decoded.origin, .local(source: "memory-service"))
                XCTAssertEqual(decoded.data["path"]?.stringValue, "agent/notes/plan.md")
                XCTAssertEqual(decoded.data["expected_version"]?.intValue, 1)
            case "memory-document-deleted":
                XCTAssertEqual(decoded.type, "memory.document_deleted")
                XCTAssertTrue(BotEventEnvelopeCodec.isDurable(decoded.type))
                XCTAssertEqual(decoded.origin, .local(source: "memory-service"))
                XCTAssertEqual(decoded.data["reason"]?.stringValue, "forget")
            default:
                XCTFail("unhandled phone event case \(vector["name"] ?? "?")")
            }
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

    func testAuthzGrantSnapshotIsDurableAndTheWriterMatchesTheFrozenVector() throws {
        XCTAssertTrue(BotEventEnvelopeCodec.isDurable("authz.grant_snapshot"))
        XCTAssertTrue(BotEventEnvelopeCodec.isDurable(BotGrantSnapshot.eventType))

        let fixture = try loadPhoneFixture()
        let valid = try XCTUnwrap(fixture["validCases"] as? [[String: Any]])
        let vector = try XCTUnwrap(valid.first { $0["name"] as? String == "authz-grant-snapshot" })
        let eventObject = vector["event"] as! [String: Any]
        let codec = BotEventEnvelopeCodec()
        let goldenEvent = try codec.decode(JSONSerialization.data(withJSONObject: eventObject))
        let grants = try BotGrantSnapshot.decode(goldenEvent, now: 0)

        let written = try BotGrantSnapshot.event(grants: grants, at: goldenEvent.time)
        XCTAssertEqual(written.type, "authz.grant_snapshot")
        XCTAssertEqual(written.ignorable, true)
        XCTAssertNil(written.commitSeq)
        XCTAssertEqual(try written.data.encoded(), try goldenEvent.data.encoded())
        try BotEventEnvelopeCodec.validate(written, mode: .append)

        // The writer's snapshot data in the frozen event shape is byte-identical
        // to the vector the bot record published.
        let frozenShape = BotEvent(
            type: written.type, eventId: goldenEvent.eventId, commitSeq: goldenEvent.commitSeq,
            time: written.time, origin: written.origin, traceId: goldenEvent.traceId,
            principal: written.principal, causationId: nil, correlationId: nil,
            ignorable: true, data: written.data)
        XCTAssertEqual(try codec.encode(frozenShape), try canonicalEventData(eventObject))

        let stored = written.assigningCommitSeq(goldenEvent.commitSeq)
        let roundTripped = try codec.decode(try codec.encode(stored))
        XCTAssertEqual(roundTripped.data, goldenEvent.data)
        XCTAssertEqual(try BotGrantSnapshot.decode(roundTripped, now: 0), grants)
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
