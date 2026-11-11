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

    func testPhoneGoldenAgentCommUsesRealEncoderAndDecoder() throws {
        let fixture = try loadPhoneFixture()
        let valid = fixture["validCases"] as! [[String: Any]]
        XCTAssertEqual(valid.count, 3)
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
            default:
                XCTAssertEqual(decoded.type, "agent.comm")
                XCTAssertEqual(decoded.origin, .local(source: "comm-service"))
                XCTAssertEqual(decoded.principal.kind, "team")
            }
            XCTAssertEqual(try codec.decode(codec.encode(decoded)), decoded)
        }

        let invalid = fixture["invalidCases"] as! [[String: Any]]
        XCTAssertFalse(invalid.isEmpty)
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
