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
import com.phonedsh.agentcore.JsonNumber
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
import java.util.UUID
import java.util.concurrent.atomic.AtomicInteger
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.channels.ReceiveChannel
import kotlinx.coroutines.delay
import kotlinx.coroutines.withContext
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

/** One live approval/question waterfall delivered on the `$events` stream. */
data class PendingRemoteRequest(
    val eventID: String,
    val clientID: String,
    val request: JsonValue,
    val eventKind: String,
)

/** Parses a waterfall addressed to this active session; unknown event kinds can be passed to the next listener. */
fun pendingRemoteRequest(
    value: JsonObject,
    sessionId: String,
    clientId: String?,
): PendingRemoteRequest? {
    if (value.text("type") != "waterfall" || value.text("agentId") != sessionId) return null
    val eventKind = value.text("event") ?: return null
    val eventID = value.text("eventId") ?: return null
    val clientID = clientId ?: return null
    val request = value["request"] ?: return null
    return PendingRemoteRequest(eventID, clientID, request, eventKind)
}

/** Exact mux-open frame for live permission/question events. */
fun remoteEventsOpenFrame(): JsonObject = JsonObject(
    linkedMapOf(
        "type" to JsonString("open"),
        "streamId" to JsonString("events"),
        "endpoint" to JsonString("\$events"),
        "payload" to JsonObject(linkedMapOf("args" to JsonObject(emptyMap()))),
    ),
)

