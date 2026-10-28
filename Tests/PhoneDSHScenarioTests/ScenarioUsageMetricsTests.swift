// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — G2 scenario runner: upstream byte provenance tests.
//
// G2-FIX-7/G2-FIX-126: the report inferred byte direction from the bounded
// response log (request bytes hard-coded to 0) even though ModelGateway already
// exposes bytesUp/bytesDown. These tests pin the projection and its provenance.

import Foundation
import XCTest
import PhoneDSH
import PhoneDSHGateway
@testable import PhoneDSHScenario

final class ScenarioUsageMetricsTests: XCTestCase {
    func testRealRunProjectsGatewayBytesInBothDirections() {
        let metrics = ModelGatewayMetrics(bytesUp: 1_234, bytesDown: 56_789)
        let bytes = ScenarioUsageMetrics.real(gatewayMetrics: metrics,
                                              responseLogBytes: 999)
        XCTAssertEqual(bytes.bytesIn, 1_234,
                       "request bytes must come from the gateway, not 0")
        XCTAssertEqual(bytes.bytesOut, 56_789,
                       "response bytes must come from the gateway")
        XCTAssertEqual(bytes.source, .gatewayMetrics)
        XCTAssertEqual(bytes.source.rawValue, "gateway_metrics")
    }

    func testRealRunWithoutGatewaySnapshotUsesTheLabelledFallback() {
        let bytes = ScenarioUsageMetrics.real(gatewayMetrics: nil,
                                              responseLogBytes: 4_096)
        XCTAssertEqual(bytes.bytesIn, 0)
        XCTAssertEqual(bytes.bytesOut, 4_096)
        XCTAssertEqual(bytes.source, .responseLogFallback)
        XCTAssertEqual(bytes.source.rawValue, "response_log_fallback")
    }

    func testMockRunKeepsRequestAndResponseDirections() {
        let bytes = ScenarioUsageMetrics.mock(requestBytes: 321,
                                              responseBytes: 654)
        XCTAssertEqual(bytes.bytesIn, 321,
                       "the mock request is inbound for the mock, outbound for the run")
        XCTAssertEqual(bytes.bytesOut, 654)
        XCTAssertEqual(bytes.source, .mock)
        XCTAssertEqual(bytes.source.rawValue, "mock")
    }

    func testFallbackSumsResponseLogBodyFilesOnly() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdsh-usage-log-\(UUID().uuidString)",
                                    isDirectory: true)
        let first = root.appendingPathComponent("one", isDirectory: true)
        let second = root.appendingPathComponent("two", isDirectory: true)
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 10).write(to: first.appendingPathComponent("body"))
        try Data(repeating: 2, count: 20).write(to: second.appendingPathComponent("body"))
        try Data(repeating: 3, count: 99).write(to: second.appendingPathComponent("meta"))
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }

        XCTAssertEqual(ScenarioUsageMetrics.responseLogBytes(in: root), 30,
                       "only response-log body files contribute")
    }

    func testDiagnosticsCarriesTheGatewaySnapshot() {
        let metrics = ModelGatewayMetrics(bytesUp: 7, bytesDown: 11)
        let diagnostics = PhoneDSHDiagnostics(state: .stopped,
                                              bootID: String(repeating: "0", count: 32),
                                              gatewayMetrics: metrics)
        XCTAssertEqual(diagnostics.gatewayMetrics, metrics)
    }
}
