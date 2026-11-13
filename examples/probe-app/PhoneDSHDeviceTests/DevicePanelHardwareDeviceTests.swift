// SPDX-License-Identifier: MIT
// Physical-device proof for the device panel (device-panel.md): the panel's own
// model, bound to the app's real `BLEDeviceStore`, switches a TonoLink board's
// LED and reads it back through `callLinkTool(origin: .user)` — no chat, no
// model turn. TEST-ONLY: this bundle is hosted by the probe app, so the page it
// screenshots is the production `DevicePanelPage` in the app's own window.
import SwiftUI
import UIKit
import XCTest
import PhoneDSHAgentCore
import PhoneDSHLoopback
@testable import PhoneDSHBLE
@testable import PhoneDSHProbe

@MainActor
final class DevicePanelHardwareDeviceTests: XCTestCase {
    private typealias Model = PhoneDSHProbe.DevicePanelModel
    private typealias Page = PhoneDSHProbe.DevicePanelPage
    private typealias Live = PhoneDSHProbe.LiveDevicePanelSource
    private typealias Cache = PhoneDSHProbe.DevicePanelResultCache

    private var window: UIWindow?

    private func requireFixture() throws -> String {
        let environment = ProcessInfo.processInfo.environment
        let enabled = environment["TEST_RUNNER_PDSH_DEVICE_PANEL_TEST"] ?? environment["PDSH_DEVICE_PANEL_TEST"]
        guard enabled == "1" else {
            throw XCTSkip("device panel fixture not supplied: pass TEST_RUNNER_PDSH_DEVICE_PANEL_TEST=1")
        }
        return environment["TEST_RUNNER_PDSH_TONOLINK_BOARD"] ?? environment["PDSH_TONOLINK_BOARD"] ?? "PhoneAgent"
    }

    override func tearDown() async throws {
        window?.isHidden = true
        window = nil
    }

