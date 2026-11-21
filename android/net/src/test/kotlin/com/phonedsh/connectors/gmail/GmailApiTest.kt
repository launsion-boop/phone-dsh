// phone-dsh — :net tests for the Gmail REST client.
// SPDX-License-Identifier: MIT
//
// Mirrors examples/probe-app/PhoneDSHSimTests/GmailAPITests.swift and drives
// the real GmailApi through a fake transport.

package com.phonedsh.connectors.gmail

import java.io.IOException
import java.net.URI
import java.net.URLDecoder
import java.util.Base64
import java.util.Collections
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

class GmailApiTest {

    private class Recorded(val url: String, val headers: Map<String, String>) {
        val uri: URI = URI(url)
        val path: String get() = uri.rawPath
        val rawQuery: String get() = uri.rawQuery ?: ""
        val query: List<Pair<String, String>>
            get() = rawQuery.split('&').filter { it.isNotEmpty() }.map {
                val (name, value) = it.split('=', limit = 2)
                URLDecoder.decode(name, Charsets.UTF_8) to URLDecoder.decode(value, Charsets.UTF_8)
            }
    }

    private class FakeTransport(val route: suspend (Recorded) -> GmailHttpResponse) : GmailHttpTransport {
        val requests: MutableList<Recorded> = Collections.synchronizedList(mutableListOf())
        override suspend fun get(url: String, headers: Map<String, String>): GmailHttpResponse {
            val request = Recorded(url, headers)
            requests += request
            return route(request)
        }
    }

    private fun ok(json: String) = GmailHttpResponse(200, json.toByteArray(Charsets.UTF_8))

    private fun api(route: suspend (Recorded) -> GmailHttpResponse) = FakeTransport(route).let { it to GmailApi(it) }

    private fun <T> gmailError(expected: GmailError, block: suspend () -> T) {
        try {
            runBlocking { block() }
            fail("expected $expected")
        } catch (failure: GmailException) {
            assertEquals(expected, failure.error)
        }
    }

    private fun metadata(id: String, from: String = "QA <qa@example.com>", subject: String = "Fixture", date: String? = null) =
        ok(
            """{"id":"$id",${date?.let { "\"internalDate\":\"$it\"," } ?: ""}"payload":{"headers":[""" +
                """{"name":"From","value":"$from"},{"name":"subject","value":"$subject"}]}}""",
        )

    @Test
    fun wakeHistoryUsesOnlyInboxMetadataAndKeepsItsProviderWatermark() = runBlocking<Unit> {
        val (transport, api) = api { request ->
            when (request.path) {
                "/gmail/v1/users/me/profile" -> ok(
                    """{"emailAddress":"qa@example.com","historyId":"4180"}""",
                )
                "/gmail/v1/users/me/history" -> ok(
                    """{"historyId":"4180","history":[{"id":"4110","messagesAdded":[
                       {"message":{"id":"inbox","labelIds":["INBOX"]}},
                       {"message":{"id":"other","labelIds":["SENT"]}}]}]}""",
                )
                "/gmail/v1/users/me/messages/inbox" -> metadata("inbox")
                else -> error("Unexpected request ${request.path}")
            }
        }
        val mailbox = api.wakeMailbox("fixture")
        assertEquals("4180", mailbox.historyId)
        val page = api.wakeHistory("4100", "fixture")
        assertEquals("4110", page.historyId)
        assertEquals(listOf("inbox"), page.messages.map { it.id })
        assertTrue(transport.requests[1].query.contains("startHistoryId" to "4100"))
        assertTrue(transport.requests[1].query.contains("labelId" to "INBOX"))
        assertTrue(transport.requests[2].query.contains("format" to "metadata"))
        assertFalse(transport.requests.any { it.query.contains("format" to "full") })
    }

