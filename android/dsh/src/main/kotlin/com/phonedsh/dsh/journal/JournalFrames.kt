// phone-dsh — :dsh / com.phonedsh.dsh.journal: the JOURNAL frames of channel.md §3.5/§3.6.
// SPDX-License-Identifier: MIT
//
// ---- one layout, and it is the Rust codec's -------------------------------
// `JOURNAL` is `jseq | session_id_len | session_id | record` (§3.5), and
// `JOURNAL_ACK` is `level | session_id_len | session_id | upto_jseq` (§3.6).
// Both layouts live in `pdsh-wire`; this file is the typed projection of the
// decoded `fields` object plus one encoder for the answer. There is no second
// offset table here: `WireCodec.decode` has already validated the header,
// `jseq >= 1`, the UTF-8 session id and a non-empty record, and `record_hex` is
// the binary member of `golden/README.md` §3.
//
// ---- why the hex is decoded here ------------------------------------------
// The codec returns the record as `record_hex` (the golden field table), and
// the store must keep the bytes exactly: the host treats the record as opaque
// and must never re-serialize it. `java.util.HexFormat` is API 34+ on Android
// and this module ships minSdk 26, so the small strict decoder below is the
// portable one. `:dsh`'s VFS decoder has a private twin in VfsFrames.kt; a
// shared helper would belong in `:core`, which this lane may not edit, so the
// duplication is reported instead of hidden.

package com.phonedsh.dsh.journal

import com.phonedsh.agentcore.JsonNumber
import com.phonedsh.agentcore.JsonObject
import com.phonedsh.agentcore.JsonString
import com.phonedsh.agentcore.JsonValue
import com.phonedsh.agentcore.toJsonString
import com.phonedsh.wire.WireCodec
import com.phonedsh.wire.WireException

/**
 * One decoded `JOURNAL` (`0x30`) frame: an opaque record at `(sessionId, jseq)`.
 *
 * @property jseq the per-session sequence number, `>= 1` and consecutive from 1.
 * @property sessionId the D6 session id (§6).
 * @property record the opaque tool-journal record bytes, at least one byte.
 */
class JournalRecord internal constructor(
    val jseq: Long,
    val sessionId: String,
    val record: ByteArray,
) {
    /** Content equality: two records are the same evidence only when the bytes are. */
    override fun equals(other: Any?): Boolean =
        this === other ||
            (other is JournalRecord &&
                jseq == other.jseq &&
                sessionId == other.sessionId &&
                record.contentEquals(other.record))

    /** Content hash, consistent with [equals]. */
    override fun hashCode(): Int {
        var result = jseq.hashCode()
        result = 31 * result + sessionId.hashCode()
        result = 31 * result + record.contentHashCode()
        return result
    }

    override fun toString(): String = "JournalRecord(jseq=$jseq, sessionId=$sessionId, bytes=${record.size})"
}

/**
 * The result of decoding one `JOURNAL` frame.
 *
 * [Invalid] carries a `channel.md` §10 code so the channel can answer with one
 * closing `ERROR`; nothing has been written when it is returned.
 */
sealed interface JournalFrame {
    /** A legal frame; the sink may append it. */
    data class Parsed(val value: JournalRecord) : JournalFrame

    /**
     * A refused frame.
     *
     * @property code a §10 code (`BAD_PAYLOAD` for every structural failure).
     * @property detail safe to log and to put in the `ERROR` message.
     */
    data class Invalid(val code: String, val detail: String) : JournalFrame

