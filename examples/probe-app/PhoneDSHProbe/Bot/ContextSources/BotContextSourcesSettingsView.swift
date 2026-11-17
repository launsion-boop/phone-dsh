// SPDX-License-Identifier: MIT

import Foundation
import SwiftUI
import PhoneDSHBot

/// The production settings model for the seven native context sources.
///
/// It calls the real assembly: `requestConsent` (which subscribes the Bot and
/// starts the OS adapter), `revoke`, `refreshOSAuthorizations`, and the
/// payload-free read view. It never fabricates a source state or an observation.
@MainActor
final class BotContextSourcesSettingsModel: ObservableObject {
    @Published private(set) var states: [BotContextSourceKind: BotSourceAuthorizationState] = [:]
    /// Per-Bot subscription, not the App/OS consent. A source may be globally
    /// authorized while this Bot is not subscribed (and vice versa after a
    /// per-Bot unsubscribe/global revoke).
    @Published private(set) var subscriptions: [BotContextSourceKind: Bool] = [:]
    @Published private(set) var recent: [BotContextObservationViewItem] = []
    @Published private(set) var fences: [BotContextGeofenceSpec] = []
    @Published private(set) var loading = false
    @Published var actionError: String?
    /// A later load/set supersedes an older OS-refresh read. Without this an
    /// older task can overwrite the current loading/actionError/states.
    private var loadGeneration = 0
    private var refreshTask: Task<Void, Never>?

    let botID: String
    private let assembly: BotContextSourcesAssembly

    init(botID: String, assembly: BotContextSourcesAssembly) {
        self.botID = botID
        self.assembly = assembly
        // N/assembly owns the single product-config store; read after load.
    }

    /// User-confirmed places only. Coordinates are typed/selected by the user;
    /// this never asks CoreLocation for the current position.
    func addFence(label: String, latitude: Double, longitude: Double,
                  radiusMeters: Double) async {
        do {
            let clean = label.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clean.isEmpty else { throw BotContextSourceError.invalidRequest("围栏名称不能为空") }
            let id = "fence-" + String(UUID().uuidString.prefix(8)).lowercased()
            let spec = try BotContextGeofenceSpec(
                id: id, latitude: latitude, longitude: longitude,
                radiusMeters: radiusMeters, label: clean)
            var next = fences
            next.append(spec)
            try await assembly.setGeofences(next)
            fences = assembly.geofences
            actionError = nil
        } catch {
            actionError = (error as? LocalizedError)?.errorDescription ?? "围栏保存失败"
        }
    }

    func removeFence(_ spec: BotContextGeofenceSpec) async {
        var next = fences
        next.removeAll { $0.id == spec.id }
        do {
            try await assembly.setGeofences(next)
            fences = assembly.geofences
        } catch {
            actionError = (error as? LocalizedError)?.errorDescription ?? "围栏移除失败"
        }
    }

