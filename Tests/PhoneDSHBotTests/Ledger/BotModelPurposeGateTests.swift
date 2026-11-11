// SPDX-License-Identifier: MIT

import Foundation
import XCTest
@testable import PhoneDSHBot

/// Drives the enforcement gate with `golden/model-purpose-enforcement.phone.json`.
final class BotModelPurposeGateTests: XCTestCase {
    private func golden() throws -> [String: Any] {
        let data = try BotGoldenFixture.rawData("model-purpose-enforcement.phone")
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testValidVectorsAreAllowedAtTheGate() throws {
        let valid = try XCTUnwrap(golden()["valid"] as? [[String: Any]])
        XCTAssertFalse(valid.isEmpty)
        for entry in valid {
            let purpose = try XCTUnwrap(entry["purpose"] as? String)
            let model = try XCTUnwrap(entry["model"] as? String)
            XCTAssertEqual(entry["allowed"] as? Bool, true)
            XCTAssertNoThrow(try BotModelPurposeGate().authorize(
                purposeName: purpose, model: model))
        }
    }

    func testInvalidVectorsFailClosedWithTheFrozenCode() throws {
        let invalid = try XCTUnwrap(golden()["invalid"] as? [[String: Any]])
        XCTAssertFalse(invalid.isEmpty)
        for entry in invalid {
            let purpose = try XCTUnwrap(entry["purpose"] as? String)
            let model = try XCTUnwrap(entry["model"] as? String)
            let expected = try XCTUnwrap(entry["code"] as? String)
            XCTAssertEqual(entry["allowed"] as? Bool, false)
            XCTAssertThrowsError(try BotModelPurposeGate().authorize(
                purposeName: purpose, model: model)) { error in
                guard let purposeError = error as? BotModelPurposeError else {
                    return XCTFail("unexpected error \(error)")
                }
                if expected == "EPURPOSE_MODEL_REQUIRED" {
                    XCTAssertEqual(purposeError.code, expected)
                } else {
                    // Unknown purposes and denied models share the frozen
                    // denial code; both must never widen the model.
                    XCTAssertEqual(purposeError.code, "EPURPOSE_MODEL_DENIED")
                }
            }
        }
    }

    func testProviderAndAuthorizedPurposeReachTheLedgerRecordPoint() throws {
        let request = BotModelRequest(purpose: .completionCheck,
                                      model: "deepseek-flash", provider: "deepseek-official")
        XCTAssertEqual(request.provider, "deepseek-official")
        XCTAssertEqual(BotModelPurposeGate.ledgerPurpose(request), .completionCheck)
        XCTAssertEqual(try BotModelPurposeGate().authorize(request), "deepseek-flash")
        let unknown = BotModelRequest(purposeName: "not-a-purpose", model: "deepseek-flash")
        XCTAssertNil(BotModelPurposeGate.ledgerPurpose(unknown))
    }

    func testMissingPurposeAndProfilePromotionAreDenied() {
        XCTAssertThrowsError(try BotModelPurposeGate().authorize(purpose: nil, model: "deepseek-flash"))
        let widened = BotModelPurposePolicy(
            purposes: BotModelPurposePolicy.frozen.purposes,
            largeModelPurposes: [.frontTurn, .workerTurn, .triage])
        XCTAssertThrowsError(try BotModelPurposeGate(policy: widened)
            .authorize(purpose: .triage, model: "deepseek-v4-pro")) { error in
                XCTAssertEqual((error as? BotModelPurposeError)?.code, "EPURPOSE_MODEL_DENIED")
            }
    }
}
