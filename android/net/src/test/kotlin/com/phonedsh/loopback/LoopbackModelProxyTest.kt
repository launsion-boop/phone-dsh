// phone-dsh — :loopback tests: the model edge injects, replaces and never echoes.
// SPDX-License-Identifier: MIT
//
// Every upstream here is a real socket on 127.0.0.1. "The Authorization header
// reached the wire" is therefore an observation, not a check of the transport
// argument, and "the provider failure opened no socket" is a connection count.
//
// The six security claims of the M1 lane each have a test below: forwarded key,
// Worker credential replaced, no-key 502 with no contact, incremental SSE,
// no response echo, and (in `LoopbackModelProxyLoggingTest`) no logging call on
// the key path.

package com.phonedsh.loopback

import com.phonedsh.gateway.CredentialUnavailableException
import com.phonedsh.gateway.GatewayCredential
import com.phonedsh.gateway.GatewayCredentialProvider
import com.phonedsh.gateway.ModelEndpoint
import com.phonedsh.gateway.ModelGatewayCredentialProvider
import com.phonedsh.gateway.ModelKeySource
import com.phonedsh.gateway.GatewayRequestHeaders
import io.ktor.client.HttpClient
import io.ktor.client.engine.cio.CIO
import io.ktor.client.request.get
import io.ktor.client.request.header
import io.ktor.client.request.post
import io.ktor.client.request.setBody
import io.ktor.client.statement.bodyAsText
import io.ktor.http.ContentType
import io.ktor.http.HttpHeaders
import io.ktor.http.contentType
import java.io.BufferedInputStream
import java.io.ByteArrayOutputStream
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.net.InetAddress
import java.net.ServerSocket
import java.net.Socket
import java.net.SocketTimeoutException
import java.nio.file.Path
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import kotlin.concurrent.thread
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class LoopbackModelProxyTest {

    @get:Rule
    val temporary = TemporaryFolder()

    private val assets: Path by lazy {
        Fixtures.write(Path.of(temporary.newFolder("assets").absolutePath))
    }

    /** Clearly fake, and long enough for the settings page's mask rule. */
    private val fakeKey: String = "sk-test-NOT-A-REAL-KEY-MODEL-0000"

    private val requestBody: String = """{"model":"deepseek-flash","messages":[{"role":"user","content":"hi"}]}"""

    // ---- fixtures ---------------------------------------------------------

    private data class RecordedModelRequest(
        val method: String,
        val target: String,
        val headers: Map<String, String>,
        val body: String,
    ) {
        val path: String get() = target.substringBefore('?')
        val authorization: String? get() = headers["authorization"]
    }

    private class StaticKeySource(private val key: String?) : ModelKeySource {
        @Volatile
        var reads: Int = 0
            private set

        override fun readKey(): String? {
            reads++
            return key
        }
    }

    /** A store failure whose text would be a leak if any layer forwarded it. */
    private class FailingKeySource(private val key: String) : ModelKeySource {
        override fun readKey(): String? {
            throw CredentialUnavailableException("keystore entry gone for $key")
        }
    }

    /**
     * One real HTTP/1.1 upstream.
     *
     * Each accepted connection is parsed (request line, lowercased headers,
     * `Content-Length` body) and handed to [respond], which writes the answer on
     * the same socket. A streaming test keeps the socket open between chunks.
     */
    private inner class FakeModelUpstream(
        private val respond: (RecordedModelRequest, OutputStream) -> Unit,
    ) : AutoCloseable {
        val requests = CopyOnWriteArrayList<RecordedModelRequest>()
        val connections = AtomicInteger()
        private val closed = AtomicBoolean(false)
        private val server = ServerSocket(0, 16, InetAddress.getByName("127.0.0.1"))

        private val acceptor = thread(start = true, isDaemon = true, name = "fake-model-upstream") {
            while (!closed.get()) {
                val socket = try {
                    server.accept()
                } catch (_: IOException) {
                    break
                }
                connections.incrementAndGet()
                thread(start = true, isDaemon = true, name = "fake-model-upstream-worker") {
                    socket.use {
                        try {
                            val request = readRequest(it.getInputStream())
                            requests += request
                            respond(request, it.getOutputStream())
                        } catch (_: IOException) {
                            // The proxy aborted the stream; nothing to answer.
                        }
                    }
                }
            }
        }

        val origin: String get() = "http://127.0.0.1:${server.localPort}"

        override fun close() {
            closed.set(true)
            runCatching { server.close() }
        }
    }

    private fun writeSimpleResponse(
        out: OutputStream,
        status: Int,
        headers: Map<String, String>,
        body: String,
    ) {
        val payload = body.toByteArray(Charsets.UTF_8)
        val head = buildString {
            append("HTTP/1.1 ").append(status).append(" Status\r\n")
            for ((name, value) in headers) append(name).append(": ").append(value).append("\r\n")
            append("Content-Length: ").append(payload.size).append("\r\n")
            append("Connection: close\r\n\r\n")
        }
        out.write(head.toByteArray(Charsets.ISO_8859_1))
        out.write(payload)
        out.flush()
    }

    private fun writeChunk(out: OutputStream, text: String) {
        val bytes = text.toByteArray(Charsets.UTF_8)
        out.write("${bytes.size.toString(16)}\r\n".toByteArray(Charsets.ISO_8859_1))
        out.write(bytes)
        out.write("\r\n".toByteArray(Charsets.ISO_8859_1))
        out.flush()
    }

    private fun proxy(
        upstreamOrigin: String,
        baseUrl: String = upstreamOrigin,
        source: ModelKeySource = StaticKeySource(fakeKey),
    ): LoopbackModelProxy {
        val endpoint = ModelEndpoint.parse(baseUrl) ?: error("the test base URL must parse")
        return LoopbackModelProxy(
            endpoint = endpoint,
            credentialProvider = ModelGatewayCredentialProvider(endpoint, source),
        )
    }

    // ---- what reaches the wire -------------------------------------------

    @Test
    fun theHostInjectsTheStoredKeyIntoTheForwardedRequest() = runBlocking {
        val upstream = FakeModelUpstream { _, out ->
            writeSimpleResponse(out, 200, mapOf("Content-Type" to "application/json"), """{"ok":true}""")
        }
        try {
            LoopbackServer(modelProxy = proxy(upstream.origin)).use { server ->
                val loopback = server.start(assets)
                newClient().use { http ->
                    val response = http.post(loopback.urlFor("/v1/messages")) {
                        header(HttpHeaders.Authorization, "Bearer ${loopback.token}")
                        contentType(ContentType.Application.Json)
                        setBody(requestBody)
                    }
                    assertEquals(200, response.status.value)
                    assertEquals("""{"ok":true}""", response.bodyAsText())
                }
            }
            val recorded = upstream.requests.single()
            assertEquals("POST", recorded.method)
            assertEquals("/v1/messages", recorded.path)
            assertEquals("Bearer $fakeKey", recorded.authorization)
            assertEquals(requestBody, recorded.body)
        } finally {
            upstream.close()
        }
    }

    @Test
    fun everyModelProtocolRouteIsMounted() = runBlocking {
        val upstream = FakeModelUpstream { _, out ->
            writeSimpleResponse(out, 200, mapOf("Content-Type" to "application/json"), """{"ok":true}""")
        }
        try {
            val modelProxy = proxy(upstream.origin)
            LoopbackServer(modelProxy = modelProxy).use { server ->
                val loopback = server.start(assets)
                newClient().use { http ->
                    for (route in modelProxy.routes()) {
                        val response = http.get(loopback.urlFor(route.loopbackPath)) {
                            header(HttpHeaders.Authorization, "Bearer ${loopback.token}")
                        }
                        assertEquals("route ${route.loopbackPath} is mounted", 200, response.status.value)
                    }
                }
            }
            assertEquals(
                "the loopback route set maps onto the endpoint's own protocol paths",
                modelProxy.routes().map { it.upstreamPath },
                upstream.requests.map { it.path },
            )
            assertTrue(
                "every mounted route injects the key",
                upstream.requests.all { it.authorization == "Bearer $fakeKey" },
            )
        } finally {
            upstream.close()
        }
    }

    @Test
    fun theConfiguredBasePathIsPrefixedOnTheUpstreamSide() = runBlocking {
        val upstream = FakeModelUpstream { _, out ->
            writeSimpleResponse(out, 200, mapOf("Content-Type" to "application/json"), """{"data":[]}""")
        }
        try {
            val baseUrl = "${upstream.origin}/anthropic"
            LoopbackServer(modelProxy = proxy(upstream.origin, baseUrl)).use { server ->
                val loopback = server.start(assets)
                newClient().use { http ->
                    val response = http.get(loopback.urlFor("/v1/models/deepseek-chat")) {
                        header(HttpHeaders.Authorization, "Bearer ${loopback.token}")
                    }
                    assertEquals(200, response.status.value)
                }
            }
            val recorded = upstream.requests.single()
            assertEquals("/anthropic/v1/models/deepseek-chat", recorded.path)
            assertEquals("Bearer $fakeKey", recorded.authorization)
        } finally {
            upstream.close()
        }
    }

    @Test
    fun aWorkerCredentialIsReplacedByTheHostKey() = runBlocking {
        val upstream = FakeModelUpstream { _, out ->
            writeSimpleResponse(out, 200, mapOf("Content-Type" to "application/json"), """{"ok":true}""")
        }
        try {
            LoopbackServer(modelProxy = proxy(upstream.origin)).use { server ->
                val loopback = server.start(assets)
                newClient().use { http ->
                    val response = http.post(loopback.urlFor("/v1/messages")) {
                        // The launch cookie authenticates the loopback request, so the
                        // Authorization header can be the Worker's own value.
                        header(HttpHeaders.Cookie, "${LaunchCookie.NAME}=${loopback.token}")
                        header(HttpHeaders.Authorization, "Bearer ${GatewayRequestHeaders.HOST_MANAGED_PLACEHOLDER}")
                        // A forged non-placeholder value must be dropped by name too.
                        header("x-api-key", "Bearer worker-forged-value")
                        contentType(ContentType.Application.Json)
                        setBody(requestBody)
                    }
                    assertEquals(200, response.status.value)
                }
            }
            val recorded = upstream.requests.single()
            assertEquals("the host key is what the upstream sees", "Bearer $fakeKey", recorded.authorization)
            assertFalse(
                "the Worker's placeholder must not ride along",
                recorded.headers.values.any { it.contains(GatewayRequestHeaders.HOST_MANAGED_PLACEHOLDER) },
            )
            assertNull("a Worker-supplied x-api-key is dropped by name", recorded.headers["x-api-key"])
            assertFalse(
                "a forged x-api-key value does not ride along either",
                recorded.headers.values.any { it.contains("worker-forged-value") },
            )
        } finally {
            upstream.close()
        }
    }

    @Test
    fun aCredentialFailureIsA502BeforeAnyUpstreamContact() = runBlocking {
        val upstream = FakeModelUpstream { _, out ->
            writeSimpleResponse(out, 200, mapOf("Content-Type" to "application/json"), """{"ok":true}""")
        }
        try {
            LoopbackServer(
                modelProxy = proxy(upstream.origin, source = FailingKeySource(fakeKey)),
            ).use { server ->
                val loopback = server.start(assets)
                newClient().use { http ->
                    val response = http.post(loopback.urlFor("/v1/messages")) {
                        header(HttpHeaders.Authorization, "Bearer ${loopback.token}")
                        contentType(ContentType.Application.Json)
                        setBody(requestBody)
                    }
                    assertEquals(502, response.status.value)
                    assertEquals("credential_unavailable", response.headers["x-pdsh-proxy-error"])
                    val body = response.bodyAsText()
                    assertTrue("the stable cause is the diagnostic", body.contains("credential_unavailable"))
                    assertFalse("the Worker never sees the key", body.contains(fakeKey))
                    assertFalse("the provider text is not forwarded", body.contains("keystore"))
                }
            }
            Thread.sleep(100)
            assertEquals("a pre-flight denial opens no socket", 0, upstream.connections.get())
            assertTrue("the upstream answered nothing", upstream.requests.isEmpty())
        } finally {
            upstream.close()
        }
    }

    @Test
    fun anAnonymousCredentialAddsNoAuthorizationHeader() = runBlocking {
        val upstream = FakeModelUpstream { _, out ->
            writeSimpleResponse(out, 200, mapOf("Content-Type" to "application/json"), """{"data":[]}""")
        }
        try {
            val endpoint = ModelEndpoint.parse(upstream.origin) ?: error("the test origin must parse")
            val anonymous = GatewayCredentialProvider { GatewayCredential.None }
            LoopbackServer(modelProxy = LoopbackModelProxy(endpoint, anonymous)).use { server ->
                val loopback = server.start(assets)
                newClient().use { http ->
                    val response = http.get(loopback.urlFor("/v1/models")) {
                        header(HttpHeaders.Authorization, "Bearer ${loopback.token}")
                    }
                    assertEquals(200, response.status.value)
                }
            }
            assertNull(
                "None means no Authorization header at all, not an empty one",
                upstream.requests.single().authorization,
            )
        } finally {
            upstream.close()
        }
    }

    @Test
    fun aStalledUpstreamTimesOutInsteadOfHangingTheHandler() = runBlocking {
        val upstream = FakeModelUpstream { _, _ ->
            // Accept the request and never answer, the shape a hung provider has.
            Thread.sleep(5_000)
        }
        try {
            val endpoint = ModelEndpoint.parse(upstream.origin) ?: error("the test origin must parse")
            val proxy = LoopbackModelProxy(
                endpoint = endpoint,
                credentialProvider = ModelGatewayCredentialProvider(endpoint, StaticKeySource(fakeKey)),
                readTimeoutMillis = 250,
            )
            LoopbackServer(modelProxy = proxy).use { server ->
                val loopback = server.start(assets)
                newClient().use { http ->
                    val response = withTimeout(5_000) {
                        http.get(loopback.urlFor("/v1/models")) {
                            header(HttpHeaders.Authorization, "Bearer ${loopback.token}")
                        }
                    }
                    assertEquals("a read timeout is a bounded failure", 502, response.status.value)
                    assertEquals("upstream", response.headers["x-pdsh-proxy-error"])
                    assertFalse(response.bodyAsText().contains(fakeKey))
                }
            }
        } finally {
            upstream.close()
        }
    }

    // ---- streaming --------------------------------------------------------

    @Test
    fun theUpstreamSseBodyIsStreamedChunkByChunk() = runBlocking {
        val firstDelivered = CountDownLatch(1)
        val releaseRest = CountDownLatch(1)
        val releaseTimedOut = AtomicBoolean(false)
        val upstream = FakeModelUpstream { _, out ->
            out.write(
                (
                    "HTTP/1.1 200 OK\r\n" +
                        "Content-Type: text/event-stream\r\n" +
                        "Transfer-Encoding: chunked\r\n" +
                        "Connection: close\r\n\r\n"
                    ).toByteArray(Charsets.ISO_8859_1),
            )
            out.flush()
            writeChunk(out, "data: first\n\n")
            firstDelivered.countDown()
            if (!releaseRest.await(10, TimeUnit.SECONDS)) releaseTimedOut.set(true)
            writeChunk(out, "data: second\n\n")
            writeChunk(out, "data: third\n\n")
            out.write("0\r\n\r\n".toByteArray(Charsets.ISO_8859_1))
            out.flush()
        }
        try {
            LoopbackServer(modelProxy = proxy(upstream.origin)).use { server ->
                val loopback = server.start(assets)
                val socket = Socket()
                socket.soTimeout = 20_000
                socket.connect(java.net.InetSocketAddress("127.0.0.1", loopback.port), 5_000)
                try {
                    val request = (
                        "POST /v1/messages HTTP/1.1\r\n" +
                            "Host: 127.0.0.1:${loopback.port}\r\n" +
                            "Authorization: Bearer ${loopback.token}\r\n" +
                            "Content-Type: application/json\r\n" +
                            "Content-Length: ${requestBody.toByteArray().size}\r\n" +
                            "Connection: close\r\n\r\n" +
                            requestBody
                        )
                    socket.getOutputStream().apply {
                        write(request.toByteArray(Charsets.ISO_8859_1))
                        flush()
                    }
                    val input = socket.getInputStream()
                    val head = readHeaderBlock(input).toString(Charsets.ISO_8859_1)
                    assertTrue(head.startsWith("HTTP/1.1 200"))
                    assertTrue(
                        "SSE keeps its media type",
                        head.contains("content-type: text/event-stream", ignoreCase = true),
                    )
                    assertTrue("the first chunk arrives before the upstream finished", firstDelivered.await(5, TimeUnit.SECONDS))
                    val first = readChunkedBody(input, "the first SSE chunk")
                    assertEquals("data: first\n\n", first)
                    assertFalse(
                        "the proxy did not wait for the whole upstream body",
                        releaseTimedOut.get(),
                    )
                    releaseRest.countDown()
                    // The proxy may coalesce two upstream writes into one read; what
                    // matters is that no event waited for the end of the stream.
                    val rest = StringBuilder()
                    while (true) {
                        val chunk = readChunkedBody(input, "the rest of the SSE stream")
                        if (chunk.isEmpty()) break
                        rest.append(chunk)
                    }
                    assertTrue(rest.contains("data: second\n\n"))
                    assertTrue(rest.contains("data: third\n\n"))
                } finally {
                    runCatching { socket.close() }
                }
            }
        } finally {
            releaseRest.countDown()
            upstream.close()
        }
    }

    // ---- response side ----------------------------------------------------

    @Test
    fun theInjectedAuthorizationIsNeverEchoedBack() = runBlocking {
        val upstream = FakeModelUpstream { _, out ->
            writeSimpleResponse(
                out,
                200,
                mapOf(
                    "Content-Type" to "text/plain",
                    "X-Upstream-Echo" to "Bearer $fakeKey",
                    // A key is a valid HTTP token, so it can ride a header name too.
                    "X-Echo-$fakeKey" to "1",
                ),
                "the origin saw Bearer $fakeKey",
            )
        }
        try {
            LoopbackServer(modelProxy = proxy(upstream.origin)).use { server ->
                val loopback = server.start(assets)
                val socket = Socket()
                socket.soTimeout = 10_000
                socket.connect(java.net.InetSocketAddress("127.0.0.1", loopback.port), 5_000)
                try {
                    val request = (
                        "GET /models HTTP/1.1\r\n" +
                            "Host: 127.0.0.1:${loopback.port}\r\n" +
                            "Authorization: Bearer ${loopback.token}\r\n" +
                            "Connection: close\r\n\r\n"
                        )
                    socket.getOutputStream().apply {
                        write(request.toByteArray(Charsets.ISO_8859_1))
                        flush()
                    }
                    val input = socket.getInputStream()
                    val head = readHeaderBlock(input).toString(Charsets.ISO_8859_1)
                    assertTrue(head.startsWith("HTTP/1.1 200"))
                    assertFalse("no response header may carry the key", head.contains(fakeKey))
                    assertTrue(
                        "the echo header is redacted whole",
                        head.contains("x-upstream-echo: [redacted]", ignoreCase = true),
                    )
                    val body = readToEnd(input).toString(Charsets.UTF_8)
                    assertFalse("no response body byte may carry the key", body.contains(fakeKey))
                } finally {
                    runCatching { socket.close() }
                }
            }
        } finally {
            upstream.close()
        }
    }

    @Test
    fun anUpstreamRedirectIsNotFollowed() = runBlocking {
        val upstream = FakeModelUpstream { _, out ->
            writeSimpleResponse(
                out,
                302,
                mapOf("Location" to "https://elsewhere.invalid/steal"),
                "moved",
            )
        }
        try {
            LoopbackServer(modelProxy = proxy(upstream.origin)).use { server ->
                val loopback = server.start(assets)
                newClient().use { http ->
                    val response = nonFollowingClient().use { client ->
                        client.get(loopback.urlFor("/v1/models")) {
                            header(HttpHeaders.Authorization, "Bearer ${loopback.token}")
                        }
                    }
                    assertEquals("the refused hop's own 3xx is handed back", 302, response.status.value)
                    assertNull("Location is withheld so the Worker cannot follow it", response.headers["Location"])
                    val body = response.bodyAsText()
                    assertTrue(body.contains("upstream_redirect_refused"))
                    assertFalse(body.contains("elsewhere.invalid"))
                }
            }
            assertEquals("exactly one upstream contact", 1, upstream.requests.size)
            assertEquals("/v1/models", upstream.requests.single().path)
        } finally {
            upstream.close()
        }
    }

    @Test
    fun anUpstreamErrorBodyIsReplacedByAStableCode() = runBlocking {
        val hostileBody = """{"error":"provider said Bearer $fakeKey and /secret/path"}"""
        val upstream = FakeModelUpstream { _, out ->
            writeSimpleResponse(
                out,
                500,
                mapOf(
                    "Content-Type" to "application/json",
                    "X-Upstream-Diagnostic" to "Bearer $fakeKey",
                ),
                hostileBody,
            )
        }
        try {
            LoopbackServer(modelProxy = proxy(upstream.origin)).use { server ->
                val loopback = server.start(assets)
                newClient().use { http ->
                    val response = http.post(loopback.urlFor("/v1/messages")) {
                        header(HttpHeaders.Authorization, "Bearer ${loopback.token}")
                        contentType(ContentType.Application.Json)
                        setBody(requestBody)
                    }
                    assertEquals("the status stays the diagnostic", 500, response.status.value)
                    assertEquals("upstream", response.headers["x-pdsh-proxy-error"])
                    val body = response.bodyAsText()
                    assertTrue(body.contains("upstream_status"))
                    assertFalse("no upstream error byte survives", body.contains("provider said"))
                    assertFalse(body.contains(fakeKey))
                    assertNull("no upstream diagnostic header survives", response.headers["X-Upstream-Diagnostic"])
                }
            }
        } finally {
            upstream.close()
        }
    }

    @Test
    fun aPathOutsideTheModelPrefixesIsNotForwarded() = runBlocking {
        val upstream = FakeModelUpstream { _, out ->
            writeSimpleResponse(out, 200, mapOf("Content-Type" to "application/json"), """{"ok":true}""")
        }
        try {
            LoopbackServer(modelProxy = proxy(upstream.origin)).use { server ->
                val loopback = server.start(assets)
                val socket = Socket()
                socket.soTimeout = 10_000
                socket.connect(java.net.InetSocketAddress("127.0.0.1", loopback.port), 5_000)
                try {
                    val request = (
                        "GET /v1/models/..%2F..%2Fsecret HTTP/1.1\r\n" +
                            "Host: 127.0.0.1:${loopback.port}\r\n" +
                            "Authorization: Bearer ${loopback.token}\r\n" +
                            "Connection: close\r\n\r\n"
                        )
                    socket.getOutputStream().apply {
                        write(request.toByteArray(Charsets.ISO_8859_1))
                        flush()
                    }
                    val head = readHeaderBlock(socket.getInputStream()).toString(Charsets.ISO_8859_1)
                    assertTrue("a traversal path is rejected", head.startsWith("HTTP/1.1 400"))
                } finally {
                    runCatching { socket.close() }
                }
            }
            Thread.sleep(100)
            assertEquals("the escaped path never reaches the upstream", 0, upstream.connections.get())
        } finally {
            upstream.close()
        }
    }

    /** A client that hands a 3xx back instead of following it. */
    private fun nonFollowingClient(): HttpClient = HttpClient(CIO) {
        followRedirects = false
    }

    // ---- raw HTTP helpers -------------------------------------------------

    private fun readRequest(input: InputStream): RecordedModelRequest {
        val buffered = BufferedInputStream(input)
        val requestLine = readLine(buffered) ?: throw IOException("no request line")
        val parts = requestLine.split(' ')
        val headers = LinkedHashMap<String, String>()
        while (true) {
            val line = readLine(buffered) ?: break
            if (line.isEmpty()) break
            val colon = line.indexOf(':')
            if (colon > 0) headers[line.substring(0, colon).trim().lowercase()] = line.substring(colon + 1).trim()
        }
        val length = headers["content-length"]?.toIntOrNull() ?: 0
        val body = if (length > 0) {
            val bytes = ByteArray(length)
            var read = 0
            while (read < length) {
                val count = buffered.read(bytes, read, length - read)
                if (count < 0) break
                read += count
            }
            String(bytes, 0, read, Charsets.UTF_8)
        } else {
            ""
        }
        return RecordedModelRequest(
            method = parts.getOrElse(0) { "" },
            target = parts.getOrElse(1) { "" },
            headers = headers,
            body = body,
        )
    }

    private fun readLine(input: InputStream): String? {
        val out = ByteArrayOutputStream()
        while (true) {
            val byte = input.read()
            if (byte < 0) return if (out.size() == 0) null else out.toString("ISO-8859-1")
            if (byte == '\n'.code) break
            out.write(byte)
        }
        return out.toByteArray().toString(Charsets.ISO_8859_1).removeSuffix("\r")
    }

    private fun readHeaderBlock(input: InputStream): ByteArray {
        val out = ByteArrayOutputStream()
        while (true) {
            val byte = try {
                input.read()
            } catch (_: SocketTimeoutException) {
                break
            }
            if (byte < 0) break
            out.write(byte)
            if (out.size() >= 4) {
                val bytes = out.toByteArray()
                if (bytes[bytes.size - 4] == 13.toByte() && bytes[bytes.size - 3] == 10.toByte() &&
                    bytes[bytes.size - 2] == 13.toByte() && bytes[bytes.size - 1] == 10.toByte()
                ) {
                    return bytes
                }
            }
        }
        return out.toByteArray()
    }

    private fun readChunkedBody(input: InputStream, what: String): String {
        val sizeLine = readLine(input) ?: throw AssertionError("no chunk size for $what")
        val size = sizeLine.substringBefore(';').trim().toIntOrNull(16)
            ?: throw AssertionError("bad chunk size '$sizeLine' for $what")
        if (size == 0) {
            readLine(input)
            return ""
        }
        val body = readFully(input, size)
        readLine(input)
        return body.toString(Charsets.UTF_8)
    }

    private fun readToEnd(input: InputStream): ByteArray {
        val out = ByteArrayOutputStream()
        val buffer = ByteArray(4096)
        while (true) {
            val read = try {
                input.read(buffer)
            } catch (_: SocketTimeoutException) {
                break
            } catch (_: IOException) {
                break
            }
            if (read < 0) break
            out.write(buffer, 0, read)
        }
        return out.toByteArray()
    }
}
