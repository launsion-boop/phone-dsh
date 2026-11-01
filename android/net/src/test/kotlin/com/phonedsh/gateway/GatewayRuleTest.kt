// phone-dsh — :net tests: gateway rules the vectors only partly pin.
// SPDX-License-Identifier: MIT
//
// The 30 golden vectors are the acceptance bar, but a few normative sentences
// of spec/v1/gateway-security.md are not reachable through a vector:
// `invalid_request` for a non-http scheme, the empty allow-list, the LRU
// response log, the 4 MiB buffered bound and the non-UTF-8 fallback. They are
// pinned here so "not vector-covered" cannot become "not implemented"; the
// hostless invalid_request, the transport-failure surface, the positive log
// and empty-body suppression are additionally pinned by gw-fail-003,
// gw-fail-004, gw-log-001 and gw-resp-006.

package com.phonedsh.gateway

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.nio.charset.StandardCharsets

class GatewayRuleTest {

    @Test
    fun aNonHttpUrlIsAnInvalidRequestBeforeEgressOrCredential() {
        val transport = ScriptedTransport()
        val provider = RecordingCredentialProvider { GatewayCredential.None }
        val session = session(transport = transport, provider = provider, rules = listOf("*"))

        val outcome = session.exchange(GatewayRequest("GET", "ftp://files.example.invalid/x"))

        assertEquals(GatewayDispatch.DENY, outcome.dispatch)
        assertEquals("invalid_request", outcome.denyReason)
        assertEquals(GatewayFailureCode.INVALID_REQUEST, outcome.failure?.code)
        assertEquals(400, outcome.failure?.code?.proxyStatus)
        assertEquals("bad_request", outcome.failure?.code?.proxyError)
        assertEquals(0, outcome.upstreamContacts)
        assertTrue(transport.requests.isEmpty())
        assertTrue(provider.scopes.isEmpty())
        assertEquals("", outcome.outboundUrl)
    }

    @Test
    fun theCredentialIsResolvedOnceForTheLowerCaseHostAndNormalizedPath() {
        val transport = ScriptedTransport()
        val provider = RecordingCredentialProvider { GatewayCredential.Bearer("scope-token") }
        val session = session(
            transport = transport,
            provider = provider,
            rules = listOf("https://api.example.invalid:8443"),
        )

        val outcome = session.exchange(
            GatewayRequest(
                method = "GET",
                url = "https://API.Example.Invalid:8443/v1//models/?q=1#frag",
            ),
        )

        assertEquals(GatewayDispatch.ALLOW, outcome.dispatch)
        assertEquals(1, provider.scopes.size)
        assertEquals(
            CredentialScope("api.example.invalid", "/v1/models", "https", 8443),
            provider.scopes[0],
        )
        assertEquals(
            mapOf("authorization" to "Bearer scope-token"),
            outcome.lastRequestHeaders,
        )
        assertEquals("https://API.Example.Invalid:8443/v1//models/?q=1#frag", outcome.outboundUrl)
    }

    @Test
    fun aPlaceholderValueIsDroppedWithoutCountingTheNameAsStripped() {
        val sanitized = DenylistRequestHeaderSanitizer().sanitize(
            mapOf(
                "x-mcp-token" to GatewayRequestHeaders.HOST_MANAGED_PLACEHOLDER,
                "accept" to "application/json",
            ),
        )

        assertFalse(sanitized.headers.containsKey("x-mcp-token"))
        assertTrue(sanitized.placeholderSeen)
        assertEquals(emptyList<String>(), sanitized.stripped)
        assertEquals(mapOf("accept" to "application/json"), sanitized.headers)

        val outbound = LinkedHashMap(sanitized.headers)
        GatewayCredential.Headers(mapOf("x-mcp-token" to "real-value")).applyTo(outbound)
        assertEquals("real-value", outbound["x-mcp-token"])
    }

    @Test
    fun theCallerCredentialDropIsCountedAndListed() {
        val sanitized = DenylistRequestHeaderSanitizer().sanitize(
            mapOf(
                "Authorization" to "Bearer sk-SENTINEL-DO-NOT-USE",
                "x-pdsh-upstream-authorization" to "Bearer sk-SENTINEL-DO-NOT-USE",
                "x-api-key" to "caller-value",
            ),
        )

        assertEquals(1, sanitized.workerCredentialsDropped)
        assertEquals(
            listOf("authorization", "x-pdsh-upstream-authorization"),
            sanitized.stripped,
        )
        assertEquals(mapOf("x-api-key" to "caller-value"), sanitized.headers)
    }

