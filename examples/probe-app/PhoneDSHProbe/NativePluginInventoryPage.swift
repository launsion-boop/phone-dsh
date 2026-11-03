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
                if let error = model.inventoryError ?? model.error {
                    Label(NativeText("需配置/读取失败", "Configuration or read failure"),
                          systemImage: "exclamationmark.triangle")
                    Text(nativeConfigurationError(error))
                        .font(.system(size: 13))
                        .foregroundStyle(NativeParityTokens.warning)
                }
                if model.isLoading && model.pluginEntries.isEmpty {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text(NativeText("正在读取插件…", "Loading plugins…"))
                            .foregroundStyle(HomeSpec.textPlaceholder)
                    }
                } else if filtered.isEmpty {
                    Text(query.isEmpty
                         ? NativeText("需桌面安装/当前 Worker 不可用", "Desktop installation or current Worker unavailable")
                         : NativeText("没有匹配的插件。", "No matching plugins."))
                        .foregroundStyle(HomeSpec.textPlaceholder)
                } else {
                    ForEach(filtered) { plugin in
                        DisclosureGroup {
                            LabeledContent(NativeText("条目", "Entry"), value: plugin.id)
                            LabeledContent(NativeText("模块", "Module"), value: plugin.module)
                            if let phase = plugin.phase {
                                LabeledContent(NativeText("运行状态", "Phase"), value: phase)
                            }
                        } label: {
                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(plugin.module)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                    Text(plugin.id)
                                        .font(.system(size: 13))
                                        .foregroundStyle(HomeSpec.textPlaceholder)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                                Spacer(minLength: 8)
                                HomeTag(text: plugin.enabled && plugin.phase == "active"
                                        ? NativeText("运行中", "Active")
                                        : (plugin.enabled ? NativeText("已启用", "Enabled") : NativeText("已停用", "Disabled")))
                            }
                        }
                    }
                }
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    if let error = model.inventoryError ?? model.error {
                        Text(nativeConfigurationError(error)).foregroundStyle(ChatPage.danger)
                    }
                    Text(nativePluginManagementMessage("This iPhone Worker has no pnpm, execa or subprocess installation environment. Plugins and bundles can be viewed here; install, enable and disable them in desktop DSH."))
                }
            }
        }
        .homeGroupedList()
        .navigationTitle(NativeText("已加载插件", "Loaded Plugins"))
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, prompt: NativeText("搜索插件", "Search plugins"))
        .refreshable { await model.refresh() }
        .task { await model.refresh() }
    }
}
