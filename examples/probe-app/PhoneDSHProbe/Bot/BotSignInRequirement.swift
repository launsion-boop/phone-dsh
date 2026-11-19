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
