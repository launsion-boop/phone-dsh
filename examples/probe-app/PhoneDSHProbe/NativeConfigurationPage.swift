// SPDX-License-Identifier: MIT
// Native counterpart to DSH Web's Plugins page, backed by DSH Remote.

import SwiftUI

struct NativeConfigurationPage: View {
    /// 插件与工具 when pushed from settings or the chat menu; 发现 as a tab.
    var title: String = NativeText("插件与工具", "Plugins and Tools")
    /// Full-height sheet from the chat menu: 完成 trailing, the info and
    /// refresh buttons move to the leading side.
    var presentedAsSheet = false
    @Environment(\.dismiss) private var dismiss
    @State private var model = NativeConfigurationModel.shared
    @State private var showInformation = false

    var body: some View {
        // Pushed from 设置 › 插件与工具, or wrapped in a NavigationStack by
        // the sheets that present it: no stack of its own, so it never nests.
        List {
            if model.isLoading && model.pluginEntries.isEmpty && model.settingsGroups.isEmpty {
                Section {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text(NativeText("正在读取插件与设置…", "Loading plugins and settings…"))
                            .foregroundStyle(HomeSpec.textPlaceholder)
                    }
                }
            }
            if let error = model.error {
                Section {
                    Label(nativeConfigurationError(error), systemImage: "exclamationmark.triangle")
                        .font(.system(size: 14))
                        .foregroundStyle(NativeParityTokens.warning)
                }
            }
            builtInSettings
            experimentalPlugins
            installedPlugins
        }
        .homeGroupedList()
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if presentedAsSheet {
                ToolbarItem(placement: .confirmationAction) {
                    Button(NativeText("完成", "Done")) { dismiss() }
                        .fontWeight(.semibold)
                }
            }
            ToolbarItemGroup(placement: presentedAsSheet ? .topBarLeading : .topBarTrailing) {
                Button {
                    showInformation = true
                } label: {
                    Image(systemName: "info.circle")
                }
                .accessibilityLabel(NativeText("插件说明", "About Plugins"))
                Button {
                    Task { await model.refresh() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(model.isLoading || model.hasDrafts)
                .accessibilityLabel(NativeText("刷新", "Refresh"))
            }
        }
        .sheet(isPresented: $showInformation) {
            NavigationStack {
                List {
                    Section(NativeText("本机管理范围", "Local management scope")) {
                        Text(NativeText("这一页显示引擎里真正装着的插件。保存后马上生效。", "This page shows the plugins actually installed in the engine. Saved changes take effect immediately."))
                    }
                    Section(NativeText("iPhone Worker 限制", "iPhone Worker limitations")) {
                        Text(nativePluginManagementMessage("This iPhone Worker has no pnpm, execa or subprocess installation environment. Plugins and bundles can be viewed here; install, enable and disable them in desktop DSH."))
                        Text(NativeText("只有真正加载起来的插件才会显示为已启用。没装的,这里不会假装它在跑。", "Only plugins that are actually loaded appear as enabled. Plugins that are not installed are never shown as running."))
                    }
                }
                .homeGroupedList()
                .navigationTitle(NativeText("插件说明", "About Plugins"))
                .navigationBarTitleDisplayMode(.inline)
            }
            .presentationDetents([.medium, .large])
            .homeSheetChrome()
        }
        .task { await model.refresh() }

    }

    // MARK: - Built-in settings: one section per group

    @ViewBuilder
    private var builtInSettings: some View {
        if let group = model.group("subagent") {
            settingsGroup(group)
        } else {
            unavailableSection(NativeText("子 Agent", "Subagents"), detail: model.settingsError ?? NativeText("这台主机不支持调整子代理。", "This host does not support changing subagent settings."))
        }

        if let group = model.group("subagent-model-selection-settings") {
            subagentModelGroup(group)
        } else {
            unavailableSection(NativeText("子 Agent 模型", "Subagent Models"), detail: model.settingsError ?? NativeText("这台主机不支持为子代理指定模型。", "This host does not support selecting models for subagents."))
        }

        if let group = model.group("agent-loop") {
            settingsGroup(group)
        } else {
            unavailableSection(NativeText("自动执行轮次", "Automatic Execution"), detail: model.settingsError ?? NativeText("这台主机不支持调整自动执行的轮次。", "This host does not support changing automatic execution limits."))
        }

        if let group = model.group("bash-sandbox") {
            settingsGroup(group)
        } else {
            unavailableSection(NativeText("终端", "Terminal"), detail: model.settingsError ?? NativeText("这台主机不支持调整终端设置。", "This host does not support changing terminal settings."))
        }

        Section {
            NavigationLink {
                WebSearchSettingsPage()
            } label: {
                SettingsRowLabel(title: NativeText("网页搜索与抓取", "Web Search and Fetch"), icon: "globe")
            }
        } header: {
            Text(NativeText("工具", "Tools"))
        }

        defaultPermissionSetting
    }