    func load() async {
        loadGeneration += 1
        let generation = loadGeneration
        await readStates(generation: generation)
        // Syncing every OS adapter can block on a permission prompt; it must
        // never delay the switch states or hold `loading` while the page is
        // visible. Sync in the background, then re-read the ledger truth. Only
        // the newest generation may apply its result.
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            guard let self else { return }
            await self.assembly.refreshOSAuthorizations()
            guard !Task.isCancelled, generation == self.loadGeneration else { return }
            await self.readStates(generation: generation)
        }
    }

    private func readStates(generation: Int) async {
        guard generation == loadGeneration else { return }
        loading = true
        var next: [BotContextSourceKind: BotSourceAuthorizationState] = [:]
        var nextSubscriptions: [BotContextSourceKind: Bool] = [:]
        for source in BotContextSourceKind.allCases {
            if let state = await assembly.authorization(for: source) {
                next[source] = state
                nextSubscriptions[source] = await assembly.isSubscribed(
                    botID: botID, source: source)
            }
            guard generation == loadGeneration else { return }
        }
        guard generation == loadGeneration else { return }
        states = next
        subscriptions = nextSubscriptions
        let view = await assembly.observationView(for: botID)
        guard generation == loadGeneration else { return }
        recent = view.items
        fences = assembly.geofences
        if !assembly.isStarted() {
            actionError = "情境来源尚未启动，请回到 Bot 页面重试。"
        }
        loading = false
    }

    /// The switch is the pair (global App/OS authorization, this Bot's actual
    /// subscription). A globally authorized source never makes Bot B show on.
    func isEnabled(_ source: BotContextSourceKind) -> Bool {
        guard states[source]?.authorization.allowsReading == true else { return false }
        return subscriptions[source] == true
    }

    func isSubscribed(_ source: BotContextSourceKind) -> Bool {
        subscriptions[source] == true
    }

    func stateText(_ source: BotContextSourceKind) -> String {
        guard let state = states[source] else { return "不可用" }
        switch state.authorization {
        case .notDetermined: return "未授权"
        case .authorized: return "已授权"
        case .limited: return "受限授权"
        case .denied: return "系统已拒绝"
        case .restricted: return "系统受限"
        case .revoked: return "已撤回"
        }
    }

    func subscriptionText(_ source: BotContextSourceKind) -> String {
        guard states[source] != nil else { return "本 Bot：不可用" }
        return isSubscribed(source) ? "本 Bot：已订阅" : "本 Bot：未订阅"
    }

    /// User toggles are the only production grant/revoke entry. An OS prompt
    /// appears only when the source actually has an OS permission.
    func set(_ source: BotContextSourceKind, enabled: Bool) async {
        actionError = nil
        do {
            if enabled {
                // Reuses the existing global consent when it is already
                // authorized; only subscribes this Bot. A missing global grant
                // is the only path that may ask the OS.
                _ = try await assembly.requestConsent(source: source, botID: botID)
            } else {
                // Turn off only this Bot's subscription. This is not a global
                // App/source revoke and must not affect another Bot.
                await assembly.unsubscribe(botID: botID, source: source)
            }
            await load()
        } catch {
            actionError = (error as? LocalizedError)?.errorDescription
                ?? "情境来源操作失败，请稍后重试。"
            await load()
        }
    }

    func clearError() { actionError = nil }

#if DEBUG
    /// Test seam for the deterministic late-result ordering check. Production
    /// load()/readStates() use the same counter and guards.
    func beginGenerationForTesting() -> Int {
        loadGeneration += 1
        return loadGeneration
    }

    func isCurrentGenerationForTesting(_ generation: Int) -> Bool {
        generation == loadGeneration
    }
#endif
}

struct BotContextSourcesSettingsView: View {
    @StateObject private var model: BotContextSourcesSettingsModel
    @State private var fenceLabel = ""
    @State private var fenceLatitude = ""
    @State private var fenceLongitude = ""
    @State private var fenceRadius = "200"

    init(botID: String, assembly: BotContextSourcesAssembly) {
        _model = StateObject(wrappedValue: BotContextSourcesSettingsModel(
            botID: botID, assembly: assembly))
    }

