// phone-dsh — :net tests: the exact-route MCP egress gate and credential router.
// SPDX-License-Identifier: MIT
//
// Drives the real `GatewaySession`/`GatewayHttpEgress` chain with a fake
// transport so "no credential resolution, no socket, no response log" is an
// assertion rather than a hope. The frozen §1.1 403 body/header is checked
// byte-for-byte.

package com.phonedsh.gateway

import com.phonedsh.loopback.LoopbackHttpEgress
import com.phonedsh.loopback.LoopbackHttpRequest
import com.phonedsh.loopback.LoopbackHttpResponse
import java.util.concurrent.CopyOnWriteArrayList
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

class McpEgressPolicyTest {
    private val egressToken: String = "e".repeat(32)
    private val botBearer: String = "bot-bearer-secret"
    private val botEndpoint: String = "http://127.0.0.1:8787/mcp"

    private fun policy(withBearer: Boolean = true): McpEgressPolicy =
        McpEgressPolicy().apply {
            installEgressToken(egressToken)
            grantBotRuntimeEndpoint(botEndpoint, if (withBearer) botBearer else null)
        }

    private fun scope(path: String, host: String = "127.0.0.1", port: Int? = 8787): CredentialScope =
        CredentialScope(service = host, audience = path, scheme = "http", port = port)

    // ----------------------------------------------------------- exact route

    @Test
    fun allFourBotRoutesRequireTheCurrentEgressHeader() {
        val policy = policy()
        for (path in listOf("/mcp", "/identity/register", "/identity/cancel", "/approval")) {
            val url = "http://127.0.0.1:8787$path"
            assertTrue("$path is an exact route", policy.allowsEgressHost(url))
            assertTrue("$path with the current token", policy.admitsEgress(url, mapOf("X-PDSH-MCP-Egress" to egressToken)))
            assertFalse("$path without a token", policy.admitsEgress(url, emptyMap()))
            assertFalse("$path with an empty token", policy.admitsEgress(url, mapOf("X-PDSH-MCP-Egress" to "")))
            assertFalse("$path with a wrong token", policy.admitsEgress(url, mapOf("X-PDSH-MCP-Egress" to "f".repeat(32))))
            assertFalse("$path with a case-shifted token", policy.admitsEgress(url, mapOf("X-PDSH-MCP-Egress" to egressToken.uppercase())))
        }
        assertEquals(
            listOf(
                "http://127.0.0.1:8787/approval",
                "http://127.0.0.1:8787/identity/cancel",
                "http://127.0.0.1:8787/identity/register",
                "http://127.0.0.1:8787/mcp",
            ),
            policy.authorizedURLs().sorted(),
        )
    }

    @Test
    fun aHostWithoutAnEgressTokenFailsClosedEvenWithAHeader() {
        val policy = McpEgressPolicy().apply {
            grantBotRuntimeEndpoint(botEndpoint, botBearer)
        }
        assertFalse(policy.admitsEgress(botEndpoint, mapOf("X-PDSH-MCP-Egress" to egressToken)))
    }

    @Test
    fun theHeaderNameIsCaseInsensitiveButTheValueIsByteExact() {
        val policy = policy()
        assertTrue(policy.admitsEgress(botEndpoint, mapOf("x-pdsh-mcp-egress" to egressToken)))
        assertTrue(policy.admitsEgress(botEndpoint, mapOf("X-PdSh-McP-EgReSs" to egressToken)))
        assertFalse(policy.admitsEgress(botEndpoint, mapOf("x-pdsh-mcp-egress" to "$egressToken ")))
    }

    @Test
    fun aTargetOutsideEveryExactRouteIsUnaffected() {
        val policy = policy()
        assertFalse(policy.allowsEgressHost("https://example.test/mcp"))
        assertTrue("a non-MCP target is not gated", policy.admitsEgress("https://example.test/v1/messages", emptyMap()))
        assertTrue("a malformed target is left to the gateway", policy.admitsEgress("not a url", emptyMap()))
    }

    @Test
    fun effectivePortAndNormalizedPathAreTheCredentialPredicate() {
        val policy = policy()
        // A route with no explicit port is the same exact route on :80.
        policy.grant("connector", "http://connector.test/mcp", mapOf("Authorization" to "Bearer c"))
        assertTrue(policy.admitsEgress("http://connector.test:80/mcp", mapOf("X-PDSH-MCP-Egress" to egressToken)))
        assertTrue(policy.admitsEgress("http://connector.test/mcp/", mapOf("X-PDSH-MCP-Egress" to egressToken)))
        assertFalse("another effective port is not the exact route", policy.allowsEgressHost("http://connector.test:81/mcp"))
        assertTrue("and is left to the ordinary gateway policy", policy.admitsEgress("http://connector.test:81/mcp", emptyMap()))
        assertFalse("another scheme is not the exact route", policy.allowsEgressHost("https://connector.test/mcp"))
    }

