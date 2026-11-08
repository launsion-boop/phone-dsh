// phone-dsh — :net tests: the independent Search/Fetch grant.
// SPDX-License-Identifier: MIT
//
// The frozen cases (`spec/v1/golden/gateway/independent-search/cases.json`) judge
// the base normalization and the request scope; the Worker bridge test reads the
// same file. The rest pins what JSON cannot express: the real `/v1/http` route
// injects the independent key per request, fails before a socket without it,
// refuses redirects and never logs the exchange.
package com.phonedsh.gateway

import com.phonedsh.loopback.LoopbackHttpEgress
import com.phonedsh.loopback.LoopbackHttpRequest
import com.phonedsh.loopback.LoopbackHttpResponse
import java.nio.charset.StandardCharsets
import java.nio.file.Files
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class IndependentSearchWebToolsTest {
    private val searchKey: String = "sk-search-NOT-A-REAL-KEY-1111"
    private val base: String = "https://pdsh.tonoai.cn/v1/web"

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
            return GatewayTransportResponse(status, headers, body.toByteArray(StandardCharsets.UTF_8))
        }
    }

    private fun fixture(): JsonValue.Obj {
        val root = GatewayVectorRunner.findRepositoryRoot()
        val path = root.resolve("spec/v1/golden/gateway/independent-search/cases.json")
        assertTrue("frozen cases must exist at $path", Files.isRegularFile(path))
        return GatewayJson.parse(Files.readString(path, StandardCharsets.UTF_8)) as JsonValue.Obj
    }

    private fun cases(name: String): List<JsonValue.Obj> =
        requireNotNull(fixture().array(name)) { "$name is missing" }
            .map { it as? JsonValue.Obj ?: error("$name entries must be objects") }

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

    private fun egress(
        keys: ModelKeySource = RecordingKeySource(searchKey),
        transport: GatewayTransport = RecordingTransport(),
        fallback: LoopbackHttpEgress? = null,
        at: String = base,
    ) = IndependentSearchWebToolsEgress(base = at, keys = keys, transport = transport, fallback = fallback)

    @Test
    fun basesNormalizeExactlyAsTheFrozenCases() {
        val bases = cases("bases")
        assertTrue(bases.any { it.string("canonical") == null })
        assertTrue(bases.any { it.string("canonical") != null })
        for (case in bases) {
            val input = requireNotNull(case.string("input"))
            val expected = case.string("canonical")
            assertEquals("base ${input.quoted()}", expected, IndependentSearchWebTools.canonicalBase(input))
            if (expected != null) {
                assertEquals("canonical is a fixed point", expected, IndependentSearchWebTools.canonicalBase(expected))
            }
        }
    }

    @Test
    fun requestScopeMatchesTheFrozenCasesThroughTheRealRoute() {
        for (case in cases("requests")) {
            val caseBase = requireNotNull(case.string("base"))
            val method = requireNotNull(case.string("method"))
            val url = requireNotNull(case.string("url"))
            val allowed = requireNotNull(case.bool("allowed"))
            val transport = RecordingTransport()
            val response = egress(transport = transport, at = caseBase).handle(workerRequest(url, method))

            if (allowed) {
                assertEquals("$method $url must be admitted", 1, transport.requests.size)
                val sent = transport.requests.single()
                assertEquals("POST", sent.method)
                assertEquals(url, sent.url)
                assertEquals("Bearer $searchKey", sent.headers["authorization"])
                assertTrue(response.status in 200..299)
            } else {
                assertTrue("$method $url must not contact upstream", transport.requests.isEmpty())
                assertTrue("$method $url must be refused, was ${response.status}", response.status == 400 || response.status == 403)
            }
        }
    }

    @Test
    fun workerEnvironmentCarriesTheCanonicalBaseAndPlaceholderOnly() {
        val env = IndependentSearchWebTools.workerEnvironment(base)
        assertEquals(
            mapOf(
                "PDSH_WEB_SEARCH_PROVIDER" to "deepseek-search-api",
                "PDSH_WEB_FETCH_PROVIDER" to "deepseek-fetch-api",
                "DEEPSEEK_SEARCH_API_BASE_URL" to base,
                "DEEPSEEK_SEARCH_API_KEY" to requireNotNull(fixture().string("placeholder")),
            ),
            env,
        )
        for (case in cases("bases")) {
            val input = requireNotNull(case.string("input"))
            if (case.string("canonical") == input) continue
            assertTrue(
                "a non-canonical base ${input.quoted()} never reaches the Worker",
                runCatching { IndependentSearchWebTools.workerEnvironment(input) }.isFailure,
            )
        }
    }

    @Test
    fun operationsInjectTheIndependentKeyAndDropCallerCredentials() {
        val transport = RecordingTransport()
        val response = egress(transport = transport).handle(
            workerRequest(
                "$base/search",
                headers = linkedMapOf(
                    "authorization" to "Bearer forged",
                    "proxy-authorization" to "Bearer forged",
                    "x-pdsh-upstream-authorization" to "Bearer phone-host-injects-search-key",
                    "x-api-key" to "forged",
                    "api-key" to "forged",
                    "x-dsh-auth-token" to "forged",
                    "content-type" to "application/json",
                ),
            ),
        )

        assertEquals(200, response.status)
        val sent = transport.requests.single()
        assertEquals("Bearer $searchKey", sent.headers["authorization"])
        assertFalse(sent.headers.containsKey("proxy-authorization"))
        assertFalse(sent.headers.keys.any { it.startsWith("x-pdsh-") })
        assertTrue(listOf("x-api-key", "api-key", "x-dsh-auth-token").none(sent.headers::containsKey))
    }

    @Test
    fun everyRequestReadsTheIndependentKeyAgain() {
        val transport = RecordingTransport()
        val keys = RecordingKeySource(searchKey)
        val egress = egress(keys = keys, transport = transport)
        egress.handle(workerRequest("$base/search"))
        egress.handle(workerRequest("$base/fetch"))
        assertEquals(2, transport.requests.size)
        assertEquals(2, keys.reads)
    }

    @Test
    fun aMissingOrUnreadableKeyFailsBeforeTheTransport() {
        for (keys in listOf(RecordingKeySource(null), RecordingKeySource(null, failure = "gone $searchKey"))) {
            val transport = RecordingTransport()
            val response = egress(keys = keys, transport = transport).handle(workerRequest("$base/fetch"))
            assertEquals(502, response.status)
            assertEquals("credential_unavailable", response.headers["x-pdsh-proxy-error"])
            assertTrue("no socket is opened", transport.requests.isEmpty())
            assertFalse(response.bodyText().contains(searchKey))
        }
    }

    @Test
    fun theResponseNeverExposesTheKeyAndIsNeverLogged() {
        val transport = RecordingTransport(
            body = """{"content":"$searchKey"}""",
            headers = mapOf("content-type" to "application/json", "x-echo" to "Bearer $searchKey"),
        )
        val egress = egress(transport = transport)
        val response = egress.handle(workerRequest("$base/search"))
        assertEquals(200, response.status)
        assertFalse(response.bodyText().contains(searchKey))
        assertFalse(response.headers.values.joinToString(" ").contains(searchKey))
        assertEquals("no-store", response.headers["cache-control"])

        val outcome = egress.session.exchange(
            GatewayRequest(method = "POST", url = "$base/fetch", headers = emptyMap(), body = ByteArray(0)),
        )
        val log = requireNotNull(outcome.log)
        assertFalse(log.recorded)
        assertEquals(ResponseLogReasons.SENSITIVE_CREDENTIAL, log.reason)
    }

    @Test
    fun everyRedirectIsRefusedWithoutASecondContact() {
        val transport = RecordingTransport(
            status = 307,
            headers = mapOf("location" to "$base/fetch", "content-type" to "application/json"),
        )
        val response = egress(transport = transport).handle(workerRequest("$base/search"))
        assertEquals(307, response.status)
        assertEquals(1, transport.requests.size)
    }

    @Test
    fun theCredentialNeverGoesToTheOfficialToolsOrAnotherPort() {
        val provider = IndependentSearchCredentialProvider(base, RecordingKeySource(searchKey))
        for (scope in listOf(
            CredentialScope("api.deepseek.com", "/v1/tools/search", "https", null),
            CredentialScope("pdsh.tonoai.cn", "/v1/web/search", "https", 443),
            CredentialScope("pdsh.tonoai.cn", "/v1/web/search", "http", null),
            CredentialScope("pdsh.tonoai.cn", "/v1/web/messages", "https", null),
            CredentialScope("pdsh.tonoai.cn", "/v1/search", "https", null),
        )) {
            assertTrue("$scope must not get the key", runCatching { provider.resolve(scope) }.isFailure)
        }
        val credential = provider.resolve(CredentialScope("pdsh.tonoai.cn", "/v1/web/fetch", "https", null))
        assertEquals(searchKey, (credential as GatewayCredential.Bearer).value)
        val root = IndependentSearchCredentialProvider("https://search.example.com", RecordingKeySource(searchKey))
        assertTrue(runCatching { root.resolve(CredentialScope("search.example.com", "/search", "https", null)) }.isSuccess)
    }

    @Test
    fun otherRequestsUseTheDiagnosticFallbackOrAreRefused() {
        val fallbackCalls = ArrayList<LoopbackHttpRequest>()
        val fallback = LoopbackHttpEgress { request ->
            fallbackCalls += request
            LoopbackHttpResponse(status = 204)
        }
        val transport = RecordingTransport()
        assertEquals(204, egress(transport = transport, fallback = fallback).handle(workerRequest("https://model.example/v1/messages")).status)
        assertEquals(1, fallbackCalls.size)
        assertTrue(transport.requests.isEmpty())
        assertEquals(400, egress(transport = transport).handle(workerRequest("https://api.deepseek.com/v1/tools/search")).status)
    }

    @Test
    fun aNonCanonicalBaseCannotBuildTheRoute() {
        assertTrue(runCatching { egress(at = "$base/") }.isFailure)
        assertTrue(runCatching { egress(at = "http://pdsh.tonoai.cn/v1/web") }.isFailure)
    }

    private fun String.quoted(): String = "\"" + replace("\n", "\\n") + "\""
}
