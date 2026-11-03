// SPDX-License-Identifier: MIT

import SwiftUI

struct DSHNewSessionPage: View {
    @Environment(\.dismiss) private var dismiss
    @State private var management = DSHManagementModel.shared
    @State private var chat = ChatModel.shared
    @State private var isCreating = false

    var body: some View {
        List {
            Section {
                Button {
                    guard !isCreating else { return }
                    isCreating = true
                    Task {
                        if await management.createSession() != nil { dismiss() }
                        isCreating = false
                    }
                } label: {
                    Label(NativeText("使用当前预设新建会话", "New session with the current preset"),
                          systemImage: "square.and.pencil")
                }
                .disabled(isCreating || !chat.isStarted || chat.busy || chat.turnRunning || chat.keepingAlive)
                NavigationLink {
                    NativeAgentPresetsPage()
                } label: {
                    SettingsRowLabel(title: NativeText("Agent 预设", "Agent presets"), icon: "person.2")
                }
                .accessibilityIdentifier("dsh.new-session.presets")
            } header: {
                Text(NativeText("新建会话", "New session"))
            } footer: {
                Text(NativeText("预设只用于 DSH 新会话，不是 Personal Agent 的个人设置。", "Presets belong to new DSH sessions, not Personal Agent profile settings."))
            }
            if let error = management.error {
                Section { Text(error).foregroundStyle(ChatPage.danger) }
            }
        }
        .homeGroupedList()
        .navigationTitle(NativeText("新建 DSH 会话", "New DSH session"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(NativeText("取消", "Cancel")) { dismiss() }
            }
        }
        .accessibilityIdentifier("dsh.new-session")
    }
}
