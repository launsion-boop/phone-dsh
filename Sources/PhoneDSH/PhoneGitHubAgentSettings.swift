// SPDX-License-Identifier: MIT
// phone-dsh host: the GitHub agent credential.
//
// The Worker's `github` command never holds a token. It sends `/v1/http`
// requests with the loopback channel bearer; the host gateway strips that
// bearer and asks `CredentialProvider` for the `api.github.com` scope. This
// provider answers that one scope from the device Keychain and delegates every
// other scope to the configured model/egress provider.
//
// Writes additionally need an opt-in: `PDSH_GITHUB_AUTH=1` is injected into
// the Worker only when a token exists and the person enabled agent writes, so
// a read-only token cannot make `github commit` look available and then fail
// with GitHub's 401.

import Foundation
import PhoneDSHAgentCore

/// One write-capable GitHub token stored in the device Keychain.
///
/// The token is independent of the read-only Discover connector: that connector
/// keeps its own Keychain record and never grants write access to the agent.
public struct GitHubAgentConfiguration: Equatable, Sendable {
    /// False for a host/test that has no GitHub agent credential at all.
    public var enabled: Bool
    /// Keychain service holding the token.
    public var service: String
    /// Keychain account holding the token.
    public var account: String
    /// The person allows the agent to use write verbs (`commit`/`branch`/`pr`).
    public var allowWrites: Bool

    public init(enabled: Bool = true,
                service: String = GitHubAgentSettings.service,
                account: String = GitHubAgentSettings.account,
                allowWrites: Bool = false) {
        self.enabled = enabled
        self.service = service
        self.account = account
        self.allowWrites = allowWrites
    }

    /// A host that never reads the GitHub Keychain record (tests, embedded
    /// hosts that do not ship the settings page).
    public static let disabled = GitHubAgentConfiguration(enabled: false)

    /// True when a token exists. This is the fact behind `PDSH_GITHUB_AUTH`
    /// (authenticated reads and code search).
    public func credentialAvailable(store: any ModelProviderSecretStore) -> Bool {
        guard enabled else { return false }
        guard let token = try? store.secret(for: account), !token.isEmpty else { return false }
        return true
    }

    /// True only when a token exists and the person enabled writes. This is
    /// the fact behind `PDSH_GITHUB_WRITE`; a token alone is not enough.
    public func writeCredentialAvailable(store: any ModelProviderSecretStore) -> Bool {
        guard allowWrites else { return false }
        return credentialAvailable(store: store)
    }
}

/// The one place the App and the framework agree on the Keychain record and
/// the write opt-in key.
public enum GitHubAgentSettings {
    public static let service = "dev.phone-dsh.github.agent"
    public static let account = "access-token"
    /// UserDefaults key for the explicit write opt-in. Defaults to false: a
    /// read-only token must not silently turn the agent into a writer.
    public static let allowWritesKey = "phone-dsh.github.agent.allow-writes"

    /// The configuration the App passes to `PhoneDSHConfiguration`.
    public static func configuration(defaults: UserDefaults = .standard) -> GitHubAgentConfiguration {
        GitHubAgentConfiguration(
            service: service,
            account: account,
            allowWrites: defaults.bool(forKey: allowWritesKey))
    }
}

/// Credential provider that injects the GitHub bearer for `api.github.com`
/// and delegates every other scope to the base provider.
public struct GitHubAgentCredentialProvider: CredentialProvider {
    public static let githubHost = "api.github.com"

    private let base: any CredentialProvider
    private let store: any ModelProviderSecretStore
    private let account: String

    public init(base: any CredentialProvider,
                store: any ModelProviderSecretStore,
                account: String = GitHubAgentSettings.account) {
        self.base = base
        self.store = store
        self.account = account
    }

    public func credential(for scope: CredentialScope) async throws -> Credential {
        // The host is ours even when the scheme/port is wrong: answer `.none`
        // (anonymous) instead of asking the model provider about a host it
        // does not know.
        if Self.isGitHubHost(scope) && !Self.isGitHubScope(scope) {
            return .none
        }
        guard Self.isGitHubScope(scope) else {
            return try await base.credential(for: scope)
        }
        guard let token = try? store.secret(for: account), !token.isEmpty else {
            // Anonymous public reads are still allowed. The gateway's host
            // allow-list stays in force either way.
            return .none
        }
        return Credential(kind: .bearer, value: token)
    }

    public func invalidate(_ credential: Credential, for scope: CredentialScope) async {
        // A GitHub 401 can mean "read-only token" or "revoked token", not
        // necessarily a bad model credential. Never delete the Keychain value
        // from a failed write; the person disconnects explicitly.
        guard !Self.isGitHubHost(scope) else { return }
        await base.invalidate(credential, for: scope)
    }

    /// Exact host, HTTPS and the default port. A scope that predates the
    /// scheme/port extension is accepted (older gateway callers only sent the
    /// host); any explicit mismatch is not.
    public static func isGitHubScope(_ scope: CredentialScope) -> Bool {
        guard isGitHubHost(scope) else { return false }
        if let scheme = scope.scheme?.lowercased(), scheme != "https" { return false }
        if let port = scope.port, port != 443 { return false }
        return true
    }

    public static func isGitHubHost(_ scope: CredentialScope) -> Bool {
        scope.service.lowercased() == githubHost
    }
}