    /// A settings group as its own section: one row per field, the group's
    /// description and any save error in the footer, 保存 / 撤销 only once
    /// something changed.
    private func settingsGroup(_ group: NativeSettingsGroup) -> some View {
        Section {
            ForEach(group.fields.filter { $0.id != "allowedModels" }) { field in
                settingField(field, namespace: group.namespace, writable: group.writable)
            }
            if model.isDirty(group.namespace) {
                saveRow(save: { Task { _ = await model.save(group.namespace) } },
                        discard: { model.discard(group.namespace) },
                        canSave: group.writable)
            }
        } header: {
            Text(nativeSettingsGroupTitle(group))
        } footer: {
            groupFooter(nativeSettingsGroupDetail(group), error: model.namespaceErrors[group.namespace])
        }
    }

    private func subagentModelGroup(_ group: NativeSettingsGroup) -> some View {
        Section {
            if let enabled = group.fields.first(where: { $0.id == "enabled" }) {
                settingField(enabled, namespace: group.namespace, writable: group.writable)
            }
            if model.modelCatalogError != nil {
                Text(NativeText("暂时读不到模型列表。", "The model list is temporarily unavailable."))
                    .foregroundStyle(NativeParityTokens.warning)
            } else if model.modelRoutes.isEmpty {
                Text(NativeText("没有可给子任务用的模型。", "No models are available for subtasks."))
                    .foregroundStyle(HomeSpec.textPlaceholder)
            } else {
                ForEach(model.modelRoutes) { route in
                    Toggle(isOn: Binding(
                        get: { model.activeSubagentModels().contains(route.id) },
                        set: { model.setSubagentModel(route, enabled: $0) }
                    )) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(route.available ? route.modelName : String(format: NativeText("%@ · 当前不可用", "%@ · Currently unavailable"), route.modelName))
                            Text("\(route.providerName) · \(route.model)")
                                .font(.system(size: 13))
                                .foregroundStyle(HomeSpec.textPlaceholder)
                        }
                    }
                    .disabled(!group.writable)
                }
            }
            if model.isDirty(group.namespace) {
                saveRow(save: { Task { _ = await model.save(group.namespace) } },
                        discard: { model.discard(group.namespace) },
                        canSave: group.writable)
            }
        } header: {
            Text(nativeSettingsGroupTitle(group))
        } footer: {
            groupFooter(NativeText("只影响之后新开的子任务,已经在跑的不变。", "Only new subtasks are affected; running subtasks are unchanged."),
                        error: model.namespaceErrors[group.namespace])
        }
    }

    @ViewBuilder
    private func settingField(_ field: NativeSettingsField, namespace: String, writable: Bool) -> some View {
        switch field.kind {
        case .toggle:
            Toggle(isOn: Binding(
                get: { model.fields(in: namespace).first(where: { $0.id == field.id })?.value.boolValue ?? false },
                set: { model.edit(field, in: namespace, value: $0) }
            )) {
                fieldLabel(field)
            }
            .disabled(!writable)
        case .number, .text:
            HStack(spacing: 12) {
                fieldLabel(field)
                Spacer(minLength: 8)
                TextField("", text: Binding(
                    get: { model.fields(in: namespace).first(where: { $0.id == field.id })?.inputText ?? field.inputText },
                    set: { model.edit(field, in: namespace, text: $0) }
                ))
                .keyboardType(field.kind == .number ? .numberPad : .default)
                .multilineTextAlignment(.trailing)
                .foregroundStyle(HomeSpec.textSecondary)
                .frame(maxWidth: 120)
                .disabled(!writable)
            }
        case .readOnly:
            LabeledContent(nativeSettingsFieldTitle(field), value: field.inputText)
        }
        if field.overridden {
            HStack {
                Text(NativeText("已改成你自己的值", "Using your custom value"))
                    .font(.system(size: 14))
                    .foregroundStyle(HomeSpec.textPlaceholder)
                Spacer()
                Button(NativeText("恢复默认", "Reset")) { Task { _ = await model.reset(field, in: namespace) } }
                    .font(.system(size: 14, weight: .medium))
                    .buttonStyle(.borderless)
                    .disabled(!writable || model.isDirty(namespace))
            }
        }
    }

    private func fieldLabel(_ field: NativeSettingsField) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(nativeSettingsFieldTitle(field))
            if let detail = field.detail {
                Text(detail)
                    .font(.system(size: 13))
                    .foregroundStyle(HomeSpec.textPlaceholder)
            }
        }
    }

    /// 撤销 on the left in gray, 保存 on the right in semibold ink.
    private func saveRow(save: @escaping () -> Void, discard: @escaping () -> Void, canSave: Bool) -> some View {
        HStack {
            Button(NativeText("撤销", "Discard"), action: discard)
                .foregroundStyle(HomeSpec.textSecondary)
            Spacer()
            Button(NativeText("保存", "Save"), action: save)
                .fontWeight(.semibold)
                .disabled(!canSave)
        }
        .buttonStyle(.borderless)
    }

    @ViewBuilder
    private func groupFooter(_ detail: String, error: String?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(detail)
            if let error {
                Text(nativeConfigurationError(error)).foregroundStyle(ChatPage.danger)
            }
        }
    }

    private var defaultPermissionSetting: some View {
        Section {
            if model.permissionCatalogError != nil {
                Text(NativeText("没能读到权限列表。", "The permission list could not be loaded."))
                    .foregroundStyle(NativeParityTokens.warning)
            } else if model.defaultPermissionModes.isEmpty {
                Text(NativeText("没有可选的权限预设。", "No permission presets are available."))
                    .foregroundStyle(HomeSpec.textPlaceholder)
            } else {
                Picker(NativeText("默认权限", "Default permission"), selection: Binding(
                    get: { model.stagedDefaultPermissionMode },
                    set: { model.stageDefaultPermissionMode($0) }
                )) {
                    ForEach(model.defaultPermissionModes, id: \.id) { mode in
                        Text(nativePermissionModeTitle(id: mode.id, fallback: mode.name)).tag(mode.id)
                    }
                }
                .disabled(!model.settingsWritable || !model.canEditDefaultPermission)
                if model.hasDefaultPermissionDraft {
                    saveRow(save: { Task { _ = await model.saveDefaultPermissionMode() } },
                            discard: { model.discardDefaultPermissionMode() },
                            canSave: model.settingsWritable)
                }
            }
        } header: {
            Text(NativeText("新会话默认权限", "Default Permission for New Sessions"))
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                if let current = model.defaultPermissionMode,
                   let detail = model.defaultPermissionDescription(current) {
                    Text(detail)
                }
                if !model.canEditDefaultPermission {
                    Text(nativeConfigurationError(model.defaultPermissionReadOnlyReason))
                }
                Text(NativeText("只影响之后新开的会话。正在聊的这个,权限在输入框里的盾牌菜单里改。", "Only new sessions are affected. Change the current session's permission from the shield menu in the composer."))
                if let error = model.namespaceErrors["permission"] {
                    Text(nativeConfigurationError(error)).foregroundStyle(ChatPage.danger)
                }
            }
        }
    }

    // MARK: - Plugins

    private var experimentalPlugins: some View {
        Section {
            ForEach(model.experimentalPlugins) { plugin in
                let title = nativeExperimentalPluginTitle(plugin)
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                        Text(nativeExperimentalPluginStatus(plugin))
                            .font(.system(size: 13))
                            .foregroundStyle(HomeSpec.textPlaceholder)
                    }
                    Spacer(minLength: 8)
                    HomeTag(text: plugin.loaded ? NativeText("已加载", "Loaded") : NativeText("未加载", "Not loaded"))
                }
                .accessibilityElement(children: .combine)
            }
        } header: {
            Text(NativeText("实验插件", "Experimental Plugins"))
        } footer: {
            Text(nativePluginManagementMessage("This iPhone Worker has no pnpm, execa or subprocess installation environment. Plugins and bundles can be viewed here; install, enable and disable them in desktop DSH."))
        }
    }

    private var installedPlugins: some View {
        Section {
            if model.inventoryError != nil {
                Text(NativeText("暂时读不到插件状态。", "Plugin status is temporarily unavailable."))
                    .foregroundStyle(NativeParityTokens.warning)
            } else {
                NavigationLink {
                    NativePluginInventoryPage()
                } label: {
                    SettingsRowLabel(title: NativeText("已加载插件", "Loaded Plugins"), icon: "puzzlepiece.extension",
                                     value: model.pluginEntries.isEmpty ? nil : "\(model.pluginEntries.count)")
                }
            }
        } footer: {
            Text(NativeText("显示的是引擎里真实加载的插件,手机上不会另外记一份。", "Shows the plugins the engine actually loaded; nothing is stored separately on the phone."))
        }
    }

    private func unavailableSection(_ title: String, detail: String) -> some View {
        Section {
            Text(NativeText("暂不可用", "Unavailable"))
                .foregroundStyle(HomeSpec.textPlaceholder)
        } header: {
            Text(title)
        } footer: {
            Text(detail)
        }
    }
}

