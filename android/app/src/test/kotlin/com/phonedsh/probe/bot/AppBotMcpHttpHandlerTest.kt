// SPDX-License-Identifier: MIT
package com.phonedsh.probe.bot

import com.phonedsh.agentcore.JsonBool
import com.phonedsh.agentcore.JsonNumber
import com.phonedsh.agentcore.JsonObject
import com.phonedsh.agentcore.JsonString
import com.phonedsh.agentcore.JsonValue
import com.phonedsh.bot.authz.BotApprovalCoordinator
import com.phonedsh.bot.authz.BotGrantStore
import com.phonedsh.bot.gateway.BotAttributionRegistry
import com.phonedsh.bot.gateway.BotIdentityRegistrationService
import com.phonedsh.bot.gateway.BotTokenRegistry
import com.phonedsh.bot.mcp.BotMCPHandler
import com.phonedsh.bot.mcp.BotMCPToolRuntime
import com.phonedsh.bot.mcp.BotToolCatalog
import com.phonedsh.bot.mcp.EmptyBotAttributionPort
import com.phonedsh.bot.store.BotDomainStore
import com.phonedsh.loopback.BotMcpRequest
import com.phonedsh.loopback.BotMcpResponse
import java.io.File
import java.nio.file.Files
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

/** K6b: the App HTTP adapter over the real B5a1 dispatcher + authz stack. */
class AppBotMcpHttpHandlerTest {
    private lateinit var file: File
    private lateinit var sql: JdbcBotSqlDriver
    private lateinit var store: BotDomainStore
    private lateinit var handler: AppBotMcpHttpHandler

    @Before
    fun setUp() {
        file = Files.createTempFile("pdsh-app-bot-http-", ".sqlite").toFile()
        sql = JdbcBotSqlDriver.open(file)
        store = BotDomainStore(sql)
        val clock = { 1_000L }
        val catalog = BotToolCatalog.fromDefinitions(emptyList())
        val tools = BotMCPToolRuntime(
            catalogProvider = catalog,
            attribution = EmptyBotAttributionPort,
            now = clock,
        )
        val mcp = BotMCPHandler(catalog = catalog, tools = tools)
        val tokens = BotTokenRegistry(clock)
        val grants = BotGrantStore(
            AppBotAuthzEventLog(store, AppBotAuthzEventLog.GRANT_TYPES, clock),
            clock,
        )
        val approvals = BotApprovalCoordinator(
            grants = grants,
            eventLog = AppBotAuthzEventLog(store, AppBotAuthzEventLog.APPROVAL_TYPES, clock),
            now = clock,
        )
        val identity = BotIdentityRegistrationService(
            tokens = tokens,
            attributions = BotAttributionRegistry(clock),
            approvals = approvals,
            now = clock,
        )
        handler = AppBotMcpHttpHandler(
            handler = mcp,
            identity = identity,
            approvals = approvals,
            runtimeId = "phone-worker",
        )
    }

    @After
    fun tearDown() {
        runCatching { store.close() }
    }

    @Test
    fun initializeGoesThroughTheRealDispatcher() = runBlocking {
        val response = handle(
            "/mcp",
            """{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25"}}""",
        )
        assertTrue(response is BotMcpResponse.Json)
        val body = JsonValue.parse((response as BotMcpResponse.Json).body.toString(Charsets.UTF_8))
            as JsonObject
        assertEquals(JsonString("2.0"), body["jsonrpc"])
        assertEquals(JsonNumber("1"), body["id"])
        val result = body["result"] as JsonObject
        assertEquals(JsonString("phone"), result["serverInfo"]?.let { (it as JsonObject)["name"] })
    }

    @Test
    fun invalidIdentityRegistrationIsAnApplicationRefusalNotA500() = runBlocking {
        val response = handle("/identity/register", "{}") as BotMcpResponse.Json
        assertEquals(200, response.status)
        val body = JsonValue.parse(response.body.toString(Charsets.UTF_8)) as JsonObject
        assertEquals(JsonBool(false), body["ok"])
        assertEquals(JsonString("invalid identity registration"), body["error"])
    }

    @Test
    fun invalidApprovalIsAnApplicationRefusalNotA500() = runBlocking {
        val response = handle("/approval", "{}") as BotMcpResponse.Json
        assertEquals(200, response.status)
        val body = JsonValue.parse(response.body.toString(Charsets.UTF_8)) as JsonObject
        assertEquals(JsonBool(false), body["ok"])
        assertEquals(JsonBool(false), body["allowed"])
        assertEquals(JsonBool(false), body["pending"])
    }

    @Test
    fun unknownRouteIs404() = runBlocking {
        val response = handle("/nope", "{}") as BotMcpResponse.Json
        assertEquals(404, response.status)
    }

    private suspend fun handle(path: String, body: String): BotMcpResponse =
        handler.handle(
            BotMcpRequest(
                path = path,
                headers = mapOf("content-type" to "application/json"),
                body = body.toByteArray(Charsets.UTF_8),
                origin = "http://127.0.0.1:18888",
            ),
        )
}
