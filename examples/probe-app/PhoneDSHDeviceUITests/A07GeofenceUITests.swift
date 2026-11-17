// SPDX-License-Identifier: MIT

// User-confirmed geofence configuration through the real settings page. It
// never asks for the current location and never fabricates a region callback;
// a missing Always grant only means OS callbacks stay device-only.

import XCTest

final class A07GeofenceUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch()
        Thread.sleep(forTimeInterval: 12)
    }

    func testAddPersistRestartAndRemoveFence() throws {
        openFenceSection()
        let label = "公司"
        let lat = "31.23040"
        let lon = "121.47370"

        let name = app.textFields["bot.context.fence.label"]
        reveal(name)
        XCTAssertTrue(name.waitForExistence(timeout: 10), "fence name field missing")
        name.tap(); name.typeText(label)
        let latitude = app.textFields["bot.context.fence.latitude"]
        let longitude = app.textFields["bot.context.fence.longitude"]
        let radius = app.textFields["bot.context.fence.radius"]
        latitude.tap(); latitude.typeText(lat)
        longitude.tap(); longitude.typeText(lon)
        radius.tap(); radius.typeText("200")
        app.buttons["bot.context.fence.add"].tap()

        XCTAssertTrue(app.staticTexts[label].waitForExistence(timeout: 10),
                      "confirmed fence did not appear")

        // Cold restart: the assembly/store, not this test, must restore it.
        app.terminate()
        app.launch()
        Thread.sleep(forTimeInterval: 12)
        openFenceSection()
        XCTAssertTrue(app.staticTexts[label].waitForExistence(timeout: 10),
                      "confirmed fence did not survive restart")

        let remove = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "bot.context.fence.remove.")).firstMatch
        XCTAssertTrue(remove.exists, "fence remove action missing")
        remove.tap()
        XCTAssertFalse(app.staticTexts[label].waitForExistence(timeout: 3),
                       "removed fence still visible")
    }

    private func openFenceSection() {
        let info = app.buttons["bot.info.open"]
        XCTAssertTrue(info.waitForExistence(timeout: 20), "Bot info missing")
        info.tap()
        for _ in 0..<3 {
            let link = app.descendants(matching: .any)["bot.info.context-sources"]
            if link.waitForExistence(timeout: 3) { link.tap(); return }
            if app.staticTexts["管理情境来源"].exists { app.staticTexts["管理情境来源"].tap(); return }
            app.swipeUp()
        }
        XCTFail("context-sources entry missing")
    }

    private func reveal(_ element: XCUIElement) {
        for _ in 0..<5 {
            if element.exists { return }
            app.swipeUp()
        }
    }
}
