// :testkit channel — the DSH remote-API client a turn needs (session, prompt, follow).
// SPDX-License-Identifier: MIT
//
// ---- where the wire shape comes from ---------------------------------------
// `dsh web`'s remote API, as implemented by the Swift reference client
// (`Sources/PhoneDSHAgentCore/DSH/DSHRemoteTransport.swift`,
// `DSHRemoteHarness.swift`) and served by the Worker entry
// (`plugins/worker-entry/src/entry.ts`, `mux-bridge.ts`):
//
//   unary   POST /api/<endpoint>  {"type":"client-request","rpcId":…,
//                                  "method":…,"payload":{"args":{…}}}
//           <- {"type":"server-response","rpcId":…,"result":{"ok":…,"value":…}}
//   stream  POST /api/remote.mux  x-pdsh-mux-id / x-pdsh-mux-op: send|receive|close
//           <- newline-delimited {"type":"item","streamId":…,"value":…}
//
// A turn is: `session/create` -> `session/prompt` -> the `session/follow` stream
// (snapshot records, then live `event` items). The events in those items are the
// host events of `spec/host/v1` (`turn_started`, `tool_call`, …); this client
// does not invent any — it parses what the Worker produced.
//
// This class is test-surface glue. It is the missing *host* client: the Android
// `:dsh` facade never implemented the `/api` lane (`src/main` work).

package com.phonedsh.testkit.channel

import com.phonedsh.agentcore.JsonBool
import com.phonedsh.agentcore.JsonNumber
import com.phonedsh.agentcore.JsonObject
import com.phonedsh.agentcore.JsonString
import com.phonedsh.agentcore.JsonValue
import com.phonedsh.agentcore.toJsonString
import java.security.SecureRandom
import java.util.concurrent.atomic.AtomicInteger
import kotlinx.coroutines.withTimeoutOrNull

/**
 * One event the Worker's `session/follow` stream delivered.
 *
 * A DSH event carries its authoring type in `type` (`turn/start`, `tool/call`,
 * …). The host contract (`spec/host/v1/event-kinds.md` §1) names the projection
 * type and the host `kind` those map to; [hostKind] is that mapping, applied
 * verbatim, and [raw] keeps the worker's own event untouched.
 */
data class TurnEvent(
    /** `seq` of the durable event; `null` for a best-effort one. */
    val seq: Long?,
    /** The worker's authoring type, verbatim (`turn/start`, `tool/call`, …). */
    val dshType: String,
    /** The host `kind` per event-kinds.md §1, or `null` when no row exists. */
    val hostKind: String?,
    /** `turn-%04d` from `data.turn`; `null` for a session-scope event. */
    val turnId: String?,
    /** The raw event object, for assertions this projection does not name. */
    val raw: com.phonedsh.agentcore.JsonObject,
) {
    /** A one-line, logcat-friendly projection. */
    fun describe(): String = buildString {
        append("kind=").append(hostKind ?: "-")
        append(" dsh=").append(dshType)
        append(" seq=").append(seq ?: "-")
        if (turnId != null) append(" turn=").append(turnId)
        val data = raw["data"] as? com.phonedsh.agentcore.JsonObject
        if (hostKind == "tool_call") {
            (data?.get("name") as? JsonString)?.value?.let { append(" tool=").append(it) }
            (data?.get("callId") as? JsonString)?.value?.let { append(" call=").append(it) }
        }
        if (hostKind == "tool_result") {
            (data?.get("callId") as? JsonString)?.value?.let { append(" call=").append(it) }
            (data?.get("isError") as? JsonBool)?.value?.let { append(" isError=").append(it) }
        }
        if (hostKind == "turn_ended") {
            val reason = data?.get("reason") as? com.phonedsh.agentcore.JsonObject
            (reason?.get("kind") as? JsonString)?.value?.let { append(" reason=").append(it) }
        }
    }

    /**
     * The host contract's projection table (`spec/host/v1/event-kinds.md` §1),
     * applied to the worker's authoring type. Types with no row are `null`: the
     * event is kept for diagnostics, never invented into a host kind.
     */
    companion object {
        fun hostKindOf(dshType: String): String? = when (dshType) {
            "assistant/message" -> "assistant_message"
            "permission/request" -> "permission_requested"
            "question/request" -> "question_requested"
            "session/start" -> "session_status"
            "tool/call" -> "tool_call"
            "tool/result" -> "tool_result"
            "turn/end" -> "turn_ended"
            "turn/start" -> "turn_started"
            "user/message" -> "user_message"
            else -> null
        }
    }
}

