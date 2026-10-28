// SPDX-License-Identifier: MIT
// W0 skeleton checks for PhoneDSHLoopback (PLAN §2.1/§2.2).

import Foundation
import XCTest
import PhoneDSHLoopback

final class LoopbackSkeletonTests: XCTestCase {
    func testConfigurationBindsLoopbackAndRandomPort() {
        let configuration = LoopbackConfiguration(token: "test-token")
        XCTAssertEqual(configuration.host, "127.0.0.1")
        XCTAssertEqual(LoopbackConfiguration.loopbackHost, "127.0.0.1")
        XCTAssertEqual(configuration.port, 0)
        XCTAssertTrue(configuration.crossOriginIsolation)
        XCTAssertEqual(configuration.token, "test-token")
    }

    func testCachePoliciesHaveDistinctRawValues() {
        XCTAssertEqual(Set(LoopbackCachePolicy.allCases.map(\.rawValue)),
                       ["static", "lazy", "noStore"])
    }

    func testRouteEquality() {
        XCTAssertEqual(LoopbackRoute.channelUpgrade, .channelUpgrade)
        XCTAssertNotEqual(LoopbackRoute.modelGateway, .notFound)
    }
}
