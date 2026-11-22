// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — 云端积分：余额、领取和 402 提示（spec/v1/tono-account.md §10–§11）。
//
// One owner for the app. The wallet is read only for a signed-in Tono account,
// when the account page or a credits notice appears and after a claim; it is
// never polled. A cloud-origin 402 reaches this store through
// `TonoCloudCreditsSignal` (gateway, ASR handshake, TTS) and becomes one
// notice; the answer itself already went to DSH unchanged and is never re-sent.

import Foundation
import Observation
import PhoneDSH

@MainActor
@Observable
final class CloudCreditsCenter {
    static let shared = CloudCreditsCenter()

    /// The last valid wallet; `nil` when signed out, not read yet, or the
    /// cloud does not offer a wallet yet (404 before its release).
    private(set) var wallet: TonoCloudWallet?
    /// The cloud answered 404: the credits section stays hidden.
    private(set) var unavailable = false
    /// The current §11 notice, if any.
    private(set) var notice: TonoCloudWalletProtocol.Guidance?
    private(set) var claiming = false
    private(set) var reading = false
    /// One line for the page footer after a failed read or claim.
    private(set) var errorText: String?

    @ObservationIgnored private let client: TonoCloudWalletClient
    @ObservationIgnored private var listening: Task<Void, Never>?
    @ObservationIgnored private var accountWatch: Task<Void, Never>?

    private init() {
        client = TonoCloudWalletClient(transport: URLSessionTonoAccountTransport(),
                                       tokens: TonoAccountSession.shared)
    }

    /// Starts listening for credits answers and account changes. Idempotent.
    func start() {
        if listening == nil {
            listening = Task { [weak self] in
                for await condition in TonoCloudCreditsSignal.conditions() {
                    await self?.observe(condition)
                }
            }
        }
        if accountWatch == nil {
            accountWatch = Task { [weak self] in
                for await state in await TonoAccountSession.shared.states() {
                    guard case .signedIn = state else {
                        self?.clear()
                        continue
                    }
                }
            }
        }
    }

    /// §11 rule 2: raise one notice and re-read the wallet.
    func observe(_ condition: TonoCreditsCondition) async {
        notice = TonoCloudWalletProtocol.guidance(condition, walletClaimable: nil)
        await refresh()
        notice = TonoCloudWalletProtocol.guidance(condition, walletClaimable: wallet?.claimable)
    }

    func dismissNotice() { notice = nil }

    /// §10.1. Signed out: nothing is read and nothing is shown.
    func refresh() async {
        guard !reading else { return }
        reading = true
        defer { reading = false }
        switch await client.read() {
        case nil: clear()
        case .wallet(let value)?:
            wallet = value; unavailable = false; errorText = nil
        case .unavailable?:
            wallet = nil; unavailable = true; errorText = nil
        case .unauthorized?, .rejected?:
            errorText = "无法读取积分：账号凭据被拒绝，请重新登录。"
        case .protocolError?, .transient?:
            errorText = "暂时无法读取积分，请稍后再试。"
        }
    }

    /// §10.2. One claim in flight; `granted_now: false` is a success.
    func claim() async {
        guard !claiming else { return }
        claiming = true
        defer { claiming = false }
        switch await client.claim() {
        case nil: clear()
        case .claimed(_, let value)?:
            wallet = value; unavailable = false; errorText = nil
            if notice == .claim { notice = nil }
        case .unavailable?:
            unavailable = true; errorText = "云端暂未开放领取积分。"
        case .rejected?:
            errorText = "领取失败：请用 Tono 账号登录后再领取。"
        case .unauthorized?:
            errorText = "领取失败：登录已失效，请重新登录。"
        case .protocolError?, .transient?:
            errorText = "领取失败，请稍后再试。"
        }
    }

    private func clear() {
        wallet = nil; unavailable = false; notice = nil; errorText = nil
    }

    /// §11 rule 3 texts.
    static func text(_ guidance: TonoCloudWalletProtocol.Guidance) -> String {
        switch guidance {
        case .claim: return "还没有领取积分，领取后即可继续使用"
        case .exhausted: return "积分已用完"
        case .unknown: return "云端服务需要积分，请在 Tono 账号中查看"
        }
    }
}
