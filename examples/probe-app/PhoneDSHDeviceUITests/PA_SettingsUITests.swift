// SPDX-License-Identifier: MIT

import XCTest

@MainActor
final class PA_SettingsUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication(bundleIdentifier: "dev.phone-dsh.probe")
    }

    override func tearDownWithError() throws {
        app.terminate()
    }

    func testAgentNameEditPersistsIntoChat() throws {
        launch(route: "pdsh://profile")
        app.staticTexts["Agent 与个人上下文"].tap()
        let settings = app.descendants(matching: .any)["profile.personal-agent-settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 15))
        XCTAssertFalse(app.staticTexts["电脑"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["profile.automations"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["profile.memory"].exists)

        app.buttons["profile.agent-name-edit"].tap()
        let field = app.textFields["profile.agent-name"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        let oldName = try XCTUnwrap(field.value as? String)
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: oldName.count))
        field.typeText("Grok Helper")
        app.navigationBars["编辑名称"].buttons["完成"].tap()
        XCTAssertTrue(app.staticTexts["Grok Helper"].waitForExistence(timeout: 5))

        app.terminate()
        launch(route: "pdsh://chat")
        XCTAssertTrue(app.staticTexts["Grok Helper"].waitForExistence(timeout: 15))
    }

    func testNotificationToggleUsesSystemAuthorization() throws {
        launch(route: "pdsh://profile")
        app.staticTexts["Agent 与个人上下文"].tap()
        let toggle = app.switches["profile.notifications"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 15))
        if toggle.value as? String == "0" {
            toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
            let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
            var allow: XCUIElement?
            let applications: [XCUIApplication] = [app, springboard]
            for candidate in applications {
                let button = candidate.buttons.matching(
                    NSPredicate(format: "label IN %@", ["Allow", "允许", "允許"])).firstMatch
                if button.waitForExistence(timeout: 5) {
                    allow = button
                    break
                }
            }
            let allowButton = try XCTUnwrap(allow)
            allowButton.tap()
            XCTAssertTrue(app.staticTexts["系统已允许 Personal Agent 本地通知。"].waitForExistence(timeout: 10))
        }
        XCTAssertEqual(toggle.value as? String, "1")

        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        XCTAssertTrue(app.alerts["在系统设置中管理通知"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.alerts["在系统设置中管理通知"].buttons["去系统设置"].exists)
    }

    private func launch(route: String) {
        app.launchArguments = ["-PDSH_SHELL", "v4", "-personalAgent.onboarding.completed", "YES",
                               "-appRoute", route]
        app.launch()
    }
}
