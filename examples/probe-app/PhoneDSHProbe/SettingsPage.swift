// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — official settings information architecture.

import PhoneDSH
import ProbeKit
import SwiftUI

enum NativeSettingsTab: String, CaseIterable, Identifiable {
    case general, models, plugins, permissions, presets

    var id: String { rawValue }
    var title: String {
        switch self {
        case .general: NativeText("通用设置", "General")
        case .models: NativeText("模型", "Models")
        case .plugins: NativeText("内置插件", "Built-in Plugins")
        case .permissions: NativeText("手机权限", "Phone Permissions")
        case .presets: NativeText("Agent 预设", "Agent Presets")
        }
    }
    var shortTitle: String {
        switch self {
        case .general: NativeText("通用", "General")
        case .models: NativeText("模型", "Models")
        case .plugins: NativeText("插件", "Plugins")
        case .permissions: NativeText("手机权限", "Permissions")
        case .presets: NativeText("预设", "Presets")
        }
    }
    var icon: String {
        switch self {
        case .general: "gearshape"
        case .models: "cylinder"
        case .plugins: "slider.horizontal.3"
        case .permissions: "hand.raised"
        case .presets: "person.2"
        }
    }
}

/// Settings home: one grouped list in the phone's own settings shape. Every
/// row opens its page (or a menu for a one-of choice); nothing is edited
/// inline except those menus. Groups run from what you change most (models,
/// permissions) to what you read least (engine, about).
struct SettingsPage: View {
    @Environment(\.dismiss) private var dismiss
    @State private var preferences = NativeChatPreferences.shared
    @State private var configuration = NativeConfigurationModel.shared
    @StateObject private var phonePermissions = PhonePermissionRequester.shared
    @State private var chat = ChatModel.shared
    @State private var management = DSHManagementModel.shared
    /// Deep entry (`SettingsPage(initialTab:)`) pushes that page on appear.
    @State private var deepLink: NativeSettingsTab?

    init(initialTab: NativeSettingsTab = .general) {
        _deepLink = State(initialValue: initialTab == .general ? nil : initialTab)
    }