    func testPanelSwitchesLEDAndReadsItBack() async throws {
        let board = try requireFixture()
        let store = BLEDeviceStore.shared
        let device = try await connectedBoard(named: board, store: store)
        print("PDSH-PANEL device=\(device.name) link_device_id=\(device.linkDeviceID) tools=\(device.linkTools) granted=\(device.grantedTools.sorted())")
        for raw in device.linkToolDescriptors {
            print("PDSH-PANEL tool=\(String(decoding: (try? raw.encoded()) ?? Data(), as: UTF8.self))")
        }

        let model = Model(source: Live(device: device, store: store), results: Cache.shared(for: device.id))
        model.refresh()
        show(AnyView(Page(model: model, deviceName: device.name)))
        try await snapshot("01-open")
        XCTAssertNotNil(model.tool(named: "light.set"), "the board did not advertise light.set")

        for on in [true, false, true] {
            model.setEditorValue(.toggle(on), tool: "light.set", argument: "on")
            await model.send(toolName: "light.set", preset: nil)
            print("PDSH-PANEL light.set on=\(on) record=\(String(describing: model.lastResults["light.set"])) error=\(model.errorText ?? "-")")
            guard case .completed? = model.lastResults["light.set"]?.state else {
                try await snapshot("fail-set-\(on)")
                return XCTFail("light.set on=\(on) did not complete: \(String(describing: model.lastResults["light.set"])) \(model.errorText ?? "")")
            }
            await model.send(toolName: "light.get", preset: nil)
            print("PDSH-PANEL light.get record=\(String(describing: model.lastResults["light.get"])) error=\(model.errorText ?? "-")")
            guard case .completed(let text)? = model.lastResults["light.get"]?.state else {
                try await snapshot("fail-get-\(on)")
                return XCTFail("light.get did not complete: \(String(describing: model.lastResults["light.get"]))")
            }
            XCTAssertTrue(text.replacingOccurrences(of: " ", with: "").contains("\"on\":\(on)"),
                          "light.get did not read back on=\(on): \(text)")
            try await snapshot("02-led-\(on ? "on" : "off")")
        }

        // A1: a descriptor turns the same tools into one-tap buttons. It goes
        // through the real evaluator and the host-private store.
        let descriptor = try JSONValue.object([
            "v": .number(1), "device_id": .string(device.linkDeviceID), "title": .string("TonoLink 灯"),
            "controls": .array([
                .object(["tool": .string("light.set"), "label": .string("开灯"), "group": .string("灯"),
                         "preset": .object(["on": .bool(true)])]),
                .object(["tool": .string("light.set"), "label": .string("关灯"), "group": .string("灯"),
                         "preset": .object(["on": .bool(false)])]),
                .object(["tool": .string("light.get"), "label": .string("读取灯状态"), "group": .string("灯"),
                         "preset": .object([:])]),
            ]),
        ]).encoded()
        let adopted = await model.adoptDescriptor(descriptor)
        XCTAssertEqual(adopted, .ok, "the descriptor was not adopted: \(model.errorText ?? "")")
        let controls = try XCTUnwrap(model.descriptor?.controls)
        XCTAssertEqual(controls.map(\.label), ["开灯", "关灯", "读取灯状态"])
        try await snapshot("03-descriptor")
        for (index, expected) in [(1, false), (0, true)] {
            await model.send(toolName: controls[index].tool, preset: controls[index].preset)
            await model.send(toolName: controls[2].tool, preset: controls[2].preset)
            guard case .completed(let text)? = model.lastResults["light.get"]?.state else {
                try await snapshot("fail-preset-\(expected)")
                return XCTFail("preset \(controls[index].label) did not read back: \(model.errorText ?? "")")
            }
            XCTAssertTrue(text.replacingOccurrences(of: " ", with: "").contains("\"on\":\(expected)"),
                          "\(controls[index].label) did not read back on=\(expected): \(text)")
            XCTAssertEqual(model.lastResults["light.get"]?.summary?.rows.first { $0.name == "on" }?.value,
                           expected ? "是" : "否")
            try await snapshot("04-preset-\(expected ? "on" : "off")")
        }
    }

