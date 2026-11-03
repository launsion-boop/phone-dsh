// SPDX-License-Identifier: MIT

import XCTest

@MainActor
final class PA_ShellRouteTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication(bundleIdentifier: "dev.phone-dsh.probe")
        app.launchArguments = ["-PDSH_SHELL", "v4"]
        app.launchEnvironment["PDSH_OFFICE_WORKSPACE_NAME"] = "pa-shell-routes"
        app.launchEnvironment["PDSH_SEED_PROVIDER_KEY"] = "pa-shell-placeholder-key"
    }

    override func tearDownWithError() throws {
        app.terminate()
    }

    func testConnectorDeepLink() throws {
        launch(route: "pdsh://discover?connector=github")
        XCTAssertTrue(app.navigationBars["GitHub"].waitForExistence(timeout: 15))
    }

    func testProfileMemoryDeepLinkUsesPersonalMemory() throws {
        launch(route: "pdsh://profile?focus=memory")
        XCTAssertTrue(app.navigationBars["个人 Memory"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.descendants(matching: .any)["profile.personal-memory"].exists)
        XCTAssertFalse(app.staticTexts["个人记忆正在接入"].exists)
        XCTAssertFalse(app.staticTexts["内存压力"].exists)
    }

    func testChatDeepLinkOpensPersonalAgentFollowUp() throws {
        launch(route: "pdsh://chat?followUp=3F4D4F6A-6C28-4B4E-93F4-48C0D2EFD001")
        XCTAssertTrue(app.navigationBars["持续跟进"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.staticTexts["Personal Agent 正在接入"].exists)
    }

    func testDSHDeepLinkSelectsTargetSession() throws {
        app.launchArguments += ["-appRoute", "pdsh://dsh"]
        app.launch()
        let first = createSessionAndReadID()
        let second = createSessionAndReadID()
        XCTAssertNotEqual(first, second)
        app.terminate()
        launch(route: "pdsh://dsh?session=\(first)")
        let target = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier == %@", "dsh.session.\(first)")).firstMatch
        XCTAssertTrue(target.waitForExistence(timeout: 60))
    }

    private func launch(route: String) {
        app.launchArguments = ["-PDSH_SHELL", "v4", "-appRoute", route]
        app.launch()
    }

    private func createSessionAndReadID() -> String {
        let open = app.buttons["打开会话列表"]
        XCTAssertTrue(open.waitForExistence(timeout: 60))
        open.tap()
        let create = app.buttons["新会话"]
        XCTAssertTrue(create.waitForExistence(timeout: 10))
        create.tap()
        let session = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@ AND identifier != %@",
                        "dsh.session.", "dsh.session.new")).firstMatch
        XCTAssertTrue(session.waitForExistence(timeout: 60))
        return String(session.identifier.dropFirst("dsh.session.".count))
    }
}