    @Test
    fun aResponseHeaderEchoBecomesRedactedAndCacheControlIsNoStore() {
        // The whole value is replaced, not substring-rewritten: gw-resp-004
        // pins `[redacted]` for a `server saw Bearer <token>` echo. Swift now
        // applies the same whole-value rule (ModelGateway.redactingSecrets).
        val filtered = DenylistResponseHeaderSanitizer().sanitize(
            mapOf(
                "content-type" to "text/plain",
                "set-cookie" to "sid=1",
                "x-echo" to "server saw Bearer sk-live-1",
                "mcp-session-id" to "sk-live-1",
            ),
            listOf("Bearer sk-live-1", "sk-live-1"),
        )

        assertEquals("text/plain", filtered["content-type"])
        assertEquals("[redacted]", filtered["x-echo"])
        assertEquals("no-store", filtered["cache-control"])
        assertFalse(filtered.containsKey("set-cookie"))
        assertFalse("a session id that carries a secret is withheld", filtered.containsKey("mcp-session-id"))
    }

    @Test
    fun anInvalidMediaTypeFallsBackToOctetStream() {
        val filtered = DenylistResponseHeaderSanitizer().sanitize(
            mapOf("content-type" to "nonsense"),
            listOf("secret-1"),
        )
        assertEquals("application/octet-stream", filtered["content-type"])
    }

    @Test
    fun theResponseLogStoresWholeBodiesAndDropsAnOversizedOne() {
        val log = ResponseLog(quotaBytes = 8)
        val recorded = log.record("a", 200, emptyMap(), ByteArray(8))
        assertTrue(recorded.recorded)
        assertEquals(ResponseLogReasons.RECORDED_OK, recorded.reason)
        assertEquals(8, recorded.retainedBytes)
        assertNotNull(log.replay("a"))

        val dropped = log.record("b", 200, emptyMap(), ByteArray(9))
        assertFalse(dropped.recorded)
        assertEquals(ResponseLogReasons.QUOTA_EXCEEDED, dropped.reason)
        assertEquals(9, dropped.bodyBytes)
        assertEquals(0, dropped.retainedBytes)
        assertNull(log.replay("b"))
    }

    @Test
    fun theResponseLogEvictsTheLeastRecentlyUsedEntry() {
        val log = ResponseLog(quotaBytes = 12)
        assertTrue(log.record("a", 200, emptyMap(), ByteArray(6)).recorded)
        assertTrue(log.record("b", 200, emptyMap(), ByteArray(6)).recorded)
        assertNotNull(log.replay("a"))
        assertTrue(log.record("c", 200, emptyMap(), ByteArray(6)).recorded)

        assertNull(log.replay("b"))
        assertNotNull(log.replay("a"))
        assertNotNull(log.replay("c"))
        assertEquals(12, log.totalBytes())
    }

    @Test
    fun aTransportReasonIsBoundedAndNewlineFree() {
        val reason = "x".repeat(300) + "\nsecond line\r\nthird"
        val bounded = GatewayFailure.boundedReason(reason)

        assertTrue("length ${bounded.length}", bounded.length <= GatewayFailure.MAX_REASON_LENGTH)
        assertFalse(bounded.contains("\n"))
        assertFalse(bounded.contains("\r"))
    }

    @Test
    fun aTransportFailureIsASentFailureWithABoundedReason() {
        val url = "https://api.example.invalid/v1/messages"
        val raw = "connection refused\n" + "detail ".repeat(60)
        val transport = ScriptedTransport(failureReason = raw)
        val provider = RecordingCredentialProvider {
            GatewayCredential.ApiKey(header = "x-api-key", value = "host-key")
        }
        val session = session(
            transport = transport,
            provider = provider,
            rules = listOf("https://api.example.invalid"),
        )

        val outcome = session.exchange(
            GatewayRequest(
                method = "POST",
                url = url,
                headers = mapOf("authorization" to "Bearer sk-SENTINEL-DO-NOT-USE"),
            ),
        )

        assertEquals(GatewayDispatch.DENY, outcome.dispatch)
        assertEquals("transport_failure", outcome.denyReason)
        assertEquals(GatewayFailureCode.TRANSPORT_FAILURE, outcome.failure?.code)
        assertEquals(502, outcome.failure?.code?.proxyStatus)
        assertEquals(1, outcome.upstreamContacts)
        assertEquals(url, outcome.outboundUrl)
        assertEquals(1, transport.requests.size)
        assertFalse(outcome.lastRequestHeaders.containsKey("authorization"))
        assertEquals("host-key", outcome.lastRequestHeaders["x-api-key"])
        val reason = outcome.failure?.reasonText().orEmpty()
        assertTrue("length ${reason.length}", reason.length <= GatewayFailure.MAX_REASON_LENGTH)
        assertFalse(reason.contains("\n"))
        assertFalse(reason.contains("\r"))
        assertEquals(
            GatewayFailure.boundedReason(
                GatewayFailure.TRANSPORT_REASON_PREFIX + GatewayFailure.boundedReason(raw),
            ),
            reason,
        )
    }

