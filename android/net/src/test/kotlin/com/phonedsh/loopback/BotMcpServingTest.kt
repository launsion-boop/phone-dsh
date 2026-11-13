// phone-dsh — :loopback tests: the Bot MCP HTTP surface over a real socket.
// SPDX-License-Identifier: MIT
//
// Every assertion below goes through `java.net.Socket` to a real
// `127.0.0.1:<port>` listener. The mock that is not allowed is an HTTP-stack
// mock: the tests do not bypass the socket to call BotMcpServing directly.

package com.phonedsh.loopback

import java.util.concurrent.CopyOnWriteArrayList
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class BotMcpServingTest {
    private val token: String = "0123456789abcdef0123456789abcdef"

    // ------------------------------------------------------------- happy path

    @Test
    fun postMcpReturnsTheHandlerJsonWithTheFrozenHeaders() = runBlocking<Unit> {
        val handler = BotMcpTestHandler { BotMcpResponse.Json(200, """{"ok":"mcp"}""".toByteArray()) }
        BotMcpListener(handler, token = token).use { listener ->
            val endpoint = listener.startOrThrow()
            val response = botMcpRawRequest(
                endpoint.port,
                "/mcp",
                mapOf("Authorization" to "Bearer $token"),
                """{"jsonrpc":"2.0","id":1,"method":"ping"}""".toByteArray(),
                expectClose = true,
            )
            assertEquals(200, response.status)
            assertEquals("application/json", response.header("Content-Type"))
            assertEquals(response.body.size.toString(), response.header("Content-Length"))
            assertEquals("close", response.header("Connection"))
            assertEquals("test-session", response.header("Mcp-Session-Id"))
            assertEquals("""{"ok":"mcp"}""", response.bodyText)
            assertEquals(1, handler.requests.size)
            assertEquals("/mcp", handler.requests.single().path)
            assertEquals("""{"jsonrpc":"2.0","id":1,"method":"ping"}""", handler.requests.single().bodyText())
        }
    }

    @Test
    fun identityRoutesReturnHandlerJsonWithoutAnMcpSessionHeader() = runBlocking<Unit> {
        val handler = BotMcpTestHandler { request ->
            when (request.path) {
                "/identity/register" -> BotMcpResponse.Json(200, """{"ok":true,"id":"abc"}""".toByteArray())
                "/identity/cancel" -> BotMcpResponse.Json(200, """{"ok":true}""".toByteArray())
                else -> BotMcpResponse.Json(200, """{"ok":true,"allowed":true,"pending":false}""".toByteArray())
            }
        }
        BotMcpListener(handler, token = token).use { listener ->
            val endpoint = listener.startOrThrow()
            for (path in listOf("/identity/register", "/identity/cancel", "/approval")) {
                val response = botMcpRawRequest(
                    endpoint.port,
                    path,
                    mapOf("Authorization" to "Bearer $token"),
                    """{"any":"body"}""".toByteArray(),
                )
                assertEquals(path, 200, response.status)
                assertEquals(path, "application/json", response.header("Content-Type"))
                assertNull(path, response.header("Mcp-Session-Id"))
            }
            assertEquals(3, handler.requests.size)
        }
    }

    // ---------------------------------------------------------------- bearer

    @Test
    fun missingWrongCaseShiftedAndPreviousBearersAre401() = runBlocking<Unit> {
        val handler = BotMcpTestHandler()
        BotMcpListener(handler, token = token).use { listener ->
            val endpoint = listener.startOrThrow()
            val cases = listOf(
                null,
                "Bearer ${"f".repeat(32)}",
                "bearer $token",
                "Bearer ${token.uppercase()}",
                "Token $token",
            )
            for (authorization in cases) {
                val headers = if (authorization == null) emptyMap() else mapOf("Authorization" to authorization)
                val response = botMcpRawRequest(
                    endpoint.port,
                    "/mcp",
                    headers,
                    """{"jsonrpc":"2.0","id":1,"method":"ping"}""".toByteArray(),
                )
                assertEquals("authorization=$authorization", 401, response.status)
                assertEquals("""{"error":"unauthorized"}""", response.bodyText)
            }
            assertEquals("no rejected request reaches the handler", 0, handler.requests.size)
        }
    }

    // ---------------------------------------------------------------- origin

    @Test
    fun aRequestWithAnotherOriginIs403AndTheListenerOriginIsCaseInsensitive() = runBlocking<Unit> {
        val handler = BotMcpTestHandler { BotMcpResponse.Json(200, "{}".toByteArray()) }
        BotMcpListener(handler, token = token).use { listener ->
            val endpoint = listener.startOrThrow()
            val body = """{"jsonrpc":"2.0","id":1,"method":"ping"}""".toByteArray()
            val rejected = botMcpRawRequest(
                endpoint.port,
                "/mcp",
                mapOf(
                    "Authorization" to "Bearer $token",
                    "Origin" to "http://127.0.0.1:${endpoint.port + 1}",
                ),
                body,
            )
            assertEquals(403, rejected.status)
            assertEquals("""{"error":"origin mismatch"}""", rejected.bodyText)

            // The §11 order is origin before bearer: a bad Origin wins even
            // when the bearer is also missing.
            val noBearer = botMcpRawRequest(
                endpoint.port,
                "/mcp",
                mapOf("Origin" to "http://127.0.0.1:1"),
                body,
            )
            assertEquals(403, noBearer.status)
            assertEquals("""{"error":"origin mismatch"}""", noBearer.bodyText)

            val accepted = botMcpRawRequest(
                endpoint.port,
                "/mcp",
                mapOf(
                    "Authorization" to "Bearer $token",
                    "Origin" to endpoint.origin.uppercase(),
                ),
                body,
            )
            assertEquals(200, accepted.status)
            assertEquals(1, handler.requests.size)
        }
    }

    // ---------------------------------------------------------------- method

    @Test
    fun everyMethodOtherThanPostIs405() = runBlocking<Unit> {
        val handler = BotMcpTestHandler()
        BotMcpListener(handler, token = token).use { listener ->
            val endpoint = listener.startOrThrow()
            for (method in listOf("GET", "PUT", "DELETE", "PATCH", "HEAD", "OPTIONS")) {
                val response = botMcpRawRequest(
                    endpoint.port,
                    "/mcp",
                    mapOf("Authorization" to "Bearer $token"),
                    ByteArray(0),
                    method = method,
                )
                assertEquals(method, 405, response.status)
                assertEquals("""{"error":"method not allowed"}""", response.bodyText)
            }
            assertEquals(0, handler.requests.size)
        }
    }

    // ----------------------------------------------------------------- paths

    @Test
    fun pathsAreExactAndTrailingSlashCaseOrUnknownAre404() = runBlocking<Unit> {
        val handler = BotMcpTestHandler()
        BotMcpListener(handler, token = token).use { listener ->
            val endpoint = listener.startOrThrow()
            for (path in listOf("/mcp/", "/MCP", "/mcp/native", "/", "/identity/register/")) {
                val response = botMcpRawRequest(
                    endpoint.port,
                    path,
                    mapOf("Authorization" to "Bearer $token"),
                    """{"jsonrpc":"2.0","id":1,"method":"ping"}""".toByteArray(),
                )
                assertEquals(path, 404, response.status)
                assertEquals(path, """{"error":"not found"}""", response.bodyText)
            }
            assertEquals(0, handler.requests.size)
        }
    }

    @Test
    fun queryFragmentAndDotSegmentTargetsAre400() = runBlocking<Unit> {
        val handler = BotMcpTestHandler()
        BotMcpListener(handler, token = token).use { listener ->
            val endpoint = listener.startOrThrow()
            for (target in listOf("/mcp?x=1", "/identity/../mcp", "/approval#x")) {
                val response = botMcpRawRequest(
                    endpoint.port,
                    target,
                    mapOf("Authorization" to "Bearer $token"),
                    """{"ok":true}""".toByteArray(),
                )
                assertEquals(target, 400, response.status)
                assertEquals(target, """{"error":"invalid request target"}""", response.bodyText)
            }
            assertEquals(0, handler.requests.size)
        }
    }

    // ------------------------------------------------------------------ body

    @Test
    fun aDeclaredBodyOverOneMebibyteIs413BeforeAnyHandler() = runBlocking<Unit> {
        val handler = BotMcpTestHandler()
        BotMcpListener(handler, token = token).use { listener ->
            val endpoint = listener.startOrThrow()
            // Declared length only: the frozen rule is decided from the header
            // without reading a body (Swift's rawExchange case).
            val response = botMcpRawRequest(
                endpoint.port,
                "/mcp",
                mapOf("Authorization" to "Bearer $token"),
                """{"too":"large"}""".toByteArray(),
                declaredLength = BotMcpServing.MAXIMUM_BODY_BYTES + 1,
                expectClose = true,
            )
            assertEquals(413, response.status)
            assertEquals("""{"error":"request too large"}""", response.bodyText)
            assertEquals(0, handler.requests.size)
        }
    }

    @Test
    fun exactlyOneMebibyteIsAccepted() = runBlocking<Unit> {
        val handler = BotMcpTestHandler { BotMcpResponse.Json(200, """{"ok":true}""".toByteArray()) }
        BotMcpListener(handler, token = token).use { listener ->
            val endpoint = listener.startOrThrow()
            val body = exactMaximumBody()
            assertEquals(BotMcpServing.MAXIMUM_BODY_BYTES, body.size)
            val response = botMcpRawRequest(
                endpoint.port,
                "/mcp",
                mapOf("Authorization" to "Bearer $token"),
                body,
            )
            assertEquals(200, response.status)
            assertEquals(1, handler.requests.size)
            assertEquals(BotMcpServing.MAXIMUM_BODY_BYTES, handler.requests.single().body.size)
        }
    }

    @Test
    fun aChunkedBodyOverTheReadHeadroomIs413() = runBlocking<Unit> {
        val handler = BotMcpTestHandler()
        BotMcpListener(handler, token = token).use { listener ->
            val endpoint = listener.startOrThrow()
            val oversized = ByteArray(BotMcpServing.MAXIMUM_BODY_BYTES + BotMcpServing.READ_HEADROOM + 1) { 'x'.code.toByte() }
            val response = botMcpRawRequest(
                endpoint.port,
                "/mcp",
                mapOf("Authorization" to "Bearer $token"),
                oversized,
                chunked = true,
            )
            assertEquals(413, response.status)
            assertEquals("""{"error":"request too large"}""", response.bodyText)
            assertEquals(0, handler.requests.size)
        }
    }

    @Test
    fun exactlyOneMebibyteIsAcceptedWhenChunked() = runBlocking<Unit> {
        val handler = BotMcpTestHandler { BotMcpResponse.Json(200, """{"ok":true}""".toByteArray()) }
        BotMcpListener(handler, token = token).use { listener ->
            val endpoint = listener.startOrThrow()
            val response = botMcpRawRequest(
                endpoint.port,
                "/mcp",
                mapOf("Authorization" to "Bearer $token"),
                exactMaximumBody(),
                chunked = true,
            )
            assertEquals(200, response.status)
        }
    }

    // ---------------------------------------------------------- JSON / envelope

    @Test
    fun invalidJsonIs400AndApplicationRefusalsStay200() = runBlocking<Unit> {
        val handler = BotMcpTestHandler { BotMcpResponse.Json(200, """{"ok":false,"allowed":false,"pending":false}""".toByteArray()) }
        BotMcpListener(handler, token = token).use { listener ->
            val endpoint = listener.startOrThrow()
            val invalid = botMcpRawRequest(
                endpoint.port,
                "/approval",
                mapOf("Authorization" to "Bearer $token"),
                "not json".toByteArray(),
            )
            assertEquals(400, invalid.status)
            assertEquals("""{"error":"invalid JSON"}""", invalid.bodyText)
            assertEquals(0, handler.requests.size)

            val refusal = botMcpRawRequest(
                endpoint.port,
                "/approval",
                mapOf("Authorization" to "Bearer $token"),
                """{"sessionId":"s"}""".toByteArray(),
            )
            assertEquals("an application refusal is HTTP 200", 200, refusal.status)
            assertEquals("""{"ok":false,"allowed":false,"pending":false}""", refusal.bodyText)
        }
    }

    @Test
    fun malformedBatchElementsAre400() = runBlocking<Unit> {
        val handler = BotMcpTestHandler()
        BotMcpListener(handler, token = token).use { listener ->
            val endpoint = listener.startOrThrow()
            for (body in listOf("[{},1]", """{"jsonrpc":"2.0","id":1}""", "42")) {
                val response = botMcpRawRequest(
                    endpoint.port,
                    "/mcp",
                    mapOf("Authorization" to "Bearer $token"),
                    body.toByteArray(),
                )
                assertEquals(body, 400, response.status)
                assertEquals(body, """{"error":"invalid JSON-RPC message"}""", response.bodyText)
            }
            assertEquals(0, handler.requests.size)
        }
    }

    @Test
    fun notificationOnlyBodiesAre202AndNeverReachTheHandler() = runBlocking<Unit> {
        val handler = BotMcpTestHandler { BotMcpResponse.Json(200, """{"ok":true}""".toByteArray()) }
        BotMcpListener(handler, token = token).use { listener ->
            val endpoint = listener.startOrThrow()
            val bodies = listOf(
                """{"jsonrpc":"2.0","method":"tools/list"}""",
                """[{"jsonrpc":"2.0","method":"tools/list"},{"jsonrpc":"2.0","method":"ping"}]""",
            )
            for (body in bodies) {
                val response = botMcpRawRequest(
                    endpoint.port,
                    "/mcp",
                    mapOf("Authorization" to "Bearer $token"),
                    body.toByteArray(),
                )
                assertEquals(body, 202, response.status)
                assertEquals(body, 0, response.body.size)
                assertEquals(body, "test-session", response.header("Mcp-Session-Id"))
            }
            assertEquals("a notification is never forwarded", 0, handler.requests.size)

            // `"id": null` is a request (the member is present), not a
            // notification. The handler owns the reply.
            val withNullId = botMcpRawRequest(
                endpoint.port,
                "/mcp",
                mapOf("Authorization" to "Bearer $token"),
                """{"jsonrpc":"2.0","id":null,"method":"ping"}""".toByteArray(),
            )
            assertEquals(200, withNullId.status)
            assertEquals(1, handler.requests.size)
        }
    }

    @Test
    fun aBatchWithARequestReachesTheHandlerOnce() = runBlocking<Unit> {
        val handler = BotMcpTestHandler {
            BotMcpResponse.Json(200, """[{"jsonrpc":"2.0","id":1,"result":{}}]""".toByteArray())
        }
        BotMcpListener(handler, token = token).use { listener ->
            val endpoint = listener.startOrThrow()
            val response = botMcpRawRequest(
                endpoint.port,
                "/mcp",
                mapOf("Authorization" to "Bearer $token"),
                """[{"jsonrpc":"2.0","method":"tools/list"},{"jsonrpc":"2.0","id":1,"method":"ping"}]""".toByteArray(),
            )
            assertEquals(200, response.status)
            assertEquals("""[{"jsonrpc":"2.0","id":1,"result":{}}]""", response.bodyText)
            assertEquals(1, handler.requests.size)
            assertTrue(handler.requests.single().bodyText().startsWith("["))
        }
    }

    // ------------------------------------------------------------------- SSE

    @Test
    fun aLongToolCallStreamsSseWithSessionAndOneMessageEvent() = runBlocking<Unit> {
        val delayed = DelayedHandler(
            path = "/mcp",
            result = """{"jsonrpc":"2.0","id":2,"result":{"ok":true}}""",
            delayMillis = 250,
        )
        BotMcpListener(delayed, token = token, timing = BotMcpSseTiming(streamAfterMillis = 50, keepAliveMillis = 100)).use { listener ->
            val endpoint = listener.startOrThrow()
            val response = botMcpRawRequest(
                endpoint.port,
                "/mcp",
                mapOf(
                    "Authorization" to "Bearer $token",
                    "Accept" to "application/json, text/event-stream",
                ),
                """{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"Live"}}""".toByteArray(),
            )
            assertEquals(200, response.status)
            assertEquals("text/event-stream", response.header("Content-Type"))
            assertNull("the SSE head has no Content-Length", response.header("Content-Length"))
            assertNull("the SSE head is not chunked", response.header("Transfer-Encoding"))
            assertEquals("close", response.header("Connection"))
            assertEquals("test-session", response.header("Mcp-Session-Id"))
            val text = response.bodyText
            assertTrue("at least one keepalive before the result:\n$text", text.contains(": keepalive\n\n"))
            val events = Regex("event: message\\ndata: (.*?)\\n\\n", RegexOption.DOT_MATCHES_ALL)
                .findAll(text).toList()
            assertEquals("exactly one message event", 1, events.size)
            assertEquals(
                """{"jsonrpc":"2.0","id":2,"result":{"ok":true}}""",
                events.single().groupValues[1],
            )
            assertTrue("the stream closes after its one event", text.trimEnd().endsWith("}"))
            assertFalse("a keepalive is never a data event", text.contains("event: keepalive"))
        }
    }

    @Test
    fun aLongToolCallWithoutAnExplicitSseAcceptStaysJson() = runBlocking<Unit> {
        val delayed = DelayedHandler(
            path = "/mcp",
            result = """{"jsonrpc":"2.0","id":3,"result":{}}""",
            delayMillis = 120,
        )
        BotMcpListener(delayed, token = token, timing = BotMcpSseTiming(streamAfterMillis = 20, keepAliveMillis = 50)).use { listener ->
            val endpoint = listener.startOrThrow()
            val response = botMcpRawRequest(
                endpoint.port,
                "/mcp",
                mapOf(
                    "Authorization" to "Bearer $token",
                    "Accept" to "*/*",
                ),
                """{"jsonrpc":"2.0","id":3,"method":"tools/call"}""".toByteArray(),
            )
            assertEquals(200, response.status)
            assertEquals("application/json", response.header("Content-Type"))
            assertEquals("""{"jsonrpc":"2.0","id":3,"result":{}}""", response.bodyText)
            assertNotNull(response.header("Content-Length"))
            assertEquals("test-session", response.header("Mcp-Session-Id"))
        }
    }

    @Test
    fun aLongApprovalStreamsWithoutAnMcpSessionHeader() = runBlocking<Unit> {
        val delayed = DelayedHandler(
            path = "/approval",
            result = """{"ok":true,"allowed":true,"pending":false,"approvalId":"a1","message":"allowed"}""",
            delayMillis = 250,
        )
        BotMcpListener(delayed, token = token, timing = BotMcpSseTiming(streamAfterMillis = 50, keepAliveMillis = 100)).use { listener ->
            val endpoint = listener.startOrThrow()
            val response = botMcpRawRequest(
                endpoint.port,
                "/approval",
                mapOf(
                    "Authorization" to "Bearer $token",
                    "Accept" to "application/json, text/event-stream",
                ),
                """{"sessionId":"s","callId":"c"}""".toByteArray(),
            )
            assertEquals(200, response.status)
            assertEquals("text/event-stream", response.header("Content-Type"))
            assertNull("approval never carries the MCP session header", response.header("Mcp-Session-Id"))
            assertNull(response.header("Content-Length"))
            assertNull(response.header("Transfer-Encoding"))
            val events = Regex("event: message\\ndata: (.*?)\\n\\n", RegexOption.DOT_MATCHES_ALL)
                .findAll(response.bodyText).toList()
            assertEquals(1, events.size)
            assertTrue(events.single().groupValues[1].contains("approvalId"))
        }
    }

    @Test
    fun aHandlerMayOwnAnExplicitStreamingAnswerThroughTheEmitter() = runBlocking<Unit> {
        val handler = BotMcpTestHandler {
            BotMcpResponse.Streaming {
                keepalive()
                message("""{"streamed":true}""")
            }
        }
        BotMcpListener(handler, token = token).use { listener ->
            val endpoint = listener.startOrThrow()
            val response = botMcpRawRequest(
                endpoint.port,
                "/approval",
                mapOf(
                    "Authorization" to "Bearer $token",
                    "Accept" to "text/event-stream",
                ),
                """{"sessionId":"s"}""".toByteArray(),
            )
            assertEquals(200, response.status)
            assertEquals("text/event-stream", response.header("Content-Type"))
            assertNull(response.header("Mcp-Session-Id"))
            assertEquals(": keepalive\n\nevent: message\ndata: {\"streamed\":true}\n\n", response.bodyText)
        }
    }

    // ---------------------------------------------------------------- native

    @Test
    fun nativeIsStillOneBufferedJsonAnswerWithNoSseForm() = runBlocking<Unit> {
        val handler = BotMcpTestHandler()
        val native = RecordingNativeMcp()
        BotMcpListener(handler, token = token, nativeMcp = native).use { listener ->
            val endpoint = listener.startOrThrow()
            val response = botMcpRawRequest(
                endpoint.port,
                "/mcp/native",
                mapOf(
                    "Authorization" to "Bearer $token",
                    "Accept" to "application/json, text/event-stream",
                ),
                """{"jsonrpc":"2.0","id":9,"method":"tools/call"}""".toByteArray(),
            )
            assertEquals(200, response.status)
            assertEquals("application/json", response.header("Content-Type"))
            assertEquals("""{"native":true}""", response.bodyText)
            assertNull("GAP-36: /mcp/native never carries an SSE head", response.header("Mcp-Session-Id"))
            assertEquals(1, native.calls.get())
            assertEquals("POST", native.lastMethod)
            assertEquals(0, handler.requests.size)
        }
    }

    // ----------------------------------------------------------------- helpers

    private fun exactMaximumBody(): ByteArray {
        val prefix = """{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"pad":""""
        val suffix = "\"}}"
        val padding = "a".repeat(BotMcpServing.MAXIMUM_BODY_BYTES - prefix.length - suffix.length)
        return (prefix + padding + suffix).toByteArray(Charsets.UTF_8)
    }

    private class DelayedHandler(
        private val path: String,
        private val result: String,
        private val delayMillis: Long,
    ) : BotMcpRequestHandler {
        override val mcpSessionId: String = "test-session"

        override suspend fun handle(request: BotMcpRequest): BotMcpResponse {
            if (request.path != path) {
                return BotMcpResponse.Json(200, """{"path":"${request.path}"}""".toByteArray())
            }
            val deferred = CompletableDeferred<ByteArray>()
            Thread {
                Thread.sleep(delayMillis)
                deferred.complete(result.toByteArray(Charsets.UTF_8))
            }.apply {
                isDaemon = true
                start()
            }
            return BotMcpResponse.Awaiting(deferred)
        }
    }

    private class RecordingNativeMcp : NativeMcpServing {
        val calls = java.util.concurrent.atomic.AtomicInteger()
        val bodies = CopyOnWriteArrayList<ByteArray>()

        @Volatile
        var lastMethod: String? = null

        override suspend fun handle(request: NativeMcpRequest): NativeMcpResponse {
            calls.incrementAndGet()
            lastMethod = request.method
            bodies.add(request.body)
            return NativeMcpResponse(200, """{"native":true}""".toByteArray())
        }
    }
}
