// SPDX-License-Identifier: MIT

import XCTest

@MainActor
final class PA_ShellKeyboardTests: XCTestCase {
    func testKeyboardHidesDockWithoutCoveringComposerAndRestoresIt() throws {
        let app = XCUIApplication(bundleIdentifier: "dev.phone-dsh.probe")
        app.launchArguments = ["-PDSH_SHELL", "v4", "-uiPreview", "app.dsh"]
        app.launchEnvironment["PDSH_PREVIEW_DRAFT"] = "pa-keyboard-draft"
        app.launch()
        defer { app.terminate() }
        let editor = app.textViews.firstMatch
        let dock = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier == %@", "app.dock")).firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 60))
        XCTAssertTrue(dock.waitForExistence(timeout: 10))
        XCTAssertLessThanOrEqual(editor.frame.maxY, dock.frame.minY)
        editor.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 10))
        XCTAssertFalse(dock.exists)
        XCTAssertTrue(editor.isHittable)
        app.staticTexts["引擎还没启动"].tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 10))
        XCTAssertTrue(dock.waitForExistence(timeout: 10))
        XCTAssertEqual(editor.value as? String, "pa-keyboard-draft")
    }

    func testMaximumContentSizeKeepsDockActionsAvailable() throws {
        let app = XCUIApplication(bundleIdentifier: "dev.phone-dsh.probe")
        app.launchArguments = ["-PDSH_SHELL", "v4", "-uiPreview", "app.chat",
                               "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        defer { app.terminate() }
        let dock = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier == %@", "app.dock")).firstMatch
        XCTAssertTrue(dock.waitForExistence(timeout: 15))
        for tab in ["Chat", "DSH", "发现", "个人"] {
            let button = app.buttons[tab]
            XCTAssertTrue(button.exists)
            XCTAssertTrue(button.isHittable)
            XCTAssertGreaterThanOrEqual(button.frame.height, 44)
            XCTAssertLessThanOrEqual(button.frame.maxX, app.frame.maxX)
        }
    }
}