/** Exact mux-open frame for the session event/history stream. */
fun sessionFollowOpenFrame(
    sessionId: String,
    maxMessages: Int = 64,
    assistantStream: Boolean = false,
): JsonObject {
    val request = JsonObject(
        linkedMapOf(
            "address" to JsonObject(
                linkedMapOf(
                    "kind" to JsonString("session"),
                    "sessionId" to JsonString(sessionId),
                ),
            ),
            "maxMessages" to JsonNumber(maxMessages.toString()),
            "assistantStream" to JsonBool(assistantStream),
        ),
    )
    return JsonObject(
        linkedMapOf(
            "type" to JsonString("open"),
            "streamId" to JsonString("follow"),
            "endpoint" to JsonString("session/follow"),
            "payload" to JsonObject(
                linkedMapOf("args" to JsonObject(linkedMapOf("request" to request))),
            ),
        ),
    )
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
    private val random = SecureRandom()

    /** Answers the exact live waterfall request carried by the active mux. */
    suspend fun answerRemoteRequest(request: PendingRemoteRequest, outcome: JsonValue) {
        call(
            endpoint = "\$events/result",
            args = JsonObject(
                linkedMapOf(
                    "clientId" to JsonString(request.clientID),
                    "eventId" to JsonString(request.eventID),
                    "outcome" to outcome,
                ),
            ),
        )
    }

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

    /**
     * `session/create`; returns the Worker's new session id.
     *
     * @param cwd the Worker working directory, or `null` to let the Worker decide.
     * @param agentPreset the preset the new session starts with, or `null` for the
     *   Worker's configured default. The value is carried as `request.agentPreset`
     *   (`plugins/worker-entry` and the real Worker both read it there); an absent
     *   argument leaves the request body exactly as it was before presets existed.
     */
    suspend fun createSession(
        cwd: String? = null,
        agentPreset: String? = null,
        timeoutMillis: Long = CALL_TIMEOUT_MILLIS,
    ): String {
        val request = LinkedHashMap<String, JsonValue>()
        if (cwd != null) request["cwd"] = JsonString(cwd)
        if (agentPreset != null) request["agentPreset"] = JsonString(agentPreset)
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
        agentPreset: String? = null,
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
                return createSession(
                    cwd = cwd,
                    agentPreset = agentPreset,
                    timeoutMillis = perAttemptMillis,
                )
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

    /**
     * `session/prompt` in `queue` mode: the user message that starts the turn.
     *
     * @param requestId the client-minted identity DSH persists on the accepted
     *   `user/message`. It must be **new for every submission**: the Worker
     *   answers `{accepted: true}` without delivering anything when the durable
     *   Session already holds a prompt with the same id
     *   (`hasPromptRequest`, `dsh-api-session-controller` `lib/index.js`), which
     *   looks exactly like a turn that never starts (`no_turn_started` after the
     *   first-event deadline) and was the P0 defect of the chat lane. Pass an id
     *   only to retry *the same* submission.
     */
    suspend fun prompt(
        sessionId: String,
        text: String,
        requestId: String = newPromptRequestId(),
        mode: String = "queue",
        timeoutMillis: Long = CALL_TIMEOUT_MILLIS,
    ) {
        require(mode == "queue" || mode == "steer") { "session/prompt mode must be queue or steer" }
        val request = JsonObject(
            linkedMapOf(
                "requestId" to JsonString(requestId),
                "sessionId" to JsonString(sessionId),
                "mode" to JsonString(mode),
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
            remoteEventsOpenFrame().toJsonString(),
        )
        sendMuxFrame(
            muxId,
            sessionFollowOpenFrame(sessionId, maxMessages, assistantStream = false).toJsonString(),
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

        /**
         * NDJSON bytes, split into lines at the byte level.
         *
         * A mux line is UTF-8, and the Worker writes one line per 4 MiB chunk
         * boundary (see `plugins/worker-entry/src/mux-bridge.ts` `writeMuxFrame`),
         * so a multi-byte character can straddle two chunks. Decoding each chunk
         * on its own replaces that character with U+FFFD: inside a JSON string the
         * line can still parse with silently corrupted text, while elsewhere the
         * damage can make the line unparsable and it is dropped. Splitting the raw
         * bytes and decoding only complete lines keeps every character intact.
         */
        private val lines = NdjsonLineBuffer()
        private var finished = false

        /** True once the stream reached its `end` frame or the transport closed. */
        val ended: Boolean get() = finished

        /**
         * The next complete mux item, or `null` when the stream ended or the
         * read deadline elapsed.
         *
         * A `null` return does not by itself mean the stream is over: [ended]
         * distinguishes a timeout from the terminal `end` frame.
         */
        suspend fun next(timeoutMillis: Long = NEXT_TIMEOUT_MILLIS): JsonObject? {
            if (finished) return null
            val deadline = System.currentTimeMillis() + timeoutMillis
            while (true) {
                val buffered = lines.nextLine()
                if (buffered != null) {
                    val line = buffered.trim()
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
                val chunk = result.getOrNull()
                if (chunk == null) {
                    finished = true
                    return null
                }
                lines.append(chunk)
            }
        }

        /**
         * Drains the follow stream into projected host events until [stopWhen]
         * is true or the deadline elapses.
         *
         * A quiet period shorter than [nextTimeoutMillis] is **not** the end of
         * the turn: it only returns control so the caller can re-check its own
         * deadline. Breaking on it (the previous behaviour) ended the turn after
         * 45 s of silence even though [timeoutMillis] allowed 180 s, which is
         * exactly what a long tool run or a slow first token looks like.
         *
         * Each read is also capped by the overall remaining budget: a final quiet
         * window must not extend the caller's [timeoutMillis] by a full
         * [nextTimeoutMillis].
         */
        suspend fun collectEvents(
            timeoutMillis: Long = TURN_TIMEOUT_MILLIS,
            nextTimeoutMillis: Long = NEXT_TIMEOUT_MILLIS,
            stopWhen: (HostEvent) -> Boolean,
        ): List<HostEvent> {
            val events = ArrayList<HostEvent>()
            val deadline = System.currentTimeMillis() + timeoutMillis
            while (true) {
                val remainingBudget = deadline - System.currentTimeMillis()
                if (remainingBudget <= 0L) break
                val readWindow = minOf(nextTimeoutMillis.coerceAtLeast(1L), remainingBudget)
                val item = next(readWindow)
                if (item == null) {
                    if (finished) break
                    continue
                }
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
            withContext(NonCancellable) {
                try {
                    withTimeoutOrNull(CLOSE_TIMEOUT_MILLIS) {
                        apiClose?.invoke(muxId)
                    }
                } catch (_: Exception) {
                    // A best-effort close must not replace the caller's turn result.
                }
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

private fun JsonObject.text(name: String): String? = (this[name] as? JsonString)?.value

/**
 * Byte-accurate NDJSON line buffer.
 *
 * The stream delivers arbitrary byte chunks, and a UTF-8 character may straddle
 * two of them (the Worker splits a line at 4 MiB, which is not a character
 * boundary). Decoding each chunk before looking for `\n` would corrupt that
 * character and drop the line; this buffer finds the newline in the raw bytes
 * and decodes only the complete line.
 *
 * Not thread-safe: one receive loop owns it.
 */
internal class NdjsonLineBuffer(initialCapacity: Int = 1024) {
    private var buffer = ByteArray(initialCapacity.coerceAtLeast(MINIMUM_CAPACITY))
    private var size = 0

    /** Bytes held for the line that has not been terminated yet. */
    val pendingBytes: Int get() = size

    /** Appends one transport chunk without decoding it. */
    fun append(chunk: ByteArray) {
        if (chunk.isEmpty()) return
        ensureCapacity(size + chunk.size)
        chunk.copyInto(buffer, size)
        size += chunk.size
    }

    /**
     * The next complete line (without its `\n`), or `null` when no newline has
     * been received yet. The remaining bytes stay buffered for the next call.
     */
    fun nextLine(): String? {
        var newline = -1
        for (index in 0 until size) {
            if (buffer[index] == NEWLINE) {
                newline = index
                break
            }
        }
        if (newline < 0) return null
        val line = String(buffer, 0, newline, Charsets.UTF_8)
        val remaining = size - newline - 1
        if (remaining > 0) buffer.copyInto(buffer, destinationOffset = 0, startIndex = newline + 1, endIndex = size)
        size = remaining
        return line
    }

    private fun ensureCapacity(required: Int) {
        if (required <= buffer.size) return
        var capacity = buffer.size
        while (capacity < required) capacity = capacity shl 1
        buffer = buffer.copyOf(capacity)
    }

    private companion object {
        const val MINIMUM_CAPACITY: Int = 64
        const val NEWLINE: Byte = 0x0A
    }
}

/**
 * A fresh `session/prompt` identity for one submission.
 *
 * The Worker deduplicates a prompt by this value against the Session's durable
 * `user/message` sources, so a value that repeats inside one Session is
 * swallowed (`{accepted: true}`, no turn, no events). A per-client counter is
 * not enough: the chat builds a new client for every send, so every send used
 * to be `pdsh-prompt-1` and the second turn of a conversation never reached the
 * model. The official Web client mints `randomUUID()` per submission for the
 * same reason.
 */
internal fun newPromptRequestId(): String = "pdsh-prompt-${UUID.randomUUID()}"

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
