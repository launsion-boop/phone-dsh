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
                        Label(error, systemImage: "exclamationmark.triangle.fill")
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
            .navigationTitle("插件")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }.trailingBarText()
                }
            }
            .sheet(isPresented: $showInformation) {
                NavigationStack {
                    List {
                        Section("本机管理范围") {
                            Text("这一页显示引擎里真正装着的插件。保存后马上生效。")
                        }
                        Section("iPhone Worker 限制") {
                            Text(model.pluginManagementMessage)
                            Text("只有真正加载起来的插件才会显示为已启用。没装的,这里不会假装它在跑。")
                        }
                    }
                    .navigationTitle("插件说明")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("完成") { showInformation = false }.trailingBarText()
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
                Text("安装、启用和配置插件")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                HStack(spacing: 10) {
                    Button {
                        showInformation = true
                    } label: {
                        Label("插件说明", systemImage: "info.circle")
                    }
                    .buttonStyle(.bordered)
                    .accessibilityHint("查看 DSH 插件管理在 iPhone 上的支持范围")

                    Button {
                        Task { await model.refresh() }
                    } label: {
                        Label("刷新", systemImage: model.isLoading ? "arrow.trianglehead.2.clockwise.rotate.90" : "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)
                    .disabled(model.isLoading || model.hasDrafts)

                    Menu {
                        Button("安装第三方插件") {}
                            .disabled(true)
                        Button("让 Agent 创建插件") {}
                            .disabled(true)
                    } label: {
                        Label("添加插件", systemImage: "plus")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(true)
                    .accessibilityHint(model.pluginManagementMessage)
                }
                if model.isLoading && model.pluginEntries.isEmpty && model.settingsGroups.isEmpty {
                    ProgressView("读取 DSH 插件与设置…")
                        .font(.footnote)
                }
            }
            .padding(.vertical, 4)
        }
    }

    private var builtInSettings: some View {
        Section("内置插件设置") {
            if let group = model.group("subagent") {
                settingsGroup(group)
            } else {
                unavailableRow("子 Agent", detail: model.settingsError ?? "这台主机不支持调整子代理。")
            }

            if let group = model.group("subagent-model-selection-settings") {
                subagentModelGroup(group)
            } else {
                unavailableRow("子 Agent 模型", detail: model.settingsError ?? "这台主机不支持为子代理指定模型。")
            }

            if let group = model.group("agent-loop") {
                settingsGroup(group)
            } else {
                unavailableRow("自动执行轮次", detail: model.settingsError ?? "这台主机不支持调整自动执行的轮次。")
            }

            if let group = model.group("bash-sandbox") {
                settingsGroup(group)
            } else {
                unavailableRow("终端", detail: model.settingsError ?? "这台主机不支持调整终端设置。")
            }

            NavigationLink {
                WebSearchSettingsPage(host: .native)
            } label: {
                Label("网页搜索与抓取", systemImage: "globe")
            }
            defaultPermissionSetting
        }
    }

    private func settingsGroup(_ group: NativeSettingsGroup) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(group.title).font(.headline)
            Text(group.detail).font(.caption).foregroundStyle(.secondary)
            ForEach(group.fields.filter { $0.id != "allowedModels" }) { field in
                settingField(field, namespace: group.namespace, writable: group.writable)
            }
            saveActions(namespace: group.namespace, writable: group.writable)
        }
        .padding(.vertical, 6)
    }

    private func subagentModelGroup(_ group: NativeSettingsGroup) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(group.title).font(.headline)
            Text("只影响之后新开的子任务,已经在跑的不变。")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let enabled = group.fields.first(where: { $0.id == "enabled" }) {
                settingField(enabled, namespace: group.namespace, writable: group.writable)
            }
            if model.modelCatalogError != nil {
                Text("暂时读不到模型列表。")
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else if model.modelRoutes.isEmpty {
                Text("没有可给子任务用的模型。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(model.modelRoutes) { route in
                    Toggle(isOn: Binding(
                        get: { model.activeSubagentModels().contains(route.id) },
                        set: { model.setSubagentModel(route, enabled: $0) }
                    )) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(route.available ? route.modelName : "\(route.modelName) · 当前不可用")
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
            TextField(field.title, text: Binding(
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
            LabeledContent(field.title, value: field.inputText)
        }
        if field.overridden {
            HStack {
                Text("已改成你自己的值").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("恢复默认") { Task { _ = await model.reset(field, in: namespace) } }
                    .font(.caption)
                    .disabled(!writable || model.isDirty(namespace))
            }
        }
    }

    private func fieldLabel(_ field: NativeSettingsField) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(field.title)
            if let detail = field.detail {
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func saveActions(namespace: String, writable: Bool) -> some View {
        HStack {
            Button("保存") { Task { _ = await model.save(namespace) } }
                .buttonStyle(.borderedProminent)
                .disabled(!writable || !model.isDirty(namespace))
            Button("撤销") { model.discard(namespace) }
                .disabled(!model.isDirty(namespace))
            if let error = model.namespaceErrors[namespace] {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
    }

    private var defaultPermissionSetting: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("新会话默认权限").font(.headline)
            Text("只影响之后新开的会话。正在聊的这个,权限在输入框上方那个菜单里改。")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let error = model.permissionCatalogError {
                Text("没能读到权限列表。")
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else if model.defaultPermissionModes.isEmpty {
                Text("没有可选的权限预设。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Picker("默认权限", selection: Binding(
                    get: { model.stagedDefaultPermissionMode },
                    set: { model.stageDefaultPermissionMode($0) }
                )) {
                    ForEach(model.defaultPermissionModes, id: \.id) { mode in
                        Text(mode.name).tag(mode.id)
                    }
                }
                .disabled(!model.settingsWritable || !model.canEditDefaultPermission)
                if let current = model.defaultPermissionMode,
                   let detail = model.defaultPermissionDescription(current) {
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Button("保存默认") { Task { _ = await model.saveDefaultPermissionMode() } }
                        .buttonStyle(.borderedProminent)
                        .disabled(!model.settingsWritable || !model.hasDefaultPermissionDraft)
                    Button("撤销") { model.discardDefaultPermissionMode() }
                        .disabled(!model.hasDefaultPermissionDraft)
                    if let error = model.namespaceErrors["permission"] {
                        Text(error).font(.caption).foregroundStyle(.red)
                    }
                }
            }
        }
        .padding(.vertical, 6)
    }

    private var experimentalPlugins: some View {
        Section {
            ForEach(model.experimentalPlugins) { plugin in
                HStack(spacing: 12) {
                    Image(systemName: plugin.loaded ? "checkmark.circle.fill" : "circle.dashed")
                        .foregroundStyle(plugin.loaded ? Color.green : Color.secondary)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(plugin.title)
                        Text(plugin.status)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Toggle(plugin.title, isOn: .constant(plugin.loaded))
                        .labelsHidden()
                        .disabled(true)
                        .accessibilityLabel(plugin.title)
                        .accessibilityHint(plugin.status)
                }
            }
            Text(model.pluginManagementMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
        } header: {
            Text("实验插件")
        } footer: {
            Text("这里的开关显示的是引擎里的真实状态,手机上不会另外记一份。")
        }
    }

    private var installedPlugins: some View {
        Section("已加载插件") {
            if model.inventoryError != nil {
                Text("暂时读不到插件状态。")
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else if model.pluginEntries.isEmpty {
                Text("引擎还没给出插件列表。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                DisclosureGroup("查看 \(model.pluginEntries.count) 个 DSH Loader 条目") {
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
