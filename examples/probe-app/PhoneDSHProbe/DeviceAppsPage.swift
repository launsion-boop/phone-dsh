// SPDX-License-Identifier: MIT
// 「设备应用」 page (spec/device/v1/device-panel.md §9, device-app.md §13, device-app-v1.6): for a device
// whose Link tools contain all eight `app.*` names, the customer sees which apps are on the device and can
// open, stop or delete them. Each button is the user's own tap (user-origin Link call, no Bot, no grant).
// The logic lives in `DeviceAppsPageModel` (PhoneDSHBot); this file is rendering plus the Link adapter.
// Other devices keep the generic `DevicePanelPage`; a collapsed 「高级」 entry reaches it from here.
import Foundation
import PhoneDSHAgentCore
import PhoneDSHBLE
import PhoneDSHBot
import SwiftUI

/// The user-origin Link calls behind the page.
enum DeviceAppsLinkFactory {
    static func make(deviceID: UUID, store: BLEDeviceStore) -> DeviceAppsLink {
        func call(_ name: String, _ arguments: JSONValue) async -> (code: String?, result: JSONValue?) {
            do {
                let outcome = try await callLinkTool(
                    deviceID: deviceID, name: name, arguments: arguments,
                    idempotencyKey: "devapp.page.\(name).\(UUID().uuidString.lowercased())", origin: .user)
                switch outcome {
                case .completed(_, let reply):
                    guard reply["status"]?.stringValue == "completed", let result = reply["result"] else {
                        return (reply["status"]?.stringValue == "outcome_unknown" ? "outcome_unknown" : "call_failed", nil)
                    }
                    if result["ok"]?.boolValue == true { return (nil, result) }
                    return (result["code"]?.stringValue ?? "call_failed", nil)
                case .outcomeUnknown, .running: return ("outcome_unknown", nil)
                case .notExecuted: return ("not_executed", nil)
                }
            } catch is LinkBusy {
                return ("link_busy", nil)
            } catch {
                return ("call_failed", nil)
            }
        }
        return DeviceAppsLink(
            connected: { await MainActor.run { store.devices.first { $0.id == deviceID }?.state == "已连接" } },
            info: {
                let r = await call("app.info", .object([:]))
                if let result = r.result { return .reply(result) }
                return .failed(code: r.code ?? "call_failed")
            },
            run: { name in await call("app.run", .object(["name": .string(name)])).code },
            stop: { await call("app.stop", .object([:])).code },
            remove: { name in await call("app.remove", .object(["name": .string(name)])).code })
    }
}

/// The page itself.
struct DeviceAppsPage: View {
    @StateObject private var model: DeviceAppsPageModel
    private let device: BLEDeviceStore.Device
    private let store: BLEDeviceStore

    init(device: BLEDeviceStore.Device, store: BLEDeviceStore) {
        self.device = device
        self.store = store
        _model = StateObject(wrappedValue: DeviceAppsPageModel(link: DeviceAppsLinkFactory.make(deviceID: device.id, store: store)))
    }

    var body: some View {
        List {
            if let banner = model.banner {
                Section {
                    Text(banner.text)
                        .font(.subheadline)
                        .foregroundStyle(banner.isError ? Color.red : Color.green)
                        .accessibilityIdentifier("device-apps-banner")
                }
            }
            switch model.phase {
            case .loading:
                Section { ProgressView("正在读取设备上的应用…") }
            case .notConnected:
                Section { Text(DeviceAppCustomerText.pageNotConnected).foregroundStyle(.secondary) }
                    .accessibilityIdentifier("device-apps-not-connected")
            case .failed(let text):
                Section { Text(text).foregroundStyle(.secondary) }
            case .ready:
                if let free = model.freeSpace {
                    Section { Text(free).font(.footnote).foregroundStyle(.secondary) }
                }
                if model.rows.isEmpty {
                    Section { Text(DeviceAppCustomerText.emptyDevice).foregroundStyle(.secondary) }
                        .accessibilityIdentifier("device-apps-empty")
                } else {
                    Section {
                        ForEach(model.rows) { row in rowView(row) }
                    } header: { Text("设备上的应用") }
                }
            }
            Section {
                DisclosureGroup("高级") {
                    NavigationLink {
                        DevicePanelPage(device: device, store: store)
                    } label: {
                        Text("设备的原始面板")
                    }
                    .accessibilityIdentifier("device-apps-advanced-panel")
                }
            }
        }
        .navigationTitle("设备应用")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await model.refresh() }
        .task { await model.refresh() }
        .alert("删除「\(model.pendingDelete?.title ?? "")」？", isPresented: Binding(
            get: { model.pendingDelete != nil }, set: { if !$0 { model.cancelDelete() } })) {
            Button("删除", role: .destructive) { Task { await model.confirmDelete() } }
            Button("取消", role: .cancel) { model.cancelDelete() }
        } message: {
            Text(DeviceAppCustomerText.deleteConfirmation)
        }
    }

    @ViewBuilder
    private func rowView(_ row: DeviceAppsRow) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(row.title).font(.body)
                if row.running {
                    Text("运行中")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.green.opacity(0.15), in: Capsule())
                        .foregroundStyle(Color.green)
                }
            }
            if let detail = row.detail { Text(detail).font(.footnote).foregroundStyle(.secondary) }
            HStack(spacing: 12) {
                Button("打开") { Task { await model.open(row) } }
                if row.running { Button("停止") { Task { await model.stop(row) } } }
                Button("删除", role: .destructive) { model.requestDelete(row) }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(model.busy)
        }
        .padding(.vertical, 4)
        .accessibilityIdentifier("device-app-row")
    }
}

/// Where a device's entry points lead: the device-apps page for a device-app capable device, the generic
/// panel for everything else.
struct DeviceEntryPage: View {
    let device: BLEDeviceStore.Device
    let store: BLEDeviceStore

    init(device: BLEDeviceStore.Device, store: BLEDeviceStore? = nil) {
        self.device = device
        self.store = store ?? .shared
    }

    var body: some View {
        let current = store.devices.first { $0.id == device.id } ?? device
        if DeviceAppsPageModel.isDeviceAppTarget(tools: current.linkTools) {
            DeviceAppsPage(device: current, store: store)
        } else {
            DevicePanelPage(device: current, store: store)
        }
    }
}
