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
        loading = true
        defer { loading = false }
        await assembly.refreshOSAuthorizations()
        var next: [BotContextSourceKind: BotSourceAuthorizationState] = [:]
        for source in BotContextSourceKind.allCases {
            if let state = await assembly.authorization(for: source) {
                next[source] = state
            }
        }
        states = next
        let view = await assembly.observationView(for: botID)
        recent = view.items
        if !assembly.isStarted() {
            actionError = "情境来源尚未启动，请回到 Bot 页面重试。"
        }
    }

    func isEnabled(_ source: BotContextSourceKind) -> Bool {
        states[source]?.authorization.allowsReading == true
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

    /// User toggles are the only production grant/revoke entry. An OS prompt
    /// appears only when the source actually has an OS permission.
    func set(_ source: BotContextSourceKind, enabled: Bool) async {
        actionError = nil
        do {
            if enabled {
                _ = try await assembly.requestConsent(source: source, botID: botID)
            } else {
                await assembly.revoke(source: source, reason: "user-revoked")
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
                        }
                    }
                    .disabled(model.loading)
                    .accessibilityIdentifier("bot.info.context-source.\(source.rawValue)")
                }
            } header: {
                Text("独立授权")
            } footer: {
                Text("每个来源可单独授权/撤回。撤回后停止该来源的 OS 订阅，旧回调和读取会被拒绝；来源只产生观测和唤醒，不决定是否开口。")
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
