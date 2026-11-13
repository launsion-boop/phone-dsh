// SPDX-License-Identifier: MIT
package com.phonedsh.bot.mcp

import com.phonedsh.agentcore.JsonArray
import com.phonedsh.agentcore.JsonBool
import com.phonedsh.agentcore.JsonNull
import com.phonedsh.agentcore.JsonNumber
import com.phonedsh.agentcore.JsonObject
import com.phonedsh.agentcore.JsonString
import com.phonedsh.agentcore.JsonValue
import com.phonedsh.bot.BotJson
import java.util.UUID

/**
 * The frozen P05 JSON-RPC surface of the Bot `/mcp` endpoint
 * (`spec/bot/v1/mcp-endpoint.md` §7). The transport itself is B5b; this
 * object owns the bytes that are independent of the listener.
 */
public object BotMCPProtocol {
    /** Echo order: the first entry is the fallback for every other requested value. */
    public val PROTOCOL_VERSIONS: List<String> = listOf("2025-11-25", "2025-06-18", "2025-03-26")
    public const val DEFAULT_PROTOCOL_VERSION: String = "2025-11-25"
    public const val SERVER_NAME: String = "phone"
    public const val SERVER_VERSION: String = "1.0.0"
    public const val DEFAULT_RUNTIME_ID: String = "phone-worker"

    /** Optional HTTP header carrying the App-minted MCP session id (§7.3). */
    public const val CALLER_SESSION_HEADER: String = "x-pdsh-bot-session"
    public const val MAXIMUM_BODY_BYTES: Int = 1_048_576

    public const val METHOD_INITIALIZE: String = "initialize"
    public const val METHOD_PING: String = "ping"
    public const val METHOD_TOOLS_LIST: String = "tools/list"
    public const val METHOD_TOOLS_CALL: String = "tools/call"

    public const val ERROR_METHOD_NOT_FOUND: Int = -32601
    public const val ERROR_INVALID_PARAMS: Int = -32602
    public const val ERROR_INTERNAL: Int = -32603

    public const val MESSAGE_TOOLS_CALL_REQUIRES_NAME: String = "tools/call requires name"
    public const val MESSAGE_ARGUMENTS_NOT_OBJECT: String = "arguments must be an object"
    public const val MESSAGE_TOOL_CATALOG_ENCODING: String = "tool catalog encoding failed"
    public const val MESSAGE_TOOL_RESULT_ENCODING: String = "tool result encoding failed"
    public const val MESSAGE_INVALID_JSON_RPC: String = "invalid JSON-RPC message"
    public const val UNKNOWN_TOOL_TEXT_PREFIX: String = "Unknown tool: "

    /** The unknown-tool failure message is the frozen English sentence (§7.4). */
    public fun unknownToolMessage(bareName: String): String = UNKNOWN_TOOL_TEXT_PREFIX + bareName

    public fun methodNotFoundMessage(method: String): String = "method not found: $method"

    public fun unknownToolRpcMessage(bareName: String): String = "unknown tool: $bareName"
}

/** One session principal, as resolved by the App token registry (§9.1). */
public enum class BotMCPPrincipalKind(public val wire: String) {
    CHAT("chat"),
    TASK("task"),
    ROUTINE("routine"),
    VERIFIER("verifier"),
    TEAM("team"),
    PROACTIVE("proactive"),
    WATCHDOG("watchdog"),
    MAINTAINER("maintainer"),
    ;

    public companion object {
        public fun fromWire(value: String?): BotMCPPrincipalKind? =
            entries.firstOrNull { it.wire == value }
    }
}

/**
 * A resolved caller. `capabilities` is the frozen token capability list; the
 * only value this lane interprets is `task.delegate` (§4.1).
 */
public data class BotMCPPrincipal(
    public val botId: String,
    public val sessionId: String,
    public val kind: BotMCPPrincipalKind,
    public val capabilities: Set<String> = emptySet(),
    public val expiresAt: Long = 0,
)

/**
 * The attribution the gateway resolved from a `tools/call` argument digest.
 * [isUserTurn] and [hiddenTurn] are host-observed turn facts, never model
 * input. [callId] is the `/identity/register` call id, not the JSON-RPC id.
 */
