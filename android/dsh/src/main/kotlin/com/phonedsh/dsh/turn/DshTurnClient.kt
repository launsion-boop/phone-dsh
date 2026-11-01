// phone-dsh — :dsh / com.phonedsh.dsh.turn: the DSH remote API over the real channel.
// SPDX-License-Identifier: MIT
//
// ---- what this class is -----------------------------------------------------
// The host client for DSH's `/api` lane. A turn is three calls over the same
// ordered channel the worker opened:
//
//   session/create  -> a session id
//   session/follow  -> one long-lived NDJSON stream (snapshot, then live events)
//   session/prompt  -> the user message that starts the turn
//
// The frames are `API_REQ`/`API_RES`/`API_END` of `channel.md` §3.7-3.9, sent
// and received by [HostChannel]. This class does not open a socket, does not
// touch the WebView and does not run a model: it is the *host* half of the
// remote API, which the test surface used to own.
//
// ---- where the event names come from ---------------------------------------
// The Worker's `session/follow` items contain its own events (`turn/start`,
// `tool/call`, ...). They are projected by `:core`'s `hostevents` package, the
// table of `spec/host/v1/event-kinds.md` §1. No name is renamed here.
//
// ---- what it may not claim --------------------------------------------------
// The model behind the Worker is scripted in the acceptance lane. A completed
// turn proves the channel, the host exec lane and the event projection; it does
// not prove an inference provider.

package com.phonedsh.dsh.turn

import com.phonedsh.agentcore.JsonArray
import com.phonedsh.agentcore.JsonBool
import com.phonedsh.agentcore.JsonNull
import com.phonedsh.agentcore.JsonObject
import com.phonedsh.agentcore.JsonString
import com.phonedsh.agentcore.JsonValue
import com.phonedsh.agentcore.toJsonString
import com.phonedsh.dsh.host.HostApiException
import com.phonedsh.dsh.host.HostApiStream
import com.phonedsh.dsh.host.HostChannel
import com.phonedsh.hostevents.HostEvent
import com.phonedsh.hostevents.HostEventKind
import com.phonedsh.hostevents.HostEventProjection
import java.security.SecureRandom
import java.util.concurrent.atomic.AtomicInteger
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.channels.ReceiveChannel
import kotlinx.coroutines.delay
import kotlinx.coroutines.withTimeoutOrNull

/** A typed `/api` failure raised by this client; [code] is stable and token-free. */
class DshTurnException(val code: String, message: String) : Exception("$code: $message")

/** One completed turn: the session and the worker events that ended it. */
data class TurnRun(
    val sessionId: String,
    val events: List<HostEvent>,
) {
    /** The projected host kinds, in wire order. */
    val kinds: List<String> get() = events.map { it.kind.wire }

    /** The `turn_ended` event, if the stream reached the turn's edge. */
    val turnEnded: HostEvent? get() = events.lastOrNull { it.kind == HostEventKind.TURN_ENDED }

    /** `data.reason.kind` of the turn's edge (`completed`, `interrupted`, ...). */
    val turnEndReason: String? get() = turnEnded?.turnEndReason

    /** True when the four edges the acceptance names all appeared, in order. */
    val sawTheFourEdges: Boolean
        get() {
            val firsts = kinds.indexOf(HostEventKind.TURN_STARTED.wire)
            val call = kinds.indexOf(HostEventKind.TOOL_CALL.wire)
            val result = kinds.indexOf(HostEventKind.TOOL_RESULT.wire)
            val end = kinds.lastIndexOf(HostEventKind.TURN_ENDED.wire)
            return firsts >= 0 && call > firsts && result > call && end > result
        }
}

/**
 * The host-side `/api` client for one connected worker.
 *
 * @param api the host channel that owns the frames and the seq.
 * @param log a token-free log seam (`logcat` in the App, a list in a test).
 */
