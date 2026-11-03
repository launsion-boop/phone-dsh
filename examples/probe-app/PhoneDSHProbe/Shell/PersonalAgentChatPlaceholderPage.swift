// SPDX-License-Identifier: MIT

import PhoneDSH
import ProbeKit
import SwiftUI

struct PersonalAgentChatPlaceholderPage: View {
    let focus: ChatFocus?
    let dockBottomInset: CGFloat
    let openDSH: () -> Void

    private var modelConfigured: Bool {
        guard let profile = (try? PhoneModelProviderSettings.shared.load())?.selected,
              let status = try? PhoneModelProviderSettings.shared.apiKeyStatus(for: profile.id)
        else { return false }
        return status == .present
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text(NativeText("今天需要处理什么？", "What needs attention today?"))
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(HomeSpec.textPrimary)
                    .padding(.top, 32)

                if !modelConfigured {
                    VStack(alignment: .leading, spacing: 12) {
                        Label(NativeText("尚未配置模型", "Model not configured"), systemImage: "cpu")
                            .font(.system(size: HomeSpec.bodySize, weight: .semibold))
                        Text(NativeText("Personal Agent 与 DSH 共用模型服务。配置后仍会先显示接入状态，不会冒充已经可用的个人对话。",
                                        "Personal Agent uses the same model provider as DSH. Configuration does not pretend that the personal conversation is already available."))
                            .font(.system(size: 14))
                            .foregroundStyle(HomeSpec.textSecondary)
                        NavigationLink(value: ShellChatRoute.model) {
                            Text(NativeText("配置模型", "Configure model"))
                        }
                        .buttonStyle(HomePrimaryButtonStyle())
                    }
                    .padding(16)
                    .background(HomeSpec.surface, in: RoundedRectangle(cornerRadius: HomeSpec.listCardRadius))
                }

                VStack(alignment: .leading, spacing: 12) {
                    Label(NativeText("Personal Agent 正在接入", "Personal Agent is being connected"), systemImage: "person.crop.circle.badge.clock")
                        .font(.system(size: HomeSpec.bodySize, weight: .semibold))
                    Text(NativeText("这里将使用独立的 Personal Agent 对话，不是 DSH 会话。当前版本尚未开放输入、发送或个人记忆。",
                                    "This will be an independent Personal Agent conversation, not a DSH session. Input, sending and personal memory are not available yet."))
                        .font(.system(size: 14))
                        .foregroundStyle(HomeSpec.textSecondary)
                    if focus != nil {
                        Text(NativeText("已保留这次 Personal Agent 深链；对应内容会在接入后开放。",
                                        "This Personal Agent deep link is retained; its content will open when the runtime is connected."))
                            .font(.system(size: 13))
                            .foregroundStyle(HomeSpec.textTertiary)
                    }
                    Button(NativeText("先去 DSH", "Open DSH first"), action: openDSH)
                        .buttonStyle(HomePrimaryButtonStyle())
                }
                .padding(16)
                .background(HomeSpec.surface, in: RoundedRectangle(cornerRadius: HomeSpec.listCardRadius))
            }
            .padding(.horizontal, HomeSpec.contentInset)
            .padding(.bottom, 24)
        }
        .background(HomeSpec.page)
        .navigationTitle("Personal Agent")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Color.clear.frame(height: dockBottomInset)
        }
        .accessibilityIdentifier("app.chat.placeholder")
    }
}
