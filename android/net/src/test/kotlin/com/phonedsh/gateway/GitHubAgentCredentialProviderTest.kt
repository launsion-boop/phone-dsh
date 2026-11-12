// phone-dsh — :gateway tests: the GitHub agent token's exact scope.
// SPDX-License-Identifier: MIT
//
// Port of `Tests/PhoneDSHTests/GitHubAgentCredentialTests.swift` (minus the
// host-only env/write-opt-in cases, which live in `:engine`'s
// `WorkerEnvironmentTest` and `:app`'s `GitHubAgentSettingsStoreTest`):
//
//   * `api.github.com` over HTTPS:443 gets the stored bearer;
//   * every other host delegates to the base provider unchanged;
//   * no token means anonymous, never the model key;
//   * http / port 8443 get no credential at all (they do not even consult the
//     base provider, which does not know that host);
//   * a legacy scope with no scheme/port is still the GitHub scope;
//   * a GitHub invalidation never reaches (and never deletes) the token.

package com.phonedsh.gateway

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class GitHubAgentCredentialProviderTest {

    private class RecordingBase(
        private val credential: GatewayCredential = GatewayCredential.ApiKey("x-api-key", "model-key"),
    ) : GatewayCredentialProvider {
        val scopes = mutableListOf<CredentialScope>()
        val invalidated = mutableListOf<CredentialScope>()

        override fun resolve(scope: CredentialScope): GatewayCredential {
            scopes += scope
            return credential
        }

        override fun invalidate(credential: GatewayCredential, scope: CredentialScope) {
            invalidated += scope
        }
    }

    private fun provider(
        token: String? = "ghp_test",
        base: GatewayCredentialProvider = RecordingBase(),
    ): GitHubAgentCredentialProvider = GitHubAgentCredentialProvider(
        base = base,
        tokenSource = GitHubTokenSource { token },
    )

    private fun githubScope(
        scheme: String = "https",
        port: Int? = 443,
        audience: String = "/repos/octo/example",
    ) = CredentialScope(
        service = GitHubAgentCredentialProvider.GITHUB_HOST,
        audience = audience,
        scheme = scheme,
        port = port,
    )

    @Test
    fun `the github scope receives the stored token as a bearer`() {
        val credential = provider().resolve(githubScope())
        assertEquals(GatewayCredential.Bearer("ghp_test"), credential)
    }

    @Test
    fun `a legacy scope without a scheme or port is still the github scope`() {
        val credential = provider().resolve(githubScope(scheme = "", port = null))
        assertEquals(GatewayCredential.Bearer("ghp_test"), credential)
    }

    @Test
    fun `other scopes delegate to the base provider`() {
        val base = RecordingBase()
        val modelScope = CredentialScope(
            service = "model.example",
            audience = "/v1/chat/completions",
            scheme = "https",
            port = 443,
        )
        val credential = provider(base = base).resolve(modelScope)
        assertEquals(GatewayCredential.ApiKey("x-api-key", "model-key"), credential)
        assertEquals(listOf(modelScope), base.scopes)
    }

    @Test
    fun `a github scope without a token stays anonymous`() {
        val base = RecordingBase()
        val credential = provider(token = null, base = base).resolve(githubScope())
        assertEquals(GatewayCredential.None, credential)
        assertTrue("a no-token github scope must not ask the model provider", base.scopes.isEmpty())
    }

    @Test
    fun `an empty stored token is absent`() {
        assertEquals(GatewayCredential.None, provider(token = "").resolve(githubScope()))
    }

    @Test
    fun `an unreadable token is anonymous rather than a failed request`() {
        val provider = GitHubAgentCredentialProvider(
            base = RecordingBase(),
            tokenSource = GitHubTokenSource { throw IllegalStateException("keystore invalidated") },
        )
        assertEquals(GatewayCredential.None, provider.resolve(githubScope()))
    }

    @Test
    fun `the token never crosses an insecure or non default scope`() {
        val base = RecordingBase()
        val provider = provider(base = base)
        for (scope in listOf(
            githubScope(scheme = "http", port = 80),
            githubScope(scheme = "https", port = 8443),
            githubScope(scheme = "http", port = 443),
        )) {
            assertEquals(GatewayCredential.None, provider.resolve(scope))
        }
        assertTrue("a mismatched github scope must not ask the model provider", base.scopes.isEmpty())
    }

    @Test
    fun `a github host with a wrong scheme is never delegated`() {
        val base = RecordingBase()
        val credential = provider(base = base).resolve(githubScope(scheme = "http", port = 80))
        assertEquals(GatewayCredential.None, credential)
        assertFalse(base.scopes.isNotEmpty())
    }

    @Test
    fun `invalidate never reaches the token for a github scope`() {
        val base = RecordingBase()
        val provider = provider(base = base)
        val github = provider.resolve(githubScope())
        provider.invalidate(github, githubScope())
        assertTrue("the token is not a model credential and is never deleted here", base.invalidated.isEmpty())

        val model = CredentialScope("model.example", "/v1/models", "https", 443)
        provider.invalidate(GatewayCredential.ApiKey("x-api-key", "model-key"), model)
        assertEquals(listOf(model), base.invalidated)
    }

    @Test
    fun `toString never prints the token`() {
        val text = provider(token = "ghp_super_secret").toString()
        assertFalse(text.contains("ghp_super_secret"))
    }
}