    var body: some View {
        List {
            if AppShellMode.current == .legacy {
            Section(NativeText("模型与智能体", "Models and agents")) {
                link(NativeText("模型服务", "Model providers"), icon: "cpu") { ModelProviderSettingsPage() }
                link(NativeText("Agent 预设", "Agent presets"), icon: "person.2") { NativeAgentPresetsPage() }
                link(NativeText("插件与工具", "Plugins and tools"), icon: "puzzlepiece.extension") {
                    NativeConfigurationPage()
                }
            }

            Section(NativeText("权限与隐私", "Permissions and privacy")) {
                link(NativeText("新会话默认权限", "Default permission"), icon: "lock.shield",
                     value: permissionTitle) { PermissionDefaultsPage() }
                link(NativeText("手机权限", "Phone permissions"), icon: "hand.raised",
                     value: phonePermissionSummary) { PhonePermissionsPage(embedded: true) }
                link(NativeText("网络访问", "Network access"), icon: "network") { EgressAllowListPage() }
            }

            Section(NativeText("对话", "Conversation")) {
                Picker(selection: Binding(get: { preferences.appearance },
                                          set: { preferences.setAppearance($0) })) {
                    Text(NativeText("跟随系统", "System")).tag(NativeAppearance.system)
                    Text(NativeText("浅色", "Light")).tag(NativeAppearance.light)
                    Text(NativeText("深色", "Dark")).tag(NativeAppearance.dark)
                } label: {
                    SettingsRowLabel(title: NativeText("外观", "Appearance"), icon: "circle.lefthalf.filled")
                }
                Picker(selection: Binding(get: { preferences.language },
                                          set: { preferences.setLanguage($0) })) {
                    Text(NativeText("跟随系统", "System")).tag(NativeLocalePreference.system)
                    Text("中文").tag(NativeLocalePreference.zh)
                    Text("English").tag(NativeLocalePreference.en)
                } label: {
                    SettingsRowLabel(title: NativeText("语言", "Language"), icon: "globe")
                }
                link(NativeText("字号", "Text size"), icon: "textformat.size",
                     value: "\(preferences.fontSize(for: .text))") { FontSizeSettingsPage() }
                link(NativeText("工作过程", "Work details"), icon: "list.bullet.rectangle") {
                    ConversationSettingsPage()
                }
                link(NativeText("快捷键", "Shortcuts"), icon: "command") { NativeShortcutsPage() }
            }
            }

            Section(NativeText("会话与文件", "Sessions and files")) {
                link(NativeText("文件夹", "Folders"), icon: "folder",
                     value: management.workspaces.isEmpty ? nil : "\(management.workspaces.count)") {
                    WorkspaceFoldersPage()
                }
                link(NativeText("已归档会话", "Archived sessions"), icon: "archivebox",
                     value: management.archivedSessions.isEmpty ? nil : "\(management.archivedSessions.count)") {
                    ArchivedSessionsPage()
                }
            }

            Section {
                HStack(spacing: 12) {
                    SettingsRowLabel(title: NativeText("引擎状态", "Engine"), icon: "bolt.horizontal",
                                     value: chat.hostState)
                }
                if chat.engineNeedsReset {
                    Button {
                        Task { await chat.restartEngine() }
                    } label: {
                        SettingsRowLabel(title: NativeText("重新启动引擎", "Restart engine"),
                                         icon: "arrow.clockwise")
                    }
                }
                link(NativeText("运行状态", "Runtime details"), icon: "waveform.path.ecg") {
                    RuntimeDetailsPage(model: chat)
                }
            } header: {
                Text(NativeText("引擎", "Engine"))
            } footer: {
                if chat.engineNeedsReset {
                    Text(NativeText(
                        "上次启动失败后引擎不会自动重试。重新启动会确认这次失败并重新启动，会话数据不受影响。",
                        "The engine does not retry after a failure. Restarting acknowledges it and boots again; session data is kept."))
                }
            }

            Section(NativeText("关于", "About")) {
                link(NativeText("关于 Phone DSH", "About Phone DSH"), icon: "info.circle") { SettingsAboutPage() }
                SettingsRowLabel(title: NativeText("版本", "Version"), icon: "number",
                                 value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—")
                link(NativeText("开源许可", "Open-source licenses"), icon: "doc.text") { LicensesPage() }
            }
        }
        .homeGroupedList()
        .tint(HomeSpec.textPrimary)
        .navigationTitle(NativeText("设置", "Settings"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(NativeText("完成", "Done")) { dismiss() }
                    .fontWeight(.semibold)
            }
        }
        .navigationDestination(item: $deepLink) { tab in deepPage(tab) }
        .task {
            await configuration.refresh()
            await phonePermissions.refresh()
            await management.refresh()
        }
    }

    private func link<Destination: View>(_ title: String, icon: String, value: String? = nil,
                                         @ViewBuilder destination: @escaping () -> Destination) -> some View {
        NavigationLink {
            destination()
        } label: {
            SettingsRowLabel(title: title, icon: icon, value: value)
        }
    }

    @ViewBuilder private func deepPage(_ tab: NativeSettingsTab) -> some View {
        switch tab {
        case .general: EmptyView()
        case .models: ModelProviderSettingsPage()
        case .plugins: NativeConfigurationPage()
        case .permissions: PhonePermissionsPage(embedded: true)
        case .presets: NativeAgentPresetsPage()
        }
    }

    private var permissionTitle: String {
        guard let id = configuration.defaultPermissionMode else { return NativeText("未设置", "Not set") }
        return nativePermissionModeTitle(id: id)
    }

    private var phonePermissionSummary: String {
        let granted = phonePermissions.statuses.values.filter { status in
            if case .authorized = status { return true }
            if case .limited = status { return true }
            return false
        }.count
        return String(format: NativeText("%d / %d 已允许", "%d / %d allowed"),
                      granted, PhoneCapability.allCases.count)
    }
}

/// One settings row: 24pt glyph, 16pt title, optional 15pt value on the right
/// (HomeSpec ink: primary title, placeholder value).
struct SettingsRowLabel: View {
    let title: String
    let icon: String
    var value: String?

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .regular))
                .foregroundStyle(HomeSpec.textPrimary)
                .frame(width: 24, height: 24)
            Text(title)
                .font(.system(size: HomeSpec.bodySize))
                .foregroundStyle(HomeSpec.textPrimary)
                .lineLimit(1)
            Spacer(minLength: 8)
            if let value {
                Text(value)
                    .font(.system(size: 15))
                    .foregroundStyle(HomeSpec.textPlaceholder)
                    .lineLimit(1)
            }
        }
        .frame(minHeight: 32)
    }
}

