// SPDX-License-Identifier: MIT
// PhoneDSHPCLink: PCLink v1 error vocabulary (§9.1) and transport mappings.

import Foundation
import PhoneDSHAgentCore

/// A PCLink-namespace error. This is intentionally not `ProviderError`: the
/// direct-loopback 401/cookie/`Host`/`Origin` semantics of `DSHWebTransport`
/// do not exist on the relay path (§9.2), and mapping a pairing state to
/// `ProviderError.unauthorized` would make a caller re-exchange a token that
/// does not exist. `RelayDSHTransport` translates these cases at its boundary.
public enum PCLinkError: Error, Equatable, CustomStringConvertible, Sendable {
    case unavailable(String)
    /// Local phone-transport outcome: an unsafe call may have executed but no
    /// definitive reply arrived. Never a wire code and never retried.
    case unknownOutcome(endpoint: String)
    case peerOffline
    case unpaired(String)
    case authFailed(String)
    case badFrame(String)
    case frameTooLarge(String)
    case rateLimited(retryAfterMs: Int?)
    case versionUnsupported(String)
    case sessionExpired(String)
    case replay(String)
    case forbidden(String)
    case rendezvousExpired
    case rendezvousExhausted
    case replaced
    case storage(String)
    case noIdentity
    case notPaired
    case alreadyPaired
    case cancelled
    case pairingCancelled
    case pairingRejected
    case pairingTimedOut
    case unsupported(String)

    public var code: String {
        switch self {
        case .unavailable: return "unavailable"
        case .unknownOutcome: return "unknown_outcome"
        case .peerOffline: return "peer_offline"
        case .unpaired: return "unpaired"
        case .authFailed: return "auth_failed"
        case .badFrame: return "bad_frame"
        case .frameTooLarge: return "frame_too_large"
        case .rateLimited: return "rate_limited"
        case .versionUnsupported: return "version_unsupported"
        case .sessionExpired: return "session_expired"
        case .replay: return "replay"
        case .forbidden: return "forbidden"
        case .rendezvousExpired: return "rendezvous_expired"
        case .rendezvousExhausted: return "rendezvous_exhausted"
        case .replaced: return "replaced"
        case .storage: return "storage"
        case .noIdentity: return "no_identity"
        case .notPaired: return "not_paired"
        case .alreadyPaired: return "already_paired"
        case .cancelled: return "cancelled"
        case .pairingCancelled: return "cancelled"
        case .pairingRejected: return "rejected"
        case .pairingTimedOut: return "timeout"
        case .unsupported: return "unavailable"
        }
    }

    public var message: String {
        switch self {
        case .unavailable(let message),
             .unpaired(let message),
             .authFailed(let message),
             .badFrame(let message),
             .frameTooLarge(let message),
             .versionUnsupported(let message),
             .sessionExpired(let message),
             .replay(let message),
             .forbidden(let message),
             .storage(let message),
             .unsupported(let message):
            return message
        case .unknownOutcome(let endpoint):
            return "may have executed but no definitive reply arrived for \(endpoint)"
        case .peerOffline:
            return "the paired PC is offline"
        case .rateLimited(let retryAfterMs):
            if let retryAfterMs { return "rate limited; retry after \(retryAfterMs) ms" }
            return "rate limited"
        case .rendezvousExpired:
            return "the pairing code expired"
        case .rendezvousExhausted:
            return "the pairing code was already used or exhausted"
        case .replaced:
            return "a newer connection replaced this one"
        case .noIdentity:
            return "the phone identity key is missing"
        case .notPaired:
            return "no paired computer"
        case .alreadyPaired:
            return "a computer is already paired; unpair it first"
        case .cancelled:
            return "the operation was cancelled"
        case .pairingCancelled:
            return "the pairing was cancelled"
        case .pairingRejected:
            return "the PC operator rejected the pairing"
        case .pairingTimedOut:
            return "the pairing timed out"
        }
    }

    public var description: String { "[\(code)] \(message)" }
    public var errorDescription: String? { description }

    /// PCLink codes defined by §9.1.
    public static let knownCodes: Set<String> = [
        "unavailable", "unknown_outcome", "peer_offline", "unpaired",
        "auth_failed", "replaced", "session_expired", "replay", "bad_frame",
        "frame_too_large", "rate_limited", "version_unsupported",
        "rendezvous_expired", "rendezvous_exhausted", "rekey", "forbidden",
    ]

