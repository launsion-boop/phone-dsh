// SPDX-License-Identifier: MIT

import XCTest

@MainActor
final class PA_ShellAnchorTests: XCTestCase {
    func testV4KeepsExactlyOneWorkerAnchorAcrossAllTabs() throws {
        let app = XCUIApplication(bundleIdentifier: "dev.phone-dsh.probe")
        app.launchArguments = ["-PDSH_SHELL", "v4", "-uiPreview", "app.chat"]
        app.launch()
        defer { app.terminate() }
        let anchors = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier == %@", "shell.worker-anchor"))
        XCTAssertTrue(anchors.firstMatch.waitForExistence(timeout: 15))
        XCTAssertEqual(anchors.count, 1)
        for tab in ["DSH", "发现", "个人", "Chat"] {
            app.buttons[tab].tap()
            XCTAssertEqual(anchors.count, 1)
        }
    }
}
