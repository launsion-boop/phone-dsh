// SPDX-License-Identifier: MIT

// A05 UI acceptance over E's restored real production snapshot. The app is
// already installed with the snapshot container; this test only launches it
// and taps the real projected rows. It never imports or fabricates rows.

import XCTest

final class A05FeedbackUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchEnvironment["PDSH_SEED_PROVIDER_KEY"] = "a05-dummy-key"
        app.launch()
        Thread.sleep(forTimeInterval: 10)
        print("A05_HIERARCHY\n\(app.debugDescription)")
    }

    func testAttachmentAdoptAndUndo() throws {
        let adopt = app.buttons["bot.feedback.adopt"].firstMatch
        reveal(adopt)
        XCTAssertTrue(adopt.exists, "attachment adopt action missing")
        adopt.tap()
        XCTAssertTrue(app.staticTexts["已记录：采纳"].waitForExistence(timeout: 10),
                      "adopt receipt missing")
        let undo = app.buttons["bot.feedback.undo"].firstMatch
        XCTAssertTrue(undo.waitForExistence(timeout: 5), "undo action missing")
        undo.tap()
        XCTAssertTrue(app.staticTexts["已撤销反馈"].waitForExistence(timeout: 10),
                      "undo receipt missing")
    }

    func testAutomationSuppressScopes() throws {
        let suppress = app.buttons["bot.feedback.suppress"].firstMatch
        reveal(suppress)
        XCTAssertTrue(suppress.exists, "automation suppress action missing")
        suppress.tap()
        XCTAssertTrue(app.buttons["bot.feedback.suppress.artifact"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["bot.feedback.suppress.routineClass"].exists)
        XCTAssertTrue(app.buttons["bot.feedback.suppress.user"].exists)
        app.buttons["bot.feedback.suppress.routineClass"].tap()
        XCTAssertTrue(app.staticTexts["已记录：这类别推了"].waitForExistence(timeout: 10),
                      "suppress receipt missing")
    }

    private func reveal(_ element: XCUIElement) {
        for _ in 0..<4 {
            if element.exists { return }
            app.swipeUp()
        }
    }
}
