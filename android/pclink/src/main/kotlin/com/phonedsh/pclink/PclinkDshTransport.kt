// SPDX-License-Identifier: MIT
// DSH-facing adapter over `PclinkRpc` (`workspace/1`, §6, §7, §9.2).
//
// The App talks in `JsonValue`; PCLink wire messages carry `PclinkJson`. This
// file owns that conversion, the `$events/result` one-layer rule and the
// mapping of a local PCLink outcome to the DSH-facing error type. It has no
// Android import: C5 constructs it with the real `PclinkRpc`.
package com.phonedsh.pclink

import com.phonedsh.agentcore.JsonArray
import com.phonedsh.agentcore.JsonBool
import com.phonedsh.agentcore.JsonNull
import com.phonedsh.agentcore.JsonNumber
import com.phonedsh.agentcore.JsonObject
import com.phonedsh.agentcore.JsonString
import com.phonedsh.agentcore.JsonValue

/** Lossless-enough conversion between the host `JsonValue` and the wire model. */
object PclinkDshJson {
    fun toPclink(value: JsonValue): PclinkJson = when (value) {
        JsonNull -> PclinkJson.Null
        is JsonBool -> PclinkJson.Bool(value.value)
        is JsonString -> PclinkJson.Text(value.value)
        is JsonNumber -> numberToPclink(value.raw)
        is JsonArray -> PclinkJson.Array(value.values.map(::toPclink))
        is JsonObject -> PclinkJson.Object(
            value.members.entries.associateTo(LinkedHashMap()) { (key, member) -> key to toPclink(member) },
        )
    }

    fun toJsonValue(value: PclinkJson): JsonValue = when (value) {
        PclinkJson.Null -> JsonNull
        is PclinkJson.Bool -> JsonBool(value.value)
        is PclinkJson.Text -> JsonString(value.value)
        is PclinkJson.Integer -> JsonNumber(value.value.toString())
        is PclinkJson.Decimal -> {
            if (!value.value.isFinite()) throw PclinkError.BadFrame("non-finite JSON number")
            JsonNumber(value.value.toString())
        }
        is PclinkJson.Array -> JsonArray(value.values.map(::toJsonValue))
        is PclinkJson.Object -> JsonObject(
            value.members.entries.associateTo(LinkedHashMap()) { (key, member) -> key to toJsonValue(member) },
        )
    }

    private fun numberToPclink(raw: String): PclinkJson {
        if (raw.indexOf('.') < 0 && raw.indexOf('e') < 0 && raw.indexOf('E') < 0) {
            raw.toLongOrNull()?.let { return PclinkJson.Integer(it) }
        }
        val value = raw.toDoubleOrNull()
        if (value == null || !value.isFinite()) throw PclinkError.BadFrame("JSON number out of range")
        return PclinkJson.Decimal(value)
    }
}

/**
 * The transport the app uses to call PC `workspace/1` endpoints. A unary
 * [call] returns the DSH `result` value; [openMux] opens a multiplexer whose
 * streams yield DSH values. Errors are split the same way the PC splits them:
 * a DSH endpoint error stays a [PclinkRpcError] with its own code/message, a
 * transport/pairing outcome is projected through [projection] (never a
 * credential refresh, §9.2).
 */
