// SPDX-License-Identifier: MIT
//
// GitHubConnectorModel state machine on Android, driven with the real broker,
// REST client and callback validator over a fake transport. iOS baseline:
// GitHubConnectorModel in PhoneDSHProbe/GitHubConnectorPage.swift.

package com.phonedsh.connectors.github

import java.io.IOException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.withContext
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class GitHubConnectorModelTest {
    private val f = GitHubFixture

    private class FakeStore(var token: String? = null) : GitHubTokenStore {
        var readFails = false
        var writeFails = false
        var deleteFails = false
        var writes = 0
        var deletes = 0

        override suspend fun read(): GitHubTokenRead = when {
            readFails -> GitHubTokenRead.Unreadable
            token == null -> GitHubTokenRead.Absent
            else -> GitHubTokenRead.Present(token!!)
        }

        override suspend fun write(token: String) {
            if (writeFails) throw IOException("write")
            writes += 1
            this.token = token
        }

        override suspend fun delete() {
            if (deleteFails) throw IOException("delete")
            deletes += 1
            token = null
        }
    }

    private inner class Harness(
        scope: CoroutineScope,
        configuration: GitHubOAuthConfiguration? = testConfiguration(),
        val store: FakeStore = FakeStore(),
    ) {
        var now = 1_000_000L
        var userStatus = 200
        var reposStatus = 200
        var revokeStatus = 204
        var exchangeGate: CompletableDeferred<Unit>? = null
        var callbackGate: CompletableDeferred<Unit>? = null
        var reposGate: CompletableDeferred<Unit>? = null
        var callback: (String) -> String = { state -> "phonedsh-github://oauth/callback?state=$state&code=${f.code}" }
        var authorizeError: Exception? = null
        var authorizeUrl: String? = null
        val pages = mapOf(
            1 to (listOf(repo(1, "octo/one"), repo(2, "octo/two")) to true),
            2 to (listOf(repo(2, "octo/two"), repo(3, "octo/three")) to false),
        )

        val transport = FakeTransport { request ->
            when {
                request.url.endsWith("/v1/github/oauth/exchange") -> {
                    exchangeGate?.let { gate -> withContext(NonCancellable) { gate.await() } }
                    response(200, """{"access_token":"${f.accessToken}","expires_in":${f.expiresIn}}""")
                }
                request.url.endsWith("/v1/github/oauth/revoke") -> response(revokeStatus)
                request.url == "https://api.github.com/user" ->
                    response(userStatus, """{"login":"octocat"}""")
                request.url.startsWith("https://api.github.com/user/repos?") -> {
                    reposGate?.await()
                    val page = queryOf(request.url)["page"]!!.toInt()
                    val (repos, more) = pages.getValue(page)
                    val body = repos.joinToString(",", "[", "]") {
                        """{"id":${it.id},"name":"${it.name}","full_name":"${it.fullName}","html_url":"${it.htmlUrl}"}"""
                    }
                    val headers = if (more) mapOf("link" to "<https://api.github.com/x>; rel=\"next\"") else emptyMap()
                    response(reposStatus, body, headers)
                }
                else -> error("unexpected ${request.url}")
            }
        }

        val model = GitHubConnectorModel(
            configuration = configuration,
            api = GitHubConnectorApi(transport),
            broker = { GitHubOAuthBroker(it, transport) },
            tokenStore = store,
            authorizer = { url ->
                authorizeUrl = url
                authorizeError?.let { throw it }
                callbackGate?.let { gate -> withContext(NonCancellable) { gate.await() } }
                callback(queryOf(url).getValue("state"))
            },
            scope = scope,
            text = { _, en -> en },
            nowMillis = { now },
            randomBytes = { ByteArray(it) },
        )

        val snap: GitHubConnectorSnapshot get() = model.snapshot.value

        fun urls(): List<String> = transport.requests.map { it.url }
    }

    private fun repo(id: Long, fullName: String) =
        GitHubRepository(id, fullName.substringAfter('/'), fullName, "https://github.com/$fullName")

    private suspend fun Harness.connectFully() {
        model.connect()
        settle()
        val state = snap.state as GitHubConnectorState.Connected
        assertEquals("octocat", state.login)
    }

    @Test
    fun restoreDiscardsLegacyPat() = singleThreadTest { scope ->
        val h = Harness(scope, store = FakeStore(f.invalidToken))
        h.model.restore()
        settle()
        assertNull(h.store.token)
        assertEquals(GitHubConnectorState.Disconnected, h.snap.state)
        assertEquals("The old GitHub token was cleared. Reconnect GitHub.", h.snap.connectionNotice)
        assertFalse(h.snap.needsDeleteRetry)
        assertTrue(h.transport.requests.isEmpty())
    }

    @Test
    fun restoreLegacyDeleteFailureNeedsRetryAndBlocksConnect() = singleThreadTest { scope ->
        val h = Harness(scope, store = FakeStore(f.invalidToken))
        h.store.deleteFails = true
        h.model.restore()
        settle()
        assertTrue(h.snap.needsDeleteRetry)
        assertEquals(
            "GitHub data was cleared on this phone, but the keychain token could not be removed. Try again.",
            h.snap.connectionNotice,
        )
        h.model.connect()
        settle()
        assertEquals(GitHubConnectorState.Disconnected, h.snap.state)
        h.store.deleteFails = false
        h.model.retryDelete()
        settle()
        assertFalse(h.snap.needsDeleteRetry)
        assertNull(h.snap.connectionNotice)
    }

    @Test
    fun restoreWithSavedTokenConnectsWithoutRewriting() = singleThreadTest { scope ->
        val h = Harness(scope, store = FakeStore(f.accessToken))
        h.model.restore()
        settle()
        val state = h.snap.state as GitHubConnectorState.Connected
        assertEquals(listOf(1L, 2L), state.repos.map { it.id })
        assertEquals(0, h.store.writes)
        assertTrue(h.urls().none { it.contains("/oauth/") })
    }

    @Test
    fun restoreUnreadableOffersRetry() = singleThreadTest { scope ->
        val h = Harness(scope, store = FakeStore(f.accessToken))
        h.store.readFails = true
        h.model.restore()
        settle()
        assertTrue(h.snap.canRetryRestore)
        assertEquals("Could not read the saved GitHub token on this phone. Try again.", h.snap.connectionNotice)
        h.store.readFails = false
        h.model.restore()
        settle()
        assertTrue(h.snap.state is GitHubConnectorState.Connected)
        assertFalse(h.snap.canRetryRestore)
    }

    @Test
    fun connectExchangesAndLoadsRepositories() = singleThreadTest { scope ->
        val h = Harness(scope)
        assertTrue(h.snap.isConfigured)
        assertEquals("https://github.com/apps/phone-dsh-app/installations/new", h.snap.installationUrl)
        h.connectFully()

        val url = h.authorizeUrl!!
        val query = queryOf(url)
        assertEquals(f.state, query["state"])
        assertEquals("S256", query["code_challenge_method"])
        val verifier = GitHubOAuthPkce.base64Url(ByteArray(32))
        assertEquals(GitHubOAuthPkce.codeChallenge(verifier), query["code_challenge"])

        val exchange = h.transport.requests.first { it.url.endsWith("/exchange") }
        assertEquals(
            """{"code":"${f.code}","code_verifier":"$verifier"}""",
            String(exchange.body!!, Charsets.UTF_8),
        )
        assertEquals(f.accessToken, h.store.token)
        val state = h.snap.state as GitHubConnectorState.Connected
        assertEquals(listOf(1L, 2L), state.repos.map { it.id })
        assertEquals(2, state.nextPage)
        assertNull(state.notice)
        assertFalse(h.snap.loading)

        h.model.loadMore()
        settle()
        val more = h.snap.state as GitHubConnectorState.Connected
        assertEquals(listOf(1L, 2L, 3L), more.repos.map { it.id })
        assertNull(more.nextPage)
    }

    @Test
    fun unconfiguredBuildShowsNotice() = singleThreadTest { scope ->
        val h = Harness(scope, configuration = null)
        assertFalse(h.snap.isConfigured)
        assertNull(h.snap.installationUrl)
        h.model.connect()
        settle()
        assertEquals(GitHubConnectorState.Disconnected, h.snap.state)
        assertEquals("This build is not configured for GitHub OAuth.", h.snap.connectionNotice)
    }

    @Test
    fun cancelLeavesDisconnectedWithoutNoticeAndIgnoresStaleCallback() = singleThreadTest { scope ->
        val h = Harness(scope)
        val gate = CompletableDeferred<Unit>()
        h.callbackGate = gate
        h.model.connect()
        settle()
        assertEquals(GitHubConnectorState.Connecting, h.snap.state)
        h.model.cancelAuthorization()
        settle()
        assertEquals(GitHubConnectorState.Disconnected, h.snap.state)
        assertNull(h.snap.connectionNotice)

        gate.complete(Unit)
        settle()
        assertEquals(GitHubConnectorState.Disconnected, h.snap.state)
        assertNull(h.snap.connectionNotice)
        assertTrue(h.transport.requests.isEmpty())
        assertNull(h.store.token)
    }

    @Test
    fun staleExchangeAfterCancelDoesNotRestoreConnection() = singleThreadTest { scope ->
        val h = Harness(scope)
        val gate = CompletableDeferred<Unit>()
        h.exchangeGate = gate
        h.model.connect()
        settle()
        assertEquals(GitHubConnectorState.Connecting, h.snap.state)
        h.model.cancelAuthorization()
        settle()
        gate.complete(Unit)
        settle()
        assertEquals(GitHubConnectorState.Disconnected, h.snap.state)
        assertNull(h.snap.connectionNotice)
        assertNull(h.store.token)
        assertTrue(h.urls().none { it.startsWith("https://api.github.com/") })
    }

    @Test
    fun accessDeniedShowsNotice() = singleThreadTest { scope ->
        val h = Harness(scope)
        h.callback = { state -> "phonedsh-github://oauth/callback?state=$state&error=access_denied" }
        h.model.connect()
        settle()
        assertEquals(GitHubConnectorState.Disconnected, h.snap.state)
        assertEquals("GitHub authorization was cancelled.", h.snap.connectionNotice)
        assertTrue(h.transport.requests.isEmpty())
    }

    @Test
    fun badCallbackAndWebFailuresMapToNotices() = singleThreadTest { scope ->
        val h = Harness(scope)
        h.callback = { _ -> "phonedsh-github://oauth/callback?state=${f.wrongState}&code=${f.code}" }
        h.model.connect()
        settle()
        assertEquals("GitHub authorization could not be completed. Try again.", h.snap.connectionNotice)

        h.authorizeError = GitHubWebAuthorizationException(cancelled = true)
        h.model.connect()
        settle()
        assertEquals(GitHubConnectorState.Disconnected, h.snap.state)
        assertNull(h.snap.connectionNotice)

        h.authorizeError = GitHubWebAuthorizationException(cancelled = false)
        h.model.connect()
        settle()
        assertEquals("Could not reach GitHub. Try again later.", h.snap.connectionNotice)
        assertTrue(h.transport.requests.isEmpty())
    }

    @Test
    fun saveFailureLeavesDisconnected() = singleThreadTest { scope ->
        val h = Harness(scope)
        h.store.writeFails = true
        h.model.connect()
        settle()
        assertEquals(GitHubConnectorState.Disconnected, h.snap.state)
        assertEquals(
            "The authorization was verified, but it could not be saved to the keychain. Try again.",
            h.snap.connectionNotice,
        )
    }

    @Test
    fun unauthorizedRepositoriesClearConnectionWithReconnectNotice() = singleThreadTest { scope ->
        val h = Harness(scope)
        h.reposStatus = 401
        h.model.connect()
        settle()
        assertEquals(GitHubConnectorState.Disconnected, h.snap.state)
        assertEquals("Reconnect GitHub to continue.", h.snap.connectionNotice)
        assertNull(h.store.token)
        assertFalse(h.snap.loading)
    }

    @Test
    fun repositoryFailureKeepsConnectionAndRetries() = singleThreadTest { scope ->
        val h = Harness(scope)
        h.reposStatus = 429
        h.model.connect()
        settle()
        val failed = h.snap.state as GitHubConnectorState.Connected
        assertEquals("GitHub is temporarily rate limiting requests. Try again later.", failed.notice)
        h.reposStatus = 200
        h.model.retry()
        settle()
        val recovered = h.snap.state as GitHubConnectorState.Connected
        assertNull(recovered.notice)
        assertEquals(listOf(1L, 2L), recovered.repos.map { it.id })
    }

    @Test
    fun expiredTokenAsksForReconnect() = singleThreadTest { scope ->
        val h = Harness(scope)
        h.connectFully()
        h.now += f.expiresIn * 1000L
        h.model.loadMore()
        settle()
        assertEquals(GitHubConnectorState.Disconnected, h.snap.state)
        assertEquals("Reconnect GitHub to continue.", h.snap.connectionNotice)
        assertNull(h.store.token)
    }

    @Test
    fun disconnectRevokesAndClears() = singleThreadTest { scope ->
        val h = Harness(scope)
        h.connectFully()
        h.model.disconnect()
        settle()
        assertEquals(GitHubConnectorState.Disconnected, h.snap.state)
        assertNull(h.store.token)
        assertNull(h.snap.connectionNotice)
        assertNull(h.snap.revocationSettingsUrl)
        val revoke = h.transport.requests.single { it.url.endsWith("/revoke") }
        assertEquals("""{"access_token":"${f.accessToken}"}""", String(revoke.body!!, Charsets.UTF_8))
    }

    @Test
    fun disconnectWithRevokeFailureLinksToSettings() = singleThreadTest { scope ->
        val h = Harness(scope)
        h.connectFully()
        h.revokeStatus = 502
        h.model.disconnect()
        settle()
        assertEquals(GitHubConnectorState.Disconnected, h.snap.state)
        assertNull(h.store.token)
        assertEquals(GitHubOAuthConfiguration.AUTHORIZED_APP_SETTINGS_URL, h.snap.revocationSettingsUrl)
        assertEquals(
            "GitHub was disconnected on this phone, but the server could not revoke the authorization. Revoke it in GitHub app settings.",
            h.snap.connectionNotice,
        )

        // A new connection attempt clears the fallback link.
        h.revokeStatus = 204
        h.model.connect()
        settle()
        assertNull(h.snap.revocationSettingsUrl)
        assertTrue(h.snap.state is GitHubConnectorState.Connected)
    }

    @Test
    fun lateRepositoryPageAfterDisconnectIsIgnored() = singleThreadTest { scope ->
        val h = Harness(scope)
        val gate = CompletableDeferred<Unit>()
        h.reposGate = gate
        h.model.connect()
        settle()
        assertTrue(h.snap.loading)
        assertTrue(h.snap.state is GitHubConnectorState.Connected)
        h.model.disconnect()
        settle()
        assertEquals(GitHubConnectorState.Disconnected, h.snap.state)
        gate.complete(Unit)
        settle()
        assertEquals(GitHubConnectorState.Disconnected, h.snap.state)
        assertFalse(h.snap.loading)
        assertNull(h.snap.connectionNotice)
        assertNull(h.store.token)
    }
}