    @Test
    fun searchKeepsGmailQueryEncodingAndLoadsOnlyMetadata() = runBlocking<Unit> {
        val (transport, api) = api { request ->
            assertEquals("gmail.googleapis.com", request.uri.host)
            assertEquals("https", request.uri.scheme)
            assertEquals("Bearer fixture", request.headers["Authorization"])
            when (request.path) {
                "/gmail/v1/users/me/messages" -> ok("""{"messages":[{"id":"message2"},{"id":"message1"}],"nextPageToken":"more"}""")
                "/gmail/v1/users/me/messages/message2" -> metadata("message2", date = "1700000000123")
                "/gmail/v1/users/me/messages/message1" -> metadata("message1", from = "B <b@example.com>")
                else -> GmailHttpResponse(500, ByteArray(0))
            }
        }
        val page = api.search("from:qa+tag@example.com & subject:测试", pageToken = "p 2", token = "fixture")
        assertEquals(listOf("message2", "message1"), page.messages.map { it.id })
        assertEquals("QA <qa@example.com>", page.messages[0].sender)
        assertEquals("Fixture", page.messages[1].subject)
        assertEquals(1_700_000_000_123L, page.messages[0].dateMillis)
        assertNull(page.messages[1].dateMillis)
        assertEquals("more", page.nextPageToken)

        val listing = transport.requests.first { it.path == "/gmail/v1/users/me/messages" }
        assertEquals(
            "maxResults=12&q=from%3Aqa%2Btag%40example.com%20%26%20subject%3A%E6%B5%8B%E8%AF%95&pageToken=p%202",
            listing.rawQuery,
        )
        assertFalse(listing.rawQuery.contains('+'))
        val reads = transport.requests.filter { it.path.startsWith("/gmail/v1/users/me/messages/") }
        assertEquals(2, reads.size)
        for (read in reads) {
            assertEquals(
                listOf("format" to "metadata", "metadataHeaders" to "From", "metadataHeaders" to "Subject"),
                read.query,
            )
        }
    }

    @Test
    fun emptyQueryListsTheInbox() = runBlocking<Unit> {
        val (transport, api) = api { ok("""{}""") }
        val page = api.search("", token = "fixture")
        assertTrue(page.messages.isEmpty())
        assertNull(page.nextPageToken)
        assertEquals("maxResults=12&labelIds=INBOX", transport.requests.single().rawQuery)
    }

    @Test
    fun missingMessagesAreDroppedAndOrderIsPreserved() = runBlocking<Unit> {
        val (_, api) = api { request ->
            when (request.path) {
                "/gmail/v1/users/me/messages" -> ok("""{"messages":[{"id":"a"},{"id":"gone"},{"id":"c"},{"id":"d"}]}""")
                "/gmail/v1/users/me/messages/gone" -> GmailHttpResponse(404, ByteArray(0))
                else -> metadata(request.path.substringAfterLast('/'))
            }
        }
        assertEquals(listOf("a", "c", "d"), api.search("x", token = "t").messages.map { it.id })
    }

    @Test
    fun otherMetadataFailuresFailTheSearch() {
        val (_, api) = api { request ->
            if (request.path == "/gmail/v1/users/me/messages") ok("""{"messages":[{"id":"a"}]}""")
            else GmailHttpResponse(403, ByteArray(0))
        }
        gmailError(GmailError.FORBIDDEN) { api.search("x", token = "t") }
    }

    @Test
    fun nestedMultipartUsesPlainTextAndSkipsAttachedText() = runBlocking<Unit> {
        val (transport, api) = api {
            ok(
                """{"id":"message1","payload":{"mimeType":"multipart/mixed","headers":[{"name":"Subject","value":"Fixture"}],"parts":[
                  {"mimeType":"text/plain","filename":"attachment.txt","body":{"data":"${encoded("Attachment")}"}},
                  {"mimeType":"text/plain","headers":[{"name":"Content-Disposition","value":"Attachment; x"}],"body":{"data":"${encoded("Disposed")}"}},
                  {"mimeType":"multipart/alternative","parts":[
                    {"mimeType":"text/html","body":{"data":"${encoded("<p>HTML</p>")}"}},
                    {"mimeType":"TEXT/PLAIN","body":{"data":"${encoded("正文 +/")}"}}
                  ]}
                ]}}""",
            )
        }
        val message = api.message("message1", "fixture")
        assertEquals(GmailBody.Plain("正文 +/"), message.body)
        assertEquals("Fixture", message.summary.subject)
        assertEquals(listOf("format" to "full"), transport.requests.single().query)
        assertEquals("/gmail/v1/users/me/messages/message1", transport.requests.single().path)
    }

