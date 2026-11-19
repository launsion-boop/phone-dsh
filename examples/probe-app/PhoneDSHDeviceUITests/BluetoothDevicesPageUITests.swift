// SPDX-License-Identifier: MIT
import XCTest

/// Real XCUI coverage for the production `BluetoothDevicesPage`. The app is
/// launched with `-uiPreview ble.devices`, whose DEBUG-only host pairs the same
/// page with `BLEDeviceStore.TestAdapter`: no CoreBluetooth radio, no real
/// peripheral and no user settings are touched. These replace the hostless
/// SwiftUI/UIKit accessibility probe, which saw no elements from a List in an
/// XCTest unit process.
@MainActor
final class BluetoothDevicesPageUITests: XCTestCase {
    private let deviceID = UUID(uuidString: "0F0E0D0C-0B0A-4908-8706-050403020100")!
    private var peer: String { deviceID.uuidString }
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication(bundleIdentifier: "dev.phone-dsh.probe")
    }

    override func tearDownWithError() throws {
        if let app { app.terminate() }
    }

    private func launch(_ scenario: String) {
        app.launchArguments = [
            "-uiPreview", "ble.devices.\(scenario)",
            "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN",
        ]
        app.launch()
    }

    private func deviceElement(_ name: String) -> String {
        "ble-device-\(name)-\(peer)"
    }

    private var list: XCUIElement { app.collectionViews.firstMatch }

    private func scrollStep(towardTop: Bool) {
        let startY: CGFloat = towardTop ? 0.36 : 0.64
        let endY: CGFloat = towardTop ? 0.64 : 0.36
        let start = list.coordinate(withNormalizedOffset: CGVector(dx: 0.08, dy: startY))
        let end = list.coordinate(withNormalizedOffset: CGVector(dx: 0.08, dy: endY))
        start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.05)
    }

    /// SwiftUI List materializes rows lazily; sweep until the target is on
    /// screen instead of assuming one viewport contains the whole page.
    @discardableResult
    private func reveal(_ element: XCUIElement, towardTopFirst: Bool = false,
                        requireHittable: Bool = true,
                        file: StaticString = #filePath, line: UInt = #line) -> Bool {
        guard list.waitForExistence(timeout: 30) else {
            XCTFail("BluetoothDevicesPage list did not appear: \(app.debugDescription)",
                    file: file, line: line)
            return false
        }
        func visible() -> Bool {
            element.exists && (!requireHittable || element.isHittable)
        }
        if visible() { return true }
        for towardTop in [towardTopFirst, !towardTopFirst] {
            for _ in 1...24 {
                scrollStep(towardTop: towardTop)
                if visible() { return true }
            }
        }
        XCTFail("Element did not become visible: \(element): \(app.debugDescription)",
                file: file, line: line)
        return false
    }

    @discardableResult
    private func waitForValue(_ element: XCUIElement, _ value: String,
                              timeout: TimeInterval = 10,
                              file: StaticString = #filePath, line: UInt = #line) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", value), object: element)
        guard XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed else {
            XCTFail("Value did not become \(value) for \(element): \(app.debugDescription)",
                    file: file, line: line)
            return false
        }
        return true
    }

    @discardableResult
    private func waitForEnabled(_ element: XCUIElement, timeout: TimeInterval = 10,
                                file: StaticString = #filePath, line: UInt = #line) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "isEnabled == true"), object: element)
        guard XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed else {
            XCTFail("Control did not become enabled: \(element): \(app.debugDescription)",
                    file: file, line: line)
            return false
        }
        return true
    }

    @discardableResult
    private func waitForAudit(_ expected: String, timeout: TimeInterval = 10,
                              file: StaticString = #filePath, line: UInt = #line) -> Bool {
        let audit = app.staticTexts["ble-preview-audit"]
        XCTAssertTrue(audit.waitForExistence(timeout: timeout), app.debugDescription,
                      file: file, line: line)
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@", expected), object: audit)
        guard XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed else {
            XCTFail("Audit did not become \(expected); observed \(audit.label): \(app.debugDescription)",
                    file: file, line: line)
            return false
        }
        return true
    }

    /// Taps the real SwiftUI toggle row. The identifier sits on the row while
    /// the UISwitch is a descendant; tapping the row center can hit the label.
    @discardableResult
    private func setToggle(_ identifier: String, on: Bool,
                           file: StaticString = #filePath, line: UInt = #line) -> Bool {
        let toggle = app.switches[identifier]
        guard reveal(toggle, towardTopFirst: true, file: file, line: line) else { return false }
        let expected = on ? "1" : "0"
        if (toggle.value as? String) != expected {
            let control = toggle.descendants(matching: .switch).firstMatch
            guard reveal(control, towardTopFirst: true, file: file, line: line) else { return false }
            control.tap()
        }
        return waitForValue(toggle, expected, file: file, line: line)
    }

    /// The unavailable branch must expose the retained device and no operation
    /// carrying that device's identifier. Scan to the section that follows the
    /// device so a lazily built row cannot be missed.
    private func assertNoDeviceOperations(file: StaticString = #filePath, line: UInt = #line) {
        let unavailableID = deviceElement("unavailable")
        let operations = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND identifier ENDSWITH %@ AND identifier != %@",
            "ble-device-", peer, unavailableID))
        let nextSection = app.buttons["legacy-task-inspection-start"]
        for step in 0...8 {
            XCTAssertEqual(operations.count, 0,
                           "Unavailable device exposed operations: \(operations.allElementsBoundByIndex.map(\.identifier))",
                           file: file, line: line)
            if nextSection.exists && nextSection.isHittable { return }
            if step < 8 { scrollStep(towardTop: false) }
        }
        XCTFail("Did not reach the section after the device: \(app.debugDescription)",
                file: file, line: line)
    }

    func testClosingPageKeepsDeviceVisibleUntilDisconnectCallbackReturns() throws {
        launch("closing")

        // Connected read/alert controls exist and start disallowed. The two
        // grants are the real toggles; enabling them must enable the controls.
        let read = app.buttons[deviceElement("read-battery")]
        XCTAssertTrue(reveal(read), app.debugDescription)
        XCTAssertFalse(read.isEnabled, app.debugDescription)
        let alert = app.buttons[deviceElement("alert-0")]
        XCTAssertTrue(reveal(alert), app.debugDescription)
        XCTAssertFalse(alert.isEnabled, app.debugDescription)

        XCTAssertTrue(setToggle(deviceElement("grant-read"), on: true))
        XCTAssertTrue(reveal(read), app.debugDescription)
        XCTAssertTrue(waitForEnabled(read))
        XCTAssertTrue(setToggle(deviceElement("grant-alert"), on: true))
        XCTAssertTrue(reveal(alert), app.debugDescription)
        XCTAssertTrue(waitForEnabled(alert))

        // The real disconnect button starts the closing state; the simulated
        // system callback is withheld until this test releases it.
        let disconnect = app.buttons[deviceElement("disconnect")]
        XCTAssertTrue(reveal(disconnect, towardTopFirst: true), app.debugDescription)
        disconnect.tap()

        let unavailable = app.staticTexts[deviceElement("unavailable")]
        XCTAssertTrue(reveal(unavailable, towardTopFirst: true), app.debugDescription)
        XCTAssertEqual(unavailable.label, "正在等待系统断开，暂不可重连")
        XCTAssertFalse(app.buttons[deviceElement("connect")].exists,
                       "Reconnect must not be offered before the disconnect callback returns")
        XCTAssertTrue(waitForAudit(
            "phase=closing;read=false;alert=false;callback=false;insideDenied=false;callbackPhase="))
        assertNoDeviceOperations()

        let callback = app.buttons["ble-preview-disconnect-callback"]
        XCTAssertTrue(callback.waitForExistence(timeout: 10), app.debugDescription)
        callback.tap()

        let reconnect = app.buttons[deviceElement("connect")]
        XCTAssertTrue(reveal(reconnect, towardTopFirst: true), app.debugDescription)
        XCTAssertTrue(reconnect.isEnabled)
        XCTAssertFalse(unavailable.exists)
        XCTAssertTrue(waitForAudit(
            "phase=idle;read=false;alert=false;callback=true;insideDenied=true;callbackPhase=closing"),
            "A connect attempted inside the callback must stay rejected and grants must be off")

        // Reconnect through the real button; the simulated peripheral accepts
        // it and discovers battery/alert again. The connected branch keeps the
        // per-connection authorization guidance visible.
        reconnect.tap()
        let reauthorize = app.staticTexts[deviceElement("reauthorize")]
        XCTAssertTrue(reveal(reauthorize, towardTopFirst: true), app.debugDescription)
        XCTAssertEqual(reauthorize.label,
                       "你连接的设备默认允许 Agent 使用全部能力；关闭某个开关即撤销并记住，断开连接后不再自动重连。")
        let reauthorizationGuide = app.staticTexts.matching(NSPredicate(
            format: "label CONTAINS %@", "每次连接需单独授权")).firstMatch
        XCTAssertTrue(reveal(reauthorizationGuide, towardTopFirst: true),
                      "The page must explain that every connection needs a new grant")

        let afterRead = app.buttons[deviceElement("read-battery")]
        XCTAssertTrue(reveal(afterRead), app.debugDescription)
        XCTAssertFalse(afterRead.isEnabled, app.debugDescription)
        let afterAlert = app.buttons[deviceElement("alert-0")]
        XCTAssertTrue(reveal(afterAlert), app.debugDescription)
        XCTAssertFalse(afterAlert.isEnabled, app.debugDescription)

        let readToggle = app.switches[deviceElement("grant-read")]
        XCTAssertTrue(reveal(readToggle, towardTopFirst: true), app.debugDescription)
        XCTAssertEqual(readToggle.value as? String, "0",
                       "A new connection must not inherit the previous read grant")
        let alertToggle = app.switches[deviceElement("grant-alert")]
        XCTAssertTrue(reveal(alertToggle, towardTopFirst: true), app.debugDescription)
        XCTAssertEqual(alertToggle.value as? String, "0",
                       "A new connection must not inherit the previous alert grant")
    }

    func testQuarantinedPageKeepsDeviceVisibleAndOffersNoDeviceOperations() throws {
        launch("quarantined")

        let read = app.buttons[deviceElement("read-battery")]
        XCTAssertTrue(reveal(read), app.debugDescription)
        XCTAssertTrue(read.isEnabled, app.debugDescription)
        let alert = app.buttons[deviceElement("alert-0")]
        XCTAssertTrue(reveal(alert), app.debugDescription)
        XCTAssertTrue(alert.isEnabled, app.debugDescription)
        let readToggle = app.switches[deviceElement("grant-read")]
        XCTAssertTrue(reveal(readToggle, towardTopFirst: true), app.debugDescription)
        XCTAssertEqual(readToggle.value as? String, "1")
        let alertToggle = app.switches[deviceElement("grant-alert")]
        XCTAssertTrue(reveal(alertToggle, towardTopFirst: true), app.debugDescription)
        XCTAssertEqual(alertToggle.value as? String, "1")

        let radio = app.buttons["ble-preview-radio-unavailable"]
        XCTAssertTrue(radio.waitForExistence(timeout: 10), app.debugDescription)
        radio.tap()

        let unavailable = app.staticTexts[deviceElement("unavailable")]
        XCTAssertTrue(reveal(unavailable, towardTopFirst: true), app.debugDescription)
        XCTAssertEqual(unavailable.label, "连接状态无法确认，暂不可用")
        XCTAssertTrue(waitForAudit(
            "phase=quarantined;read=false;alert=false;callback=false;insideDenied=false;callbackPhase="),
            "Quarantine must revoke the previous grants")
        assertNoDeviceOperations()
    }
}
