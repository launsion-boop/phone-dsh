// SPDX-License-Identifier: MIT
// Test-only generic driver for the SIM Partner Lab. It drives the real App
// composer and the real host; it never injects assistant/derived events and
// never asserts a fixed reply. Copy into PhoneDSHDeviceUITests before the SIM
// candidate build. Environment (test process):
//   SIM_TASK, SIM_FOLLOWUP, SIM_FOLLOWUP_DELAY, SIM_ACTION
import XCTest

@MainActor
final class SimPartnerChatDriver: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication(bundleIdentifier: "dev.phone-dsh.probe")
    }

    private func composer() -> XCUIElement {
        let field = app.textFields["bot.composer.input"]
        if field.exists { return field }
        return app.textViews["bot.composer.input"]
    }

    private func attach(_ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    private func launchBot() {
        app.launch()
        XCTAssertTrue(app.buttons["bot.info.open"].waitForExistence(timeout: 300),
                      "Bot page did not become ready")
    }

    private func send(_ text: String) {
        let input = composer()
        XCTAssertTrue(input.waitForExistence(timeout: 60), "composer input missing")
        input.tap()
        input.typeText(text)
        let send = app.buttons["bot.composer.send"]
        XCTAssertTrue(send.waitForExistence(timeout: 20), "send button missing")
        XCTAssertTrue(waitUntil(30) { send.isEnabled }, "send stayed disabled")
        send.tap()
        XCTAssertTrue(app.staticTexts[text].waitForExistence(timeout: 30),
                      "user text did not render in transcript")
    }

    @discardableResult
    private func waitForTurnEnd(timeout: TimeInterval) -> Bool {
        let stop = app.buttons["bot.composer.stop"]
        let deadline = Date().addingTimeInterval(timeout)
        var quiet = 0
        while Date() < deadline {
            if stop.exists { quiet = 0 } else { quiet += 1 }
            if quiet >= 4 { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        }
        return false
    }

    private func waitUntil(_ timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        }
        return condition()
    }

    /// One real task through the real composer. The reply text is not asserted:
    /// evidence is the durable transcript/row plus host/DB records.
    func testSendTask() throws {
        let task = ProcessInfo.processInfo.environment["SIM_TASK"]
            ?? "请先看一下当前工作区里的项目资料，告诉我你看到的项目目标和你还缺什么。"
        launchBot()
        attach("bot-before-task")
        send(task)
        attach("bot-after-send")
        XCTAssertTrue(waitForTurnEnd(timeout: 900), "turn did not settle")
        attach("bot-after-turn")
    }

    /// Sends a real supplementary constraint while the first turn is running.
    /// It records what the App actually allows (queue vs steer) instead of
    /// forcing a product behaviour.
    func testSendTaskWithFollowUp() throws {
        let env = ProcessInfo.processInfo.environment
        let task = env["SIM_TASK"] ?? "请先读项目资料，准备评审材料。"
        let follow = env["SIM_FOLLOWUP"] ?? "补充一个约束：财务上限是 50 万含税，超过要额外审批。"
        let delay = TimeInterval(env["SIM_FOLLOWUP_DELAY"] ?? "12") ?? 12
        launchBot()
        send(task)
        attach("bot-task-running")
        RunLoop.current.run(until: Date().addingTimeInterval(delay))
        let input = composer()
        input.tap()
        input.typeText(follow)
        let send = app.buttons["bot.composer.send"]
        let allowed = send.exists && send.isEnabled
        attach("bot-followup-\(allowed ? "sendable" : "blocked")")
        if allowed {
            send.tap()
            XCTAssertTrue(app.staticTexts[follow].waitForExistence(timeout: 30),
                          "follow-up did not render")
        }
        XCTAssertTrue(waitForTurnEnd(timeout: 1200), "turn did not settle after follow-up")
        attach("bot-after-followup-turn")
    }

    /// Confirms the App's own secure provider store is readable and shows
    /// model id/effort without exposing the key.
    func testProviderStatus() throws {
        app.launchArguments = ["-uiPreview", "settings.model", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        XCTAssertTrue(app.buttons["provider.edit-default"].waitForExistence(timeout: 60),
                      "provider settings did not open")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "密钥已保存")).firstMatch.waitForExistence(timeout: 20),
                      "Keychain-backed provider key is not readable")
        attach("provider-status")
        print("SIM_PROVIDER_PAGE_READY")
    }

    /// Sets the provider-level reasoning effort to max through the normal
    /// settings editor; the key is left untouched and never rendered.
    func testSetReasoningEffortMax() throws {
        app.launchArguments = ["-uiPreview", "settings.model", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        let edit = app.buttons["provider.edit-default"]
        XCTAssertTrue(edit.waitForExistence(timeout: 60), "edit-default missing")
        edit.tap()
        let effortRow = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "推理强度")).firstMatch
        if !effortRow.waitForExistence(timeout: 10) {
            attach("provider-editor-no-effort-row")
            XCTFail("reasoning effort picker not found")
            return
        }
        effortRow.tap()
        let max = app.buttons["最高"]
        if !max.waitForExistence(timeout: 5) {
            _ = app.staticTexts["最高"].waitForExistence(timeout: 5)
        }
        if max.exists { max.tap() } else if app.staticTexts["最高"].exists { app.staticTexts["最高"].tap() }
        let save = app.buttons["保存"]
        XCTAssertTrue(save.waitForExistence(timeout: 10), "save missing")
        save.tap()
        RunLoop.current.run(until: Date().addingTimeInterval(2))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "已保存")).firstMatch.waitForExistence(timeout: 20),
                      "save receipt missing")
        attach("provider-after-save")
    }

    /// Read-only hierarchy dump used only to adapt selectors; no key content is
    /// displayed because the provider list shows status, not the SecureField.
    func testDumpProviderHierarchy() throws {
        app.launchArguments = ["-uiPreview", "settings.model", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        _ = app.buttons["provider.edit-default"].waitForExistence(timeout: 60)
        print("SIM_HIERARCHY_BEGIN")
        print(app.debugDescription)
        print("SIM_HIERARCHY_END")
        attach("provider-hierarchy")
    }

    /// Sends task one, terminates, relaunches, verifies the durable transcript
    /// is still visible and appends task two in the same session.
    func testRelaunchThenContinue() throws {
        let env = ProcessInfo.processInfo.environment
        let first = env["SIM_TASK"] ?? "先读一下项目资料，告诉我你的第一步。"
        let second = env["SIM_SECOND"] ?? "继续，把刚才的结论补成可发出去的版本。"
        launchBot()
        send(first)
        XCTAssertTrue(waitForTurnEnd(timeout: 900), "first turn did not settle")
        app.terminate()
        launchBot()
        XCTAssertTrue(app.staticTexts[first].waitForExistence(timeout: 90),
                      "first user row did not survive relaunch")
        attach("bot-after-relaunch")
        send(second)
        XCTAssertTrue(waitForTurnEnd(timeout: 900), "second turn did not settle")
        attach("bot-after-second-turn")
    }
}
