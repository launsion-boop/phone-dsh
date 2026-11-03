// SPDX-License-Identifier: MIT

import XCTest

@MainActor
final class PA_SuggestionCardUITests: XCTestCase {
    func testSuggestionOptionsAndDismissRemainAccessible() throws {
        let app = XCUIApplication(bundleIdentifier: "dev.phone-dsh.probe")
        app.launchArguments = ["-PDSH_SHELL", "v4", "-uiPreview", "app.suggestion-card"]
        app.launch()
        defer { app.terminate() }

        XCTAssertTrue(app.staticTexts["接下来可以做什么？"].waitForExistence(timeout: 30))
        for (index, option) in ["查看这个 PR 的新阻塞", "整理成简短回复", "继续处理下一项任务"].enumerated() {
            let button = app.buttons["app.chat.suggestion.\(index)"]
            XCTAssertTrue(button.exists)
            XCTAssertTrue(button.isHittable)
            XCTAssertGreaterThanOrEqual(button.frame.height, 44)
            XCTAssertTrue(app.staticTexts[option].exists)
        }
        let dismiss = app.buttons["app.chat.suggestions.dismiss"]
        XCTAssertTrue(dismiss.exists)
        XCTAssertTrue(dismiss.isHittable)
        XCTAssertTrue(app.staticTexts["或在下方聊天中回答"].exists)
    }
}
