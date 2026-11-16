// SPDX-License-Identifier: MIT

import XCTest
@testable import PhoneDSHBot

final class BotSkillUseGateTests: XCTestCase {
    func testOnlyCurrentIsAllowed() {
        XCTAssertEqual(BotSkillUseGate.decide(status: .current), .allowed)
        for status in [BotProvenanceStatus.changed, .unavailable, .revoked,
                       .erased, .unknown] {
            let decision = BotSkillUseGate.decide(
                status: status, reasons: [.refreshNotPerformed])
            XCTAssertEqual(decision, .denied(
                status: status, reasons: [.refreshNotPerformed]))
            XCTAssertEqual(decision.denialCode, "skill-provenance-\(status.rawValue)")
        }
    }

    func testUnknownIsNeverCurrent() {
        let decision = BotSkillUseGate.decide(status: .unknown)
        XCTAssertNotEqual(decision, .allowed)
        XCTAssertEqual(decision.denialCode, "skill-provenance-unknown")
    }
}
