// SPDX-License-Identifier: MIT
// Bot chat: tell the user before they send that the selected model service needs a Tono account
// sign-in (spec/ui/v1/pages/bot-chat.md, 「需要登录」提示). Without it a message is admitted, the
// phone's model gateway finds no credential and the turn ends as 「回合失败：no credential is
// configured for the upstream host」, which says nothing the user can act on.

import PhoneDSH
import SwiftUI

/// Where `BotChatPage` puts the banner: directly below the transcript, above the activity band.
struct BotSignInBannerSlot: ViewModifier {
    /// Cached: the page body re-runs on every streamed token, and this reads UserDefaults and the
    /// Keychain, so it is refreshed only on an account change, on appear and when the sheet closes.
    @State private var requirement: BotSignInRequirement = .none
    @State private var account: TonoAccountState?
    @State private var showingSignIn = false

    func body(content: Content) -> some View {
        VStack(spacing: 0) {
            content
            if case .signIn = requirement {
                BotSignInBanner(requirement: requirement) { showingSignIn = true }
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: requirement)
        .onAppear(perform: refresh)
        .task {
            for await value in await TonoAccountSession.shared.states() {
                account = value
                refresh()
            }
        }
        .sheet(isPresented: $showingSignIn, onDismiss: refresh) {
            NavigationStack {
                TonoAccountPage()
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("完成") { showingSignIn = false }
                        }
                    }
            }
        }
    }

    private func refresh() {
        // Unknown until the session reports its first state: never flash the banner at launch.
        guard let account else { requirement = .none; return }
        let settings = PhoneModelProviderSettings.shared
        guard let profile = (try? settings.load())?.selected else { requirement = .none; return }
        let hasKey = (try? settings.hasAPIKey(for: profile.id)) ?? true
        requirement = BotSignInRequirement.resolve(account: account, profileBaseURL: profile.baseURL,
                                                   hasStoredKey: hasKey)
    }
}

struct BotSignInBanner: View {
    let requirement: BotSignInRequirement
    let signIn: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "person.crop.circle.badge.exclamationmark")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(requirement.title).font(.subheadline.weight(.semibold)).foregroundStyle(HomeSpec.textPrimary)
                Text(requirement.detail).font(.caption).foregroundStyle(HomeSpec.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 4)
            Button(action: signIn) {
                Text("去登录").font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 14).padding(.vertical, 7)
                    .background(HomeSpec.textPrimary, in: Capsule())
                    .foregroundStyle(HomeSpec.page)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("bot.signin.open")
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(HomeSpec.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(HomeSpec.borderList, lineWidth: 0.5))
        .padding(.horizontal, HomeSpec.contentInset)
        .padding(.top, 6)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("bot.signin.banner")
    }
}