    companion object {
        /** `channel.md` §6: `session_id` is `^[A-Za-z0-9._-]{1,64}$`. */
        val SESSION_ID: Regex = Regex("[A-Za-z0-9._-]{1,64}")

        /**
         * Decodes one whole `JOURNAL` frame through the one Rust codec.
         *
         * A codec refusal keeps its own §10 code; a JSON failure or a missing
         * member is `BAD_PAYLOAD`. The frame's type byte was already routed by
         * the channel, so this assumes the `0x30` variant.
         */
        fun parse(frame: ByteArray): JournalFrame {
            val json = try {
                WireCodec.decode(frame)
            } catch (error: WireException) {
                return Invalid(error.code, error.detail)
            } catch (error: RuntimeException) {
                return Invalid("BAD_PAYLOAD", "JOURNAL could not be decoded (${error.javaClass.simpleName})")
            }
            val fields = try {
                JsonValue.parse(json)
            } catch (error: RuntimeException) {
                return Invalid("BAD_PAYLOAD", "JOURNAL fields are not JSON (${error.javaClass.simpleName})")
            } as? JsonObject ?: return Invalid("BAD_PAYLOAD", "JOURNAL fields are not an object")

            val sessionId = (fields["session_id"] as? JsonString)?.value
                ?: return Invalid("BAD_PAYLOAD", "JOURNAL has no string session_id")
            if (!SESSION_ID.matches(sessionId)) {
                return Invalid("BAD_PAYLOAD", "JOURNAL session_id is not a D6 identifier")
            }
            val jseq = (fields["jseq"] as? JsonNumber)?.asLongOrNull()
                ?: return Invalid("BAD_PAYLOAD", "JOURNAL has no integer jseq")
            if (jseq < 1L) return Invalid("BAD_PAYLOAD", "JOURNAL jseq starts at 1, was $jseq")
            val recordHex = (fields["record_hex"] as? JsonString)?.value
                ?: return Invalid("BAD_PAYLOAD", "JOURNAL has no string record_hex")
            val record = hexToBytes(recordHex)
                ?: return Invalid("BAD_PAYLOAD", "JOURNAL record_hex is not hex")
            if (record.isEmpty()) {
                return Invalid("BAD_PAYLOAD", "a JOURNAL record carries at least one byte")
            }
            return Parsed(JournalRecord(jseq = jseq, sessionId = sessionId, record = record))
        }
    }
}

/**
 * One `JOURNAL_ACK` (`0x31`) the host sends: §3.6's `level | session_id | upto_jseq`.
 *
 * [LEVEL_FSYNC] is the only level this host sends, because a record is appended
 * **and fsynced** before its acknowledgement exists (see [JournalSink]); the
 * worker's tracker treats a level-2 acknowledgement as implying level 1, so the
 * level-1 wait on a `tool-journal` append resolves on this same frame. [LEVEL_WRITE]
 * is kept as the vocabulary of the spec, not as a value this host produces.
 *
 * @property level 1 (journal `write()` returned) or 2 (journal fsync).
 * @property sessionId the session the watermark belongs to.
 * @property uptoJseq the highest contiguous `jseq` the host holds.
 */
data class JournalAck(
    val level: Int,
    val sessionId: String,
    val uptoJseq: Long,
) {
    init {
        require(level == LEVEL_WRITE || level == LEVEL_FSYNC) {
            "JOURNAL_ACK level is 1 or 2, was $level"
        }
        require(JournalFrame.SESSION_ID.matches(sessionId)) {
            "JOURNAL_ACK session_id is not a D6 identifier"
        }
        require(uptoJseq >= 0L) { "JOURNAL_ACK upto_jseq is non-negative, was $uptoJseq" }
    }

    /** The §3.6 `fields` object, canonical through the one JSON writer. */
    fun fieldsJson(): String = JsonObject(
        linkedMapOf(
            "level" to JsonNumber(level.toString()),
            "session_id" to JsonString(sessionId),
            "upto_jseq" to JsonNumber(uptoJseq.toString()),
        ),
    ).toJsonString()

    /**
     * Encodes the whole frame for the host's next outbound [seq] (§1).
     *
     * @throws com.phonedsh.wire.WireException the codec refused the fields.
     * @throws com.phonedsh.wire.WireUnavailable the JNI library is not packaged.
     */
    fun encode(seq: Long): ByteArray =
        WireCodec.encode("{\"type\":\"JOURNAL_ACK\",\"fields\":${fieldsJson()}}", seq)

    companion object {
        /** §3.6: `level = 1`, the journal `write()` returned. */
        const val LEVEL_WRITE: Int = 1

        /** §3.6: `level = 2`, the journal fsync returned. The only level this host sends. */
        const val LEVEL_FSYNC: Int = 2
    }
}

/**
 * Strict lowercase-or-uppercase hex decoding, `null` when [hex] is malformed.
 *
 * The codec emits lowercase; uppercase is accepted because the golden field
 * table promises a hex member, not a case. An odd length or a non-hex character
 * is a `BAD_PAYLOAD`, never a partially decoded record.
 */
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
