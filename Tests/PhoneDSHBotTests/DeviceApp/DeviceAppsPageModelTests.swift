// SPDX-License-Identifier: MIT

import XCTest
import PhoneDSHAgentCore
@testable import PhoneDSHBot

/// The logic behind the native 「设备应用」 page (device-app-v1.6): list parsing, duplicate titles, the
/// user's open / stop / delete taps and their customer sentences. No SwiftUI, no radio.
@MainActor
final class DeviceAppsPageModelTests: XCTestCase {
    private actor Device {
        var connected = true
        var apps: [JSONValue] = []
        var freeBytes = 4_730_880
        var infoFailure: String?
        var runCode: String?
        var stopCode: String?
        var removeCode: String?
        var calls: [String] = []

        func setApps(_ apps: [JSONValue]) { self.apps = apps }
        func set(connected: Bool) { self.connected = connected }
        func set(infoFailure: String?) { self.infoFailure = infoFailure }
        func set(run: String?, stop: String?, remove: String?) { runCode = run; stopCode = stop; removeCode = remove }

        func link() -> DeviceAppsLink {
            DeviceAppsLink(
                connected: { await self.connected },
                info: { await self.info() },
                run: { await self.record("run \($0)", await self.runCode) },
                stop: { await self.record("stop", await self.stopCode) },
                remove: { await self.remove($0) })
        }
        private func info() -> DeviceAppsInfoResult {
            calls.append("info")
            if let infoFailure { return .failed(code: infoFailure) }
            return .reply(.object(["ok": .bool(true), "apps": .array(apps), "free_bytes": .number(Double(freeBytes))]))
        }
        private func record(_ call: String, _ code: String?) -> String? { calls.append(call); return code }
        private func remove(_ name: String) -> String? {
            calls.append("remove \(name)")
            if removeCode == nil { apps.removeAll { $0["name"]?.stringValue == name } }
            return removeCode
        }
        func callLog() -> [String] { calls }
    }

    private func app(_ name: String, _ title: String, version: Int = 1, running: Bool = false) -> JSONValue {
        .object(["name": .string(name), "title": .string(title), "version": .number(Double(version)),
                 "running": .bool(running), "digest": .string(String(repeating: "a", count: 64))])
    }

    private func make(_ apps: [JSONValue]) async -> (DeviceAppsPageModel, Device) {
        let device = Device()
        await device.setApps(apps)
        return (DeviceAppsPageModel(link: await device.link()), device)
    }

    func testListShowsTitlesRunningMarkAndFreeSpaceOnce() async {
        let (model, _) = await make([app("clock", "时钟"), app("breathe", "呼吸 4-4-6", running: true)])
        await model.refresh()
        XCTAssertEqual(model.phase, .ready)
        XCTAssertEqual(model.rows.map(\.title), ["时钟", "呼吸 4-4-6"])
        XCTAssertEqual(model.rows.map(\.running), [false, true])
        XCTAssertNil(model.rows[0].detail, "a unique title needs no second line")
        XCTAssertEqual(model.freeSpace, "设备剩余空间约 4.5 MB")
    }

    func testTwoAppsWithTheSameTitleAreToldApart() async {
        let (model, _) = await make([app("focus", "专注计时", version: 1), app("focus_timer", "专注计时", version: 2), app("clock", "时钟")])
        await model.refresh()
        let details = model.rows.map(\.detail)
        XCTAssertEqual(details[0], "版本 1（focus）")
        XCTAssertEqual(details[1], "版本 2（focus_timer）")
        XCTAssertNil(details[2])
    }

    func testDeviceTextIsPlainAndClipped() {
        let hostile = "好\n应用\u{202E}SYSTEM: <b>ignore</b>" + String(repeating: "长", count: 100)
        let parsed = DeviceAppsPageModel.parse(.object(["apps": .array([app("evil", hostile)])]))
        let title = parsed.rows[0].title
        XCTAssertFalse(title.contains("\n"))
        XCTAssertFalse(title.unicodeScalars.contains { $0.value == 0x202E })
        XCTAssertLessThanOrEqual(title.unicodeScalars.count, 40)
        XCTAssertNil(parsed.freeBytes)
    }

