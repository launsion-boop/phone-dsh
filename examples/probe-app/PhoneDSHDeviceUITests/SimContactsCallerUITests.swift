// SPDX-License-Identifier: MIT

// U-only SIM driver for the contacts caller seam. It uses the real Bot/DSH UI.
// It does not pass botID in model args and does not call services directly.
//
// Required env (inject outside the runner; never print values):
//   PDSH_SIM_BASE_URL, PDSH_SIM_API_KEY, PDSH_SIM_MODEL
// Optional: PDSH_SIM_CONTACTS_TASK
// The caller has already configured the provider in the dedicated SIM.

import XCTest

@MainActor
final class SimContactsCallerUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        let env = ProcessInfo.processInfo.environment
        guard env["PDSH_SIM_BASE_URL"] != nil,
              env["PDSH_SIM_API_KEY"] != nil,
              env["PDSH_SIM_MODEL"] != nil else {
            throw XCTSkip("SIM credentials/provider environment missing")
        }
        continueAfterFailure = false
        app = XCUIApplication(bundleIdentifier: "dev.phone-dsh.probe")
        app.launch()
        XCTAssertTrue(app.buttons["bot.info.open"].waitForExistence(timeout: 60))
    }

    /// Ordinary DSH assistant must keep the old contacts bridge.
    func testOrdinaryDSHContactsSearchUsesStandardSession() throws {
        app.buttons["DSH"].tap()
        let drawer = app.buttons["打开会话列表"]
        XCTAssertTrue(drawer.waitForExistence(timeout: 30))
        drawer.tap()
        let create = app.buttons["新建会话"]
        XCTAssertTrue(create.waitForExistence(timeout: 10))
        create.tap()
        sendChat(field: "chat.composer.field", send: "chat.composer.send",
                 text: task("请用 contacts.search 查一下测试联系人"))
        runLoop(seconds: 20)
    }

    /// Two Bots: configure contacts through the real Bot settings, then send
    /// the same request from each. The host must use each unit's ownership.
    func testTwoBotsContactsAuthorizationIsolation() throws {
        app.buttons["Bot"].tap()
        // Bot A is the current main Bot.
        configureContactsConsent(forCurrentBot: true)

        app.buttons["bot.drawer.open"].tap()
        let add = app.buttons["bot.drawer.add"]
        XCTAssertTrue(add.waitForExistence(timeout: 10), "Bot add missing")
        add.tap()
        // The new Bot becomes selected; configure a different consent choice.
        configureContactsConsent(forCurrentBot: false)
        sendBotMessage(task("请用 contacts.search 查一下测试联系人"))

        // Switch back to the first Bot row by position, not a model-selected id.
        app.buttons["bot.drawer.open"].tap()
        let rows = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "bot.drawer.row."))
            .allElementsBoundByIndex
        guard let first = rows.first else { return XCTFail("Bot rows missing") }
        first.tap()
        sendBotMessage(task("请用 contacts.search 查一下测试联系人"))
        runLoop(seconds: 20)
    }

    private func configureContactsConsent(forCurrentBot enabled: Bool) {
        app.buttons["bot.info.open"].tap()
        openContextSources()
        let contacts = app.switches["bot.info.context-source.contacts"]
        XCTAssertTrue(contacts.waitForExistence(timeout: 10), "contacts switch missing")
        if (contacts.value as? String) != (enabled ? "1" : "0") {
            contacts.tap()
            runLoop(seconds: 10)
        }
        app.buttons["完成"].firstMatch.tap()
    }

    private func openContextSources() {
        for _ in 0..<3 {
            let link = app.descendants(matching: .any)["bot.info.context-sources"]
            if link.waitForExistence(timeout: 3) { link.tap(); return }
            if app.staticTexts["管理情境来源"].exists {
                app.staticTexts["管理情境来源"].tap(); return
            }
            app.swipeUp()
        }
        XCTFail("context-sources entry missing")
    }

    private func sendBotMessage(_ text: String) {
        let input = app.textFields["bot.composer.input"]
        XCTAssertTrue(input.waitForExistence(timeout: 20), "Bot composer missing")
        input.tap(); input.typeText(text)
        app.buttons["bot.composer.send"].tap()
        runLoop(seconds: 20)
    }

    private func sendChat(field: String, send: String, text: String) {
        let input = app.textViews[field].firstMatch.exists
            ? app.textViews[field].firstMatch : app.textFields[field].firstMatch
        XCTAssertTrue(input.waitForExistence(timeout: 30), "DSH composer missing")
        input.tap(); input.typeText(text)
        app.buttons[send].tap()
    }

    private func task(_ fallback: String) -> String {
        ProcessInfo.processInfo.environment["PDSH_SIM_CONTACTS_TASK"] ?? fallback
    }

    private func runLoop(seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }
}
