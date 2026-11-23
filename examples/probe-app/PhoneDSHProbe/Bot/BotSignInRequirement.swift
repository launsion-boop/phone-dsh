// SPDX-License-Identifier: MIT
// Whether the Bot chat must ask the user to sign in to Tono before a message can go out
// (spec/ui/v1/pages/bot-chat.md 「需要登录」提示). Pure; the banner is `BotSignInBanner.swift`.

import PhoneDSH

/// Pure rule, so it is unit-testable without Keychain or UserDefaults.
enum BotSignInRequirement: Equatable {
    /// The selected profile can send: signed in, a stored key, or not the cloud origin.
    case none
    /// The cloud profile has neither a Tono session nor a stored key.
    case signIn(TonoAccountNotice?)

    /// spec/v1/tono-account.md §4: on the cloud origin a signed-in session's token is used, else the
    /// profile's stored key. A signed-in session whose refresh fails is not detected here (it is only
    /// known when a request is made), so it is never reported as signed out.
    static func resolve(account: TonoAccountState, profileBaseURL: String?, hasStoredKey: Bool) -> Self {
        switch account {
        case .signedIn: return resolve(signedIn: true, notice: nil, profileBaseURL: profileBaseURL, hasStoredKey: hasStoredKey)
        case .signedOut(let notice):
            return resolve(signedIn: false, notice: notice, profileBaseURL: profileBaseURL, hasStoredKey: hasStoredKey)
        }
    }

    static func resolve(signedIn: Bool, notice: TonoAccountNotice?, profileBaseURL: String?, hasStoredKey: Bool) -> Self {
        guard let profileBaseURL, CloudVoiceCredential.isCloudOrigin(profileBaseURL) else { return .none }
        if signedIn || hasStoredKey { return .none }
        return .signIn(notice)
    }

    /// The rule over the live settings at the moment of a send. `signedIn` defaults to the stored
    /// session record, which is readable synchronously; a session ended by the server is cleared
    /// from the record, so it reads as signed out here too.
    static func current(signedIn: Bool = TonoAccountSession.shared.hasSession) -> Self {
        let settings = PhoneModelProviderSettings.shared
        guard let profile = (try? settings.load())?.selected else { return .none }
        let hasKey = (try? settings.hasAPIKey(for: profile.id)) ?? true
        return resolve(signedIn: signedIn, notice: nil, profileBaseURL: profile.baseURL, hasStoredKey: hasKey)
    }

    /// spec/ui/v1/pages/bot-chat.md 「需要登录」: a send while sign-in is required is not admitted;
    /// the composer keeps the draft and opens the Tono account sheet instead.
    var holdsSend: Bool {
        if case .signIn = self { return true }
        return false
    }

    var title: String {
        switch self {
        case .none: return ""
        case .signIn(.reverifyRequired): return "Tono 账号需要重新验证，消息暂时发不出去"
        case .signIn(.sessionEnded): return "Tono 账号已退出，消息暂时发不出去"
        case .signIn: return "还没登录 Tono 账号，消息发不出去"
        }
    }

    var detail: String {
        switch self {
        case .signIn(.reverifyRequired): return "登录满 180 天需要用短信验证码再登录一次。"
        case .signIn: return "云端模型要用你的 Tono 账号。用手机号和短信验证码登录后就能继续聊。"
        case .none: return ""
        }
    }
}

/// Whether the selected model service still needs setting up — the 「待配置模型服务」 state of the
/// chat page and Settings. spec/v1/tono-account.md §4: on the cloud origin a signed-in Tono session
/// replaces the stored key, so a cloud profile is ready when signed in or when a key is stored; any
/// other profile needs its stored key. Pure, so it is unit-testable without Keychain or UserDefaults.
enum ModelProviderReadiness {
    static func needsSetup(profileBaseURL: String?, keyStatus: ModelProviderAPIKeyStatus?, signedIn: Bool) -> Bool {
        guard let profileBaseURL else { return true }          // no model service selected
        if keyStatus == .present { return false }
        return !(signedIn && CloudVoiceCredential.isCloudOrigin(profileBaseURL))
    }

    /// The rule over the live settings. `signedIn` comes from the page's observed account state, so the
    /// label changes as soon as the user signs in or out.
    static func needsSetup(signedIn: Bool) -> Bool {
        let settings = PhoneModelProviderSettings.shared
        guard let profile = (try? settings.load())?.selected else { return true }
        return needsSetup(profileBaseURL: profile.baseURL,
                          keyStatus: try? settings.apiKeyStatus(for: profile.id),
                          signedIn: signedIn)
    }
}

extension TonoAccountState {
    var isSignedIn: Bool { if case .signedIn = self { return true } else { return false } }
}
