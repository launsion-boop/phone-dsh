// SPDX-License-Identifier: MIT
//
// github-oauth-v1 client conformance on Android: configuration, PKCE, callback
// validation and broker status mapping, driven through the real classes with
// the shared fixture spec/v1/golden/github-oauth/github-oauth-cases.json.
// iOS baseline: GitHubOAuthTests over ProbeKit/GitHubOAuthFlow.swift.

package com.phonedsh.connectors.github

import com.phonedsh.gateway.GatewayJson
import com.phonedsh.gateway.JsonValue
import java.io.IOException
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

class GitHubOAuthTest {
    private val f = GitHubFixture

    // ---- configuration

    @Test
    fun validConfigurationNormalizesOriginAndDerivesEndpoints() {
        val config = GitHubOAuthConfiguration.create("  https://Broker.Example.com/  ", " Iv1.client ", "phone-dsh-app")!!
        assertEquals("https://broker.example.com", config.origin)
        assertEquals("Iv1.client", config.clientId)
        assertEquals("https://broker.example.com/v1/github/oauth/callback", config.redirectUri)
        assertEquals("https://broker.example.com/v1/github/oauth/exchange", config.exchangeEndpoint)
        assertEquals("https://broker.example.com/v1/github/oauth/revoke", config.revokeEndpoint)
        assertEquals("https://github.com/apps/phone-dsh-app/installations/new", config.installationUrl)

        val withPort = GitHubOAuthConfiguration.create("https://broker.example.com:8443", "Iv1.client", "a")!!
        assertEquals("https://broker.example.com:8443/v1/github/oauth/exchange", withPort.exchangeEndpoint)
    }

    @Test
    fun invalidConfigurationIsUnavailable() {
        val badOrigins = listOf(
            "", "http://broker.example.com", "https://broker.example.com/path", "https://user@broker.example.com",
            "https://broker.example.com?x=1", "https://broker.example.com?", "https://broker.example.com#f",
            "https://broker.example.com:0", "https://broker.example.com:70000", "https://broker .example.com",
            "https://", "broker.example.com", "ftp://broker.example.com",
        )
        for (origin in badOrigins) {
            assertNull(origin, GitHubOAuthConfiguration.create(origin, "Iv1.client", "phone-dsh-app"))
        }
        val badSlugs = listOf("", "-bad", "bad-", "bad slug", "bad_slug", "a".repeat(101), "ü")
        for (slug in badSlugs) {
            assertNull(slug, GitHubOAuthConfiguration.create("https://broker.example.com", "Iv1.client", slug))
        }
        val badClientIds = listOf("", "bad/id", "bad id", "a".repeat(129))
        for (id in badClientIds) {
            assertNull(id, GitHubOAuthConfiguration.create("https://broker.example.com", id, "phone-dsh-app"))
        }
        assertNotNull(GitHubOAuthConfiguration.create("https://broker.example.com", "a".repeat(128), "a".repeat(100)))
    }

    @Test
    fun authorizationUrlCarriesChallengeButNeverVerifier() {
        val config = testConfiguration()
        val attempt = GitHubOAuthAttempt(f.state, f.codeVerifier)
        val url = config.authorizationUrl(attempt.state, attempt.challenge)!!
        assertTrue(url.startsWith("https://github.com/login/oauth/authorize?"))
        assertEquals(
            mapOf(
                "client_id" to "Iv1.client",
                "redirect_uri" to "https://broker.example.com/v1/github/oauth/callback",
                "state" to f.state,
                "code_challenge" to attempt.challenge,
                "code_challenge_method" to "S256",
            ),
            queryOf(url),
        )
        assertFalse(url.contains(f.codeVerifier))
        assertNull(config.authorizationUrl("short", attempt.challenge))
        assertNull(config.authorizationUrl(f.state, "short"))
    }

    // ---- PKCE and value domains

    @Test
    fun codeChallengeMatchesRfc7636AppendixB() {
        assertEquals(
            "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM",
            GitHubOAuthPkce.codeChallenge("dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"),
        )
    }