    public static func code(_ code: String, message: String = "") -> PCLinkError {
        switch code {
        case "unavailable": return .unavailable(message)
        case "unpaired": return .unpaired(message)
        case "auth_failed": return .authFailed(message)
        case "replaced": return .replaced
        case "session_expired": return .sessionExpired(message)
        case "replay": return .replay(message)
        case "bad_frame": return .badFrame(message)
        case "frame_too_large": return .frameTooLarge(message)
        case "rate_limited": return .rateLimited(retryAfterMs: nil)
        case "version_unsupported": return .versionUnsupported(message)
        case "rendezvous_expired": return .rendezvousExpired
        case "rendezvous_exhausted": return .rendezvousExhausted
        case "forbidden": return .forbidden(message)
        case "peer_offline": return .peerOffline
        case "unknown_outcome": return .unavailable(message)
        default: return .badFrame("unknown PCLink code \(code)")
        }
    }

    /// Whether a caller may retry the same logical operation after this error.
    public var isRetryable: Bool {
        switch self {
        case .unavailable, .peerOffline, .rateLimited, .sessionExpired, .replaced:
            return true
        default:
            return false
        }
    }
}

/// Internal control-flow error: the established session went away while a
/// request was in flight. The transport uses it to apply §7 retry classes.
struct PCLinkSessionLost: Error, Equatable {
    let reason: PCLinkError
}

/// `ProviderError`-shaped projection used by `RelayDSHTransport`. It never
/// produces `.unauthorized`, because relay `unpaired`/`auth_failed` are
/// pairing states, not credential refreshes (§9.2).
public enum PCLinkErrorMapping {
    public static func providerError(for error: PCLinkError) -> ProviderError {
        switch error {
        case .unavailable: return .unavailable(retryAfter: nil)
        case .peerOffline: return .unavailable(retryAfter: nil)
        case .rateLimited(let retryAfterMs):
            return .rateLimited(retryAfter: retryAfterMs.map { Double($0) / 1000 })
        case .unpaired(let message): return .invalidRequest("unpaired: \(message)")
        case .authFailed(let message): return .invalidRequest("auth_failed: \(message)")
        case .versionUnsupported(let message): return .unsupported("version_unsupported: \(message)")
        case .badFrame(let message): return .invalidResponse("bad_frame: \(message)")
        case .frameTooLarge(let message): return .invalidRequest("frame_too_large: \(message)")
        case .sessionExpired: return .unavailable(retryAfter: nil)
        case .replay(let message): return .invalidResponse("replay: \(message)")
        case .forbidden(let message): return .invalidRequest("forbidden: \(message)")
        case .rendezvousExpired: return .invalidRequest("rendezvous_expired")
        case .rendezvousExhausted: return .invalidRequest("rendezvous_exhausted")
        case .replaced: return .unavailable(retryAfter: 30)
        case .storage(let message): return .invalidRequest("storage: \(message)")
        case .noIdentity: return .invalidRequest("no_identity: re-pair this phone")
        case .notPaired: return .invalidRequest("not_paired")
        case .alreadyPaired: return .invalidRequest("already_paired")
        case .cancelled, .pairingCancelled: return .cancelled
        case .pairingRejected: return .invalidRequest("rejected")
        case .pairingTimedOut: return .unavailable(retryAfter: nil)
        case .unsupported(let message): return .unsupported(message)
        case .unknownOutcome: return .invalidRequest("unknown_outcome")
        }
    }
}


/// A DSH endpoint error carried by `rpc.result`/`rpc.stream.error`. It is a
/// different namespace from PCLink codes and is passed through unchanged; the
/// only PCLink code allowed inside it is `forbidden` (§9.1).
public struct PCLinkRPCError: Error, Equatable, Sendable, CustomStringConvertible {
    public var code: String
    public var message: String
    public var details: PCLinkJSON?

    public init(code: String, message: String, details: PCLinkJSON? = nil) {
        self.code = code
        self.message = message
        self.details = details
    }

    public var description: String { "[\(code)] \(message)" }
    public var errorDescription: String? { description }

    /// `DSHRemoteError` is the PhoneDSHAgentCore error shape understood by
    /// `DSHRemoteHarness` and maps to the same `ProviderError` branches it
    /// already uses for direct DSH Remote.
    public var dshRemoteError: DSHRemoteError {
        DSHRemoteError(code: code, message: message, details: details?.jsonValue)
    }
}