/** A string member of a JSON object (absent or non-string -> `null`). */
internal fun JsonObject.memberText(name: String): String? = (this[name] as? JsonString)?.value

/** A DSH remote-API error: `result.error.code` from a `server-response`. */
class DshApiException(val code: String, message: String) : Exception("$code: $message")

/**
 * The `/api` client for one turned-on channel.
 *
 * @param api the host side of the `/api` lane (`ApiFrameChannel`).
 */
class DshTurnClient(
    private val api: ApiFrameChannel,
    /** Optional observer for every complete NDJSON mux line (logcat evidence). */
    private val onMuxLine: ((String) -> Unit)? = null,
) {
    private val rpcIds = AtomicInteger(0)
    private val random = SecureRandom()

    /** `POST /api/<endpoint>` with `{"args": …}` and unwraps the response value. */
    suspend fun call(
        endpoint: String,
        args: String = "{}",
        timeoutMillis: Long = CALL_TIMEOUT_MILLIS,
    ): JsonValue {
        val rpcId = "testkit-rpc-${rpcIds.incrementAndGet()}"
        val body = """{"type":"client-request","rpcId":"$rpcId","method":${quote(endpoint)},""" +
            """"payload":{"args":$args}}"""
        val response = api.request(
            method = "POST",
            path = "/api/$endpoint",
            headers = mapOf("content-type" to "application/json"),
            body = body.toByteArray(),
            timeoutMillis = timeoutMillis,
        )
        val envelope = parseObject(response.bodyText())
            ?: throw DshApiException("invalid_response", "no JSON envelope for $endpoint")
        if (envelope.memberText("type") != "server-response") {
            throw DshApiException("invalid_response", "$endpoint answered ${envelope.memberText("type")}")
        }
        if (envelope.memberText("rpcId") != rpcId) {
            throw DshApiException("invalid_response", "$endpoint answered another rpcId")
        }
        val result = envelope["result"] as? JsonObject
            ?: throw DshApiException("invalid_response", "$endpoint carried no result")
        if ((result["ok"] as? JsonBool)?.value != true) {
            val error = result["error"] as? JsonObject
            throw DshApiException(
                error?.memberText("code") ?: "unknown",
                error?.memberText("message") ?: "",
            )
        }
        return result["value"] ?: com.phonedsh.agentcore.JsonNull
    }

    /** `session/create`; returns the new session id. */
    suspend fun createSession(cwd: String? = null, timeoutMillis: Long = CALL_TIMEOUT_MILLIS): String {
        val request = StringBuilder("{")
        if (cwd != null) request.append("\"cwd\":").append(quote(cwd))
        request.append("}")
        val value = call("session/create", """{"request":$request}""", timeoutMillis) as? JsonObject
            ?: throw DshApiException("invalid_response", "session/create returned no object")
        return value.memberText("sessionId")
            ?: throw DshApiException("invalid_response", "session/create returned no sessionId")
    }

    /** `session/prompt` in `queue` mode: the user message that starts a turn. */
    suspend fun prompt(sessionId: String, text: String) {
        val requestId = "testkit-prompt-${rpcIds.incrementAndGet()}"
        val request = """{"requestId":${quote(requestId)},"sessionId":${quote(sessionId)},""" +
            """"mode":"queue","content":[{"type":"text","text":${quote(text)}}]}"""
        call("session/prompt", """{"request":$request}""")
    }

    /** `session/page`: the durable records after the fact (a fallback for `follow`). */
    suspend fun page(sessionId: String, maxMessages: Int = 64): List<TurnEvent> {
        val request = """{"address":{"kind":"session","sessionId":${quote(sessionId)}},""" +
            """"maxMessages":$maxMessages}"""
        val value = call("session/page", """{"request":$request}""") as? JsonObject ?: return emptyList()
        val records = value["records"] as? com.phonedsh.agentcore.JsonArray ?: return emptyList()
        return records.values.mapNotNull { record ->
            val event = (record as? JsonObject)?.get("event") as? JsonObject ?: return@mapNotNull null
            event.toTurnEvent()
        }
    }

    /**
     * Opens one mux session following [sessionId].
     *
     * Both DSH streams are opened on the same logical mux: `$events` (live
     * status/approvals) and `session/follow` (the durable event window and its
     * live tail). The response is the `receive` call's NDJSON stream; call
     * [MuxSession.next] until it returns `null`.
     */
    suspend fun openFollow(sessionId: String, maxMessages: Int = 64): MuxSession {
        val muxId = ByteArray(16).also(random::nextBytes).toHex()
        sendMuxFrame(
            muxId,
            """{"type":"open","streamId":"events","endpoint":"${'$'}events","payload":{"args":{}}}""",
        )
        val followRequest = """{"address":{"kind":"session","sessionId":${quote(sessionId)}},""" +
            """"maxMessages":$maxMessages,"assistantStream":false}"""
        sendMuxFrame(
            muxId,
            """{"type":"open","streamId":"follow","endpoint":"session/follow",""" +
                """"payload":{"args":{"request":$followRequest}}}""",
        )
        val stream = api.stream(
            method = "POST",
            path = MUX_PATH,
            headers = mapOf(
                "content-type" to "application/json",
                "x-pdsh-mux-id" to muxId,
                "x-pdsh-mux-op" to "receive",
            ),
        )
        return MuxSession(muxId, stream)
    }

    private suspend fun sendMuxFrame(muxId: String, frame: String) {
        api.request(
            method = "POST",
            path = MUX_PATH,
            headers = mapOf(
                "content-type" to "application/json",
                "x-pdsh-mux-id" to muxId,
                "x-pdsh-mux-op" to "send",
            ),
            body = frame.toByteArray(),
        )
    }

    /** One open logical mux session, fed by the `receive` call's NDJSON stream. */
    inner class MuxSession internal constructor(
        val muxId: String,
        private val stream: ApiFrameChannel.ApiStream,
    ) {
        private val pending = MuxByteBuffer()
        private var finished = false

        /**
         * The next mux item, or `null` when the stream ended or [timeoutMillis]
         * elapsed. Server frames are `{type:"item"|"error"|"end", …}`.
         */
        suspend fun next(timeoutMillis: Long = NEXT_TIMEOUT_MILLIS): JsonObject? {
            if (finished) return null
            val deadline = System.currentTimeMillis() + timeoutMillis
            while (true) {
                val lineBytes = pending.nextLine()
                if (lineBytes != null) {
                    val line = lineBytes.toString(Charsets.UTF_8).trim()
                    if (line.isEmpty()) continue
                    onMuxLine?.invoke(line)
                    val parsed = parseObject(line) ?: continue
                    if (parsed.memberText("type") == "end") finished = true
                    return parsed
                }
                val remaining = deadline - System.currentTimeMillis()
                if (remaining <= 0) return null
                val chunk = withTimeoutOrNull(remaining) { readNextChunk() } ?: return null
                pending.append(chunk)
            }
        }

        /** Drains the follow stream into host events until [stopWhen] is true or it ends. */
        suspend fun collectEvents(
            timeoutMillis: Long = COLLECT_TIMEOUT_MILLIS,
            stopWhen: (TurnEvent) -> Boolean,
        ): List<TurnEvent> {
            val events = ArrayList<TurnEvent>()
            val deadline = System.currentTimeMillis() + timeoutMillis
            while (true) {
                val remaining = deadline - System.currentTimeMillis()
                if (remaining <= 0) break
                val item = next(remaining)
                if (item == null) {
                    if (finished) break
                    continue
                }
                if (item.memberText("type") != "item") {
                    if (item.memberText("type") == "error") break
                    continue
                }
                for (event in eventsOf(item)) {
                    events += event
                    if (stopWhen(event)) return events
                }
            }
            return events
        }

        /** Closes the logical mux (`x-pdsh-mux-op: close`) and the receive stream. */
        suspend fun close() {
            stream.close()
            runCatching {
                api.request(
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
        }

        private val channel = stream.chunks()

        private suspend fun readNextChunk(): ByteArray? {
            val result = channel.receiveCatching()
            if (result.isClosed) {
                finished = true
                result.exceptionOrNull()?.let { throw it }
                return null
            }
            return result.getOrNull()
        }
    }

    private fun eventsOf(item: JsonObject): List<TurnEvent> {
        val streamId = item.memberText("streamId")
        if (streamId != null && streamId != "follow") return emptyList()
        val value = item["value"] as? JsonObject ?: return emptyList()
        return when (value.memberText("type")) {
            "snapshot" -> {
                val records = value["records"] as? com.phonedsh.agentcore.JsonArray ?: return emptyList()
                records.values.mapNotNull { record ->
                    val event = (record as? JsonObject)?.get("event") as? JsonObject
                    event?.toTurnEvent()
                }
            }

            "event" -> listOfNotNull((value["event"] as? JsonObject)?.toTurnEvent())
            else -> emptyList()
        }
    }

    private fun JsonObject.toTurnEvent(): TurnEvent? {
        val dshType = memberText("type") ?: return null
        val seq = (this["seq"] as? JsonNumber)?.asLongOrNull()
        val data = this["data"] as? JsonObject
        val turn = (data?.get("turn") as? JsonNumber)?.asLongOrNull()
        val turnId = if (turn == null) null else "turn-%04d".format(turn)
        return TurnEvent(
            seq = seq,
            dshType = dshType,
            hostKind = TurnEvent.hostKindOf(dshType),
            turnId = turnId,
            raw = this,
        )
    }

    private fun quote(text: String): String {
        val out = StringBuilder(text.length + 2)
        out.append('"')
        for (character in text) {
            when (character) {
                '"' -> out.append("\\\"")
                '\\' -> out.append("\\\\")
                '\n' -> out.append("\\n")
                '\r' -> out.append("\\r")
                '\t' -> out.append("\\t")
                else -> if (character.code < 0x20) {
                    out.append("\\u").append(String.format("%04x", character.code))
                } else {
                    out.append(character)
                }
            }
        }
        out.append('"')
        return out.toString()
    }

    /** Reads a string member of a JSON object (absent or non-string -> `null`). */
    /** Parses [text] as a JSON object, or `null` when it is not one. */
    private fun parseObject(text: String): JsonObject? = try {
        JsonValue.parse(text) as? JsonObject
    } catch (_: Exception) {
        null
    }

    private fun ByteArray.toHex(): String = buildString(size * 2) {
        for (byte in this@toHex) {
            val value = byte.toInt() and 0xFF
            append(HEX[value ushr 4]).append(HEX[value and 0x0F])
        }
    }

    private companion object {
        const val MUX_PATH = "/api/remote.mux"
        const val HEX = "0123456789abcdef"
        const val NEXT_TIMEOUT_MILLIS = 45_000L
        const val COLLECT_TIMEOUT_MILLIS = 120_000L
        const val CLOSE_TIMEOUT_MILLIS = 5_000L
        const val CALL_TIMEOUT_MILLIS = 60_000L
    }
}

/** Byte queue that scans each received byte once until its LF delimiter arrives. */
private class MuxByteBuffer(initialCapacity: Int = 256) {
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
