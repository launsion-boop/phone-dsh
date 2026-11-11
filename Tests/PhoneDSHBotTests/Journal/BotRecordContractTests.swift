// SPDX-License-Identifier: MIT

import XCTest
@testable import PhoneDSHBot

final class BotRecordReferenceTests: XCTestCase {
    func testSharedVectorsParseCanonicalizeAndReject() throws {
        let fixture = try BotGoldenFixture.rawObject("record-reference.phone")
        let valid = try XCTUnwrap(fixture["valid"] as? [[String: Any]])
        for vector in valid {
            let input = try XCTUnwrap(vector["input"] as? String)
            let reference = try XCTUnwrap(BotRecordReference.parse(input),
                                          "valid vector \(vector["name"] ?? "?") was rejected")
            XCTAssertEqual(reference.canonical, vector["canonical"] as? String)
            XCTAssertEqual(reference.kind, vector["kind"] as? String)
            if let sessionID = vector["sessionId"] as? String {
                XCTAssertEqual(reference.sessionID, sessionID)
                XCTAssertEqual(reference.seq, vector["seq"] as? Int)
            }
            if let commitSeq = vector["commitSeq"] as? Int {
                XCTAssertEqual(reference.commitSeq, commitSeq)
            }
        }
        let invalid = try XCTUnwrap(fixture["invalid"] as? [[String: Any]])
        for vector in invalid {
            let input = try XCTUnwrap(vector["input"] as? String)
            XCTAssertNil(BotRecordReference.parse(input),
                         "invalid vector \(vector["name"] ?? "?") was accepted")
        }
    }

    func testJSONSafeBoundaryAndDotSessionIDs() {
        XCTAssertNotNil(BotRecordReference.parse("record://session/gb-1#9007199254740991"))
        XCTAssertNil(BotRecordReference.parse("record://session/gb-1#9007199254740992"))
        XCTAssertNil(BotRecordReference.parse("record://session/.#1"))
        XCTAssertNil(BotRecordReference.parse("record://session/..#1"))
        XCTAssertEqual(BotRecordReference.parse("  RECORD://SESSION/gb-1#0007\n")?.canonical,
                       "record://session/gb-1#7")
    }
}

final class BotObservationEnvelopeTests: XCTestCase {
    func testSharedEnvelopeVectorsUseRealCodec() throws {
        let fixture = try BotGoldenFixture.rawObject("observation-envelope.phone")
        let valid = try XCTUnwrap(fixture["valid"] as? [[String: Any]])
        for vector in valid {
            let object = try XCTUnwrap(vector["envelope"] as? [String: Any])
            let envelope = BotObservationEnvelope(
                source: try XCTUnwrap(object["source"] as? String),
                origin: try XCTUnwrap(object["origin"] as? String),
                at: try XCTUnwrap(object["at"] as? String),
                owner: try XCTUnwrap(object["owner"] as? String),
                ref: try XCTUnwrap(object["ref"] as? String),
                text: try XCTUnwrap(object["text"] as? String))
            XCTAssertEqual(envelope.encoded(), vector["encoded"] as? String,
                           "encoding mismatch for \(vector["name"] ?? "?")")
            XCTAssertEqual(BotObservationEnvelope.decode(envelope.encoded()), envelope)
        }
        let invalid = try XCTUnwrap(fixture["invalid"] as? [[String: Any]])
        for vector in invalid {
            let object = try XCTUnwrap(vector["envelope"] as? [String: Any])
            let accepted = Set(object.keys) == Set(BotObservationEnvelope.attributes)
                && BotObservationEnvelope(
                    validatedSource: object["source"] as? String ?? "",
                    origin: object["origin"] as? String ?? "",
                    at: object["at"] as? String ?? "",
                    owner: object["owner"] as? String ?? "",
                    ref: object["ref"] as? String ?? "",
                    text: object["text"] as? String ?? "") != nil
            XCTAssertFalse(accepted, "invalid envelope \(vector["name"] ?? "?") was accepted")
        }
        let decodeErrors = try XCTUnwrap(fixture["decodeErrors"] as? [[String: Any]])
        for vector in decodeErrors {
            XCTAssertNil(BotObservationEnvelope.decode(vector["encoded"] as? String ?? ""),
                         "decode error \(vector["name"] ?? "?") was accepted")
        }
    }

    func testEnvelopeSourceBoundaryAndTrailingTraceShape() throws {
        XCTAssertNotNil(BotObservationEnvelope(
            source: "web", origin: "https://example.com", at: "2026-11-11T07:00:00.000Z",
            owner: "unknown", reference: .session(sessionID: "gb-main", seq: 3), text: "ok"))
        XCTAssertNil(BotObservationEnvelope(
            source: "bash", origin: "bash", at: "2026-11-11T07:00:00.000Z",
            owner: "unknown", reference: .session(sessionID: "gb-main", seq: 3), text: "ok"))
        let encoded = BotObservationEnvelope(
            source: "agent", origin: "agent:bot-b", at: "2026-11-11T07:00:00.000Z",
            owner: "agent:bot-b", ref: "record://event/9", text: "before </observation> after").encoded()
        XCTAssertTrue(encoded.contains("\\u003c/observation>"))
        XCTAssertEqual(encoded.components(separatedBy: "</observation>").count - 1, 1)
        let control = try XCTUnwrap(BotObservationEnvelope(
            validatedSource: "tool", origin: "line\nnext", at: "2026-11-11T07:00:00.000Z",
            owner: "unknown", ref: "record://event/9", text: "ok"))
        XCTAssertEqual(BotObservationEnvelope.decode(control.encoded()), control)
    }
}