public data class BotResolvedToolCall(
    public val principal: BotMCPPrincipal,
    public val callId: String,
    public val attributionId: String? = null,
    public val isUserTurn: Boolean = true,
    public val hiddenTurn: Boolean = false,
)

/** The per-call context handed to a tool handler and every host port. */
public data class BotToolCallContext(
    public val runtimeId: String,
    public val callId: String,
    public val call: BotResolvedToolCall,
) {
    public val principal: BotMCPPrincipal get() = call.principal
    public val sessionId: String get() = call.principal.sessionId
    public val isUserTurn: Boolean get() = call.isUserTurn
    public val hiddenTurn: Boolean get() = call.hiddenTurn
}

/** One advertised tool entry (`BotMCPToolDefinition` in the Swift reference). */
public data class BotMCPToolDefinition(
    public val name: String,
    public val description: String,
    public val inputSchema: JsonValue,
) {
    public fun toJson(): JsonObject = BotJson.objectOf(
        "name" to JsonString(name),
        "description" to JsonString(description),
        "inputSchema" to inputSchema,
    )

    public companion object {
        public fun fromJson(value: JsonValue): BotMCPToolDefinition? {
            val members = (value as? JsonObject)?.members ?: return null
            val name = (members["name"] as? JsonString)?.value ?: return null
            val description = (members["description"] as? JsonString)?.value ?: ""
            val schema = members["inputSchema"] ?: JsonObject(emptyMap())
            return BotMCPToolDefinition(name, description, schema)
        }
    }
}

/**
 * The `BotMCPCallResult` shape of §7.4. `content` is always present,
 * `structuredContent` is present for every Bot tool result, and [isError] is
 * `true` exactly for a failure (absent from the JSON for a success).
 */
public class BotMCPCallResult private constructor(
    public val content: List<JsonValue>,
    public val structuredContent: JsonValue?,
    public val isError: Boolean,
) {
    public fun toJson(): JsonObject {
        val fields = LinkedHashMap<String, JsonValue>()
        fields["content"] = JsonArray(content)
        structuredContent?.let { fields["structuredContent"] = it }
        if (isError) fields["isError"] = JsonBool(true)
        return JsonObject(fields)
    }

    public fun text(): String? =
        ((content.firstOrNull() as? JsonObject)?.members?.get("text") as? JsonString)?.value

    public companion object {
        public fun success(value: JsonValue, text: String? = null): BotMCPCallResult =
            BotMCPCallResult(
                content = listOf(textBlock(text ?: BotJson.canonical(value))),
                structuredContent = value,
                isError = false,
            )

        public fun failure(code: String, message: String): BotMCPCallResult =
            BotMCPCallResult(
                content = listOf(textBlock(message)),
                structuredContent = failureValue(code, message),
                isError = true,
            )

        /** Used only by tests/adapters that already built the frozen content blocks. */
        public fun raw(
            content: List<JsonValue>,
            structuredContent: JsonValue?,
            isError: Boolean = false,
        ): BotMCPCallResult = BotMCPCallResult(content, structuredContent, isError)

        public fun failureValue(code: String, message: String): JsonObject = BotJson.objectOf(
            "ok" to JsonBool(false),
            "error" to BotJson.objectOf(
                "code" to JsonString(code),
                "message" to JsonString(message),
            ),
        )

        public fun textBlock(text: String): JsonObject = BotJson.objectOf(
            "type" to JsonString("text"),
            "text" to JsonString(text),
        )
    }
}

/**
 * A typed tool failure. The MCP layer maps [code]/[message] straight into the
 * `structuredContent.error` pair of a `BotMCPCallResult`; it never becomes a
 * JSON-RPC `error` member (§7.4, PC ruling 4).
 */
public class BotMCPToolException(
    public val code: String,
    message: String,
) : Exception(message)

/** A memory store read failure is `memory_unavailable`, not `execution_failed` (§3.3). */
public class BotMemoryUnavailableException(message: String, cause: Throwable? = null) :
    Exception(message, cause)

/** The JSON-RPC request/response/notification envelope of §7. */
public object BotMCPMessages {
    public sealed interface Message {
        public val method: String
        public val params: JsonValue
    }

