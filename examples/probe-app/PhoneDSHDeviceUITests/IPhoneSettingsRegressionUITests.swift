// SPDX-License-Identifier: MIT

import XCTest

/// Native navigation with the real local Worker. No preview data, model key,
/// automatic prompt, or replacement RPC response is supplied by this suite.
@MainActor
final class IPhoneSettingsRegressionUITests: XCTestCase {
    func testDarkSettingsSheetAfterReopenAndColdLaunch() {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "dev.phone-dsh.probe")
        app.launchArguments = ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        defer { app.terminate() }
        openSettings(app)
        let appearance = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "外观")).firstMatch
        XCTAssertTrue(appearance.waitForExistence(timeout: 15))
        appearance.tap()
        app.buttons["深色"].tap()
        capture("dark-settings-immediate")
        app.buttons["完成"].tap()
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "设置，")).firstMatch.tap()
        XCTAssertTrue(app.navigationBars["设置"].waitForExistence(timeout: 10))
        capture("dark-settings-reopened")
        app.terminate()
        app.launch()
        openSettings(app)
        capture("dark-settings-cold-launch")
    }

    func testStartupLocksRealPresetReadAndSessionNavigation() throws {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "dev.phone-dsh.probe")
        app.launchArguments = ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        defer { app.terminate() }

        let drawer = app.buttons["打开会话列表"]
        XCTAssertTrue(drawer.waitForExistence(timeout: 60))
        drawer.tap()
        let settings = app.buttons.matching(NSPredicate(format: "label == %@", "设置，待配置模型")).firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 90), "The real Worker must start before settings are read")
        waitForDrawerSettings(settings, drawer: drawer)
        settings.tap()

        app.staticTexts["新会话默认权限"].tap()
        let readOnlyReason = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "只读：此 iPhone Worker")).firstMatch
        XCTAssertTrue(readOnlyReason.waitForExistence(timeout: 20))
        XCTAssertTrue(app.buttons["仅可查看"].firstMatch.exists)
        XCTAssertFalse(app.buttons["仅可查看"].firstMatch.isEnabled)
        capture("permission-startup-lock")
        app.navigationBars.buttons.element(boundBy: 0).tap()

        app.staticTexts["Agent 预设"].tap()
        let viewStandard = app.buttons["presets.read.standard"]
        XCTAssertTrue(viewStandard.waitForExistence(timeout: 45), "Roster must come from the actual Worker")
        XCTAssertTrue(app.buttons["presets.create"].isEnabled, "Creator must mount real inspection and profile services")
        capture("real-preset-roster")
        viewStandard.tap()
        let yaml = app.staticTexts["presets.yaml"]
        XCTAssertTrue(yaml.waitForExistence(timeout: 20))
        XCTAssertTrue(yaml.label.contains("name:"))
        capture("real-preset-yaml")
        app.buttons["完成"].tap()

        let usePTC = app.buttons["presets.use.ptc"]
        XCTAssertTrue(usePTC.waitForExistence(timeout: 10))
        usePTC.tap()
        XCTAssertTrue(drawer.waitForExistence(timeout: 30))
        XCTAssertFalse(app.navigationBars["Agent 预设"].exists)
        let dismissed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"),
                                                  object: app.navigationBars["设置"])
        XCTAssertEqual(XCTWaiter.wait(for: [dismissed], timeout: 10), .completed,
                       "Successful selection dismisses the entire settings sheet")
        capture("selected-preset-session")
        app.buttons["更多"].tap()
        let selectedPreset = app.descendants(matching: .any).matching(
            NSPredicate(format: "label == %@", "Agent 预设：ptc")).firstMatch
        XCTAssertTrue(selectedPreset.waitForExistence(timeout: 15),
                      "The real session projection must reflect the non-default preset, without a prompt. \(app.debugDescription)")
        capture("selected-preset-projection")
    }

    func testCreatorEntryUsesCordisWithoutSendingAndPreservesOldDraft() {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "dev.phone-dsh.probe")
        app.launchArguments = ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        defer { app.terminate() }
        let title = "Creator draft \(UUID().uuidString.prefix(8))"
        let draft = "UNSENT_CREATOR_DRAFT_\(UUID().uuidString.prefix(8))"
        openSettings(app)
        app.staticTexts["Agent 预设"].tap()
        XCTAssertTrue(app.buttons["presets.read.standard"].waitForExistence(timeout: 45))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.buttons["完成"].tap()
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        let editor = app.textViews.matching(NSPredicate(format: "label BEGINSWITH %@", "发消息或创建任务")).firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 60))
        let titleButton = app.buttons["chat.session-title"]
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true"), object: titleButton)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 90), .completed)
        titleButton.tap()
        let name = app.alerts["重命名会话"].textFields["会话名称"]
        XCTAssertTrue(name.waitForExistence(timeout: 10))
        name.tap()
        if let old = name.value as? String { name.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: old.count)) }
        name.typeText(title)
        app.alerts["重命名会话"].buttons["保存"].tap()
        editor.tap()
        editor.typeText(draft)
        let expectedDraft = editor.value as? String ?? ""
        XCTAssertTrue(expectedDraft.contains(draft))
        openSettings(app)
        app.staticTexts["Agent 预设"].tap()
        let creator = app.buttons["presets.create"]
        XCTAssertTrue(creator.waitForExistence(timeout: 30))
        XCTAssertTrue(creator.isEnabled)
        creator.tap()
        let dismissed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: app.navigationBars["设置"])
        XCTAssertEqual(XCTWaiter.wait(for: [dismissed], timeout: 30), .completed)
        XCTAssertFalse(app.buttons["停止执行"].exists)
        XCTAssertFalse((editor.value as? String ?? "").contains(draft))
        app.buttons["更多"].tap()
        let mode = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Agent 预设：cordis")).firstMatch
        XCTAssertTrue(mode.waitForExistence(timeout: 15))
        capture("creator-cordis-idle")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.5)).tap()
        app.buttons["打开会话列表"].tap()
        let oldSession = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", title)).firstMatch
        XCTAssertTrue(oldSession.waitForExistence(timeout: 15))
        oldSession.tap()
        let restored = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", expectedDraft), object: editor)
        XCTAssertEqual(XCTWaiter.wait(for: [restored], timeout: 15), .completed)
        capture("creator-old-draft-preserved")
    }

    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func openSettings(_ app: XCUIApplication) {
        let drawer = app.buttons["打开会话列表"]
        XCTAssertTrue(drawer.waitForExistence(timeout: 60))
        drawer.tap()
        let settings = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "设置，")).firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 15))
        waitForDrawerSettings(settings, drawer: drawer)
        settings.tap()
        XCTAssertTrue(app.navigationBars["设置"].waitForExistence(timeout: 15))
    }

    private func waitForDrawerSettings(_ settings: XCUIElement, drawer: XCUIElement) {
        // A cold launch can finish its adaptive layout after the first tap.
        // An offscreen AX match is not an interactable drawer row. Opening the
        // drawer is idempotent; wait for the actual row before tapping it.
        if !settings.isHittable { drawer.tap() }
        let visible = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isHittable == true"), object: settings)
        XCTAssertEqual(XCTWaiter.wait(for: [visible], timeout: 15), .completed)
    }
}
