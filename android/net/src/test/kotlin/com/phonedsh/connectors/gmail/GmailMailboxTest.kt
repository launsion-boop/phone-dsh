// phone-dsh — :net tests for the Gmail page state.
// SPDX-License-Identifier: MIT
//
// Drives the real GmailMailbox and GmailApi with a fake authorizer and a fake
// transport on runBlocking's single-threaded event loop, mirroring the
// behaviour of GmailMailbox in examples/probe-app/PhoneDSHProbe/GmailConnectorPage.swift.

package com.phonedsh.connectors.gmail

import java.net.URI
import java.net.URLDecoder
import java.util.concurrent.ConcurrentHashMap
import kotlin.coroutines.cancellation.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.async
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import kotlinx.coroutines.yield
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

class GmailMailboxTest {

    private class FakeAuthorizer(override val isConfigured: Boolean = true) : GmailAuthorizer {
        var restoreResult = true
        var connectFailure: GmailAuthorizationFailure? = null
        var revokes = true
        var signOuts = 0
        var disconnects = 0

        override suspend fun restore(): Boolean = restoreResult
        override suspend fun connect() {
            connectFailure?.let { throw GmailAuthorizationException(it) }
        }
        override suspend fun accessToken(): String = "token"
        override suspend fun disconnect(): Boolean {
            disconnects++
            return revokes
        }
        override fun signOut() {
            signOuts++
        }
    }

    /** Routes by path; `q` (or the inbox) picks the listing, and gates can hold a request. */
    private class FakeGmail : GmailHttpTransport {
        val listings = ConcurrentHashMap<String, String>()
        val gates = ConcurrentHashMap<String, CompletableDeferred<Unit>>()
        val arrived = ConcurrentHashMap<String, CompletableDeferred<Unit>>()
        var listingStatus = 200

        fun arrival(key: String) = arrived.getOrPut(key) { CompletableDeferred() }

        override suspend fun get(url: String, headers: Map<String, String>): GmailHttpResponse {
            val uri = URI(url)
            val query = (uri.rawQuery ?: "").split('&').filter { it.isNotEmpty() }.associate {
                val (name, value) = it.split('=', limit = 2)
                name to URLDecoder.decode(value, Charsets.UTF_8)
            }
            val path = uri.rawPath.removePrefix("/gmail/v1/users/me/")
            val key = when {
                path == "messages" -> "list:" + (query["q"] ?: "INBOX") + (query["pageToken"]?.let { "@$it" } ?: "")
                path.startsWith("messages/") -> "${query["format"]}:" + path.removePrefix("messages/")
                else -> path
            }
            arrival(key).complete(Unit)
            gates[key]?.await()
            return when {
                path == "profile" -> ok("""{"emailAddress":"me@example.com"}""")
                path == "messages" ->
                    if (listingStatus != 200) GmailHttpResponse(listingStatus, ByteArray(0))
                    else ok(listings[key.removePrefix("list:")] ?: """{}""")
                key.startsWith("metadata:") ->
                    ok("""{"id":"${path.removePrefix("messages/")}","payload":{"headers":[{"name":"Subject","value":"S"}]}}""")
                else -> ok(
                    """{"id":"${path.removePrefix("messages/")}","payload":{"mimeType":"text/plain","body":{"data":"${GmailApiTest.encoded("body")}"}}}""",
                )
            }
        }

        private fun ok(json: String) = GmailHttpResponse(200, json.toByteArray(Charsets.UTF_8))
    }

    private fun listing(vararg ids: String, next: String? = null): String =
        """{"messages":[${ids.joinToString(",") { "{\"id\":\"$it\"}" }}]${next?.let { ",\"nextPageToken\":\"$it\"" } ?: ""}}"""

    private fun CoroutineScope.mailbox(authorizer: FakeAuthorizer, gmail: FakeGmail) =
        GmailMailbox(authorizer, GmailApi(gmail), this) { _, en -> en }

    private suspend fun GmailMailbox.await(predicate: (GmailMailboxSnapshot) -> Boolean): GmailMailboxSnapshot =
        withTimeout(5_000) { snapshot.first(predicate) }

    private suspend fun GmailMailbox.connected(): GmailMailboxSnapshot =
        await { it.account is GmailAccount.Connected && !it.loading }

    /** The fakes never suspend, so a few event-loop turns finish a launched mutator. */
    private suspend fun settle() = repeat(20) { yield() }

    private fun ids(snapshot: GmailMailboxSnapshot) = snapshot.messages.map { it.id }

