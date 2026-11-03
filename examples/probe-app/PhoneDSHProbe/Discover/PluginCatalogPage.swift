// SPDX-License-Identifier: MIT

import SwiftUI

struct PluginCatalogPage: View {
    let focus: String?

    var body: some View {
        List {
            Section {
                NavigationLink {
                    NativePluginInventoryPage()
                } label: {
                    SettingsRowLabel(title: NativeText("已加载插件", "Loaded plugins"), icon: "puzzlepiece.extension")
                }
                NavigationLink {
                    NativeConfigurationPage()
                } label: {
                    SettingsRowLabel(title: NativeText("可写设置", "Writable settings"), icon: "slider.horizontal.3")
                }
            } header: {
                Text(NativeText("真实运行状态", "Actual runtime state"))
            } footer: {
                Text(NativeText("状态只区分运行中、已启用、已停用、需配置/读取失败、需桌面安装/当前 Worker 不可用。启用不等于运行中。",
                                "States are active, enabled, disabled, configuration/read failure, or desktop installation/Worker unavailable. Enabled does not mean active."))
            }
            if focus != nil {
                Section {
                    Text(NativeText("已保留插件深链；请从真实插件清单打开对应条目。", "The plugin deep link is retained; open the entry from the actual inventory."))
                        .font(.system(size: 13))
                        .foregroundStyle(HomeSpec.textSecondary)
                }
            }
        }
        .homeGroupedList()
        .navigationTitle(NativeText("插件", "Plugins"))
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("discover.plugin-catalog")
    }
}
