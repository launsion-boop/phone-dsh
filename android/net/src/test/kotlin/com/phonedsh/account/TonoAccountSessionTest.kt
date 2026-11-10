// phone-dsh — :net tests: the tono-account session on Android (§3).
// SPDX-License-Identifier: MIT
//
// The session runs against a local fake of the account service that rotates
// refresh tokens and revokes the whole session when an old one is reused —
// the same scenarios `Tests/PhoneDSHTests/TonoAccountSessionTests.swift`
// runs on iOS. No real phone number, token or SMS is involved.

package com.phonedsh.account

import com.phonedsh.gateway.CredentialScope
import com.phonedsh.gateway.GatewayCredential
import com.phonedsh.gateway.GatewayJson
import com.phonedsh.gateway.GatewayUrls
import com.phonedsh.gateway.JsonValue
import com.phonedsh.gateway.ModelEndpoint
import com.phonedsh.gateway.ModelGatewayCredentialProvider
import com.phonedsh.gateway.ModelKeySource
import java.io.IOException
import java.nio.charset.StandardCharsets
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

class TonoAccountSessionTest {

    /** Local account service: rotating refresh tokens with reuse revocation. */
    private class FakeService : TonoAccountTransport {
        private var counter = 0
        private var live: String? = null
        private val used = HashSet<String>()
        @Volatile var revoked = false
        @Volatile var refreshDelayMillis = 0L
        val scriptedRefresh = ArrayDeque<TonoAccountAnswer?>()
        val refreshTokensSent: MutableList<String> = java.util.Collections.synchronizedList(ArrayList())
        val logoutAuthorizations = ArrayList<String>()
        val paths = ArrayList<String>()

        override fun send(request: TonoAccountRequest): TonoAccountAnswer {
            val path = java.net.URI(request.url).path
            synchronized(this) { paths += path }
            return when (path) {
                "/v1/auth/otp/send" -> json(200, """{"challenge_id":"ch_TEST_0001"}""")
                "/v1/oauth/token" -> if (request.headers["content-type"] == "application/json") {
                    val body = GatewayJson.parse(String(request.body, StandardCharsets.UTF_8)) as JsonValue.Obj
                    if (body.string("code") != "123456") json(400, """{"error":"invalid_grant"}""") else synchronized(this) { issue() }
                } else {
                    val form = String(request.body, StandardCharsets.UTF_8)
                    val token = java.net.URLDecoder.decode(
                        form.split("&").first { it.startsWith("refresh_token=") }.removePrefix("refresh_token="),
                        "UTF-8",
                    )
                    refreshTokensSent += token
                    if (refreshDelayMillis > 0) Thread.sleep(refreshDelayMillis)
                    synchronized(this) {
                        if (scriptedRefresh.isNotEmpty()) {
                            scriptedRefresh.removeFirst()?.let { return it }
                        }
                        when {
                            revoked -> json(400, """{"error":"invalid_grant"}""")
                            token in used -> {
                                revoked = true
                                live = null
                                json(400, """{"error":"invalid_grant"}""")
                            }
                            token != live -> json(400, """{"error":"invalid_grant"}""")
                            else -> {
                                used += token
                                issue()
                            }
                        }
                    }
                }
                "/v1/auth/logout" -> synchronized(this) {
                    logoutAuthorizations += request.headers["authorization"].orEmpty()
                    revoked = true
                    json(204, "")
                }
                else -> json(404, "{}")
            }
        }

        private fun issue(): TonoAccountAnswer {
            counter++
            live = "rt_TEST_REFRESH_$counter"
            return json(
                200,
                """{"access_token":"at_TEST_ACCESS_$counter","refresh_token":"rt_TEST_REFRESH_$counter",""" +
                    """"token_type":"Bearer","expires_in":7200,"user":{"id":"u_TEST_0001","phone":"+8610000001234"}}""",
            )
        }

        private fun json(status: Int, text: String) =
            TonoAccountAnswer(status, mapOf("content-type" to "application/json"), text.toByteArray(StandardCharsets.UTF_8))
    }

    private class Offline : TonoAccountTransport {
        override fun send(request: TonoAccountRequest): TonoAccountAnswer = throw IOException("offline")
    }