private func nativeSettingsGroupTitle(_ group: NativeSettingsGroup) -> String {
    switch group.namespace {
    case "subagent": NativeText("子 Agent", "Subagents")
    case "subagent-model-selection-settings": NativeText("子 Agent 模型", "Subagent Models")
    case "agent-loop": NativeText("Agent 循环", "Agent Loop")
    case "bash-sandbox": NativeText("终端", "Terminal")
    default: group.title
    }
}

private func nativeSettingsGroupDetail(_ group: NativeSettingsGroup) -> String {
    switch group.namespace {
    case "subagent": NativeText("控制 DSH 子 Agent 的递归深度和并发容量。", "Control recursion depth and concurrency for DSH subagents.")
    case "subagent-model-selection-settings": NativeText("设置子 Agent 可使用的模型路由。", "Choose the model routes available to subagents.")
    case "agent-loop": NativeText("限制单步并行执行的安全工具调用数。", "Limit parallel safe tool calls within one step.")
    case "bash-sandbox": NativeText("调整 DSH Bash 执行器的时限和输出预算。", "Adjust command timeout and output budget for the DSH Bash executor.")
    default: group.detail
    }
}

private func nativeSettingsFieldTitle(_ field: NativeSettingsField) -> String {
    switch field.id {
    case "maxDepth": NativeText("最大递归层级", "Maximum recursion depth")
    case "maxActiveSubagents": NativeText("最大并发子 Agent", "Maximum concurrent subagents")
    case "enabled": NativeText("允许子 Agent 选择模型", "Allow subagents to select models")
    case "allowedModels": NativeText("允许的子 Agent 模型", "Allowed subagent models")
    case "maxParallelToolCalls": NativeText("并行工具调用上限", "Parallel tool call limit")
    case "timeoutMs": NativeText("单条命令时限（毫秒）", "Command timeout (ms)")
    case "maxOutputBytes": NativeText("每路输出上限（字节）", "Output limit per stream (bytes)")
    default: field.title
    }
}