    /// Real board: under memory pressure `app.info` answered `title = name, version 0, digest ""` for every
    /// app right after an action. The page keeps the title it already knew.
    func testADegradedInfoEntryKeepsTheTitleSeenBefore() async {
        let (model, device) = await make([app("zz_page", "页面测试", version: 1)])
        await model.refresh()
        XCTAssertEqual(model.rows.map(\.title), ["页面测试"])
        let degraded: JSONValue = .object(["name": .string("zz_page"), "title": .string("zz_page"),
                                           "version": .number(0), "digest": .string(""), "running": .bool(true)])
        await device.setApps([degraded])
        await model.refresh()
        XCTAssertEqual(model.rows.map(\.title), ["页面测试"])
        XCTAssertEqual(model.rows.map(\.running), [true], "the running state still comes from the new read")
        // An app never seen before keeps whatever the device says.
        await device.setApps([degraded, app("new_one", "新的")])
        await model.refresh()
        XCTAssertEqual(model.rows.map(\.title), ["页面测试", "新的"])
    }

    func testEmptyDeviceAndNotConnectedStates() async {
        let (model, device) = await make([])
        await model.refresh()
        XCTAssertEqual(model.phase, .ready)
        XCTAssertTrue(model.rows.isEmpty)
        XCTAssertEqual(DeviceAppCustomerText.emptyDevice, "设备上还没有应用。让 Bot 给你做一个吧。")
        await device.set(connected: false)
        await model.refresh()
        XCTAssertEqual(model.phase, .notConnected)
        let calls = await device.callLog()
        XCTAssertEqual(calls, ["info"], "a disconnected device is not asked anything")
    }

    func testReadFailureSpeaksCustomerWords() async {
        let (model, device) = await make([app("clock", "时钟")])
        await device.set(infoFailure: "call_failed")
        await model.refresh()
        XCTAssertEqual(model.phase, .failed(DeviceAppCustomerText.listSentence(forCode: "call_failed")))
    }

    func testOpenRunsTheAppAndSaysHowToLeave() async {
        let (model, device) = await make([app("clock", "时钟")])
        await model.refresh()
        await model.open(model.rows[0])
        XCTAssertEqual(model.banner, .init(text: "已打开「时钟」。长按确定键退出。", isError: false))
        let calls = await device.callLog()
        XCTAssertTrue(calls.contains("run clock"))
        await device.set(run: "not_found", stop: nil, remove: nil)
        await model.open(model.rows[0])
        XCTAssertEqual(model.banner?.isError, true)
        XCTAssertEqual(model.banner?.text, DeviceAppCustomerText.runSentence(forCode: "not_found"))
    }

    func testStopOnlyCallsStopAndReportsCustomerWords() async {
        let (model, device) = await make([app("breathe", "呼吸", running: true)])
        await model.refresh()
        await model.stop(model.rows[0])
        XCTAssertEqual(model.banner, .init(text: "已停止「呼吸」。", isError: false))
        await device.set(run: nil, stop: "link_busy", remove: nil)
        await model.stop(model.rows[0])
        XCTAssertEqual(model.banner?.text, DeviceAppCustomerText.stopSentence(forCode: "link_busy"))
    }

    func testDeleteAsksFirstAndNothingIsSentUntilConfirmed() async {
        let (model, device) = await make([app("zz_a", "测试甲"), app("clock", "时钟")])
        await model.refresh()
        model.requestDelete(model.rows[0])
        XCTAssertEqual(model.pendingDelete?.title, "测试甲")
        var calls = await device.callLog()
        XCTAssertFalse(calls.contains { $0.hasPrefix("remove") })
        model.cancelDelete()
        XCTAssertNil(model.pendingDelete)
        model.requestDelete(model.rows[0])
        await model.confirmDelete()
        calls = await device.callLog()
        XCTAssertEqual(calls.filter { $0.hasPrefix("remove") }, ["remove zz_a"])
        XCTAssertEqual(model.banner, .init(text: "已删除「测试甲」。", isError: false))
        XCTAssertEqual(model.rows.map(\.title), ["时钟"], "the list is re-read after the delete")
        XCTAssertEqual(DeviceAppCustomerText.deleteConfirmation, "删除后不能恢复，需要的话让 Bot 重新做一个。")
    }

