// SPDX-License-Identifier: MIT
// ConnectorsPage: the 发现 tab. A first-level page listing the outside
// connections DSH has today. Phone data (calendar,
// reminders, contacts…) is a permission, not a connector, and lives in
// 我的 › 手机权限. Picking a connector opens its detail sheet, which rests at
// half height and drags up to full; its action pushes the setup page.

import ProbeKit
import SwiftUI

enum DiscoverConnector: String, CaseIterable, Identifiable, Hashable {
    case gmail, github, feishu, devices, webSearch, mcp

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .devices: return "dot.radiowaves.left.and.right"
        case .webSearch: return "globe"
        case .mcp: return "server.rack"
        case .gmail: return "envelope.fill"
        case .github: return "GitHubMark"
        case .feishu: return "doc.text.fill"
        }
    }

    var tint: Color {
        switch self {
        case .devices: return Color(red: 0.19, green: 0.69, blue: 0.78)
        case .webSearch: return Color(red: 0.20, green: 0.78, blue: 0.35)
        case .mcp: return HomeSpec.textPrimary
        case .gmail: return Color(red: 0.92, green: 0.26, blue: 0.21)
        case .github: return Color(red: 0.13, green: 0.15, blue: 0.18)
        case .feishu: return Color(red: 0.20, green: 0.44, blue: 1.0)
        }
    }

    var title: String {
        switch self {
        case .devices: return NativeText("设备", "Devices")
        case .webSearch: return NativeText("网页搜索", "Web search")
        case .mcp: return NativeText("自定义 MCP 服务", "Custom MCP server")
        case .gmail: return "Gmail"
        case .github: return "GitHub"
        case .feishu: return NativeText("飞书", "Feishu")
        }
    }

    var subtitle: String {
        switch self {
        case .devices: return NativeText("通过蓝牙连接外设", "Peripherals over Bluetooth")
        case .webSearch: return NativeText("让 DSH 搜索和读取网页", "Let DSH search and read the web")
        case .mcp: return NativeText("添加你自己的服务地址", "Add your own server")
        case .gmail: return NativeText("连接账号、搜索和阅读邮件", "Connect an account, search and read mail")
        case .github: return NativeText("浏览已授权的仓库", "Browse authorized repositories")
        case .feishu: return NativeText("浏览云文档", "Browse cloud documents")
        }
    }

    /// The gray pill on the row, naming what the sheet's action does.
    var pillTitle: String {
        switch self {
        case .devices: return NativeText("连接", "Connect")
        case .gmail, .github: return NativeText("打开", "Open")
        case .feishu: return NativeText("连接", "Connect")
        case .webSearch: return NativeText("设置", "Set up")
        case .mcp: return NativeText("添加", "Add")
        }
    }

}

struct ConnectorsPage: View {
    @State private var selected: DiscoverConnector?
    /// The sheet's action: pushed once the sheet has gone, so the dismissal
    /// and the push never animate over each other.
    @State private var pendingPush: DiscoverConnector?
    @State private var pushed: DiscoverConnector?

    var body: some View {
        List { DevicePanelShortcuts()
            Section {
                ForEach(DiscoverConnector.allCases) { connector in
                    row(connector)
                }
            } header: {
                sectionHeader(NativeText("连接器", "Connectors"))
            }

            Section {
                NavigationLink { NativeConfigurationPage() } label: {
                    SettingsRowLabel(title: NativeText("插件与工具", "Plugins and tools"), icon: "puzzlepiece.extension")
                }
            } header: {
                sectionHeader(NativeText("更多", "More"))
            }
        }
        .homeGroupedList()
        .navigationTitle(NativeText("发现", "Discover"))
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $selected, onDismiss: {
            if let next = pendingPush {
                pendingPush = nil
                pushed = next
            }
        }) { connector in
            ConnectorDetailSheet(connector: connector) {
                pendingPush = connector
                selected = nil
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
            .presentationBackground(HomeSpec.page)
            .presentationCornerRadius(32)
        }
        .navigationDestination(item: $pushed) { connector in
            destination(connector)
        }
    }

    @ViewBuilder
    private func destination(_ connector: DiscoverConnector) -> some View {
        switch connector {
        case .devices: BluetoothDevicesPage()
        case .webSearch: WebSearchSettingsPage()
        case .mcp: MCPSettingsPage()
        case .gmail: GmailConnectorPage()
        case .github: GitHubConnectorPage()
        case .feishu: FeishuConnectorPage()
        }
    }

