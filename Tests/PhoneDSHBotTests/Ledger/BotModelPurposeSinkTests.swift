// SPDX-License-Identifier: MIT
// P12 type sink regression (PC-20261113-p12-model-purpose-sink §2,
// spec/bot/v1/README.md §2.10).
//
// The enforcer's pure policy types live in `PhoneDSHAgentCore`; `PhoneDSHBot`
// keeps its external names as aliases. These assertions are compile-time where
// possible: a cross-module assignment only compiles when both names denote the
// same type, and `ObjectIdentifier` proves there is no second declaration.

import XCTest
import PhoneDSHAgentCore
@testable import PhoneDSHBot

final class BotModelPurposeSinkTests: XCTestCase {
    func testBotNamesResolveToTheAgentCoreTypes() {
        // Compile-time proof: each `let` would fail to compile if the Bot name
        // were a second type instead of an alias of the AgentCore type.
        let purpose: PhoneDSHAgentCore.BotModelPurpose = .workerTurn
        let request: PhoneDSHAgentCore.BotModelRequest =
            BotModelRequest(purpose: purpose, model: "deepseek-flash")
        let gate: PhoneDSHAgentCore.BotModelPurposeGate = BotModelPurposeGate()
        let policy: PhoneDSHAgentCore.BotModelPurposePolicy = BotModelPurposePolicy.frozen
        let row: PhoneDSHAgentCore.BotModelPurposeRow = policy.purposes[0]
        let defaults: PhoneDSHAgentCore.BotModelPurposeDefaults = row.defaults
        let tier: PhoneDSHAgentCore.BotModelTier = .small
        let error: PhoneDSHAgentCore.BotModelPurposeError = .init(
            code: "EPURPOSE_MODEL_DENIED", purpose: .triage, model: "deepseek-v4-pro",
            message: "denied")

        // Runtime proof: same metatype for all eight public names.
        let pairs: [(Any.Type, Any.Type)] = [
            (BotModelPurpose.self, PhoneDSHAgentCore.BotModelPurpose.self),
            (BotModelPurposeDefaults.self, PhoneDSHAgentCore.BotModelPurposeDefaults.self),
            (BotModelPurposeRow.self, PhoneDSHAgentCore.BotModelPurposeRow.self),
            (BotModelPurposePolicy.self, PhoneDSHAgentCore.BotModelPurposePolicy.self),
            (BotModelTier.self, PhoneDSHAgentCore.BotModelTier.self),
            (BotModelPurposeError.self, PhoneDSHAgentCore.BotModelPurposeError.self),
            (BotModelRequest.self, PhoneDSHAgentCore.BotModelRequest.self),
            (BotModelPurposeGate.self, PhoneDSHAgentCore.BotModelPurposeGate.self),
        ]
        for (botName, agentCoreName) in pairs {
            XCTAssertEqual(ObjectIdentifier(botName), ObjectIdentifier(agentCoreName),
                           "\(botName) and \(agentCoreName) must be one type")
        }

        XCTAssertEqual(request.purpose, .workerTurn)
        XCTAssertEqual(gate.policy, BotModelPurposePolicy.frozen)
        XCTAssertEqual(defaults, BotModelPurposePolicy.defaults(for: .frontTurn))
        XCTAssertEqual(policy, PhoneDSHAgentCore.BotModelPurposePolicy.frozen)
        XCTAssertEqual(tier, .small)
        XCTAssertEqual(error.code, "EPURPOSE_MODEL_DENIED")
    }

    /// The Bot name keeps driving the real enforcer (not a copy): the frozen
    /// policy and the gate decisions are identical through either name.
    func testGateStillDrivesTheOneEnforcerThroughTheBotName() throws {
        XCTAssertEqual(BotModelPurposePolicy.frozen,
                       PhoneDSHAgentCore.BotModelPurposePolicy.frozen)
        XCTAssertEqual(BotModelPurpose.allCases,
                       PhoneDSHAgentCore.BotModelPurpose.allCases)

        XCTAssertEqual(try BotModelPurposeGate().authorize(
            purpose: .frontTurn, model: "deepseek-v4-pro"), "deepseek-v4-pro")
        XCTAssertThrowsError(try BotModelPurposeGate().authorize(
            purpose: .triage, model: "deepseek-v4-pro")) { error in
            XCTAssertEqual((error as? PhoneDSHAgentCore.BotModelPurposeError)?.code,
                           "EPURPOSE_MODEL_DENIED")
        }
        XCTAssertThrowsError(try BotModelPurposeGate().authorize(
            purpose: nil, model: "deepseek-flash")) { error in
            XCTAssertEqual((error as? BotModelPurposeError)?.code, "EPURPOSE_MODEL_DENIED")
        }
    }
}
