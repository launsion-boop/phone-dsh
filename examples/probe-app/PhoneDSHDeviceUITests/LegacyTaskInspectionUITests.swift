// SPDX-License-Identifier: MIT
import XCTest

/// Run on a fresh isolated simulator: no existing journal is needed and no
/// Bluetooth grant or network fixture is created by this test.
@MainActor
final class LegacyTaskInspectionUITests: XCTestCase {
    func testDefaultBluetoothPageRequiresAnExplicitInspection() {
        let app = XCUIApplication()
        app.launchArguments = ["-uiPreview", "settings", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        defer { app.terminate() }

        let bluetooth = app.buttons["蓝牙设备"]
        XCTAssertTrue(bluetooth.waitForExistence(timeout: 30))
        if !bluetooth.isHittable { app.swipeUp() }
        bluetooth.tap()
        let start = app.buttons["legacy-task-inspection-start"]
        XCTAssertTrue(start.waitForExistence(timeout: 20))
        if !start.isHittable { app.swipeUp() }
        XCTAssertFalse(app.staticTexts["legacy-task-inspection-incomplete"].exists)
        XCTAssertFalse(app.staticTexts["legacy-task-inspection-busy"].exists)
        start.tap()
        XCTAssertTrue(app.staticTexts["legacy-task-inspection-incomplete"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.staticTexts["没有找到记录目录；这不能证明不存在旧记录。"].exists)
        XCTAssertFalse(app.staticTexts["legacy-task-inspection-busy"].exists)
    }
}
