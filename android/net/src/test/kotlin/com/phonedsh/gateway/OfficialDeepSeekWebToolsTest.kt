// phone-dsh — :net tests: the official DeepSeek Search/Fetch grant.
// SPDX-License-Identifier: MIT
//
// The frozen cases (`spec/v1/golden/gateway/official-deepseek-web/cases.json`)
// are the judge for the model-base and request-scope rules. Everything else here
// pins the parts the JSON fixture cannot express: the real `/v1/http` route
// injects the selected model key, fails before a socket when the key is gone,
// refuses every redirect, and keeps the response log empty.
package com.phonedsh.gateway

import com.phonedsh.loopback.LoopbackHttpRequest
import java.nio.charset.StandardCharsets
import java.nio.file.Files
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class OfficialDeepSeekWebToolsTest {
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

    private class RecordingTransport(
        private val status: Int = 200,
        private val body: String = """{"results":[]}""",
        private val headers: Map<String, String> = mapOf("content-type" to "application/json"),
    ) : GatewayTransport {
        val requests: MutableList<GatewayTransportRequest> = ArrayList()

        override fun execute(request: GatewayTransportRequest): GatewayTransportResponse {
            requests += request
            return GatewayTransportResponse(
                status = status,
                headers = headers,
                body = body.toByteArray(StandardCharsets.UTF_8),
            )
        }
    }

    private fun fixture(): JsonValue.Obj {
        val root = GatewayVectorRunner.findRepositoryRoot()
        val path = root.resolve("spec/v1/golden/gateway/official-deepseek-web/cases.json")
        assertTrue("frozen cases must exist at $path", Files.isRegularFile(path))
        return GatewayJson.parse(Files.readString(path, StandardCharsets.UTF_8)) as JsonValue.Obj
    }

    private fun cases(name: String): List<JsonValue.Obj> =
        requireNotNull(fixture().array(name)) { "$name is missing" }
            .map { it as? JsonValue.Obj ?: error("$name entries must be objects") }

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
            body = "{}".toByteArray(StandardCharsets.UTF_8),
        )
    }

    @Test
    fun modelBasesMatchTheFrozenCases() {
        for (case in cases("modelBases")) {
            val url = requireNotNull(case.string("url"))
            val supported = requireNotNull(case.bool("supported"))
            assertEquals(
                "model base $url must be ${if (supported) "supported" else "refused"}",
                supported,
                OfficialDeepSeekWebTools.isOfficialModelBase(url),
            )
        }
    }

    @Test
    fun requestScopeMatchesTheFrozenCases() {
        for (case in cases("requests")) {
            val method = requireNotNull(case.string("method"))
            val url = requireNotNull(case.string("url"))
            val allowed = requireNotNull(case.bool("allowed"))
            val transport = RecordingTransport()
            val egress = OfficialDeepSeekWebToolsEgress(
                keys = RecordingKeySource(fakeKey),
                transport = transport,
            )

            val response = egress.handle(workerRequest(url, method = method))

            if (allowed) {
                assertEquals("$method $url must be admitted", 1, transport.requests.size)
                val sent = transport.requests.single()
                assertEquals("POST", sent.method)
                assertEquals(url, sent.url)
                assertEquals("Bearer $fakeKey", sent.headers["authorization"])
                assertTrue("a successful exchange keeps its status", response.status in 200..299)
            } else {
                assertTrue("$method $url must not contact upstream", transport.requests.isEmpty())
                assertTrue(
                    "$method $url must be refused, was ${response.status}",
                    response.status == 400 || response.status == 403,
                )
            }
        }
    }

    @Test
    fun canonicalPostInjectsTheSelectedModelKeyAndDropsCallerCredentials() {
        val transport = RecordingTransport()
        val egress = OfficialDeepSeekWebToolsEgress(
            keys = RecordingKeySource(fakeKey),
            transport = transport,
        )

        val response = egress.handle(
            workerRequest(
                OfficialDeepSeekWebTools.SEARCH_URL,
                headers = linkedMapOf(
                    "authorization" to "Bearer forged-caller-value",
                    "proxy-authorization" to "Bearer forged-caller-value",
                    "x-pdsh-upstream-authorization" to "Bearer forged-caller-value",
                    "x-api-key" to "forged-caller-value",
                    "api-key" to "forged-caller-value",
                    "x-dsh-auth-token" to "forged-caller-value",
                    "content-type" to "application/json",
                ),
            ),
        )

        assertEquals(200, response.status)
        val sent = transport.requests.single()
        assertEquals("the host credential is applied last", "Bearer $fakeKey", sent.headers["authorization"])
        assertFalse("a caller proxy credential never survives", sent.headers.containsKey("proxy-authorization"))
        assertFalse("an internal header never survives", sent.headers.keys.any { it.startsWith("x-pdsh-") })
        assertTrue(listOf("x-api-key", "api-key", "x-dsh-auth-token").none(sent.headers::containsKey))
        assertEquals("POST", sent.method)
        assertEquals(OfficialDeepSeekWebTools.SEARCH_URL, sent.url)
    }

    @Test
    fun everyRequestReadsTheSelectedModelKeyAgain() {
        val transport = RecordingTransport()
        val keys = RecordingKeySource(fakeKey)
        val egress = OfficialDeepSeekWebToolsEgress(keys = keys, transport = transport)

        egress.handle(workerRequest(OfficialDeepSeekWebTools.SEARCH_URL))
        egress.handle(workerRequest(OfficialDeepSeekWebTools.FETCH_URL))

        assertEquals(2, transport.requests.size)
        assertEquals("each request resolves the key again", 2, keys.reads)
        assertEquals("Bearer $fakeKey", transport.requests[0].headers["authorization"])
        assertEquals("Bearer $fakeKey", transport.requests[1].headers["authorization"])
    }

    @Test
    fun theResponseBodyAndHeadersNeverExposeTheKey() {
        val body = """{"content":"$fakeKey","echo":"Bearer $fakeKey"}"""
        val transport = RecordingTransport(
            body = body,
            headers = mapOf(
                "content-type" to "application/json",
                "x-echo" to "Bearer $fakeKey",
            ),
        )
        val egress = OfficialDeepSeekWebToolsEgress(
            keys = RecordingKeySource(fakeKey),
            transport = transport,
        )

        val response = egress.handle(workerRequest(OfficialDeepSeekWebTools.FETCH_URL))

        assertEquals(200, response.status)
        val text = response.bodyText()
        assertFalse("the response body must not carry the key", text.contains(fakeKey))
        assertTrue("the injected value is replaced", text.contains("[redacted]"))
        assertFalse(
            "a response header must not carry the key",
            response.headers.values.joinToString(" ").contains(fakeKey),
        )
        assertEquals("no-store", response.headers["cache-control"])
    }

    @Test
    fun aNon2xxFetchBodyNamesTheWebToolAndKeepsTheUpstreamBodyOut() {
        val upstreamBody = """{"error":"upstream-secret-$fakeKey"}"""
        val transport = RecordingTransport(
            status = 404,
            body = upstreamBody,
            headers = mapOf("content-type" to "text/plain"),
        )
        val egress = OfficialDeepSeekWebToolsEgress(
            keys = RecordingKeySource(fakeKey),
            transport = transport,
        )

        val response = egress.handle(workerRequest(OfficialDeepSeekWebTools.FETCH_URL))

        assertEquals(404, response.status)
        assertEquals("application/json; charset=utf-8", response.headers["content-type"])
        val text = response.bodyText()
        assertTrue("the diagnostic names the web tool", text.contains("web tool"))
        assertTrue("the real status survives", text.contains("HTTP 404"))
        assertTrue("it says the body was withheld", text.contains("withheld by the host"))
        assertFalse("it is not an MCP diagnostic", text.contains("MCP"))
        assertFalse("the upstream body never reaches the Worker", text.contains("upstream-secret"))
        assertFalse("the injected key never reaches the Worker", text.contains(fakeKey))
    }

    @Test
    fun theResponseLogNeverRecordsAnOfficialToolExchange() {
        val transport = RecordingTransport(body = """{"content":"$fakeKey"}""")
        val egress = OfficialDeepSeekWebToolsEgress(
            keys = RecordingKeySource(fakeKey),
            transport = transport,
        )

        val outcome = egress.session.exchange(
            GatewayRequest(
                method = "POST",
                url = OfficialDeepSeekWebTools.SEARCH_URL,
                headers = mapOf("authorization" to "Bearer $fakeKey"),
                body = "{}".toByteArray(StandardCharsets.UTF_8),
            ),
        )

        assertEquals(GatewayDispatch.ALLOW, outcome.dispatch)
        val log = requireNotNull(outcome.log)
        assertFalse("the sensitive exchange is never logged", log.recorded)
        assertEquals(ResponseLogReasons.SENSITIVE_CREDENTIAL, log.reason)
        assertFalse(
            "no observable log field carries the key",
            log.fields().values.joinToString(" ") { it.toString() }.contains(fakeKey),
        )
        assertFalse(String(outcome.responseBody, StandardCharsets.UTF_8).contains(fakeKey))
    }

    @Test
    fun everyRedirectIsRefusedWithoutASecondContact() {
        val transport = object : GatewayTransport {
            val requests: MutableList<GatewayTransportRequest> = ArrayList()

            override fun execute(request: GatewayTransportRequest): GatewayTransportResponse {
                requests += request
                return GatewayTransportResponse(
                    status = 307,
                    headers = mapOf(
                        "location" to OfficialDeepSeekWebTools.FETCH_URL,
                        "content-type" to "application/json",
                    ),
                    body = """{"redirect":"$fakeKey"}""".toByteArray(StandardCharsets.UTF_8),
                )
            }
        }
        val egress = OfficialDeepSeekWebToolsEgress(
            keys = RecordingKeySource(fakeKey),
            transport = transport,
        )

        val response = egress.handle(workerRequest(OfficialDeepSeekWebTools.SEARCH_URL))

        assertEquals("the refused hop's own 3xx is handed back", 307, response.status)
        assertEquals("the redirect target is never contacted", 1, transport.requests.size)
        assertEquals(OfficialDeepSeekWebTools.SEARCH_URL, transport.requests.single().url)
        assertFalse(response.bodyText().contains(fakeKey))
    }

    @Test
    fun aMissingKeyFailsBeforeTheTransport() {
        val transport = RecordingTransport()
        val egress = OfficialDeepSeekWebToolsEgress(
            keys = RecordingKeySource(null),
            transport = transport,
        )

        val response = egress.handle(workerRequest(OfficialDeepSeekWebTools.SEARCH_URL))

        assertEquals(502, response.status)
        assertEquals("credential_unavailable", response.headers["x-pdsh-proxy-error"])
        assertTrue("no socket is opened", transport.requests.isEmpty())
        assertTrue(response.bodyText().contains("credential_unavailable"))
    }

    @Test
    fun anUnreadableKeyFailsClosedAndItsTextIsNotForwarded() {
        val transport = RecordingTransport()
        val egress = OfficialDeepSeekWebToolsEgress(
            keys = RecordingKeySource(null, failure = "keystore entry gone for $fakeKey"),
            transport = transport,
        )

        val response = egress.handle(workerRequest(OfficialDeepSeekWebTools.FETCH_URL))

        assertEquals(502, response.status)
        assertEquals("credential_unavailable", response.headers["x-pdsh-proxy-error"])
        assertTrue("no socket is opened", transport.requests.isEmpty())
        assertFalse("the provider's text is not forwarded", response.bodyText().contains("keystore entry"))
        assertFalse("the key is not forwarded", response.bodyText().contains(fakeKey))
    }

    @Test
    fun theCredentialProviderRefusesEveryScopeOutsideTheTwoCanonicalPaths() {
        val provider = OfficialDeepSeekToolCredentialProvider(RecordingKeySource(fakeKey))
        for (scope in listOf(
            CredentialScope(OfficialDeepSeekWebTools.MODEL_HOST, "/v1/tools/search", "https", 443),
            CredentialScope(OfficialDeepSeekWebTools.MODEL_HOST, "/v1/tools/unknown", "https", null),
            CredentialScope(OfficialDeepSeekWebTools.MODEL_HOST, "/v1/tools/search/extra", "https", null),
            CredentialScope("api.deepseek.com.example.invalid", "/v1/tools/search", "https", null),
            CredentialScope(OfficialDeepSeekWebTools.MODEL_HOST, "/v1/tools/search", "http", null),
        )) {
            val accepted = runCatching { provider.resolve(scope) }.isSuccess
            assertFalse("$scope must not receive the model key", accepted)
        }
        val credential = provider.resolve(
            CredentialScope(OfficialDeepSeekWebTools.MODEL_HOST, "/v1/tools/search", "https", null),
        )
        assertEquals(fakeKey, (credential as GatewayCredential.Bearer).value)
    }

    @Test
    fun theExistingDiagnosticFallbackStillHandlesNonToolRequests() {
        val officialTransport = RecordingTransport()
        val fallbackCalls = ArrayList<LoopbackHttpRequest>()
        val fallback = com.phonedsh.loopback.LoopbackHttpEgress { request ->
            fallbackCalls += request
            com.phonedsh.loopback.LoopbackHttpResponse(status = 204)
        }
        val egress = OfficialDeepSeekWebToolsEgress(
            keys = RecordingKeySource(fakeKey),
            transport = officialTransport,
            fallback = fallback,
        )

        val response = egress.handle(workerRequest("https://diagnostic.example.test/health"))

        assertEquals(204, response.status)
        assertEquals(1, fallbackCalls.size)
        assertTrue("the official credential scope is never consulted", officialTransport.requests.isEmpty())
    }

    @Test
    fun theCanonicalRequestPredicateIsTheFrozenScopeRule() {
        assertTrue(OfficialDeepSeekWebTools.isCanonicalRequest("POST", OfficialDeepSeekWebTools.SEARCH_URL))
        assertTrue(OfficialDeepSeekWebTools.isCanonicalRequest("post", OfficialDeepSeekWebTools.FETCH_URL))
        for ((method, url) in listOf(
            "GET" to OfficialDeepSeekWebTools.SEARCH_URL,
            "POST" to "${OfficialDeepSeekWebTools.SEARCH_URL}?x=1",
            "POST" to "${OfficialDeepSeekWebTools.SEARCH_URL}#x",
            "POST" to "https://api.deepseek.com/v1/tools/%73earch",
            "POST" to "https://api.deepseek.com:443/v1/tools/search",
            "POST" to "https://api.deepseek.com/v1/tools/search/",
            "POST" to "https://api.deepseek.com.example.invalid/v1/tools/search",
        )) {
            assertFalse("$method $url must be outside the grant", OfficialDeepSeekWebTools.isCanonicalRequest(method, url))
        }
    }
}
