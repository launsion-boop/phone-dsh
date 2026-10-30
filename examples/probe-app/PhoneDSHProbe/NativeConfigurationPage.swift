// SPDX-License-Identifier: MIT
// Native counterpart to DSH Web's Plugins page, backed by DSH Remote.

import SwiftUI

struct NativeConfigurationPage: View {
    @Environment(\.dismiss) private var dismiss
    @State private var model = NativeConfigurationModel.shared
    @State private var showInformation = false

    var body: some View {
        NavigationStack {
            List {
                pageHeader
                if let error = model.error {
                    Section {
                        Label(nativeConfigurationError(error), systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                }
                builtInSettings
                experimentalPlugins
                installedPlugins
            }
            .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Color.white)
            .navigationTitle(NativeText("插件", "Plugins"))
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(NativeText("完成", "Done")) { dismiss() }.trailingBarText()
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
                    .navigationTitle(NativeText("插件说明", "About Plugins"))
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button(NativeText("完成", "Done")) { showInformation = false }.trailingBarText()
                        }
                    }
                }
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
            }
            .task { await model.refresh() }
        }
    }

    private var pageHeader: some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                Text(NativeText("安装、启用和配置插件", "Install, enable and configure plugins"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                HStack(spacing: 10) {
                    Button {
                        showInformation = true
                    } label: {
                        Label(NativeText("插件说明", "About Plugins"), systemImage: "info.circle")
                    }
                    .buttonStyle(.bordered)
                    .accessibilityHint(NativeText("查看 DSH 插件管理在 iPhone 上的支持范围", "View DSH plugin management support on iPhone"))

                    Button {
                        Task { await model.refresh() }
                    } label: {
                        Label(NativeText("刷新", "Refresh"), systemImage: model.isLoading ? "arrow.trianglehead.2.clockwise.rotate.90" : "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)
                    .disabled(model.isLoading || model.hasDrafts)

                    Menu {
                        Button(NativeText("安装第三方插件", "Install Third-party Plugin")) {}
                            .disabled(true)
                        Button(NativeText("让 Agent 创建插件", "Create a Plugin with Agent")) {}
                            .disabled(true)
                    } label: {
                        Label(NativeText("添加插件", "Add Plugin"), systemImage: "plus")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(true)
                    .accessibilityHint(nativePluginManagementMessage("This iPhone Worker has no pnpm, execa or subprocess installation environment. Plugins and bundles can be viewed here; install, enable and disable them in desktop DSH."))
                }
                if model.isLoading && model.pluginEntries.isEmpty && model.settingsGroups.isEmpty {
                    ProgressView(NativeText("读取 DSH 插件与设置…", "Loading DSH plugins and settings…"))
                        .font(.footnote)
                }
            }
            .padding(.vertical, 4)
        }
    }

    private var builtInSettings: some View {
        Section(NativeText("内置插件设置", "Built-in Plugin Settings")) {
            if let group = model.group("subagent") {
                settingsGroup(group)
            } else {
                unavailableRow(NativeText("子 Agent", "Subagents"), detail: model.settingsError ?? NativeText("这台主机不支持调整子代理。", "This host does not support changing subagent settings."))
            }

            if let group = model.group("subagent-model-selection-settings") {
                subagentModelGroup(group)
            } else {
                unavailableRow(NativeText("子 Agent 模型", "Subagent Models"), detail: model.settingsError ?? NativeText("这台主机不支持为子代理指定模型。", "This host does not support selecting models for subagents."))
            }

            if let group = model.group("agent-loop") {
                settingsGroup(group)
            } else {
                unavailableRow(NativeText("自动执行轮次", "Automatic Execution"), detail: model.settingsError ?? NativeText("这台主机不支持调整自动执行的轮次。", "This host does not support changing automatic execution limits."))
            }

            if let group = model.group("bash-sandbox") {
                settingsGroup(group)
            } else {
                unavailableRow(NativeText("终端", "Terminal"), detail: model.settingsError ?? NativeText("这台主机不支持调整终端设置。", "This host does not support changing terminal settings."))
            }

            NavigationLink {
                WebSearchSettingsPage()
            } label: {
                Label(NativeText("网页搜索与抓取", "Web Search and Fetch"), systemImage: "globe")
            }
            defaultPermissionSetting
        }
    }

    private func settingsGroup(_ group: NativeSettingsGroup) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(nativeSettingsGroupTitle(group)).font(.headline)
            Text(nativeSettingsGroupDetail(group)).font(.caption).foregroundStyle(.secondary)
            ForEach(group.fields.filter { $0.id != "allowedModels" }) { field in
                settingField(field, namespace: group.namespace, writable: group.writable)
            }
            saveActions(namespace: group.namespace, writable: group.writable)
        }
        .padding(.vertical, 6)
    }

    private func subagentModelGroup(_ group: NativeSettingsGroup) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(nativeSettingsGroupTitle(group)).font(.headline)
            Text(NativeText("只影响之后新开的子任务,已经在跑的不变。", "Only new subtasks are affected; running subtasks are unchanged."))
                .font(.caption)
                .foregroundStyle(.secondary)
            if let enabled = group.fields.first(where: { $0.id == "enabled" }) {
                settingField(enabled, namespace: group.namespace, writable: group.writable)
            }
            if model.modelCatalogError != nil {
                Text(NativeText("暂时读不到模型列表。", "The model list is temporarily unavailable."))
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else if model.modelRoutes.isEmpty {
                Text(NativeText("没有可给子任务用的模型。", "No models are available for subtasks."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(model.modelRoutes) { route in
                    Toggle(isOn: Binding(
                        get: { model.activeSubagentModels().contains(route.id) },
                        set: { model.setSubagentModel(route, enabled: $0) }
                    )) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(route.available ? route.modelName : String(format: NativeText("%@ · 当前不可用", "%@ · Currently unavailable"), route.modelName))
                            Text("\(route.providerName) · \(route.model)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .disabled(!group.writable)
                }
            }
            saveActions(namespace: group.namespace, writable: group.writable)
        }
        .padding(.vertical, 6)
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
            TextField(nativeSettingsFieldTitle(field), text: Binding(
                get: { model.fields(in: namespace).first(where: { $0.id == field.id })?.inputText ?? field.inputText },
                set: { model.edit(field, in: namespace, text: $0) }
            ))
            .keyboardType(field.kind == .number ? .numberPad : .default)
            .disabled(!writable)
            .textFieldStyle(.roundedBorder)
            if let detail = field.detail {
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        case .readOnly:
            LabeledContent(nativeSettingsFieldTitle(field), value: field.inputText)
        }
        if field.overridden {
            HStack {
                Text(NativeText("已改成你自己的值", "Using your custom value")).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(NativeText("恢复默认", "Reset")) { Task { _ = await model.reset(field, in: namespace) } }
                    .font(.caption)
                    .disabled(!writable || model.isDirty(namespace))
            }
        }
    }

    private func fieldLabel(_ field: NativeSettingsField) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(nativeSettingsFieldTitle(field))
            if let detail = field.detail {
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func saveActions(namespace: String, writable: Bool) -> some View {
        HStack {
            Button(NativeText("保存", "Save")) { Task { _ = await model.save(namespace) } }
                .buttonStyle(.borderedProminent)
                .disabled(!writable || !model.isDirty(namespace))
            Button(NativeText("撤销", "Discard")) { model.discard(namespace) }
                .disabled(!model.isDirty(namespace))
            if let error = model.namespaceErrors[namespace] {
                Text(nativeConfigurationError(error)).font(.caption).foregroundStyle(.red)
            }
        }
    }

    private var defaultPermissionSetting: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(NativeText("新会话默认权限", "Default Permission for New Sessions")).font(.headline)
            Text(NativeText("只影响之后新开的会话。正在聊的这个,权限在输入框上方那个菜单里改。", "Only new sessions are affected. Change the current session's permission in the menu above the composer."))
                .font(.caption)
                .foregroundStyle(.secondary)
            if model.permissionCatalogError != nil {
                Text(NativeText("没能读到权限列表。", "The permission list could not be loaded."))
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else if model.defaultPermissionModes.isEmpty {
                Text(NativeText("没有可选的权限预设。", "No permission presets are available."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
                if let current = model.defaultPermissionMode,
                   let detail = model.defaultPermissionDescription(current) {
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Button(NativeText("保存默认", "Save Default")) { Task { _ = await model.saveDefaultPermissionMode() } }
                        .buttonStyle(.borderedProminent)
                        .disabled(!model.settingsWritable || !model.hasDefaultPermissionDraft)
                    Button(NativeText("撤销", "Discard")) { model.discardDefaultPermissionMode() }
                        .disabled(!model.hasDefaultPermissionDraft)
                    if let error = model.namespaceErrors["permission"] {
                        Text(nativeConfigurationError(error)).font(.caption).foregroundStyle(.red)
                    }
                }
            }
        }
        .padding(.vertical, 6)
    }

    private var experimentalPlugins: some View {
        Section {
            ForEach(model.experimentalPlugins) { plugin in
                let title = nativeExperimentalPluginTitle(plugin)
                let status = nativeExperimentalPluginStatus(plugin)
                HStack(spacing: 12) {
                    Image(systemName: plugin.loaded ? "checkmark.circle.fill" : "circle.dashed")
                        .foregroundStyle(plugin.loaded ? Color.green : Color.secondary)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(title)
                        Text(status)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Toggle(title, isOn: .constant(plugin.loaded))
                        .labelsHidden()
                        .disabled(true)
                        .accessibilityLabel(title)
                        .accessibilityHint(status)
                }
            }
            Text(nativePluginManagementMessage("This iPhone Worker has no pnpm, execa or subprocess installation environment. Plugins and bundles can be viewed here; install, enable and disable them in desktop DSH."))
                .font(.caption)
                .foregroundStyle(.secondary)
        } header: {
            Text(NativeText("实验插件", "Experimental Plugins"))
        } footer: {
            Text(NativeText("这里的开关显示的是引擎里的真实状态,手机上不会另外记一份。", "These switches show the engine's actual state; no separate state is stored on the phone."))
        }
    }

    private var installedPlugins: some View {
        Section(NativeText("已加载插件", "Loaded Plugins")) {
            if model.inventoryError != nil {
                Text(NativeText("暂时读不到插件状态。", "Plugin status is temporarily unavailable."))
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else if model.pluginEntries.isEmpty {
                Text(NativeText("引擎还没给出插件列表。", "The engine has not provided a plugin list yet."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                DisclosureGroup(String(format: NativeText("查看 %d 个 DSH Loader 条目", "View %d DSH Loader entries"), model.pluginEntries.count)) {
                    ForEach(model.pluginEntries) { plugin in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(plugin.module).font(.subheadline)
                            HStack {
                                Text(plugin.id).font(.caption2).foregroundStyle(.secondary)
                                Spacer()
                                Text(plugin.enabled ? (plugin.phase ?? "enabled") : "disabled")
                                    .font(.caption2)
                                    .foregroundStyle(plugin.enabled ? Color.green : Color.secondary)
                            }
                        }
                        .padding(.vertical, 3)
                    }
                }
            }
        }
    }

    private func unavailableRow(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: "exclamationmark.circle")
            Text(detail).font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
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
