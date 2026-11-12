// phone-dsh — :net / com.phonedsh.loopback: the Bot MCP HTTP surface.
// SPDX-License-Identifier: MIT
//
// This file is the transport half of `spec/bot/v1/mcp-endpoint.md` §2 and §11.
// It owns the exact-path/POST/origin/bearer/body-limit checks, the 202/400/401/
// 403/404/405/413 byte forms, the MCP `Mcp-Session-Id` rule, and the SSE answer
// form for a long `tools/call` and a long interactive `/approval`. It does not
// know any JSON-RPC method: the App attaches the B5a1 handler through
// [BotMcpRequestHandler], and `:net` never imports `:bot`.
//
// The transport is deliberately a small HTTP/1.1 surface, not Ktor's router:
// the contract requires exact status/body/header bytes, `Connection: close`,
// and an SSE head with no `Content-Length`/`Transfer-Encoding`. Ktor CIO owns
// both choices (it chunk-encodes a writer and keeps the socket until its idle
// timeout), so [BotMcpListener] speaks the frozen bytes on a raw loopback
// socket and this file only makes the decisions.

package com.phonedsh.loopback

import com.phonedsh.agentcore.JsonArray
import com.phonedsh.agentcore.JsonObject
import com.phonedsh.agentcore.JsonString
import com.phonedsh.agentcore.JsonValue
import com.phonedsh.agentcore.toJsonString
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Deferred
import kotlinx.coroutines.withTimeoutOrNull

/** One authenticated Bot MCP exchange as the application handler sees it. */
class BotMcpRequest(
    /** The exact HTTP path that matched a route (`/mcp`, `/identity/register`, ...). */
    val path: String,
    /** Request headers exactly as received; lookup through [header] is case-insensitive. */
    val headers: Map<String, String>,
    /** The complete JSON body, at most 1 MiB. */
    val body: ByteArray,
    /** The listener's own origin, `http://127.0.0.1:<port>`, no trailing slash. */
    val origin: String,
) {
    /** Case-insensitive header lookup. */
    fun header(name: String): String? =
        headers.entries.firstOrNull { it.key.equals(name, ignoreCase = true) }?.value

    /** The body as UTF-8 text; the parsed value is the handler's concern. */
    fun bodyText(): String = body.toString(Charsets.UTF_8)
}

/**
 * Writes the MCP Streamable HTTP SSE answer form (mcp-endpoint.md §2).
 *
 * A streaming handler sends exactly one [message] event; [keepalive] is the
 * comment line the transport uses while a call is still running.
 */
interface BotMcpSseEmitter {
    /** Sends one `event: message` whose single `data:` line is [json]. */
    suspend fun message(json: String)

    /** Sends `: keepalive` (one comment line and a blank line). */
    suspend fun keepalive()
}

/**
 * The answer one [BotMcpRequestHandler] returns.
 *
 * This is a closed set on purpose: the HTTP layer must be able to tell a
 * finished JSON answer from one that is still being produced, and the
 * `Awaiting` form is what makes the §2 "not ready after 5 s" decision without
 * the handler reimplementing transport timing.
 */
sealed interface BotMcpResponse {
    /** A finished JSON answer (or an application-level 4xx from the handler). */
    class Json(
        val status: Int = 200,
        val body: ByteArray,
    ) : BotMcpResponse

    /**
     * The answer is not ready yet. The serving layer waits
     * [BotMcpSseTiming.streamAfterMillis] for it; if the request is an SSE
     * candidate it opens the stream and sends the eventual body as the single
     * `event: message`.
     */
    class Awaiting(
        val result: Deferred<ByteArray>,
        val status: Int = 200,
    ) : BotMcpResponse

    /**
     * The handler already chose the SSE form. The producer receives the
     * transport emitter and is responsible for §2's exactly-one-message shape;
     * the serving layer only owns the response head.
     */
    class Streaming(
        val producer: suspend BotMcpSseEmitter.() -> Unit,
    ) : BotMcpResponse
}

/**
 * The App's Bot MCP application seam.
 *
 * `mcpSessionId` is the per-handler MCP session id (Swift `BotMCPHandler.mcpSessionId`):
 * the serving layer sends it only on `/mcp` answers, never on `/approval`.
 */
interface BotMcpRequestHandler {
    val mcpSessionId: String

