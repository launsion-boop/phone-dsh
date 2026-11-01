// :testkit channel — the host→worker `/api` lane over the real ordered channel.
// SPDX-License-Identifier: MIT
//
// ---- what this class is ----------------------------------------------------
// The Android host facade (`com.phonedsh.dsh.host.HostChannel`) answers HELLO,
// routes `VFS_MUT`/`VFS_BARRIER` into the VFS sink and `EXEC_REQ` into the exec
// bridge. It does NOT implement the host→worker API lane (`channel.md` §3.7-3.10)
// — that is `src/main` work this lane may not touch. This class is the missing
// half, written in the TEST surface, and it is a transport decorator, not a new
// protocol: it speaks the frame layouts the spec fixes and the Worker entry
// already serves (`plugins/worker-entry/src/entry.ts`, `serveApiRequests`).
//
// ---- the seq rule, and why this class owns it ------------------------------
// `channel.md` §1: `seq` is per connection and per direction, first frame 1,
// then +1 per frame. Two producers share this one host→worker direction
// (HostChannel's HELLO/VFS_ACK/EXEC_EVT, and this class's API_REQ/API_ABORT), so
// a single writer must allocate the number. The decorator is that writer: it
// re-stamps the 8-byte header `seq` of every frame it forwards and of every frame
// it originates. `type`, `flags`, `len` and the payload are forwarded unchanged,
// so the contract's ordering invariant holds and no protocol behaviour is
// invented. Without this the two producers would collide at the same number and
// the Worker would close the connection with `BAD_SEQ`.
//
// ---- payload encoding ------------------------------------------------------
// Frames are built and parsed by `:core`'s Rust codec (`WireCodec`), not by a
// second JSON/frame implementation: `{"type":"API_REQ","fields":{...}}` in,
// canonical `fields` JSON out. On a device the test APK carries
// `libpdsh_jni.so` (see `testkit/build.gradle.kts`), exactly as the demo APK does.

package com.phonedsh.testkit.channel

import com.phonedsh.agentcore.JsonNumber
import com.phonedsh.agentcore.JsonObject
import com.phonedsh.agentcore.JsonString
import com.phonedsh.agentcore.JsonValue
import com.phonedsh.agentcore.toJsonString
import com.phonedsh.loopback.LoopbackConnection
import com.phonedsh.wire.WireCodec
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicInteger
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.channels.ReceiveChannel
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.consumeAsFlow
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withTimeoutOrNull

/** The head of one `API_RES` (`channel.md` §3.8): `{status, headers}`. */
data class ApiResponseHead(val status: Int, val headers: Map<String, String>)

/** What one unary API request produced. */
data class ApiResponse(val head: ApiResponseHead, val body: ByteArray) {
    /** Body as UTF-8 text (the DSH API is JSON). */
    fun bodyText(): String = String(body, Charsets.UTF_8)
}

/**
 * The host end of the `/api` lane over one ordered-channel connection.
 *
 * Wrap the connection the engine hands to `onOpen` **before** passing it to the
 * host facade, and forward every inbound payload to [onInbound] as well as to
 * the host. Then [request] / [stream] are the two shapes DSH's remote API needs:
 * a unary call and a long-lived NDJSON response.
 *
 * @param target the transport connection; the only writer of the WebSocket.
 */
