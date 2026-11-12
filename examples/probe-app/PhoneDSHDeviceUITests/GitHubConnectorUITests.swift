// SPDX-License-Identifier: MIT

import XCTest

@MainActor
final class GitHubConnectorUITests: XCTestCase {
    func testDiscoverOrdersGmailAboveGitHubAndOpensConnector() {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        defer { app.terminate() }

        let discover = app.buttons["发现"]
        XCTAssertTrue(discover.waitForExistence(timeout: 30))
        discover.tap()

        let gmail = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Gmail")).firstMatch
        let github = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "GitHub")).firstMatch
        XCTAssertTrue(gmail.waitForExistence(timeout: 10))
        XCTAssertTrue(github.waitForExistence(timeout: 10))
        XCTAssertLessThan(gmail.frame.minY, github.frame.minY)

        github.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let open = app.buttons["打开 GitHub"]
        XCTAssertTrue(open.waitForExistence(timeout: 10))
        open.tap()

        XCTAssertTrue(app.navigationBars["GitHub"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["github.connect"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["github.unconfigured"].exists)
        XCTAssertFalse(app.secureTextFields["github.token"].exists)
    }
}
