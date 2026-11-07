// SPDX-License-Identifier: MIT

import XCTest
@testable import PhoneDSHBot

final class BotModelPurposePolicyTests: XCTestCase {
    func testFrozenGoldenMatchesEveryPurposeDefaultAndLargeModelGate() throws {
        let fixture = try botGolden("model-purpose-policy")
        let policy = try botDecode(BotModelPurposePolicy.self, fixture["valid"]!)
        XCTAssertEqual(policy, .frozen)
        XCTAssertEqual(policy.largeModelPurposes, [.frontTurn, .workerTurn])
        XCTAssertEqual(policy.purposes.count, 8)

        for purpose in BotModelPurpose.allCases {
            XCTAssertEqual(BotModelPurposePolicy.allowsLargeModel(purpose), purpose.largeModelAllowed)
            XCTAssertEqual(BotModelPurposePolicy.defaults(for: purpose), policy.purposes.first { $0.purpose == purpose }?.defaults)
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
