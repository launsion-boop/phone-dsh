// phone-dsh — :gateway tests: the model key rides only its own origin and path.
// SPDX-License-Identifier: MIT
//
// Two kinds of claim live here:
//   * routing — the key is released for the configured model origin and its
//     protocol paths only, and never for a same-host MCP/Search path, another
//     port or another scheme (the Swift baseline's `ModelProviderCredentialProvider`);
//   * leak — the header that reaches the socket equals the stored key, and the
//     same value never appears in a failure envelope, a response header, a
//     response body, the response log or a provider `toString()`.
//
// The upstream here is a real `com.sun.net.httpserver.HttpServer` on an ephemeral
// loopback port: "the Authorization header was sent" is then an observation of
// the wire, not a check of the transport argument. No remote API is contacted and
// every key-shaped literal is obviously fake.

package com.phonedsh.gateway

import com.phonedsh.loopback.LoopbackHttpRequest
import com.sun.net.httpserver.HttpServer
import java.net.InetSocketAddress
import java.util.concurrent.CopyOnWriteArrayList
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

class ModelGatewayCredentialProviderTest {

    // ---- fixtures ---------------------------------------------------------

    /** Clearly fake, and long enough for the page's eight-character mask rule. */
    private val fakeKey: String = "sk-test-NOT-A-REAL-KEY-0000"

    private class RecordingKeySource(
        private val key: String?,
        private val failure: String? = null,
    ) : ModelKeySource {
        var reads: Int = 0
            private set

        override fun readKey(): String? {
            reads++
            failure?.let { throw CredentialUnavailableException(it) }
            return key
        }
    }

    private data class Recorded(
        val path: String,
        val authorization: String?,
        val headers: Map<String, String>,
    )

    private class FakeUpstream(
        private val status: Int = 200,
        private val body: String = """{"ok":true}""",
        private val location: (String) -> String? = { null },
    ) {
        val requests = CopyOnWriteArrayList<Recorded>()
        private val server = HttpServer.create(InetSocketAddress("127.0.0.1", 0), 0)

        init {
            server.createContext("/") { exchange ->
                val headers = exchange.requestHeaders.entries
                    .associate { (name, values) -> name.lowercase() to values.joinToString(", ") }
                requests += Recorded(
                    path = exchange.requestURI.rawPath,
                    authorization = exchange.requestHeaders.getFirst("Authorization"),
                    headers = headers,
                )
                val redirect = location(exchange.requestURI.rawPath)
                val payload = body.toByteArray(Charsets.UTF_8)
                if (redirect != null) {
                    exchange.responseHeaders.add("Location", redirect)
                    exchange.sendResponseHeaders(302, -1)
                } else {
                    exchange.responseHeaders.add("content-type", "application/json")
                    exchange.sendResponseHeaders(status, payload.size.toLong())
                    exchange.responseBody.use { it.write(payload) }
                }
                exchange.close()
            }
            server.start()
        }

        val origin: String get() = "http://127.0.0.1:${server.address.port}"

        fun close() = server.stop(0)
    }

    /** One `/v1/http` request as the Worker's route adapter sees it. */
    private fun workerRequest(
        target: String,
        method: String = "POST",
        headers: Map<String, String> = emptyMap(),
    ): LoopbackHttpRequest {
        val all = LinkedHashMap(headers)
        all["x-pdsh-target-url"] = target
        all["x-pdsh-target-method"] = method
        return LoopbackHttpRequest(
            method = "POST",
            targetUrl = target,
            targetMethod = method,
            headers = all,
            body = ByteArray(0),
        )
    }

    private fun scope(
        service: String = "127.0.0.1",
        audience: String = "/deepseek/v1/messages",
        scheme: String = "http",
        port: Int? = 8080,
    ): CredentialScope = CredentialScope(service, audience, scheme, port)

    private fun provider(
        baseUrl: String = "http://127.0.0.1:8080/deepseek",
        source: ModelKeySource = RecordingKeySource(fakeKey),
        anonymous: Set<String> = emptySet(),
    ): ModelGatewayCredentialProvider =
        ModelGatewayCredentialProvider(baseUrl = baseUrl, keys = source, anonymousHosts = anonymous)

