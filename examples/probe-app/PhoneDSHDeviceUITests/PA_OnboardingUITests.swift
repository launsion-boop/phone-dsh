// SPDX-License-Identifier: MIT

import XCTest

@MainActor
final class PA_OnboardingUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication(bundleIdentifier: "dev.phone-dsh.probe")
    }

    override func tearDownWithError() throws {
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = String(name.split(separator: " ").last ?? "onboarding-ui")
        screenshot.lifetime = .keepAlways
        add(screenshot)
        app.terminate()
    }

    func testTwoStepOnboardingPersistsNamesMemoryAndSkipsOnRelaunch() throws {
        launchFreshOnboarding()
        let ownerField = app.textFields["onboarding.owner-name"]
        XCTAssertTrue(ownerField.waitForExistence(timeout: 30))
        ownerField.tap()
        ownerField.typeText("  引导主人  ")
        let continueButton = app.buttons["onboarding.continue"]
        XCTAssertTrue(continueButton.isEnabled)
        continueButton.tap()

        let agentField = app.textFields["onboarding.agent-name"]
        XCTAssertTrue(agentField.waitForExistence(timeout: 10))
        XCTAssertEqual(agentField.value as? String, "小肥鱼")
        agentField.tap()
        agentField.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 3))
        agentField.typeText("导航鱼")
        XCTAssertEqual(agentField.value as? String, "导航鱼")
        app.buttons["onboarding.finish"].tap()

        assertChat(agentName: "导航鱼")
        openMemoryAndAssertOwner("引导主人")

        app.terminate()
        app.launchArguments = ["-PDSH_SHELL", "v4", "-personalOnboarding"]
        app.launch()
        assertChat(agentName: "导航鱼")
        XCTAssertFalse(app.textFields["onboarding.owner-name"].exists)
        openMemoryAndAssertOwner("引导主人")
    }

    func testDefaultAgentNameCompletesOnboarding() throws {
        launchFreshOnboarding()
        let ownerField = app.textFields["onboarding.owner-name"]
        XCTAssertTrue(ownerField.waitForExistence(timeout: 30))
        ownerField.tap()
        ownerField.typeText("默认名主人")
        app.buttons["onboarding.continue"].tap()
        let agentField = app.textFields["onboarding.agent-name"]
        XCTAssertTrue(agentField.waitForExistence(timeout: 10))
        XCTAssertEqual(agentField.value as? String, "小肥鱼")
        app.buttons["onboarding.finish"].tap()
        assertChat(agentName: "小肥鱼")
    }

    private func launchFreshOnboarding() {
        app.launchArguments = ["-PDSH_SHELL", "v4", "-personalOnboarding", "-resetPersonalOnboarding"]
        app.launch()
        XCTAssertTrue(app.staticTexts["第 1 步，共 2 步"].waitForExistence(timeout: 30))
        XCTAssertEqual(app.state, .runningForeground)
    }

    private func assertChat(agentName: String) {
        XCTAssertTrue(app.descendants(matching: .any)["app.chat"].waitForExistence(timeout: 60))
        let settings = app.buttons["app.chat.agent-settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 10))
        XCTAssertTrue(settings.label.contains(agentName))
    }

    private func openMemoryAndAssertOwner(_ ownerName: String) {
        app.buttons["app.chat.agent-settings"].tap()
        XCTAssertTrue(app.navigationBars["Personal Agent"].waitForExistence(timeout: 15))
        app.descendants(matching: .any)["profile.memory"].tap()
        XCTAssertTrue(app.navigationBars["个人 Memory"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts[ownerName].waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["displayName"].exists)
    }
}
