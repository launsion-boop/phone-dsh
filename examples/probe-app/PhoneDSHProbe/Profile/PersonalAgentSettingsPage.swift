// SPDX-License-Identifier: MIT

import SwiftUI

struct PersonalAgentSettingsPage: View {
    @AppStorage("personalAgent.displayName") private var agentName = "Personal Agent"
    @AppStorage("personalAgent.ownerName") private var ownerName = ""

    var body: some View {
        Form {
            Section(NativeText("Personal Agent", "Personal Agent")) {
                TextField(NativeText("Agent 名称", "Agent name"), text: $agentName)
                    .accessibilityIdentifier("profile.agent-name")
                TextField(NativeText("如何称呼你", "How to address you"), text: $ownerName)
                    .accessibilityIdentifier("profile.owner-name")
            }
            Section(NativeText("个人上下文", "Personal context")) {
                Text(NativeText("称呼保存在本机。时区、语言、职业、关键联系人与作息等结构化字段将在 Personal Agent 数据层接入后提供。",
                                "The preferred name is stored locally. Structured timezone, language, occupation, contacts and schedule fields will use the Personal Agent data layer."))
                    .font(.system(size: 14))
                    .foregroundStyle(HomeSpec.textSecondary)
            }
            Section(NativeText("AI 日记", "AI Journal")) {
                Text(NativeText("历史与数据管理入口将在 AI 日记能力接入后开放；当前没有生成日记。",
                                "History and data controls will open when AI Journal is connected. No journal has been generated."))
                    .font(.system(size: 14))
                    .foregroundStyle(HomeSpec.textSecondary)
            }
        }
        .homeGroupedList()
        .navigationTitle("Personal Agent")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("profile.personal-agent-settings")
    }
}
