// SPDX-License-Identifier: MIT

import XCTest

@MainActor
final class PA_ShellTabStateTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication(bundleIdentifier: "dev.phone-dsh.probe")
        app.launchArguments = ["-PDSH_SHELL", "v4"]
        app.launchEnvironment["PDSH_OFFICE_WORKSPACE_NAME"] = "pa-shell-tabs-\(UUID().uuidString)"
    }

    override func tearDownWithError() throws {
        app.terminate()
    }

    func testDiscoverNavigationStackSurvivesTabSwitch() throws {
        app.launchArguments += ["-uiPreview", "app.discover"]
        app.launch()
        app.buttons["discover.connector.github"].waitForExistence(timeout: 15)
        app.buttons["discover.connector.github"].tap()
        XCTAssertTrue(app.navigationBars["GitHub"].waitForExistence(timeout: 10))
        app.buttons["Chat"].tap()
        app.buttons["发现"].tap()
        XCTAssertTrue(app.navigationBars["GitHub"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["发现"].exists)
    }

    func testProfileScrollPositionSurvivesTabSwitch() throws {
        app.launchArguments += ["-uiPreview", "app.profile"]
        app.launchEnvironment["PDSH_PREVIEW_SCROLL_BOTTOM"] = "1"
        app.launch()
        XCTAssertTrue(app.navigationBars["个人"].waitForExistence(timeout: 15))
        let licenses = app.buttons["开源许可"]
        XCTAssertTrue(licenses.waitForExistence(timeout: 5))
        let frame = licenses.frame
        app.buttons["Chat"].tap()
        app.buttons["个人"].tap()
        XCTAssertTrue(licenses.waitForExistence(timeout: 5))
        XCTAssertEqual(licenses.frame.minY, frame.minY, accuracy: 2)
    }

    func testDSHDraftAndSessionSurviveTabSwitch() throws {
        app.launchArguments += ["-uiPreview", "app.dsh"]
        app.launchEnvironment["PDSH_PREVIEW_DRAFT"] = "pa-shell-draft"
        app.launch()
        let editor = app.textViews.firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 60))
        let session = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "dsh.session.")).firstMatch
        XCTAssertTrue(session.waitForExistence(timeout: 10))
        let sessionID = session.identifier
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45)).tap()
        let dock = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier == %@", "app.dock")).firstMatch
        XCTAssertTrue(dock.waitForExistence(timeout: 10))
        app.buttons["发现"].tap()
        app.buttons["DSH"].tap()
        XCTAssertEqual(session.identifier, sessionID)
        XCTAssertEqual(editor.value as? String, "pa-shell-draft")
    }
}
