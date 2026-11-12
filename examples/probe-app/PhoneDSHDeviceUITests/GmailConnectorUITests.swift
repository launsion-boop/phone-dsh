// SPDX-License-Identifier: MIT

import XCTest

@MainActor
final class GmailConnectorUITests: XCTestCase {
    func testDiscoverCardOpensGmailAccountPage() {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        defer { app.terminate() }

        let discover = app.buttons["发现"]
        XCTAssertTrue(discover.waitForExistence(timeout: 30))
        discover.tap()
        let card = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Gmail")).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 10))
        card.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let open = app.buttons["打开 Gmail"]
        XCTAssertTrue(open.waitForExistence(timeout: 10))
        open.tap()
        XCTAssertTrue(app.navigationBars["Gmail"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Google 账号"].exists)
    }
}