    /// The Agent's leg, without a model: `ble_link_tools` on the real board says
    /// which Link device ID and workspace path to use; a descriptor written from
    /// that answer alone, at that path, is listed by the adoption sheet and
    /// evaluates to `ok` against the board's live tool table.
    func testAgentListingIsEnoughToAuthorAnAdoptableDescriptor() async throws {
        let board = try requireFixture()
        let store = BLEDeviceStore.shared
        let device = try await connectedBoard(named: board, store: store)

        let request = LoopbackRequest(method: "POST", path: "/mcp/native", headers: [:], body: try JSONValue.object([
            "jsonrpc": .string("2.0"), "id": .number(1), "method": .string("tools/call"),
            "params": .object(["name": .string("ble_link_tools"),
                               "arguments": .object(["device_id": .string(device.id.uuidString)])]),
        ]).encoded())
        let response = await DeviceMCPServer.shared.handle(request)
        let text = try XCTUnwrap(try JSONValue.parse(response.body)["result"]?["content"]?.arrayValue?.first?["text"]?.stringValue)
        let listing = try JSONValue.parse(Data(text.utf8))
        let linkDeviceID = try XCTUnwrap(listing["device_id"]?.stringValue)
        let panelPath = try XCTUnwrap(listing["panel_path"]?.stringValue)
        print("PDSH-PANEL listing device_id=\(linkDeviceID) panel_path=\(panelPath)")
        XCTAssertEqual(linkDeviceID, device.linkDeviceID)

        // What the tool description tells a model to write, using only the listing.
        let names = (listing["tools"]?.arrayValue ?? []).compactMap { $0["name"]?.stringValue }
        XCTAssertTrue(names.contains("light.set") && names.contains("light.get"), "\(names)")
        let descriptor = try JSONValue.object([
            "v": .number(1), "device_id": .string(linkDeviceID), "title": .string("TonoLink 灯"),
            "controls": .array([
                .object(["tool": .string("light.set"), "label": .string("开灯"), "group": .string("灯"),
                         "preset": .object(["on": .bool(true)])]),
                .object(["tool": .string("light.set"), "label": .string("关灯"), "group": .string("灯"),
                         "preset": .object(["on": .bool(false)])]),
                .object(["tool": .string("light.get"), "label": .string("读取灯状态"), "group": .string("灯"),
                         "preset": .object([:])]),
            ]),
        ]).encoded()

        let root = ChatModel.shared.workspaceRoot
            .appendingPathComponent("materialized", isDirectory: true)
            .appendingPathComponent("workspace", isDirectory: true)
        // Not `panelPath` itself: on a phone in use that file may be the one the
        // user's own Agent wrote, and this test must not replace or delete it.
        XCTAssertTrue(PhoneDSHProbe.DevicePanelDescriptorPreview.handles(panelPath))
        let testPath = "device-panels/pdsh-device-test.json"
        let file = root.appendingPathComponent(testPath)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try descriptor.write(to: file)
        addTeardownBlock { try? FileManager.default.removeItem(at: file) }

        let url = try XCTUnwrap(PhoneDSHProbe.DevicePanelAdoptionSheet.descriptorURL(for: testPath),
                                "the adoption sheet cannot resolve \(testPath)")
        let bytes = try XCTUnwrap(PhoneDSHProbe.DevicePanelAdoptionSheet.readCapped(url))
        let model = Model(source: Live(device: device, store: store))
        model.refresh()
        let review = model.reviewDescriptor(bytes)
        XCTAssertEqual(review.result, .ok, "a descriptor authored from the listing must be adoptable")

        // What tapping the file in the chat now opens.
        show(AnyView(PhoneDSHProbe.DevicePanelDescriptorPreview(path: testPath)))
        try await snapshot("05-descriptor-preview")
    }

    // MARK: - Board

    /// The board as a user gets it: a remembered board reconnects by itself;
    /// otherwise scan and connect the first match.
    private func connectedBoard(named board: String, store: BLEDeviceStore) async throws -> BLEDeviceStore.Device {
        var scanned = false, connecting = false
        for tick in 0..<180 {
            let matches = store.devices.filter { $0.name.contains(board) }
            if let ready = matches.first(where: { !$0.linkTools.isEmpty }) {
                if store.scanning { store.stopScan() }
                return ready
            }
            if tick % 10 == 0 {
                print("PDSH-PANEL waiting t=\(tick / 2)s devices=\(store.devices.map { "\($0.name)[\($0.state)|\($0.linkState)]" })")
            }
            if tick >= 10, matches.isEmpty, !scanned { store.scan(); scanned = true }
            if tick >= 10, !connecting, let candidate = matches.first, candidate.state == "未连接" {
                store.connect(candidate.id); connecting = true
            }
            try await Task.sleep(for: .milliseconds(500))
        }
        throw XCTSkip("no connected board named \(board) with PDSH Tools v1 within 90 s: \(store.devices.map { "\($0.name)[\($0.state)|\($0.linkState)]" })")
    }

    // MARK: - Screenshots of the real page

    private func show(_ page: AnyView) {
        // The board mirrors the phone over AirPlay, so there can be a second
        // scene; the panel belongs on the phone's own screen.
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let scene = scenes.first(where: { $0.screen == UIScreen.main && $0.activationState == .foregroundActive })
            ?? scenes.first(where: { $0.screen == UIScreen.main }) ?? scenes.first else { return }
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: NavigationStack { page })
        window.windowLevel = .alert + 1
        window.makeKeyAndVisible()
        self.window = window
    }

    private func snapshot(_ name: String) async throws {
        try await Task.sleep(for: .milliseconds(700))
        guard let window else { return }
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            _ = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