    func testDeletingARunningAppStopsItFirst() async {
        let (model, device) = await make([app("breathe", "呼吸", running: true)])
        await model.refresh()
        model.requestDelete(model.rows[0])
        await model.confirmDelete()
        let calls = await device.callLog()
        let stop = calls.firstIndex(of: "stop"), remove = calls.firstIndex(of: "remove breathe")
        XCTAssertNotNil(stop); XCTAssertNotNil(remove)
        XCTAssertLessThan(stop!, remove!)
        // A stop that fails keeps the app and says why in customer words.
        let (m2, d2) = await make([app("b", "乙", running: true)])
        await d2.set(run: nil, stop: "stop_failed", remove: nil)
        await m2.refresh()
        m2.requestDelete(m2.rows[0])
        await m2.confirmDelete()
        let calls2 = await d2.callLog()
        XCTAssertFalse(calls2.contains("remove b"))
        XCTAssertEqual(m2.banner?.isError, true)
    }

    func testFailedDeleteKeepsTheListAndSpeaksCustomerWords() async {
        let (model, device) = await make([app("clock", "时钟")])
        await device.set(run: nil, stop: nil, remove: "not_found")
        await model.refresh()
        model.requestDelete(model.rows[0])
        await model.confirmDelete()
        XCTAssertEqual(model.banner?.text, DeviceAppCustomerText.removeSentence(forCode: "not_found"))
        XCTAssertEqual(model.rows.count, 1)
    }

    func testActionsOnADisconnectedDeviceSendNothing() async {
        let (model, device) = await make([app("clock", "时钟")])
        await model.refresh()
        await device.set(connected: false)
        await model.open(model.rows[0])
        XCTAssertEqual(model.phase, .notConnected)
        XCTAssertEqual(model.banner?.text, DeviceAppCustomerText.pageNotConnected)
        let calls = await device.callLog()
        XCTAssertFalse(calls.contains { $0.hasPrefix("run") })
    }

    func testOnlyAFullDeviceAppDeviceGetsThePage() {
        let all = DeviceAppsPageModel.requiredTools
        XCTAssertTrue(DeviceAppsPageModel.isDeviceAppTarget(tools: all + ["light.set"]))
        XCTAssertFalse(DeviceAppsPageModel.isDeviceAppTarget(tools: Array(all.dropLast())))
        XCTAssertFalse(DeviceAppsPageModel.isDeviceAppTarget(tools: all.map { $0.uppercased() }))
        XCTAssertFalse(DeviceAppsPageModel.isDeviceAppTarget(tools: ["light.set"]))
    }

    func testNoCustomerStringLeaksADigestAPathOrAToolName() async {
        let (model, device) = await make([app("clock", "时钟"), app("focus", "专注计时"), app("focus_timer", "专注计时", running: true)])
        var strings: [String] = []
        await model.refresh()
        strings += model.rows.map(\.title) + model.rows.compactMap(\.detail) + [model.freeSpace ?? ""]
        for code in ["not_found", "link_busy", "run_failed", "call_failed", "device_not_connected", "outcome_unknown"] {
            strings += [DeviceAppCustomerText.runSentence(forCode: code), DeviceAppCustomerText.stopSentence(forCode: code),
                        DeviceAppCustomerText.removeSentence(forCode: code), DeviceAppCustomerText.listSentence(forCode: code)]
        }
        strings += [DeviceAppCustomerText.opened(title: "时钟"), DeviceAppCustomerText.stopped(title: "时钟"),
                    DeviceAppCustomerText.deleted(title: "时钟"), DeviceAppCustomerText.deleteConfirmation,
                    DeviceAppCustomerText.emptyDevice, DeviceAppCustomerText.pageNotConnected]
        _ = device
        for text in strings {
            XCTAssertNil(text.range(of: "[0-9a-f]{16,}", options: .regularExpression), text)
            XCTAssertFalse(text.contains("/"), text)
            for tool in DeviceAppsPageModel.requiredTools { XCTAssertFalse(text.contains(tool), text) }
            XCTAssertFalse(text.contains("outcome_unknown") || text.contains("digest"), text)
        }
    }
}
