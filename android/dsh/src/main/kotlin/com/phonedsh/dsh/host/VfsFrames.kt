// phone-dsh — :dsh / com.phonedsh.dsh.host: the typed VFS frames of channel.md §3.
// SPDX-License-Identifier: MIT
//
// ---- why there is no second binary layout in this file ---------------------
// The `VFS_MUT` payload is `mseq | op | mode | mflags | append_from | path_len |
// path | data_len | data` (channel.md §3.1). That layout is implemented once, in
// the Rust `pdsh-wire` codec, and this file is the typed projection of the
// `fields` object that `WireCodec.decode` returns. Re-implementing the offsets
// here would create a second parser that can disagree with the codec the worker
// uses; the codec already enforces every structural field (mseq, op, mflags,
// UTF-8 path, lengths) and the 15 MiB data bound.
//
// What remains here is the semantic layer the codec deliberately leaves to the
// channel: turning the decoded fields into a `MutationBody` (which validates the
// D4 path grammar and the op/mode/mflags consistency) and encoding the
// host-to-worker frames `VFS_ACK`, `VFS_RESYNC` and `ERROR`.

package com.phonedsh.dsh.host

import com.phonedsh.agentcore.JsonNumber
import com.phonedsh.agentcore.JsonObject
import com.phonedsh.agentcore.JsonString
import com.phonedsh.agentcore.JsonValue
import com.phonedsh.agentcore.toJsonString
import com.phonedsh.log.MutationBody
import com.phonedsh.log.VfsOp
import com.phonedsh.wire.WalException
import com.phonedsh.wire.WireCodec
import com.phonedsh.wire.WireException

/** One typed outbound frame the VFS sink can emit. */
sealed interface VfsFrame {
    /** Encodes the frame for the host's next outbound [seq] (channel.md §1). */
    fun encode(seq: Long): ByteArray

    /**
     * `VFS_ACK` (§3.2): `level | upto_mseq`.
     *
     * @property level 1 (WAL `write()` returned) or 2 (epoch close, D18).
     * @property uptoMseq the highest contiguous mseq covered.
     */
    data class Ack(val level: Int, val uptoMseq: Long) : VfsFrame {
        init {
            require(level == 1 || level == 2) { "VFS_ACK level is 1 or 2, was $level" }
            require(uptoMseq >= 0L) { "VFS_ACK upto_mseq is non-negative, was $uptoMseq" }
        }

        override fun encode(seq: Long): ByteArray = WireCodec.encode(
            """{"type":"VFS_ACK","fields":{"level":$level,"upto_mseq":$uptoMseq}}""",
            seq,
        )
    }

    /**
     * `VFS_RESYNC` (§3.4): asks for a complete re-send of [path].
     *
     * Sent when an appended mutation's base did not match; the sink never
     * blocks waiting for the repair.
     */
    data class Resync(val path: String) : VfsFrame {
        override fun encode(seq: Long): ByteArray {
            val fields = JsonObject(linkedMapOf<String, JsonValue>("path" to JsonString(path)))
            return WireCodec.encode("{\"type\":\"VFS_RESYNC\",\"fields\":${fields.toJsonString()}}", seq)
        }
    }

    /**
     * `ERROR` (§4.8).
     *
     * @property code a §10 code.
     * @property message human-readable detail; no token or local path.
     * @property refSeq the inbound frame's seq, when known.
     * @property closeConnection `true` for every closing code; `VFS_REFUSED`
     *   would be the only diagnostic and it is not produced in this lane.
     * @property path/limit/reason/mseq/acceptedBytes the optional structured
     *   members of §4.8, unused today but kept so `VFS_REFUSED` needs no new
     *   frame type.
     */
    data class Error(
        val code: String,
        val message: String,
        val refSeq: Long? = null,
        val closeConnection: Boolean = true,
        val path: String? = null,
        val limit: Long? = null,
        val reason: String? = null,
        val mseq: Long? = null,
        val acceptedBytes: Long? = null,
    ) : VfsFrame {
        override fun encode(seq: Long): ByteArray {
            val members = linkedMapOf<String, JsonValue>()
            members["code"] = JsonString(code)
            members["message"] = JsonString(message)
            refSeq?.let { members["ref_seq"] = JsonNumber(it.toString()) }
            path?.let { members["path"] = JsonString(it) }
            limit?.let { members["limit"] = JsonNumber(it.toString()) }
            reason?.let { members["reason"] = JsonString(it) }
            mseq?.let { members["mseq"] = JsonNumber(it.toString()) }
            acceptedBytes?.let { members["accepted_bytes"] = JsonNumber(it.toString()) }
            val fields = JsonObject(members)
            return WireCodec.encode("{\"type\":\"ERROR\",\"fields\":${fields.toJsonString()}}", seq)
        }
    }
}

