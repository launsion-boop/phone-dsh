// SPDX-License-Identifier: MIT
// phone-dsh SDK — PhoneDSH: cloud wallet, claim and credits notices.
//
// spec/v1/tono-account.md §10–§11 (PC-20261121-cloud-wallet-credits). The
// wallet is read and claimed only with a signed-in user's access token, never
// an API key. A cloud-origin 402 is classified by the gateway policy and
// posted to `TonoCloudCreditsSignal`; the app's credits store turns it into
// one notice and re-reads the wallet. The shared cases
// (`spec/v1/golden/tono-account/cases.json`: `wallet_responses`,
// `claim_responses`, `credit_display`, `credits_guidance`) judge this file.

import Foundation
import PhoneDSHGateway

public typealias TonoCreditsCondition = TonoCloudResponsePolicy.CreditsCondition

/// What the wallet page may show. Counters are micro-credit decimal strings.
public struct TonoCloudWallet: Equatable, Sendable {
    public var availableMicroCredits: String
    public var claimable: Bool
    /// `shadow`, `live` or a future value; informational only.
    public var mode: String?

    public init(availableMicroCredits: String, claimable: Bool, mode: String?) {
        self.availableMicroCredits = availableMicroCredits
        self.claimable = claimable
        self.mode = mode
    }

    /// §10 display: credits, truncated to two decimals.
    public var displayCredits: String { TonoCloudWalletProtocol.displayCredits(availableMicroCredits) ?? "0" }
}

public enum TonoCloudWalletProtocol {
    public static let walletPath = "/v1/wallet"
    public static let claimPath = "/v1/wallet/claim"
    public static let microCreditsPerCredit = 1_000_000
    public static let microCreditsMaxDigits = 30

    public enum ReadOutcome: Equatable, Sendable {
        case wallet(TonoCloudWallet)
        case protocolError
        case unauthorized
        case rejected
        case unavailable
        case transient
    }

    public enum ClaimOutcome: Equatable, Sendable {
        case claimed(grantedNow: Bool, wallet: TonoCloudWallet)
        case protocolError
        case unauthorized
        case rejected
        case unavailable
        case transient
    }

    /// §11 guidance for one credits condition.
    public enum Guidance: String, Equatable, Sendable {
        case claim
        case exhausted
        case unknown
    }

    // MARK: Requests

    public static func walletRequest(origin: URL, accessToken: String) -> URLRequest {
        request(origin: origin, path: walletPath, method: "GET", accessToken: accessToken)
    }

    public static func claimRequest(origin: URL, accessToken: String) -> URLRequest {
        var request = request(origin: origin, path: claimPath, method: "POST", accessToken: accessToken)
        request.httpBody = Data()
        return request
    }

    private static func request(origin: URL, path: String, method: String, accessToken: String) -> URLRequest {
        var request = URLRequest(url: origin.appendingPathComponent(String(path.dropFirst())))
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        return request
    }

    // MARK: Classification

    public static func classifyRead(_ answer: TonoAccountProtocol.Answer?) -> ReadOutcome {
        guard let answer else { return .transient }
        switch answer.status {
        case 200..<300:
            guard let object = jsonObject(answer.body), let wallet = wallet(object) else { return .protocolError }
            return .wallet(wallet)
        case 401: return .unauthorized
        case 403: return .rejected
        case 404: return .unavailable
        default: return .transient
        }
    }

    public static func classifyClaim(_ answer: TonoAccountProtocol.Answer?) -> ClaimOutcome {
        guard let answer else { return .transient }
        switch answer.status {
        case 200..<300:
            guard let object = jsonObject(answer.body),
                  let grantedNow = object["granted_now"] as? Bool, isBoolean(object["granted_now"]),
                  let walletObject = object["wallet"] as? [String: Any],
                  let wallet = wallet(walletObject) else { return .protocolError }
            return .claimed(grantedNow: grantedNow, wallet: wallet)
        case 401: return .unauthorized
        case 403: return .rejected
        case 404: return .unavailable
        default: return .transient
        }
    }

    /// A valid §10 wallet object, or `nil`.
    static func wallet(_ object: [String: Any]) -> TonoCloudWallet? {
        guard let available = object["available_micro_credits"] as? String,
              isMicroCredits(available),
              let claimable = object["claimable"] as? Bool, isBoolean(object["claimable"]) else { return nil }
        var mode: String?
        if let raw = object["mode"] {
            guard let string = raw as? String else { return nil }
            mode = string
        }
        return TonoCloudWallet(availableMicroCredits: available, claimable: claimable, mode: mode)
    }

    /// 1…30 ASCII digits.
    public static func isMicroCredits(_ value: String) -> Bool {
        let bytes = value.utf8
        return !bytes.isEmpty && bytes.count <= microCreditsMaxDigits
            && bytes.allSatisfy { $0 >= 0x30 && $0 <= 0x39 }
    }

