// SPDX-License-Identifier: MIT

import ProbeKit
import SwiftUI

struct PersonalAgentSettingsPage: View {
    @AppStorage("personalAgent.displayName") private var agentName = "小肥鱼"
    @AppStorage("personalAgent.ownerName") private var ownerName = ""
    @State private var composition = AppComposition.shared
    @State private var errorMessage: String?

    var body: some View {
        Form {
            Section(NativeText("Personal Agent", "Personal Agent")) {
                TextField(NativeText("Agent 名称", "Agent name"), text: $agentName)
                    .accessibilityIdentifier("profile.agent-name")
                TextField(NativeText("如何称呼你", "How to address you"), text: $ownerName)
                    .accessibilityIdentifier("profile.owner-name")
                Button(NativeText("保存称呼到个人上下文", "Save name to personal context")) {
                    Task { await saveOwnerName() }
                }
                if let errorMessage { Text(errorMessage).foregroundStyle(NativeParityTokens.warning) }
            }
            Section(NativeText("个人上下文", "Personal context")) {
                Text(NativeText("称呼会用于后续回答。语言、职业、关键联系人与作息等记忆可在 Chat 中明确要求记住，并在个人 Memory 中查看来源、修正或遗忘。",
                                "Your preferred name is used in later answers. Language, occupation, contacts and schedule can be explicitly saved in Chat and managed in Personal Memory."))
                    .font(.system(size: 14))
                    .foregroundStyle(HomeSpec.textSecondary)
            }
            Section(NativeText("每日简报", "Daily brief")) {
                Text(NativeText("只有真实新增内容才会生成每日简报 Artifact，并显示在 Chat 时间线中。",
                                "Only real changes create a Daily Brief artifact in the Chat timeline."))
                    .font(.system(size: 14))
                    .foregroundStyle(HomeSpec.textSecondary)
            }
        }
        .homeGroupedList()
        .navigationTitle("Personal Agent")
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadOwnerName() }
        .accessibilityIdentifier("profile.personal-agent-settings")
    }

    private func loadOwnerName() async {
        guard ownerName.isEmpty, let name = try? await composition.preferredOwnerName() else { return }
        ownerName = name
    }

    private func saveOwnerName() async {
        do {
            try await composition.savePreferredOwnerName(ownerName)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