    @Test
    fun unconfiguredBuildStartsUnconfiguredAndIgnoresConnect() = runBlocking<Unit> {
        val mailbox = mailbox(FakeAuthorizer(isConfigured = false), FakeGmail())
        assertEquals(GmailAccount.Unconfigured, mailbox.snapshot.value.account)
        mailbox.connect()
        mailbox.restore()
        repeat(10) { yield() }
        assertEquals(GmailAccount.Unconfigured, mailbox.snapshot.value.account)
    }

    @Test
    fun restoreWithoutPreviousConnectionStaysDisconnected() = runBlocking<Unit> {
        val authorizer = FakeAuthorizer().apply { restoreResult = false }
        val mailbox = mailbox(authorizer, FakeGmail())
        assertEquals(GmailAccount.Disconnected, mailbox.snapshot.value.account)
        mailbox.restore()
        settle()
        val state = mailbox.snapshot.value
        assertEquals(GmailAccount.Disconnected, state.account)
        assertNull(state.notice)
    }

    @Test
    fun connectLoadsTheAccountAndTheInbox() = runBlocking<Unit> {
        val gmail = FakeGmail().apply { listings["INBOX"] = listing("m1", "m2", next = "p2") }
        val mailbox = mailbox(FakeAuthorizer(), gmail)
        mailbox.connect()
        val state = mailbox.connected()
        assertEquals("me@example.com", (state.account as GmailAccount.Connected).email)
        assertEquals(listOf("m1", "m2"), ids(state))
        assertEquals("p2", state.nextPage)
        assertNull(state.notice)
    }

    @Test
    fun cancelledConnectReturnsToDisconnectedSilently() = runBlocking<Unit> {
        val authorizer = FakeAuthorizer().apply { connectFailure = GmailAuthorizationFailure.CANCELLED }
        val mailbox = mailbox(authorizer, FakeGmail())
        mailbox.connect()
        settle()
        val state = mailbox.snapshot.value
        assertEquals(GmailAccount.Disconnected, state.account)
        assertNull(state.notice)
        assertEquals(0, authorizer.signOuts)
    }

    @Test
    fun missingReadPermissionAsksForReconnect() = runBlocking<Unit> {
        val authorizer = FakeAuthorizer().apply { connectFailure = GmailAuthorizationFailure.READ_PERMISSION_REQUIRED }
        val mailbox = mailbox(authorizer, FakeGmail())
        mailbox.connect()
        val state = mailbox.await { it.account == GmailAccount.Reconnect }
        assertEquals("Tap Connect Google account and select Gmail read access on the Google page.", state.notice)
        assertEquals(0, authorizer.signOuts)

        // Reconnect is allowed from the reconnect state.
        authorizer.connectFailure = null
        mailbox.connect()
        mailbox.connected()
    }

    @Test
    fun unavailableConnectShowsTheGenericNotice() = runBlocking<Unit> {
        val authorizer = FakeAuthorizer().apply { connectFailure = GmailAuthorizationFailure.UNAVAILABLE }
        val mailbox = mailbox(authorizer, FakeGmail())
        mailbox.connect()
        settle()
        val state = mailbox.snapshot.value
        assertEquals(GmailAccount.Disconnected, state.account)
        assertEquals("Could not read Gmail. Try again.", state.notice)
    }

    @Test
    fun unauthorizedSearchSignsOutAndAsksForReconnect() = runBlocking<Unit> {
        val gmail = FakeGmail().apply { listings["INBOX"] = listing("m1") }
        val authorizer = FakeAuthorizer()
        val mailbox = mailbox(authorizer, gmail)
        mailbox.connect()
        mailbox.connected()
        gmail.listingStatus = 401
        mailbox.search()
        val state = mailbox.await { it.account == GmailAccount.Reconnect }
        assertEquals("Reconnect Gmail to continue.", state.notice)
        assertTrue(state.messages.isEmpty())
        assertEquals(1, authorizer.signOuts)
    }

    @Test
    fun forbiddenSearchKeepsTheConnectionWithANotice() = runBlocking<Unit> {
        val gmail = FakeGmail()
        val mailbox = mailbox(FakeAuthorizer(), gmail)
        mailbox.connect()
        mailbox.connected()
        gmail.listingStatus = 403
        mailbox.search()
        val state = mailbox.await { it.notice != null && !it.loading }
        assertTrue(state.account is GmailAccount.Connected)
        assertTrue(state.notice!!.startsWith("Google denied this Gmail request."))
    }

    @Test
    fun staleSearchResultIsIgnoredAfterANewSearch() = runBlocking<Unit> {
        val gmail = FakeGmail().apply {
            listings["first"] = listing("old")
            listings["second"] = listing("new")
            gates["list:first"] = CompletableDeferred()
        }
        val mailbox = mailbox(FakeAuthorizer(), gmail)
        mailbox.connect()
        mailbox.connected()

        mailbox.setQuery("  first ")
        mailbox.search()
        gmail.arrival("list:first").await()
        mailbox.setQuery("second")
        mailbox.search()
        val state = mailbox.await { ids(it) == listOf("new") && !it.loading }
        gmail.gates.getValue("list:first").complete(Unit)
        // Let the stale request finish, then check that nothing changed.
        gmail.arrival("metadata:old").await()
        repeat(20) { yield() }
        assertEquals(state, mailbox.snapshot.value)
        assertEquals("second", mailbox.snapshot.value.query)
    }