    @Test
    fun ordinaryBodyForbiddenResponsesAreEmptyAndStillRecorded() {
        val cases = listOf(
            "HEAD" to 200,
            "GET" to 204,
            "GET" to 205,
            "GET" to 304,
        )
        for ((method, status) in cases) {
            val url = "https://api.example.invalid/v1/models"
            val transport = ScriptedTransport(
                finalResponse = GatewayTransportResponse(
                    status = status,
                    headers = mapOf("content-type" to "application/json"),
                    body = "must-not-appear".toByteArray(StandardCharsets.UTF_8),
                ),
            )
            val session = session(
                transport = transport,
                rules = listOf("https://api.example.invalid"),
            )

            val outcome = session.exchange(GatewayRequest(method, url))

            assertEquals("$method $status dispatch", GatewayDispatch.ALLOW, outcome.dispatch)
            assertEquals("$method $status body", 0, outcome.responseBody.size)
            assertFalse("$method $status withheld", outcome.bodyWithheld)
            assertEquals("$method $status log", true, outcome.log?.recorded)
            assertEquals(
                "$method $status reason",
                ResponseLogReasons.RECORDED_OK,
                outcome.log?.reason,
            )
            assertEquals("$method $status bytes", 0, outcome.log?.bodyBytes)
        }
    }

    @Test
    fun anUnavailableCredentialNeverForwardsTheProviderErrorText() {
        val transport = ScriptedTransport()
        val provider = RecordingCredentialProvider {
            throw CredentialUnavailableException(
                "${GatewayVectorRunner.PROVIDER_ERROR_MARKER}: ${GatewayVectorRunner.CALLER_SENTINEL}",
            )
        }
        val session = session(
            transport = transport,
            provider = provider,
            rules = listOf("https://api.example.invalid"),
        )

        val outcome = session.exchange(
            GatewayRequest(
                method = "POST",
                url = "https://api.example.invalid/v1/messages",
                headers = mapOf("authorization" to "Bearer ${GatewayVectorRunner.CALLER_SENTINEL}"),
            ),
        )

        assertEquals(GatewayDispatch.DENY, outcome.dispatch)
        assertEquals("credential_unavailable", outcome.denyReason)
        assertEquals(502, outcome.failure?.code?.proxyStatus)
        assertEquals(0, outcome.upstreamContacts)
        assertTrue(transport.requests.isEmpty())
        val envelope = outcome.failure?.envelopeJson().orEmpty()
        assertFalse(envelope.contains(GatewayVectorRunner.PROVIDER_ERROR_MARKER))
        assertFalse(envelope.contains(GatewayVectorRunner.CALLER_SENTINEL))
    }

    @Test
    fun aSensitiveNon2xxBodyBecomesOneControlledDiagnostic() {
        val body = String(
            CanonicalSensitiveBodyRedactor().controlledDiagnostic(500),
            StandardCharsets.UTF_8,
        )
        assertEquals(
            "{\"error\":{\"code\":-32000,\"message\":\"MCP upstream returned HTTP 500; " +
                "response body withheld\"},\"id\":null,\"jsonrpc\":\"2.0\"}",
            body,
        )
    }

    @Test
    fun aNoContentResponseCarriesNoBodyOnTheSensitivePath() {
        val url = "https://mcp.example.invalid/mcp"
        val transport = ScriptedTransport(
            finalResponse = GatewayTransportResponse(
                status = 204,
                headers = mapOf("content-type" to "application/json"),
                body = "must-not-appear".toByteArray(StandardCharsets.UTF_8),
            ),
        )
        val session = mcpSession(url, transport)

        val outcome = session.exchange(GatewayRequest("POST", url))

        assertEquals(GatewayDispatch.ALLOW, outcome.dispatch)
        assertEquals(204, outcome.responseStatus)
        assertEquals(0, outcome.responseBody.size)
        assertFalse(outcome.bodyWithheld)
        assertEquals(ResponseLogReasons.SENSITIVE_CREDENTIAL, outcome.log?.reason)
    }

    @Test
    fun aNonUtf8SensitiveBodyFallsBackToByteReplacement() {
        val body = byteArrayOf(0xFF.toByte()) + "before secret after".toByteArray(StandardCharsets.UTF_8)
        val sanitized = CanonicalSensitiveBodyRedactor().sanitizeBufferedBody(body, listOf("secret"))
        val text = String(sanitized, StandardCharsets.ISO_8859_1)

        assertFalse(text.contains("secret"))
        assertTrue(text.contains("[redacted]"))
        assertEquals(0xFF.toByte(), sanitized[0])
    }

