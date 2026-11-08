// SPDX-License-Identifier: MIT
import XCTest

final class IdentityUITests: XCTestCase {
    // Each drag covers less than a third of the viewport with little inertia;
    // inspect between drags so lazily materialized controls cannot be skipped.
    private let sweepSteps = 24

    private func scrollStep(_ list: XCUIElement, towardTop: Bool) {
        let startY: CGFloat = towardTop ? 0.36 : 0.64
        let endY: CGFloat = towardTop ? 0.64 : 0.36
        let start = list.coordinate(withNormalizedOffset: CGVector(dx: 0.07, dy: startY))
        let end = list.coordinate(withNormalizedOffset: CGVector(dx: 0.07, dy: endY))
        start.press(forDuration: 0.1, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.1)
    }

    private func reportScrollPosition(_ list: XCUIElement, towardTop: Bool, step: Int) {
        let visibleCells = list.cells.allElementsBoundByIndex.filter {
            $0.frame.intersects(list.frame)
        }.prefix(3).map { cell in
            "\(cell.label.prefix(60)) @ \(cell.frame)"
        }
        let bar = list.scrollBars.firstMatch
        let barValue = bar.exists ? String(describing: bar.value) : "unavailable"
        print("UI scroll towardTop=\(towardTop) step=\(step) cells=\(visibleCells) scrollBar=\(barValue)")
    }

    /// SwiftUI List lazily materializes rows, so inspect each target in its
    /// own viewport. Never tap while searching and stop after a bounded sweep.
    private func show(_ target: XCUIElement, in app: XCUIApplication,
                      towardTopFirst: Bool = false, requireHittable: Bool = true,
                      file: StaticString = #filePath, line: UInt = #line) -> Bool {
        let list = app.collectionViews.firstMatch
        guard list.waitForExistence(timeout: 5) else {
            XCTFail("Device list not found: \(app.debugDescription)", file: file, line: line)
            return false
        }
        func visible() -> Bool {
            target.exists && (requireHittable ? target.isHittable : target.frame.intersects(list.frame))
        }
        if visible() { return true }
        for towardTop in [towardTopFirst, !towardTopFirst] {
            for step in 1...sweepSteps {
                scrollStep(list, towardTop: towardTop)
                if visible() { return true }
                if step.isMultiple(of: 6) {
                    reportScrollPosition(list, towardTop: towardTop, step: step)
                }
            }
        }
        XCTFail("Element did not become hittable: \(target): \(app.debugDescription)", file: file, line: line)
        return false
    }