    suspend fun handle(request: BotMcpRequest): BotMcpResponse
}

/**
 * The frozen long-call timing (mcp-endpoint.md §2).
 *
 * Tests scale these down; production always uses [STANDARD]. [probeTimeoutMillis]
 * is the TCP liveness probe of §10, not an HTTP probe.
 */
data class BotMcpSseTiming(
    val streamAfterMillis: Long = 5_000,
    val keepAliveMillis: Long = 15_000,
    val probeTimeoutMillis: Int = 1_500,
) {
    init {
        require(streamAfterMillis >= 0) { "streamAfterMillis must not be negative" }
        require(keepAliveMillis > 0) { "keepAliveMillis must be positive" }
        require(probeTimeoutMillis > 0) { "probeTimeoutMillis must be positive" }
    }

    companion object {
        val STANDARD: BotMcpSseTiming = BotMcpSseTiming()
    }
}

/**
 * What [BotMcpServing] needs from one HTTP connection.
 *
 * It is internal so the wire format has one implementation
 * ([BotMcpListener]'s raw HTTP/1.1 socket) and the application seam stays the
 * public [BotMcpRequestHandler].
 */
internal interface BotMcpExchange {
    val method: String
    val target: String
    val headers: Map<String, String>

    /** The declared `Content-Length`, or null when the body is chunked/empty. */
    val declaredLength: Long?

    fun header(name: String): String? = headers.entries
        .firstOrNull { it.key.equals(name, ignoreCase = true) }?.value

    /**
     * Reads the body, at most [limit] bytes. Returns null when the body is
     * larger than [limit]; the transport must not buffer the excess.
     */
    suspend fun readBody(limit: Int): ByteArray?

    /** Writes a JSON answer and closes the connection. */
    suspend fun respondJson(status: Int, body: ByteArray, session: Boolean)

    /** Writes the SSE head and runs [producer]; the transport closes afterwards. */
    suspend fun respondSse(session: Boolean, producer: suspend BotMcpSseEmitter.() -> Unit)
}

/**
 * The Bot MCP HTTP decisions (mcp-endpoint.md §2/§8/§11).
 *
 * It is transport-neutral: [BotMcpListener] supplies exact HTTP bytes and the
 * tests drive it through a real loopback socket. The §11 order is origin ->
 * bearer -> method -> target -> body/JSON -> route.
 */
