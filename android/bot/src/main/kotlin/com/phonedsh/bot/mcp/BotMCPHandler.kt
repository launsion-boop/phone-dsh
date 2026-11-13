// SPDX-License-Identifier: MIT
package com.phonedsh.bot.mcp

import com.phonedsh.agentcore.JsonArray
import com.phonedsh.agentcore.JsonBool
import com.phonedsh.agentcore.JsonNull
import com.phonedsh.agentcore.JsonObject
import com.phonedsh.agentcore.JsonString
import com.phonedsh.agentcore.JsonValue
import com.phonedsh.bot.BotJson
import kotlinx.coroutines.CancellationException

/** Optional bridge to the native MCP server (`BotNativeMCPForwarding`). */
public interface BotNativeMCPForwarder {
    public suspend fun handle(request: JsonValue, headers: Map<String, String>): JsonValue?
}

/**
 * The JSON-RPC surface of `mcp-endpoint.md` §7: initialize/ping/tools-list/
 * tools-call, native forwarding and the `-32601/-32602/-32603` boundaries.
 * The handler never reads a token store, an approval coordinator or a routine
 * store; those come in through [BotMCPToolRuntime] ports.
 */
public class BotMCPHandler(
    private val catalog: BotMCPToolCatalogProvider,
    private val tools: BotMCPToolRuntime,
    private val tokens: BotTokenPrincipalPort = EmptyBotTokenPrincipalPort,
    private var native: BotNativeMCPForwarder? = null,
    private val protocolVersions: List<String> = BotMCPProtocol.PROTOCOL_VERSIONS,
    private val resultEncoder: (BotMCPCallResult) -> JsonValue = { it.toJson() },
    public val mcpSessionId: String = randomHexId(),
) {
    public fun attachNativeMCP(forwarder: BotNativeMCPForwarder?) {
        native = forwarder
    }

    public suspend fun rpc(
        method: String,
        params: JsonValue = JsonObject(emptyMap()),
        id: JsonValue = JsonNull,
        headers: Map<String, String> = emptyMap(),
    ): JsonObject = when (method) {
        BotMCPProtocol.METHOD_INITIALIZE -> initialize(params, id)
        BotMCPProtocol.METHOD_PING -> BotMCPMessages.result(id, JsonObject(emptyMap()))
        BotMCPProtocol.METHOD_TOOLS_LIST -> toolsList(id, headers)
        BotMCPProtocol.METHOD_TOOLS_CALL -> toolsCall(params, id, headers)
        else -> forwardNative(method, params, id, headers)
            ?: BotMCPMessages.error(
                id,
                BotMCPProtocol.ERROR_METHOD_NOT_FOUND,
                BotMCPProtocol.methodNotFoundMessage(method),
            )
    }

    private suspend fun initialize(params: JsonValue, id: JsonValue): JsonObject {
        val requested = ((params as? JsonObject)?.members?.get("protocolVersion") as? JsonString)?.value ?: ""
        val selected = if (protocolVersions.contains(requested)) requested else protocolVersions.first()
        val fields = LinkedHashMap<String, JsonValue>()
        fields["protocolVersion"] = JsonString(selected)
        fields["capabilities"] = BotJson.objectOf("tools" to JsonObject(emptyMap()))
        fields["serverInfo"] = BotJson.objectOf(
            "name" to JsonString(BotMCPProtocol.SERVER_NAME),
            "version" to JsonString(BotMCPProtocol.SERVER_VERSION),
        )
        nativeInstructions(requested)?.let { fields["instructions"] = JsonString(it) }
        return BotMCPMessages.result(id, JsonObject(fields))
    }

    private suspend fun toolsList(id: JsonValue, headers: Map<String, String>): JsonObject {
        return try {
            val callerSession = header(headers, BotMCPProtocol.CALLER_SESSION_HEADER)
            val callerBotId = callerSession?.let { session ->
                tokens.principalForSessionId(session)?.botId
            }
            val definitions = catalog.definitions(callerBotId)
            val tools: MutableList<JsonValue> =
                definitions.map<BotMCPToolDefinition, JsonValue> { it.toJson() }.toMutableList()
            val names = tools.mapNotNull {
                ((it as? JsonObject)?.members?.get("name") as? JsonString)?.value
            }.toMutableSet()
            for (tool in nativeTools() ?: emptyList()) {
                val name = ((tool as? JsonObject)?.members?.get("name") as? JsonString)?.value ?: ""
                if (names.add(name)) tools += tool
            }
            BotMCPMessages.result(id, BotJson.objectOf("tools" to JsonArray(tools)))
        } catch (error: CancellationException) {
            throw error
        } catch (_: Throwable) {
            BotMCPMessages.error(
                id,
                BotMCPProtocol.ERROR_INTERNAL,
                BotMCPProtocol.MESSAGE_TOOL_CATALOG_ENCODING,
            )
        }
    }

    private suspend fun toolsCall(
        params: JsonValue,
        id: JsonValue,
        headers: Map<String, String>,
    ): JsonObject {
        val members = (params as? JsonObject)?.members
        val name = (members?.get("name") as? JsonString)?.value
        if (members == null || name == null) {
            return BotMCPMessages.error(
                id,
                BotMCPProtocol.ERROR_INVALID_PARAMS,
                BotMCPProtocol.MESSAGE_TOOLS_CALL_REQUIRES_NAME,
            )
        }
        val arguments = members["arguments"] ?: JsonObject(emptyMap())
        if (arguments !is JsonObject) {
            return BotMCPMessages.error(
                id,
                BotMCPProtocol.ERROR_INVALID_PARAMS,
                BotMCPProtocol.MESSAGE_ARGUMENTS_NOT_OBJECT,
            )
        }
        val bare = bareToolName(name)
        val botTool = tools.isRegistered(bare)
        val teamTool = !botTool && tools.handlesTeam(bare)
        if (!botTool && !teamTool) {
            val forwarded = try {
                forwardNative(BotMCPProtocol.METHOD_TOOLS_CALL, params, id, headers)
            } catch (error: CancellationException) {
                throw error
            } catch (_: Throwable) {
                null
            }
            if (forwarded != null) return forwarded
            val failure = BotMCPCallResult.failure(
                "unknown_tool",
                BotMCPProtocol.unknownToolMessage(bare),
            )
            return try {
                BotMCPMessages.result(id, resultEncoder(failure))
            } catch (error: CancellationException) {
                throw error
            } catch (_: Throwable) {
                BotMCPMessages.error(
                    id,
                    BotMCPProtocol.ERROR_INVALID_PARAMS,
                    BotMCPProtocol.unknownToolRpcMessage(bare),
                )
            }
        }
        val call = tools.execute(bare, arguments, id)
        return try {
            BotMCPMessages.result(id, resultEncoder(call))
        } catch (error: CancellationException) {
            throw error
        } catch (_: Throwable) {
            BotMCPMessages.error(
                id,
                BotMCPProtocol.ERROR_INTERNAL,
                BotMCPProtocol.MESSAGE_TOOL_RESULT_ENCODING,
            )
        }
    }

    /**
     * Transport-neutral body handling for B5b. A single object is one reply;
     * an array is a batch; notifications produce no reply; an invalid batch
     * element is HTTP 400 with no reply for any element (§7.5).
     */
    public suspend fun dispatch(body: JsonValue): BotMCPDispatchResult {
        return when (body) {
            is JsonObject -> dispatchSingle(body)
            is JsonArray -> dispatchBatch(body.values)
            else -> BotMCPDispatchResult.invalidJsonRpc()
        }
    }

    private suspend fun dispatchSingle(value: JsonValue): BotMCPDispatchResult {
        val message = BotMCPMessages.parse(value)
            ?: return BotMCPDispatchResult.invalidJsonRpc()
        return when (message) {
            is BotMCPMessages.Request -> BotMCPDispatchResult.replies(
                listOf(rpc(message.method, message.params, message.id)),
                isBatch = false,
            )
            is BotMCPMessages.Notification -> BotMCPDispatchResult.replies(
                emptyList(),
                isBatch = false,
            )
        }
    }

    private suspend fun dispatchBatch(values: List<JsonValue>): BotMCPDispatchResult {
        val messages = ArrayList<BotMCPMessages.Message>(values.size)
        for (value in values) {
            val message = BotMCPMessages.parse(value)
                ?: return BotMCPDispatchResult.invalidJsonRpc()
            messages += message
        }
        val replies = ArrayList<JsonValue>()
        for (message in messages) {
            if (message is BotMCPMessages.Request) {
                replies += rpc(message.method, message.params, message.id)
            }
        }
        return BotMCPDispatchResult.replies(replies, isBatch = true)
    }

    // ------------------------------------------------------------------
    // Native forwarding
    // ------------------------------------------------------------------

    private suspend fun forwardNative(
        method: String,
        params: JsonValue,
        id: JsonValue,
        headers: Map<String, String>,
    ): JsonObject? {
        val forwarder = native ?: return null
        val request = BotJson.objectOf(
            "jsonrpc" to JsonString("2.0"),
            "id" to id,
            "method" to JsonString(method),
            "params" to params,
        )
        val response = try {
            forwarder.handle(request, headers)
        } catch (error: CancellationException) {
            throw error
        } catch (_: Throwable) {
            return null
        }
        val responseObject = response as? JsonObject ?: return null
        responseObject.members["error"]?.let { error ->
            return BotJson.objectOf(
                "jsonrpc" to JsonString("2.0"),
                "id" to id,
                "error" to error,
            )
        }
        val result = responseObject.members["result"] ?: return null
        return BotMCPMessages.result(id, result)
    }

    private suspend fun nativeTools(): List<JsonValue>? {
        val forwarder = native ?: return null
        val request = BotJson.objectOf(
            "jsonrpc" to JsonString("2.0"),
            "id" to JsonString("native-tools-list"),
            "method" to JsonString(BotMCPProtocol.METHOD_TOOLS_LIST),
            "params" to JsonObject(emptyMap()),
        )
        val response = try {
            forwarder.handle(request, emptyMap())
        } catch (error: CancellationException) {
            throw error
        } catch (_: Throwable) {
            return null
        }
        val result = ((response as? JsonObject)?.members?.get("result") as? JsonObject) ?: return null
        return (result.members["tools"] as? JsonArray)?.values
    }

    private suspend fun nativeInstructions(protocolVersion: String): String? {
        val forwarder = native ?: return null
        val request = BotJson.objectOf(
            "jsonrpc" to JsonString("2.0"),
            "id" to JsonString("native-initialize"),
            "method" to JsonString(BotMCPProtocol.METHOD_INITIALIZE),
            "params" to BotJson.objectOf("protocolVersion" to JsonString(protocolVersion)),
        )
        val response = try {
            forwarder.handle(request, emptyMap())
        } catch (error: CancellationException) {
            throw error
        } catch (_: Throwable) {
            return null
        }
        val result = ((response as? JsonObject)?.members?.get("result") as? JsonObject) ?: return null
        val instructions = (result.members["instructions"] as? JsonString)?.value
        return instructions?.takeIf { it.isNotEmpty() }
    }

    private fun header(headers: Map<String, String>, name: String): String? {
        var found: String? = null
        for ((key, value) in headers) {
            if (key.equals(name, ignoreCase = true)) {
                found = value
                break
            }
        }
        val trimmed = found?.trim() ?: return null
        return trimmed.ifEmpty { null }
    }
}

/** Notification-only checks used by B5b's `/mcp` 202 answer. */
public fun BotMCPDispatchResult.requiresSessionHeader(): Boolean = status == 200 || status == 202
