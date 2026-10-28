// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — PhoneDSHLoopback: `/v1/http` egress
// failures, classified and made diagnosable.
//
// The upstream response can only be written once the egress stream yields its
// first chunk. If the stream throws first, the loopback origin answers with a
// proxy error instead (spec/exec-bridge-v1 §6: 403 when the host denies the
// origin, 502 for a proxy-side failure, `X-PDSH-Proxy-Error: <code>`). This type
// is that answer. It preserves the machine-readable cause, the human message
// and the bridged `NSError` identity of the failure, so a host-not-allowed, a
// missing credential and a transport failure never collapse into one generic
// body again (G2-FIX-32).
//
// ENG-04 adds the closed egress-failure taxonomy and the JSON envelope the
// Worker-side curl shim can read without guessing:
//
//   `{"error":{...}, "xl_error":{"code","host","detail"}}`
//
// `error` is the spec/exec-bridge-v1 §1 envelope retained from G2-FIX-32 (its
// `code` stays the most specific stable cause, e.g. `credential_unavailable`).
// `xl_error.code` is always one of the seven classes in
// ``HTTPEgressFailureClass``, `xl_error.host` names the denied/failed upstream
// host and `xl_error.detail` is the sanitized human reason. Neither member
// ever carries a request header, a URL path/query or a credential.
//
// Cross-module contract: `PhoneDSHGateway` cannot import this module
// (PLAN §2.1 dependency direction), so a structured gateway failure reaches
// the writer as `any Error` and is read through Foundation's standard
// `NSError` keys:
//
//   `NSLocalizedFailureReasonErrorKey` — the stable cause code
//     (`host_not_allowed`, `credential_unavailable`, `transport_failure`, …)
//   `NSLocalizedDescriptionKey`        — the human message
//   `NSUnderlyingErrorKey`             — the transport cause
//     (`NSURLErrorDomain`/`-1003`, …)
//
// An `HTTPEgress` implementation may also throw this type directly.

import Foundation

// MARK: - Failure taxonomy

/// The closed cause taxonomy of the `/v1/http` egress (ENG-04).
///
/// Exactly one class answers every pre-response egress failure. The class
/// drives the HTTP status and the `xl_error.code` member (the more specific
/// stable cause still drives `X-PDSH-Proxy-Error`), so the Worker (and the curl
/// shim) can tell a blocked host from DNS, TLS, timeout, upstream and
/// transport failures without parsing prose.
public enum HTTPEgressFailureClass: String, CaseIterable, Equatable, Sendable {
    /// The gateway's allow-list (model upstream ∪ `egressAllowHosts`) denied
    /// the target host.
    case hostNotAllowed = "host_not_allowed"
    /// The upstream host name could not be resolved.
    case dnsFailed = "dns_failed"
    /// The TLS handshake or certificate validation failed.
    case tlsFailed = "tls_failed"
    /// The connection attempt timed out (the 504 case).
    case connectTimeout = "connect_timeout"
    /// The upstream answered with a status the model-side caller turns into a
    /// failure (retries exhausted / caller needs a 2xx).
    case upstreamStatus = "upstream_status"
    /// The response exceeded the host's per-response body budget (a producer
    /// that enforces one reports this class; the plain streaming proxy has no
    /// implicit cap).
    case bodyTooLarge = "body_too_large"
    /// Any other transport failure (connection reset, offline, truncated body,
    /// stream ended before the response head, …).
    case transportFailed = "transport_failed"

    /// HTTP status the writer answers with for this class.
    public var httpStatus: Int {
        switch self {
        case .hostNotAllowed:
            return 403
        case .connectTimeout:
            return 504
        case .dnsFailed, .tlsFailed, .upstreamStatus, .bodyTooLarge, .transportFailed:
            return 502
        }
    }

    /// The class for an explicit stable code, if the producer already used a
    /// taxonomy member. `nil` means the code is not part of the taxonomy and
    /// the cause must be inferred from the bridged `NSError` identity.
    init?(explicitCode: String) {
        self.init(rawValue: explicitCode)
    }

