// SPDX-License-Identifier: MIT
// Mirrors Tests/PhoneDSHTests/PhoneMCPOAuthTests.swift plus the Android proxy.
package com.phonedsh.connectors.mcpoauth

import com.phonedsh.agentcore.JsonObject
import com.phonedsh.agentcore.JsonString
import com.phonedsh.agentcore.JsonValue
import com.phonedsh.loopback.NativeMcpRequest
import com.phonedsh.loopback.NativeMcpResponse
import com.phonedsh.loopback.NativeMcpServing
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import java.net.URI

private const val RESOURCE = "https://docs.example.test/openapi/mcp"
private const val RESOURCE_METADATA = "https://docs.example.test/openapi/mcp/.well-known/oauth-protected-resource"
private const val TOKEN = "https://docs.example.test/openapi/mcp/oauth/token"

private class FakeHttp : HttpExchange {
    val routes = LinkedHashMap<String, (String, Map<String, String>, ByteArray?) -> HttpReply>()
    val requests = ArrayList<Triple<String, Map<String, String>, String>>()

    fun route(method: String, url: String, reply: (String, Map<String, String>, ByteArray?) -> HttpReply) { routes["$method $url"] = reply }

    override fun send(method: String, url: String, headers: Map<String, String>, body: ByteArray?): HttpReply {
        requests.add(Triple("$method $url", headers, body?.let { String(it) }.orEmpty()))
        return routes["$method $url"]?.invoke(url, headers, body) ?: HttpReply(404, emptyMap(), ByteArray(0))
    }
}

private fun json(status: Int = 200, body: String, headers: Map<String, String> = emptyMap()) =
    HttpReply(status, headers + ("Content-Type" to "application/json"), body.toByteArray())

private fun tencentLike(): FakeHttp = FakeHttp().apply {
    route("POST", RESOURCE) { _, _, _ ->
        json(401, """{"error":"invalid_token"}""", mapOf("WWW-Authenticate" to "Bearer resource_metadata=\"$RESOURCE_METADATA\""))
    }
    route("GET", RESOURCE_METADATA) { _, _, _ ->
        json(body = """{"resource":"$RESOURCE","authorization_servers":["https://docs.example.test"]}""")
    }
    route("GET", "https://docs.example.test/.well-known/oauth-authorization-server") { _, _, _ ->
        json(body = """{"issuer":"https://docs.example.test","authorization_endpoint":"https://docs.example.test/scenario/open.html?authType=2","token_endpoint":"$TOKEN","registration_endpoint":"https://docs.example.test/openapi/mcp/oauth/register","code_challenge_methods_supported":["S256"]}""")
    }
    route("POST", "https://docs.example.test/openapi/mcp/oauth/register") { _, _, body ->
        assertTrue(String(body!!).contains("\"token_endpoint_auth_method\":\"none\""))
        json(201, """{"client_id":"client-1"}""")
    }
}

private fun registration() = McpOAuthRegistration("https://docs.example.test", "https://docs.example.test/scenario/open.html?authType=2",
    TOKEN, "client-1", McpConnectorCatalog.redirectUri(McpConnectorCatalog.TENCENT_DOCS), RESOURCE)

private fun record(access: String, refresh: String?, expiresAt: Long? = null) =
    McpOAuthRecord(registration(), McpOAuthTokens(access, refresh, expiresAt, null))

private class MemoryOAuthStore : McpOAuthStore {
    val records = HashMap<String, McpOAuthRecord>()
    override fun read(connectorId: String) = records[connectorId]
    override fun write(connectorId: String, record: McpOAuthRecord) { records[connectorId] = record }
    override fun delete(connectorId: String) { records.remove(connectorId) }
}

class McpOAuthClientTest {
    @Test fun discoveryFollowsTheResourceMetadataHeader() = runBlocking {
        val metadata = McpOAuthClient(tencentLike()).discover(RESOURCE)
        assertEquals("https://docs.example.test", metadata.issuer)
        assertEquals(TOKEN, metadata.tokenEndpoint)
        assertEquals(RESOURCE, metadata.resource)
    }

    @Test fun authorizationUrlKeepsQueryAndCarriesPkce() = runBlocking {
        val client = McpOAuthClient(tencentLike())
        val registration = client.register(client.discover(RESOURCE), McpConnectorCatalog.redirectUri(McpConnectorCatalog.TENCENT_DOCS), "docs:read")
        val attempt = client.begin(registration, "docs:read")
        val query = McpOAuthClient.parseQuery(URI(attempt.url).rawQuery)
        assertEquals("2", query["authType"])
        assertEquals("client-1", query["client_id"])
        assertEquals("S256", query["code_challenge_method"])
        assertEquals(McpOAuthClient.challenge(attempt.verifier), query["code_challenge"])
        assertEquals(attempt.state, query["state"])
        assertEquals(RESOURCE, query["resource"])
    }

    @Test fun foreignStateIsRejectedBeforeAnyTokenRequest() = runBlocking {
        val http = tencentLike()
        val client = McpOAuthClient(http)
        val attempt = client.begin(registration(), null)
        try {
            client.finish(attempt, "phonedsh-oauth://callback/tencent-docs?code=abc&state=forged")
            fail("expected state_mismatch")
        } catch (failure: McpOAuthException) {
            assertEquals("state_mismatch", failure.code)
        }
        assertFalse(http.requests.any { it.first.endsWith("/oauth/token") })
    }