    @Test
    fun fixtureValueDomains() {
        assertTrue(GitHubOAuthPkce.isValidState(f.state))
        assertTrue(GitHubOAuthPkce.isValidState(f.wrongState))
        assertFalse(GitHubOAuthPkce.isValidState(f.state.dropLast(1)))
        assertFalse(GitHubOAuthPkce.isValidState(f.state.dropLast(1) + "="))
        assertTrue(GitHubOAuthPkce.isValidCode(f.code))
        assertFalse(GitHubOAuthPkce.isValidCode(""))
        assertFalse(GitHubOAuthPkce.isValidCode("a".repeat(513)))
        assertFalse(GitHubOAuthPkce.isValidCode("bad.code"))
        assertTrue(GitHubOAuthPkce.isValidVerifier(f.codeVerifier))
        assertFalse(GitHubOAuthPkce.isValidVerifier(f.invalidVerifier))
        assertFalse(GitHubOAuthPkce.isValidVerifier("a".repeat(129)))
        assertTrue(GitHubOAuthPkce.isValidVerifier("a~.-_".repeat(9)))
        assertTrue(GitHubConnectorApi.isValidToken(f.accessToken))
        assertFalse(GitHubConnectorApi.isValidToken(f.invalidToken))
        assertFalse(GitHubConnectorApi.isValidToken("ghu_"))
        assertFalse(GitHubConnectorApi.isValidToken("ghu_" + "a".repeat(252)))
        assertTrue(GitHubConnectorApi.isValidToken("ghu_" + "a".repeat(251)))
        assertFalse(GitHubConnectorApi.isValidToken("ghu_bad-token"))
        expectOAuth(GitHubOAuthError.INVALID_VERIFIER) { GitHubOAuthAttempt(f.state, f.invalidVerifier) }
        expectOAuth(GitHubOAuthError.INVALID_STATE) { GitHubOAuthAttempt("short", f.codeVerifier) }
    }

    @Test
    fun makeAttemptUsesThirtyTwoRandomBytes() {
        val zeros = GitHubOAuthPkce.makeAttempt { ByteArray(it) }
        assertEquals(f.state, zeros.state)
        assertEquals(GitHubOAuthPkce.codeChallenge(zeros.verifier), zeros.challenge)
        expectOAuth(GitHubOAuthError.RANDOM_UNAVAILABLE) { GitHubOAuthPkce.makeAttempt { ByteArray(31) } }

        val first = GitHubOAuthPkce.makeAttempt()
        val second = GitHubOAuthPkce.makeAttempt()
        assertTrue(GitHubOAuthPkce.isValidState(first.state))
        assertTrue(GitHubOAuthPkce.isValidVerifier(first.verifier))
        assertTrue(GitHubOAuthPkce.isValidChallenge(first.challenge))
        assertNotEquals(first.state, first.verifier)
        assertNotEquals(first.state, second.state)
    }

    // ---- callback

    @Test
    fun validCallbacks() {
        val base = "phonedsh-github://oauth/callback"
        assertEquals(
            GitHubOAuthCallback.Code(f.code),
            GitHubOAuthCallbackValidator.validate("$base?state=${f.state}&code=${f.code}", f.state),
        )
        assertEquals(
            GitHubOAuthCallback.Code(f.code),
            GitHubOAuthCallbackValidator.validate("$base?code=${f.code}&state=${f.state}", f.state),
        )
        assertEquals(
            GitHubOAuthCallback.AccessDenied,
            GitHubOAuthCallbackValidator.validate("$base?state=${f.state}&error=access_denied", f.state),
        )
        // Percent-encoded values decode before the domain check.
        assertEquals(
            GitHubOAuthCallback.Code(f.code),
            GitHubOAuthCallbackValidator.validate("$base?state=${f.state}&code=github%2Dcode_1234", f.state),
        )
        assertEquals(
            GitHubOAuthCallback.Code(f.code),
            GitHubOAuthCallbackValidator.validate("PHONEDSH-GITHUB://OAUTH/callback?state=${f.state}&code=${f.code}", f.state),
        )
    }

