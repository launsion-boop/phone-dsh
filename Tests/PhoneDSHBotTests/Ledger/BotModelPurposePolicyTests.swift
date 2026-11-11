// SPDX-License-Identifier: MIT

import XCTest
@testable import PhoneDSHBot

final class BotModelPurposePolicyTests: XCTestCase {
    func testFrozenGoldenMatchesEveryPurposeDefaultAndLargeModelGate() throws {
        let fixture = try botGolden("model-purpose-policy")
        let policy = try botDecode(BotModelPurposePolicy.self, fixture["valid"]!)
        XCTAssertEqual(policy.largeModelPurposes, [.frontTurn, .workerTurn])
        XCTAssertEqual(policy.purposes.count, 8)
        // The phone-only maintenance purpose is additive: the upstream golden
        // still has eight rows, and .frozen has one extra row.
        XCTAssertEqual(BotModelPurposePolicy.frozen.purposes.count,
                       BotModelPurpose.allCases.count)
        for row in policy.purposes {
            XCTAssertEqual(BotModelPurposePolicy.frozen.purposes.first {
                $0.purpose == row.purpose
            }, row)
        }
        XCTAssertNotNil(BotModelPurposePolicy.frozen.purposes.first {
            $0.purpose == .memoryMaintenance
        })

        for purpose in BotModelPurpose.allCases {
            XCTAssertEqual(BotModelPurposePolicy.allowsLargeModel(purpose), purpose.largeModelAllowed)
            if let goldenRow = policy.purposes.first(where: { $0.purpose == purpose }) {
                XCTAssertEqual(BotModelPurposePolicy.defaults(for: purpose), goldenRow.defaults)
            } else {
                // Additive phone-only purpose: not in the shared upstream rows.
                XCTAssertEqual(
                    BotModelPurposePolicy.defaults(for: purpose),
                    BotModelPurposePolicy.frozen.purposes.first { $0.purpose == purpose }?.defaults)
            }
            if purpose.largeModelAllowed {
                XCTAssertEqual(try BotModelPurposePolicy.assertModelAllowed(purpose: purpose, model: " deepseek-v4-pro "), "deepseek-v4-pro")
            } else {
                for model in ["deepseek-v4-pro", "deepseek-chat", "vendor/opus-latest", "unknown-model"] {
                    XCTAssertThrowsError(try BotModelPurposePolicy.assertModelAllowed(purpose: purpose, model: model)) { error in
                        XCTAssertEqual((error as? BotModelPurposeError)?.code, "EPURPOSE_MODEL_DENIED")
                    }
                }
                XCTAssertEqual(try BotModelPurposePolicy.assertModelAllowed(purpose: purpose, model: "deepseek-flash"), "deepseek-flash")
            }
        }
    }

    func testFrozenInvalidVectorFailsClosedWithStableCode() throws {
        let fixture = try botGolden("model-purpose-policy")
        for vector in fixture["invalid"] as! [[String: Any]] {
            let purpose = BotModelPurpose(rawValue: vector["purpose"] as! String)!
            XCTAssertThrowsError(try BotModelPurposePolicy.assertModelAllowed(
                purpose: purpose, model: vector["model"] as! String)) { error in
                let purposeError = error as? BotModelPurposeError
                XCTAssertEqual(purposeError?.code, vector["code"] as? String)
                XCTAssertEqual(purposeError?.purpose, purpose)
                XCTAssertEqual(purposeError?.model, vector["model"] as? String)
            }
        }
        XCTAssertThrowsError(try BotModelPurposePolicy.assertModelAllowed(purpose: .frontTurn, model: " ")) { error in
            XCTAssertEqual((error as? BotModelPurposeError)?.code, "EPURPOSE_MODEL_REQUIRED")
        }
    }
}