    private func sectionHeader(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(HomeSpec.textPlaceholder)
            .textCase(nil)
    }

    private func row(_ connector: DiscoverConnector) -> some View {
        Button { selected = connector } label: {
            HStack(spacing: 14) {
                ConnectorTile(connector: connector, size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(connector.title)
                        .font(.system(size: HomeSpec.bodySize))
                        .foregroundStyle(HomeSpec.textPrimary)
                    Text(connector.subtitle)
                        .font(.system(size: 13))
                        .foregroundStyle(HomeSpec.textPlaceholder)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                ConnectPill(title: connector.pillTitle)
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .alignmentGuide(.listRowSeparatorLeading) { _ in 58 }
    }
}

private struct ConnectorTile: View {
    let connector: DiscoverConnector
    let size: CGFloat

    var body: some View {
        Group {
            if connector == .github {
                Image(connector.icon)
                    .resizable()
                    .renderingMode(.template)
                    .scaledToFit()
                    .frame(width: size * 0.46, height: size * 0.46)
            } else {
                Image(systemName: connector.icon)
                    .font(.system(size: size * 0.46, weight: .medium))
            }
        }
        .foregroundStyle(connector.tint)
        .frame(width: size, height: size)
        .background(Color(red: 0.95, green: 0.95, blue: 0.95),
                    in: RoundedRectangle(cornerRadius: size * 0.27, style: .continuous))
        .accessibilityHidden(true)
    }
}

/// The gray pill on a connector row.
private struct ConnectPill: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(HomeSpec.textPrimary)
            .padding(.horizontal, 16)
            .frame(height: 32)
            .background(HomeSpec.userBubble, in: Capsule())
    }
}

// MARK: - Detail sheet

/// One connector's sheet: icon, name, the one action, what it is for, then
/// "关于此连接器". Rests at half height; drags up to full height. Tapping
/// outside closes it, so it has no close button.
private struct ConnectorDetailSheet: View {
    let connector: DiscoverConnector
    let onOpen: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                ConnectorTile(connector: connector, size: 96)
                    .shadow(color: .black.opacity(0.08), radius: 12, y: 6)
                    .padding(.top, 28)
                Text(connector.title)
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(HomeSpec.textPrimary)
                    .padding(.top, 16)

                primaryAction
                    .frame(maxWidth: 260)
                    .padding(.top, 20)

