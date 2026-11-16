// SPDX-License-Identifier: MIT

import XCTest
@testable import PhoneDSHBot

final class ContextSourceCapabilityTests: XCTestCase {
    func testMatrixMarksIOSUnavailableAbilitiesUnsupported() throws {
        for id in ["third-party-notifications.read", "sms.read", "call-history.read"] {
            let entry = try XCTUnwrap(BotContextCapabilityMatrix.entry(id: id))
            XCTAssertEqual(entry.support, .unsupported, id)
            XCTAssertFalse(entry.reason.isEmpty, id)
            XCTAssertNil(entry.source)
        }
        XCTAssertEqual(BotContextCapabilityMatrix.entry(id: "android.notification-listener")?.support, .deferred)
        XCTAssertEqual(BotContextCapabilityMatrix.entry(id: "android.sms-call-log")?.support, .deferred)
        XCTAssertEqual(BotContextCapabilityMatrix.entry(id: "photos-library.enumerate")?.support, .unsupported)
        XCTAssertEqual(BotContextCapabilityMatrix.entry(id: "power.system-idle")?.support, .unsupported)
    }

    func testMatrixContainsEveryDeclaredSource() throws {
        for source in BotContextSourceKind.allCases {
            XCTAssertFalse(BotContextCapabilityMatrix.entries(for: source).isEmpty,
                           "missing capability rows for \(source.rawValue)")
        }
        XCTAssertEqual(BotContextCapabilityMatrix.support(for: .calendar), .supported)
        XCTAssertEqual(BotContextCapabilityMatrix.support(for: .contacts), .limited)
        XCTAssertEqual(BotContextCapabilityMatrix.support(for: .locationFence), .supported)
        XCTAssertEqual(BotContextCapabilityMatrix.support(for: .power), .supported)
        XCTAssertEqual(BotContextCapabilityMatrix.entry(id: "power.system-idle")?.support, .unsupported)
        XCTAssertEqual(BotContextCapabilityMatrix.support(for: .externalEntry), .supported)
    }

    func testCapabilityMatrixIsEncodableData() throws {
        let data = try BotContextCapabilityMatrix.matrixJSON()
        let decoded = try JSONDecoder().decode([BotContextCapability].self, from: data)
        XCTAssertEqual(decoded.count, BotContextCapabilityMatrix.all.count)
        XCTAssertTrue(decoded.contains { $0.id == "third-party-notifications.read" && $0.support == .unsupported })
    }

    func testInjectedDeliveryIsNotReal() {
        XCTAssertFalse(BotContextObservationDelivery.injected.isReal)
        XCTAssertTrue(BotContextObservationDelivery.os.isReal)
        XCTAssertEqual(BotContextObservationDelivery(rawValue: "os"), .os)
        XCTAssertNil(BotContextObservationDelivery(rawValue: "user"))
    }
}

final class ContextSourceObservationTests: XCTestCase {
    private func makeObservation(
        id: String = "calendar:changed:1",
        observedAt: Int64 = 1_000,
        revision: Int = 3,
        payload: BotJSONValue = .object(["changed": .bool(true)]),
        delivery: BotContextObservationDelivery = .os
    ) throws -> BotContextObservation {
        try BotContextObservation(
            id: id, source: .calendar, kind: .calendarChanged,
            observedAt: observedAt, permissionRevision: revision,
            sourceVersion: .unversioned(),
            uncertainty: BotContextUncertainty(level: .high, reason: "no-event-identity"),
            delivery: delivery, payload: payload,
            dedupeKey: "calendar:changed:1", wakeRequested: true)
    }

    func testCodableRoundTripPreservesSourceOwnerTimeRevisionUncertainty() throws {
        let bound = try makeObservation().bound(to: "bot-a", sessionID: "session-a")
        let data = try JSONEncoder().encode(bound)
        let decoded = try JSONDecoder().decode(BotContextObservation.self, from: data)
        XCTAssertEqual(decoded.source, .calendar)
        XCTAssertEqual(decoded.ownerBotID, "bot-a")
        XCTAssertEqual(decoded.observedAt, 1_000)
        XCTAssertEqual(decoded.permissionRevision, 3)
        XCTAssertEqual(decoded.uncertainty.level, .high)
        XCTAssertEqual(decoded.uncertainty.reason, "no-event-identity")
        XCTAssertEqual(decoded.delivery, .os)
        XCTAssertEqual(decoded.sourceVersion, .unversioned())
        XCTAssertEqual(decoded.payload, .object(["changed": .bool(true)]))
    }