/// 字号: the three text roles, each a stepper plus an optional font family.
private struct FontSizeSettingsPage: View {
    @State private var preferences = NativeChatPreferences.shared

    var body: some View {
        List {
            section(.text, NativeText("会话内容", "Conversation"))
            section(.code, NativeText("代码", "Code"))
            section(.terminal, NativeText("终端", "Terminal"))
        }
        .homeGroupedList()
        .navigationTitle(NativeText("字号", "Text size"))
        .navigationBarTitleDisplayMode(.inline)
    }

    private func section(_ role: NativeFontRole, _ title: String) -> some View {
        let size = preferences.fontSize(for: role)
        return Section {
            Stepper(value: Binding(get: { size }, set: { preferences.setFontSize(role, $0) }),
                    in: role.sizeRange) {
                LabeledContent(NativeText("字号", "Size"), value: "\(size) pt")
            }
            TextField(NativeText("字体（留空使用系统默认）", "Font family (system default)"), text: Binding(
                get: { preferences.fontFamily(for: role) },
                set: { preferences.setFontFamily(role, $0) }))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        } header: {
            Text(title)
        } footer: {
            if let missing = preferences.fontFamilyError(for: role) {
                Text(String(format: NativeText("未安装字体 %@，将使用系统回退字体", "Font %@ is unavailable; system fallback will be used"), missing))
            }
        }
    }
}

/// 工作过程: how the transcript shows and folds the agent's work, and what
/// sending does while it is busy.
private struct ConversationSettingsPage: View {
    @State private var preferences = NativeChatPreferences.shared

    var body: some View {
        List {
            Section {
                Picker(NativeText("显示方式", "Show"), selection: Binding(
                    get: { preferences.transcriptView }, set: { preferences.setTranscriptView($0) })) {
                    Text(NativeText("简洁", "Compact")).tag(NativeTranscriptViewMode.compact)
                    Text(NativeText("标准", "Standard")).tag(NativeTranscriptViewMode.standard)
                    Text(NativeText("详细", "Detailed")).tag(NativeTranscriptViewMode.detailed)
                    Text(NativeText("完全展开", "Verbose")).tag(NativeTranscriptViewMode.verbose)
                }
                Picker(NativeText("收起时机", "Collapse"), selection: Binding(
                    get: { preferences.collapseTiming }, set: { preferences.setCollapseTiming($0) })) {
                    Text(NativeText("回答结束后", "After completion")).tag(NativeCollapseTiming.completion)
                    Text(NativeText("下次有新消息时", "With the next input")).tag(NativeCollapseTiming.nextInput)
                }
                Toggle(NativeText("显示代码工作视图", "Show code work"), isOn: Binding(
                    get: { preferences.developerTools }, set: { preferences.setDeveloperTools($0) }))
            } header: {
                Text(NativeText("工作步骤", "Work steps"))
            }

            Section {
                Picker(NativeText("任务进行中发送", "While busy"), selection: Binding(
                    get: { preferences.busyEnterMode }, set: { preferences.setBusyEnterMode($0) })) {
                    Text(NativeText("排队发送", "Queue")).tag("queue")
                    Text(NativeText("引导当前任务", "Steer")).tag("steer")
                }
                Picker(NativeText("性能与用量", "Performance and usage"), selection: Binding(
                    get: { preferences.performanceUsage }, set: { preferences.setPerformanceUsage($0) })) {
                    Text(NativeText("简洁", "Compact")).tag(NativePerformanceUsage.compact)
                    Text(NativeText("详细", "Detailed")).tag(NativePerformanceUsage.detailed)
                }
            } header: {
                Text(NativeText("发送与用量", "Sending and usage"))
            } footer: {
                Text(NativeText("排队发送会等当前任务结束再处理；引导会把新消息交给正在进行的任务。",
                                "Queue waits for the current task; steer hands the message to the running task."))
            }
        }
        .homeGroupedList()
        .navigationTitle(NativeText("工作过程", "Work details"))
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// 已归档会话: everything archived from the drawer, each restorable.
private struct ArchivedSessionsPage: View {
    @State private var management = DSHManagementModel.shared

    var body: some View {
        List {
            if management.archivedSessions.isEmpty {
                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(NativeText("没有已归档的会话", "No archived sessions"))
                            .font(.system(size: HomeSpec.bodySize))
                            .foregroundStyle(HomeSpec.textPrimary)
                        Text(NativeText("在侧边栏长按会话选「归档」，会话会收到这里，随时可以恢复。",
                                        "Long-press a session in the drawer and choose Archive; restore it here any time."))
                            .font(.system(size: 14))
                            .foregroundStyle(HomeSpec.textPlaceholder)
                    }
                    .padding(.vertical, 6)
                }
            } else {
                Section {
                    ForEach(management.archivedSessions) { session in
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(DrawerTitles.sessionTitle(session.title, index: 1))
                                    .font(.system(size: HomeSpec.bodySize))
                                    .foregroundStyle(HomeSpec.textPrimary)
                                    .lineLimit(1)
                                Text(SessionTime.relative(session.updatedAt))
                                    .font(.system(size: 13))
                                    .foregroundStyle(HomeSpec.textPlaceholder)
                            }
                            Spacer(minLength: 8)
                            Button(NativeText("恢复", "Restore")) {
                                Task { await management.unarchive(session) }
                            }
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(HomeSpec.textPrimary)
                            .buttonStyle(.borderless)
                        }
                        .frame(minHeight: 44)
                    }
                } footer: {
                    Text(NativeText("恢复后，会话回到原来的文件夹。", "Restored sessions return to their folder."))
                }
            }
        }
        .homeGroupedList()
        .navigationTitle(NativeText("已归档会话", "Archived sessions"))
        .navigationBarTitleDisplayMode(.inline)
        .task { await management.refresh() }
    }
}