                VStack(alignment: .leading, spacing: 14) {
                    Text(summary)
                        .font(.system(size: 15))
                        .foregroundStyle(HomeSpec.textPlaceholder)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(NativeText("关于此连接器", "About this connector"))
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(HomeSpec.textPlaceholder)
                        .padding(.top, 10)
                    aboutCard
                }
                .padding(.horizontal, HomeSpec.contentInset)
                .padding(.top, 28)
                .padding(.bottom, 32)
            }
            .frame(maxWidth: .infinity)
        }
    }

    private var primaryAction: some View {
        Button(actionTitle) { onOpen() }
            .buttonStyle(HomePrimaryButtonStyle())
    }

    private var actionTitle: String {
        switch connector {
        case .devices:
            return NativeText("连接设备", "Connect a device")
        case .webSearch: return NativeText("设置网页搜索", "Set up web search")
        case .mcp: return NativeText("添加服务", "Add a server")
        case .gmail: return NativeText("打开 Gmail", "Open Gmail")
        case .github: return NativeText("打开 GitHub", "Open GitHub")
        case .feishu: return NativeText("打开飞书", "Open Feishu")
        }
    }

    private var summary: String {
        switch connector {
        case .devices:
            return NativeText("连接附近的蓝牙外设，读取标准数据或控制提醒。局域网设备在「自定义 MCP 服务」中添加。",
                              "Connect nearby Bluetooth peripherals to read standard data or control alerts. LAN devices are added under Custom MCP server.")
        case .webSearch:
            return NativeText("让 DSH 在对话里搜索网页、打开链接并读取内容，回答时附上来源。",
                              "Let DSH search the web, open links and read pages, citing its sources.")
        case .mcp:
            return NativeText("填入 MCP 服务的地址和密钥，DSH 就能调用这个服务提供的工具。",
                              "Enter an MCP server's address and key so DSH can use the tools it offers.")
        case .gmail:
            return NativeText("连接 Google 账号后，可以在手机上搜索和阅读 Gmail 邮件。",
                              "Connect a Google account to search and read Gmail on this phone.")
        case .github:
            return NativeText("连接 GitHub 账号后，可以在手机上查看你选择的仓库。",
                              "Connect a GitHub account to browse the repositories you choose on this phone.")
        case .feishu:
            return NativeText("连接飞书账号后，可以在手机上浏览你的云文档。",
                              "Connect a Feishu account to browse your cloud documents on this phone.")
        }
    }

    private var aboutRows: [(icon: String, title: String, detail: String)] {
        switch connector {
        case .devices:
            return [
                ("antenna.radiowaves.left.and.right", NativeText("蓝牙设备", "Bluetooth devices"),
                 NativeText("只在蓝牙设备页主动扫描，连接后才会发现可用能力。",
                            "Scan is explicit on the Bluetooth devices page; capabilities appear only after connecting.")),
                ("lock.shield", NativeText("每次连接单独授权", "Authorized per connection"),
                 NativeText("每次建立新连接后，需重新授权读取或提醒控制。",
                            "Each new connection needs read or alert permission again.")),
            ]
        case .webSearch:
            return [
                ("magnifyingglass", NativeText("跟随模型或自定义来源", "Model or custom source"),
                 NativeText("默认使用模型自带的搜索，也可以填入自己的搜索服务。",
                            "Uses the model's own search by default, or a search service you add.")),
                ("key", NativeText("密钥只存在本机", "Keys stay on this phone"),
                 NativeText("搜索服务的密钥保存在设备钥匙串里。",
                            "Search service keys are kept in the device keychain.")),
            ]
        case .mcp:
            return [
                ("point.3.connected.trianglepath.dotted", NativeText("标准 MCP 协议", "Standard MCP"),
                 NativeText("支持通过 HTTP 访问的 MCP 服务，可以添加多个。",
                            "Works with MCP servers reachable over HTTP; add as many as you need.")),
                ("key", NativeText("密钥只存在本机", "Keys stay on this phone"),
                 NativeText("认证信息只写入设备钥匙串，不会上传。",
                            "Credentials are written to the device keychain only.")),
            ]
        case .gmail:
            return [
                ("tray.full", NativeText("读取和搜索邮件", "Read and search mail"),
                 NativeText("按发件人、主题或时间查找邮件，点开查看正文。",
                            "Find mail by sender, subject or date and open the message to read it.")),
                ("lock.shield", NativeText("只读授权", "Read-only access"),
                 NativeText("你可以随时断开 Google 账号。", "You can disconnect your Google account at any time.")),
            ]
        case .github:
            return [
                ("book.closed", NativeText("只读仓库元数据", "Read-only repository metadata"),
                 NativeText("只读取你选择的仓库名称和链接，不下载仓库内容。",
                            "Reads only the names and links of repositories you choose; no repository content is downloaded.")),
                ("lock.shield", NativeText("GitHub 授权", "GitHub authorization"),
                 NativeText("在 GitHub 授权。你可以随时断开连接，或到 GitHub 管理授权。",
                            "Authorize on GitHub. You can disconnect here or manage access on GitHub.")),
            ]
        case .feishu:
            return [
                ("doc.text", NativeText("只读云文档清单", "Read-only document listing"),
                 NativeText("只读取云空间根目录的文档名称、类型和链接，不下载文件内容。",
                            "Reads the names, types and links of files in your cloud space root; no file content is downloaded.")),
                ("lock.shield", NativeText("飞书授权", "Feishu authorization"),
                 NativeText("在飞书完成授权，应用密钥只保存在平台侧，不下发到手机。",
                            "Authorize in Feishu; the app secret stays on the platform and never reaches this phone.")),
            ]
        }
    }

    private var aboutCard: some View {
        let rows = aboutRows
        return VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                if index > 0 { Divider().padding(.leading, 52) }
                aboutRow(icon: row.icon, title: row.title, detail: row.detail)
            }
        }
        .background(HomeSpec.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private func aboutRow(icon: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .regular))
                .foregroundStyle(HomeSpec.textSecondary)
                .frame(width: 22)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: HomeSpec.bodySize, weight: .semibold))
                    .foregroundStyle(HomeSpec.textPrimary)
                Text(detail)
                    .font(.system(size: 14))
                    .foregroundStyle(HomeSpec.textPlaceholder)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
    }
}
