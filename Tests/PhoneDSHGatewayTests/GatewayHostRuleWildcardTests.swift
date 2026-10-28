// SPDX-License-Identifier: MIT
// Wildcard entries of the gateway allow-list: `*` (every host) and
// `*.corp.example` (one domain). An App that wants unrestricted egress sets a
// single `*`; the credential provider still decides per host what, if
// anything, is attached, so the wildcard widens reach without leaking keys.

import Foundation
import XCTest
@testable import PhoneDSHGateway

final class GatewayHostRuleWildcardTests: XCTestCase {
    private func url(_ text: String) throws -> URL { try XCTUnwrap(URL(string: text)) }

    func testStarAdmitsEveryHTTPHost() throws {
        let rule = try XCTUnwrap(GatewayHostRule(rawValue: "*"))
        XCTAssertTrue(rule.isWildcard)
        XCTAssertTrue(rule.matches(try url("https://weather.example/city?format=3")))
        XCTAssertTrue(rule.matches(try url("http://host.example:8080/")))
        XCTAssertFalse(rule.matches(try url("ftp://host.example/")))
    }

    func testStarStillHonoursSchemeAndPort() throws {
        let https = try XCTUnwrap(GatewayHostRule(rawValue: "https://*"))
        XCTAssertTrue(https.matches(try url("https://api.weather.example/v1/forecast")))
        XCTAssertFalse(https.matches(try url("http://api.weather.example/v1/forecast")))
        let port = try XCTUnwrap(GatewayHostRule(rawValue: "*:8443"))
        XCTAssertTrue(port.matches(try url("https://a.corp.example:8443/")))
        XCTAssertFalse(port.matches(try url("https://a.corp.example/")))
    }

    func testDefaultPortRuleMatchesSerializedURLWithoutThePort() throws {
        let https = try XCTUnwrap(GatewayHostRule(rawValue: "https://api.example.test:443"))
        XCTAssertTrue(https.matches(try url("https://api.example.test/v1/messages")))
        XCTAssertTrue(https.matches(try url("https://api.example.test:443/v1/messages")))
        XCTAssertFalse(https.matches(try url("https://api.example.test:8443/v1/messages")))

        let http = try XCTUnwrap(GatewayHostRule(rawValue: "api.example.test:80"))
        XCTAssertTrue(http.matches(try url("http://api.example.test/v1/messages")))
        XCTAssertFalse(http.matches(try url("https://api.example.test/v1/messages")))
    }

    func testDomainWildcardAdmitsApexAndSubdomainsOnly() throws {
        let rule = try XCTUnwrap(GatewayHostRule(rawValue: "*.corp.example"))
        XCTAssertTrue(rule.isWildcard)
        XCTAssertTrue(rule.matches(try url("https://corp.example/")))
        XCTAssertTrue(rule.matches(try url("https://api.corp.example/")))
        XCTAssertTrue(rule.matches(try url("https://a.b.corp.example/")))
        XCTAssertFalse(rule.matches(try url("https://notcorp.example/")))
        XCTAssertFalse(rule.matches(try url("https://corp.example.evil.invalid/")))
    }

    func testExactRuleStaysExact() throws {
        let rule = try XCTUnwrap(GatewayHostRule(rawValue: "corp.example"))
        XCTAssertFalse(rule.isWildcard)
        XCTAssertTrue(rule.matches(try url("https://corp.example/")))
        XCTAssertFalse(rule.matches(try url("https://api.corp.example/")))
    }

    func testWildcardRulesAreNotPrewarmed() throws {
        XCTAssertNil(try XCTUnwrap(GatewayHostRule(rawValue: "*")).prewarmURL())
        XCTAssertNil(try XCTUnwrap(GatewayHostRule(rawValue: "*.corp.example")).prewarmURL())
        XCTAssertNotNil(try XCTUnwrap(GatewayHostRule(rawValue: "corp.example")).prewarmURL())
    }

    func testCoordinatorAdmitsThroughTheWildcard() throws {
        let wide = GatewaySessionCoordinator(
            allowedHosts: ["model.example", "*"].compactMap(GatewayHostRule.init(rawValue:)))
        XCTAssertTrue(wide.isAllowed(try url("https://weather.example/")))
        let strict = GatewaySessionCoordinator(
            allowedHosts: ["model.example"].compactMap(GatewayHostRule.init(rawValue:)))
        XCTAssertFalse(strict.isAllowed(try url("https://weather.example/")))
    }
}
