// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — PhoneDSHGateway: cloud-origin 401/503 policy.
//
// spec/v1/tono-account.md §5–§6. The phoneDSH cloud service answers an
// expired user token with 401 `credential_expired` and a temporarily
// unreachable account service with 503 `identity_unavailable`. Both are
// rejections before any model work, so the gateway may re-send them even for
// a non-replay-safe POST: the first after the credential provider produced a
// different credential, the second after `Retry-After`. Every other answer is
// forwarded exactly as before. The shared cases
// (`spec/v1/golden/tono-account/cases.json`, `cloud_responses`) judge
// `decide(url:status:headers:body:)`.

import Foundation

/// Decides what the gateway does with a 401/503 answer from the cloud origin.
public struct TonoCloudResponsePolicy: Equatable, Sendable {
    /// One exact origin: lowercased scheme and host, effective port.
    public struct Origin: Hashable, Sendable {
        public var scheme: String
        public var host: String
        public var port: Int

        public init?(_ url: URL) {
            guard let scheme = url.scheme?.lowercased(),
                  scheme == "https" || scheme == "http",
                  let host = url.host?.lowercased(), !host.isEmpty else { return nil }
            self.scheme = scheme
            self.host = host
            self.port = url.port ?? (scheme == "https" ? 443 : 80)
        }
    }

    public enum Decision: Equatable, Sendable {
        /// Hand the answer to the Worker unchanged.
        case forward
        /// Invalidate the injected credential, re-resolve it and re-send once
        /// if the value changed.
        case refreshRetry
        /// Wait this many seconds and re-send.
        case retryAfter(TimeInterval)
    }

    /// The production cloud origin (`https://pdsh.tonoai.cn`).
    public static let cloudOrigin = "https://pdsh.tonoai.cn"
    /// At most this many body bytes are read before deciding.
    public static let inspectBodyLimit = 16_384
    /// Re-sends after `credential_expired`, per request.
    public static let credentialRetryMax = 1
    /// Re-sends after `identity_unavailable`, per request.
    public static let identityRetryMax = 2
    /// Delay when `Retry-After` is absent or unusable.
    public static let identityRetryDefaultSeconds: TimeInterval = 1
    /// Upper bound for one `Retry-After` wait.
    public static let identityRetryCapSeconds: TimeInterval = 30

    public static let credentialExpiredCode = "credential_expired"
    public static let identityUnavailableCode = "identity_unavailable"

    /// The production policy: only the cloud origin.
    public static let production = TonoCloudResponsePolicy(origins: [cloudOrigin])
    /// A policy that never inspects anything.
    public static let disabled = TonoCloudResponsePolicy(origins: [])

    public let origins: Set<Origin>

    /// - Parameter origins: absolute origins (`scheme://host[:port]`). Tests
    ///   pass a loopback origin; production uses ``production``.
    public init(origins: [String]) {
        self.origins = Set(origins.compactMap { URL(string: $0).flatMap(Origin.init) })
    }

    /// True when the request's exact origin is one this policy inspects.
    public func applies(to url: URL) -> Bool {
        guard let origin = Origin(url) else { return false }
        return origins.contains(origin)
    }

    /// True for a status whose body must be read before anything is forwarded.
    public func inspects(url: URL, status: Int) -> Bool {
        (status == 401 || status == 503) && applies(to: url)
    }

    /// The decision for one complete (at most ``inspectBodyLimit`` bytes) answer.
    public func decide(url: URL, status: Int, headers: [String: String], body: Data) -> Decision {
        guard inspects(url: url, status: status), body.count <= Self.inspectBodyLimit else {
            return .forward
        }
        let codes = Self.errorCodes(body)
        if status == 401, codes.contains(Self.credentialExpiredCode) {
            return .refreshRetry
        }
        if status == 503, codes.contains(Self.identityUnavailableCode) {
            let raw = headers.first { $0.key.lowercased() == "retry-after" }?.value
            return .retryAfter(Self.retryAfterSeconds(raw))
        }
        return .forward
    }

    /// §6: a non-negative ASCII decimal integer of seconds, capped; anything
    /// else (absent, negative, fractional, an HTTP date) is the default.
    public static func retryAfterSeconds(_ raw: String?) -> TimeInterval {
        guard let raw else { return identityRetryDefaultSeconds }
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed.utf8.count <= 10,
              trimmed.utf8.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }),
              let seconds = Int(trimmed) else {
            return identityRetryDefaultSeconds
        }
        return min(TimeInterval(seconds), identityRetryCapSeconds)
    }

    /// `error.code` and `error.type` of a JSON object body, when they are strings.
    static func errorCodes(_ body: Data) -> Set<String> {
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let error = object["error"] as? [String: Any] else { return [] }
        var codes = Set<String>()
        if let code = error["code"] as? String { codes.insert(code) }
        if let type = error["type"] as? String { codes.insert(type) }
        return codes
    }
}