    @Test
    fun theBotGrantRequiresTheExactMcpEndpointPath() {
        try {
            McpEgressPolicy().grantBotRuntimeEndpoint("http://127.0.0.1:8787/other", botBearer)
            fail("a non-/mcp Bot endpoint must be refused")
        } catch (expected: IllegalArgumentException) {
            assertTrue(expected.message!!.contains("/mcp"))
        }
    }

    @Test
    fun theHostStartTokenIs128BitLowercaseHexAndFreshEachStart() {
        val first = McpEgressCredential.make()
        val second = McpEgressCredential.make()
        assertTrue("at least 128 bits as lowercase hex", Regex("[0-9a-f]{32}").matches(first))
        assertTrue(Regex("[0-9a-f]{32}").matches(second))
        assertFalse("one value per host start", first == second)
    }

    @Test
    fun installingANewHostStartTokenInvalidatesTheOldOne() {
        val policy = policy()
        val replacement = "44".repeat(32)
        policy.installEgressToken(replacement)
        assertFalse(policy.admitsEgress(botEndpoint, mapOf("X-PDSH-MCP-Egress" to egressToken)))
        assertTrue(policy.admitsEgress(botEndpoint, mapOf("X-PDSH-MCP-Egress" to replacement)))
    }

    @Test
    fun aDuplicateExactRouteIsRefused() {
        val policy = policy()
        try {
            policy.grant("other", "http://127.0.0.1:8787/mcp", emptyMap())
            fail("two server names for one exact route would be ambiguous")
        } catch (expected: IllegalArgumentException) {
            assertTrue(expected.message!!.contains("dshbot"))
        }
        try {
            policy.grantBotRuntimeEndpoint("http://127.0.0.1:8787/mcp", "another")
            // Re-granting the same four names replaces them; this is the
            // host-start rotation path and must stay allowed.
        } catch (expected: IllegalArgumentException) {
            fail("re-granting the Bot route set is a token rotation, not a duplicate: ${expected.message}")
        }
    }

    @Test
    fun aUserConnectorCannotTakeOneOfTheReservedBotRoutes() {
        val policy = McpEgressPolicy()
        policy.grant("connector", "http://127.0.0.1:8787/approval", mapOf("X-Connector" to "v"))
        try {
            policy.grantBotRuntimeEndpoint(botEndpoint, botBearer)
            fail("a connector route cannot shadow a reserved Bot route")
        } catch (expected: IllegalArgumentException) {
            assertTrue(expected.message!!.contains("connector"))
        }
    }

    // --------------------------------------------------------------- gate

    @Test
    fun theGateReturnsTheFrozen403WithoutCallingTheGateway() {
        val delegate = RecordingEgress()
        val gate = McpEgressGate(policy(), delegate)
        val response = gate.handle(
            request(
                target = botEndpoint,
                headers = mapOf(
                    "authorization" to "Bearer phone-host-injects-bot-mcp-token",
                ),
            ),
        )
        assertEquals(403, response.status)
        assertEquals("application/json; charset=utf-8", response.headers["content-type"])
        assertEquals("mcp_egress_forbidden", response.headers["x-pdsh-proxy-error"])
        assertEquals(
            """{"error":{"code":"mcp_egress_forbidden","message":"the MCP egress credential is missing or invalid"}}""",
            response.bodyText(),
        )
        assertEquals("the gateway, its response log and the transport were never reached", 0, delegate.calls)
    }

    @Test
    fun theGateDelegatesWithTheCurrentTokenAndLeavesOtherTargetsAlone() {
        val delegate = RecordingEgress()
        val gate = McpEgressGate(policy(), delegate)
        val admitted = gate.handle(
            request(
                target = botEndpoint,
                headers = mapOf("X-PDSH-MCP-Egress" to egressToken),
            ),
        )
        assertEquals(200, admitted.status)
        assertEquals(1, delegate.calls)

        gate.handle(request(target = "https://example.test/v1/models", headers = emptyMap()))
        assertEquals("a non-MCP target passes through", 2, delegate.calls)
    }

    // --------------------------------------------------------- credentials

    @Test
    fun theProviderInjectsTheBotBearerAndConnectorHeaders() {
        val policy = policy()
        policy.grant("connector", "https://connector.test/mcp", mapOf("X-Connector" to "stored"))
        val provider = McpEgressCredentialProvider(policy, NoCredentialProvider)

        val bot = provider.resolve(scope("/mcp"))
        assertTrue(bot is GatewayCredential.Headers)
        assertEquals("Bearer $botBearer", (bot as GatewayCredential.Headers).headers["Authorization"])

        val connector = provider.resolve(
            CredentialScope(service = "connector.test", audience = "/mcp", scheme = "https", port = null),
        )
        assertEquals(
            mapOf("X-Connector" to "stored"),
            (connector as GatewayCredential.Headers).headers,
        )
    }

    @Test
    fun aHostWithoutAnEgressTokenAlsoRefusesToResolveARouteCredential() {
        val policy = McpEgressPolicy()
        policy.grantBotRuntimeEndpoint(botEndpoint, botBearer)
        assertEquals(McpRouteCredential.Unavailable, policy.credentialFor(scope("/mcp")))
    }

