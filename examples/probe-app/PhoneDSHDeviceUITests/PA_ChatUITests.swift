// SPDX-License-Identifier: MIT

import XCTest

@MainActor
final class PA_ChatUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication(bundleIdentifier: "dev.phone-dsh.probe")
        app.launchArguments = ["-PDSH_SHELL", "v4", "-uiPreview", "app.chat", "-resetPersonalAgentName"]
        app.launch()
    }

    override func tearDownWithError() throws {
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = String(name.split(separator: " ").last ?? "personal-agent-chat")
        screenshot.lifetime = .keepAlways
        add(screenshot)
        app.terminate()
    }

    func testCenteredAgentHeaderAndComposerRemainExposedInsideChatContainer() {
        let root = app.descendants(matching: .any)["app.chat"]
        XCTAssertTrue(root.waitForExistence(timeout: 60))

        let settings = app.buttons["app.chat.agent-settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 10))
        XCTAssertTrue(settings.label.contains("小肥鱼"))
        XCTAssertEqual(settings.frame.midX, app.frame.midX, accuracy: 1)
        XCTAssertTrue(app.buttons["app.chat.more"].isHittable)

        XCTAssertTrue(app.staticTexts["你好，我是 小肥鱼"].exists)
        XCTAssertTrue(app.staticTexts["模型尚未配置"].exists)
        XCTAssertTrue(app.buttons["整理一份本地文件，或先去看看能连接什么。"].exists)

        for identifier in ["app.chat.source", "app.chat.voice", "app.chat.send"] {
            let control = app.buttons[identifier]
            XCTAssertTrue(control.exists, "Chat 容器不应覆盖 \(identifier)")
            XCTAssertTrue(control.isHittable)
            XCTAssertGreaterThanOrEqual(control.frame.height, 44)
        }
        XCTAssertTrue(app.descendants(matching: .any)["app.chat.composer"].isHittable)
    }

    func testSourceMenuShowsCurrentSelectionAndKeepsConnectorManagement() {
        let source = app.buttons["app.chat.source"]
        XCTAssertTrue(source.waitForExistence(timeout: 60))
        source.tap()
        app.buttons["文件"].tap()
        XCTAssertTrue(source.label.contains("文件"))

        source.tap()
        XCTAssertTrue(app.buttons["自动"].exists)
        XCTAssertTrue(app.buttons["GitHub"].exists)
        XCTAssertTrue(app.buttons["Gmail"].exists)
        XCTAssertTrue(app.buttons["管理连接器"].exists)
    }

    func testKeyboardHidesDockWithoutCoveringPersonalAgentComposer() {
        let editor = app.descendants(matching: .any)["app.chat.composer"]
        let dock = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier == %@", "app.dock")).firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 60))
        XCTAssertTrue(dock.waitForExistence(timeout: 10))
        XCTAssertLessThanOrEqual(editor.frame.maxY, dock.frame.minY)

        editor.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 10))
        XCTAssertFalse(dock.exists)
        XCTAssertTrue(editor.isHittable)
        editor.typeText("pa-chat-keyboard")
        app.staticTexts["今天想一起处理什么？"].tap()
        XCTAssertTrue(dock.waitForExistence(timeout: 10))
        XCTAssertEqual(editor.value as? String, "pa-chat-keyboard")
    }
}