    private class MemoryStore(initial: ByteArray? = null) : TonoAccountStore {
        @Volatile var value: ByteArray? = initial
        @Volatile var failSaves = false
        val operations: MutableList<String> = java.util.Collections.synchronizedList(ArrayList())
        val record: TonoSessionRecord? get() = value?.let { TonoAccountProtocol.decodeRecord(it) }

        override fun load(): ByteArray? = value
        override fun save(bytes: ByteArray) {
            operations += "save"
            if (failSaves) throw IOException("store unavailable")
            value = bytes
        }
        override fun delete() {
            operations += "delete"
            value = null
        }
    }

    private class Clock {
        @Volatile var now: Long = 1_762_214_400_000
        fun advance(seconds: Long) { now += seconds * 1000 }
    }

    private val device = TonoDeviceInfo("android", "Android", "0.1.0", "16")

    private fun session(service: TonoAccountTransport, store: MemoryStore, clock: Clock) =
        TonoAccountSession(TonoAccountClient(service), store, device) { clock.now }

    private fun signIn(session: TonoAccountSession) {
        val challenge = session.requestCode("100 0000 0000")
        assertEquals("+8610000000000", challenge.phone)
        session.signIn(challenge, " 123456 ")
    }

    private fun expectFailure(expected: TonoAccountFailure, block: () -> Unit) {
        try {
            block()
            fail("expected $expected")
        } catch (failure: TonoAccountException) {
            assertEquals(expected, failure.failure)
        }
    }

    @Test
    fun signInStoresOnlyTheRefreshToken() {
        val service = FakeService()
        val store = MemoryStore()
        val session = session(service, store, Clock())
        signIn(session)
        assertEquals("rt_TEST_REFRESH_1", store.record?.refreshToken)
        assertEquals("1234", store.record?.phoneHint)
        assertFalse(String(store.value!!, StandardCharsets.UTF_8).contains("at_TEST_ACCESS"))
        assertEquals("at_TEST_ACCESS_1", session.accessToken())
        assertTrue(service.refreshTokensSent.isEmpty())
        val state = session.state as TonoAccountState.SignedIn
        assertEquals("1234", state.phoneHint)
        assertTrue(session.hasSession)
    }

    @Test
    fun invalidInputSendsNothing() {
        val service = FakeService()
        val session = session(service, MemoryStore(), Clock())
        expectFailure(TonoAccountFailure.INVALID_PHONE) { session.requestCode("+1 2025550100") }
        val challenge = session.requestCode("10000000000")
        expectFailure(TonoAccountFailure.INVALID_CODE) { session.signIn(challenge, "12a456") }
        expectFailure(TonoAccountFailure.WRONG_CODE) { session.signIn(challenge, "654321") }
        assertEquals(listOf("/v1/auth/otp/send", "/v1/oauth/token"), service.paths)
        assertNull(session.accessToken())
    }

    @Test
    fun rotationReplacesTheStoredTokenAtomically() {
        val service = FakeService()
        val store = MemoryStore()
        val clock = Clock()
        val session = session(service, store, clock)
        signIn(session)
        for (round in 2..4) {
            clock.advance(7200 - 300)
            assertEquals("at_TEST_ACCESS_$round", session.accessToken())
            assertEquals("rt_TEST_REFRESH_$round", store.record?.refreshToken)
        }
        assertEquals(listOf("rt_TEST_REFRESH_1", "rt_TEST_REFRESH_2", "rt_TEST_REFRESH_3"), service.refreshTokensSent.toList())
        assertFalse("rotation never deletes and re-adds", "delete" in store.operations)
        assertFalse(service.revoked)
    }

    @Test
    fun concurrentCallersShareOneRefresh() {
        val service = FakeService()
        val clock = Clock()
        val session = session(service, MemoryStore(), clock)
        signIn(session)
        clock.advance(7200)
        service.refreshDelayMillis = 150
        val pool = Executors.newFixedThreadPool(16)
        val start = CountDownLatch(1)
        val futures = (0 until 24).map { pool.submit<String?> { start.await(); session.accessToken() } }
        start.countDown()
        val tokens = futures.map { it.get(10, TimeUnit.SECONDS) }
        pool.shutdown()
        assertEquals("single flight", 1, service.refreshTokensSent.size)
        assertEquals(setOf("at_TEST_ACCESS_2"), tokens.toSet())
        assertFalse(service.revoked)
    }