    /// Classifies the stable reason code plus the bridged `NSError` identities
    /// of one egress error. This is the single decision point: every writer
    /// answer goes through it.
    ///
    /// A URL error identity is authoritative when the stable code is generic
    /// (`transport_failure` / `upstream_failed` / unknown), because the
    /// gateway keeps the original `NSURLError` domain and code; an explicit
    /// taxonomy code wins over it.
    public static func classify(code: String?,
                                source: HTTPEgressFailure.Cause?,
                                underlying: HTTPEgressFailure.Cause?) -> HTTPEgressFailureClass {
        if let code, let explicit = HTTPEgressFailureClass(explicitCode: code) {
            return explicit
        }
        if let cause = underlying ?? source, cause.domain == NSURLErrorDomain {
            if let classified = classify(urlErrorCode: cause.code) {
                return classified
            }
        }
        return .transportFailed
    }

    /// Refines the seven taxonomy members that have a URL Loading System
    /// identity. Unknown URL error codes stay generic transport failures.
    static func classify(urlErrorCode code: Int) -> HTTPEgressFailureClass? {
        switch code {
        case NSURLErrorDNSLookupFailed, NSURLErrorCannotFindHost:
            return .dnsFailed
        case NSURLErrorSecureConnectionFailed,
             NSURLErrorServerCertificateHasBadDate,
             NSURLErrorServerCertificateUntrusted,
             NSURLErrorServerCertificateHasUnknownRoot,
             NSURLErrorServerCertificateNotYetValid,
             NSURLErrorClientCertificateRejected,
             NSURLErrorClientCertificateRequired,
             NSURLErrorAppTransportSecurityRequiresSecureConnection:
            return .tlsFailed
        case NSURLErrorTimedOut:
            return .connectTimeout
        case NSURLErrorDataLengthExceedsMaximum:
            return .bodyTooLarge
        default:
            return nil
        }
    }
}

// MARK: - Structured failure

/// Structured cause of one `/v1/http` egress failure before the response head.
public struct HTTPEgressFailure: Error, Equatable, Sendable {
    /// `NSError`-style identity of one cause.
    public struct Cause: Equatable, Sendable {
        /// Error domain, for example `NSURLErrorDomain`.
        public var domain: String
        /// Error code within `domain`.
        public var code: Int

        public init(domain: String, code: Int) {
            self.domain = domain
            self.code = code
        }
    }

    /// Top-level member name of the Worker-facing classification envelope.
    public static let errorBodyKey = "xl_error"

    /// HTTP status the writer answers with.
    public var status: Int
    /// Stable lower-snake cause code (`host_not_allowed`, …). This is the
    /// G2-FIX-32 value carried in `X-PDSH-Proxy-Error`; the seven-class taxonomy
    /// is exposed separately as ``classification``.
    public var code: String
    /// Human-readable cause; never contains a credential.
    public var message: String
    /// Upstream host the failure is attributed to, when the target is known.
    /// Never contains a userinfo, a port credential or a path.
    public var host: String?
    /// Identity of the error that produced this failure, when it has one.
    public var source: Cause?
    /// Transport cause from `NSUnderlyingErrorKey`, when present.
    public var underlying: Cause?

    public init(status: Int, code: String, message: String, host: String? = nil,
                source: Cause? = nil, underlying: Cause? = nil) {
        self.status = status
        let sanitizedCode = Self.sanitizedCode(code)
        self.code = sanitizedCode.isEmpty ? "upstream_failed" : sanitizedCode
        self.message = Self.sanitizedMessage(message)
        self.host = Self.sanitizedHost(host)
        self.source = source
        self.underlying = underlying
    }

    /// Stable cause code carried in `NSLocalizedFailureReasonErrorKey` by the
    /// producing error (the value `PhoneDSHGateway` writes there).
    public static let codeUserInfoKey = NSLocalizedFailureReasonErrorKey

    /// One classification for this failure (ENG-04).
    public var classification: HTTPEgressFailureClass {
        HTTPEgressFailureClass.classify(code: code, source: source, underlying: underlying)
    }