    @Test
    fun htmlOnlyMailIsKeptSeparateFromPlainText() = runBlocking<Unit> {
        val (_, api) = api {
            ok("""{"id":"message2","payload":{"mimeType":"text/html","body":{"data":"${encoded("<p>HTML only</p>")}"}}}""")
        }
        assertEquals(GmailBody.Html("<p>HTML only</p>"), api.message("message2", "fixture").body)
    }

    @Test
    fun emptyOversizeOrUndecodableBodiesAreUnavailable() = runBlocking<Unit> {
        val oversize = encoded("a".repeat(2_000_001))
        val exact = encoded("a".repeat(2_000_000))
        for ((data, expected) in listOf(
            "" to GmailBody.Unavailable,
            oversize to GmailBody.Unavailable,
            "!!!" to GmailBody.Unavailable,
            exact to GmailBody.Plain("a".repeat(2_000_000)),
        )) {
            val (_, api) = api { ok("""{"id":"m","payload":{"mimeType":"text/plain","body":{"data":"$data"}}}""") }
            assertEquals(expected, api.message("m", "t").body)
        }
        val (_, noPayload) = api { ok("""{"id":"m"}""") }
        assertEquals(GmailBody.Unavailable, noPayload.message("m", "t").body)
    }

    @Test
    fun messageIdCannotEscapeTheMessagesPath() {
        for (id in listOf("../../profile", "", "a/b", "a b", "a%2F", "ü")) {
            val (transport, api) = api { fail("no request expected"); ok("{}") }
            gmailError(GmailError.INVALID_RESPONSE) { api.message(id, "fixture") }
            assertTrue(transport.requests.isEmpty())
        }
    }

    @Test
    fun statusesMapToGmailErrors() {
        for ((status, expected) in listOf(
            401 to GmailError.UNAUTHORIZED,
            403 to GmailError.FORBIDDEN,
            404 to GmailError.NOT_FOUND,
            500 to GmailError.SERVICE_UNAVAILABLE,
            302 to GmailError.SERVICE_UNAVAILABLE,
            429 to GmailError.SERVICE_UNAVAILABLE,
        )) {
            val (_, api) = api { GmailHttpResponse(status, "{}".toByteArray()) }
            gmailError(expected) { api.accountEmail("t") }
        }
        val (_, offline) = api { throw IOException("offline") }
        gmailError(GmailError.SERVICE_UNAVAILABLE) { offline.accountEmail("t") }
    }

    @Test
    fun undecodableAnswersAreInvalidResponses() {
        for (body in listOf("not json", "[]", """{"emailAddress":""}""", """{"emailAddress":7}""", "{}")) {
            val (_, api) = api { ok(body) }
            gmailError(GmailError.INVALID_RESPONSE) { api.accountEmail("t") }
        }
        val (_, badHeader) = api { ok("""{"id":"m","payload":{"headers":[{"name":"From"}]}}""") }
        gmailError(GmailError.INVALID_RESPONSE) { badHeader.message("m", "t") }
    }

    @Test
    fun profileReturnsTheAccountAddress() = runBlocking<Unit> {
        val (transport, api) = api { ok("""{"emailAddress":"me@example.com","messagesTotal":3}""") }
        assertEquals("me@example.com", api.accountEmail("tok"))
        assertEquals("https://gmail.googleapis.com/gmail/v1/users/me/profile", transport.requests.single().url)
        assertEquals("Bearer tok", transport.requests.single().headers["Authorization"])
    }

    companion object {
        fun encoded(text: String): String =
            Base64.getEncoder().encodeToString(text.toByteArray(Charsets.UTF_8))
                .replace('+', '-').replace('/', '_').replace("=", "")
    }
}
