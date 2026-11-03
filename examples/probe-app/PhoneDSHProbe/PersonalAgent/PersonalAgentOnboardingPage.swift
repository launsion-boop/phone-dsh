// SPDX-License-Identifier: MIT

import SwiftUI

struct PersonalAgentOnboardingPage: View {
    @AppStorage("personalAgent.displayName") private var agentName = "小肥鱼"
    @AppStorage("personalAgent.ownerName") private var ownerName = ""
    @AppStorage("personalAgent.onboarding.completed") private var completed = false
    @State private var composition = AppComposition.shared
    @State private var step = 1
    @State private var ownerDraft = ""
    @State private var agentDraft = "小肥鱼"
    @State private var isSaving = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Spacer()
            Text("第 \(step) 步，共 2 步")
                .font(.subheadline)
                .foregroundStyle(HomeSpec.textSecondary)
            if step == 1 { ownerStep } else { agentStep }
            Spacer()
            if let errorMessage {
                Text(errorMessage)
                    .font(.subheadline)
                    .foregroundStyle(NativeParityTokens.warning)
            }
            HStack {
                if step == 2 {
                    Button("上一步") { step = 1 }
                        .disabled(isSaving)
                        .accessibilityIdentifier("onboarding.back")
                }
                Spacer()
                Button(step == 1 ? "继续" : "开始使用") {
                    if step == 1 {
                        step = 2
                    } else {
                        Task { await finish() }
                    }
                }
                .buttonStyle(HomePrimaryButtonStyle())
                .disabled(isSaving || (step == 1 ? ownerDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                                : agentDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
                .accessibilityIdentifier(step == 1 ? "onboarding.continue" : "onboarding.finish")
            }
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(HomeSpec.page)
        .interactiveDismissDisabled()
        .task { prepare() }
    }

    private var ownerStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("先认识一下")
                .font(.largeTitle.bold())
            Text("你希望我怎么称呼你？")
                .font(.title3)
                .foregroundStyle(HomeSpec.textSecondary)
            TextField("你的名字或称呼", text: $ownerDraft)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("onboarding.owner-name")
        }
    }

    private var agentStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("给你的 Personal Agent 取个名字")
                .font(.largeTitle.bold())
            Text("以后会显示在 Chat 顶栏。默认叫小肥鱼，也可以改成你喜欢的名字。")
                .font(.title3)
                .foregroundStyle(HomeSpec.textSecondary)
            TextField("Agent 名称", text: $agentDraft)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("onboarding.agent-name")
        }
    }

    private func prepare() {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-resetPersonalOnboarding") {
            completed = false
            ownerName = ""
            agentName = "小肥鱼"
        }
        #endif
        ownerDraft = ownerName
        agentDraft = agentName.isEmpty ? "小肥鱼" : agentName
        step = 1
    }

    private func finish() async {
        guard !isSaving else { return }
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }
        do {
            await composition.personalModel.load()
            try await composition.savePreferredOwnerName(ownerDraft)
            ownerName = ownerDraft.trimmingCharacters(in: .whitespacesAndNewlines)
            agentName = agentDraft.trimmingCharacters(in: .whitespacesAndNewlines)
            completed = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
