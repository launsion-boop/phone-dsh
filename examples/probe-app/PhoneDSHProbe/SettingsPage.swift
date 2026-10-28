// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — native settings.

import PhoneDSH
import ProbeKit
import SwiftUI
import UIKit

struct SettingsPage: View {
    @State private var model = ChatModel.shared
    @State private var configuration = NativeConfigurationModel.shared
    @State private var web = WebHostModel.shared
    @AppStorage("phone-dsh.composer.busyEnter") private var busyEnterMode = "queue"
    @State private var showDSHConfiguration = false
    @State private var didSave = false
    @State private var mcpRows: [MCPServerSummary] = []
    @State private var showExport = false
    @Environment(\.dismiss) private var dismiss

    private var networkConfigurationChanged: Bool {
        model.egressAllow != ChatSettings.egressAllow
    }

    private var selectedProvider: ProviderProfile? {
        (try? PhoneModelProviderSettings.shared.load().selected)
    }

    init() {
        // SwiftUI 会忽略 listRowSeparatorTint,统一从 UIKit 侧设,免得每页各写一份。
        UITableView.appearance().separatorColor = UIColor(red: 0xDD / 255, green: 0xDC / 255, blue: 0xE2 / 255, alpha: 1)
    }

    var body: some View {
        List {
            mainGroup
            toolsGroup
            aboutGroup
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Color.white)
        .listRowSeparatorTint(ChatPage.hairline)
        .listRowSeparator(.visible)
        .listSectionSpacing(0)
        .environment(\.defaultMinListRowHeight, 44)
        .tint(ChatPage.accent)
        .navigationTitle("设置")
        // 页头规矩:标题居中,不随列表滚动变成左侧大标题。
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("完成") { dismiss() }.leadingBarText()
            }
        }
        .sheet(isPresented: $showDSHConfiguration) {
            NativeConfigurationPage()
                .presentationDragIndicator(.visible)
        }
        .onChange(of: model.egressAllow) { _, _ in didSave = false }
        // 权限那行显示宿主报的默认档,MCP 那行显示真数量:都不缓存,每次进设置读一遍。
        .task {
            await configuration.refresh()
            await refreshMCPRows()
        }
    }

    // MARK: - 首屏第一组:七行,不写组标题(iOS 自己的设置第一组也不写)

    private var mainGroup: some View {
        Section {
            // 能不能写、写之前问不问:第一行可改,第二行只照第一行报结果,
            // 不带箭头也不能点——它是预设带出来的,不是第二个开关。
            row("权限", permissionValue) { PermissionDefaultsPage() }
            settingsRow(rowLabel("写之前", askValue, chevronSlot: true))
            row("模型服务", selectedProvider?.displayName ?? "未配置") { ModelProviderSettingsPage() }
            row("MCP", mcpSummary) { MCPSettingsPage(host: .native) }
            settingsRow(Toggle("后台运行", isOn: $model.backgroundKeepAlive)
                .onChange(of: model.backgroundKeepAlive) { _, value in
                    ChatSettings.backgroundKeepAlive = value
                })
        }
    }

    // MARK: - 第二组:工具(偶尔改一次的开关,给它一个名字)

    private var toolsGroup: some View {
        Section {
            row("网页搜索", searchSummary.title) { WebSearchSettingsPage(host: .native) }
            row("网络访问", "\(egressEntries.count) 个地址") { EgressAllowListPage() }
            settingsRow(Button { showDSHConfiguration = true } label: {
                rowLabel("插件与模型", "")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.primary))
            row("命令", "") { PDSHShellPage() }
            settingsRow(LabeledContent("发送消息时") {
                Picker("", selection: $busyEnterMode) {
                    Text("排到下一轮").tag("queue")
                    Text("补充当前任务").tag("steer")
                }
                .labelsHidden()
                .pickerStyle(.menu)
            }, divider: false)
        } header: {
            groupHeader("工具")
        } footer: {
            // 这几种提示原来各占一行,现在折成一组页脚:行数不变,信息不丢。
            if let line = toolsFooter {
                Text(line)
                    .font(.system(size: 13))
                    .foregroundStyle(ChatPage.inkSecondary)
            }
        }
    }

    // MARK: - 第三组:关于(版本那几行,组标题和「工具」同一套)

    private var aboutGroup: some View {
        Section {
            settingsRow(versionRow)
            row("开源许可", "") { LicensesPage() }
            settingsRow(Button { showExport = true } label: {
                rowLabel("导出诊断", "")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.primary), divider: false)
        } header: {
            groupHeader("关于")
        }
        .sheet(isPresented: $showExport) { ExportPage() }
    }

    private var toolsFooter: String? {
        if let warning = searchLaunchWarning { return warning }
        if model.isStarted && networkConfigurationChanged { return "重启本地引擎后生效。" }
        if didSave { return "已保存。" }
        return nil
    }

    /// MCP 那行的值:引擎没起、或者一个都没有,都写「未配置」,不硬写 0。
    private var mcpSummary: String {
        guard model.isStarted, !mcpRows.isEmpty else { return "未配置" }
        return "\(mcpRows.count) 个服务器"
    }

    private func refreshMCPRows() async {
        guard model.isStarted else { mcpRows = []; return }
        let probe = MCPSettingsModel(
            host: .native,
            settings: .shared,
            isHostRunning: { ChatModel.shared.isStarted },
            makeTransport: { try await ChatModel.shared.transportForManagement() },
            refreshPolicy: { ChatModel.shared.refreshMCPAccessPolicy() })
        await probe.refresh()
        mcpRows = probe.rows
    }

    // MARK: - 开发者入口:版本号连点七下

    private var versionText: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    }

    /// 摆在面上的一行版本号;连点七下才进开发者页。第 4 下起每下轻震一次,
    /// 让人知道自己在点一件有反应的事,第 7 下进页面。
    /// 只读一行版本号。连点七下进开发者页那套撤了:关于组里留着「导出诊断」,
    /// 那是用户报问题时唯一能自己走的一条路,不藏在暗门后面。
    private var versionRow: some View {
        rowLabel("版本", versionText, chevronSlot: true)
    }

    // MARK: - 行与小注


    /// 组标题全站一套:13 号 #66666B、左 16、上 24 下 8;组与组之间不再另画分隔线,
    /// 标题自己就是分界。
    private func groupHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 13, weight: .regular))
            .foregroundStyle(ChatPage.inkSecondary)
            .textCase(nil)
            .listRowInsets(EdgeInsets(top: 24, leading: 16, bottom: 8, trailing: 16))
    }

    /// 分隔线自己画:iOS 26 的 insetGrouped 会忽略 listRowSeparatorTint 和
    /// UITableView 的分隔线颜色,只有自绘才稳定落在 #DDDCE2。
    private func hairline() -> some View {
        Rectangle()
            .fill(ChatPage.hairline)
            .frame(height: 1 / UIScreen.main.scale)
    }

    /// 全页一套行规矩:内容左缘 16、右缘 370(箭头右缘落 370、值右缘落 350),
    /// 分隔线自绘到 16..386。iOS 26 的 insetGrouped 会给每行再套一层内边距,
    /// 所以行内边距一律在这里显式写死,不靠默认值。
    private func settingsRow(_ view: some View, divider: Bool = true) -> some View {
        view
            // insetGrouped 的卡片左缘本来就在 16,内边距是往里加的:
            // 所以 leading 写 0 才是屏幕上 16;trailing 16 让行右缘落 370,
            // 值再让出 20 的箭头位,右缘就落在 350。
            .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 16))
            .listRowSeparator(.hidden)
            .overlay(alignment: .bottom) {
                if divider { hairline().padding(.trailing, -16) }
            }
    }

    private func rowLabel(_ title: String, _ value: String, chevronSlot: Bool = false) -> some View {
        // 行内容左缘 16、右缘 370:带箭头的行,箭头右缘落 370、值右缘落 350;
        // 不带箭头的行照样空出那 20,值的右缘才和上一行齐。
        HStack(spacing: 12) {
            Text(title)
                .font(.system(size: 17))
                .foregroundStyle(.primary)
            Spacer(minLength: 12)
            Text(value)
                .font(.system(size: 15))
                .foregroundStyle(ChatPage.inkSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.trailing, chevronSlot ? 20 : 0)
        }
        .frame(minHeight: 44)
        .contentShape(Rectangle())
    }

    private func row<Destination: View>(_ title: String, _ value: String, divider: Bool = true,
                                        @ViewBuilder destination: () -> Destination) -> some View {
        settingsRow(NavigationLink { destination() } label: { rowLabel(title, value) }, divider: divider)
    }

    private func note(_ text: String, isWarning: Bool) -> some View {
        Label(text, systemImage: isWarning ? "exclamationmark.triangle" : "checkmark.circle.fill")
            .font(.system(size: 13))
            .foregroundStyle(isWarning ? ChatPage.warning : ChatPage.inkSecondary)
    }

    /// 权限那行的值 = 宿主报的默认档翻成中文;翻不出来就写「未设置」,不写死一个词。
    private var permissionValue: String {
        guard let id = NativeConfigurationModel.shared.defaultPermissionMode else { return "未设置" }
        return AccessModeWording.title(for: id) ?? "未设置"
    }

    /// 第二行只报「写之前问不问」这一半,由上面那档决定。
    private var askValue: String {
        guard let id = NativeConfigurationModel.shared.defaultPermissionMode,
              AccessModeWording.title(for: id) != nil else { return "未设置" }
        return AccessModeWording.title(for: id) == "完全权限" ? "不再问" : "每次都问"
    }

    private var hostLabel: String {
        if model.busy { return "正在启动或切换…" }
        if model.parked { return "已暂停" }
        if model.turnRunning { return "正在执行" }
        return model.isStarted ? "运行中" : "未启动"
    }

    private var runtimeSection: some View {
        Section {
            HStack(spacing: 8) {
                Circle()
                    .fill(model.isStarted ? Color(red: 0x0E / 255, green: 0x9F / 255, blue: 0x6E / 255) : Color(uiColor: .tertiaryLabel))
                    .frame(width: 8, height: 8)
                Text("本地引擎")
                Spacer()
                Text(hostLabel)
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
        }
    }

    /// 高级: the switches a normal session never needs. The raw shell page and
    /// the diagnostics live here so they stop cluttering the first screen.
    private var advancedSection: some View {
        Section("高级") {
            Button { showDSHConfiguration = true } label: {
                Label("插件与模型", systemImage: "puzzlepiece.extension")
            }
            .foregroundStyle(.primary)
            NavigationLink {
                PDSHShellPage()
            } label: {
                Label("命令", systemImage: "terminal")
            }
            NavigationLink {
                RuntimeDetailsPage(model: ChatModel.shared)
            } label: {
                Label("运行状态", systemImage: "info.circle")
            }
        }
    }

    private var modelSection: some View {
        Section {
            NavigationLink {
                ModelProviderSettingsPage()
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "server.rack")
                        .frame(width: 24)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(selectedProvider?.displayName ?? "尚未配置模型服务")
                            .foregroundStyle(.primary)
                        if let provider = selectedProvider {
                            Text("\(provider.model) · \(provider.baseURL)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        } else {
                            Text("添加服务、模型名称和 API 密钥")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        } header: {
            Text("模型服务")
        } footer: {
            Text("密钥只保存在本机。修改后需重启本地引擎。")
        }
    }

    private var webSearchSection: some View {
        Section {
            NavigationLink {
                WebSearchSettingsPage(host: .native)
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "globe")
                        .frame(width: 24)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(searchSummary.title)
                            .foregroundStyle(.primary)
                        Text(searchSummary.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
            }
            if let searchLaunchWarning {
                Label(searchLaunchWarning, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
        } header: {
            Text("网页搜索")
        } footer: {
            if searchLaunchWarning == nil {
                Text("用模型服务自带的搜索，或者自己填一个搜索接口。")
            } else {
                Text("改完重启本地引擎，这里就不会再提示。")
            }
        }
    }

    /// The same non-secret launch decision the active host published. The Web
    /// surface and the native recovery host each own one; only the active
    /// surface's warning is shown.
    private var searchLaunchWarning: String? {
        web.mode == .web ? web.searchLaunchWarning : model.searchLaunchWarning
    }

    private var searchSummary: (title: String, detail: String) {
        do {
            let loaded = try PhoneWebSearchSettings.shared.load()
            switch loaded.configuration.mode {
            case .followModel:
                return ("沿用模型服务", "显式回退；仅官方 DeepSeek Messages 端点可用")
            case .searchAPI:
                return ("独立 DeepSeek 搜索 API",
                        loaded.hasCredential
                            ? loaded.configuration.baseURL
                            : "已保存 endpoint，尚未保存独立密钥")
            }
        } catch {
            return ("网页搜索配置不可读",
                    WebSearchHostConfiguration.userFacingMessage(for: error))
        }
    }

    private var mcpSection: some View {
        Section {
            NavigationLink {
                MCPSettingsPage(host: .native)
            } label: {
                Label("MCP 网络与密钥", systemImage: "network")
            }
        } header: {
            Text("MCP")
        } footer: {
            Text("给每个 MCP 服务器单独放行网络地址和凭据。")
        }
    }

    /// The first screen carries one summary line; the address list itself is a
    /// page, so domains never eat half of settings.
    private var networkSection: some View {
        Section {
            NavigationLink {
                EgressAllowListPage()
            } label: {
                LabeledContent("允许列表", value: "\(egressEntries.count) 个地址")
            }
            if model.isStarted && networkConfigurationChanged {
                Label("重启本地引擎后生效。", systemImage: "arrow.clockwise")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            } else if didSave {
                Label("已保存。", systemImage: "checkmark.circle.fill")
                    .font(.footnote)
                    .foregroundStyle(.green)
            }
        } header: {
            Text("网络访问")
        } footer: {
            Text("智能体访问这些地址时不带模型密钥。改完要重启本地引擎。")
        }
    }

    private var egressEntries: [String] {
        let raw = model.egressAllow.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw == ChatSettings.allowAllEgress { return [] }
        return raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    private var backgroundSection: some View {
        Section("后台运行") {
            Toggle("继续执行当前任务", isOn: $model.backgroundKeepAlive)
                .onChange(of: model.backgroundKeepAlive) { _, value in
                    ChatSettings.backgroundKeepAlive = value
                }
            Text("锁屏或切到后台时尽量让任务继续跑。系统仍可能暂停它。")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var conversationSection: some View {
        Section("发送消息时") {
            Picker("发送消息时", selection: $busyEnterMode) {
                Text("排到下一轮").tag("queue")
                Text("补充当前任务").tag("steer")
            }
            .pickerStyle(.menu)
            Text("排队的消息会在当前任务后处理；补充说明会尝试引导正在运行的任务。")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var aboutSection: some View {
        Section("关于") {
            settingsRow(LabeledContent("版本", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"))
            Text("会话记录和文件都保存在这台手机上。")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

private struct PermissionDefaultsPage: View {
    @State private var value: String? = NativeConfigurationModel.shared.defaultPermissionMode
    var body: some View {
        List {
            Section {
                Text("只影响之后新开的会话。正在聊的这个不跟着变。")
                    .font(.system(size: 13))
                    .foregroundStyle(ChatPage.inkSecondary)
            }
            Section {
                // 三档就是聊天里权限菜单那三档,措辞一致;顺序也一致,完全权限压最后。
                option("仅可查看")
                option("工作区内修改")
                option("完全权限")
            }
        }
        .navigationTitle("新会话默认权限")
        .navigationBarTitleDisplayMode(.large)
    }

    private func option(_ title: String) -> some View {
        Button {
            value = title
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(title).foregroundStyle(.primary)
                Spacer(minLength: 8)
                if value == title {
                    Image(systemName: "checkmark")
                        .foregroundStyle(ChatPage.accent)
                }
            }
        }
    }
}

private struct LicensesPage: View {
    var body: some View {
        List {
            LabeledContent("SwiftTerm", value: "MIT")
            LabeledContent("swift-nio", value: "Apache 2.0")
        }
        .navigationTitle("开源许可")
        .navigationBarTitleDisplayMode(.large)
    }
}

#if DEBUG
    private var developerGroup: some View {
        Section {
            NavigationLink {
                DevelopmentToolsPage()
            } label: {
                Label("探针工具", systemImage: "wrench.and.screwdriver")
            }
        } header: {
            groupHeader("开发者")
        }
    }

    private var developerSection: some View {
        Section("开发者") {
            NavigationLink {
                DevelopmentToolsPage()
            } label: {
                Label("探针工具", systemImage: "wrench.and.screwdriver")
            }
        }
    }
#endif
}

#if DEBUG
private struct DevelopmentToolsPage: View {
    var body: some View {
        List {
            NavigationLink("探针") { ProbesPage() }
            NavigationLink("内存") { MemoryPage() }
            NavigationLink("后台") { BackgroundPage() }
            NavigationLink("屏幕") { TaskScreenPage() }
            NavigationLink("导出") { ExportPage() }
        }
        .navigationTitle("探针工具")
    }
}
#endif

/// 只有连点版本号七下才走得到这里:探针和导出诊断都是给我们自己验收用的。
private struct DeveloperPage: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 标题居中、完成在左,同一行:用叠放,标题按屏宽居中,不被左边按钮挤歪。
            ZStack {
                Text("开发者")
                    .font(.system(size: 17, weight: .semibold))
                HStack {
                    Button("完成") { dismiss() }
                        .font(.system(size: 17))
                        .foregroundStyle(ChatPage.accent)
                    Spacer()
                }
            }
            .padding(.horizontal, 16)
            .frame(height: 44)
            .padding(.top, 4)
            .padding(.bottom, 8)

            VStack(spacing: 0) {
                NavigationLink { DevelopmentToolsPage() } label: {
                    developerRow("探针")
                }
                Rectangle()
                    .fill(ChatPage.hairline)
                    .frame(height: 1 / UIScreen.main.scale)
                    .padding(.horizontal, 16)
                NavigationLink { ExportPage() } label: {
                    developerRow("导出诊断")
                }
            }

            Text("这些是给我们自己看的，你不需要用。")
                .font(.system(size: 13))
                .foregroundStyle(ChatPage.inkSecondary)
                .padding(.leading, 16)
                .padding(.trailing, 16)
                .padding(.top, 12)

            Spacer()
        }
        .background(Color.white)
        .navigationBarBackButtonHidden()
        .toolbar(.hidden, for: .navigationBar)
    }

    private func developerRow(_ title: String) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 17))
                .foregroundStyle(.primary)
            Spacer(minLength: 12)
            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(ChatPage.inkSecondary.opacity(0.6))
        }
        .frame(minHeight: 44)
        .padding(.leading, 16)
        .padding(.trailing, 16)
        .contentShape(Rectangle())
    }
}
