// SPDX-License-Identifier: MIT
// W0 skeleton checks for PhoneDSH (PLAN §2.1/§2.5).

import Foundation
import XCTest
import PhoneDSHController
import PhoneDSH

final class PhoneDSHSkeletonTests: XCTestCase {
    func testConfigurationDefaults() throws {
        let origin = try XCTUnwrap(URL(string: "http://127.0.0.1:8080"))
        let configuration = PhoneDSHConfiguration(
            workspaceRoot: FileManager.default.temporaryDirectory.appendingPathComponent("workspace"),
            token: "test-token",
            origin: origin)
        XCTAssertEqual(configuration.deviceTier, .eightGB)
        XCTAssertEqual(configuration.budgets, BudgetTable.eightGB)
        XCTAssertEqual(configuration.loopback.host, "127.0.0.1")
        XCTAssertEqual(configuration.loopback.port, 0)
        XCTAssertEqual(configuration.engine.visibleAreaPoints, 1)
        XCTAssertEqual(configuration.log.walQuotaBytes, 512 * 1024 * 1024)
        XCTAssertEqual(configuration.gateway.responseLogQuotaBytes, 128 * 1024 * 1024)
    }

    func testFacadeStates() {
        XCTAssertEqual(PhoneDSHState.allCases, [.stopped, .starting, .running,
                                                .draining, .remote, .failed])
    }

    func testDiagnosticsDefaults() {
        let diagnostics = PhoneDSHDiagnostics(
            state: .starting, bootID: "00112233445566778899aabbccddeeff")
        XCTAssertEqual(diagnostics.nextMseq, 1)
        XCTAssertEqual(diagnostics.ackedMseq, 0)
        XCTAssertEqual(diagnostics.durableMseq, 0)
        XCTAssertNil(diagnostics.lastError)
    }
}
