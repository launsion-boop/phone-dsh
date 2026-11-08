// SPDX-License-Identifier: MIT
// The Worker environment the host injects at boot (D24): the egress
// allow-list reaches the Worker's capability manifest as `PDSH_EGRESS_ALLOW`
// so the agent knows which hosts `curl` may reach without probing.

import Foundation
import XCTest
import PhoneDSHLoopback
@testable import PhoneDSH

private final class StubNativeMCP: NativeMCPServing, @unchecked Sendable {
    func handle(_ request: LoopbackRequest) async -> NativeMCPResponse { NativeMCPResponse() }
}

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

    func testBotEndpointWinsOverNativeMCPWhenBothAreConfigured() {
        let endpoint = LoopbackEndpoint(baseURL: URL(string: "http://127.0.0.1:41000")!,
                                        token: "loopback-token")
        var environment = [
            "PDSH_PHONE_MCP_URL": "http://127.0.0.1:42000/mcp",
            "PDSH_PHONE_MCP_TOKEN": "phone-host-injects-bot-mcp-token",
        ]
        PhoneDSHHost.applyConfiguredMCPEnvironment(&environment, endpoint: endpoint,
                                                   nativeMCP: StubNativeMCP())
        XCTAssertEqual(environment["PDSH_PHONE_MCP_URL"], "http://127.0.0.1:42000/mcp")
        XCTAssertEqual(environment["PDSH_PHONE_MCP_TOKEN"], "phone-host-injects-bot-mcp-token")
    }

    func testNativeOnlyConfigurationKeepsLegacyNativeMCPEndpoint() {
        let endpoint = LoopbackEndpoint(baseURL: URL(string: "http://127.0.0.1:41000")!,
                                        token: "loopback-token")
        var environment: [String: String] = [:]
        PhoneDSHHost.applyConfiguredMCPEnvironment(&environment, endpoint: endpoint,
                                                   nativeMCP: StubNativeMCP())
        XCTAssertEqual(environment["PDSH_PHONE_MCP_URL"],
                       "http://127.0.0.1:41000/mcp/native")
        XCTAssertEqual(environment["PDSH_PHONE_MCP_TOKEN"], "loopback-token")
    }

    func testNoNativeMCPLeavesEnvironmentUntouched() {
        let endpoint = LoopbackEndpoint(baseURL: URL(string: "http://127.0.0.1:41000")!,
                                        token: "loopback-token")
        var environment: [String: String] = [:]
        PhoneDSHHost.applyConfiguredMCPEnvironment(&environment, endpoint: endpoint, nativeMCP: nil)
        XCTAssertTrue(environment.isEmpty)
    }
}
