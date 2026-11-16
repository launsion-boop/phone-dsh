// SPDX-License-Identifier: MIT

// A07 native context-settings acceptance on a real app/OS path.
//
// The simulator host has no provisioning profile, so Keychain entitlements
// cannot be provisioned (K/U evidence). This test therefore runs the app with
// the explicit `PDSH_TEST_CREDENTIAL_STORE=1` env: provider secrets live in an
// in-memory store for this test only. It is NOT a production Keychain claim and
// the A07 Keychain/alias item stays NOT_VERIFIED/WAITING_DEVICE.
//
// Calendar authorization itself is real: prepare it externally with
// `xcrun simctl privacy <udid> grant calendar dev.phone-dsh.probe`; the test
// never fabricates an authorization or observation.

import XCTest

final class A07ContextSettingsUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        print("A07_TEST_SECRET_STORE=1 (in-memory; NOT production Keychain)")
        app = XCUIApplication()
        app.launchEnvironment["PDSH_TEST_CREDENTIAL_STORE"] = "1"
        app.launchEnvironment["PDSH_SEED_PROVIDER_KEY"] = "a07-dummy-key"
        app.launchEnvironment["PDSH_SEED_PROVIDER_MODEL"] = "deepseek-chat"
        addUIInterruptionMonitor(withDescription: "Calendar authorization") { alert in
            for label in ["允许完全访问", "允许", "Allow Full Access", "Allow"] {
                if alert.buttons[label].exists {
                    alert.buttons[label].tap()
                    return true
                }
            }
            return false
        }
        addUIInterruptionMonitor(withDescription: "Contacts authorization") { alert in
            for label in ["允许", "Allow", "允许访问所有通讯录", "Allow Full Access"] {
                if alert.buttons[label].exists {
                    alert.buttons[label].tap()
                    return true
                }
            }
            return false
        }
        app.launch()
        // BotProductionHub.connect waits up to 10s for chat.botRuntime; the
        // info sheet must be opened after that composition exists.
        Thread.sleep(forTimeInterval: 15)
    }

    func testContextSettingsCalendarConsentAndRevoke() throws {
        app.buttons["bot.info.open"].tap()
        openContextSources()

        let calendar = app.switches["bot.info.context-source.calendar"]
        XCTAssertTrue(calendar.waitForExistence(timeout: 10), "calendar source row is missing")
        attach(name: "a07-context-calendar-before")

        let initial = calendar.value as? String
        calendar.tap()
        let changed = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value != %@", initial ?? ""),
            object: calendar)
        XCTAssertEqual(XCTWaiter().wait(for: [changed], timeout: 10), .completed,
                       "calendar switch did not change; OS prompt may be pending")
        attach(name: "a07-context-calendar-after-enable")

        calendar.tap()
        let reverted = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", initial ?? ""),
            object: calendar)
        XCTAssertEqual(XCTWaiter().wait(for: [reverted], timeout: 10), .completed,
                       "calendar switch did not revoke")
        attach(name: "a07-context-calendar-after-revoke")
    }


    func testPreGrantedCalendarConsentPathWithoutOSPrompt() throws {
        print("A07_OS_PROMPT_PREGRANTED=1; interactive full-access toggle remains WAITING_DEVICE")
        app.buttons["bot.info.open"].tap()
        openContextSources()
        let calendar = app.switches["bot.info.context-source.calendar"]
        XCTAssertTrue(calendar.waitForExistence(timeout: 10), "calendar source row is missing")
        // OS TCC was pre-granted externally; it must NOT create App consent.
        XCTAssertEqual(calendar.value as? String, "0",
                       "pre-grant must not fabricate App consent before the user taps")
        attach(name: "a07-context-calendar-pregranted-switch-off")

        calendar.tap()
        let changed = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value != %@", "0"),
            object: calendar)
        XCTAssertEqual(XCTWaiter().wait(for: [changed], timeout: 10), .completed,
                       "real tap with pre-granted OS permission should write App consent")
        attach(name: "a07-context-calendar-pregranted-switch-on")
    }


    func testContactsPreGrantedConsentPathWithoutPrompt() throws {
        app.buttons["bot.info.open"].tap()
        openContextSources()
        let contacts = app.switches["bot.info.context-source.contacts"]
        XCTAssertTrue(contacts.waitForExistence(timeout: 10), "contacts source row is missing")
        XCTAssertEqual(contacts.value as? String, "0",
                       "pre-grant must not fabricate App consent before the user taps")
        contacts.tap()
        app.tap() // allow the interruption monitor to accept a real OS prompt
        let on = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value != %@", "0"), object: contacts)
        XCTAssertEqual(XCTWaiter().wait(for: [on], timeout: 10), .completed,
                       "real contacts tap with pre-granted OS permission should write App consent")
        contacts.tap()
        let off = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "0"), object: contacts)
        XCTAssertEqual(XCTWaiter().wait(for: [off], timeout: 10), .completed,
                       "contacts revoke should clear the switch")
        attach(name: "a07-context-contacts-consent-revoke")
    }

    func testUnsupportedCapabilityIsNotOfferedAsASwitch() throws {
        app.buttons["bot.info.open"].tap()
        openContextSources()
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
        XCTFail("context-sources link is missing")
    }

    private func attach(name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
