// SPDX-License-Identifier: MIT
// Physical-device checks for the board's LED effects (tonolink-board.md §4.3): a USB OTA of the
// image bundled into this test build, the Link tools the mini program uses (light.phase,
// light.effect.set/get), the voice turn's `<seq> fx <phase>` ctrl line, and the device panel
// with an effects descriptor. Hosted in the app, so everything goes through the app's real
// BLE store, Link caller and USB flow.
import SwiftUI
import UIKit
import XCTest
import PhoneDSHAgentCore
@testable import PhoneDSHBLE
@testable import PhoneDSHProbe

@MainActor
final class TonoLinkLightDeviceTests: XCTestCase {
    private var window: UIWindow?

    override func tearDown() async throws {
        window?.isHidden = true
        window = nil
    }

    private func flag(_ name: String) -> Bool {
        let environment = ProcessInfo.processInfo.environment
        return (environment["TEST_RUNNER_" + name] ?? environment[name]) == "1"
    }

    private func note(_ line: String) { print("PDSH-LIGHT \(line)") }

    // MARK: - OTA

    /// Flashes `agent_s3.bin` from this test bundle over USB (the app's own OTA flow). The image is
    /// copied in by the developer for one run; without it, or without the flag, nothing happens.
    func testUSBOTAOfTheBundledImage() async throws {
        try XCTSkipUnless(flag("PDSH_TONOLINK_OTA_TEST"), "pass TEST_RUNNER_PDSH_TONOLINK_OTA_TEST=1 to flash the board")
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "agent_s3", withExtension: "bin"),
                                "no agent_s3.bin in the test bundle")
        let image = try TonoLinkFirmwareImage(data: try Data(contentsOf: url))
        note("image \(image.version) \(image.data.count) B elf=\(image.elfSHA256.prefix(16))")
        let flow = TonoLinkUSBOTA(ctrl: TonoLinkCtrlBLE(nameHint: "PhoneAgent"), network: TonoLinkUSBSocketNetwork(),
                                  http: TonoLinkURLSessionHTTP())
        flow.onEvent = { [weak self] event in
            if case .step(let text) = event { self?.note("ota: \(text)") }
        }
        let outcome = try await flow.run(image: image)
        note("ota outcome: \(outcome)")
        switch outcome {
        case .confirmed(let state), .alreadyRunning(let state):
            XCTAssertEqual(state.elfSHA256, image.elfSHA256)
        }
    }

    // MARK: - Link tools and the ctrl line

    func testEffectsOverLinkToolsAndTheCtrlLine() async throws {
        try XCTSkipUnless(flag("PDSH_TONOLINK_LIGHT_TEST"), "pass TEST_RUNNER_PDSH_TONOLINK_LIGHT_TEST=1 with a board nearby")
        let store = BLEDeviceStore.shared
        let device = try await connectedBoard(store: store)
        note("tools=\(device.linkTools) granted=\(device.grantedTools.sorted())")
        for tool in ["light.phase", "light.effect.set", "light.effect.get"] {
            XCTAssertTrue(device.linkTools.contains(tool), "the board does not advertise \(tool)")
        }

        func call(_ name: String, _ args: [String: JSONValue]) async throws -> JSONValue {
            let outcome = try await callLinkTool(deviceID: device.id, name: name, arguments: .object(args),
                                                 idempotencyKey: UUID().uuidString.lowercased(), origin: .user)
            guard case .completed(_, let reply) = outcome else { throw XCTSkip("\(name) did not complete: \(outcome)") }
            XCTAssertEqual(reply["status"]?.stringValue, "completed", "\(name): \(reply)")
            return reply["result"] ?? .null
        }

        let before = try await call("light.effect.get", [:])
        note("styles before: \(String(decoding: (try? before.encoded()) ?? Data(), as: UTF8.self))")
        let originalWake = try XCTUnwrap(before["styles"]?["wake"])

        for phase in ["wake", "task_start", "task_running", "task_report", "task_done", "idle"] {
            let result = try await call("light.phase", ["phase": .string(phase)])
            // task_start moves on to task_running by itself after 1.6 s; right after the call it shows itself.
            XCTAssertEqual(result["phase"]?.stringValue, phase, "light.phase \(phase)")
            note("phase \(phase) -> \(result["phase"]?.stringValue ?? "?")")
            try await Task.sleep(for: .milliseconds(phase == "idle" ? 200 : 1800))
        }

        // Change one phase, read it back, put it back.
        let set = try await call("light.effect.set", ["phase": .string("wake"), "effect": .string("scanner"),
                                                      "hue": .number(330), "brightness": .number(80), "speed": .number(9)])
        XCTAssertEqual(set["styles"]?["wake"]?["effect"]?.stringValue, "scanner")
        XCTAssertEqual(set["styles"]?["wake"]?["hue"], .number(330))
        let after = try await call("light.effect.get", [:])
        XCTAssertEqual(after["styles"]?["wake"]?["effect"]?.stringValue, "scanner", "the change was not saved")
        var restore: [String: JSONValue] = ["phase": .string("wake")]
        for key in ["effect", "hue", "brightness", "speed"] { restore[key] = originalWake[key] ?? .null }
        _ = try await call("light.effect.set", restore)
        _ = try await call("light.phase", ["phase": .string("idle")])

        // The voice turn's line: a second ctrl link, like the OTA page's.
        let ctrl = TonoLinkCtrlBLE(nameHint: "PhoneAgent")
        try await ctrl.connect(timeout: .seconds(20))
        defer { ctrl.disconnect() }
        let ok = try await ctrl.command(try TonoLinkVoiceCommand.fx(seq: 31_001, phase: .taskStart), seq: 31_001,
                                        timeout: .seconds(3))
        note("fx task_start ack ok=\(ok.ok) err=\(ok.error ?? "-")")
        XCTAssertTrue(ok.ok)
        try await Task.sleep(for: .seconds(2))
        let unknown = try await ctrl.command(try TonoLinkBLECommand.line("31002 fx disco"), seq: 31_002, timeout: .seconds(3))
        note("fx disco ack ok=\(unknown.ok) err=\(unknown.error ?? "-")")
        XCTAssertFalse(unknown.ok, "an unknown phase must be refused")
        _ = try? await ctrl.command(try TonoLinkVoiceCommand.fx(seq: 31_003, phase: .idle), seq: 31_003, timeout: .seconds(3))
    }

    // MARK: - Mini program

    /// Adopts a descriptor for the effects (one-tap previews per phase, the style editor, the read-out)
    /// through the real evaluator and store, and screenshots the panel.
    func testEffectsPanel() async throws {
        try XCTSkipUnless(flag("PDSH_TONOLINK_LIGHT_TEST"), "pass TEST_RUNNER_PDSH_TONOLINK_LIGHT_TEST=1 with a board nearby")
        let store = BLEDeviceStore.shared
        let device = try await connectedBoard(store: store)
        func preset(_ label: String, _ phase: String, group: String) -> JSONValue {
            .object(["tool": .string("light.phase"), "label": .string(label), "group": .string(group),
                     "preset": .object(["phase": .string(phase)])])
        }
        let descriptor = try JSONValue.object([
            "v": .number(1), "device_id": .string(device.linkDeviceID), "title": .string("TonoLink 灯效"),
            "controls": .array([
                preset("唤醒", "wake", group: "预览灯效"),
                preset("开始任务", "task_start", group: "预览灯效"),
                preset("任务进行", "task_running", group: "预览灯效"),
                preset("任务汇报", "task_report", group: "预览灯效"),
                preset("任务结束", "task_done", group: "预览灯效"),
                preset("关闭灯效", "idle", group: "预览灯效"),
                .object(["tool": .string("light.effect.set"), "label": .string("设置一个阶段的灯效"), "group": .string("设置")]),
                .object(["tool": .string("light.effect.get"), "label": .string("查看全部灯效"), "group": .string("设置"),
                         "preset": .object([:])]),
                .object(["tool": .string("light.set"), "label": .string("常亮白光"), "group": .string("照明"),
                         "preset": .object(["on": .bool(true)])]),
                .object(["tool": .string("light.set"), "label": .string("关灯"), "group": .string("照明"),
                         "preset": .object(["on": .bool(false)])]),
            ]),
        ]).encoded()
        let model = DevicePanelModel(source: LiveDevicePanelSource(device: device, store: store),
                                     results: .shared(for: device.id))
        model.refresh()
        let adopted = await model.adoptDescriptor(descriptor)
        XCTAssertEqual(adopted, .ok, "descriptor not adopted: \(model.errorText ?? "")")
        show(AnyView(DevicePanelPage(model: model, deviceName: device.name)))
        try await snapshot("panel")
        let running = try XCTUnwrap(model.descriptor?.controls.first { $0.label == "任务进行" })
        await model.send(toolName: running.tool, preset: running.preset)
        note("preview task_running: \(String(describing: model.lastResults["light.phase"]?.state))")
        guard case .completed? = model.lastResults["light.phase"]?.state else {
            return XCTFail("the preview did not complete: \(model.errorText ?? "")")
        }
        try await snapshot("panel-after-preview")
        let idle = try XCTUnwrap(model.descriptor?.controls.first { $0.label == "关闭灯效" })
        try await Task.sleep(for: .seconds(3))
        await model.send(toolName: idle.tool, preset: idle.preset)
    }

    // MARK: - Helpers

    private func connectedBoard(store: BLEDeviceStore) async throws -> BLEDeviceStore.Device {
        var scanned = false, connecting = false
        for tick in 0..<180 {
            let matches = store.devices.filter { $0.name.contains("PhoneAgent") }
            if let ready = matches.first(where: { !$0.linkTools.isEmpty }) {
                if store.scanning { store.stopScan() }
                return ready
            }
            if tick >= 10, matches.isEmpty, !scanned { store.scan(); scanned = true }
            if tick >= 10, !connecting, let candidate = matches.first, candidate.state == "未连接" {
                store.connect(candidate.id); connecting = true
            }
            try await Task.sleep(for: .milliseconds(500))
        }
        throw XCTSkip("no connected board with PDSH Tools v1 within 90 s")
    }

    private func show(_ page: AnyView) {
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