class PclinkDshTransport(
    private val rpc: PclinkRpc,
    private val projection: PclinkErrorProjection = DEFAULT_PROJECTION,
) {
    /**
     * One `rpc.call` (§6.1). `args` must be a JSON object; for `$events/result`
     * it must be exactly `{clientId,eventId,outcome}` in one layer.
     */
    suspend fun call(endpoint: String, args: JsonValue): JsonValue {
        val objectArgs = args as? JsonObject
            ?: throw PclinkError.BadFrame("args must be a JSON object")
        if (endpoint == EVENTS_RESULT_ENDPOINT) validateEventsResultArgs(objectArgs)
        try {
            val result = rpc.call(endpoint, PclinkDshJson.toPclink(objectArgs))
            return PclinkDshJson.toJsonValue(result)
        } catch (error: PclinkRpcError) {
            throw error
        } catch (error: PclinkError) {
            throw projection.project(error)
        }
    }

    /** The §6.1 one-layer `$events/result` answer; first answer wins on the PC. */
    suspend fun answerEvents(clientId: String, eventId: String, outcome: JsonValue): JsonValue =
        call(
            EVENTS_RESULT_ENDPOINT,
            JsonObject(
                linkedMapOf(
                    "clientId" to JsonString(clientId),
                    "eventId" to JsonString(eventId),
                    "outcome" to outcome,
                ),
            ),
        )

    /** Opens a stream multiplexer bound to the same E2E session (§6.2). */
    suspend fun openMux(): PclinkDshMux = PclinkDshMux(rpc, projection)

    /** Releases every stream and the RPC instance; idempotent. */
    fun close() = rpc.close()

    private fun validateEventsResultArgs(args: JsonObject) {
        val expected = setOf("clientId", "eventId", "outcome")
        if (args.members.keys != expected) {
            throw PclinkError.BadFrame("$EVENTS_RESULT_ENDPOINT args must be exactly {clientId,eventId,outcome}")
        }
        for (key in listOf("clientId", "eventId")) {
            val value = args[key] as? JsonString
                ?: throw PclinkError.BadFrame("$EVENTS_RESULT_ENDPOINT $key must be a string")
            if (value.value.isEmpty()) {
                throw PclinkError.BadFrame("$EVENTS_RESULT_ENDPOINT $key must not be empty")
            }
        }
    }

    companion object {
        const val EVENTS_RESULT_ENDPOINT: String = "\$events/result"

        /**
         * Local PCLink outcome → DSH-facing error. Codes the app must
         * distinguish (`unknown_outcome`, `peer_offline`, `forbidden`,
         * `frame_too_large`, `bad_frame`, `rate_limited`, `session_expired`)
         * keep their meaning; anything else is displayed as `unavailable` with
         * the original message (§9.1/§9.2). This is not an on-wire error object
         * and never feeds a PCLink code back into `rpc.result.error`.
         */
        val DEFAULT_PROJECTION: PclinkErrorProjection = PclinkErrorProjection { error ->
            val code = when (error) {
                is PclinkError.UnknownOutcome -> "unknown_outcome"
                is PclinkError.PeerOffline -> "peer_offline"
                is PclinkError.Forbidden -> "forbidden"
                is PclinkError.FrameTooLarge -> "frame_too_large"
                is PclinkError.BadFrame -> "bad_frame"
                is PclinkError.RateLimited -> "rate_limited"
                is PclinkError.Unavailable -> "unavailable"
                is PclinkError.SessionExpired -> "session_expired"
                else -> "unavailable"
            }
            PclinkRpcError(code = code, message = error.message ?: error.code)
        }
    }
}

/**
 * One multiplexer over an E2E session (§6.2). Local stream ids are per mux;
 * PCLink wire ids are allocated by [PclinkRpc] and never reused in a session.
 */
class PclinkDshMux internal constructor(
    private val rpc: PclinkRpc,
    private val projection: PclinkErrorProjection,
) {
    private val lock = Any()
    private val streams = LinkedHashMap<String, PclinkDshMuxStream>()
    private val opening = HashSet<String>()

    @Volatile
    private var closed = false

    /**
     * Opens one `rpc.stream.open` for [endpoint]. [streamId] is the local mux
     * id (1–64 §6.1 correlation characters); it is unique for the lifetime of
     * the mux.
     */
    suspend fun open(streamId: String, endpoint: String, args: JsonValue): PclinkDshMuxStream {
        if (!PclinkValidation.isCorrelationId(streamId)) {
            throw PclinkError.BadFrame("invalid streamId")
        }
        val objectArgs = args as? JsonObject
            ?: throw PclinkError.BadFrame("args must be a JSON object")
        synchronized(lock) {
            if (closed) throw PclinkError.Cancelled()
            if (streamId in streams || streamId in opening) {
                throw PclinkError.BadFrame("duplicate or reused streamId")
            }
            opening.add(streamId)
        }
        val handle = try {
            rpc.openStream(endpoint, PclinkDshJson.toPclink(objectArgs))
        } catch (error: PclinkRpcError) {
            throw error
        } catch (error: PclinkError) {
            throw projection.project(error)
        } finally {
            synchronized(lock) { opening.remove(streamId) }
        }
        val stream = PclinkDshMuxStream(streamId, handle, projection)
        synchronized(lock) {
            if (closed) {
                handle.close()
                throw PclinkError.Cancelled()
            }
            streams[streamId] = stream
        }
        return stream
    }

    /** Sends `rpc.stream.cancel` for [streamId]; unknown/terminal ids are ignored. */
    suspend fun cancel(streamId: String) {
        val stream = synchronized(lock) { streams[streamId] } ?: return
        stream.cancel()
    }

    /** Cancels and releases every stream. */
    fun close() {
        val open = synchronized(lock) {
            val values = streams.values.toList()
            streams.clear()
            closed = true
            values
        }
        for (stream in open) stream.close()
    }
}

/** One value stream opened through [PclinkDshMux]. */
class PclinkDshMuxStream internal constructor(
    val streamId: String,
    private val handle: PclinkRpcStream,
    private val projection: PclinkErrorProjection,
) {
    /** Returns the next DSH value, or `null` when the stream ended. */
    suspend fun receive(): JsonValue? = try {
        handle.next()?.let(PclinkDshJson::toJsonValue)
    } catch (error: PclinkRpcError) {
        throw error
    } catch (error: PclinkError) {
        throw projection.project(error)
    }

    suspend fun cancel() = handle.cancel()

    fun close() = handle.close()
}
