// SPDX-License-Identifier: MIT

import XCTest

@MainActor
final class PA_ShellLegacyTests: XCTestCase {
    func testLegacyUsesOriginalDrawerWithoutV4Dock() throws {
        let app = XCUIApplication(bundleIdentifier: "dev.phone-dsh.probe")
        app.launchArguments = ["-PDSH_SHELL", "legacy"]
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["打开会话列表"].waitForExistence(timeout: 60))
        XCTAssertFalse(app.otherElements["app.dock"].exists)
        app.buttons["打开会话列表"].tap()
        XCTAssertTrue(app.buttons["定时任务"].waitForExistence(timeout: 10))
        let settings = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "设置")).firstMatch
        XCTAssertTrue(settings.exists)
        XCTAssertFalse(app.buttons["新建会话与 Agent 预设"].exists)
    }

    func testV4RemovesSettingsEntryAndLegacyKeepsIt() throws {
        let app = XCUIApplication(bundleIdentifier: "dev.phone-dsh.probe")
        app.launchArguments = ["-PDSH_SHELL", "v4", "-appRoute", "pdsh://dsh"]
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["打开会话列表"].waitForExistence(timeout: 60))
        app.buttons["打开会话列表"].tap()
        let settings = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "设置")).firstMatch
        XCTAssertFalse(settings.exists)
        app.terminate()
        app.launchArguments = ["-PDSH_SHELL", "legacy"]
        app.launch()
        XCTAssertTrue(app.buttons["打开会话列表"].waitForExistence(timeout: 60))
        app.buttons["打开会话列表"].tap()
        XCTAssertTrue(settings.waitForExistence(timeout: 10))
        settings.tap()
        XCTAssertTrue(app.staticTexts["模型服务"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Agent 预设"].exists)
        XCTAssertTrue(app.staticTexts["插件与工具"].exists)
    }

    func testLegacyPreviewRouteRemainsAvailable() throws {
        let app = XCUIApplication(bundleIdentifier: "dev.phone-dsh.probe")
        app.launchArguments = ["-PDSH_SHELL", "legacy", "-uiPreview", "chat.official"]
        app.launch()
        defer { app.terminate() }
        let answer = app.staticTexts.matching(NSPredicate(
            format: "label CONTAINS %@", "原始 HTML 保持字面")).firstMatch
        XCTAssertTrue(answer.waitForExistence(timeout: 30))
        XCTAssertFalse(app.otherElements["app.dock"].exists)
    }
}