    @Test
    fun reuseOfARotatedTokenEndsTheSession() {
        val service = FakeService()
        val store = MemoryStore()
        val clock = Clock()
        val first = session(service, store, clock)
        signIn(first)
        store.failSaves = true
        clock.advance(7200)
        assertEquals("a failed write still serves the rotated token", "at_TEST_ACCESS_2", first.accessToken())
        assertEquals("the old token is still on disk", "rt_TEST_REFRESH_1", store.record?.refreshToken)

        store.failSaves = false
        val relaunched = session(service, store, clock)
        expectFailure(TonoAccountFailure.SESSION_ENDED) { relaunched.accessToken() }
        assertTrue(service.revoked)
        assertNull(store.value)
        assertEquals(TonoAccountState.SignedOut(TonoAccountNotice.SESSION_ENDED), relaunched.state)
        assertNull("signed out: callers fall back to their key", relaunched.accessToken())
        assertFalse(relaunched.hasSession)
    }

    @Test
    fun failedWriteIsRetriedBeforeTheNextRefresh() {
        val service = FakeService()
        val store = MemoryStore()
        val clock = Clock()
        val session = session(service, store, clock)
        signIn(session)
        store.failSaves = true
        clock.advance(7200)
        session.accessToken()
        store.failSaves = false
        clock.advance(7200)
        assertEquals("at_TEST_ACCESS_3", session.accessToken())
        assertEquals("rt_TEST_REFRESH_3", store.record?.refreshToken)
        assertEquals(listOf("rt_TEST_REFRESH_1", "rt_TEST_REFRESH_2"), service.refreshTokensSent.toList())
    }

    @Test
    fun transientRefreshFailureKeepsTheSession() {
        val service = FakeService()
        val store = MemoryStore()
        val clock = Clock()
        val session = session(service, store, clock)
        signIn(session)
        clock.advance(7200)
        service.scriptedRefresh += TonoAccountAnswer(
            503, mapOf("retry-after" to "3"), """{"error":{"code":"identity_unavailable"}}""".toByteArray(),
        )
        expectFailure(TonoAccountFailure.TEMPORARILY_UNAVAILABLE) { session.accessToken() }
        assertEquals("rt_TEST_REFRESH_1", store.record?.refreshToken)
        assertTrue(session.state is TonoAccountState.SignedIn)
        assertEquals("at_TEST_ACCESS_2", session.accessToken())
    }

    @Test
    fun invalidateOnlyDropsTheCurrentToken() {
        val service = FakeService()
        val session = session(service, MemoryStore(), Clock())
        signIn(session)
        session.invalidate("pdsk_TEST_NOT_OURS")
        assertEquals("at_TEST_ACCESS_1", session.accessToken())
        session.invalidate("at_TEST_ACCESS_1")
        assertEquals("at_TEST_ACCESS_2", session.accessToken())
        session.invalidate("at_TEST_ACCESS_1")
        assertEquals("at_TEST_ACCESS_2", session.accessToken())
        assertEquals(1, service.refreshTokensSent.size)
    }

    @Test
    fun signOutClearsLocallyAndCallsLogout() {
        val service = FakeService()
        val store = MemoryStore()
        val session = session(service, store, Clock())
        signIn(session)
        session.signOut()
        assertNull(store.value)
        assertEquals(listOf("Bearer at_TEST_ACCESS_1"), service.logoutAuthorizations)
        assertEquals(TonoAccountState.SignedOut(null), session.state)
        assertNull(session.accessToken())
    }

    @Test
    fun signOutSucceedsOffline() {
        val store = MemoryStore()
        val clock = Clock()
        signIn(session(FakeService(), store, clock))
        val offline = session(Offline(), store, clock)
        offline.signOut()
        assertNull(store.value)
        assertEquals(TonoAccountState.SignedOut(null), offline.state)
    }

