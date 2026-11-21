// SPDX-License-Identifier: MIT
// Debug-only host for the real BluetoothDevicesPage over the production
// BLEDeviceStore test adapter. It exists only for the `-uiPreview ble.devices`
// UI acceptance pass: no CoreBluetooth central, no real peripheral and no
// shared app settings. Release builds contain none of this file's views.
#if DEBUG
import Foundation
import Observation
import SwiftUI
@testable import PhoneDSHBLE

/// One isolated page/store pair for a scripted BLE lifecycle. The store still
/// runs the real grant, disconnect and quarantine state machine; only the
/// physical radio callbacks come from `BLEDeviceStore.TestAdapter`.
@MainActor @Observable
final class BLEDevicesPreviewHarnessModel {
    enum Scenario: String {
        case connected
        case closing
        case quarantined
    }

    static let deviceID = UUID(uuidString: "0F0E0D0C-0B0A-4908-8706-050403020100")!
    static let trustSuite = "dev.phone-dsh.probe.ble-preview.trust"

    let scenario: Scenario
    let adapter: BLEDeviceStore.TestAdapter
    let store: BLEDeviceStore
    private(set) var callbackDelivered = false
    private(set) var callbackPhase = ""
    private(set) var reconnectDeniedBeforeBoundary = false
    /// Bumped after scripted transitions so the audit row re-renders; the
    /// store's own properties drive the page itself.
    private var revision = 0

    init(scenario: Scenario) {
        self.scenario = scenario
        let defaults = UserDefaults(suiteName: Self.trustSuite)!
        defaults.removePersistentDomain(forName: Self.trustSuite)
        let adapter = BLEDeviceStore.TestAdapter()
        let store = BLEDeviceStore(
            testAdapter: adapter,
            testDevices: [.init(id: Self.deviceID, name: "PDSH UI test peripheral", rssi: -40)])
        // Keep the disconnect path's remembered-board bookkeeping in a private
        // suite: this harness must not read or write the user's real boards.
        store.trustMemory = BLEDeviceTrustMemory(defaults: defaults)
        self.adapter = adapter
        self.store = store
        store.connect(Self.deviceID)
        store.testDidConnect(Self.deviceID)
        store.testDiscover(Self.deviceID, profiles: [.battery, .alert])
        if scenario == .quarantined {
            store.grant(Self.deviceID, read: true, alert: true)
        }
    }

    var audit: String {
        _ = revision
        let device = store.devices.first(where: { $0.id == Self.deviceID })
        return "phase=\(store.testPhase(Self.deviceID))"
            + ";read=\(device?.allowRead == true)"
            + ";alert=\(device?.allowAlert == true)"
            + ";callback=\(callbackDelivered)"
            + ";insideDenied=\(reconnectDeniedBeforeBoundary)"
            + ";callbackPhase=\(callbackPhase)"
    }

    /// Delivers the system disconnect callback the real page is waiting for.
    /// The production callback boundary is still synchronous: reconnecting
    /// from inside it must be rejected until the boundary task retires it.
    func deliverDisconnectCallback() {
        guard !callbackDelivered else { return }
        let before = adapter.commands
        var phase = ""
        var denied = false
        store.testDidDisconnect(Self.deviceID, during: {
            self.store.connect(Self.deviceID)
            phase = self.store.testPhase(Self.deviceID)
            denied = phase == "closing" && self.adapter.commands == before
        })
        callbackPhase = phase
        reconnectDeniedBeforeBoundary = denied
        callbackDelivered = true
        revision += 1
    }

    func simulateRadioUnavailable() {
        store.testRadioUnavailable(reset: true)
        revision += 1
    }

    /// Re-renders the display-only audit row after the store changes state.
    func refreshAudit() {
        revision += 1
    }

    /// The simulated peripheral accepts the user's real reconnect tap.
    func completeSimulatedConnectionIfNeeded() {
        guard store.devices.first(where: { $0.id == Self.deviceID })?.state == "连接中" else { return }
        store.testDidConnect(Self.deviceID)
        store.testDiscover(Self.deviceID, profiles: [.battery, .alert])
        revision += 1
    }
}

struct BLEDevicesPreviewHarness: View {
    @State private var model: BLEDevicesPreviewHarnessModel

    init(scenario: BLEDevicesPreviewHarnessModel.Scenario) {
        _model = State(initialValue: BLEDevicesPreviewHarnessModel(scenario: scenario))
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 2) {
                switch model.scenario {
                case .connected:
                    EmptyView()
                case .closing:
                    Button("模拟系统断开回调") { model.deliverDisconnectCallback() }
                        .accessibilityIdentifier("ble-preview-disconnect-callback")
                case .quarantined:
                    Button("模拟蓝牙不可用") { model.simulateRadioUnavailable() }
                        .accessibilityIdentifier("ble-preview-radio-unavailable")
                }
                Text(model.audit)
                    .font(.caption2).lineLimit(1)
                    .accessibilityIdentifier("ble-preview-audit")
            }
            .padding(6)
            BluetoothDevicesPage(store: model.store)
        }
        .onChange(of: model.store.devices.map {
            "\($0.state)|\($0.allowRead)|\($0.allowAlert)"
        }) { _, _ in
            model.refreshAudit()
        }
        .task {
            // Walk the page's real connect -> connected -> discover transition
            // without a CoreBluetooth peripheral. Only this preview host runs
            // the loop; the page and store are the production implementations.
            while !Task.isCancelled {
                model.completeSimulatedConnectionIfNeeded()
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
    }
}
#endif
