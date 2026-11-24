// SPDX-License-Identifier: MIT
// Android path for hosted MCP connectors. This host has no `phone/mcpUpsert`
// and no gateway injection for user MCP rows, so instead of mounting a Worker
// row the app itself is the MCP client: it talks Streamable HTTP to the
// provider with the Keystore-held bearer and re-exposes the provider's tools on
// `/mcp/native` under a prefix (`tencent_docs__<tool>`). The token never enters
// the Worker either way.
package com.phonedsh.connectors.mcpoauth

import com.phonedsh.agentcore.JsonArray
import com.phonedsh.agentcore.JsonBool
import com.phonedsh.agentcore.JsonNumber
import com.phonedsh.agentcore.JsonObject
import com.phonedsh.agentcore.JsonString
import com.phonedsh.agentcore.JsonValue
import com.phonedsh.agentcore.toJsonString
import com.phonedsh.loopback.NativeMcpRequest
import com.phonedsh.loopback.NativeMcpResponse
import com.phonedsh.loopback.NativeMcpServing
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext

/** A minimal Streamable HTTP MCP client for one remote server. */
public class RemoteMcpClient(
    private val url: String,
    private val bearer: suspend (forceRefresh: Boolean) -> String?,
    private val http: HttpExchange = UrlConnectionExchange,
) {
    private val mutex = Mutex()
    private var sessionId: String? = null
    private var initialized = false
    private var nextId = 1L

    public class NotConnected : Exception("not connected")

    public suspend fun listTools(): List<JsonObject> {
        val tools = ArrayList<JsonObject>()
        var cursor: String? = null
        do {
            val params = if (cursor != null) JsonObject(linkedMapOf("cursor" to JsonString(cursor))) else JsonObject(emptyMap())
            val result = request("tools/list", params) as? JsonObject ?: break
            (result["tools"] as? JsonArray)?.values?.filterIsInstance<JsonObject>()?.let(tools::addAll)
            cursor = (result["nextCursor"] as? JsonString)?.value
        } while (cursor != null && tools.size < 500)
        return tools
    }

    public suspend fun callTool(name: String, arguments: JsonValue): JsonValue =
        request("tools/call", JsonObject(linkedMapOf("name" to JsonString(name), "arguments" to arguments)))
            ?: JsonObject(emptyMap())

    /** Returns the JSON-RPC `result`, or throws with the server's error. */
    private suspend fun request(method: String, params: JsonValue): JsonValue? = mutex.withLock {
        if (!initialized) initialize()
        try {
            rpc(method, params)
        } catch (expired: SessionExpired) {
            initialize()
            rpc(method, params)
        }
    }

    private class SessionExpired : Exception()

    private suspend fun initialize() {
        sessionId = null
        rpc("initialize", JsonObject(linkedMapOf(
            "protocolVersion" to JsonString("2025-06-18"),
            "capabilities" to JsonObject(emptyMap()),
            "clientInfo" to JsonObject(linkedMapOf("name" to JsonString("phone-dsh"), "version" to JsonString("1.0"))),
        )))
        post(JsonObject(linkedMapOf("jsonrpc" to JsonString("2.0"), "method" to JsonString("notifications/initialized"))), expectReply = false)
        initialized = true
    }

    private suspend fun rpc(method: String, params: JsonValue): JsonValue? {
        val id = nextId++
        val message = JsonObject(linkedMapOf(
            "jsonrpc" to JsonString("2.0"), "id" to JsonNumber(id.toString()),
            "method" to JsonString(method), "params" to params,
        ))
        val reply = post(message, expectReply = true) ?: return null
        (reply["error"] as? JsonObject)?.let {
            throw RemoteMcpException((it["message"] as? JsonString)?.value ?: "remote MCP error")
        }
        return reply["result"]
    }

    /** One POST; retries once with a refreshed bearer on 401. */
    private suspend fun post(message: JsonObject, expectReply: Boolean): JsonObject? {
        var token = bearer(false) ?: throw NotConnected()
        repeat(2) { attempt ->
            val headers = linkedMapOf(
                "Content-Type" to "application/json",
                "Accept" to "application/json, text/event-stream",
                "Authorization" to "Bearer $token",
                "MCP-Protocol-Version" to "2025-06-18",
            )
            sessionId?.let { headers["Mcp-Session-Id"] = it }
            val reply = withContext(Dispatchers.IO) { http.send("POST", url, headers, message.toJsonString().toByteArray()) }
            if (reply.status == 401 && attempt == 0) {
                token = bearer(true) ?: throw NotConnected()
                return@repeat
            }
            if (reply.status == 401) throw NotConnected()
            if (reply.status == 404 && sessionId != null && (message["method"] as? JsonString)?.value != "initialize") {
                throw SessionExpired()
            }
            reply.header("Mcp-Session-Id")?.let { sessionId = it }
            if (!expectReply) return null
            if (reply.status !in 200..299) throw RemoteMcpException("HTTP ${reply.status}")
            return parseReply(reply, message["id"])
        }
        throw NotConnected()
    }

    private fun parseReply(reply: HttpReply, id: JsonValue?): JsonObject? {
        val contentType = reply.header("Content-Type").orEmpty()
        if (contentType.contains("text/event-stream")) {
            // Take the JSON-RPC response with our id among the SSE events.
            for (event in reply.text().split("\n\n")) {
                val data = event.lines().filter { it.startsWith("data:") }.joinToString("\n") { it.removePrefix("data:").trimStart() }
                if (data.isEmpty()) continue
                val message = try { JsonValue.parse(data) as? JsonObject } catch (_: Exception) { null } ?: continue
                if (message["id"] == id) return message
            }
            return null
        }
        return try { JsonValue.parse(reply.text()) as? JsonObject } catch (_: Exception) { null }
    }
}

