// phone-dsh — :dsh / com.phonedsh.dsh.host: the `/api` lane's value types.
// SPDX-License-Identifier: MIT
//
// `channel.md` §3.7-3.10 fixes the wire shape: a request head JSON and a body
// inside one API_REQ; a response head on the first API_RES only; zero or more
// continuation chunks; API_END when the response is complete; API_ABORT when
// either side terminates it. [HostChannel] owns the routing and the seq; this
// file only names what a caller sees, so the frame code stays readable.
//
// The values are deliberately *not* the HTTP types. A chunk may be arbitrary
// bytes, `head` may be absent on a continuation, and an abort is a first-class
// outcome of the stream, none of which `java.net.http` models.

package com.phonedsh.dsh.host

import com.phonedsh.agentcore.JsonNumber
import com.phonedsh.agentcore.JsonObject
import com.phonedsh.agentcore.JsonString
import com.phonedsh.agentcore.JsonValue
import com.phonedsh.agentcore.toJsonString
import com.phonedsh.wire.WireCodec
import java.util.concurrent.atomic.AtomicInteger
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.channels.ReceiveChannel

/** A typed `/api` failure; [code] is a stable lower-snake cause, never a token. */
class HostApiException(val code: String, message: String) : Exception("$code: $message")

/** The first API_RES head of one exchange (`channel.md` §4.9). */
data class HostApiHead(val status: Int, val headers: Map<String, String>)

/** One completed unary exchange. */
data class HostApiResponse(val head: HostApiHead, val body: ByteArray) {
    /** The response body as UTF-8; DSH's `/api` is JSON. */
    fun bodyText(): String = body.toString(Charsets.UTF_8)
}

/** One live response stream; [chunks] ends when API_END arrives. */
class HostApiStream internal constructor(
    val reqId: Int,
    private val exchange: HostApiExchange,
    private val forget: (Int) -> Unit,
) {
    /** Body chunks in wire order; the channel closes on API_END. */
    fun chunks(): ReceiveChannel<ByteArray> = exchange.body

    /** Stops tracking the exchange; the worker may still be writing it. */
    fun close() = forget(reqId)
}

/** The host-side state of one in-flight request. */
internal class HostApiExchange(val reqId: Int) {
    val head = CompletableDeferred<HostApiHead?>()
    val body = Channel<ByteArray>(Channel.UNLIMITED)
    val done = CompletableDeferred<Unit>()

    @Volatile
    var abortReason: String? = null
        private set

    /** API_END: the response is complete. */
    fun finish() {
        body.close()
        done.complete(Unit)
    }

    /**
     * `API_ABORT` (or a dead connection): terminate locally, never write a frame.
     *
     * The failure is typed by [ChannelLoss.failure], so a stream that ends because
     * the transport died reports `channel_lost` and a Worker-sent abort keeps
     * `api_aborted` (P22).
     */
    fun abort(reason: String) {
        abortReason = reason
        body.close(ChannelLoss.failure(reason, reqId))
        done.complete(Unit)
    }

    /**
     * Copies the chunks that were delivered before API_END.
     *
     * Called only after [done] completed, so nothing can be added afterwards;
     * a closed channel is drained without suspending.
     */
    fun drain(): ByteArray {
        val chunks = ArrayList<ByteArray>()
        while (true) {
            val result = body.tryReceive()
            if (result.isSuccess) {
                chunks += result.getOrNull()!!
                continue
            }
            break
        }
        val total = chunks.sumOf { it.size }
        val combined = ByteArray(total)
        var offset = 0
        for (chunk in chunks) {
            chunk.copyInto(combined, offset)
            offset += chunk.size
        }
        return combined
    }
}

/** Builds and parses the four API payloads through the one Rust codec. */
internal object HostApiFrames {
    /** `{req_id, head, body_hex}` of `channel.md` §3.7. */
    fun encodeRequest(
        reqId: Int,
        method: String,
        path: String,
        headers: Map<String, String>,
        body: ByteArray,
        seq: Long,
    ): ByteArray {
        val headerMembers = LinkedHashMap<String, JsonValue>()
        for ((name, value) in headers) headerMembers[name.lowercase()] = JsonString(value)
        val head = JsonObject(
            linkedMapOf(
                "method" to JsonString(method),
                "path" to JsonString(path),
                "headers" to JsonObject(headerMembers),
            ),
        )
        val fields = JsonObject(
            linkedMapOf(
                "req_id" to JsonNumber(reqId.toString()),
                "head" to head,
                "body_hex" to JsonString(hex(body)),
            ),
        )
        val frame = JsonObject(
            linkedMapOf(
                "type" to JsonString(FrameName.API_REQ),
                "fields" to fields,
            ),
        )
        return WireCodec.encode(frame.toJsonString(), seq)
    }

    /** Decodes any API payload into its `fields` object, or `null` on a codec error. */
    fun fields(payload: ByteArray): JsonObject? = try {
        JsonValue.parse(WireCodec.decode(payload)) as? JsonObject
    } catch (_: Exception) {
        null
    }

    /** The `req_id` of an API_RES/END/ABORT fields object. */
    fun reqId(fields: JsonObject): Int? =
        (fields["req_id"] as? JsonNumber)?.asLongOrNull()?.toInt()

    /** The head of the first API_RES chunk, or `null` on a continuation. */
    fun head(fields: JsonObject): HostApiHead? {
        val head = fields["head"] as? JsonObject ?: return null
        val status = (head["status"] as? JsonNumber)?.asLongOrNull()?.toInt() ?: return null
        val headers = LinkedHashMap<String, String>()
        val rawHeaders = head["headers"] as? JsonObject
        if (rawHeaders != null) {
            for ((name, value) in rawHeaders.members) {
                (value as? JsonString)?.let { headers[name.lowercase()] = it.value }
            }
        }
        return HostApiHead(status = status, headers = headers)
    }

    /** The `body_hex` member as bytes; an absent or malformed value is empty. */
    fun body(fields: JsonObject): ByteArray =
        unhex((fields["body_hex"] as? JsonString)?.value ?: "")

    /** `{"reason": <string>}` of an API_ABORT. */
    fun abortReason(fields: JsonObject): String =
        (fields["reason"] as? JsonString)?.value ?: "aborted"

    fun hex(bytes: ByteArray): String = buildString(bytes.size * 2) {
        for (byte in bytes) {
            val value = byte.toInt() and 0xFF
            append(HEX[value ushr 4]).append(HEX[value and 0x0F])
        }
    }

    fun unhex(text: String): ByteArray {
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

    private const val HEX = "0123456789abcdef"

    private object FrameName {
        const val API_REQ = "API_REQ"
    }
}

/** The request-id allocator; one channel's ids are unique among in-flight ones. */
internal class HostApiIds {
    private val next = AtomicInteger(0)

    fun mint(): Int = next.incrementAndGet()
}
