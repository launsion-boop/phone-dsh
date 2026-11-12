// phone-dsh — :net / com.phonedsh.gateway: the GitHub agent credential.
// SPDX-License-Identifier: MIT
//
// The Worker's `github` command never holds a token. It sends `/v1/http`
// requests with the loopback channel bearer; the host gateway strips that
// bearer and asks the credential provider for the `api.github.com` scope. This
// provider answers that one scope from the device secret store and delegates
// every other scope to the configured model/egress provider.
//
// The scope rule is the Swift baseline's
// (`Sources/PhoneDSH/PhoneGitHubAgentSettings.swift`,
// `GitHubAgentCredentialProvider`):
//
//   * exact host `api.github.com` over HTTPS and port 443 (or a legacy scope
//     with no scheme/port) receives the stored bearer;
//   * the same host on another scheme/port receives `None` — the token is never
//     sent over an insecure or non-default scope;
//   * every other host delegates to the base provider unchanged.
//
// A GitHub 401 can mean "read-only token" or "revoked token", not a bad model
// credential. `invalidate` therefore never reaches the token: the person
// disconnects explicitly in Settings.

package com.phonedsh.gateway

/**
 * The one GitHub agent token as the provider sees it.
 *
 * `null` means the store was read and holds no token (or the token cannot be
 * read). The provider treats that as anonymous public reads; it never invents
 * a value. Implementations must not log, cache, or put the value into a
 * `toString()`.
 */
fun interface GitHubTokenSource {
    /** The stored fine-grained token, or `null` when absent/unreadable. */
    fun readToken(): String?
}

/**
 * Injects the GitHub agent token for `api.github.com` and delegates every other
 * scope to [base].
 *
 * @param base the host's configured model/egress provider.
 * @param tokenSource the device secret store; read once per credential scope.
 */
class GitHubAgentCredentialProvider(
    private val base: GatewayCredentialProvider,
    private val tokenSource: GitHubTokenSource,
) : GatewayCredentialProvider {

    override fun resolve(scope: CredentialScope): GatewayCredential {
        // The host is ours even when the scheme/port is wrong: answer `None`
        // (anonymous) instead of asking the model provider about a host it does
        // not know.
        if (isGitHubHost(scope) && !isGitHubScope(scope)) return GatewayCredential.None
        if (!isGitHubScope(scope)) return base.resolve(scope)
        val token = try {
            tokenSource.readToken()
        } catch (failure: Exception) {
            // The baseline's `try?`: an unreadable record means anonymous, not
            // the model key and not a failed request.
            null
        }
        if (token.isNullOrEmpty()) {
            // Anonymous public reads are still allowed. The gateway's host
            // allow-list stays in force either way.
            return GatewayCredential.None
        }
        return GatewayCredential.Bearer(token)
    }

    override fun invalidate(credential: GatewayCredential, scope: CredentialScope) {
        if (isGitHubHost(scope)) return
        base.invalidate(credential, scope)
    }

    /**
     * Exact host, HTTPS and the default port. A scope that predates the
     * scheme/port extension is accepted (older gateway callers only sent the
     * host); any explicit mismatch is not.
     */
    fun isGitHubScope(scope: CredentialScope): Boolean {
        if (!isGitHubHost(scope)) return false
        val scheme = scope.scheme.trim().lowercase()
        if (scheme.isNotEmpty() && scheme != "https") return false
        if (scope.port != null && scope.port != 443) return false
        return true
    }

    fun isGitHubHost(scope: CredentialScope): Boolean =
        scope.service.lowercase() == GITHUB_HOST

    /** Never prints the token or the store. */
    override fun toString(): String = "GitHubAgentCredentialProvider($GITHUB_HOST)"

    companion object {
        const val GITHUB_HOST: String = "api.github.com"
    }
}