    /// Derives the structured failure from any egress stream error.
    ///
    /// This is the unified `EgressFailure → HTTP response` mapping: it reads
    /// the stable reason code and the bridged cause, picks one taxonomy class,
    /// and fixes the status/body the loopback writer sends. `target` is the
    /// upstream URL taken from the `/v1/http` request; only its host is kept.
    public init(error: any Error, target: String? = nil) {
        if let failure = error as? HTTPEgressFailure {
            self = failure.attachingHost(Self.host(fromTarget: target))
            return
        }
        let bridged = error as NSError
        var code = "upstream_failed"
        if let token = bridged.userInfo[Self.codeUserInfoKey] as? String {
            let sanitized = Self.sanitizedCode(token)
            if !sanitized.isEmpty { code = sanitized }
        }
        let description = (bridged.userInfo[NSLocalizedDescriptionKey] as? String)
            ?? bridged.localizedDescription
        let source = bridged.domain.isEmpty
            ? nil
            : Cause(domain: bridged.domain, code: bridged.code)
        let underlying = (bridged.userInfo[NSUnderlyingErrorKey] as? NSError).map {
            Cause(domain: $0.domain, code: $0.code)
        }
        let classification = HTTPEgressFailureClass.classify(
            code: code, source: source, underlying: underlying)
        // Explicit request-shape errors keep their G2-FIX-32 status; every
        // proxy-side failure takes the class status (502, or 504 for timeout).
        let status: Int
        switch Self.status(forCode: code) {
        case 400, 403:
            status = Self.status(forCode: code)
        default:
            status = classification.httpStatus
        }
        self.init(status: status,
                  code: code,
                  message: description,
                  host: Self.host(fromTarget: target),
                  source: source,
                  underlying: underlying)
    }

    /// The egress stream ended before yielding a response head. That is a
    /// contract violation of `HTTPEgress`, not an upstream failure.
    public static let noResponse = HTTPEgressFailure(
        status: 502,
        code: "egress_no_response",
        message: "the egress produced no response head")

    /// Returns a copy attributed to `host` when this failure has no host yet.
    public func attachingHost(_ host: String?) -> HTTPEgressFailure {
        guard let sanitized = Self.sanitizedHost(host), self.host == nil else { return self }
        var copy = self
        copy.host = sanitized
        return copy
    }

    /// Maps a stable cause code to the status spec/exec-bridge-v1 §6 assigns:
    /// 403 when the host denies the origin, 400 for a malformed request, 504
    /// for a connect timeout and 502 for every other proxy-side failure.
    public static func status(forCode code: String) -> Int {
        switch code {
        case "host_not_allowed", "forbidden":
            return 403
        case "invalid_request", "bad_request":
            return 400
        case "connect_timeout":
            return 504
        default:
            return 502
        }
    }

    /// Drops userinfo, query and fragment from a target so the run-log line
    /// never records a credential that a caller smuggled into the URL.
    public static func sanitizedTarget(_ target: String) -> String? {
        guard let url = URL(string: target), let scheme = url.scheme,
              let host = url.host else { return nil }
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.port = url.port
        components.path = url.path
        return components.string
    }

    /// Extracts the bare host of an upstream target. Userinfo, path, query and
    /// fragment are dropped: the answer must never echo a credential that a
    /// caller smuggled into the URL.
    public static func host(fromTarget target: String?) -> String? {
        guard let target, !target.isEmpty, let url = URL(string: target) else { return nil }
        return sanitizedHost(url.host)
    }

    /// Canonical JSON error envelope (spec/exec-bridge-v1 §1):
    /// `{"error":{"code","message","details"}}` retained for G2-FIX-32
    /// clients, plus the ENG-04 `xl_error` classification envelope:
    /// `{"xl_error":{"code","host","detail"}}`.
    public func encodedBody() -> Data {
        var error: [String: CanonicalJSONValue] = [
            "code": .string(code),
            "message": .string(message),
        ]
        var details: [String: CanonicalJSONValue] = [:]
        if let source {
            details["source_domain"] = .string(source.domain)
            details["source_code"] = .signed(Int64(source.code))
        }
        if let underlying {
            details["underlying_domain"] = .string(underlying.domain)
            details["underlying_code"] = .signed(Int64(underlying.code))
        }
        if !details.isEmpty {
            error["details"] = .object(details)
        }
        let xlError: [String: CanonicalJSONValue] = [
            "code": .string(classification.rawValue),
            "host": .string(host ?? ""),
            "detail": .string(message),
        ]
        return CanonicalJSONValue.object([
            "error": .object(error),
            Self.errorBodyKey: .object(xlError),
        ]).encoded()
    }