class ApiFrameChannel(
    private val target: LoopbackConnection,
    /** Optional per-frame trace `(direction, typeName, seq)` for logcat evidence. */
    private val trace: ((String, String, Long) -> Unit)? = null,
    /** Optional observer for every host→worker payload (the EXEC_EVT proof lives here). */
    private val onOutboundFrame: ((Int, ByteArray) -> Unit)? = null,
) : LoopbackConnection {
    private val sendMutex = Mutex()

    /** Next `seq` this direction has not used yet. Starts at 1 (HELLO). */
    private var nextSeq: Long = 1

    private val lock = Any()
    private val exchanges = ConcurrentHashMap<Int, Exchange>()
    private val requestIds = AtomicInteger(0)
    private var aborted: String? = null

    override val id: String get() = target.id

    /** Waiters for the first inbound frame (the driver has nothing to do before it). */
    private val inbound = Channel<ByteArray>(Channel.UNLIMITED)

    /** Frame types the `/api` lane owns (`channel.md` §2). */
    private val apiRes = CHANNEL_API_RES
    private val apiEnd = CHANNEL_API_END
    private val apiAbort = CHANNEL_API_ABORT

    override suspend fun sendBinary(payload: ByteArray) {
        sendMutex.withLock {
            val seq = nextSeq
            nextSeq += 1
            frameTypeOf(payload)?.let { type ->
                trace?.invoke("host->worker", frameTypeName(type), seq)
                onOutboundFrame?.invoke(type, payload)
            }
            target.sendBinary(withSeq(payload, seq))
        }
    }

    override suspend fun close(code: Short, reason: String) {
        target.close(code, reason)
    }

    /**
     * Feeds one inbound payload to the API lane.
     *
     * The caller still forwards the same payload to the host facade. This method
     * only consumes the three API frame types and ignores everything else, so
     * VFS/EXEC frames keep flowing to their owners unchanged.
     */
    fun onInbound(payload: ByteArray) {
        inbound.trySend(payload)
        val type = frameTypeOf(payload) ?: return
        trace?.invoke("worker->host", frameTypeName(type), seqOf(payload))
        if (type != apiRes && type != apiEnd && type != apiAbort) return
        val fields = try {
            JsonValue.parse(WireCodec.decode(payload)) as? JsonObject
        } catch (_: Exception) {
            // The channel's own decoder owns malformed frames; a test driver that
            // guesses would hide a protocol defect.
            return
        } ?: return
        val reqId = fields.long("req_id")?.toInt() ?: return
        val exchange = exchanges[reqId] ?: return
        when (type) {
            apiRes -> {
                val head = (fields["head"] as? JsonObject)?.let { headObject ->
                    ApiResponseHead(
                        status = headObject.long("status")?.toInt() ?: 0,
                        headers = headObject.stringMap("headers"),
                    )
                }
                if (head != null) exchange.head.complete(head)
                val body = fields.hex("body_hex")
                if (body.isNotEmpty()) exchange.body.trySend(body)
            }

            apiEnd -> {
                exchange.body.close()
                exchange.done.complete(Unit)
                exchanges.remove(reqId)
            }

            apiAbort -> {
                val reason = (fields["reason"] as? JsonString)?.value ?: "aborted"
                aborted = reason
                exchange.body.close(IllegalStateException("API request $reqId aborted: $reason"))
                exchange.done.complete(Unit)
                exchanges.remove(reqId)
            }
        }
    }

    /** The first inbound frame received, or `null` after [INBOUND_TIMEOUT_MILLIS]. */
    suspend fun awaitFirstInbound(timeoutMillis: Long = INBOUND_TIMEOUT_MILLIS): ByteArray? =
        withTimeoutOrNull(timeoutMillis) { inbound.receive() }

    /**
     * One unary call: sends `API_REQ`, collects `API_RES` bodies until `API_END`.
     *
     * @throws IllegalStateException on `API_ABORT`, a timeout, or a transport loss.
     */
    suspend fun request(
        method: String,
        path: String,
        headers: Map<String, String> = emptyMap(),
        body: ByteArray = ByteArray(0),
        timeoutMillis: Long = REQUEST_TIMEOUT_MILLIS,
    ): ApiResponse {
        val reqId = requestIds.incrementAndGet()
        val exchange = Exchange()
        exchanges[reqId] = exchange
        sendApiRequest(reqId, method, path, headers, body)
        val completed = withTimeoutOrNull(timeoutMillis) { exchange.done.await() }
        if (completed == null) {
            exchanges.remove(reqId)
            throw IllegalStateException("API $method $path did not finish within $timeoutMillis ms")
        }
        val head = exchange.head.await() ?: ApiResponseHead(0, emptyMap())
        val chunks = ArrayList<ByteArray>()
        for (chunk in exchange.drain()) chunks += chunk
        val combined = ByteArray(chunks.sumOf { it.size })
        var offset = 0
        for (chunk in chunks) {
            chunk.copyInto(combined, offset)
            offset += chunk.size
        }
        return ApiResponse(head, combined)
    }

    /**
     * A long-lived call: the returned flow yields each `API_RES` body chunk as the
     * worker writes it, and completes on `API_END` (or throws on `API_ABORT`).
     *
     * Used for `POST /api/remote.mux` with `x-pdsh-mux-op: receive`, whose response
     * is newline-delimited JSON that ends when the logical mux closes.
     */
    suspend fun stream(
        method: String,
        path: String,
        headers: Map<String, String> = emptyMap(),
        body: ByteArray = ByteArray(0),
    ): ApiStream {
        val reqId = requestIds.incrementAndGet()
        val exchange = Exchange()
        exchanges[reqId] = exchange
        sendApiRequest(reqId, method, path, headers, body)
        return ApiStream(reqId, exchange)
    }

    /** Forgets one exchange (called by [ApiStream.close]). */
    internal fun forget(reqId: Int) = exchanges.remove(reqId)

    /** The abort reason the worker reported, when one arrived. */
    fun abortReason(): String? = aborted

    private suspend fun sendApiRequest(
        reqId: Int,
        method: String,
        path: String,
        headers: Map<String, String>,
        body: ByteArray,
    ) {
        val head = JsonObject(
            linkedMapOf(
                "method" to JsonString(method),
                "path" to JsonString(path),
                "headers" to JsonObject(
                    linkedMapOf(*headers.entries.map { (name, value) ->
                        name.lowercase() to JsonString(value)
                    }.toTypedArray()),
                ),
            ),
        )
        val fields = JsonObject(
            linkedMapOf(
                "req_id" to JsonNumber(reqId.toString()),
                "head" to head,
                "body_hex" to JsonString(hex(body)),
            ),
        )
        sendFrame("API_REQ", fields)
    }

    /**
     * Encodes one frame with the Rust codec and sends it at the next seq.
     *
     * The seq is allocated here and encoded into the frame, because the codec
     * refuses a placeholder (`BAD_SEQ: frame seq starts at 1`). Both writer paths
     * therefore take the same mutex and the same counter.
     */
    internal suspend fun sendFrame(type: String, fields: JsonObject) {
        val json = "{\"type\":\"$type\",\"fields\":${fields.toJsonString()}}"
        sendMutex.withLock {
            val seq = nextSeq
            nextSeq += 1
            trace?.invoke("host->worker", type, seq)
            target.sendBinary(WireCodec.encode(json, seq))
        }
    }

    /** One completed exchange; the body chunks are handed over in wire order. */
    internal inner class Exchange {
        val head = CompletableDeferred<ApiResponseHead?>()
        val body = Channel<ByteArray>(Channel.UNLIMITED)
        val done = CompletableDeferred<Unit>()

        /** Drains whatever the worker wrote before `API_END`. */
        suspend fun drain(): List<ByteArray> {
            val chunks = ArrayList<ByteArray>()
            while (true) {
                val next = body.tryReceive()
                if (next.isSuccess) {
                    chunks += next.getOrNull()!!
                    continue
                }
                break
            }
            return chunks
        }
    }

    /** A live `API_RES` stream. [close] forgets the exchange when the caller is done. */
    inner class ApiStream internal constructor(
        val reqId: Int,
        private val exchange: Exchange,
    ) {
        /** Body chunks in wire order; completes on `API_END`. */
        fun body(): Flow<ByteArray> = exchange.body.consumeAsFlow()

        /** The raw chunk channel, for a caller that reads with its own deadline. */
        fun chunks(): ReceiveChannel<ByteArray> = exchange.body

        /** Stops listening (the worker may still be writing; the turn is over). */
        fun close() {
            forget(reqId)
        }
    }

    private fun withSeq(payload: ByteArray, seq: Long): ByteArray {
        if (payload.size < HEADER_BYTES) return payload
        val copy = payload.copyOf()
        var value = seq
        for (offset in 11 downTo 4) {
            copy[offset] = (value and 0xFF).toByte()
            value = value ushr 8
        }
        return copy
    }

    private fun seqOf(payload: ByteArray): Long {
        var value = 0L
        for (offset in 4 until 12) value = (value shl 8) or (payload[offset].toLong() and 0xFF)
        return value
    }

    private fun frameTypeName(type: Int): String = when (type) {
        0x01 -> "HELLO"
        0x10 -> "VFS_MUT"
        0x11 -> "VFS_ACK"
        0x12 -> "VFS_BARRIER"
        0x13 -> "VFS_RESYNC"
        0x20 -> "EXEC_REQ"
        0x21 -> "EXEC_EVT"
        0x22 -> "EXEC_CTL"
        0x30 -> "JOURNAL"
        0x31 -> "JOURNAL_ACK"
        0x40 -> "API_REQ"
        0x41 -> "API_RES"
        0x42 -> "API_END"
        0x43 -> "API_ABORT"
        0x50 -> "LIFECYCLE"
        0x60 -> "CONSOLE"
        0x70 -> "FENCE"
        0x7F -> "ERROR"
        else -> "0x" + type.toString(16)
    }

    private fun frameTypeOf(payload: ByteArray): Int? {
        if (payload.size < HEADER_BYTES) return null
        val magic = ((payload[0].toInt() and 0xFF) shl 8) or (payload[1].toInt() and 0xFF)
        if (magic != MAGIC) return null
        return payload[2].toInt() and 0xFF
    }

    private fun hex(bytes: ByteArray): String = buildString(bytes.size * 2) {
        for (byte in bytes) {
            val value = byte.toInt() and 0xFF
            append(HEX[value ushr 4]).append(HEX[value and 0x0F])
        }
    }

    private fun JsonObject.long(name: String): Long? = (this[name] as? JsonNumber)?.asLongOrNull()

    private fun JsonObject.hex(name: String): ByteArray {
        val text = (this[name] as? JsonString)?.value ?: return ByteArray(0)
        if (text.length % 2 != 0) return ByteArray(0)
        val bytes = ByteArray(text.length / 2)
        for (index in bytes.indices) {
            val high = Character.digit(text[index * 2], 16)
            val low = Character.digit(text[index * 2 + 1], 16)
            if (high < 0 || low < 0) return ByteArray(0)
            bytes[index] = ((high shl 4) or low).toByte()
        }
        return bytes
    }

    private fun JsonObject.stringMap(name: String): Map<String, String> {
        val object_ = this[name] as? JsonObject ?: return emptyMap()
        val out = LinkedHashMap<String, String>()
        for ((key, value) in object_.members) {
            (value as? JsonString)?.let { out[key] = it.value }
        }
        return out
    }

    private companion object {
        const val HEADER_BYTES = 16
        const val MAGIC = 0x5A4C
        const val CHANNEL_API_RES = 0x41
        const val CHANNEL_API_END = 0x42
        const val CHANNEL_API_ABORT = 0x43
        const val HEX = "0123456789abcdef"
        const val REQUEST_TIMEOUT_MILLIS = 60_000L
        const val INBOUND_TIMEOUT_MILLIS = 60_000L
    }
}
