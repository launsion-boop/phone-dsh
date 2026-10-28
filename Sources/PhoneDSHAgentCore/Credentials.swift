// SPDX-License-Identifier: MIT
// phone-dsh SDK — PhoneDSHAgentCore: credentials.
//
// The credential contract every network provider depends on. The concrete
// stores (Keychain, account binding) stay in the provider and host modules;
// this target only carries the value types and the refresh seam.

import Foundation

/// Which service a credential is for. Providers define their own service names.
///
/// `service` and `audience` remain the host/path pair every existing provider
/// uses. A gateway can additionally publish the request's lowercased `scheme`
/// and explicit `port` so a provider can distinguish two origins that share a
/// bare host. Both fields are optional: scopes from older callers, and scopes
/// for non-HTTP services such as the remote handoff, decode and compare with
/// `nil` exactly as before.
public struct CredentialScope: Codable, Hashable, Sendable {
    public var service: String
    public var audience: String?
    /// Lowercase URL scheme when the caller knows it. Providers that route by
    /// origin (the MCP credential router) require it; model/search providers
    /// match on `service` and ignore it.
    public var scheme: String?
    /// Effective URL port when the caller knows it. `nil` means the scheme's
    /// default port.
    public var port: Int?

    public init(service: String,
                audience: String? = nil,
                scheme: String? = nil,
                port: Int? = nil) {
        self.service = service
        self.audience = audience
        self.scheme = scheme
        self.port = port
    }
}

public struct Credential: Codable, Equatable, Sendable {
    public enum Kind: Codable, Equatable, Sendable {
        case bearer
        /// API key sent in the named header.
        case apiKey(header: String)
        /// Several header values injected together. Used by the scoped MCP
        /// credential router; the real values stay in the host process.
        case headers([String: String])
        case none
    }

    public var kind: Kind
    public var value: String
    public var expiresAt: Date?

    public init(kind: Kind, value: String, expiresAt: Date? = nil) {
        self.kind = kind
        self.value = value
        self.expiresAt = expiresAt
    }

    public static let none = Credential(kind: .none, value: "")

    /// Applies the credential to a request.
    public func apply(to request: inout URLRequest) {
        switch kind {
        case .bearer: request.setValue("Bearer \(value)", forHTTPHeaderField: "Authorization")
        case .apiKey(let header): request.setValue(value, forHTTPHeaderField: header)
        case .headers(let headers):
            for (header, headerValue) in headers {
                request.setValue(headerValue, forHTTPHeaderField: header)
            }
        case .none: break
        }
    }
}

/// An additional host-side admission policy for Worker `/v1/http` egress.
///
/// The model gateway always enforces its configured host union first; this
/// policy is the per-request seam for an exact-origin/path grant (the MCP
/// endpoint the user explicitly added) without widening the static allow-list
/// or admitting a wildcard. Implementations must be thread-safe because the
/// gateway reads them from URLSession delegate queues.
public protocol EgressHostAuthorizing: Sendable {
    /// True only when this exact `http(s)` URL is admitted.
    func allowsEgressHost(_ url: URL) -> Bool
}

public protocol CredentialProvider: Sendable {
    /// Returns a currently valid credential, refreshing if needed.
    func credential(for scope: CredentialScope) async throws -> Credential
    /// Called after the service rejected `credential`; the next call must
    /// refresh or throw `ProviderError.unauthorized`.
    func invalidate(_ credential: Credential, for scope: CredentialScope) async
}

/// Fixed credentials (an API key typed into settings, kept in the Keychain by
/// the host app).
public struct StaticCredentialProvider: CredentialProvider {
    public var credentials: [CredentialScope: Credential]

    public init(_ credentials: [CredentialScope: Credential]) {
        self.credentials = credentials
    }

    public func credential(for scope: CredentialScope) async throws -> Credential {
        if let credential = credentials[scope] ?? credentials[CredentialScope(service: scope.service)] {
            return credential
        }
        // A caller that adds scheme/port to the scope (the MCP router) must not
        // make a registered service/audience credential disappear. Fall back to
        // the pre-scheme/port key shape for existing injected providers.
        if scope.scheme != nil || scope.port != nil {
            let legacy = CredentialScope(service: scope.service, audience: scope.audience)
            if let credential = credentials[legacy] { return credential }
        }
        throw ProviderError.unauthorized("no credential for \(scope.service)")
    }

    public func invalidate(_ credential: Credential, for scope: CredentialScope) async {}
}