/**
 * A decoded `VFS_MUT` (§3.1), or the stable code that refused it.
 *
 * The bytes are decoded by the Rust codec; [Parsed.body] has passed both the
 * codec's frame checks and [MutationBody.validate] (D4 path, op/mode/mflags
 * consistency).
 */
sealed interface VfsMutFrame {
    /**
     * A structurally valid mutation.
     *
     * @property mseq the worker's host-allocated mseq; the sink checks it
     *   against its own expected value.
     * @property body the validated WAL mutation body.
     */
    data class Parsed(val mseq: Long, val body: MutationBody) : VfsMutFrame

    /**
     * A refusal with a `channel.md` §10 code.
     *
     * @property code always a closing code today (`BAD_PAYLOAD`/`BAD_PATH`/
     *   `BAD_MSEQ`); a resource refusal would be `VFS_REFUSED` and is not
     *   produced here.
     * @property detail safe to log and to put in the ERROR message.
     */
    data class Invalid(val code: String, val detail: String) : VfsMutFrame

    companion object {
        /** `channel.md` §6: one mutation carries at most 15 MiB of data. */
        const val MAX_DATA_BYTES: Int = 15 * 1024 * 1024

        /**
         * Decodes [frame] and validates it as a `VFS_MUT`.
         *
         * The 15 MiB bound is enforced by the Rust decoder itself (it returns
         * `BAD_PAYLOAD` before reading the data), and is checked again here so
         * the typed layer states the limit rather than inheriting it silently.
         */
        fun parse(frame: ByteArray): VfsMutFrame {
            val fields = when (val decoded = decodeFields(frame, "VFS_MUT")) {
                is Decoded.Failure -> return Invalid(decoded.code, decoded.detail)
                is Decoded.Fields -> decoded.value
            }
            val mseq = fields.long("mseq")
                ?: return Invalid("BAD_PAYLOAD", "VFS_MUT has no integer mseq")
            if (mseq < 1L) return Invalid("BAD_MSEQ", "VFS_MUT mseq starts at 1, was $mseq")

            val opCode = fields.long("op")
                ?: return Invalid("BAD_PAYLOAD", "VFS_MUT has no integer op")
            if (opCode < Int.MIN_VALUE || opCode > Int.MAX_VALUE) {
                return Invalid("BAD_PAYLOAD", "VFS_MUT op is out of range: $opCode")
            }
            val op = VfsOp.fromCode(opCode.toInt())
                ?: return Invalid("BAD_PAYLOAD", "unknown VFS mutation op $opCode")

            val mode = fields.long("mode")
                ?: return Invalid("BAD_PAYLOAD", "VFS_MUT has no integer mode")
            if (mode < 0L || mode > Int.MAX_VALUE) {
                return Invalid("BAD_PAYLOAD", "VFS_MUT mode is out of range: $mode")
            }

            val mflags = fields.long("mflags")
                ?: return Invalid("BAD_PAYLOAD", "VFS_MUT has no integer mflags")
            if (mflags < 0L || mflags > 3L) {
                return Invalid("BAD_PAYLOAD", "VFS_MUT mflags has reserved bits set: $mflags")
            }

            val appendFrom = fields.long("append_from")
                ?: return Invalid("BAD_PAYLOAD", "VFS_MUT has no integer append_from")
            if (appendFrom < 0L) return Invalid("BAD_PAYLOAD", "VFS_MUT append_from is negative")

            val path = fields.string("path")
                ?: return Invalid("BAD_PAYLOAD", "VFS_MUT has no string path")

            val dataLen = fields.long("data_len")
                ?: return Invalid("BAD_PAYLOAD", "VFS_MUT has no integer data_len")
            if (dataLen < 0L || dataLen > MAX_DATA_BYTES.toLong()) {
                return Invalid(
                    "BAD_PAYLOAD",
                    "VFS_MUT data_len $dataLen exceeds the 15 MiB mutation bound",
                )
            }
            val dataHex = fields.string("data_hex")
                ?: return Invalid("BAD_PAYLOAD", "VFS_MUT has no data_hex")
            val data = hexToBytes(dataHex)
                ?: return Invalid("BAD_PAYLOAD", "VFS_MUT data_hex is not hex")
            if (data.size.toLong() != dataLen) {
                return Invalid(
                    "BAD_PAYLOAD",
                    "VFS_MUT data_len $dataLen does not match ${data.size} decoded bytes",
                )
            }

            val body = MutationBody(
                op = op,
                mode = mode.toInt(),
                path = path,
                data = data,
                appended = (mflags.toInt() and MutationBody.MFLAG_APPENDED) != 0,
                appendFrom = appendFrom,
                entryChanged = (mflags.toInt() and MutationBody.MFLAG_ENTRY_CHANGED) != 0,
            )
            return try {
                body.validate()
                Parsed(mseq, body)
            } catch (error: WalException) {
                Invalid(error.code, error.detail)
            }
        }
    }
}