    @Test fun finishExchangesTheCode() = runBlocking {
        val http = tencentLike()
        http.route("POST", TOKEN) { _, _, body ->
            val form = String(body!!)
            assertTrue(form.contains("grant_type=authorization_code") && form.contains("code=the-code") && form.contains("code_verifier="))
            json(body = """{"access_token":"at-1","refresh_token":"rt-1","token_type":"Bearer","expires_in":3600}""")
        }
        val client = McpOAuthClient(http, now = { 1_000_000L })
        val attempt = client.begin(registration(), null)
        val result = client.finish(attempt, "phonedsh-oauth://callback/tencent-docs?code=the-code&state=${attempt.state}")
        assertEquals("at-1", result.tokens.accessToken)
        assertEquals(1_000_000L + 3_600_000L, result.tokens.expiresAtMillis)
    }

    @Test fun rejectedRefreshRequiresReauthorization() = runBlocking {
        val http = FakeHttp().apply { route("POST", TOKEN) { _, _, _ -> json(400, """{"error":"invalid_grant"}""") } }
        try {
            McpOAuthClient(http).refresh(record("at-1", "rt-1"))
            fail("expected reauthorization")
        } catch (failure: McpOAuthException) {
            assertEquals("reauthorization_required", failure.code)
        }
    }

    @Test fun recordRoundTrips() {
        val original = record("at-1", "rt-1", 42L)
        assertEquals(original, McpOAuthRecord.decode(original.encode()))
    }

    @Test fun tokenSourceRefreshesNearExpiryAndPersists() = runBlocking {
        val http = FakeHttp().apply {
            route("POST", TOKEN) { _, _, _ -> json(body = """{"access_token":"at-2","refresh_token":"rt-2","token_type":"Bearer","expires_in":3600}""") }
        }
        val store = MemoryOAuthStore().apply { write("tencent-docs", record("at-1", "rt-1", expiresAt = 1_000L)) }
        val source = McpOAuthTokenSource(McpConnectorCatalog.TENCENT_DOCS, store, McpOAuthClient(http, now = { 0L }), now = { 0L })
        assertEquals("at-2", source.bearer())
        assertEquals("rt-2", store.read("tencent-docs")?.tokens?.refreshToken)
    }

    @Test fun tokenSourceReportsReauthorization() = runBlocking {
        val http = FakeHttp().apply { route("POST", TOKEN) { _, _, _ -> json(400, """{"error":"invalid_grant"}""") } }
        var flagged = false
        val store = MemoryOAuthStore().apply { write("tencent-docs", record("at-1", "rt-1")) }
        val source = McpOAuthTokenSource(McpConnectorCatalog.TENCENT_DOCS, store, McpOAuthClient(http), onReauthorizationRequired = { flagged = true })
        assertNull(source.bearer(forceRefresh = true))
        assertTrue(flagged)
    }
}

class McpConnectorProxyTest {
    private object Empty : NativeMcpServing {
        override suspend fun handle(request: NativeMcpRequest) =
            NativeMcpResponse(200, """{"jsonrpc":"2.0","id":1,"result":{"tools":[]}}""".toByteArray())
    }

    private fun remote(): FakeHttp = FakeHttp().apply {
        route("POST", RESOURCE) { _, headers, body ->
            assertEquals("Bearer at-1", headers["Authorization"])
            val message = JsonValue.parse(String(body!!)) as JsonObject
            when ((message["method"] as JsonString).value) {
                "initialize" -> json(body = """{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2025-06-18","capabilities":{}}}""",
                    headers = mapOf("Mcp-Session-Id" to "s1"))
                "notifications/initialized" -> HttpReply(202, emptyMap(), ByteArray(0))
                "tools/list" -> HttpReply(200, mapOf("Content-Type" to "text/event-stream"),
                    "event: message\ndata: {\"jsonrpc\":\"2.0\",\"id\":${(message["id"] as com.phonedsh.agentcore.JsonNumber).raw},\"result\":{\"tools\":[{\"name\":\"search_docs\",\"description\":\"Search\",\"inputSchema\":{\"type\":\"object\"}}]}}\n\n".toByteArray())
                "tools/call" -> json(body = """{"jsonrpc":"2.0","id":${(message["id"] as com.phonedsh.agentcore.JsonNumber).raw},"result":{"content":[{"type":"text","text":"ok"}],"isError":false}}""")
                else -> json(400, "{}")
            }
        }
    }

    @Test fun listsPrefixedToolsAndForwardsCalls() = runBlocking {
        val http = remote()
        val client = RemoteMcpClient(RESOURCE, { "at-1" }, http)
        val server = McpConnectorNativeServer(Empty, McpConnectorCatalog.TENCENT_DOCS, { true }, client)
        val list = String(server.handle(NativeMcpRequest("POST", emptyMap(), """{"jsonrpc":"2.0","id":1,"method":"tools/list"}""".toByteArray())).body)
        assertTrue(list.contains("\"tencent_docs__search_docs\""))
        val call = String(server.handle(NativeMcpRequest("POST", emptyMap(),
            """{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"tencent_docs__search_docs","arguments":{"q":"x"}}}""".toByteArray())).body)
        assertTrue(call.contains("\"text\":\"ok\""))
        val forwarded = http.requests.last { it.third.contains("tools/call") }
        assertTrue(forwarded.third.contains("\"name\":\"search_docs\""))
        assertEquals("s1", forwarded.second["Mcp-Session-Id"])
    }

    @Test fun disconnectedConnectorAddsNoTools() = runBlocking {
        val server = McpConnectorNativeServer(Empty, McpConnectorCatalog.TENCENT_DOCS, { false }, RemoteMcpClient(RESOURCE, { null }, FakeHttp()))
        val list = String(server.handle(NativeMcpRequest("POST", emptyMap(), """{"jsonrpc":"2.0","id":1,"method":"tools/list"}""".toByteArray())).body)
        assertFalse(list.contains("tencent_docs__"))
    }
}
