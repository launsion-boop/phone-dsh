// SPDX-License-Identifier: MIT
// W0 skeleton checks for PhoneDSHEngine (PLAN §2.1/§2.5).

import Foundation
import XCTest
import PhoneDSHEngine

final class WebEngineSkeletonTests: XCTestCase {
    func testConfigurationDefaults() throws {
        let origin = try XCTUnwrap(URL(string: "http://127.0.0.1:8080"))
        let configuration = WebEngineConfiguration(origin: origin)
        XCTAssertEqual(configuration.pagePath, "/index.html")
        XCTAssertEqual(configuration.workerPath, "/worker.js")
        XCTAssertEqual(configuration.imagePath, "/vfs-image.tar.gz")
        XCTAssertEqual(configuration.visibleAreaPoints, 1)
        XCTAssertEqual(WebEngineConfiguration.requiredVisibleAreaPoints, 1)
        XCTAssertTrue(configuration.allowsLockdownMode)
    }
}