    /// One-line diagnostic for the host's run log. It names the target, the
    /// status, the stable code, the taxonomy class, the attributed host and
    /// the bridged identities; it never contains a request header or a
    /// credential.
    public func diagnosticLine(target: String? = nil) -> String {
        var parts = ["[pdsh-loopback] /v1/http egress failed:"]
        if let target, !target.isEmpty {
            // Keep scheme/host/path for attribution; userinfo and the query
            // string may carry a credential and are dropped.
            parts.append("target=\(Self.sanitizedTarget(target) ?? "<invalid>")")
        }
        parts.append("status=\(status)")
        parts.append("code=\(code)")
        parts.append("class=\(classification.rawValue)")
        if let host {
            parts.append("host=\(host)")
        }
        if let source {
            parts.append("source=\(source.domain)/\(source.code)")
        }
        if let underlying {
            parts.append("underlying=\(underlying.domain)/\(underlying.code)")
        }
        parts.append("message=\"\(message)\"")
        return parts.joined(separator: " ")
    }

    // MARK: - Sanitizing

    private static func sanitizedCode(_ value: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789_.-")
        var result = ""
        var previousWasSeparator = false
        for scalar in value.lowercased().unicodeScalars where result.count < 64 {
            let character = Character(scalar)
            if allowed.contains(character) {
                result.append(character)
                previousWasSeparator = false
            } else if !previousWasSeparator {
                result.append("_")
                previousWasSeparator = true
            }
        }
        return result.trimmingCharacters(in: CharacterSet(charactersIn: "_"))
    }

    private static func sanitizedMessage(_ value: String) -> String {
        var flattened = value
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // Defence in depth: a producer's message may embed a URL with userinfo
        // or a credential-shaped token. Neither ever belongs in the answer.
        flattened = flattened.replacingOccurrences(
            of: #"(?i)([a-z][a-z0-9+.-]*://)[^/\s@]+@"#,
            with: "$1<redacted>@",
            options: .regularExpression)
        flattened = flattened.replacingOccurrences(
            of: #"(?i)bearer\s+[A-Za-z0-9._~+/-]{16,}"#,
            with: "Bearer <redacted>",
            options: .regularExpression)
        flattened = flattened.replacingOccurrences(
            of: #"\bsk-[A-Za-z0-9]{16,}"#,
            with: "<redacted>",
            options: .regularExpression)
        guard !flattened.isEmpty else { return "the egress failed before a response" }
        return String(flattened.prefix(512))
    }

    private static func sanitizedHost(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty, !trimmed.contains("/"), !trimmed.contains("@"),
              !trimmed.contains(":"), trimmed.count <= 253 else {
            return nil
        }
        return trimmed
    }
}

extension HTTPEgressFailure: LocalizedError {
    public var errorDescription: String? { message }
}

// MARK: - Run-log diagnostic

/// Writes one structured line per `/v1/http` egress failure to standard error.
///
/// The scenario runner tees the whole `swift test` stream into its run log, so
/// this is the surface that lets a G2 rerun attribute a failed fetch without
/// reading the Worker's saved body. Writes are lock-guarded because concurrent
/// egress streams share the handle.
enum LoopbackEgressDiagnostics {
    private static let lock = NSLock()

    static func record(_ failure: HTTPEgressFailure, target: String?) {
        let line = failure.diagnosticLine(target: target) + "\n"
        guard let data = line.data(using: .utf8) else { return }
        lock.lock()
        defer { lock.unlock() }
        FileHandle.standardError.write(data)
    }
}