func nativePermissionModeTitle(id: String, fallback: String? = nil) -> String {
    switch id {
    case "read-only", "phone-read-only": NativeText("仅可查看", "Read only")
    case "workspace-write", "phone": NativeText("工作区内修改", "Workspace write")
    case "danger-full-access", "bypassPermissions": NativeText("完全权限", "Full access")
    default: fallback ?? AccessModeWording.title(for: id) ?? id
    }
}

private struct PermissionDefaultsPage: View {
    @State private var model = NativeConfigurationModel.shared

    var body: some View {
        List {
            Section(NativeText("只影响之后新开的会话，当前会话保持不变。", "Only new sessions use this default; the current session is unchanged.")) {
                ForEach(model.defaultPermissionModes) { mode in
                    Button {
                        Task { _ = await model.setDefaultPermissionMode(mode.id) }
                    } label: {
                        HStack {
                            Text(nativePermissionModeTitle(id: mode.id, fallback: mode.name))
                            Spacer()
                            if model.defaultPermissionMode == mode.id {
                                Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
                            }
                        }
                    }
                }
            }
            if let error = model.error {
                Section { Text(nativeConfigurationError(error)).foregroundStyle(.red) }
            }
        }
        .homeGroupedList()
        .navigationTitle(NativeText("新会话默认权限", "Default permission"))
        .task { await model.refresh() }
    }
}

private struct LicensesPage: View {
    var body: some View {
        List {
            LabeledContent("SwiftTerm", value: "MIT")
            LabeledContent("swift-nio", value: "Apache 2.0")
        }
        .homeGroupedList()
        .navigationTitle(NativeText("开源许可", "Open-source licenses"))
    }
}

func makeFontSizeSettingsView() -> some View { FontSizeSettingsPage() }
func makeConversationSettingsView() -> some View { ConversationSettingsPage() }
func makeArchivedSessionsView() -> some View { ArchivedSessionsPage() }
func makePermissionDefaultsView() -> some View { PermissionDefaultsPage() }
func makeLicensesView() -> some View { LicensesPage() }
