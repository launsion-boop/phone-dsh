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

/// The page itself (device-app.md §13): a device header, the 「正在运行」 card, the 「设备上的应用」 list and a
/// collapsed 「高级」. On a device it is a `List` (swipe-to-delete, pull-to-refresh); the DEBUG layout render
/// draws the same sections in a stack because `ImageRenderer` draws no `List` or `ScrollView` content.
struct DeviceAppsPage: View {
    @StateObject private var model: DeviceAppsPageModel
    private let device: BLEDeviceStore.Device?
    private let store: BLEDeviceStore?
    private let renderedDeviceName: String
    /// false only for the DEBUG layout render.
    private let scrolls: Bool

    init(device: BLEDeviceStore.Device, store: BLEDeviceStore) {
        self.device = device
        self.store = store
        self.renderedDeviceName = device.name
        self.scrolls = true
        _model = StateObject(wrappedValue: DeviceAppsPageModel(link: DeviceAppsLinkFactory.make(deviceID: device.id, store: store)))
    }

    /// A page over a given model (DEBUG layout rendering with a stubbed link; no device behind it).
    init(model: DeviceAppsPageModel, deviceName: String = "AI Passport", scrolls: Bool = true) {
        self.device = nil
        self.store = nil
        self.renderedDeviceName = deviceName
        self.scrolls = scrolls
        _model = StateObject(wrappedValue: model)
    }

    /// Icon tints: the shared device-app.md §13.1 palette (the device home screen uses the same one). Green
    /// is not in it; it marks 运行中.
    private static let tints: [Color] = DeviceAppsPageModel.iconPalette.map {
        Color(.sRGB, red: Double(($0 >> 16) & 0xFF) / 255, green: Double(($0 >> 8) & 0xFF) / 255, blue: Double($0 & 0xFF) / 255)
    }

