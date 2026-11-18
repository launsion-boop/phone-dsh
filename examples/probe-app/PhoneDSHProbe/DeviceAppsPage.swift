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
    private let device: BLEDeviceStore.Device?
    private let store: BLEDeviceStore?
    /// false only for the DEBUG layout render (ImageRenderer draws no ScrollView content).
    private let scrolls: Bool

    init(device: BLEDeviceStore.Device, store: BLEDeviceStore) {
        self.device = device
        self.store = store
        self.scrolls = true
        _model = StateObject(wrappedValue: DeviceAppsPageModel(link: DeviceAppsLinkFactory.make(deviceID: device.id, store: store)))
    }

    /// A page over a given model (DEBUG layout rendering with a stubbed link; no device behind it).
    init(model: DeviceAppsPageModel, scrolls: Bool = true) {
        self.device = nil
        self.store = nil
        self.scrolls = scrolls
        _model = StateObject(wrappedValue: model)
    }

    var body: some View {
        Group {
            if scrolls { ScrollView { content.padding(16) } } else { content.padding(16) }
        }
        .background(Color(.systemGroupedBackground))
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

    private var content: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let banner = model.banner {
                Text(banner.text)
                    .font(.subheadline)
                    .foregroundStyle(banner.isError ? Color.red : Color.green)
                    .accessibilityIdentifier("device-apps-banner")
            }
            switch model.phase {
            case .loading:
                ProgressView("正在读取设备上的应用…").frame(maxWidth: .infinity)
            case .notConnected:
                Text(DeviceAppCustomerText.pageNotConnected).foregroundStyle(.secondary)
                    .accessibilityIdentifier("device-apps-not-connected")
            case .failed(let text):
                Text(text).foregroundStyle(.secondary)
            case .ready:
                if let free = model.freeSpace {
                    Text(free).font(.footnote).foregroundStyle(.secondary)
                }
                if model.rows.isEmpty {
                    Text(DeviceAppCustomerText.emptyDevice).foregroundStyle(.secondary)
                        .accessibilityIdentifier("device-apps-empty")
                } else {
                    Text("设备上的应用").font(.footnote).foregroundStyle(.secondary)
                    // Grid (not LazyVGrid): a row's two cards get the same height, and 22 cards are cheap.
                    Grid(horizontalSpacing: 12, verticalSpacing: 12) {
                        ForEach(Array(stride(from: 0, to: model.rows.count, by: 2)), id: \.self) { start in
                            GridRow {
                                rowView(model.rows[start])
                                if start + 1 < model.rows.count { rowView(model.rows[start + 1]) } else { Color.clear }
                            }
                        }
                    }
                }
            }
            DisclosureGroup("高级") {
                if let device, let store {
                    NavigationLink {
                        DevicePanelPage(device: device, store: store)
                    } label: {
                        Text("设备的原始面板")
                    }
                    .accessibilityIdentifier("device-apps-advanced-panel")
                }
            }
            .padding(.top, 8)
        }
    }

    /// One app as a card in the two-column grid: tapping the card opens the app; the menu holds
    /// 停止 (only while it runs) and 删除.
    @ViewBuilder
    private func rowView(_ row: DeviceAppsRow) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                Text(row.title)
                    .font(.headline)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 4)
                Menu {
                    if row.running { Button("停止") { Task { await model.stop(row) } } }
                    Button("删除", role: .destructive) { model.requestDelete(row) }
                } label: {
                    Image(systemName: "ellipsis.circle").font(.title3).foregroundStyle(.secondary)
                }
                .accessibilityLabel("更多")
                .accessibilityIdentifier("device-app-more")
            }
            if row.running {
                Text("运行中")
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color.green.opacity(0.15), in: Capsule())
                    .foregroundStyle(Color.green)
            }
            if let detail = row.detail { Text(detail).font(.footnote).foregroundStyle(.secondary).lineLimit(2) }
            Spacer(minLength: 0)
            Button("打开") { Task { await model.open(row) } }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .frame(minHeight: 110)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
        .disabled(model.busy)
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
