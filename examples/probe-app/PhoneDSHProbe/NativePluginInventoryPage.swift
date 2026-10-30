// SPDX-License-Identifier: MIT

import SwiftUI

struct NativePluginInventoryPage: View {
    @State private var model = NativeConfigurationModel.shared
    @State private var query = ""

    private var filtered: [NativePluginEntry] {
        guard !query.isEmpty else { return model.pluginEntries }
        return model.pluginEntries.filter {
            $0.module.localizedCaseInsensitiveContains(query) || $0.id.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        List {
            Section {
                NavigationLink { NativeConfigurationPage() } label: {
                    Label(NativeText("插件配置", "Plugin configuration"), systemImage: "slider.horizontal.3")
                }
                Text(NativeText("清单只读；修改官方插件、网页搜索和执行器配置请进入插件配置。", "The inventory is read-only. Edit official plugins, web search and executors in Plugin configuration."))
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section(NativeText("插件列表", "Inventory")) {
                if model.isLoading && model.pluginEntries.isEmpty {
                    ProgressView(NativeText("正在读取插件…", "Loading plugins…"))
                } else if filtered.isEmpty {
                    Text(NativeText("没有匹配的插件。", "No matching plugins."))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(filtered) { plugin in
                        DisclosureGroup {
                            LabeledContent(NativeText("条目", "Entry"), value: plugin.id)
                            LabeledContent(NativeText("模块", "Module"), value: plugin.module)
                            LabeledContent(NativeText("启用", "Enabled"), value: plugin.enabled ? NativeText("是", "Yes") : NativeText("否", "No"))
                            if let phase = plugin.phase {
                                LabeledContent(NativeText("运行状态", "Phase"), value: phase)
                            }
                        } label: {
                            HStack {
                                Circle()
                                    .fill(plugin.enabled && plugin.phase == "active" ? Color.green : Color.secondary)
                                    .frame(width: 7, height: 7)
                                Text(plugin.module)
                                    .lineLimit(2)
                            }
                        }
                    }
                }
            }
            if let error = model.inventoryError ?? model.error {
                Section { Text(nativeConfigurationError(error)).foregroundStyle(.red) }
            }
            Section {
                Text(nativePluginManagementMessage("This iPhone Worker has no pnpm, execa or subprocess installation environment. Plugins and bundles can be viewed here; install, enable and disable them in desktop DSH."))
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle(NativeText("内置插件", "Built-in Plugins"))
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, prompt: NativeText("搜索插件", "Search plugins"))
        .refreshable { await model.refresh() }
        .task { await model.refresh() }
    }
}
