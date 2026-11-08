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
    var reconnectDeniedInsideCallback = false
    let discoveryMode: Bool
    var discoveryPeer: AnyObject?
    var discoveryServices: [BLEDeviceStore.TestService] = []
    var discoveryBattery: BLEDeviceStore.TestService?
    var discoveryBatteryValue: BLEDeviceStore.TestCharacteristic?
    var discoveryDeadline: BLEDeviceStore.TestTimerProbe?
    var duplicateChecks = 0
    var duplicateDeviceNotifications = 0
    var duplicateStatusNotifications = 0
    var duplicateUnchanged = true
    @ObservationIgnored private var measuringDuplicate = false

    init() {
        let id = UUID(uuidString: "12345678-1234-4234-8234-123456789abc")!
        let label = "ble:" + String(repeating: "a", count: 64)
        let suite = "IdentityUIHarness." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set(42, forKey: BLETrustedIdentities.key)
        let adapter = BLEDeviceStore.TestAdapter()
        adapter.identityDefaults = defaults
        let store = BLEDeviceStore(testAdapter: adapter, testDevices: [.init(id: id, name: "PDSH test", rssi: -40)])
        let discoveryMode = ProcessInfo.processInfo.arguments.contains("--discovery-ambiguity")
        store.connect(id)
        let deadline = store.testCaptureConnectionTimeout(id)
        store.testDidConnect(id)
        var physical: AnyObject?
        var discoveredServices: [BLEDeviceStore.TestService] = []
        var battery: BLEDeviceStore.TestService?
        var batteryValue: BLEDeviceStore.TestCharacteristic?
        if discoveryMode {
            let peer = store.testPhysicalPeer(id)!
            let first = BLEDeviceStore.TestService(parent: peer, uuid: PDSHLink.service)
            let second = BLEDeviceStore.TestService(parent: peer, uuid: PDSHLink.service)
            let standard = BLEDeviceStore.TestService(parent: peer, uuid: "180F")
            let value = BLEDeviceStore.TestCharacteristic(parent: standard, uuid: "2A19", properties: [.read])
            let services = [first, standard, second]
            store.testDiscoveryServices(id, peer: peer, services: services)
            store.testDiscoveryCharacteristics(id, peer: peer, service: standard, characteristics: [value])
            physical = peer; discoveredServices = services; battery = standard; batteryValue = value
        } else {
            store.testDiscover(id, profiles: [.battery, .alert])
            store.grant(id, read: true, alert: true)
            store.testReplaceIdentityChannel(id)
            store.testInstallIdentityClient(id, reuse: false)
            store.testSetIdentityPending(id, label: label)
        }
        self.id = id; self.label = label; self.suite = suite
        self.defaults = defaults; self.adapter = adapter; self.store = store
        self.originalCommands = adapter.commands
        self.discoveryMode = discoveryMode
        self.discoveryPeer = physical; self.discoveryServices = discoveredServices
        self.discoveryBattery = battery; self.discoveryBatteryValue = batteryValue
        self.discoveryDeadline = deadline
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

    var serviceAudit: String {
        _ = revision
        guard let device = store.devices.first(where: { $0.id == id }) else { return "missing device" }
        let connections = adapter.commands.filter { if case .connect(let peer) = $0 { return peer == id }; return false }.count
        let cancellations = adapter.commands.filter { if case .disconnect(let peer) = $0 { return peer == id }; return false }.count
        return "phase=\(store.testPhase(id));read=\(device.allowRead);alert=\(device.allowAlert);tasks=\(device.allowDeviceTasks || device.supportsDeviceTasks);connects=\(connections);disconnects=\(cancellations);insideDenied=\(reconnectDeniedInsideCallback)"
    }

    var discoveryAudit: String {
        _ = revision
        guard let device = store.devices.first(where: { $0.id == id }) else { return "missing device" }
        let requests = adapter.discoverySubmissions.filter { $0.id == id && $0.service != nil }.count
        let batteryAvailable = store.testDiscoveryProfileEndpoint(id, profile: .battery) === discoveryBatteryValue
        let channel = store.testIdentityChannel(id) != nil || store.testIdentityClient(id) != nil
        let rawEmpty = store.testDiscoveryRawLinkStorageEmpty(id)
        let readAdmitted = (try? store.testReadAdmission(id, profile: .battery)) != nil
        let linkAdmitted = (try? store.authorizeLink(id, name: "light.get", arguments: nil)) != nil
        return "phase=\(store.testPhase(id));battery=\(batteryAvailable);read=\(device.allowRead);readAdmitted=\(readAdmitted);alert=\(device.allowAlert);tasks=\(device.allowDeviceTasks || device.supportsDeviceTasks);tool=\(linkAdmitted);channel=\(channel);rawEmpty=\(rawEmpty);requests=\(requests);notifies=\(adapter.notifyEndpoints.count);duplicates=\(duplicateChecks);deviceNotifications=\(duplicateDeviceNotifications);statusNotifications=\(duplicateStatusNotifications);unchanged=\(duplicateUnchanged);deadline=\(discoveryDeadline?.state ?? "missing")"
    }

    func repeatDiscoveryCallbacks() {
        guard let peer = discoveryPeer, let battery = discoveryBattery, let value = discoveryBatteryValue else { return }
        let beforeCommands = adapter.commands
        let beforeRequests = adapter.discoverySubmissions.count
        let beforeNotifications = adapter.notifyEndpoints
        let beforeStatus = store.status
        let beforePhase = store.testPhase(id)
        let beforeDeadline = discoveryDeadline?.state
        let beforeEndpoint = store.testDiscoveryProfileEndpoint(id, profile: .battery)
        let beforeChannel = store.testIdentityChannel(id)
        let beforeRawEmpty = store.testDiscoveryRawLinkStorageEmpty(id)
        measuringDuplicate = true
        withObservationTracking { _ = store.devices } onChange: {
            MainActor.assumeIsolated { if self.measuringDuplicate { self.duplicateDeviceNotifications += 1 } }
        }
        withObservationTracking { _ = store.status } onChange: {
            MainActor.assumeIsolated { if self.measuringDuplicate { self.duplicateStatusNotifications += 1 } }
        }
        store.testDiscoveryServices(id, peer: peer, services: discoveryServices)
        store.testDiscoveryCharacteristics(id, peer: peer, service: battery, characteristics: [value])
        measuringDuplicate = false
        duplicateChecks += 1
        duplicateUnchanged = duplicateUnchanged && adapter.commands == beforeCommands &&
            adapter.discoverySubmissions.count == beforeRequests && adapter.notifyEndpoints == beforeNotifications &&
            store.status == beforeStatus && store.testPhase(id) == beforePhase && discoveryDeadline?.state == beforeDeadline &&
            store.testDiscoveryProfileEndpoint(id, profile: .battery) === beforeEndpoint &&
            store.testIdentityChannel(id) == beforeChannel && store.testDiscoveryRawLinkStorageEmpty(id) == beforeRawEmpty
        revision += 1
    }

    func simulateServiceChange() {
        store.testServicesModified(id, invalidated: [])
        revision += 1
    }

    func simulateDisconnectCallback() {
        store.testDidDisconnect(id, during: {
            let before = self.adapter.commands
            self.store.connect(self.id)
            self.reconnectDeniedInsideCallback = self.store.testPhase(self.id) == "closing" && self.adapter.commands == before
        })
        revision += 1
    }
}