    func testSourceVersionRejectsAnUnfrozenReason() throws {
        let json = Data(#"{"reason":"not-a-frozen-reason"}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(BotContextSourceVersion.self, from: json))
        XCTAssertThrowsError(try JSONDecoder().decode(
            BotContextSourceVersion.self,
            from: Data(#"{"basis":"not-a-basis","value":"x"}"#.utf8)))
        let unknown = try JSONDecoder().decode(
            BotContextSourceVersion.self,
            from: Data(#"{"reason":"source-unversioned"}"#.utf8))
        XCTAssertEqual(unknown, .unversioned())
    }

    func testCredentialShapedPayloadIsRejected() {
        XCTAssertThrowsError(try makeObservation(payload: .object([
            "token": .string("Bearer abcdefghijklmnop"),
        ]))) { error in
            XCTAssertEqual(error as? BotContextSourceError, .credentialShapeRejected)
        }
        XCTAssertThrowsError(try makeObservation(payload: .object([
            "note": .string("api_key=supersecretvalue"),
        ])))
    }

    func testOpenKindKeepsUnknownValueInsteadOfDropping() throws {
        let observation = try BotContextObservation(
            id: "x", source: .calendar,
            kind: BotContextObservationKind("calendar.future-kind"),
            observedAt: 1, permissionRevision: 0,
            sourceVersion: .unversioned(),
            uncertainty: BotContextUncertainty(level: .medium),
            delivery: .os, payload: .object([:]),
            dedupeKey: "x")
        XCTAssertFalse(observation.kind.isKnown)
        XCTAssertEqual(observation.kind.rawValue, "calendar.future-kind")
        let data = try JSONEncoder().encode(observation)
        let decoded = try JSONDecoder().decode(BotContextObservation.self, from: data)
        XCTAssertEqual(decoded.kind.rawValue, "calendar.future-kind")
    }

    func testPayloadMustBeObject() {
        XCTAssertThrowsError(try makeObservation(payload: .string("not-an-object")))
    }

    func testWakeReasonIsStableAndContainsNoPayload() throws {
        let observation = try makeObservation(payload: .object(["text": .string("secret-looking")]))
        XCTAssertEqual(observation.wakeReason, "context:calendar:calendar.changed")
        XCTAssertFalse(observation.wakeReason.contains("secret-looking"))
    }

    func testGeofenceValidation() throws {
        let fence = try BotContextGeofenceSpec(id: "office", latitude: 25.0, longitude: 121.5, radiusMeters: 100)
        XCTAssertEqual(fence.regionIdentifier, "pdsh.context.office")
        XCTAssertThrowsError(try BotContextGeofenceSpec(id: "office", latitude: 25.0, longitude: 121.5, radiusMeters: 5))
        XCTAssertThrowsError(try BotContextGeofenceSpec(id: "office:bad", latitude: 25.0, longitude: 121.5, radiusMeters: 100))
        XCTAssertThrowsError(try BotContextGeofenceSpec(id: "office", latitude: 95, longitude: 121.5, radiusMeters: 100))
    }

    func testUserSelectionValidatesSizeAndFingerprint() throws {
        let hash = BotContextUserSelection.fingerprint(Data("hello".utf8))
        let selection = try BotContextUserSelection(
            kind: .image, name: "receipt.jpg", mimeType: "image/jpeg",
            byteCount: 5, sha256: hash)
        XCTAssertEqual(selection.sha256, hash)
        XCTAssertThrowsError(try BotContextUserSelection(
            kind: .file, name: "x", mimeType: "application/pdf",
            byteCount: BotAttachmentPolicy.maxBytes + 1, sha256: hash))
        XCTAssertThrowsError(try BotContextUserSelection(
            kind: .file, name: "x", mimeType: "application/pdf",
            byteCount: 1, sha256: "not-a-sha"))
    }
}
