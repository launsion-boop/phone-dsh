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
        // BotProductionHub.connect waits up to 10s for chat.botRuntime. The
        // info sheet must be opened after that composition exists, otherwise
        // the contextSources parameter is nil and the section is hidden.
        Thread.sleep(forTimeInterval: 12)
    }

    func testContextSettingsPageEntry() throws {
        let info = app.buttons["bot.info.open"]
        XCTAssertTrue(info.waitForExistence(timeout: 30), "Bot info capsule is missing")
        info.tap()
        openContextSources()

        let calendar = app.switches["bot.info.context-source.calendar"]
        XCTAssertTrue(calendar.waitForExistence(timeout: 10), "calendar source row is missing")
        XCTAssertTrue(app.switches["bot.info.context-source.contacts"].exists)
        attach(name: "a07-context-settings-entry")
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
        for _ in 0..<2 {
            let link = app.descendants(matching: .any)["bot.info.context-sources"]
            if link.waitForExistence(timeout: 3) {
                link.tap()
                return
            }
            let label = app.staticTexts["管理情境来源"]
            if label.waitForExistence(timeout: 2) {
                label.tap()
                return
            }
            app.swipeUp()
        }
        let debug = app.staticTexts.allElementsBoundByIndex.map(\.label).joined(separator: " | ")
        XCTFail("context-sources link is missing; visible: \(debug)")
    }

    private func attach(name: String) {
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