    @Test
    fun anOversizedSensitiveBodyFailsClosed() {
        val url = "https://mcp.example.invalid/mcp"
        val oversized = ByteArray(CanonicalSensitiveBodyRedactor.DEFAULT_MAX_BUFFERED_BODY_BYTES + 1) { 'x'.code.toByte() }
        val transport = ScriptedTransport(
            finalResponse = GatewayTransportResponse(
                status = 200,
                headers = mapOf("content-type" to "application/json"),
                body = oversized,
            ),
        )
        val session = mcpSession(url, transport)

        val outcome = session.exchange(GatewayRequest("POST", url))

        assertEquals(GatewayDispatch.ALLOW, outcome.dispatch)
        assertTrue(outcome.bodyWithheld)
        assertTrue(outcome.responseBody.size < oversized.size)
        val body = String(outcome.responseBody, StandardCharsets.UTF_8)
        assertFalse(body.contains("xxxx"))
        assertTrue(body.contains("limit"))
        assertEquals(ResponseLogReasons.SENSITIVE_CREDENTIAL, outcome.log?.reason)
    }

    @Test
    fun hostRulesFollowTheWildcardAndPortTable() {
        fun url(text: String): GatewayUrl =
            GatewayUrls.parse(text) ?: throw IllegalArgumentException("bad test URL $text")

        val suffix = GatewayHostRule.parse("*.corp.example")
            ?: throw IllegalStateException("rule must parse")
        assertTrue(suffix.matches(url("https://corp.example/x")))
        assertTrue(suffix.matches(url("https://a.corp.example/x")))
        assertFalse(suffix.matches(url("https://evilcorp.example/x")))

        val any = GatewayHostRule.parse("*") ?: throw IllegalStateException("rule must parse")
        assertTrue("loopback is admitted by a wildcard", any.matches(url("http://127.0.0.1:7861/x")))
        assertTrue("a private literal is admitted by a wildcard", any.matches(url("http://10.1.2.3/x")))
        assertFalse(any.matches(url("ftp://10.1.2.3/x")))

        val httpsOnly = GatewayHostRule.parse("https://*")
            ?: throw IllegalStateException("rule must parse")
        assertTrue(httpsOnly.matches(url("https://corp.example:8443/x")))
        assertFalse("an https rule cannot authorize an http downgrade", httpsOnly.matches(url("http://corp.example/x")))

        val portRule = GatewayHostRule.parse("127.0.0.1:7861")
            ?: throw IllegalStateException("rule must parse")
        assertTrue(portRule.matches(url("http://127.0.0.1:7861/x")))
        assertFalse(portRule.matches(url("http://127.0.0.1:7862/x")))

        val defaultPort = GatewayHostRule.parse("https://api.example.invalid:443")
            ?: throw IllegalStateException("rule must parse")
        assertTrue(defaultPort.matches(url("https://api.example.invalid/x")))
    }

    @Test
    fun anEmptyAllowListDeniesEveryHost() {
        val policy = AllowListEgressPolicy(emptyList())
        val loopback = GatewayUrls.parse("http://127.0.0.1:7861/x")
            ?: throw IllegalStateException("URL must parse")
        assertFalse(policy.permits(loopback))
        assertFalse(policy.admitsMcpGrant(loopback))
    }

    // --------------------------------------------------------------- helpers

    private fun session(
        transport: GatewayTransport = ScriptedTransport(),
        provider: GatewayCredentialProvider = RecordingCredentialProvider { GatewayCredential.None },
        rules: List<String> = listOf("*"),
        quotaBytes: Int = GatewaySession.DEFAULT_QUOTA_BYTES,
    ): GatewaySession {
        val parsed = rules.map { text ->
            GatewayHostRule.parse(text)
                ?: throw IllegalStateException("test rule '$text' does not parse")
        }
        return GatewaySession(
            transport = transport,
            credentialProvider = provider,
            egress = AllowListEgressPolicy(parsed),
            quotaBytes = quotaBytes,
        )
    }

    private fun mcpSession(url: String, transport: GatewayTransport): GatewaySession {
        val parsed = GatewayUrls.parse(url)
            ?: throw IllegalStateException("test URL '$url' does not parse")
        return GatewaySession(
            transport = transport,
            credentialProvider = RecordingCredentialProvider { GatewayCredential.Bearer("mcp-token-1") },
            egress = AllowListEgressPolicy(
                rules = emptyList(),
                mcpGrant = CredentialOriginScope.of(parsed),
            ),
        )
    }
}
