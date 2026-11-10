// SPDX-License-Identifier: MIT

import XCTest

/// Hardware acceptance, from a normal user's point of view: connect a TonoLink board once on
/// the Bluetooth devices page, then its Link tools (light.set …) are allowed without any tap,
/// and the chat can switch the LED. Needs a physical iPhone, a powered board whose name
/// contains `PDSH_TONOLINK_BOARD` (default `PhoneAgent`) and a configured chat model.
@MainActor
final class TonoLinkLEDDeviceUITests: XCTestCase {
    private var app: XCUIApplication!
    private var board = "PhoneAgent"

    override func setUpWithError() throws {
        continueAfterFailure = false
        let env = ProcessInfo.processInfo.environment
        guard env["PDSH_TONOLINK_LED_TEST"] == "1" else {
            throw XCTSkip("set PDSH_TONOLINK_LED_TEST=1 with a powered TonoLink board nearby")
        }
        board = env["PDSH_TONOLINK_BOARD"] ?? board
        app = XCUIApplication()
        XCUIDevice.shared.orientation = .portrait
        app.launch()
    }

    override func tearDownWithError() throws {
        app?.terminate()
    }

    func testConnectOnceThenChatSwitchesLED() throws {
        openBluetoothDevices()
        connectBoardIfNeeded()

        // Default trust: the Link tool is allowed with no tap.
        let grant = app.switches.matching(NSPredicate(format: "identifier BEGINSWITH %@", "ble-device-link-light.set-")).firstMatch
        if !scrollUntilExists(grant, timeout: 60) {
            print("PDSH-UI-TREE devices\n" + app.debugDescription)
            XCTFail("\(board) never offered light.set")
            return
        }
        XCTAssertEqual(grant.value as? String, "1", "light.set should be allowed by default for the user's own board")

        goBackToChat()
        for (command, expected) in [("off", false), ("on", true)] {
            let reply = sendAndWait("Use ble_link_call once: device \(board), tool light.set, args {\"on\": \(expected)}. Reply with the exact tool result. [\(command)]")
            XCTAssertFalse(reply.contains { $0.localizedCaseInsensitiveContains("journal idempotency key") }, "key missing: \(reply)")
            XCTAssertFalse(reply.contains { $0.contains("Authorize this Link tool") }, "permission prompt: \(reply)")
            XCTAssertTrue(reply.contains { $0.contains("\"on\":\(expected)") }, "LED not \(command): \(reply)")
        }
    }

    // MARK: - Steps

    private func openBluetoothDevices() {
        let discover = app.buttons["发现"]
        XCTAssertTrue(discover.waitForExistence(timeout: 60), "tab bar did not appear")
        discover.tap()
        let devices = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "设备, ")).firstMatch
        XCTAssertTrue(devices.waitForExistence(timeout: 10), "设备 row missing on 发现")
        devices.tap()
        let open = app.buttons.matching(NSPredicate(format: "label == %@ AND identifier == ''", "连接设备")).firstMatch
        XCTAssertTrue(open.waitForExistence(timeout: 10), "连接设备 button missing")
        open.tap()
    }

    /// A user taps 连接 on the board's row; a remembered board is already connecting by itself.
    private func connectBoardIfNeeded() {
        let title = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", board)).firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 30), "\(board) not listed (scan / system-connected lookup)")
        // The connect button that belongs to this board: the first `ble-device-connect-<id>` after its name.
        let tree = app.debugDescription
        guard let name = tree.range(of: board) else { return }
        guard let marker = tree.range(of: "ble-device-connect-", range: name.upperBound..<tree.endIndex) else { return }
        let id = String(tree[marker.lowerBound...].prefix(while: { $0 != "'" }))
        let connect = app.buttons[id]
        if connect.waitForExistence(timeout: 3) { connect.tap() }
    }

    private func goBackToChat() {
        let back = app.buttons.matching(NSPredicate(format: "label IN %@ OR identifier == 'BackButton'", ["返回", "Back", "发现"])).firstMatch
        if back.waitForExistence(timeout: 5) { back.tap() }
        let dsh = app.buttons["DSH"]
        XCTAssertTrue(dsh.waitForExistence(timeout: 10))
        dsh.tap()
    }

    /// Sends one message and returns the texts after it once the turn has finished.
    private func sendAndWait(_ message: String) -> [String] {
        let composer = app.textViews.matching(NSPredicate(format: "label BEGINSWITH %@", "发消息或创建任务")).firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 30), "composer not ready")
        composer.tap()
        composer.typeText(message)
        let send = app.buttons.matching(NSPredicate(format: "label == %@ AND identifier != %@ AND enabled == true", "发送消息", "bot.composer.send")).firstMatch
        XCTAssertTrue(send.waitForExistence(timeout: 10))
        send.tap()
        let stop = app.buttons.matching(NSPredicate(format: "label == %@", "停止执行")).firstMatch
        _ = stop.waitForExistence(timeout: 20)
        let finished = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: stop)
        XCTAssertEqual(XCTWaiter().wait(for: [finished], timeout: 240), .completed, "the turn did not finish")
        let all = texts()
        let start = all.lastIndex { $0.hasPrefix(String(message.prefix(40))) } ?? all.startIndex
        let reply = Array(all[start...])
        let attachment = XCTAttachment(string: reply.joined(separator: "\n"))
        attachment.lifetime = .keepAlways
        add(attachment)
        print("PDSH-UI-REPLY\n" + reply.joined(separator: "\n"))
        return reply
    }

    private func scrollUntilExists(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !element.exists && Date() < deadline {
            if app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "PDSH Tools")).firstMatch.exists { app.swipeUp() }
            _ = element.waitForExistence(timeout: 2)
        }
        return element.exists
    }

    /// One read of the whole tree: the transcript keeps updating, so per-element reads race.
    private func texts() -> [String] {
        app.debugDescription.split(separator: "\n").compactMap { line -> String? in
            guard line.contains("StaticText"), let start = line.range(of: "label: '") else { return nil }
            var label = String(line[start.upperBound...])
            if label.hasSuffix("'") { label.removeLast() }
            return label.isEmpty ? nil : label
        }
    }
}
