// SPDX-License-Identifier: MIT

import ProbeKit
import SwiftUI

enum DiscoverRoute: Hashable {
    case connector(String)
    case plugins(focus: String?)
    case devices(focus: String?)
}

enum DiscoverFilter: String, CaseIterable, Identifiable {
    case all, connected, attention

    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: NativeText("全部", "All")
        case .connected: NativeText("已连接", "Connected")
        case .attention: NativeText("待处理", "Needs attention")
        }
    }
}

struct DiscoverPage: View {
    let model: DiscoverConnectorModel
    let dockBottomInset: CGFloat
    @State private var query = ""
    @State private var filter = DiscoverFilter.all

    private var connectors: [DiscoverConnectorDescriptor] {
        DiscoverConnectorDescriptor.all.filter { descriptor in
            let matchesQuery = query.isEmpty || descriptor.title.localizedCaseInsensitiveContains(query)
                || descriptor.detail.localizedCaseInsensitiveContains(query)
            guard matchesQuery else { return false }
            let state = model.records[descriptor.id]?.state
            switch filter {
            case .all: return true
            case .connected: return state == .connected
            case .attention: return state == .needsAttention || state == .expired || state == .error
            }
        }
    }

    var body: some View {
        List {
            Section {
                Picker(NativeText("筛选", "Filter"), selection: $filter) {
                    ForEach(DiscoverFilter.allCases) { item in
                        Text(item.title).tag(item)
                    }
                }
                .pickerStyle(.segmented)
                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
            }

            Section {
                ForEach(connectors) { descriptor in
                    NavigationLink(value: DiscoverRoute.connector(descriptor.id)) {
                        HStack(spacing: 12) {
                            Image(systemName: descriptor.systemImage)
                                .frame(width: 28, height: 28)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(descriptor.title)
                                Text(descriptor.detail)
                                    .font(.system(size: 13))
                                    .foregroundStyle(HomeSpec.textSecondary)
                            }
                            Spacer(minLength: 8)
                            if let record = model.records[descriptor.id] {
                                HomeTag(text: nativeConnectorStateTitle(record.state))
                            } else {
                                ProgressView().controlSize(.mini)
                            }
                        }
                        .frame(minHeight: 48)
                    }
                    .accessibilityIdentifier("discover.connector.\(descriptor.id)")
                }
                if connectors.isEmpty {
                    Text(NativeText("没有符合当前搜索与筛选的连接器。", "No connectors match this search and filter."))
                        .foregroundStyle(HomeSpec.textPlaceholder)
                }
            } header: {
                Text(NativeText("连接器", "Connectors"))
            } footer: {
                Text(NativeText("连接器运行时正在接入；这里不显示伪造的账号或连接成功状态。",
                                "The connector runtime is being connected. No account or successful connection is fabricated."))
            }

            Section(NativeText("插件", "Plugins")) {
                NavigationLink(value: DiscoverRoute.plugins(focus: nil)) {
                    SettingsRowLabel(title: NativeText("插件与运行配置", "Plugins and runtime configuration"),
                                     icon: "puzzlepiece.extension")
                }
                .accessibilityIdentifier("discover.plugins")
            }

            Section(NativeText("硬件", "Hardware")) {
                NavigationLink(value: DiscoverRoute.devices(focus: nil)) {
                    SettingsRowLabel(title: NativeText("BLE / LAN 设备", "BLE / LAN devices"),
                                     icon: "dot.radiowaves.left.and.right")
                }
                .accessibilityIdentifier("discover.devices")
            }
        }
        .homeGroupedList()
        .navigationTitle(NativeText("发现", "Discover"))
        .toolbar(.visible, for: .navigationBar)
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always),
                    prompt: NativeText("搜索连接器、插件、硬件", "Search connectors, plugins and hardware"))
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Color.clear.frame(height: dockBottomInset)
        }
        .task { await model.refresh() }
        .task { await model.observeUpdates() }
        .refreshable { await model.refresh() }
        .accessibilityIdentifier("app.discover")
    }
}