public class RemoteMcpException(message: String) : Exception(message)

/**
 * `/mcp/native` front for one connector: lists the provider's tools under
 * [McpConnector.toolPrefix] while connected and forwards calls to them.
 */
public class McpConnectorNativeServer(
    private val fallback: NativeMcpServing,
    private val connector: McpConnector,
    private val isConnected: () -> Boolean,
    private val client: RemoteMcpClient,
    private val now: () -> Long = System::currentTimeMillis,
) : NativeMcpServing {
    private val cacheLock = Mutex()
    private var cached: List<JsonObject>? = null
    private var cachedAt = 0L

    override suspend fun cancelPendingOperations() {
        fallback.cancelPendingOperations()
    }

    /** Drop the cached tool list (after connect or disconnect). */
    public suspend fun invalidate() {
        cacheLock.withLock { cached = null }
    }

    override suspend fun handle(request: NativeMcpRequest): NativeMcpResponse {
        if (!request.method.equals("POST", true)) return fallback.handle(request)
        val root = try { JsonValue.parse(String(request.body, Charsets.UTF_8)) as? JsonObject } catch (_: Exception) { null }
            ?: return fallback.handle(request)
        val method = (root["method"] as? JsonString)?.value ?: return fallback.handle(request)
        if ((method == "tools/list" || method == "initialize") && isConnected()) {
            val response = fallback.handle(request)
            val body = try { JsonValue.parse(String(response.body, Charsets.UTF_8)) as? JsonObject } catch (_: Exception) { null }
                ?: return response
            val result = body["result"] as? JsonObject ?: return response
            val members = LinkedHashMap(result.members)
            if (method == "tools/list") {
                val existing = (result["tools"] as? JsonArray)?.values ?: return response
                members["tools"] = JsonArray(existing + remoteTools())
            } else {
                val text = (result["instructions"] as? JsonString)?.value?.let { "$it " }.orEmpty()
                members["instructions"] = JsonString(text + instructions())
            }
            val next = LinkedHashMap(body.members).apply { put("result", JsonObject(members)) }
            return NativeMcpResponse(response.status, JsonObject(next).toJsonString().toByteArray(Charsets.UTF_8))
        }
        val params = root["params"] as? JsonObject
        val name = (params?.get("name") as? JsonString)?.value
        if (method != "tools/call" || name == null || !name.startsWith(connector.toolPrefix)) return fallback.handle(request)
        val id = root["id"] ?: return NativeMcpResponse(202)
        val result: JsonValue = try {
            client.callTool(name.removePrefix(connector.toolPrefix), params["arguments"] ?: JsonObject(emptyMap()))
        } catch (_: RemoteMcpClient.NotConnected) {
            error("not_connected", "${connector.displayName}未连接或授权已失效，请到「发现 › ${connector.displayName}」重新连接。")
        } catch (failure: Exception) {
            error("remote_failed", "${connector.displayName}调用失败：${failure.message ?: failure.javaClass.simpleName}")
        }
        val envelope = JsonObject(linkedMapOf("jsonrpc" to JsonString("2.0"), "id" to id, "result" to result))
        return NativeMcpResponse(200, envelope.toJsonString().toByteArray(Charsets.UTF_8))
    }

    private suspend fun remoteTools(): List<JsonValue> = cacheLock.withLock {
        val fresh = cached?.takeIf { now() - cachedAt < CACHE_MILLIS }
            ?: try { client.listTools().also { cached = it; cachedAt = now() } } catch (_: Exception) { return emptyList() }
        fresh.mapNotNull { tool ->
            val name = (tool["name"] as? JsonString)?.value ?: return@mapNotNull null
            val members = LinkedHashMap(tool.members)
            members["name"] = JsonString(connector.toolPrefix + name)
            val description = (tool["description"] as? JsonString)?.value.orEmpty()
            members["description"] = JsonString("[${connector.displayName}] $description".trim())
            JsonObject(members)
        }
    }

    private fun instructions(): String =
        "Tools named ${connector.toolPrefix}* come from the ${connector.displayName} plugin (Tencent Docs). In user-facing replies call it the 腾讯文档插件, not MCP."

    private fun error(code: String, message: String): JsonValue {
        val payload = JsonObject(linkedMapOf("status" to JsonString(code), "message" to JsonString(message), "automatic_retry" to JsonBool(false)))
        return JsonObject(linkedMapOf(
            "content" to JsonArray(listOf(JsonObject(linkedMapOf("type" to JsonString("text"), "text" to JsonString(payload.toJsonString()))))),
            "isError" to JsonBool(true),
        ))
    }

    private companion object { const val CACHE_MILLIS = 5 * 60_000L }
}