internal class BotMcpServing(
    private val handler: BotMcpRequestHandler,
    private val token: String,
    /** The listener's origin, or null before the port is published. */
    private val origin: () -> String?,
    /** The legacy buffered `/mcp/native` server, when this listener also carries it. */
    private val nativeMcp: NativeMcpServing? = null,
    private val timing: BotMcpSseTiming = BotMcpSseTiming.STANDARD,
) {
    init {
        require(token.isNotEmpty()) { "the Bot MCP bearer must not be empty" }
    }

    suspend fun serve(exchange: BotMcpExchange) {
        // 1. Origin. A request without Origin is the host's own egress path.
        val suppliedOrigin = exchange.header(ORIGIN)
        val ownOrigin = origin()
        if (suppliedOrigin != null) {
            if (ownOrigin == null || !suppliedOrigin.equals(ownOrigin, ignoreCase = true)) {
                exchange.respondJson(403, ORIGIN_MISMATCH, session = false)
                return
            }
        }

        // 2. Bearer. The scheme is case-sensitive and the whole value is
        // compared in constant time (PC D13 ruling 11).
        if (!LoopbackToken.matches(exchange.header(AUTHORIZATION), "Bearer $token")) {
            exchange.respondJson(401, UNAUTHORIZED, session = false)
            return
        }

        // 3. Method.
        if (exchange.method.uppercase() != "POST") {
            exchange.respondJson(405, METHOD_NOT_ALLOWED, session = false)
            return
        }

        // 4. Request target. Checked before any normalization; a query,
        // fragment or `..` segment is a 400, a different exact path is a 404.
        val target = exchange.target
        if (!isValidTarget(target)) {
            exchange.respondJson(400, INVALID_TARGET, session = false)
            return
        }

        // 5. Body limit. A declared oversize is refused from the header without
        // reading a body; a chunked/undeclared body is capped at the documented
        // read headroom (the extra 65,536 is not a second accepted limit).
        val declared = exchange.declaredLength
        if (declared != null && declared > MAXIMUM_BODY_BYTES) {
            exchange.respondJson(413, TOO_LARGE, session = false)
            return
        }
        val body = exchange.readBody(MAXIMUM_BODY_BYTES + READ_HEADROOM)
        if (body == null || body.size > MAXIMUM_BODY_BYTES) {
            exchange.respondJson(413, TOO_LARGE, session = false)
            return
        }

        // `/mcp/native` is the pre-existing buffered route. It never forwards a
        // notification and has no SSE form (GAP-36); when no native server is
        // attached the path is not a route.
        if (target == NATIVE_MCP_PATH) {
            if (nativeMcp == null) {
                exchange.respondJson(404, NOT_FOUND, session = false)
                return
            }
            val response = nativeMcp.handle(
                NativeMcpRequest("POST", exchange.headers, body),
            )
            exchange.respondJson(response.status, response.body, session = false)
            return
        }

        // 6. JSON parse. Every Bot route carries a JSON body; an application
        // refusal is still HTTP 200 and comes from the handler.
        val parsed = try {
            JsonValue.parse(body.toString(Charsets.UTF_8))
        } catch (invalid: Exception) {
            exchange.respondJson(400, INVALID_JSON, session = false)
            return
        }

        val request = BotMcpRequest(
            path = target,
            headers = exchange.headers,
            body = body,
            origin = ownOrigin ?: "",
        )

        // 7. Exact route.
        when (target) {
            "/identity/register", "/identity/cancel" -> {
                respondHandler(exchange, request, session = false)
            }
            "/approval" -> {
                respondHandler(exchange, request, session = false, allowStream = wantsEventStream(request))
            }
            "/mcp" -> respondMcp(exchange, request, parsed)
            else -> exchange.respondJson(404, NOT_FOUND, session = false)
        }
    }

    /**
     * `/mcp`: the HTTP envelope rules of §7.5 live here because they are status
     * codes, not JSON-RPC methods: a notification-only body is `202` with an
     * empty body and never reaches the handler; a malformed message is `400`;
     * a single long `tools/call` may switch to SSE after 5 s.
     */
    private suspend fun respondMcp(exchange: BotMcpExchange, request: BotMcpRequest, parsed: JsonValue) {
        val messages: List<JsonObject>
        val isBatch: Boolean
        when (parsed) {
            is JsonArray -> {
                isBatch = true
                messages = parsed.values.map { message ->
                    message as? JsonObject ?: run {
                        exchange.respondJson(400, INVALID_JSON_RPC_MESSAGE, session = false)
                        return
                    }
                }
            }
            is JsonObject -> {
                isBatch = false
                messages = listOf(parsed)
            }
            else -> {
                exchange.respondJson(400, INVALID_JSON_RPC_MESSAGE, session = false)
                return
            }
        }
        for (message in messages) {
            if (message["method"] !is JsonString) {
                exchange.respondJson(400, INVALID_JSON_RPC_MESSAGE, session = false)
                return
            }
        }

        // A notification is a message with no `id` member (a present null is a
        // request). A batch of only notifications is 202 and is never
        // forwarded, including to a native server (PC D13 ruling 10).
        if (messages.isEmpty() || messages.none { it.members.containsKey("id") }) {
            exchange.respondJson(202, ByteArray(0), session = true)
            return
        }

        val streamingCandidate = !isBatch &&
            (messages.single()["method"] as? JsonString)?.value == "tools/call" &&
            wantsEventStream(request)
        respondHandler(exchange, request, session = true, allowStream = streamingCandidate)
    }

    /**
     * Calls the application handler and applies the §2 SSE decision.
     *
     * A `Json` answer is sent at once. An `Awaiting` answer is JSON when the
     * request is not an SSE candidate; otherwise the layer waits
     * [BotMcpSseTiming.streamAfterMillis] and, when it is still not ready,
     * opens the stream with keepalives every [BotMcpSseTiming.keepAliveMillis].
     */
    private suspend fun respondHandler(
        exchange: BotMcpExchange,
        request: BotMcpRequest,
        session: Boolean,
        allowStream: Boolean = false,
    ) {
        val response = try {
            handler.handle(request)
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (failure: Throwable) {
            exchange.respondJson(500, INTERNAL_ERROR, session = false)
            return
        }
        when (response) {
            is BotMcpResponse.Json -> exchange.respondJson(response.status, response.body, session)
            is BotMcpResponse.Awaiting -> {
                if (!allowStream) {
                    val body = try {
                        response.result.await()
                    } catch (cancelled: CancellationException) {
                        throw cancelled
                    } catch (failure: Throwable) {
                        exchange.respondJson(500, INTERNAL_ERROR, session = false)
                        return
                    }
                    exchange.respondJson(response.status, body, session)
                    return
                }
                val early = withTimeoutOrNull(timing.streamAfterMillis) { response.result.await() }
                if (early != null) {
                    exchange.respondJson(response.status, early, session)
                    return
                }
                exchange.respondSse(session) {
                    while (true) {
                        val body = withTimeoutOrNull(timing.keepAliveMillis) { response.result.await() }
                        if (body != null) {
                            message(compactJson(body))
                            return@respondSse
                        }
                        keepalive()
                    }
                }
            }
            is BotMcpResponse.Streaming -> exchange.respondSse(session) {
                response.producer(this)
            }
        }
    }

    /**
     * True when the raw request target obeys §11's target rule.
     *
     * An empty target, a target not starting with `/`, a query/fragment and a
     * `..` segment are invalid; they are never normalized into a route. A
     * trailing slash is a valid target and becomes a 404 below.
     */
    private fun isValidTarget(target: String): Boolean {
        if (target.isEmpty() || !target.startsWith("/")) return false
        if (target.contains('?') || target.contains('#')) return false
        return target.split('/').none { it == ".." }
    }

    /**
     * True when `Accept` explicitly lists `text/event-stream` (§2). A wildcard
     * media range is not an explicit accept, and parameters are ignored.
     */
    private fun wantsEventStream(request: BotMcpRequest): Boolean {
        val accept = request.header("Accept") ?: return false
        return accept.split(',').any { range ->
            val mediaType = range.substringBefore(';').trim()
            mediaType.equals("text/event-stream", ignoreCase = true)
        }
    }

    /**
     * One compact JSON text. SSE has a single `data:` line; the handler's body
     * is already JSON, and re-encoding here makes a pretty-printed body safe
     * without changing its value.
     */
    private fun compactJson(body: ByteArray): String {
        val text = body.toString(Charsets.UTF_8)
        return try {
            JsonValue.parse(text).toJsonString()
        } catch (invalid: Exception) {
            // The handler owns the body; this layer must never silently alter
            // it. If it is not JSON, keep the bytes but flatten line breaks so
            // the event framing stays one data line.
            text.replace("\r", " ").replace("\n", " ")
        }
    }

    companion object {
        /** mcp-endpoint.md §11: the one accepted request-body limit. */
        const val MAXIMUM_BODY_BYTES: Int = 1_048_576

        /** Transport read headroom used only to answer 413 instead of closing. */
        const val READ_HEADROOM: Int = 65_536

        /** The pre-existing buffered native route; no SSE form (GAP-36). */
        const val NATIVE_MCP_PATH: String = "/mcp/native"

        /** The MCP session header (mcp-endpoint.md §11). */
        const val MCP_SESSION_ID: String = "Mcp-Session-Id"

        private const val ORIGIN = "Origin"
        private const val AUTHORIZATION = "Authorization"

        private val ORIGIN_MISMATCH = """{"error":"origin mismatch"}""".toByteArray(Charsets.UTF_8)
        private val UNAUTHORIZED = """{"error":"unauthorized"}""".toByteArray(Charsets.UTF_8)
        private val METHOD_NOT_ALLOWED = """{"error":"method not allowed"}""".toByteArray(Charsets.UTF_8)
        private val INVALID_TARGET = """{"error":"invalid request target"}""".toByteArray(Charsets.UTF_8)
        private val NOT_FOUND = """{"error":"not found"}""".toByteArray(Charsets.UTF_8)
        private val TOO_LARGE = """{"error":"request too large"}""".toByteArray(Charsets.UTF_8)
        private val INVALID_JSON = """{"error":"invalid JSON"}""".toByteArray(Charsets.UTF_8)
        private val INVALID_JSON_RPC_MESSAGE =
            """{"error":"invalid JSON-RPC message"}""".toByteArray(Charsets.UTF_8)
        private val INTERNAL_ERROR = """{"error":"internal error"}""".toByteArray(Charsets.UTF_8)
    }
}