    var body: some View {
        List {
            if model.loading {
                Section {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("正在读取情境来源…")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityIdentifier("bot.context.loading")
                }
            }

            Section {
                ForEach(BotContextSourceKind.allCases, id: \.self) { source in
                    Toggle(isOn: Binding(
                        get: { model.isEnabled(source) },
                        set: { value in Task { await model.set(source, enabled: value) } }
                    )) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(Self.title(source))
                                .font(.system(size: 15))
                            Text(model.stateText(source))
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                            Text(model.subscriptionText(source))
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .disabled(model.loading)
                    .accessibilityIdentifier("bot.info.context-source.\(source.rawValue)")
                }
            } header: {
                Text("独立授权")
            } footer: {
                Text("这里分两层：上面的授权是全局 App/OS 权限；下面的“本 Bot”是当前 Bot 自己的订阅。打开只订阅当前 Bot（复用已有全局授权），关闭只取消当前 Bot，不影响其他 Bot。全局撤权会使所有 Bot 停读并失效旧回调；来源只产生观测和唤醒，不决定是否开口。")
            }

            Section("位置围栏（用户确认的地点）") {
                ForEach(model.fences) { fence in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(fence.label ?? fence.id).font(.system(size: 14))
                            Text(String(format: "%.5f, %.5f · %dm",
                                        fence.latitude, fence.longitude, Int(fence.radiusMeters)))
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("移除", role: .destructive) {
                            Task { await model.removeFence(fence) }
                        }
                        .accessibilityIdentifier("bot.context.fence.remove.\(fence.id)")
                    }
                }
                TextField("名称（如 公司）", text: $fenceLabel)
                    .accessibilityIdentifier("bot.context.fence.label")
                HStack {
                    TextField("纬度", text: $fenceLatitude).keyboardType(.numbersAndPunctuation)
                        .accessibilityIdentifier("bot.context.fence.latitude")
                    TextField("经度", text: $fenceLongitude).keyboardType(.numbersAndPunctuation)
                        .accessibilityIdentifier("bot.context.fence.longitude")
                }
                TextField("半径（米，10–1000）", text: $fenceRadius)
                    .keyboardType(.numberPad)
                    .accessibilityIdentifier("bot.context.fence.radius")
                Button("添加围栏") {
                    guard let lat = Double(fenceLatitude), let lon = Double(fenceLongitude),
                          let radius = Double(fenceRadius) else {
                        model.actionError = "请输入有效的纬度和经度"
                        return
                    }
                    Task {
                        await model.addFence(label: fenceLabel, latitude: lat,
                                             longitude: lon, radiusMeters: radius)
                        if model.actionError == nil {
                            fenceLabel = ""; fenceLatitude = ""; fenceLongitude = ""
                        }
                    }
                }
                .accessibilityIdentifier("bot.context.fence.add")
                Text("只使用你在这里确认的地点；不会读取当前定位。配置后真实硬件围栏回调仍需真机授权。")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }

            if !model.recent.isEmpty {
                Section("最近观测（只显示来源元数据）") {
                    ForEach(Array(model.recent.prefix(10).enumerated()), id: \.offset) { _, item in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(Self.title(item.source))
                                .font(.system(size: 14))
                            Text("\(item.kind) · \(Self.timeText(item.observedAtMS)) · \(item.uncertainty.level.rawValue)")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            Section("平台边界") {
                ForEach(BotContextCapabilityMatrix.all.filter { $0.support == .unsupported }, id: \.id) { row in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(Self.capabilityTitle(row.id))
                            .font(.system(size: 14))
                        Text(row.reason)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if let error = model.actionError {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.system(size: 13))
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("bot.context.error")
                }
            }
        }
        .navigationTitle("情境来源")
        .task { await model.load() }
        .refreshable { await model.load() }
    }

    private static func title(_ source: BotContextSourceKind) -> String {
        switch source {
        case .calendar: return "日历"
        case .contacts: return "联系人"
        case .selectedMedia: return "我选择的图片/文件"
        case .locationFence: return "位置围栏"
        case .power: return "充电与低电量"
        case .ownNotification: return "本 App 通知"
        case .externalEntry: return "分享/链接/粘贴"
        }
    }

    private static func capabilityTitle(_ id: String) -> String {
        switch id {
        case "third-party-notifications.read": return "其他 App 的通知"
        case "sms.read": return "短信"
        case "call-history.read": return "通话记录"
        case "photos-library.enumerate": return "整库相册枚举"
        case "power.system-idle": return "系统空闲"
        case "location.continuous": return "持续定位"
        case "android.notification-listener", "android.sms-call-log": return "Android 能力（延期）"
        default: return id
        }
    }

    private static func timeText(_ milliseconds: Int64) -> String {
        let date = Date(timeIntervalSince1970: Double(milliseconds) / 1_000)
        return date.formatted(date: .omitted, time: .shortened)
    }
}