    private func assertDeviceOperationsAbsent(in app: XCUIApplication, peer: String,
                                               file: StaticString = #filePath, line: UInt = #line) -> Bool {
        let list = app.collectionViews.firstMatch
        let unavailableID = "ble-device-unavailable-\(peer)"
        let deviceElements = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND identifier ENDSWITH %@ AND identifier != %@",
            "ble-device-", peer, unavailableID))
        // Start at the visible closing state, then inspect through the next
        // section's real button. Stop at that anchor instead of traversing the
        // entire list and allowing the production 20-second timer to expire.
        let nextSection = app.buttons["legacy-task-inspection-start"]
        for step in 0...8 {
            XCTAssertEqual(deviceElements.count, 0, app.debugDescription, file: file, line: line)
            XCTAssertFalse(app.buttons["记录此实验性指纹"].exists, app.debugDescription, file: file, line: line)
            if nextSection.exists && nextSection.isHittable { return true }
            if step < 8 { scrollStep(list, towardTop: false) }
        }
        XCTFail("Did not reach the section after the device: \(app.debugDescription)", file: file, line: line)
        return false
    }

    func testAmbiguousLinkLeavesStandardProfileAvailableWithoutImplicitGrant() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--discovery-ambiguity"]
        app.launch()
        let peer = "12345678-1234-4234-8234-123456789ABC"
        let warning = app.staticTexts["发现多个 Link 服务，暂不可用"]
        guard show(warning, in: app, requireHittable: false) else { return }
        XCTAssertEqual(warning.label, "发现多个 Link 服务，暂不可用")
        let read = app.buttons["ble-device-read-battery-\(peer)"]
        guard show(read, in: app, towardTopFirst: true, requireHittable: false) else { return }
        XCTAssertFalse(read.isEnabled, app.debugDescription)
        let grant = app.switches["ble-device-grant-read-\(peer)"]
        guard show(grant, in: app, towardTopFirst: true) else { return }
        XCTAssertEqual(grant.value as? String, "0", app.debugDescription)
        let audit = app.staticTexts["identity-harness-discovery-audit"]
        XCTAssertTrue(audit.waitForExistence(timeout: 5))
        XCTAssertEqual(audit.label, "phase=connected;battery=true;read=false;readAdmitted=false;alert=false;tasks=false;tool=false;channel=false;rawEmpty=true;requests=1;notifies=0;duplicates=0;deviceNotifications=0;statusNotifications=0;unchanged=true;deadline=cancelled")

        app.buttons["identity-harness-repeat-discovery"].tap()
        XCTAssertEqual(audit.label, "phase=connected;battery=true;read=false;readAdmitted=false;alert=false;tasks=false;tool=false;channel=false;rawEmpty=true;requests=1;notifies=0;duplicates=1;deviceNotifications=0;statusNotifications=0;unchanged=true;deadline=cancelled")
        XCTAssertEqual(grant.value as? String, "0", app.debugDescription)
        guard show(read, in: app, requireHittable: false) else { return }
        XCTAssertFalse(read.isEnabled, app.debugDescription)
        guard show(warning, in: app, requireHittable: false) else { return }
        XCTAssertEqual(warning.label, "发现多个 Link 服务，暂不可用")

        guard show(grant, in: app, towardTopFirst: true) else { return }
        // SwiftUI exposes the entire row as the identified Switch, with the
        // actual UISwitch nested inside it. Tapping the row's center can hit
        // its label instead of the control.
        let grantControl = grant.descendants(matching: .switch).firstMatch
        guard show(grantControl, in: app, towardTopFirst: true) else { return }
        XCTAssertEqual(grantControl.value as? String, "0", app.debugDescription)
        grantControl.tap()
        XCTAssertEqual(grant.value as? String, "1", app.debugDescription)
        guard show(read, in: app, requireHittable: false) else { return }
        XCTAssertTrue(read.isEnabled, app.debugDescription)
        XCTAssertEqual(audit.label, "phase=connected;battery=true;read=true;readAdmitted=true;alert=false;tasks=false;tool=false;channel=false;rawEmpty=true;requests=1;notifies=0;duplicates=1;deviceNotifications=0;statusNotifications=0;unchanged=true;deadline=cancelled")
    }

    func testServiceChangeClosesPageUntilDisconnectBoundary() throws {
        let app = XCUIApplication()
        app.launch()
        let peer = "12345678-1234-4234-8234-123456789ABC"
        let read = app.buttons["ble-device-read-battery-\(peer)"]
        let alert = app.buttons["ble-device-alert-0-\(peer)"]
        guard show(read, in: app) else { return }
        XCTAssertTrue(read.isEnabled, app.debugDescription)
        guard show(alert, in: app, towardTopFirst: true) else { return }
        XCTAssertTrue(alert.isEnabled, app.debugDescription)
        let readGrant = app.switches["ble-device-grant-read-\(peer)"]
        guard show(readGrant, in: app, towardTopFirst: true) else { return }
        XCTAssertTrue(readGrant.isEnabled, app.debugDescription)

        app.buttons["identity-harness-service-change"].tap()
        let unavailable = app.staticTexts["ble-device-unavailable-\(peer)"]
        guard show(unavailable, in: app, towardTopFirst: true) else { return }
        XCTAssertEqual(unavailable.label, "正在等待系统断开，暂不可重连")
        guard assertDeviceOperationsAbsent(in: app, peer: peer) else { return }
        let audit = app.staticTexts["identity-harness-service-audit"]
        XCTAssertEqual(audit.label, "phase=closing;read=false;alert=false;tasks=false;connects=1;disconnects=1;insideDenied=false")

        app.buttons["identity-harness-disconnect-callback"].tap()
        let reconnect = app.buttons["ble-device-connect-\(peer)"]
        guard show(reconnect, in: app, towardTopFirst: true) else { return }
        XCTAssertTrue(reconnect.isEnabled)
        XCTAssertFalse(unavailable.exists)
        XCTAssertEqual(audit.label, "phase=idle;read=false;alert=false;tasks=false;connects=1;disconnects=1;insideDenied=true")
        reconnect.tap()
        XCTAssertEqual(audit.label, "phase=connecting;read=false;alert=false;tasks=false;connects=2;disconnects=1;insideDenied=true")
    }

    func testFailureRendersAndExplicitRetryClearsIt() throws {
        let app = XCUIApplication()
        app.launch()
        let confirm = app.buttons["记录此实验性指纹"]
        guard show(confirm, in: app) else { return }
        let audit = app.staticTexts["identity-harness-audit"]
        XCTAssertTrue(audit.waitForExistence(timeout: 5))
        XCTAssertEqual(audit.label, "pending=true;recorded=false;tasks=false;commandsUnchanged=true;storage=invalid")
        let error = app.staticTexts["ble-device-identity-error-12345678-1234-4234-8234-123456789ABC"]
        XCTAssertFalse(error.exists)

        confirm.tap()
        guard show(error, in: app, towardTopFirst: true) else { return }
        XCTAssertEqual(error.label, "记录身份失败，请重试")
        XCTAssertEqual(audit.label, "pending=true;recorded=false;tasks=false;commandsUnchanged=true;storage=invalid")

        app.buttons["identity-harness-repair"].tap()
        XCTAssertEqual(audit.label, "pending=true;recorded=false;tasks=false;commandsUnchanged=true;storage=valid")
        guard show(confirm, in: app, towardTopFirst: true) else { return }
        confirm.tap()
        let disappearance = NSPredicate(format: "exists == false")
        expectation(for: disappearance, evaluatedWith: error)
        waitForExpectations(timeout: 5)
        XCTAssertEqual(audit.label, "pending=false;recorded=true;tasks=false;commandsUnchanged=true;storage=recorded")
    }
}
