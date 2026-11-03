// SPDX-License-Identifier: MIT

import SwiftUI

struct ProfilePage: View {
    let dockBottomInset: CGFloat
    @State private var chat = ChatModel.shared

    var body: some View {
        ScrollViewReader(content: { (reader: ScrollViewProxy) in
        List {
            Section(NativeText("Personal Agent", "Personal Agent")) {
                link(NativeText("Agent 与个人上下文", "Agent and personal context"), icon: "person.crop.circle",
                     route: .personalAgent)
            }

            Section(NativeText("模型与用量", "Model and usage")) {
                link(NativeText("模型服务", "Model providers"), icon: "cpu", route: .model)
                LabeledContent(NativeText("用量", "Usage"), value: NativeText("未知", "Unknown"))
            }

            Section(NativeText("Memory", "Memory")) {
                link(NativeText("个人 Memory", "Personal Memory"), icon: "brain.head.profile", route: .memory)
            }

            Section(NativeText("权限与隐私", "Permissions and privacy")) {
                link(NativeText("新会话默认权限", "Default permission"), icon: "lock.shield", route: .permissionDefaults)
                link(NativeText("手机权限", "Phone permissions"), icon: "hand.raised", route: .phonePermissions)
                link(NativeText("网络访问与模型出网", "Network and model egress"), icon: "network", route: .network)
            }

            Section(NativeText("会话与文件", "Sessions and files")) {
                link(NativeText("文件夹", "Folders"), icon: "folder", route: .folders)
                link(NativeText("已归档会话", "Archived sessions"), icon: "archivebox", route: .archivedSessions)
                Text(NativeText("Artifact 可从各 DSH 会话导出；Personal Agent 数据导出将在数据层接入后提供。",
                                "Artifacts can be exported from each DSH session. Personal Agent data export will follow its data layer."))
                    .font(.system(size: 13))
                    .foregroundStyle(HomeSpec.textSecondary)
            }

            Section(NativeText("引擎与恢复", "Engine and recovery")) {
                LabeledContent(NativeText("运行状态", "Engine"), value: chat.hostState)
                NavigationLink(value: ProfileRoute.engine) {
                    SettingsRowLabel(title: NativeText("运行状态与恢复", "Runtime and recovery"), icon: "waveform.path.ecg")
                }
            }

            Section(NativeText("通用与关于", "General and about")) {
                link(NativeText("通用设置", "General settings"), icon: "gearshape", route: .general)
                link(NativeText("关于 Phone DSH", "About Phone DSH"), icon: "info.circle", route: .about)
                link(NativeText("开源许可", "Open-source licenses"), icon: "doc.text", route: .licenses)
            }
            .id("profile-about")
        }
        .homeGroupedList()
        .navigationTitle(NativeText("个人", "Profile"))
        .toolbar(.visible, for: .navigationBar)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Color.clear.frame(height: dockBottomInset)
        }
        .accessibilityIdentifier("app.profile")
        .onAppear {
            #if DEBUG
            if ProcessInfo.processInfo.environment["PDSH_PREVIEW_SCROLL_BOTTOM"] == "1" {
                reader.scrollTo("profile-about", anchor: .bottom)
            }
            #endif
        }
        })
    }

    private func link(_ title: String, icon: String, route: ProfileRoute) -> some View {
        NavigationLink(value: route) {
            SettingsRowLabel(title: title, icon: icon)
        }
    }
}