    @Test
    fun invalidCallbacksAreRejected() {
        val s = f.state
        val c = f.code
        val invalid = listOf(
            "phonedsh-github://oauth/callback?state=$s&code=$c&code=$c",
            "phonedsh-github://oauth/callback?state=$s&state=$s",
            "phonedsh-github://oauth/callback?state=$s&code=$c&extra=1",
            "phonedsh-github://oauth/callback?state=$s&token=ghu_abc",
            "phonedsh-github://oauth/callback?state=$s&code=$c&error=access_denied",
            "phonedsh-github://oauth/callback?state=$s&code=",
            "phonedsh-github://oauth/callback?state=$s&code",
            "phonedsh-github://oauth/callback?state=$s&error=server_error",
            "phonedsh-github://oauth/callback?state=$s&code=bad.code",
            "phonedsh-github://oauth/callback?code=$c",
            "phonedsh-github://oauth/callback",
            "phonedsh-github://oauth/callback?",
            "phonedsh-github://other/callback?state=$s&code=$c",
            "phonedsh-github://oauth/callbacks?state=$s&code=$c",
            "phonedsh-github://oauth/callback/?state=$s&code=$c",
            "phonedsh-github://oauth?state=$s&code=$c",
            "https://oauth/callback?state=$s&code=$c",
            "phonedsh-gitlab://oauth/callback?state=$s&code=$c",
            "phonedsh-github://oauth:8080/callback?state=$s&code=$c",
            "phonedsh-github://user@oauth/callback?state=$s&code=$c",
            "phonedsh-github://oauth/callback?state=$s&code=$c#frag",
            "phonedsh-github://oauth/callback?state=$s&code=%ZZ",
            "phonedsh-github:/callback?state=$s&code=$c",
            "not a url",
        )
        for (url in invalid) {
            try {
                GitHubOAuthCallbackValidator.validate(url, s)
                fail("accepted $url")
            } catch (e: GitHubOAuthException) {
                assertEquals(url, GitHubOAuthError.INVALID_CALLBACK, e.error)
            }
        }
        expectOAuth(GitHubOAuthError.STATE_MISMATCH) {
            GitHubOAuthCallbackValidator.validate("phonedsh-github://oauth/callback?state=${f.wrongState}&code=$c", s)
        }
        expectOAuth(GitHubOAuthError.INVALID_STATE) {
            GitHubOAuthCallbackValidator.validate("phonedsh-github://oauth/callback?state=$s&code=$c", "short")
        }
    }

    // ---- broker

    @Test
    fun exchangePostsJsonAndReturnsToken() = runBlocking {
        val transport = FakeTransport {
            response(200, """{"access_token":"${f.accessToken}","expires_in":${f.expiresIn}}""")
        }
        val token = GitHubOAuthBroker(testConfiguration(), transport).exchange(f.code, f.codeVerifier)
        assertEquals(f.accessToken, token.accessToken)
        assertEquals(f.expiresIn.toLong(), token.expiresIn)

        val request = transport.requests.single()
        assertEquals("POST", request.method)
        assertEquals("https://broker.example.com/v1/github/oauth/exchange", request.url)
        assertEquals("application/json", request.headers["Content-Type"])
        assertEquals("application/json", request.headers["Accept"])
        assertEquals("phone-dsh", request.headers["User-Agent"])
        val body = GatewayJson.parse(String(request.body!!, Charsets.UTF_8)) as JsonValue.Obj
        assertEquals(setOf("code", "code_verifier"), body.members.map { it.name }.toSet())
        assertEquals(f.code, body.string("code"))
        assertEquals(f.codeVerifier, body.string("code_verifier"))
        assertFalse(request.url.contains(f.codeVerifier))
    }

