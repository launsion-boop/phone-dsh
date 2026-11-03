// SPDX-License-Identifier: MIT

import XCTest

@MainActor
final class PA_AppDockTests: XCTestCase {
    func testContainerPreservesTabActionsAndBadgeAccessibility() throws {
        let app = XCUIApplication(bundleIdentifier: "dev.phone-dsh.probe")
        app.launchArguments = ["-PDSH_SHELL", "v4", "-uiPreview", "app.dock"]
        app.launch()
        defer { app.terminate() }

        let dock = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier == %@", "app.dock")).firstMatch
        XCTAssertTrue(dock.waitForExistence(timeout: 15))

        let tabs = [
            ("chat", "Chat"),
            ("dsh", "DSH"),
            ("discover", "发现"),
            ("profile", "个人"),
        ]
        for (identifier, label) in tabs {
            let button = app.buttons["app.tab.\(identifier)"]
            XCTAssertTrue(button.exists, "Missing accessible action for \(identifier)")
            XCTAssertEqual(button.label, label)
            XCTAssertTrue(button.isHittable)
            XCTAssertGreaterThanOrEqual(button.frame.height, 44)
            XCTAssertGreaterThanOrEqual(button.frame.minX, dock.frame.minX)
            XCTAssertLessThanOrEqual(button.frame.maxX, dock.frame.maxX)
        }

        XCTAssertEqual(app.buttons["app.tab.chat"].value as? String, "已选中")
        XCTAssertEqual(app.buttons["app.tab.dsh"].value as? String, "2 项需要处理")
        XCTAssertEqual(app.buttons["app.tab.discover"].value as? String, "有需要处理的事项")
    }
}
