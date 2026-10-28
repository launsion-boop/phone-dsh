// SPDX-License-Identifier: MIT
// The Worker environment the host injects at boot (D24): the egress
// allow-list reaches the Worker's capability manifest as `PDSH_EGRESS_ALLOW`
// so the agent knows which hosts `curl` may reach without probing.

import Foundation
import XCTest
@testable import PhoneDSH

final class PhoneDSHWorkerEnvironmentTests: XCTestCase {
    func testEgressAllowValueIsSortedAndCommaSeparated() {
        XCTAssertEqual(
            PhoneDSHHost.egressAllowEnvironmentValue(["weather.example", "api.weather.example", " *.corp.example "]),
            "*.corp.example,api.weather.example,weather.example")
        XCTAssertEqual(PhoneDSHHost.egressAllowEnvironmentValue(["*"]), "*")
    }

    func testNoEgressHostsMeansNoVariable() {
        XCTAssertNil(PhoneDSHHost.egressAllowEnvironmentValue([]))
        XCTAssertNil(PhoneDSHHost.egressAllowEnvironmentValue([" ", ""]))
    }

    func testEnvironmentNameMatchesTheWorkerEntry() {
        XCTAssertEqual(PhoneDSHWorkerEnvironment.egressAllow, "PDSH_EGRESS_ALLOW")
    }
}