    var body: some View {
        Group {
            if scrolls {
                List { listSections }
                    .listStyle(.insetGrouped)
                    .refreshable { await model.refresh() }
            } else {
                VStack(alignment: .leading, spacing: 18) { stackSections }.padding(16)
            }
        }
        .background(Color(.systemGroupedBackground))
        .overlay(alignment: .bottom) { toast }
        .animation(.snappy, value: model.banner)
        .navigationTitle("设备应用")
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.refresh() }
        .alert("删除「\(model.pendingDelete?.title ?? "")」？", isPresented: Binding(
            get: { model.pendingDelete != nil }, set: { if !$0 { model.cancelDelete() } })) {
            Button("删除", role: .destructive) { Task { await model.confirmDelete() } }
            Button("取消", role: .cancel) { model.cancelDelete() }
        } message: {
            Text(DeviceAppCustomerText.deleteConfirmation)
        }
    }

    // MARK: Sections

    @ViewBuilder
    private var listSections: some View {
        Section { header }
        switch model.phase {
        case .loading:
            Section { ProgressView("正在读取设备上的应用…").frame(maxWidth: .infinity) }
        case .notConnected:
            Section { notice(DeviceAppCustomerText.pageNotConnected, symbol: "antenna.radiowaves.left.and.right.slash", id: "device-apps-not-connected") }
        case .failed(let text):
            Section { notice(text, symbol: "exclamationmark.triangle", id: nil) }
        case .ready:
            if let running = model.runningRow {
                Section("正在运行") { runningCard(running).deleteActions(model, running) }
            }
            if model.rows.isEmpty {
                Section { notice(DeviceAppCustomerText.emptyDevice, symbol: "square.grid.2x2", id: "device-apps-empty") }
            } else if !model.listRows.isEmpty {
                Section("设备上的应用") {
                    ForEach(model.listRows) { row in appRow(row).deleteActions(model, row) }
                }
            }
        }
        Section { advanced }
    }

    @ViewBuilder
    private var stackSections: some View {
        grouped { header }
        switch model.phase {
        case .loading: ProgressView("正在读取设备上的应用…").frame(maxWidth: .infinity)
        case .notConnected: grouped { notice(DeviceAppCustomerText.pageNotConnected, symbol: "antenna.radiowaves.left.and.right.slash", id: nil) }
        case .failed(let text): grouped { notice(text, symbol: "exclamationmark.triangle", id: nil) }
        case .ready:
            if let running = model.runningRow { grouped("正在运行") { runningCard(running) } }
            if model.rows.isEmpty {
                grouped { notice(DeviceAppCustomerText.emptyDevice, symbol: "square.grid.2x2", id: nil) }
            } else if !model.listRows.isEmpty {
                grouped("设备上的应用") {
                    ForEach(Array(model.listRows.enumerated()), id: \.element.id) { index, row in
                        if index > 0 { Divider().padding(.leading, 52) }
                        appRow(row)
                    }
                }
            }
        }
    }

    /// One inset-grouped box, for the stack layout only.
    private func grouped<Content: View>(_ title: String? = nil, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let title { Text(title).font(.footnote).foregroundStyle(.secondary).padding(.leading, 16) }
            VStack(alignment: .leading, spacing: 10) { content() }
                .padding(.horizontal, 16).padding(.vertical, 11)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 10))
        }
    }

    // MARK: Pieces

    private var connected: Bool {
        switch model.phase { case .notConnected: false; case .loading: device?.state == "已连接"; default: true }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "cpu")
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 40, height: 40)
                .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 2) {
                Text(DeviceAppsPageModel.deviceName(renderedDeviceName))
                    .font(.headline).lineLimit(1)
                HStack(spacing: 6) {
                    Circle().fill(connected ? Color.green : Color.secondary).frame(width: 7, height: 7)
                    Text(connected ? "已连接" : "未连接")
                    if let free = model.freeSpace { Text("·"); Text(free) }
                }
                .font(.footnote).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("device-apps-header")
    }

    private func icon(_ row: DeviceAppsRow, running: Bool) -> some View {
        let tint = running ? Color.green : Self.tints[DeviceAppsPageModel.iconTint(name: row.id, count: Self.tints.count)]
        return Text(DeviceAppsPageModel.iconGlyph(title: row.title))
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: 36, height: 36)
            .background(tint.opacity(0.15), in: RoundedRectangle(cornerRadius: 9))
            .accessibilityHidden(true)
    }

    private func runningCard(_ row: DeviceAppsRow) -> some View {
        HStack(spacing: 12) {
            icon(row, running: true)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.title).font(.body.weight(.medium)).lineLimit(2)
                Text(row.detail ?? DeviceAppCustomerText.exitHint).font(.footnote).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: 8)
            actionButton("停止", row: row) { await model.stop(row) }
                .accessibilityIdentifier("device-app-stop")
        }
        .accessibilityIdentifier("device-app-running")
    }

    private func appRow(_ row: DeviceAppsRow) -> some View {
        HStack(spacing: 12) {
            icon(row, running: false)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.title).lineLimit(2)
                if let detail = row.detail { Text(detail).font(.footnote).foregroundStyle(.secondary).lineLimit(1) }
                if row.running { Text("运行中").font(.caption2.weight(.semibold)).foregroundStyle(.green) }
            }
            Spacer(minLength: 8)
            actionButton("打开", row: row) { await model.open(row) }
                .accessibilityIdentifier("device-app-open")
        }
        .accessibilityIdentifier("device-app-row")
    }

    /// The row's one button; only the acting row shows progress, the others wait without greying out.
    private func actionButton(_ title: String, row: DeviceAppsRow, action: @escaping () async -> Void) -> some View {
        Button { Task { await action() } } label: {
            ZStack {
                Text(title).opacity(model.busyRowID == row.id ? 0 : 1)
                if model.busyRowID == row.id { ProgressView().controlSize(.small) }
            }
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
        .controlSize(.small)
    }

    private func notice(_ text: String, symbol: String, id: String?) -> some View {
        Label { Text(text).foregroundStyle(.secondary) } icon: { Image(systemName: symbol).foregroundStyle(.secondary) }
            .padding(.vertical, 6)
            .accessibilityIdentifier(id ?? "device-apps-notice")
    }

    @ViewBuilder
    private var advanced: some View {
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
    }

    /// The result sentence: a toast that goes away by itself (an error stays longer) or on a tap.
    @ViewBuilder
    private var toast: some View {
        if let banner = model.banner {
            Label(banner.text, systemImage: banner.isError ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                .font(.subheadline)
                .foregroundStyle(banner.isError ? Color.red : Color.primary)
                .padding(.horizontal, 16).padding(.vertical, 12)
                .background(.regularMaterial, in: Capsule())
                .padding(.horizontal, 16).padding(.bottom, 12)
                .onTapGesture { model.dismissBanner() }
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .task(id: banner) {
                    try? await Task.sleep(for: .seconds(banner.isError ? 6 : 3))
                    if !Task.isCancelled, model.banner == banner { model.dismissBanner() }
                }
                .accessibilityIdentifier("device-apps-banner")
        }
    }
}

private extension View {
    /// 删除 on the trailing swipe (the running card's 停止 is its own button). No long-press menu: the
    /// interaction contract (spec/ui/v1/interaction.md §3) lists every `.contextMenu` surface.
    func deleteActions(_ model: DeviceAppsPageModel, _ row: DeviceAppsRow) -> some View {
        swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button("删除", role: .destructive) { model.requestDelete(row) }
        }
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
