// SPDX-License-Identifier: MIT
// Physical-device measurements for unlocking the phone through the TonoLink board. The phone is
// locked through AssistiveTouch (设备 → 锁定屏幕); what still works while it is locked is then
// recorded: iOS protected-data availability, the board's BLE ctrl line, its USB HTTP, the AirPlay mirror and
// the picture. No passcode is typed by these tests: unlocking with the real passcode is the
// owner's to do. They leave the phone locked.
import AVFoundation
import UIKit
import ProbeKit
import XCTest
@testable import PhoneDSHBLE
@testable import PhoneDSHProbe
import PhoneDSHVenus

@MainActor
final class TonoLinkLockDeviceTests: XCTestCase {
    private func note(_ line: String) { print("PDSH-LOCK \(line)") }

    private func requireFixture() throws {
        let environment = ProcessInfo.processInfo.environment
        guard (environment["TEST_RUNNER_PDSH_TONOLINK_LOCK_TEST"] ?? environment["PDSH_TONOLINK_LOCK_TEST"]) == "1" else {
            throw XCTSkip("pass TEST_RUNNER_PDSH_TONOLINK_LOCK_TEST=1: this locks the phone")
        }
    }

    private func attach(_ jpeg: Data, _ name: String) {
        guard let image = UIImage(data: jpeg) else { return }
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// One line of state: iOS protected-data availability, USB HTTP, the board's mirror flag, the newest frame.
    private func sample(_ host: IPhoneAgentHost, _ label: String) async {
        let protectedDataAvailable = UIApplication.shared.isProtectedDataAvailable
        let status = try? await host.hands.call("GET", "/v1/phone/status", timeout: 3)
        let mirror = await host.hands.mirrorActive()
        note("\(label): protected_data=\(protectedDataAvailable) usb=\(status == nil ? "down" : "up") mirror=\(mirror) frames=\(host.screen.frameCount)")
    }

    private func shot(_ host: IPhoneAgentHost, _ name: String) async {
        if let frame = try? await host.screen.snapshot(newerThan: host.screen.frameCount, fresh: 1, timeout: .seconds(3)) {
            attach(frame.jpeg, name)
            note("\(name): picture \(frame.width)x\(frame.height)")
        } else {
            note("\(name): no new picture")
        }
    }

    private var seq: UInt16 = 4000
    private func ble(_ link: TonoLinkCtrlBLE, _ text: String) async -> String {
        seq += 1
        do {
            let ack = try await link.command(Data("\(seq) \(text)".utf8), seq: seq, timeout: .seconds(4))
            return ack.ok ? "ok" : "err \(ack.error ?? "?")"
        } catch { return "failed \(error)" }
    }

    /// Locks the phone through AssistiveTouch: 设备 → 锁定屏幕.
    private func lockPhone(_ host: IPhoneAgentHost) async throws {
        // Every point is read off the picture, which lags the phone by seconds: wait before each read.
        let foundButton = try await host.locate("the round grey AssistiveTouch floating button near the right edge", waitForChange: false)
        let button = try XCTUnwrap(foundButton, "AssistiveTouch button not found")
        note("button at \(button) (saved layout \(host.hands.layout.assistiveButton))")
        let calm = try await host.screen.snapshot(newerThan: nil, fresh: 1, timeout: .seconds(3))
        var opened = false
        for attempt in 1...3 where !opened {
            try await host.hands.hover(button)
            try await Task.sleep(for: .milliseconds(600))
            try await host.hands.tap(button)
            try await Task.sleep(for: .seconds(4))
            let now = try await host.screen.snapshot(newerThan: nil, fresh: 1, timeout: .seconds(3))
            let difference = IPhoneScreenDiff.mean(calm.jpeg, now.jpeg) ?? 0
            opened = difference >= IPhoneAgentHost.menuOpened
            note("menu attempt \(attempt): difference \(Int(difference)) opened=\(opened)")
            if opened { attach(now.jpeg, "1-menu") }
        }
        try XCTSkipUnless(opened, "the AssistiveTouch menu did not open")
        let foundDevice = try await host.locate("the 设备 (Device) icon in the AssistiveTouch menu", waitForChange: false)
        let device = try XCTUnwrap(foundDevice, "设备 not found in the AssistiveTouch menu")
        note("设备 at \(device)")
        try await host.hands.tap(device)
        try await Task.sleep(for: .seconds(5))
        await shot(host, "2-device-menu")
        let foundLock = try await host.locate("the 锁定屏幕 (Lock Screen) icon in the AssistiveTouch menu", waitForChange: false)
        note("锁定屏幕 at \(String(describing: foundLock))")
        let lock = try XCTUnwrap(foundLock, "锁定屏幕 not found in the AssistiveTouch Device menu")
        try await host.hands.tap(lock)
        note("lock tapped")
    }

    func testWhatWorksWhileLocked() async throws {
        try requireFixture()
        let host = IPhoneAgentHost.shared
        host.screen.start()
        // The product's task start: finds a dragged AssistiveTouch button and re-learns the menu.
        try await host.prepare()
        try await Task.sleep(for: .seconds(2))
        try await host.prepare()
        note("layout button=\(host.hands.layout.assistiveButton) home=\(host.hands.layout.assistiveHome) cc=\(host.hands.layout.assistiveControlCenter)")
        await sample(host, "before")
        await shot(host, "0-before")

        // Lock through AssistiveTouch: 设备 → 锁定屏幕. The mirrored picture lags the phone by
        // seconds, so the menu is tapped blind from the learned layout (设备 sits right above
        // 控制中心, measured on this phone) and only the submenu is read off the picture, late.
        try await lockPhone(host)

        for second in stride(from: 2, through: 20, by: 3) {
            try await Task.sleep(for: .seconds(3))
            await sample(host, "locked +\(second)s")
        }
        await shot(host, "3-locked")

        // Wake the screen with the board's keyboard over BLE (the USB path may be gone).
        let link = TonoLinkCtrlBLE(nameHint: "PhoneAgent")
        try await link.connect(timeout: .seconds(10))
        let mode = await ble(link, "hid_mode 1"); note("ble hid_mode 1: \(mode)")
        try await Task.sleep(for: .seconds(2))
        let space = await ble(link, "key space"); note("ble key space: \(space)")
        try await Task.sleep(for: .milliseconds(1500))
        await sample(host, "after space")
        await shot(host, "4-after-space")
        let space2 = await ble(link, "key space"); note("ble key space: \(space2)")
        try await Task.sleep(for: .milliseconds(1500))
        await shot(host, "5-after-second-space")
        await sample(host, "end")
    }

    func testProtectedDataUnavailableStopsAgentPreflight() async throws {
        try requireFixture()
        let host = IPhoneAgentHost.shared
        host.screen.start()
        try await host.prepare()
        try await lockPhone(host)
        for _ in 0..<20 where UIApplication.shared.isProtectedDataAvailable { try await Task.sleep(for: .seconds(1)) }
        try XCTSkipIf(UIApplication.shared.isProtectedDataAvailable, "iOS still reports protected data available")
        do {
            try await host.prepare()
            XCTFail("prepare() went on with protected data unavailable")
        } catch {
            note("prepare refused: \(error)")
            XCTAssertTrue("\(error)".contains("请先解锁手机"), "\(error)")
        }
    }

    /// Reads the signals a locked phone gives the app while it is locked and in the background:
    /// protected-data availability, the audio route, and whether the
    /// speaker can be taken. Types nothing; leaves the phone locked.
    func testLockSignals() async throws {
        try requireFixture()
        let host = IPhoneAgentHost.shared
        host.screen.start()
        try await host.prepare()
        func outputs() -> String { AVAudioSession.sharedInstance().currentRoute.outputs.map(\.portType.rawValue).joined(separator: ",") }
        note("before protected=\(UIApplication.shared.isProtectedDataAvailable) app=\(UIApplication.shared.applicationState.rawValue) out=\(outputs())")
        try await lockPhone(host)
        for second in stride(from: 3, through: 30, by: 3) {
            try await Task.sleep(for: .seconds(3))
            note("+\(second)s protected=\(UIApplication.shared.isProtectedDataAvailable) app=\(UIApplication.shared.applicationState.rawValue) out=\(outputs())")
        }
        do {
            let speaker = try PhoneAudioSessionLease.acquireSpeakerOutput()
            note("speaker while locked: ok out=\(outputs())")
            PhoneAudioSessionLease.releaseSpeakerOutput(speaker)
        } catch {
            note("speaker while locked: \(error) out=\(outputs())")
        }
    }
}
