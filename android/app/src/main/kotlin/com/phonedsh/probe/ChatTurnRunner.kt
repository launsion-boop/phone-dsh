// The chat turn: one `session/follow` the App itself reads, with live text.
// SPDX-License-Identifier: MIT
//
// ---- why this file exists -----------------------------------------------
// `:dsh`'s `DshTurnClient.runTurn` already sends the three `/api` calls
// (`session/create`, `session/follow`, `session/prompt`) and projects the Worker's
// durable events, and this App's 跑一轮 button uses it. What it cannot do for the
// chat is stream: its `session/follow` asks for `assistantStream: false`, and the
// Worker only publishes its process-local assistant frames when the follow request
// opts in (`dsh-api-session-controller/lib/types/types.d.ts`, `SessionFollowRequest.
// assistantStream`). Durable `assistant/message` events are written only when a
// message is settled, so a chat painted from them alone is the
// "wait for the end, then one block" behaviour this lane must remove.
//
// This class therefore owns exactly the one stream, in `:app`, and reuses
// everything else: it creates the session *through* `DshTurnClient`
// (`createSessionWhenReady`), prompts *through* it (`prompt`), cancels *through*
// it (`call("session/cancel", ...)`), and projects durable items with `:core`'s
// `HostEventProjection`. Only the mux open and the NDJSON line reader are local.
//
// ---- the Worker session survives the Worker page (P0/L85) ------------------
// A Worker `session/create` id used to be treated as valid only while the page
// that minted it lived, so every App start and every renderer rebuild opened a
// new session and left the previous model history behind: the transcript still
// showed the earlier messages, the model did not, and a follow-up question was
// answered `UNKNOWN`. That premise is wrong for this Worker:
//
//   * the phone profile mounts `session-persistence-journaled` at
//     `$DSH_HOME/sessions` (plaintext JSONL, `phone.worker.cordis.patch.yml`);
//   * `/dsh/home/**` is host-persisted and repacked into every boot
//     (`wal.md` §8, `BootOverlay`), so a reloaded page mounts the same log;
//   * `session/prompt` resumes a non-live session from that log
//     (`AgentSessionService.resolve` → `agents.resume`, which seeds the new
//     Agent with the whole persisted prefix), and only answers
//     `session/not-found` when the log is really gone.
//
// So the stored id is the *primary* path, across renderer rebuilds and cold
// starts, and a new session is opened only on the Worker's own `not-found`
// verdict — in which case the caller is told, because a transcript that still
// shows the old messages while the model no longer has them is the one state
// this file must never produce silently.
//
// ---- what it may not claim ------------------------------------------------
// The model behind the Worker is scripted in the acceptance lane. Streaming proves
// the App renders the Worker's live frames as they arrive; it does not prove an
// inference provider.
package com.phonedsh.probe

import com.phonedsh.agentcore.JsonObject
import com.phonedsh.agentcore.JsonString
import com.phonedsh.agentcore.JsonValue
import com.phonedsh.agentcore.toJsonString
import com.phonedsh.dsh.host.HostApiException
import com.phonedsh.dsh.host.HostApiStream
import com.phonedsh.dsh.host.HostChannel
import com.phonedsh.dsh.turn.DshTurnClient
import com.phonedsh.dsh.turn.DshTurnException
import com.phonedsh.dsh.turn.PendingRemoteRequest
import com.phonedsh.dsh.turn.pendingRemoteRequest
import com.phonedsh.dsh.turn.remoteEventsOpenFrame
import com.phonedsh.dsh.turn.sessionFollowOpenFrame
import com.phonedsh.hostevents.HostEvent
import com.phonedsh.hostevents.HostEventKind
import com.phonedsh.hostevents.HostEventProjection
import java.security.SecureRandom
import java.util.ArrayDeque
import java.util.concurrent.ConcurrentHashMap
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.channels.ReceiveChannel
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull

/**
 * One finished chat turn.
 *
 * @param events every durable host event the turn reported, in wire order.
 * @param endReason `turn_ended.data.reason.kind`, or `null` when the stream ended
 *   without the turn's edge.
 * @param liveText the text the Worker streamed before the durable message; kept
 *   so a caller can tell "the stream carried text" from "it carried none" even
 *   after the settled message replaced it.
 * @param contextReset true when this turn could not continue the stored Worker
 *   session and was sent into a new one, so the model did **not** see the earlier
 *   messages of this conversation. The user was told ([run]'s `onContextLost`).
 */