@main @MainActor struct IdentityUIHost: App {
    @State private var harness = IdentityHarnessState()
    var body: some Scene {
        WindowGroup {
            VStack(spacing: 2) {
                HStack {
                    if harness.discoveryMode {
                        Button("模拟重复发现") { harness.repeatDiscoveryCallbacks() }
                            .accessibilityIdentifier("identity-harness-repeat-discovery")
                    }
                    Button("修复测试存储") { harness.repairFixture() }
                        .accessibilityIdentifier("identity-harness-repair")
                    Button("模拟服务变化") { harness.simulateServiceChange() }
                        .accessibilityIdentifier("identity-harness-service-change")
                    Button("模拟系统断开") { harness.simulateDisconnectCallback() }
                        .accessibilityIdentifier("identity-harness-disconnect-callback")
                }
                .font(.caption)
                Text(harness.audit).font(.caption2).lineLimit(1)
                    .accessibilityLabel(harness.audit)
                    .accessibilityIdentifier("identity-harness-audit")
                Text(harness.serviceAudit).font(.caption2).lineLimit(1)
                    .accessibilityLabel(harness.serviceAudit)
                    .accessibilityIdentifier("identity-harness-service-audit")
                if harness.discoveryMode {
                    Text(harness.discoveryAudit).font(.caption2).lineLimit(1)
                        .accessibilityLabel(harness.discoveryAudit)
                        .accessibilityIdentifier("identity-harness-discovery-audit")
                }
                BluetoothDevicesPage(store: harness.store)
            }
        }
    }
}
