// SPDX-License-Identifier: MIT

import XCTest
@testable import PhoneDSHAgentCore

final class DSHRemoteHarnessConfigurationTests: XCTestCase {
    func testNonIANAIdentifierFallsBackToUTC() {
        XCTAssertEqual(DSHRemoteHarness.Configuration(timeZone: "GMT+0000").timeZone, "UTC")
        XCTAssertEqual(DSHRemoteHarness.Configuration(timeZone: "Mars/Olympus").timeZone, "UTC")
    }

    func testValidIANAIdentifiersArePreserved() {
        XCTAssertEqual(DSHRemoteHarness.Configuration(timeZone: "Asia/Shanghai").timeZone, "Asia/Shanghai")
        XCTAssertEqual(DSHRemoteHarness.Configuration(timeZone: "UTC").timeZone, "UTC")
    }

    func testEmptyIdentifierRemainsAbsent() {
        XCTAssertNil(DSHRemoteHarness.Configuration(timeZone: nil).timeZone)
        XCTAssertNil(DSHRemoteHarness.Configuration(timeZone: "  ").timeZone)
    }
}