    /// §10: micro-credits ÷ 1 000 000, truncated to two decimals, trailing
    /// zeros and point removed, no grouping. `nil` for an invalid value.
    public static func displayCredits(_ micro: String) -> String? {
        guard isMicroCredits(micro) else { return nil }
        var digits = Array(micro.drop { $0 == "0" })
        if digits.count < 7 { digits = Array(repeating: "0", count: 7 - digits.count) + digits }
        let integer = String(digits.dropLast(6))
        var fraction = String(digits.suffix(6).prefix(2))
        while fraction.hasSuffix("0") { fraction.removeLast() }
        return fraction.isEmpty ? integer : "\(integer).\(fraction)"
    }

    /// §11 rule 2.
    public static func guidance(_ condition: TonoCreditsCondition, walletClaimable: Bool?) -> Guidance {
        switch condition {
        case .notClaimed: return .claim
        case .insufficient: return .exhausted
        case .unspecified:
            guard let walletClaimable else { return .unknown }
            return walletClaimable ? .claim : .exhausted
        }
    }

    private static func jsonObject(_ body: Data) -> [String: Any]? {
        try? JSONSerialization.jsonObject(with: body) as? [String: Any]
    }

    /// `JSONSerialization` bridges JSON numbers 0/1 to `Bool`; only a JSON
    /// boolean counts.
    private static func isBoolean(_ value: Any?) -> Bool {
        guard let number = value as? NSNumber else { return false }
        return CFGetTypeID(number) == CFBooleanGetTypeID()
    }
}

/// §10: wallet read and claim over the account transport (no redirects,
/// bounded body). §5 applies: one refresh and re-send on 401
/// `credential_expired` when the token changed.
public struct TonoCloudWalletClient: Sendable {
    public let origin: URL
    private let transport: any TonoAccountTransport
    private let tokens: any TonoAccessTokenSource

    public init(origin: URL = URL(string: TonoCloudResponsePolicy.cloudOrigin)!,
                transport: any TonoAccountTransport,
                tokens: any TonoAccessTokenSource) {
        self.origin = origin
        self.transport = transport
        self.tokens = tokens
    }

    /// `nil` when signed out (the wallet is never read with an API key).
    public func read() async -> TonoCloudWalletProtocol.ReadOutcome? {
        guard let answer = await exchange({ TonoCloudWalletProtocol.walletRequest(origin: origin, accessToken: $0) })
        else { return nil }
        return TonoCloudWalletProtocol.classifyRead(answer.answer)
    }

    /// `nil` when signed out.
    public func claim() async -> TonoCloudWalletProtocol.ClaimOutcome? {
        guard let answer = await exchange({ TonoCloudWalletProtocol.claimRequest(origin: origin, accessToken: $0) })
        else { return nil }
        return TonoCloudWalletProtocol.classifyClaim(answer.answer)
    }

    private struct Exchanged { var answer: TonoAccountProtocol.Answer? }

    private func exchange(_ make: (String) -> URLRequest) async -> Exchanged? {
        let token: String
        do {
            guard let value = try await tokens.accessToken() else { return nil }
            token = value
        } catch {
            return Exchanged(answer: nil)
        }
        let first = try? await transport.send(make(token))
        guard let first, first.status == 401,
              TonoCloudResponsePolicy.production.decide(url: URL(string: TonoCloudResponsePolicy.cloudOrigin)!,
                                                         status: 401, headers: first.headers,
                                                         body: first.body) == .refreshRetry else {
            return Exchanged(answer: first)
        }
        await tokens.invalidate(accessToken: token)
        guard let fresh = try? await tokens.accessToken(), fresh != token else { return Exchanged(answer: first) }
        return Exchanged(answer: try? await transport.send(make(fresh)))
    }
}

/// Process-wide broadcast of §11 credits conditions. Posting has no side
/// effect when nobody listens (tests, a host without the credits UI).
public enum TonoCloudCreditsSignal {
    private static let state = Locked()

    public static func post(_ condition: TonoCreditsCondition) {
        for continuation in state.snapshot() { continuation.yield(condition) }
    }

    public static func conditions() -> AsyncStream<TonoCreditsCondition> {
        AsyncStream { continuation in
            let id = state.add(continuation)
            continuation.onTermination = { _ in state.remove(id) }
        }
    }

    private final class Locked: @unchecked Sendable {
        private let lock = NSLock()
        private var next = 0
        private var listeners: [Int: AsyncStream<TonoCreditsCondition>.Continuation] = [:]

        func add(_ continuation: AsyncStream<TonoCreditsCondition>.Continuation) -> Int {
            lock.lock(); defer { lock.unlock() }
            next += 1
            listeners[next] = continuation
            return next
        }

        func remove(_ id: Int) {
            lock.lock(); defer { lock.unlock() }
            listeners[id] = nil
        }

        func snapshot() -> [AsyncStream<TonoCreditsCondition>.Continuation] {
            lock.lock(); defer { lock.unlock() }
            return Array(listeners.values)
        }
    }
}