    private fun session(
        upstream: FakeUpstream,
        source: ModelKeySource,
        anonymous: Set<String> = emptySet(),
    ): GatewaySession {
        val grant = GatewayHostRule.parse(upstream.origin) ?: error("the test grant must parse")
        return GatewaySession(
            transport = HttpUrlConnectionGatewayTransport(),
            credentialProvider = ModelGatewayCredentialProvider(
                baseUrl = "${upstream.origin}/deepseek",
                keys = source,
                anonymousHosts = anonymous,
            ),
            egress = AllowListEgressPolicy(listOf(grant)),
        )
    }

    // ---- endpoint parsing ------------------------------------------------

    @Test
    fun aModelBaseUrlIsParsedIntoAnExactOrigin() {
        val endpoint = ModelEndpoint.parse("HTTP://API.Example.COM:8443/deepseek/") ?: error("must parse")
        assertEquals("http", endpoint.scheme)
        assertEquals("api.example.com", endpoint.host)
        assertEquals(8443, endpoint.effectivePort)
        assertEquals("/deepseek", endpoint.normalizedBasePath)
        assertEquals("http://api.example.com:8443", endpoint.origin)
        assertNull("userinfo has no credential scope", ModelEndpoint.parse("https://user:pw@host/x"))
        assertNull("a query has no credential scope", ModelEndpoint.parse("https://host/x?key=1"))
        assertNull("a fragment has no credential scope", ModelEndpoint.parse("https://host/x#k"))
        assertNull("a non-http scheme is not a model endpoint", ModelEndpoint.parse("ftp://host/x"))
        assertNull("a relative value is not an endpoint", ModelEndpoint.parse("api.example.com/v1"))
        assertEquals(null, ModelEndpoint.defaultPort("ws"))
    }

    @Test
    fun theSchemeDefaultPortIsTheEffectivePort() {
        val endpoint = ModelEndpoint.parse("https://api.example.com/v1") ?: error("must parse")
        assertEquals(443, endpoint.effectivePort)
        assertTrue(
            "an omitted port is the scheme default",
            endpoint.admits(
                scope(service = "api.example.com", audience = "/v1/messages", scheme = "https", port = null),
            ),
        )
        assertFalse(
            "an explicit other port is not the model origin",
            endpoint.admits(
                scope(service = "api.example.com", audience = "/v1/messages", scheme = "https", port = 8443),
            ),
        )
    }

    // ---- protocol paths --------------------------------------------------

    @Test
    fun onlyModelProtocolPathsAreAdmitted() {
        val endpoint = ModelEndpoint.parse("https://api.example.com/deepseek") ?: error("must parse")

        fun admits(path: String, scheme: String = "https", port: Int? = null): Boolean = endpoint.admits(
            scope(service = "api.example.com", audience = path, scheme = scheme, port = port),
        )

        assertTrue(admits("/deepseek/v1/messages"))
        assertTrue(admits("/deepseek/v1/models"))
        assertTrue("a descendant of a known route is admitted", admits("/deepseek/v1/models/deepseek-chat"))
        assertTrue("the account listing route lives at the origin", admits("/models"))
        assertFalse("a sibling with a shared prefix is not a model route", admits("/deepseek/v1/models-mcp"))
        assertFalse("a same-host MCP route never sees the model key", admits("/deepseek/mcp"))
        assertFalse("a Search route never sees the model key", admits("/deepseek/v1/search"))
        assertFalse("another host is not this endpoint", endpoint.admits(
            scope(service = "other.example.com", audience = "/deepseek/v1/messages", scheme = "https", port = null),
        ))
        assertFalse("another scheme is not this endpoint", admits("/deepseek/v1/messages", scheme = "http"))
        assertFalse("another port is not this endpoint", admits("/deepseek/v1/messages", port = 8443))
    }

    // ---- provider routing ------------------------------------------------

    @Test
    fun theConfiguredModelScopeGetsTheKeyAsABearer() {
        val source = RecordingKeySource(fakeKey)
        val credential = provider(source = source).resolve(scope())
        assertEquals(GatewayCredential.Bearer(fakeKey), credential)
        assertEquals("one store read per resolution", 1, source.reads)
        assertEquals(
            "both the header value and the bare key are redaction sets, longest first",
            listOf("Bearer $fakeKey", fakeKey),
            credential.secretValues(),
        )
    }

