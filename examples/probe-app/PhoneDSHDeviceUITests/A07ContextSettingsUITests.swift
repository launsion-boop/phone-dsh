// SPDX-License-Identifier: MIT

// A07 native context-settings acceptance. This is a real app/OS path: it
// launches the installed probe app, opens Bot info -> Context sources, and
// toggles the calendar source against the simulator's real EventKit
// authorization. Permission state is prepared externally with
// `xcrun simctl privacy <udid> grant|revoke calendar dev.phone-dsh.probe`;
// the test never fabricates an authorization or observation.

import XCTest

final class A07ContextSettingsUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        // A production Bot composition (and therefore the context-source
        // assembly) starts only when a provider profile exists. The key is a
        // dummy: these tests never send a model request.
        app.launchEnvironment["PDSH_SEED_PROVIDER_KEY"] = "a07-dummy-key"
        app.launchEnvironment["PDSH_SEED_PROVIDER_MODEL"] = "deepseek-chat"
        app.launch()
    }

    func testContextSettingsLinkOpensProductionPage() throws {
        let info = app.buttons["bot.info.open"]
        XCTAssertTrue(info.waitForExistence(timeout: 20), "Bot info capsule is missing")
        info.tap()

        openContextSources()

        let calendar = app.switches["bot.info.context-source.calendar"]
        XCTAssertTrue(calendar.waitForExistence(timeout: 10), "calendar source row is missing")
        attach(name: "a07-context-settings")

        // Toggle against the externally prepared OS authorization. `value`
        // is the real UISwitch state; a denied/revoked prompt must not report
        // authorized.
        let initial = calendar.value as? String
        calendar.tap()
        let changed = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value != %@", initial ?? ""),
            object: calendar)
        XCTAssertEqual(XCTWaiter().wait(for: [changed], timeout: 10), .completed,
                       "calendar switch did not change; OS prompt may be pending")
        attach(name: "a07-context-calendar-after-toggle")
    }

    func testUnsupportedCapabilityIsNotOfferedAsASwitch() throws {
        let info = app.buttons["bot.info.open"]
        XCTAssertTrue(info.waitForExistence(timeout: 20))
        info.tap()
        openContextSources()

        // Capability matrix unsupported rows are shown as explanatory text,
        // never as a switch that could fake a capability.
        XCTAssertFalse(app.switches["bot.info.context-source.sms"].exists)
        XCTAssertFalse(app.switches["bot.info.context-source.third-party-notifications"].exists)
        attach(name: "a07-context-capability-boundary")
    }

    private func openContextSources() {
        let link = app.descendants(matching: .any)["bot.info.context-sources"]
        if link.waitForExistence(timeout: 8) {
            link.tap()
            return
        }
        let label = app.staticTexts["管理情境来源"]
        XCTAssertTrue(label.waitForExistence(timeout: 8), "context-sources link is missing")
        label.tap()
    }

    private func attach(name: String) {
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