/**
 * A decoded `VFS_BARRIER` (§3.3).
 *
 * A barrier is recorded, never awaited: the sink answers immediately when the
 * requested level already covers [Parsed.uptoMseq], and otherwise answers from
 * the append/epoch-close path that reaches it. That is what keeps a barrier from
 * reordering or blocking other frames.
 */
sealed interface VfsBarrierFrame {
    data class Parsed(val wantLevel: Int, val uptoMseq: Long) : VfsBarrierFrame

    data class Invalid(val code: String, val detail: String) : VfsBarrierFrame

    companion object {
        /** Decodes [frame] and validates `want_level`/`upto_mseq`. */
        fun parse(frame: ByteArray): VfsBarrierFrame {
            val fields = when (val decoded = decodeFields(frame, "VFS_BARRIER")) {
                is Decoded.Failure -> return Invalid(decoded.code, decoded.detail)
                is Decoded.Fields -> decoded.value
            }
            val wantLevel = fields.long("want_level")
                ?: return Invalid("BAD_PAYLOAD", "VFS_BARRIER has no integer want_level")
            if (wantLevel != 1L && wantLevel != 2L) {
                return Invalid("BAD_PAYLOAD", "VFS_BARRIER want_level must be 1 or 2, was $wantLevel")
            }
            val uptoMseq = fields.long("upto_mseq")
                ?: return Invalid("BAD_PAYLOAD", "VFS_BARRIER has no integer upto_mseq")
            if (uptoMseq < 0L) {
                return Invalid("BAD_PAYLOAD", "VFS_BARRIER upto_mseq is negative: $uptoMseq")
            }
            return Parsed(wantLevel.toInt(), uptoMseq)
        }
    }
}

// ---------------------------------------------------------------------------
// Decoding helpers
// ---------------------------------------------------------------------------

private sealed interface Decoded {
    data class Fields(val value: JsonObject) : Decoded

    data class Failure(val code: String, val detail: String) : Decoded
}

/**
 * Decodes a whole frame through the one Rust codec and returns its `fields`.
 *
 * A codec refusal keeps its own `channel.md` §10 code; a JSON parse failure is
 * `BAD_PAYLOAD`. The frame's type byte must already have been dispatched by the
 * channel, so the returned object is assumed to be the right variant set.
 */
private fun decodeFields(frame: ByteArray, what: String): Decoded {
    val json = try {
        WireCodec.decode(frame)
    } catch (error: WireException) {
        return Decoded.Failure(error.code, error.detail)
    } catch (error: RuntimeException) {
        return Decoded.Failure("BAD_PAYLOAD", "$what could not be decoded (${error.javaClass.simpleName})")
    }
    val value = try {
        JsonValue.parse(json)
    } catch (error: RuntimeException) {
        return Decoded.Failure("BAD_PAYLOAD", "$what fields are not JSON: ${error.message}")
    }
    val objectValue = value as? JsonObject
        ?: return Decoded.Failure("BAD_PAYLOAD", "$what fields are not an object")
    return Decoded.Fields(objectValue)
}

private fun JsonObject.long(name: String): Long? =
    (this[name] as? JsonNumber)?.asLongOrNull()

private fun JsonObject.string(name: String): String? =
    (this[name] as? JsonString)?.value

/** Strict hex; the Rust codec emits lowercase, and uppercase is accepted too. */
private fun hexToBytes(hex: String): ByteArray? {
    if (hex.length % 2 != 0) return null
    val bytes = ByteArray(hex.length / 2)
    for (index in bytes.indices) {
        val high = hexDigit(hex[index * 2])
        val low = hexDigit(hex[index * 2 + 1])
        if (high < 0 || low < 0) return null
        bytes[index] = ((high shl 4) or low).toByte()
    }
    return bytes
}

private fun hexDigit(character: Char): Int = when (character) {
    in '0'..'9' -> character - '0'
    in 'a'..'f' -> character - 'a' + 10
    in 'A'..'F' -> character - 'A' + 10
    else -> -1
}
