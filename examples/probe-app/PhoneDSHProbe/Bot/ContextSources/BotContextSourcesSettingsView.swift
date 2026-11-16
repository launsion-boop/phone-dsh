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
    @Published private(set) var loading = false
    @Published var actionError: String?

    let botID: String
    private let assembly: BotContextSourcesAssembly

    init(botID: String, assembly: BotContextSourcesAssembly) {
        self.botID = botID
        self.assembly = assembly
    }

    func load() async {
        await readStates()
        // Syncing every OS adapter can block on a permission prompt; it must
        // never delay the switch states or hold `loading` while the page is
        // visible. Sync in the background, then re-read the ledger truth.
        Task { [weak self] in
            guard let self else { return }
            await self.assembly.refreshOSAuthorizations()
            await self.readStates()
        }
    }

    private func readStates() async {
        loading = true
        var next: [BotContextSourceKind: BotSourceAuthorizationState] = [:]
        var nextSubscriptions: [BotContextSourceKind: Bool] = [:]
        for source in BotContextSourceKind.allCases {
            if let state = await assembly.authorization(for: source) {
                next[source] = state
                nextSubscriptions[source] = await assembly.isSubscribed(
                    botID: botID, source: source)
            }
        }
        states = next
        subscriptions = nextSubscriptions
        let view = await assembly.observationView(for: botID)
        recent = view.items
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
}

struct BotContextSourcesSettingsView: View {
    @StateObject private var model: BotContextSourcesSettingsModel

    init(botID: String, assembly: BotContextSourcesAssembly) {
        _model = StateObject(wrappedValue: BotContextSourcesSettingsModel(
            botID: botID, assembly: assembly))
    }

    var body: some View {
        List {
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