    @Test
    fun aBotRouteWithoutItsBearerFailsClosed() {
        val policy = policy(withBearer = false)
        val provider = McpEgressCredentialProvider(policy, NoCredentialProvider)
        try {
            provider.resolve(scope("/mcp"))
            fail("a credential-less Bot route must not become an anonymous request")
        } catch (expected: CredentialUnavailableException) {
            assertTrue(expected.message!!.contains("bearer"))
        }
    }

    @Test
    fun aNonRouteScopeDelegatesToTheBaseProvider() {
        val policy = policy()
        val base = RecordingCredentialProvider()
        val provider = McpEgressCredentialProvider(policy, base)
        provider.resolve(CredentialScope(service = "api.example.test", audience = "/v1/messages", scheme = "https", port = null))
        assertEquals(1, base.calls)
        assertNull(policy.credentialFor(scope("/other")))
    }

    // ------------------------------------------------- real gateway chain

    @Test
    fun theGatewayInjectsTheBotBearerAndStripsTheHopHeader() {
        val policy = policy()
        val transport = RecordingTransport()
        val provider = RecordingCredentialProvider(
            McpEgressCredentialProvider(policy, NoCredentialProvider),
        )
        val gateway = GatewaySession(
            transport = transport,
            credentialProvider = provider,
            egress = McpRouteEgressPolicy(policy, AllowListEgressPolicy(emptyList())),
        )
        val egress = McpEgressGate(policy, GatewayHttpEgress(gateway))
        val response = egress.handle(
            request(
                target = botEndpoint,
                headers = mapOf(
                    "x-pdsh-target-url" to botEndpoint,
                    "x-pdsh-target-method" to "POST",
                    "authorization" to "Bearer phone-host-injects-bot-mcp-token",
                    "x-pdsh-mcp-egress" to egressToken,
                    "content-type" to "application/json",
                ),
                body = """{"jsonrpc":"2.0","id":1,"method":"ping"}""".toByteArray(),
            ),
        )
        assertEquals(200, response.status)
        assertEquals(1, provider.calls)
        val sent = transport.requests.single()
        assertEquals("Bearer $botBearer", sent.headers["authorization"])
        assertNull("the hop credential never reaches the upstream", sent.headers["x-pdsh-mcp-egress"])
        assertFalse(
            "the Worker placeholder never reaches the upstream",
            sent.headers.values.any { it.contains("phone-host-injects-bot-mcp-token") },
        )
    }

    @Test
    fun anOldWorkerWithoutTheHopHeaderIsRejectedBeforeCredentialResolution() {
        val policy = policy()
        val transport = RecordingTransport()
        val provider = RecordingCredentialProvider(
            McpEgressCredentialProvider(policy, NoCredentialProvider),
        )
        val gateway = GatewaySession(
            transport = transport,
            credentialProvider = provider,
            egress = McpRouteEgressPolicy(policy, AllowListEgressPolicy(emptyList())),
        )
        val egress = McpEgressGate(policy, GatewayHttpEgress(gateway))
        val response = egress.handle(
            request(
                target = botEndpoint,
                headers = mapOf(
                    "x-pdsh-target-url" to botEndpoint,
                    "authorization" to "Bearer phone-host-injects-bot-mcp-token",
                ),
            ),
        )
        assertEquals(403, response.status)
        assertEquals("mcp_egress_forbidden", response.headers["x-pdsh-proxy-error"])
        assertEquals("the new App + old Worker pair fails closed", 0, provider.calls)
        assertEquals(0, transport.requests.size)
    }

    // --------------------------------------------------------------- helpers

    private fun request(
        target: String,
        headers: Map<String, String>,
        body: ByteArray = ByteArray(0),
    ): LoopbackHttpRequest = LoopbackHttpRequest(
        method = "POST",
        targetUrl = target,
        targetMethod = "POST",
        headers = headers,
        body = body,
    )

    private class RecordingEgress : LoopbackHttpEgress {
        var calls: Int = 0
            private set

        override fun handle(request: LoopbackHttpRequest): LoopbackHttpResponse {
            calls++
            return LoopbackHttpResponse(200, mapOf("content-type" to "application/json"), """{"ok":true}""".toByteArray())
        }
    }

    private object NoCredentialProvider : GatewayCredentialProvider {
        override fun resolve(scope: CredentialScope): GatewayCredential = GatewayCredential.None
    }

    private class RecordingCredentialProvider(
        private val delegate: GatewayCredentialProvider = NoCredentialProvider,
    ) : GatewayCredentialProvider {
        var calls: Int = 0
            private set

        override fun resolve(scope: CredentialScope): GatewayCredential {
            calls++
            return delegate.resolve(scope)
        }
    }

    private class RecordingTransport : GatewayTransport {
        val requests = CopyOnWriteArrayList<GatewayTransportRequest>()

        override fun execute(request: GatewayTransportRequest): GatewayTransportResponse {
            requests.add(request)
            return GatewayTransportResponse(200, mapOf("content-type" to "application/json"), """{"ok":true}""".toByteArray())
        }
    }
}