    /** A request iff the `id` member is present, including `"id": null` (§7). */
    public data class Request(
        public override val method: String,
        public override val params: JsonValue,
        public val id: JsonValue,
    ) : Message

    public data class Notification(
        public override val method: String,
        public override val params: JsonValue,
    ) : Message

    /** Returns null when the value is not an object with a string `method`. */
    public fun parse(value: JsonValue): Message? {
        val members = (value as? JsonObject)?.members ?: return null
        val method = (members["method"] as? JsonString)?.value ?: return null
        val params = members["params"] ?: JsonObject(emptyMap())
        return if (members.containsKey("id")) {
            Request(method, params, members.getValue("id"))
        } else {
            Notification(method, params)
        }
    }

    public fun result(id: JsonValue, result: JsonValue): JsonObject = BotJson.objectOf(
        "jsonrpc" to JsonString("2.0"),
        "id" to id,
        "result" to result,
    )

    public fun error(id: JsonValue, code: Int, message: String): JsonObject = BotJson.objectOf(
        "jsonrpc" to JsonString("2.0"),
        "id" to id,
        "error" to BotJson.objectOf(
            "code" to JsonNumber(code.toString()),
            "message" to JsonString(message),
        ),
    )

    public fun notification(method: String, params: JsonValue = JsonObject(emptyMap())): JsonObject =
        BotJson.objectOf(
            "jsonrpc" to JsonString("2.0"),
            "method" to JsonString(method),
            "params" to params,
        )
}

/**
 * Transport-neutral result of one HTTP body. B5b maps [status] to the exact
 * status/header table of `mcp-endpoint.md` §11; an empty body is 202.
 */
public data class BotMCPDispatchResult(
    public val status: Int,
    public val body: JsonValue?,
    public val isBatch: Boolean = false,
) {
    public val emptyBody: Boolean get() = body == null

    public companion object {
        public fun replies(replies: List<JsonValue>, isBatch: Boolean): BotMCPDispatchResult =
            if (replies.isEmpty()) {
                BotMCPDispatchResult(status = 202, body = null, isBatch = isBatch)
            } else {
                BotMCPDispatchResult(
                    status = 200,
                    body = if (isBatch) JsonArray(replies) else replies.first(),
                    isBatch = isBatch,
                )
            }

        public fun invalidJsonRpc(): BotMCPDispatchResult = BotMCPDispatchResult(
            status = 400,
            body = BotJson.objectOf("error" to JsonString(BotMCPProtocol.MESSAGE_INVALID_JSON_RPC)),
        )
    }
}

/** Unicode-scalar (not UTF-16 unit) helpers for the volatile caps. */
public object BotMCPScalars {
    public fun length(text: String): Int = text.codePointCount(0, text.length)

    public fun prefix(text: String, limit: Int): String {
        if (limit <= 0) return ""
        if (length(text) <= limit) return text
        var index = 0
        var remaining = limit
        while (index < text.length && remaining > 0) {
            index += Character.charCount(text.codePointAt(index))
            remaining -= 1
        }
        return text.substring(0, index)
    }
}

public fun randomHexId(prefix: String = ""): String =
    prefix + UUID.randomUUID().toString().replace("-", "")

/** The Swift handler's call-id projection (`BotMCPHandler.callId`). */
public fun botMcpCallId(id: JsonValue): String = when (id) {
    is JsonString -> id.value
    is JsonNumber -> id.asLongOrNull()?.toString() ?: id.raw
    else -> UUID.randomUUID().toString()
}

/** `mcp__phone__ask_user` -> `ask_user`; the last `__`-separated component wins. */
public fun bareToolName(name: String): String {
    if (!name.startsWith("mcp__")) return name
    return name.substringAfterLast("__")
}

/** A JSON `null` used where the frozen body keeps an explicitly null member. */
public fun jsonNull(): JsonValue = JsonNull

internal fun textOrNull(value: JsonValue?): String? = (value as? JsonString)?.value

internal fun boolOrNull(value: JsonValue?): Boolean? = (value as? JsonBool)?.value

internal fun arrayValues(value: JsonValue?): List<JsonValue>? = (value as? JsonArray)?.values