    @Test
    fun exchangeStatusAndBodyMapping() = runBlocking {
        val cases = listOf(
            response(400, """{"error":"invalid_request"}""") to GitHubOAuthError.INVALID_REQUEST,
            response(401, """{"error":"authorization_failed"}""") to GitHubOAuthError.AUTHORIZATION_FAILED,
            response(502, """{"error":"github_unavailable"}""") to GitHubOAuthError.SERVICE_UNAVAILABLE,
            response(500) to GitHubOAuthError.SERVICE_UNAVAILABLE,
            response(204) to GitHubOAuthError.SERVICE_UNAVAILABLE,
            response(302) to GitHubOAuthError.SERVICE_UNAVAILABLE,
            response(200, "not json") to GitHubOAuthError.INVALID_RESPONSE,
            response(200, """{"expires_in":1}""") to GitHubOAuthError.INVALID_RESPONSE,
            response(200, """{"access_token":"${f.invalidToken}","expires_in":1}""") to GitHubOAuthError.INVALID_TOKEN,
            response(200, """{"access_token":"${f.accessToken}","expires_in":0}""") to GitHubOAuthError.INVALID_TOKEN,
        )
        for ((answer, expected) in cases) {
            val broker = GitHubOAuthBroker(testConfiguration(), FakeTransport { answer })
            expectOAuthSuspend(expected) { broker.exchange(f.code, f.codeVerifier) }
        }
        val failing = GitHubOAuthBroker(testConfiguration(), FakeTransport { throw IOException("down") })
        expectOAuthSuspend(GitHubOAuthError.SERVICE_UNAVAILABLE) { failing.exchange(f.code, f.codeVerifier) }
        val cancelled = GitHubOAuthBroker(testConfiguration(), FakeTransport { throw CancellationException("x") })
        expectOAuthSuspend(GitHubOAuthError.CANCELLED) { cancelled.exchange(f.code, f.codeVerifier) }

        val untouched = FakeTransport { error("must not send") }
        val broker = GitHubOAuthBroker(testConfiguration(), untouched)
        expectOAuthSuspend(GitHubOAuthError.INVALID_VERIFIER) { broker.exchange(f.code, f.invalidVerifier) }
        expectOAuthSuspend(GitHubOAuthError.INVALID_CODE) { broker.exchange("bad.code", f.codeVerifier) }
        assertTrue(untouched.requests.isEmpty())
    }

    @Test
    fun revokeMapping() = runBlocking {
        val ok = FakeTransport { response(204) }
        GitHubOAuthBroker(testConfiguration(), ok).revoke(f.accessToken)
        val request = ok.requests.single()
        assertEquals("https://broker.example.com/v1/github/oauth/revoke", request.url)
        assertEquals("""{"access_token":"${f.accessToken}"}""", String(request.body!!, Charsets.UTF_8))

        val cases = listOf(
            200 to GitHubOAuthError.SERVICE_UNAVAILABLE,
            400 to GitHubOAuthError.INVALID_REQUEST,
            401 to GitHubOAuthError.AUTHORIZATION_FAILED,
            502 to GitHubOAuthError.SERVICE_UNAVAILABLE,
        )
        for ((status, expected) in cases) {
            val broker = GitHubOAuthBroker(testConfiguration(), FakeTransport { response(status) })
            expectOAuthSuspend(expected) { broker.revoke(f.accessToken) }
        }
        val untouched = FakeTransport { error("must not send") }
        expectOAuthSuspend(GitHubOAuthError.INVALID_TOKEN) {
            GitHubOAuthBroker(testConfiguration(), untouched).revoke(f.invalidToken)
        }
        assertTrue(untouched.requests.isEmpty())
    }

    private fun expectOAuth(expected: GitHubOAuthError, block: () -> Unit) {
        try {
            block()
            fail("expected $expected")
        } catch (e: GitHubOAuthException) {
            assertEquals(expected, e.error)
        }
    }

    private suspend fun expectOAuthSuspend(expected: GitHubOAuthError, block: suspend () -> Unit) {
        try {
            block()
            fail("expected $expected")
        } catch (e: GitHubOAuthException) {
            assertEquals(expected, e.error)
        }
    }
}
