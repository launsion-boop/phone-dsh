// SPDX-License-Identifier: MIT

// SIM-lane entry: configure the local DSH KEY in a dedicated Simulator and
// send one real Bot task through the app. The root SIM lane supplies the
// endpoint/key/model via launch environment. This test must NOT be run on a
// shared simulator: the caller owns the destination and resets it.
//
// Required environment:
//   PDSH_SIM_BASE_URL  local DSH endpoint
//   PDSH_SIM_API_KEY   local DSH key
//   PDSH_SIM_MODEL     model id
// Optional:
//   PDSH_SIM_TASK      user task text (default: 用一句话确认你能收到这条消息)

import XCTest

@MainActor
final class SimLocalDSHProviderUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        let env = ProcessInfo.processInfo.environment
        guard let base = env["PDSH_SIM_BASE_URL"], !base.isEmpty,
              let key = env["PDSH_SIM_API_KEY"], !key.isEmpty,
              let model = env["PDSH_SIM_MODEL"], !model.isEmpty else {
            throw XCTSkip("SIM lane env PDSH_SIM_BASE_URL/KEY/MODEL not provided")
        }
        continueAfterFailure = false
        app = XCUIApplication(bundleIdentifier: "dev.phone-dsh.probe")
        app.launchArguments = [
            "-uiPreview", "settings.model",
            "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN",
        ]
        app.launch()
        XCTAssertTrue(app.buttons["provider.add"].waitForExistence(timeout: 30))
    }

    func testConfigureLocalDSHProviderAndSendBotTask() throws {
        let env = ProcessInfo.processInfo.environment
        let base = env["PDSH_SIM_BASE_URL"]!
        let key = env["PDSH_SIM_API_KEY"]!
        let model = env["PDSH_SIM_MODEL"]!
        let task = env["PDSH_SIM_TASK"] ?? "用一句话确认你能收到这条消息"

        app.buttons["provider.add"].tap()
        XCTAssertTrue(app.textFields["provider.name"].waitForExistence(timeout: 10))
        app.textFields["provider.name"].tap()
        app.textFields["provider.name"].typeText("SIM local DSH")
        app.secureTextFields["provider.key"].tap()
        app.secureTextFields["provider.key"].typeText(key)
        app.textFields["provider.api"].tap()
        app.textFields["provider.api"].typeText(base)
        // The default model is deepseek-flash; replace it with the SIM model
        // when the editor exposes a model picker/value.
        if app.textFields["provider.model"].exists {
            app.textFields["provider.model"].tap()
            app.textFields["provider.model"].typeText(model)
        }
        app.buttons["保存"].tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(
            format: "label CONTAINS %@", "已保存")).firstMatch.waitForExistence(timeout: 15),
                      "provider save receipt missing")

        // Start the local engine from the provider page, then use the real Bot
        // composer. The task is sent once; the SIM lane records the host turn.
        let start = app.buttons["启动本地引擎"]
        if start.exists { start.tap() }
        app.tabBars.buttons["Bot"].tap()
        let input = app.textFields["bot.composer.input"]
        XCTAssertTrue(input.waitForExistence(timeout: 20), "Bot composer missing")
        input.tap()
        input.typeText(task)
        app.buttons["bot.composer.send"].tap()
        XCTAssertTrue(app.staticTexts[task].waitForExistence(timeout: 15),
                      "user task was not rendered")
        // Evidence is the real app session; the SIM lane owns host event
        // collection. Do not synthesize an assistant reply here.
    }
}
