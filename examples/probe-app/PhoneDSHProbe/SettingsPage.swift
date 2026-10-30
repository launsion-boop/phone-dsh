// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — official settings information architecture.

import PhoneDSH
import ProbeKit
import SwiftUI

enum NativeSettingsTab: String, CaseIterable, Identifiable {
    case general, models, plugins, presets

    var id: String { rawValue }
    var title: String {
        switch self {
        case .general: NativeText("通用设置", "General")
        case .models: NativeText("模型", "Models")
        case .plugins: NativeText("内置插件", "Built-in Plugins")
        case .presets: NativeText("Agent 预设", "Agent Presets")
        }
    }
    var shortTitle: String {
        switch self {
        case .general: NativeText("通用", "General")
        case .models: NativeText("模型", "Models")
        case .plugins: NativeText("插件", "Plugins")
        case .presets: NativeText("预设", "Presets")
        }
    }
    var icon: String {
        switch self {
        case .general: "gearshape"
        case .models: "cylinder"
        case .plugins: "slider.horizontal.3"
        case .presets: "person.2"
        }
    }
}

struct SettingsPage: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var tab: NativeSettingsTab? = .general
    @State private var showDocument = false

    var body: some View {
        Group {
            if horizontalSizeClass == .regular {
                NavigationSplitView {
                    List(selection: $tab) {
                        ForEach(NativeSettingsTab.allCases) { item in
                            NavigationLink(value: item) { Label(item.title, systemImage: item.icon).tag(item) }
                        }
                    }
                    .navigationTitle(NativeText("设置", "Settings"))
                } detail: {
                    content
                }
            } else {
                VStack(spacing: 0) {
                    Picker(NativeText("设置分区", "Section"), selection: $tab) {
                        ForEach(NativeSettingsTab.allCases) { item in Text(item.shortTitle).tag(item) }
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    content
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button(NativeText("配置文件", "Config")) { showDocument = true }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button(NativeText("完成", "Done")) { dismiss() }
            }
        }
        .sheet(isPresented: $showDocument) {
            NavigationStack { NativeSettingsDocumentPage() }
        }
    }

    @ViewBuilder private var content: some View {
        switch tab ?? .general {
        case .general: NativeGeneralSettingsPage()
        case .models: ModelProviderSettingsPage()
        case .plugins: NativePluginInventoryPage()
        case .presets: NativeAgentPresetsPage()
        }
    }
}

private struct NativeGeneralSettingsPage: View {
    @State private var preferences = NativeChatPreferences.shared
    @State private var configuration = NativeConfigurationModel.shared
    @StateObject private var phonePermissions = PhonePermissionRequester.shared

    var body: some View {
        List {
            Section {
                NavigationLink { PermissionDefaultsPage() } label: {
                    LabeledContent(NativeText("权限", "Permission"), value: permissionTitle)
                }
                Text(NativeText("选择新会话的默认权限模式", "Default permission for new sessions"))
                    .font(.footnote).foregroundStyle(.secondary)
                NavigationLink { PhonePermissionsPage() } label: {
                    LabeledContent(NativeText("手机权限", "Phone permissions"), value: phonePermissionSummary)
                }
            }

            Section {
                Picker(NativeText("语言", "Language"), selection: Binding(
                    get: { preferences.language }, set: { preferences.setLanguage($0) })) {
                    Text("中文").tag(NativeLocalePreference.zh)
                    Text("English").tag(NativeLocalePreference.en)
                    Text(NativeText("跟随系统", "System")).tag(NativeLocalePreference.system)
                }
                Picker(NativeText("外观", "Appearance"), selection: Binding(
                    get: { preferences.appearance }, set: { preferences.setAppearance($0) })) {
                    Text(NativeText("浅色", "Light")).tag(NativeAppearance.light)
                    Text(NativeText("深色", "Dark")).tag(NativeAppearance.dark)
                    Text(NativeText("跟随系统", "System")).tag(NativeAppearance.system)
                }
                DisclosureGroup(NativeText("字号大小", "Font size")) {
                    fontSizeRow(.text, NativeText("会话内容", "Conversation"))
                    fontSizeRow(.code, NativeText("代码", "Code"))
                    fontSizeRow(.terminal, NativeText("终端", "Terminal"))
                }
                Text(NativeText("仅影响会话内容、代码和终端的字号", "Font size for conversation, code and terminal"))
                    .font(.footnote).foregroundStyle(.secondary)
            }

            Section {
                Picker(NativeText("工作步骤展示", "Work details"), selection: Binding(
                    get: { preferences.transcriptView }, set: { preferences.setTranscriptView($0) })) {
                    Text(NativeText("简洁", "Compact")).tag(NativeTranscriptViewMode.compact)
                    Text(NativeText("标准", "Standard")).tag(NativeTranscriptViewMode.standard)
                    Text(NativeText("详细", "Detailed")).tag(NativeTranscriptViewMode.detailed)
                    Text(NativeText("完全展开", "Verbose")).tag(NativeTranscriptViewMode.verbose)
                }
                Picker(NativeText("工作步骤收起时机", "Collapse completed work"), selection: Binding(
                    get: { preferences.collapseTiming }, set: { preferences.setCollapseTiming($0) })) {
                    Text(NativeText("回答结束后", "After completion")).tag(NativeCollapseTiming.completion)
                    Text(NativeText("下次有新消息时", "With the next input")).tag(NativeCollapseTiming.nextInput)
                }
                Toggle(NativeText("显示代码工作视图", "Show code work"), isOn: Binding(
                    get: { preferences.developerTools }, set: { preferences.setDeveloperTools($0) }))
                NavigationLink { NativeShortcutsPage() } label: {
                    LabeledContent(NativeText("快捷键", "Shortcuts"), value: NativeText("编辑", "Edit"))
                }
            }

            Section {
                Picker(NativeText("繁忙时的发送行为", "While the agent is busy"), selection: Binding(
                    get: { preferences.busyEnterMode }, set: { preferences.setBusyEnterMode($0) })) {
                    Text(NativeText("排队发送", "Queue")).tag("queue")
                    Text(NativeText("引导智能体", "Steer")).tag("steer")
                }
                Picker(NativeText("性能与用量", "Performance and usage"), selection: Binding(
                    get: { preferences.performanceUsage }, set: { preferences.setPerformanceUsage($0) })) {
                    Text(NativeText("简洁", "Compact")).tag(NativePerformanceUsage.compact)
                    Text(NativeText("详细", "Detailed")).tag(NativePerformanceUsage.detailed)
                }
            }

            Section {
                LabeledContent(NativeText("当前版本", "Version"), value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—")
                NavigationLink { LicensesPage() } label: { Text(NativeText("开源许可", "Open-source licenses")) }
            }
        }
        .navigationTitle(NativeText("通用设置", "General"))
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await configuration.refresh()
            await phonePermissions.refresh()
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

    @ViewBuilder private func fontSizeRow(_ role: NativeFontRole, _ title: String) -> some View {
        let size = preferences.fontSize(for: role)
        Stepper(value: Binding(get: { size }, set: { preferences.setFontSize(role, $0) }),
                in: role.sizeRange) {
            LabeledContent(title, value: "\(size) px")
        }
        TextField(NativeText("字体（留空使用系统默认）", "Font family (system default)"), text: Binding(
            get: { preferences.fontFamily(for: role) },
            set: { preferences.setFontFamily(role, $0) }))
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
        if let missing = preferences.fontFamilyError(for: role) {
            Text(String(format: NativeText("未安装字体 %@，将使用系统回退字体", "Font %@ is unavailable; system fallback will be used"), missing))
                .font(.caption).foregroundStyle(.orange)
        }
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
        .navigationTitle(NativeText("开源许可", "Open-source licenses"))
    }
}