    @Test
    fun aSameHostNonModelPathIsAnonymousInsteadOfKeyed() {
        val credential = provider().resolve(scope(audience = "/deepseek/v1/filesystem"))
        assertEquals(GatewayCredential.None, credential)
    }

    @Test
    fun anotherHostOnTheAnonymousListIsAnonymous() {
        val credential = provider(anonymous = setOf("http://search.example.com:8443")).resolve(
            scope(service = "search.example.com", audience = "/search", scheme = "https", port = 8443),
        )
        assertEquals(GatewayCredential.None, credential)
    }

    @Test
    fun anUnlistedHostIsRefusedInsteadOfBeingSentAnonymously() {
        try {
            provider().resolve(scope(service = "unlisted.example"))
            fail("a host outside the model origin and the anonymous set must be refused")
        } catch (refused: CredentialUnavailableException) {
            assertFalse("the provider text never carries a key", refused.message.orEmpty().contains(fakeKey))
        }
    }

    @Test
    fun anAbsentKeyFailsClosedInsteadOfSendingAnAnonymousRequest() {
        try {
            provider(source = RecordingKeySource(null)).resolve(scope())
            fail("an absent key must be a refusal, never an anonymous model request")
        } catch (refused: CredentialUnavailableException) {
            assertTrue(
                "the diagnostic says what to fix and nothing else",
                refused.message.orEmpty().contains("no model API key"),
            )
        }
    }

    @Test
    fun anEmptyKeyFailsClosedToo() {
        try {
            provider(source = RecordingKeySource("")).resolve(scope())
            fail("an empty stored value must not become an empty Authorization header")
        } catch (expected: CredentialUnavailableException) {
            assertFalse(expected.message.orEmpty().contains(fakeKey))
        }
    }

    @Test
    fun theProviderNeverPrintsTheKeyOrTheStore() {
        val source = RecordingKeySource(fakeKey)
        val text = provider(source = source).toString()
        assertFalse("a toString() must not be a key leak", text.contains(fakeKey))
        assertTrue(text.contains("127.0.0.1"))
        assertFalse("no path segments of the base URL are published", text.contains("/deepseek"))
    }

    // ---- on the wire -----------------------------------------------------

    @Test
    fun theStoredKeyArrivesAsTheAuthorizationHeaderOnTheWire() {
        val upstream = FakeUpstream()
        try {
            val outcome = session(upstream, RecordingKeySource(fakeKey)).exchange(
                GatewayRequest(
                    method = "POST",
                    url = "${upstream.origin}/deepseek/v1/messages",
                    headers = mapOf(
                        "content-type" to "application/json",
                        // A Worker-supplied credential is dropped before injection.
                        "authorization" to "Bearer worker-forged-value",
                        "x-pdsh-upstream-authorization" to "Bearer worker-forged-value",
                    ),
                    body = """{"model":"deepseek-flash"}""".toByteArray(),
                ),
            )

            assertEquals(200, outcome.responseStatus)
            assertEquals(1, outcome.workerCredentialsDropped)
            val recorded = upstream.requests.single()
            assertEquals("/deepseek/v1/messages", recorded.path)
            assertEquals("Bearer $fakeKey", recorded.authorization)
            assertEquals(
                "the header the transport was handed is exactly the header sent",
                outcome.lastRequestHeaders["authorization"],
                recorded.authorization,
            )
            assertNoKeyInSurface(outcome, injected = true)
        } finally {
            upstream.close()
        }
    }

    @Test
    fun aSameHostNonModelRequestGoesOutWithoutTheKey() {
        val upstream = FakeUpstream()
        try {
            val outcome = session(upstream, RecordingKeySource(fakeKey)).exchange(
                GatewayRequest(method = "POST", url = "${upstream.origin}/deepseek/v1/filesystem"),
            )
            assertEquals(200, outcome.responseStatus)
            assertNull(
                "the model key must never ride a non-model path on the same host",
                upstream.requests.single().authorization,
            )
            assertNoKeyInSurface(outcome, injected = false)
        } finally {
            upstream.close()
        }
    }