    @Test
    fun lateRefreshAfterSignOutIsDiscarded() {
        val service = FakeService()
        val store = MemoryStore()
        val clock = Clock()
        val session = session(service, store, clock)
        signIn(session)
        clock.advance(7200)
        service.refreshDelayMillis = 300
        val pool = Executors.newSingleThreadExecutor()
        val pending = pool.submit<String?> { session.accessToken() }
        Thread.sleep(80)
        session.signOut()
        assertNull("the stale refresh publishes nothing", pending.get(5, TimeUnit.SECONDS))
        pool.shutdown()
        assertNull("the stale refresh writes nothing", store.value)
        assertEquals(TonoAccountState.SignedOut(null), session.state)
    }

    @Test
    fun reverificationAfter180Days() {
        val service = FakeService()
        val store = MemoryStore()
        val clock = Clock()
        signIn(session(service, store, clock))
        clock.advance(TonoAccountProtocol.REVERIFY_AFTER_SECONDS)
        val relaunched = session(service, store, clock)
        expectFailure(TonoAccountFailure.REVERIFY_REQUIRED) { relaunched.accessToken() }
        assertTrue("no request after the local limit", service.refreshTokensSent.isEmpty())
        assertNull(store.value)
        assertEquals(TonoAccountState.SignedOut(TonoAccountNotice.REVERIFY_REQUIRED), relaunched.state)
    }

    @Test
    fun unreadableRecordIsSignedOutAndKept() {
        val stored = """{"version":2,"refresh_token":"rt_TEST_REFRESH_1","login_at_ms":0}""".toByteArray()
        val store = MemoryStore(stored)
        val session = session(FakeService(), store, Clock())
        assertNull(session.accessToken())
        assertEquals(TonoAccountState.SignedOut(null), session.state)
        assertArrayEquals(stored, store.value)
        assertFalse(session.hasSession)
    }

    // ---- §4 precedence through the real Android model key seam

    @Test
    fun cloudKeySourceUsesTheTokenAndForwardsInvalidation() {
        val service = FakeService()
        val session = session(service, MemoryStore(), Clock())
        signIn(session)
        val stored = ModelKeySource { "pdsk_TEST_SHARED_KEY" }
        val endpoint = ModelEndpoint.parse("https://pdsh.tonoai.cn/v1/llm/anthropic")!!
        val provider = ModelGatewayCredentialProvider(endpoint, TonoAccountKeySource.overlay(endpoint.origin, session, stored))
        val scope = CredentialScope.of(GatewayUrls.parse("https://pdsh.tonoai.cn/v1/llm/anthropic/v1/messages")!!)
        assertEquals(GatewayCredential.Bearer("at_TEST_ACCESS_1"), provider.resolve(scope))
        provider.invalidate(GatewayCredential.Bearer("at_TEST_ACCESS_1"), scope)
        assertEquals(GatewayCredential.Bearer("at_TEST_ACCESS_2"), provider.resolve(scope))

        session.signOut()
        assertEquals("signed out keeps the API-key path", GatewayCredential.Bearer("pdsk_TEST_SHARED_KEY"), provider.resolve(scope))

        val other = ModelEndpoint.parse("https://api.deepseek.com/anthropic")!!
        val otherProvider = ModelGatewayCredentialProvider(other, TonoAccountKeySource.overlay(other.origin, session, stored))
        signIn(session)
        val otherScope = CredentialScope.of(GatewayUrls.parse("https://api.deepseek.com/anthropic/v1/messages")!!)
        assertEquals("other origins never see the token", GatewayCredential.Bearer("pdsk_TEST_SHARED_KEY"), otherProvider.resolve(otherScope))
    }

    @Test
    fun signedInWithoutATokenFailsClosed() {
        val service = FakeService()
        val clock = Clock()
        val session = session(service, MemoryStore(), clock)
        signIn(session)
        clock.advance(7200)
        service.scriptedRefresh += TonoAccountAnswer(503)
        val source = TonoAccountKeySource.overlay("https://pdsh.tonoai.cn:443", session) { "pdsk_TEST_SHARED_KEY" }
        try {
            source.readKey()
            fail("fell back to the shared key")
        } catch (_: com.phonedsh.gateway.CredentialUnavailableException) {
        }
    }
}
