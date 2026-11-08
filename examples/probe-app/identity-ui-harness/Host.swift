// SPDX-License-Identifier: MIT
import Foundation
import Observation
import SwiftUI
@testable import PhoneDSHBLE

@MainActor @Observable final class IdentityHarnessState {
    let id: UUID
    let label: String
    let suite: String
    let defaults: UserDefaults
    let adapter: BLEDeviceStore.TestAdapter
    let store: BLEDeviceStore
    let originalCommands: [BLEDeviceStore.TestCommand]
    var revision = 0

    init() {
        let id = UUID(uuidString: "12345678-1234-4234-8234-123456789abc")!
        let label = "ble:" + String(repeating: "a", count: 64)
        let suite = "IdentityUIHarness." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set(42, forKey: BLETrustedIdentities.key)
        let adapter = BLEDeviceStore.TestAdapter()
        adapter.identityDefaults = defaults
        let store = BLEDeviceStore(testAdapter: adapter, testDevices: [.init(id: id, name: "PDSH test", rssi: -40)])
        store.connect(id)
        store.testDidConnect(id)
        store.testDiscover(id, profiles: [.battery])
        store.testReplaceIdentityChannel(id)
        store.testInstallIdentityClient(id, reuse: false)
        store.testSetIdentityPending(id, label: label)
        self.id = id; self.label = label; self.suite = suite
        self.defaults = defaults; self.adapter = adapter; self.store = store
        self.originalCommands = adapter.commands
    }

    var audit: String {
        _ = revision
        guard let device = store.devices.first(where: { $0.id == id }) else { return "missing device" }
        let raw = defaults.object(forKey: BLETrustedIdentities.key)
        let stored: String
        if let values = raw as? [String] { stored = values == ["legacy:old", label] ? "recorded" : "valid" }
        else { stored = (raw as? Int) == 42 ? "invalid" : "unexpected" }
        return "pending=\(device.pendingIdentity == label);recorded=\(device.taskIdentity == label);tasks=\(device.allowDeviceTasks || device.supportsDeviceTasks);commandsUnchanged=\(adapter.commands == originalCommands);storage=\(stored)"
    }

    func repairFixture() {
        defaults.set(["legacy:old"], forKey: BLETrustedIdentities.key)
        revision += 1
    }
}

@main @MainActor struct IdentityUIHost: App {
    @State private var harness = IdentityHarnessState()
    var body: some Scene {
        WindowGroup {
            VStack {
                Button("修复测试存储") { harness.repairFixture() }
                    .accessibilityIdentifier("identity-harness-repair")
                Text(harness.audit).font(.caption)
                    .accessibilityIdentifier("identity-harness-audit")
                BluetoothDevicesPage(store: harness.store)
            }
        }
    }
}
