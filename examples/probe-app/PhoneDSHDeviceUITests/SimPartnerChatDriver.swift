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
        let transcript = app.otherElements["bot.chat.transcript"]
        let before = transcript.staticTexts.count
        send.tap()
        XCTAssertTrue(waitUntil(60) { transcript.staticTexts.count > before },
                      "message did not render in transcript")
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

    /// Waits for a turn to settle while accepting explicit image-egress
    /// approval cards the Bot raises. Each tap is a real user decision; the
    /// driver never fabricates an approval result.
    @discardableResult
    private func waitForTurnEndApprovingOnce(timeout: TimeInterval) -> Bool {
        let stop = app.buttons["bot.composer.stop"]
        let allow = app.buttons["允许一次"]
        var quiet = 0
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if allow.exists {
                attach("approval-card")
                allow.tap()
                quiet = 0
                RunLoop.current.run(until: Date().addingTimeInterval(2))
                continue
            }
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

    /// Same chip path but dumps the hierarchy immediately after send so the
    /// full attachment-refusal notice is captured (the UI truncates it).
    func testPhotosChipNoticeDump() throws {
        launchBot()
        app.buttons["bot.composer.attach"].tap()
        let photos = app.buttons["照片"]
        XCTAssertTrue(photos.waitForExistence(timeout: 10), "photo menu missing")
        photos.tap()
        RunLoop.current.run(until: Date().addingTimeInterval(2))
        let close = app.buttons["Close"]
        if close.exists { close.tap() }
        let cells = app.images.matching(identifier: "PXGGridLayout-Info")
        XCTAssertTrue(waitUntil(20) { cells.count >= 2 }, "photo grid did not load")
        cells.element(boundBy: 0).coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        cells.element(boundBy: 1).coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        app.buttons["Done"].tap()
        let chip0 = app.descendants(matching: .any)["bot.composer.attachment.0"]
        XCTAssertTrue(chip0.waitForExistence(timeout: 30), "chip missing")
        let input = composer()
        input.tap()
        input.typeText("看图说金额")
        app.buttons["bot.composer.send"].tap()
        RunLoop.current.run(until: Date().addingTimeInterval(4))
        print("SIM_NOTICE_HIER_BEGIN")
        print(app.debugDescription)
        print("SIM_NOTICE_HIER_END")
        attach("photos-after-send-notice")
    }

    /// Selects two *different* grid cells (0 and 2) with a delay and a fresh
    /// query, to avoid the duplicate-photo fixture artifact.
    func testPhotosChipDistinctThenSend() throws {
        launchBot()
        app.buttons["bot.composer.attach"].tap()
        let photos = app.buttons["照片"]
        XCTAssertTrue(photos.waitForExistence(timeout: 10), "photo menu missing")
        photos.tap()
        RunLoop.current.run(until: Date().addingTimeInterval(2))
        let close = app.buttons["Close"]
        if close.exists { close.tap() }
        let firstQuery = app.images.matching(identifier: "PXGGridLayout-Info")
        XCTAssertTrue(waitUntil(20) { firstQuery.count >= 3 }, "photo grid <3")
        firstQuery.element(boundBy: 0).coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))
        let secondQuery = app.images.matching(identifier: "PXGGridLayout-Info")
        XCTAssertTrue(waitUntil(10) { secondQuery.count >= 3 }, "photo grid lost")
        secondQuery.element(boundBy: 2).coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        app.buttons["Done"].tap()
        let chip0 = app.descendants(matching: .any)["bot.composer.attachment.0"]
        XCTAssertTrue(chip0.waitForExistence(timeout: 30), "chip 0 missing")
        let chip1 = app.descendants(matching: .any)["bot.composer.attachment.1"]
        XCTAssertTrue(chip1.waitForExistence(timeout: 10), "chip 1 missing")
        let input = composer()
        input.tap()
        input.typeText("请分别说出这两张图片里的票据金额和白板上的三个决策点；看不清就直说。")
        app.buttons["bot.composer.send"].tap()
        XCTAssertTrue(waitForTurnEndApprovingOnce(timeout: 900), "distinct photo turn did not settle")
        attach("photos-distinct-turn-end")
    }

    /// Fast-send race probe: selects photos, taps Done, then sends text
    /// immediately without waiting for the async chip. Records whether the chip
    /// existed at send time so a lost attachment can be classified.
    func testPhotosFastSend() throws {
        launchBot()
        app.buttons["bot.composer.attach"].tap()
        let photos = app.buttons["照片"]
        XCTAssertTrue(photos.waitForExistence(timeout: 10), "photo menu missing")
        photos.tap()
        RunLoop.current.run(until: Date().addingTimeInterval(2))
        let close = app.buttons["Close"]
        if close.exists { close.tap() }
        let cells = app.images.matching(identifier: "PXGGridLayout-Info")
        XCTAssertTrue(waitUntil(20) { cells.count >= 2 }, "photo grid did not load")
        cells.element(boundBy: 0).coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        cells.element(boundBy: 1).coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let done = app.buttons["Done"]
        XCTAssertTrue(done.waitForExistence(timeout: 10), "photo Done missing")
        done.tap()
        let chip0 = app.descendants(matching: .any)["bot.composer.attachment.0"]
        let chipBefore = chip0.exists
        let input = composer()
        input.tap()
        input.typeText("看图")
        let chipAtSend = chip0.exists
        print("FAST_SEND_CHIP_BEFORE=\(chipBefore) AT_SEND=\(chipAtSend)")
        attach("fast-send-chip-\(chipAtSend)")
        let dump = XCTAttachment(string: app.debugDescription)
        dump.name = "fast-send-hierarchy"
        dump.lifetime = .keepAlways
        add(dump)
        let send = app.buttons["bot.composer.send"]
        XCTAssertTrue(send.waitForExistence(timeout: 10), "send missing")
        if send.isEnabled { send.tap() }
        RunLoop.current.run(until: Date().addingTimeInterval(2))
        attach("fast-send-after")
        XCTAssertTrue(waitForTurnEndApprovingOnce(timeout: 600), "fast send turn did not settle")
    }

    /// Enables image input on the seeded provider model through the normal
    /// advanced settings editor, then saves. The seed profile defaults to
    /// text-only, which would make the App drop image attachments.
    func testEnableImageInput() throws {
        app.terminate()
        app.launchArguments = ["-uiPreview", "settings.model", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        let edit = app.buttons["provider.edit-default"]
        XCTAssertTrue(edit.waitForExistence(timeout: 60), "edit-default missing")
        edit.tap()
        XCTAssertTrue(app.buttons["保存"].waitForExistence(timeout: 15), "editor did not open")
        app.buttons["高级设置"].tap()
        XCTAssertTrue(app.navigationBars["高级设置"].waitForExistence(timeout: 10), "advanced page missing")
        var toggle = app.switches["图片输入"]
        for _ in 0..<3 where !toggle.exists {
            app.swipeUp()
            toggle = app.switches["图片输入"]
        }
        XCTAssertTrue(toggle.waitForExistence(timeout: 10), "image input toggle missing")
        attach("image-input-before")
        if (toggle.value as? String) == "0" {
            toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
            RunLoop.current.run(until: Date().addingTimeInterval(1))
        }
        attach("image-input-after")
        app.navigationBars["高级设置"].buttons.firstMatch.tap()
        let save = app.buttons["保存"]
        XCTAssertTrue(save.waitForExistence(timeout: 10), "save missing")
        save.tap()
        RunLoop.current.run(until: Date().addingTimeInterval(2))
        attach("image-input-saved")
    }

    /// Selects two controlled photos, waits for the attachment chips to
    /// appear (loadPhotos is async), captures the chip hierarchy, then sends.
    func testPhotosChipThenSend() throws {
        launchBot()
        app.buttons["bot.composer.attach"].tap()
        let photos = app.buttons["照片"]
        XCTAssertTrue(photos.waitForExistence(timeout: 10), "photo menu missing")
        photos.tap()
        RunLoop.current.run(until: Date().addingTimeInterval(2))
        let close = app.buttons["Close"]
        if close.exists { close.tap() }
        let cells = app.images.matching(identifier: "PXGGridLayout-Info")
        XCTAssertTrue(waitUntil(20) { cells.count >= 2 }, "photo grid did not load")
        cells.element(boundBy: 0).coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        cells.element(boundBy: 1).coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let done = app.buttons["Done"]
        XCTAssertTrue(done.waitForExistence(timeout: 10), "photo Done missing")
        done.tap()
        let chip0 = app.descendants(matching: .any)["bot.composer.attachment.0"]
        XCTAssertTrue(chip0.waitForExistence(timeout: 30), "attachment 0 chip never appeared")
        let chip1 = app.descendants(matching: .any)["bot.composer.attachment.1"]
        _ = chip1.waitForExistence(timeout: 10)
        RunLoop.current.run(until: Date().addingTimeInterval(2))
        attach("photos-chip-before-send")
        let chipDump = XCTAttachment(string: app.debugDescription)
        chipDump.name = "photos-chip-hierarchy"
        chipDump.lifetime = .keepAlways
        add(chipDump)
        let input = composer()
        input.tap()
        input.typeText("请分别说出这两张图片里的票据金额和白板上的三个决策点；看不清就直说。")
        let send = app.buttons["bot.composer.send"]
        XCTAssertTrue(waitUntil(20) { send.isEnabled }, "send disabled after chips")
        send.tap()
        attach("photos-chip-sent")
        XCTAssertTrue(waitForTurnEndApprovingOnce(timeout: 900), "photo chip turn did not settle")
        attach("photos-chip-turn-end")
    }

    /// Clicks the App's explicit engine-restart row after a failed boot. This
    /// is the product's own recovery entry, not a state-file edit.
    func testRestartEngine() throws {
        app.launchArguments = ["-uiPreview", "settings", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        let restart = app.buttons["重新启动引擎"]
        let english = app.buttons["Restart engine"]
        if restart.waitForExistence(timeout: 20) {
            attach("engine-restart-before")
            restart.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        } else if english.waitForExistence(timeout: 10) {
            attach("engine-restart-before")
            english.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        } else {
            attach("engine-restart-row-missing")
            XCTFail("restart engine row missing")
            return
        }
        RunLoop.current.run(until: Date().addingTimeInterval(20))
        attach("engine-restart-after")
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
        XCTAssertTrue(waitForTurnEndApprovingOnce(timeout: 900), "turn did not settle")
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


    /// Brings the already-open Calendar subscription sheet to the front and
    /// prints its hierarchy so the fixture step can use real labels. This does
    /// not change the app under test and does not touch personal calendars.
    func testCalendarHierarchy() throws {
        let cal = XCUIApplication(bundleIdentifier: "com.apple.mobilecal")
        cal.activate()
        RunLoop.current.run(until: Date().addingTimeInterval(2))
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for label in ["不允许", "Don’t Allow", "Don't Allow"] {
            let button = springboard.alerts.buttons[label]
            if button.exists { button.tap(); break }
        }
        print("SIM_CALENDAR_HIERARCHY_BEGIN")
        print(cal.debugDescription)
        print("SIM_CALENDAR_HIERARCHY_END")
        attach("calendar-hierarchy")
    }

    /// Adds the controlled ICS feed through the real Calendar UI already opened
    /// by simctl openurl. The URL is supplied by the host, never personal data.
    func testCalendarSubscribe() throws {
        let url = ProcessInfo.processInfo.environment["SIM_CALENDAR_URL"] ?? "http://127.0.0.1:8766/sim-calendar.ics"
        let cal = XCUIApplication(bundleIdentifier: "com.apple.mobilecal")
        cal.activate()
        RunLoop.current.run(until: Date().addingTimeInterval(2))
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for label in ["不允许", "Don’t Allow", "Don't Allow"] {
            let button = springboard.alerts.buttons[label]
            if button.exists { button.tap(); break }
        }
        let field = cal.textFields.firstMatch
        if field.waitForExistence(timeout: 10) {
            field.tap()
            if let value = field.value as? String, !value.isEmpty, value != url {
                field.press(forDuration: 1.0)
                if cal.menuItems["全选"].exists { cal.menuItems["全选"].tap() } else if cal.menuItems["Select All"].exists { cal.menuItems["Select All"].tap() }
                field.typeText(url)
            } else if (field.value as? String)?.isEmpty ?? true {
                field.typeText(url)
            }
        }
        for label in ["订阅", "Subscribe", "添加", "Add"] {
            let button = cal.buttons[label]
            if button.exists { button.tap(); break }
        }
        RunLoop.current.run(until: Date().addingTimeInterval(5))
        attach("calendar-after-subscribe")
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