    @Test
    fun anUnconfiguredKeySendsNothingAndFailsClosed() {
        val upstream = FakeUpstream()
        try {
            // The Worker surface: a `/v1/http` request through the route adapter.
            val response = GatewayHttpEgress(session(upstream, RecordingKeySource(null))).handle(
                workerRequest("${upstream.origin}/deepseek/v1/messages"),
            )
            assertEquals(502, response.status)
            assertEquals("credential_unavailable", response.headers["x-pdsh-proxy-error"])
            assertEquals("credential_unavailable", response.headers["x-pdsh-deny-reason"])
            assertTrue("no socket was opened", upstream.requests.isEmpty())
            val body = response.bodyText()
            assertTrue("the structured cause is the diagnostic", body.contains("credential_unavailable"))
            assertFalse("the Worker never sees a key", body.contains(fakeKey))
        } finally {
            upstream.close()
        }
    }

    @Test
    fun aProviderFailureIsNotForwarded() {
        val upstream = FakeUpstream()
        try {
            // The store failure text is hostile on purpose: if any layer forwarded
            // provider text, the key would ride it to the Worker.
            val source = RecordingKeySource(null, failure = "keystore entry gone for $fakeKey")
            val response = GatewayHttpEgress(session(upstream, source)).handle(
                workerRequest("${upstream.origin}/deepseek/v1/messages"),
            )
            assertEquals(502, response.status)
            assertEquals("credential_unavailable", response.headers["x-pdsh-proxy-error"])
            assertTrue(upstream.requests.isEmpty())
            val body = response.bodyText()
            assertFalse("the Worker never sees a key", body.contains(fakeKey))
            assertFalse(
                "the provider's own text is not forwarded to the Worker or a log",
                body.contains("keystore entry"),
            )
        } finally {
            upstream.close()
        }
    }

    @Test
    fun aRedirectToAnotherModelPathIsRefusedAndContactedOnce() {
        val upstream = FakeUpstream(
            location = { path -> if (path == "/deepseek/v1/messages") "/deepseek/v1/models" else null },
        )
        try {
            val outcome = session(upstream, RecordingKeySource(fakeKey)).exchange(
                GatewayRequest(method = "GET", url = "${upstream.origin}/deepseek/v1/messages"),
            )
            assertEquals("the refused hop's own 3xx is handed back", 302, outcome.responseStatus)
            assertEquals(1, outcome.upstreamContacts)
            assertEquals(listOf("/deepseek/v1/messages"), upstream.requests.map { it.path })
            assertEquals("Bearer $fakeKey", upstream.requests.single().authorization)
            assertFalse(
                "a refused hop receives no credential and no contact",
                upstream.requests.any { it.path == "/deepseek/v1/models" },
            )
            assertNoKeyInSurface(outcome, injected = true)
        } finally {
            upstream.close()
        }
    }

    /**
     * No failure text, body, header or log entry may carry the stored key.
     *
     * [injected] is the one allowed location: the outbound header map the
     * transport was handed. Everything the Worker or a log can see is checked
     * separately, which is what `gw-fail-*` and §7 require.
     */
    private fun assertNoKeyInSurface(outcome: GatewayOutcome, injected: Boolean) {
        val surfaces = LinkedHashMap<String, String>()
        surfaces["failure.reason"] = outcome.failure?.reasonText().orEmpty()
        surfaces["failure.envelope"] = outcome.failure?.envelopeJson().orEmpty()
        surfaces["denyReason"] = outcome.denyReason.orEmpty()
        surfaces["responseBody"] = String(outcome.responseBody, Charsets.UTF_8)
        surfaces["responseHeaders"] = outcome.responseHeaders.entries.joinToString { "${it.key}=${it.value}" }
        surfaces["log"] = outcome.log?.fields()?.entries?.joinToString { "${it.key}=${it.value}" }.orEmpty()
        surfaces["outboundUrl"] = outcome.outboundUrl
        for ((name, text) in surfaces) {
            assertFalse("$name must not carry the model key", text.contains(fakeKey))
            assertFalse("$name must not carry the injected header", text.contains("Bearer $fakeKey"))
        }
        if (injected) {
            assertEquals(
                "the injected header is the only place the key is allowed to be",
                "Bearer $fakeKey",
                outcome.lastRequestHeaders["authorization"],
            )
        } else {
            assertNull(
                "no credential was applied, so no outbound header may carry it",
                outcome.lastRequestHeaders["authorization"],
            )
        }
    }
}
