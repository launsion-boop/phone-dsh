// SPDX-License-Identifier: MIT
import XCTest

final class IdentityUITests: XCTestCase {
    func testFailureRendersAndExplicitRetryClearsIt() throws {
        let app = XCUIApplication()
        app.launch()
        let confirm = app.buttons["记录此实验性指纹"]
        if !confirm.waitForExistence(timeout: 5) || !confirm.isHittable { app.swipeUp() }
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(confirm.isHittable, app.debugDescription)
        let audit = app.staticTexts["identity-harness-audit"]
        XCTAssertTrue(audit.waitForExistence(timeout: 5))
        XCTAssertEqual(audit.label, "pending=true;recorded=false;tasks=false;commandsUnchanged=true;storage=invalid")
        let error = app.staticTexts["ble-device-identity-error-12345678-1234-4234-8234-123456789ABC"]
        XCTAssertFalse(error.exists)

        confirm.tap()
        XCTAssertTrue(error.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertEqual(error.label, "记录身份失败，请重试")
        XCTAssertEqual(audit.label, "pending=true;recorded=false;tasks=false;commandsUnchanged=true;storage=invalid")

        app.buttons["identity-harness-repair"].tap()
        XCTAssertEqual(audit.label, "pending=true;recorded=false;tasks=false;commandsUnchanged=true;storage=valid")
        if !confirm.isHittable { app.swipeUp() }
        XCTAssertTrue(confirm.isHittable, app.debugDescription)
        confirm.tap()
        let disappearance = NSPredicate(format: "exists == false")
        expectation(for: disappearance, evaluatedWith: error)
        waitForExpectations(timeout: 5)
        XCTAssertEqual(audit.label, "pending=false;recorded=true;tasks=false;commandsUnchanged=true;storage=recorded")
    }
}