private func nativeExperimentalPluginTitle(_ plugin: NativeExperimentalPlugin) -> String {
    switch plugin.id {
    case "agent-team": NativeText("智能体团队", "Agent Team")
    case "voice-input": NativeText("语音输入", "Voice Input")
    case "auto-review": NativeText("自动授权审查", "Automatic Permission Review")
    case "developer-tools": NativeText("开发者工具", "Developer Tools")
    default: plugin.title
    }
}

private func nativeExperimentalPluginStatus(_ plugin: NativeExperimentalPlugin) -> String {
    guard plugin.loaded else {
        return NativeText("Worker 未加载；安装/启用不能从此 iPhone 页面执行。", "Not loaded by Worker; this iPhone page cannot install or enable it.")
    }
    let phase = plugin.status.components(separatedBy: " · ").last ?? "active"
    return String(format: NativeText("Worker 当前已加载 · %@", "Loaded by Worker · %@"), phase)
}

func nativeConfigurationError(_ error: String) -> String {
    switch error {
    case "请先保存或撤销未提交的设置，再刷新。":
        NativeText(error, "Save or discard your pending settings before refreshing.")
    case "请先启动 DSH 主机，再读取插件和设置。":
        NativeText(error, "Start the DSH host before loading plugins and settings.")
    case "请修正无效的设置值后再保存。":
        NativeText(error, "Correct the invalid setting values before saving.")
    case "DSH 未提供可写的未来会话权限默认值。":
        NativeText(error, "DSH does not provide a writable default permission for future sessions.")
    default: error
    }
}