class DshTurnClient(
    private val api: HostChannel,
    private val log: (String) -> Unit = {},
) {
    private val rpcIds = AtomicInteger(0)
    private val promptIds = AtomicInteger(0)
    private val random = SecureRandom()

    /**
     * One unary remote-API call, unwrapping the `server-response`.
     *
     * @throws DshTurnException on a malformed envelope, an rpc mismatch or an
     *   error result; the message carries the Worker's bounded code, not a
     *   header or a prompt.
     */
    suspend fun call(
        endpoint: String,
        args: JsonObject = JsonObject(emptyMap()),
        timeoutMillis: Long = CALL_TIMEOUT_MILLIS,
    ): JsonValue {
        val rpcId = "pdsh-rpc-${rpcIds.incrementAndGet()}"
        val request = JsonObject(
            linkedMapOf(
                "type" to JsonString("client-request"),
                "rpcId" to JsonString(rpcId),
                "method" to JsonString(endpoint),
                "payload" to JsonObject(linkedMapOf("args" to args)),
            ),
        )
        val response = api.apiRequest(
            method = "POST",
            path = "/api/$endpoint",
            headers = mapOf("content-type" to "application/json"),
            body = request.toJsonString().toByteArray(Charsets.UTF_8),
            timeoutMillis = timeoutMillis,
        )
        val envelope = parseObject(response.bodyText())
            ?: throw DshTurnException("invalid_response", "$endpoint answered no JSON envelope")
        if (envelope.text("type") != "server-response") {
            throw DshTurnException("invalid_response", "$endpoint answered ${envelope.text("type")}")
        }
        if (envelope.text("rpcId") != rpcId) {
            throw DshTurnException("invalid_response", "$endpoint answered another rpcId")
        }
        val result = envelope["result"] as? JsonObject
            ?: throw DshTurnException("invalid_response", "$endpoint carried no result")
        if ((result["ok"] as? JsonBool)?.value != true) {
            val error = result["error"] as? JsonObject
            throw DshTurnException(
                error?.text("code") ?: "unknown",
                error?.text("message") ?: "$endpoint failed",
            )
        }
        return result["value"] ?: JsonNull
    }

    /** `session/create`; returns the Worker's new session id. */
    suspend fun createSession(
        cwd: String? = null,
        timeoutMillis: Long = CALL_TIMEOUT_MILLIS,
    ): String {
        val request = LinkedHashMap<String, JsonValue>()
        if (cwd != null) request["cwd"] = JsonString(cwd)
        val args = JsonObject(linkedMapOf("request" to JsonObject(request)))
        val value = call("session/create", args, timeoutMillis) as? JsonObject
            ?: throw DshTurnException("invalid_response", "session/create returned no object")
        return value.text("sessionId")
            ?: throw DshTurnException("invalid_response", "session/create returned no sessionId")
    }

    /**
     * `session/create`, retried until the Worker's `/api` subscriber is installed.
     *
     * The delay between attempts doubles from [CREATE_RETRY_FIRST_DELAY_MILLIS] to
     * [CREATE_RETRY_MAX_DELAY_MILLIS]. It used to be a flat second, which meant a
     * channel that was gone (P22: the ordered channel closed and the engine was
     * reloading the page) produced 180 attempts in three minutes of logcat for a
     * transport that could not answer any of them — measured 2026-11-01, emulator
     * API 35. With the backoff the first 30 s hold at most
     * [createAttemptsWithin30s] attempts and a short reload is still picked up
     * within half a second.
     */
    suspend fun createSessionWhenReady(
        cwd: String? = null,
        totalTimeoutMillis: Long = CREATE_RETRY_TIMEOUT_MILLIS,
        perAttemptMillis: Long = FIRST_CALL_TIMEOUT_MILLIS,
    ): String {
        val deadline = System.currentTimeMillis() + totalTimeoutMillis
        var attempt = 0
        var delayMillis = CREATE_RETRY_FIRST_DELAY_MILLIS
        var last: Exception? = null
        while (System.currentTimeMillis() < deadline) {
            attempt++
            try {
                return createSession(cwd = cwd, timeoutMillis = perAttemptMillis)
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (failure: Exception) {
                last = failure
                log(
                    "session/create attempt $attempt not answered (${safeReason(failure)}); " +
                        "next attempt in $delayMillis ms",
                )
                delay(delayMillis)
                delayMillis = nextCreateRetryDelay(delayMillis)
            }
        }
        throw DshTurnException(
            "session_create_unavailable",
            "session/create was never answered by the worker's /api lane",
        ).also { if (last != null) it.initCause(last) }
    }

    /** `session/prompt` in `queue` mode: the user message that starts the turn. */
    suspend fun prompt(
        sessionId: String,
        text: String,
        timeoutMillis: Long = CALL_TIMEOUT_MILLIS,
    ) {
        val request = JsonObject(
            linkedMapOf(
                "requestId" to JsonString("pdsh-prompt-${promptIds.incrementAndGet()}"),
                "sessionId" to JsonString(sessionId),
                "mode" to JsonString("queue"),
                "content" to JsonArray(
                    listOf(
                        JsonObject(
                            linkedMapOf(
                                "type" to JsonString("text"),
                                "text" to JsonString(text),
                            ),
                        ),
                    ),
                ),
            ),
        )
        call("session/prompt", JsonObject(linkedMapOf("request" to request)), timeoutMillis)
    }

    /** Opens the `session/follow` mux stream (two `open` sends, one `receive` stream). */
    suspend fun follow(sessionId: String, maxMessages: Int = 64): FollowStream {
        val muxId = ByteArray(16).also(random::nextBytes).hex()
        sendMuxFrame(
            muxId,
            JsonObject(
                linkedMapOf(
                    "type" to JsonString("open"),
                    "streamId" to JsonString("events"),
                    "endpoint" to JsonString("\$events"),
                    "payload" to JsonObject(linkedMapOf("args" to JsonObject(emptyMap()))),
                ),
            ).toJsonString(),
        )
        val follow = JsonObject(
            linkedMapOf(
                "address" to JsonObject(
                    linkedMapOf(
                        "kind" to JsonString("session"),
                        "sessionId" to JsonString(sessionId),
                    ),
                ),
                "maxMessages" to com.phonedsh.agentcore.JsonNumber(maxMessages.toString()),
                "assistantStream" to JsonBool(false),
            ),
        )
        sendMuxFrame(
            muxId,
            JsonObject(
                linkedMapOf(
                    "type" to JsonString("open"),
                    "streamId" to JsonString("follow"),
                    "endpoint" to JsonString("session/follow"),
                    "payload" to JsonObject(
                        linkedMapOf("args" to JsonObject(linkedMapOf("request" to follow))),
                    ),
                ),
            ).toJsonString(),
        )
        val stream = api.openApiStream(
            method = "POST",
            path = MUX_PATH,
            headers = mapOf(
                "content-type" to "application/json",
                "x-pdsh-mux-id" to muxId,
                "x-pdsh-mux-op" to "receive",
            ),
        )
        val followStream = FollowStream(muxId, stream, log)
        followStream.apiClose = { closedMux ->
            api.apiRequest(
                method = "POST",
                path = MUX_PATH,
                headers = mapOf(
                    "content-type" to "application/json",
                    "x-pdsh-mux-id" to closedMux,
                    "x-pdsh-mux-op" to "close",
                ),
                timeoutMillis = CLOSE_TIMEOUT_MILLIS,
            )
        }
        return followStream
    }

    /**
     * One complete turn: create, follow, prompt, collect until `turn_ended`.
     *
     * @return the session id and every projected event the Worker reported.
     * @throws DshTurnException when the stream aborts, the turn never ends, or
     *   the Worker answers with a malformed item.
     */
    suspend fun runTurn(
        promptText: String,
        cwd: String? = DEFAULT_WORKSPACE,
        createTimeoutMillis: Long = CREATE_RETRY_TIMEOUT_MILLIS,
        turnTimeoutMillis: Long = TURN_TIMEOUT_MILLIS,
    ): TurnRun {
        val sessionId = createSessionWhenReady(cwd = cwd, totalTimeoutMillis = createTimeoutMillis)
        log("session/create -> $sessionId")
        val follow = follow(sessionId)
        try {
            prompt(sessionId, promptText)
            log("session/prompt queued")
            val events = follow.collectEvents(turnTimeoutMillis) {
                it.kind == HostEventKind.TURN_ENDED
            }
            return TurnRun(sessionId = sessionId, events = events)
        } finally {
            follow.close()
        }
    }

    private suspend fun sendMuxFrame(muxId: String, frame: String) {
        api.apiRequest(
            method = "POST",
            path = MUX_PATH,
            headers = mapOf(
                "content-type" to "application/json",
                "x-pdsh-mux-id" to muxId,
                "x-pdsh-mux-op" to "send",
            ),
            body = frame.toByteArray(Charsets.UTF_8),
        )
    }

    /** The NDJSON `session/follow` receive stream. */
    inner class FollowStream internal constructor(
        private val muxId: String,
        private val stream: HostApiStream,
        private val log: (String) -> Unit,
    ) {
        private val chunks: ReceiveChannel<ByteArray> = stream.chunks()
        private val pending = StringBuilder()
        private var finished = false

        /**
         * The next complete mux item, or `null` when the stream ended or the
         * deadline elapsed.
         */
        suspend fun next(timeoutMillis: Long = NEXT_TIMEOUT_MILLIS): JsonObject? {
            if (finished) return null
            val deadline = System.currentTimeMillis() + timeoutMillis
            while (true) {
                val newline = pending.indexOf("\n")
                if (newline >= 0) {
                    val line = pending.substring(0, newline).trim()
                    pending.delete(0, newline + 1)
                    if (line.isEmpty()) continue
                    val parsed = parseObject(line) ?: continue
                    if (parsed.text("type") == "end") finished = true
                    return parsed
                }
                val remaining = deadline - System.currentTimeMillis()
                if (remaining <= 0) return null
                val result = withTimeoutOrNull(remaining) { chunks.receiveCatching() } ?: return null
                if (result.isClosed) {
                    finished = true
                    val cause = result.exceptionOrNull()
                    if (cause != null && cause !is HostApiException) throw cause
                    if (cause is HostApiException) {
                        throw DshTurnException(cause.code, cause.message ?: "the follow stream ended")
                    }
                    return null
                }
                pending.append(String(result.getOrNull() ?: return null, Charsets.UTF_8))
            }
        }

        /**
         * Drains the follow stream into projected host events until [stopWhen]
         * is true or the deadline elapses.
         */
        suspend fun collectEvents(
            timeoutMillis: Long = TURN_TIMEOUT_MILLIS,
            stopWhen: (HostEvent) -> Boolean,
        ): List<HostEvent> {
            val events = ArrayList<HostEvent>()
            val deadline = System.currentTimeMillis() + timeoutMillis
            while (System.currentTimeMillis() < deadline) {
                val item = next() ?: break
                val type = item.text("type")
                if (type == "error") {
                    val error = item["error"] as? JsonObject
                    throw DshTurnException(
                        error?.text("code") ?: "stream_error",
                        error?.text("message") ?: "the follow stream reported an error",
                    )
                }
                if (type == "end") break
                if (type != "item") continue
                for (event in eventsOf(item)) {
                    events += event
                    if (stopWhen(event)) return events
                }
            }
            log("session/follow ended with ${events.size} event(s)")
            return events
        }

        /** Closes the logical mux and forgets the receive stream. */
        suspend fun close() {
            stream.close()
            runCatching {
                apiClose?.invoke(muxId)
            }
        }

        /** Set by [DshTurnClient.follow] to send the mux close op. */
        internal var apiClose: (suspend (String) -> Unit)? = null

        private fun eventsOf(item: JsonObject): List<HostEvent> {
            val streamId = item.text("streamId")
            if (streamId != null && streamId != "follow") return emptyList()
            val value = item["value"] as? JsonObject ?: return emptyList()
            return when (value.text("type")) {
                "snapshot" -> HostEventProjection.projectSnapshot(value)
                "event" -> {
                    val event = value["event"] as? JsonObject ?: return emptyList()
                    HostEventProjection.projectAll(event)
                }

                "end" -> {
                    finished = true
                    emptyList()
                }

                else -> emptyList()
            }
        }
    }

    private fun JsonObject.text(name: String): String? = (this[name] as? JsonString)?.value

    private fun parseObject(text: String): JsonObject? = try {
        JsonValue.parse(text) as? JsonObject
    } catch (_: Exception) {
        null
    }

    private fun ByteArray.hex(): String = buildString(size * 2) {
        for (byte in this@hex) {
            val value = byte.toInt() and 0xFF
            append(HEX[value ushr 4]).append(HEX[value and 0x0F])
        }
    }

    private fun safeReason(failure: Exception): String = when (failure) {
        is HostApiException -> failure.code
        is DshTurnException -> failure.code
        else -> failure.javaClass.simpleName
    }

    private companion object {
        const val MUX_PATH = "/api/remote.mux"
        const val DEFAULT_WORKSPACE = "/dsh/workspace"
        const val CALL_TIMEOUT_MILLIS = 60_000L
        const val FIRST_CALL_TIMEOUT_MILLIS = 20_000L
        const val CREATE_RETRY_TIMEOUT_MILLIS = 180_000L
        const val TURN_TIMEOUT_MILLIS = 180_000L
        const val NEXT_TIMEOUT_MILLIS = 45_000L
        const val CLOSE_TIMEOUT_MILLIS = 5_000L
        const val HEX = "0123456789abcdef"
    }
}

/**
 * The `session/create` retry schedule: 250 ms, doubling to a 2 s cap.
 *
 * A constant of the client and not of its caller, because the two properties that
 * matter are about the whole retry loop: a reloaded page (P22: 1-3 s) is picked up
 * by the next attempt, and a dead channel produces a bounded number of attempts
 * instead of one per second.
 */
internal fun nextCreateRetryDelay(previousMillis: Long): Long =
    (previousMillis * 2).coerceAtMost(CREATE_RETRY_MAX_DELAY_MILLIS)

/** First gap between `session/create` attempts. */
internal const val CREATE_RETRY_FIRST_DELAY_MILLIS: Long = 250L

/** Cap of that gap: a reloaded page is picked up within this window at worst. */
internal const val CREATE_RETRY_MAX_DELAY_MILLIS: Long = 2_000L

/** How many `session/create` attempts start inside [windowMillis] (the no-storm bound). */
internal fun createAttemptsWithin(windowMillis: Long): Int {
    var spent = 0L
    var attempts = 0
    var wait = CREATE_RETRY_FIRST_DELAY_MILLIS
    while (attempts < 10_000) {
        attempts += 1
        if (spent + wait > windowMillis) return attempts
        spent += wait
        wait = nextCreateRetryDelay(wait)
    }
    return attempts
}
