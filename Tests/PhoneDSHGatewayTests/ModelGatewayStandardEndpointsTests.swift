// SPDX-License-Identifier: MIT
// phone-dsh — the standard model endpoint set hosts opt into POST retries.

import Foundation
import XCTest
import PhoneDSHGateway

final class ModelGatewayStandardEndpointsTests: XCTestCase {
    func testBaseWithPathYieldsTheFourProviderEndpoints() {
        let endpoints = ModelGatewayConfiguration.standardModelEndpoints(
            baseURL: URL(string: "https://api.example.invalid/anthropic/")!)
        XCTAssertEqual(endpoints, [
            "https://api.example.invalid/anthropic/v1/messages",
            "https://api.example.invalid/anthropic/messages",
            "https://api.example.invalid/anthropic/v1/chat/completions",
            "https://api.example.invalid/anthropic/chat/completions",
        ])
    }

    func testPortIsKeptAndQueryFragmentAndUserinfoAreDropped() {
        let endpoints = ModelGatewayConfiguration.standardModelEndpoints(
            baseURL: URL(string: "http://user:pw@127.0.0.1:8080/v1?api-version=1#x")!)
        XCTAssertTrue(endpoints.contains("http://127.0.0.1:8080/v1/v1/messages"))
        XCTAssertTrue(endpoints.contains("http://127.0.0.1:8080/v1/chat/completions"))
        XCTAssertFalse(endpoints.contains { $0.contains("?") || $0.contains("#") || $0.contains("@") })
    }

    func testUnusableBaseYieldsNothing() {
        XCTAssertEqual(ModelGatewayConfiguration.standardModelEndpoints(baseURL: URL(string: "file:///tmp/x")!), [])
        XCTAssertEqual(ModelGatewayConfiguration.standardModelEndpoints(baseURL: URL(string: "https:relative")!), [])
    }
}