internal data class ChatTurnOutcome(
    val events: List<HostEvent>,
    val endReason: String?,
    val liveText: String,
    val contextReset: Boolean = false,
) {
    /** The settled assistant text the turn produced, if it produced one. */
    val assistantText: String
        get() = events.lastOrNull { it.kind == HostEventKind.ASSISTANT_MESSAGE }
            ?.let(::assistantTextOf)
            .orEmpty()

    /** True when the Worker's own edge says the turn completed. */
    val completed: Boolean get() = endReason == "completed"
}

/**
 * The App-side chat turn over the host channel.
 *
 * @param channel the host channel the Worker opened.
 * @param client the `/api` client used for the three unary calls.
 * @param log a token-free log seam (logcat in the App, a list in a test).
 */
internal class ChatTurnRunner(
    private val channel: HostChannel,
    private val client: DshTurnClient,
    private val log: (String) -> Unit = {},
    private val firstEventTimeoutMillis: Long = FIRST_EVENT_TIMEOUT_MILLIS,
    private val nextReadTimeoutMillis: Long = NEXT_TIMEOUT_MILLIS,
) {
    private val random = SecureRandom()

    /**
     * Runs one turn.
     *
     * @param workerSessionId the Worker session to continue, or `null` to create
     *   one. A stored id is the normal case, not a stale one: this Worker
     *   persists its session log under `/dsh/home/sessions`, the host repacks
     *   that tree into every boot, and `session/prompt` resumes a non-live
     *   session from it. The id is therefore tried **first** even after a cold
     *   start or a renderer rebuild, and only the Worker's own `session/not-found`
     *   answer opens a new one.
     * @param prompt the complete user text (attachments are named in it).
     * @param onSession called as soon as the Worker session id is known, before
     *   the prompt is sent, so the chat record can claim it (and the session list
     *   can show it) even when the turn later fails.
     * @param onEvent one durable event, in wire order.
     * @param onDelta one live text fragment, in arrival order.
     * @param onContextLost called with a user-facing sentence when the stored
     *   session is gone and this turn runs in a new one. Never omitted by the
     *   chat: "the transcript has the earlier messages, the model does not" is
     *   the state this callback exists to make impossible to hide.
     * @throws DshTurnException with a stable code when the lane fails.
     */
    suspend fun run(
        workerSessionId: String?,
        prompt: String,
        onSession: (String) -> Unit,
        onEvent: (HostEvent) -> Unit,
        onDelta: (String) -> Unit,
        onContextLost: (String) -> Unit = {},
        onInteractiveRequest: ((PendingRemoteRequest, suspend (JsonValue) -> Unit) -> Unit)? = null,
        onInteractiveCancel: ((String) -> Unit)? = null,
        onReasoningDelta: (String) -> Unit = {},
        /** Stable idempotency identity reused by a retry of this original prompt. */
        promptRequestId: String? = null,
        /** `queue` or `steer`; the latter is only issued by the live-turn composer. */
        promptMode: String = "queue",
    ): ChatTurnOutcome {
        val requested = workerSessionId
        if (requested != null) {
            // Only the session's own verdict may discard it. A channel failure, a
            // model failure, a timeout or a `no_turn_started` stream says nothing
            // about whether the log still exists, and opening a fresh session on
            // one of those is what silently amputated the model's history.
            var sawEvent = false
            try {
                return oneTurn(
                    requested,
                    prompt,
                    promptRequestId,
                    promptMode,
                    onSession,
                    { event -> sawEvent = true; onEvent(event) },
                    onDelta,
                    onInteractiveRequest,
                    onInteractiveCancel,
                    onReasoningDelta,
                )
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (failure: Exception) {
                val reason = reasonOf(failure)
                if (sawEvent || !workerSessionGone(reason)) throw failure
                // The Worker answered `session/not-found`: its persisted log does
                // not hold this id (a wiped home, or a record this Worker never
                // wrote). A new session is the only way to send at all, and the
                // person is told exactly what that costs.
                log("chat turn: worker session=$requested is gone ($reason); opening a new one")
                onContextLost(CONTEXT_LOST)
            }
        }
        val created = client.createSessionWhenReady(cwd = WORKSPACE)
        log("chat turn: new worker session=$created (previous=${requested ?: "none"})")
        return oneTurn(
            created, prompt, promptRequestId, promptMode, onSession, onEvent, onDelta,
            onInteractiveRequest, onInteractiveCancel, onReasoningDelta,
        )
            .copy(contextReset = requested != null)
    }

    /**
     * Asks the Worker to cancel the active turn.
     *
     * The receipt is the Worker's own `accepted`; a failure is returned as a
     * stable code and never thrown at the caller, because a cancellation that did
     * not reach the Worker must not crash the screen that already stopped
     * listening.
     */
    suspend fun cancel(workerSessionId: String): String? = try {
        client.call(
            endpoint = CANCEL_ENDPOINT,
            args = JsonObject(
                linkedMapOf(
                    "request" to JsonObject(linkedMapOf("sessionId" to JsonString(workerSessionId))),
                ),
            ),
        )
        null
    } catch (cancelled: CancellationException) {
        throw cancelled
    } catch (failure: Exception) {
        reasonOf(failure)
    }

    private suspend fun oneTurn(
        sessionId: String,
        prompt: String,
        promptRequestId: String?,
        promptMode: String,
        onSession: (String) -> Unit,
        onEvent: (HostEvent) -> Unit,
        onDelta: (String) -> Unit,
        onInteractiveRequest: ((PendingRemoteRequest, suspend (JsonValue) -> Unit) -> Unit)?,
        onInteractiveCancel: ((String) -> Unit)?,
        onReasoningDelta: (String) -> Unit,
    ): ChatTurnOutcome {
        onSession(sessionId)
        val follow = openFollow(sessionId)
        val events = ArrayList<HostEvent>()
        val live = StringBuilder()
        var endReason: String? = null
        val pendingRemoteRequests = ConcurrentHashMap.newKeySet<String>()
        try {
            val prefetchedItems = ArrayDeque<JsonObject>()
            // The server's ready frame supplies the clientId required by result
            // replies. Do not send a prompt until the live waterfall subscription
            // has registered; retain any multiplexed follow items read while waiting.
            val eventClientId = awaitEventsReady(follow, prefetchedItems)
            // The whole wait for the first durable event, not per read: a stale
            // session sends one history snapshot and then nothing.
            val firstEventDeadline = System.currentTimeMillis() + firstEventTimeoutMillis
            // The prompt goes out only after the stream is open: the Worker
            // publishes the turn's first frames as soon as it accepts it, and a
            // prompt sent first can outrun the subscription.
            if (promptRequestId == null) client.prompt(sessionId, prompt, mode = promptMode)
            else client.prompt(sessionId, prompt, requestId = promptRequestId, mode = promptMode)
            log("chat turn: session/prompt queued session=$sessionId")
            while (true) {
                // Before the first durable event, keep the existing bounded
                // first-event wait. Once an event arrives the caller owns this
                // stream's lifetime through cancellation; interactive turns can
                // legitimately remain open without a total wall-clock cutoff.
                val timeout = if (events.isEmpty()) {
                    (firstEventDeadline - System.currentTimeMillis()).coerceAtLeast(1L)
                } else {
                    nextReadTimeoutMillis
                }
                val item = prefetchedItems.pollFirst() ?: follow.next(timeout)
                if (item == null) {
                    if (!follow.isFinished) {
                        // A receive timeout only means the Worker was quiet for
                        // this window. Keep the same mux/session alive; the
                        // first-event deadline above remains the stale-session
                        // guard, and later quiet windows do not end a turn.
                        if (events.isEmpty() && System.currentTimeMillis() >= firstEventDeadline) {
                            throw DshTurnException(
                                "no_turn_started",
                                "the session accepted no turn; the Worker may have reloaded",
                            )
                        }
                        continue
                    }
                    if (events.isEmpty()) {
                        throw DshTurnException(
                            "no_turn_started",
                            "the session accepted no turn; the Worker may have reloaded",
                        )
                    }
                    break
                }
                when (item.text("type")) {
                    "error" -> {
                        val error = item["error"] as? JsonObject
                        throw DshTurnException(
                            error?.text("code") ?: "stream_error",
                            error?.text("message") ?: "the follow stream reported an error",
                        )
                    }

                    "end" -> break
                    "item" -> Unit
                    else -> continue
                }
                val value = item["value"] as? JsonObject ?: continue
                if (item.text("streamId") == EVENTS_STREAM_ID) {
                    when (value.text("type")) {
                        "ready" -> Unit // Consumed by `awaitEventsReady` before prompting.
                        "waterfall" -> {
                            val remote = pendingRemoteRequest(value, sessionId, eventClientId) ?: continue
                            val eventId = remote.eventID
                            if (remote.eventKind == APPROVAL_REQUEST || remote.eventKind == QUESTION_REQUEST) {
                                val onRequest = onInteractiveRequest
                                if (onRequest == null) {
                                    // No UI owner has claimed this waterfall. Return
                                    // it to the next listener, exactly like the iOS
                                    // remote harness does for unsupported event kinds.
                                    client.answerRemoteRequest(remote, NEXT_WATERFALL_OUTCOME)
                                } else {
                                    pendingRemoteRequests.add(eventId)
                                    onRequest(remote) { outcome ->
                                        client.answerRemoteRequest(remote, outcome)
                                        pendingRemoteRequests.remove(eventId)
                                    }
                                }
                            } else {
                                client.answerRemoteRequest(
                                    remote,
                                    NEXT_WATERFALL_OUTCOME,
                                )
                            }
                        }
                        "cancel" -> {
                            val eventId = value.text("eventId")
                            if (eventId != null && pendingRemoteRequests.remove(eventId)) {
                                onInteractiveCancel?.invoke(eventId)
                            }
                        }
                    }
                    continue
                }
                when (value.text("type")) {
                    "event" -> {
                        val event = value["event"] as? JsonObject ?: continue
                        for (projected in HostEventProjection.projectAll(event)) {
                            events += projected
                            onEvent(projected)
                            if (projected.kind == HostEventKind.TURN_ENDED) {
                                endReason = projected.turnEndReason
                                return ChatTurnOutcome(events, endReason, live.toString())
                            }
                        }
                    }

                    "assistant-stream" -> {
                        val frame = value["frame"] as? JsonObject ?: continue
                        if (frame.text("type") != "chunk") continue
                        val chunk = frame["chunk"] ?: continue
                        when ((chunk as? JsonObject)?.text("type")) {
                            "text-delta" -> {
                                val text = textDeltaOf(chunk) ?: continue
                                if (text.isEmpty()) continue
                                live.append(text)
                                onDelta(text)
                            }
                            "reasoning-delta" -> {
                                val text = reasoningDeltaOf(chunk) ?: continue
                                if (text.isNotEmpty()) onReasoningDelta(text)
                            }
                        }
                    }

                    // `snapshot` is the Worker's own history replay. This App keeps the
                    // transcript (ChatSessionStore), so replaying it here would render
                    // every message twice; it is deliberately not read.
                    "snapshot", "end" -> Unit
                    else -> Unit
                }
            }
        } finally {
            follow.close()
        }
        log("chat turn: session/follow ended events=${events.size} liveChars=${live.length}")
        return ChatTurnOutcome(events, endReason, live.toString())
    }

    /** The iOS remote harness waits for the `$events` client registration before prompts can race it. */
    private suspend fun awaitEventsReady(
        follow: FollowStream,
        prefetchedItems: ArrayDeque<JsonObject>,
    ): String {
        val deadline = System.currentTimeMillis() + EVENT_READY_TIMEOUT_MILLIS
        while (System.currentTimeMillis() < deadline) {
            val remaining = (deadline - System.currentTimeMillis()).coerceAtLeast(1L)
            val item = follow.next(remaining)
                ?: throw DshTurnException("events_not_ready", "the live event stream did not register a client")
            when (item.text("type")) {
                "error" -> {
                    val error = item["error"] as? JsonObject
                    throw DshTurnException(
                        error?.text("code") ?: "events_stream_error",
                        error?.text("message") ?: "the live event stream reported an error",
                    )
                }
                "end" -> throw DshTurnException("events_stream_ended", "the live event stream ended before registration")
                "item" -> Unit
                else -> continue
            }
            val value = item["value"] as? JsonObject ?: continue
            if (item.text("streamId") == EVENTS_STREAM_ID && value.text("type") == "ready") {
                return eventsReadyClientId(item)
                    ?: throw DshTurnException("events_client_missing", "the live event stream registered no client id")
            }
            prefetchedItems.addLast(item)
        }
        throw DshTurnException("events_not_ready", "the live event stream did not register a client")
    }

    /** Opens the `session/follow` mux stream with the live assistant frames opted in. */
    private suspend fun openFollow(sessionId: String): FollowStream {
        val muxId = ByteArray(16).also(random::nextBytes).hex()
        sendMux(
            muxId,
            remoteEventsOpenFrame().toJsonString(),
        )
        sendMux(
            muxId,
            // The Worker stream carries live assistant frames as well as durable history.
            sessionFollowOpenFrame(sessionId, MAX_MESSAGES, assistantStream = true).toJsonString(),
        )
        val stream = channel.openApiStream(
            method = "POST",
            path = MUX_PATH,
            headers = mapOf(
                "content-type" to "application/json",
                "x-pdsh-mux-id" to muxId,
                "x-pdsh-mux-op" to "receive",
            ),
        )
        return FollowStream(muxId, stream)
    }

    private suspend fun sendMux(muxId: String, frame: String) {
        channel.apiRequest(
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

    /** The `session/follow` receive stream, one NDJSON item at a time. */
    private inner class FollowStream(
        private val muxId: String,
        private val stream: HostApiStream,
    ) {
        private val reader = FollowFrameReader(stream.chunks())

        val isFinished: Boolean get() = reader.isFinished

        /** The next complete mux item, or `null` when the stream ended or timed out. */
        suspend fun next(timeoutMillis: Long = NEXT_TIMEOUT_MILLIS): JsonObject? = reader.next(timeoutMillis)

        /** Closes the receive stream and the logical mux. */
        suspend fun close() {
            stream.close()
            withContext(NonCancellable) {
                try {
                    withTimeoutOrNull(CLOSE_TIMEOUT_MILLIS) {
                        channel.apiRequest(
                            method = "POST",
                            path = MUX_PATH,
                            headers = mapOf(
                                "content-type" to "application/json",
                                "x-pdsh-mux-id" to muxId,
                                "x-pdsh-mux-op" to "close",
                            ),
                            timeoutMillis = CLOSE_TIMEOUT_MILLIS,
                        )
                    }
                } catch (_: Exception) {
                    // Cleanup is best-effort; never replace the caller's turn result.
                }
            }
        }
    }

    private fun textDeltaOf(chunk: JsonValue?): String? {
        val object0 = chunk as? JsonObject ?: return null
        if (object0.text("type") != "text-delta") return null
        return object0.text("text")
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

    private fun reasonOf(failure: Exception): String = when (failure) {
        is DshTurnException -> failure.code
        is HostApiException -> failure.code
        else -> failure.javaClass.simpleName
    }

    private companion object {
        const val MUX_PATH = "/api/remote.mux"
        const val CANCEL_ENDPOINT = "session/cancel"

        /** What the person is told when the earlier context could not be kept. */
        const val CONTEXT_LOST =
            "上一段上下文已丢失：之前那轮对话的 Worker 会话已经无法恢复（session/not-found），" +
                "这条消息开了一个新会话，模型看不到本对话更早的内容。"

        /** The Worker's session cwd: the workspace the App's files page also shows. */
        const val WORKSPACE = "/dsh/workspace"
        const val MAX_MESSAGES = 64
        const val NEXT_TIMEOUT_MILLIS = 45_000L

        /** How long the first durable event of a turn may take (a reloaded page never sends one). */
        const val FIRST_EVENT_TIMEOUT_MILLIS = 20_000L
        const val EVENT_READY_TIMEOUT_MILLIS = 20_000L

        const val CLOSE_TIMEOUT_MILLIS = 5_000L
        const val EVENTS_STREAM_ID = "events"
        const val APPROVAL_REQUEST = "approval/request"
        const val QUESTION_REQUEST = "user-questions/request"
        val NEXT_WATERFALL_OUTCOME = JsonObject(
            linkedMapOf("kind" to JsonString("next")),
        )
        const val HEX = "0123456789abcdef"
    }
}

/** Byte-framed NDJSON reader shared by the App's live follow stream and its JVM regression. */
internal class FollowFrameReader(private val chunks: ReceiveChannel<ByteArray>) {
    private val pending = NdjsonByteBuffer()
    var isFinished: Boolean = false
        private set

    suspend fun next(timeoutMillis: Long): JsonObject? {
        if (isFinished) return null
        val deadline = System.currentTimeMillis() + timeoutMillis
        while (true) {
            val lineBytes = pending.nextLine()
            if (lineBytes != null) {
                val line = lineBytes.toString(Charsets.UTF_8).trim()
                if (line.isEmpty()) continue
                val parsed = try { JsonValue.parse(line) as? JsonObject } catch (_: Exception) { null }
                    ?: continue
                if ((parsed["type"] as? JsonString)?.value == "end") isFinished = true
                return parsed
            }
            val remaining = deadline - System.currentTimeMillis()
            if (remaining <= 0) return null
            val result = withTimeoutOrNull(remaining) { chunks.receiveCatching() } ?: return null
            if (result.isClosed) {
                isFinished = true
                val cause = result.exceptionOrNull()
                if (cause != null && cause !is HostApiException) throw cause
                if (cause is HostApiException) {
                    throw DshTurnException(cause.code, cause.message ?: "the follow stream ended")
                }
                return null
            }
            val chunk = result.getOrNull() ?: continue
            pending.append(chunk)
        }
    }
}

/** Retains raw NDJSON bytes and scans only bytes not examined in an earlier quiet poll. */
internal class NdjsonByteBuffer(initialCapacity: Int = 256) {
    private var bytes = ByteArray(initialCapacity.coerceAtLeast(1))
    private var start = 0
    private var size = 0
    private var scanOffset = 0

    fun append(chunk: ByteArray) {
        if (size + chunk.size > bytes.size && start > 0) {
            val remaining = size - start
            bytes.copyInto(bytes, 0, start, size)
            size = remaining
            scanOffset = (scanOffset - start).coerceAtLeast(0)
            start = 0
        }
        if (size + chunk.size > bytes.size) {
            var capacity = bytes.size
            while (capacity < size + chunk.size) capacity = (capacity * 2).coerceAtLeast(size + chunk.size)
            bytes = bytes.copyOf(capacity)
        }
        chunk.copyInto(bytes, size)
        size += chunk.size
    }

    /** Returns one complete line (without LF), or null while the tail is partial. */
    fun nextLine(): ByteArray? {
        var index = scanOffset
        while (index < size) {
            if (bytes[index] == '\n'.code.toByte()) {
                val line = bytes.copyOfRange(start, index)
                start = index + 1
                scanOffset = start
                if (start == size) {
                    start = 0
                    size = 0
                    scanOffset = 0
                }
                return line
            }
            index++
        }
        scanOffset = size
        return null
    }
}

/** Reads one live reasoning fragment without logging or persisting the content. */
internal fun reasoningDeltaOf(chunk: JsonValue?): String? {
    val value = chunk as? JsonObject ?: return null
    if ((value["type"] as? JsonString)?.value != "reasoning-delta") return null
    return (value["text"] as? JsonString)?.value
}

/** Reads DSH's mux `item` envelope for the events stream's initial ready/clientId message. */
internal fun eventsReadyClientId(frame: JsonObject): String? {
    if ((frame["type"] as? JsonString)?.value != "item") return null
    if ((frame["streamId"] as? JsonString)?.value != "events") return null
    val value = frame["value"] as? JsonObject ?: return null
    if ((value["type"] as? JsonString)?.value != "ready") return null
    return (value["clientId"] as? JsonString)?.value
}

/**
 * True when [code] is the Worker saying the stored session does not exist.
 *
 * This is the **only** reason this lane may open a new Worker session for a
 * conversation that already has one: every other failure (`no_turn_started`,
 * `stream_error`, a channel error, a timeout) leaves the durable log intact and
 * is reported to the person instead of being "recovered" into a contextless
 * session.
 */
internal fun workerSessionGone(code: String?): Boolean = code == SESSION_NOT_FOUND_CODE

/** The Worker's own verdict that a persisted session is not there. */
private const val SESSION_NOT_FOUND_CODE: String = "session/not-found"

/**
 * The text of one settled `assistant/message` event.
 *
 * The Worker's durable message carries `data.message.content[]` blocks; the
 * scripted/golden fixtures may carry a flat `data.text`. Both shapes are read, and
 * only `text` blocks count, so a reasoning or tool-call block never becomes prose.
 */
internal fun assistantTextOf(event: HostEvent): String {
    val data = event.data ?: return ""
    (data["text"] as? JsonString)?.value?.let { return it }
    val message = data["message"] as? JsonObject
    val content = (message?.get("content") as? com.phonedsh.agentcore.JsonArray)
        ?: (data["content"] as? com.phonedsh.agentcore.JsonArray)
    if (content != null) {
        return content.values.mapNotNull { block ->
            (block as? JsonObject)?.let { member ->
                if ((member["type"] as? JsonString)?.value == "text") {
                    (member["text"] as? JsonString)?.value
                } else {
                    null
                }
            }
        }.joinToString("")
    }
    return (message?.get("text") as? JsonString)?.value.orEmpty()
}