    @Test
    fun appendDeduplicatesAndFollowsTheNextPage() = runBlocking<Unit> {
        val gmail = FakeGmail().apply {
            listings["INBOX"] = listing("m1", "m2", next = "p2")
            listings["INBOX@p2"] = listing("m2", "m3")
        }
        val mailbox = mailbox(FakeAuthorizer(), gmail)
        mailbox.connect()
        mailbox.connected()
        mailbox.search(append = true)
        val state = mailbox.await { ids(it) == listOf("m1", "m2", "m3") && !it.loading }
        assertNull(state.nextPage)

        // Without a next page, append does nothing.
        mailbox.search(append = true)
        repeat(10) { yield() }
        assertEquals(state, mailbox.snapshot.value)
    }

    @Test
    fun readReturnsTheMessageBody() = runBlocking<Unit> {
        val mailbox = mailbox(FakeAuthorizer(), FakeGmail().apply { listings["INBOX"] = listing("m1") })
        mailbox.connect()
        mailbox.connected()
        assertEquals(GmailBody.Plain("body"), mailbox.read("m1").body)
    }

    @Test
    fun readAfterTheConnectionChangesIsCancelled() = runBlocking<Unit> {
        val gmail = FakeGmail().apply { gates["full:m1"] = CompletableDeferred() }
        val authorizer = FakeAuthorizer()
        val mailbox = mailbox(authorizer, gmail)
        mailbox.connect()
        mailbox.connected()

        val read = async { runCatching { mailbox.read("m1") } }
        gmail.arrival("full:m1").await()
        mailbox.disconnect()
        mailbox.await { it.account == GmailAccount.Disconnected }
        gmail.gates.getValue("full:m1").complete(Unit)
        val failure = read.await().exceptionOrNull()
        assertTrue("expected cancellation, got $failure", failure is CancellationException)
        assertNull(mailbox.snapshot.value.notice)

        // With no connection at all, read is refused as not authorized.
        try {
            mailbox.read("m1")
            fail("expected not authorized")
        } catch (failure: GmailAuthorizationException) {
            assertEquals(GmailAuthorizationFailure.NOT_AUTHORIZED, failure.failure)
        }
    }

    @Test
    fun disconnectClearsResultsAndReportsAFailedRevoke() = runBlocking<Unit> {
        val authorizer = FakeAuthorizer().apply { revokes = false }
        val mailbox = mailbox(authorizer, FakeGmail().apply { listings["x"] = listing("m1") })
        mailbox.connect()
        mailbox.connected()
        mailbox.setQuery("x")
        mailbox.search()
        mailbox.await { ids(it) == listOf("m1") && !it.loading }
        mailbox.disconnect()
        val state = mailbox.await { it.account == GmailAccount.Disconnected }
        assertTrue(state.messages.isEmpty())
        assertEquals("", state.query)
        assertNull(state.nextPage)
        assertEquals(
            "Disconnected on this phone. To revoke access, remove Phone DSH in your Google Account connections.",
            state.notice,
        )
        assertEquals(1, authorizer.disconnects)
    }

    @Test
    fun successfulRevokeDisconnectsWithoutNotice() = runBlocking<Unit> {
        val mailbox = mailbox(FakeAuthorizer(), FakeGmail())
        mailbox.connect()
        mailbox.connected()
        mailbox.disconnect()
        assertNull(mailbox.await { it.account == GmailAccount.Disconnected }.notice)
    }

    @Test
    fun readErrorMessagesUseTheNativeTextPairs() = runBlocking<Unit> {
        val mailbox = GmailMailbox(FakeAuthorizer(), GmailApi(FakeGmail()), this) { zh, _ -> zh }
        assertEquals("Gmail 授权已失效，请重新连接。", mailbox.readErrorMessage(GmailException(GmailError.UNAUTHORIZED)))
        assertEquals(
            "Gmail 授权已失效，请重新连接。",
            mailbox.readErrorMessage(GmailAuthorizationException(GmailAuthorizationFailure.INVALID_GRANT)),
        )
        assertEquals("找不到这封邮件。", mailbox.readErrorMessage(GmailException(GmailError.NOT_FOUND)))
        assertEquals("暂时无法读取 Gmail，请稍后重试。", mailbox.readErrorMessage(IllegalStateException()))
    }
}
