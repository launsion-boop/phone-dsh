// SPDX-License-Identifier: MIT

import ProbeKit
import SwiftUI
import UIKit

struct PersonalAgentSettingsPage: View {
    @AppStorage("personalAgent.displayName") private var agentName = "小肥鱼"
    @AppStorage("personalAgent.ownerName") private var ownerName = ""
    @Environment(\.scenePhase) private var scenePhase
    @State private var composition = AppComposition.shared
    @State private var management = DSHManagementModel.shared
    @State private var notifications = PersonalAgentNotificationSettings()
    @State private var editingAgentName = false
    @State private var automationLoaded = false
    @State private var errorMessage: String?

    private var enabledAutomationCount: Int? {
        guard automationLoaded, management.error == nil else { return nil }
        return PersonalAgentAutomationSummary.enabledCount(
            statuses: management.scheduleRecords.map(\.status))
    }

    var body: some View {
        List {
            agentSection
            personalizationSection
            taskSection
            memorySection
        }
        .homeGroupedList()
        .navigationTitle("Personal Agent")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await loadOwnerName()
            await notifications.refresh()
        }
        .task {
            await management.refreshAutomations()
            automationLoaded = true
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task { await notifications.refresh() }
        }
        .sheet(isPresented: $editingAgentName) { agentNameEditor }
        .alert("在系统设置中管理通知", isPresented: $notifications.requiresSystemSettings) {
            Button("取消", role: .cancel) {}
            Button("去系统设置") { openSystemSettings() }
        } message: {
            Text(notificationSettingsMessage)
        }
        .alert("通知请求失败", isPresented: Binding(
            get: { notifications.errorMessage != nil },
            set: { if !$0 { notifications.errorMessage = nil } }
        )) {
            Button("好") { notifications.errorMessage = nil }
        } message: {
            Text(notifications.errorMessage ?? "")
        }
        .accessibilityIdentifier("profile.personal-agent-settings")
    }

    private var agentSection: some View {
        Section {
            VStack(spacing: 12) {
                PhoneDSHLogo(size: 88)
                    .padding(.top, 8)
                Text(agentName.isEmpty ? "Personal Agent" : agentName)
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(HomeSpec.textPrimary)
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("profile.agent-name-label")
                Button {
                    editingAgentName = true
                } label: {
                    Label("编辑名称", systemImage: "pencil")
                        .font(.subheadline.weight(.medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(HomeSpec.textSecondary)
                .padding(.bottom, 8)
                .accessibilityIdentifier("profile.agent-name-edit")
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
        }
    }

    private var personalizationSection: some View {
        Section {
            TextField("如何称呼你", text: $ownerName)
                .accessibilityIdentifier("profile.owner-name")
            Button("保存称呼到 Memory") {
                Task { await saveOwnerName() }
            }
            .accessibilityIdentifier("profile.owner-name-save")
            if let errorMessage {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(NativeParityTokens.warning)
            }
        } header: {
            Text("个性化")
        } footer: {
            Text("称呼会保存到个人 Memory，并用于后续回答。")
        }
    }

    private var taskSection: some View {
        Section {
            NavigationLink {
                NativeAutomationPage()
            } label: {
                LabeledContent("定时任务") {
                    if let enabledAutomationCount {
                        Text("\(enabledAutomationCount) 个已开启")
                            .foregroundStyle(HomeSpec.textSecondary)
                    }
                }
            }
            .accessibilityIdentifier("profile.automations")

            Toggle(isOn: Binding(
                get: { notifications.isEnabled },
                set: { enabled in Task { await notifications.setEnabled(enabled) } }
            )) {
                Text("通知")
            }
            .accessibilityIdentifier("profile.notifications")

            if notifications.authorization == .denied {
                Button("去系统设置允许通知") {
                    notifications.requiresSystemSettings = true
                }
            }
        } header: {
            Text("任务与通知")
        } footer: {
            Text(notificationFooter)
        }
    }

    private var memorySection: some View {
        Section {
            NavigationLink {
                PersonalMemoryPage(store: composition.memories,
                                   principal: composition.personalModel.principal,
                                   domainStore: composition.domain)
            } label: {
                Label("Memory", systemImage: "person.crop.circle")
            }
            .accessibilityIdentifier("profile.memory")
        } header: {
            Text("个人上下文")
        } footer: {
            Text("查看记忆来源，或修正、归档和遗忘已保存的内容。")
        }
    }

    private var agentNameEditor: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("名称", text: $agentName)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("profile.agent-name")
                        .onSubmit { finishEditingAgentName() }
                } header: {
                    Text("Agent 名称")
                } footer: {
                    Text("名称会立即同步到 Chat。")
                }
            }
            .homeGroupedList()
            .navigationTitle("编辑名称")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { finishEditingAgentName() }
                        .disabled(agentName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .homeSheetChrome()
        .onDisappear { normalizeAgentName() }
    }

    private var notificationFooter: String {
        notifications.isEnabled
            ? "系统已允许 Personal Agent 本地通知。"
            : "系统未允许通知，Personal Agent 不会发送本地通知。"
    }

    private var notificationSettingsMessage: String {
        notifications.isEnabled
            ? "系统权限只能在设置中关闭。关闭后，Personal Agent 不会发送本地通知。"
            : "通知权限尚未允许。请在系统设置中允许通知，然后返回这里。"
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

    private func finishEditingAgentName() {
        normalizeAgentName()
        editingAgentName = false
    }

    private func normalizeAgentName() {
        let name = agentName.trimmingCharacters(in: .whitespacesAndNewlines)
        agentName = name.isEmpty ? "小肥鱼" : name
    }

    private func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}
