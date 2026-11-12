// SPDX-License-Identifier: MIT
// phone-dsh — :domain / com.phonedsh.domain.device.tonolink: the TonoLink board's
// voice turn on the ctrl GATT service (spec/device/v1/tonolink-board.md §4.1;
// shared cases spec/device/v1/golden/tonolink-voice.json).
//
//   status notify  `ev wake n=<u32> up=<u32>`                        board heard 你好小智
//   cmd write      `<seq> listen <id>`                               record one turn
//   audio notify   `[seq u16 LE][flags][id & 0xFF][Opus 20 ms]`      one frame per packet
//   status notify  `ev listen_end n=<id> frames=<u32> reason=<r>`    the turn ended
//
// The parser is deliberately the contract's whole truth: a line that is not one
// of the two events, lacks a member, carries a non-decimal value or an unknown
// reason is ignored (null), and unknown `key=value` members are ignored. An
// audio packet that is malformed or belongs to another turn is dropped (null).
package com.phonedsh.domain.device.tonolink

/** One `status` notification of the voice turn. */
sealed interface TonoLinkVoiceEvent {
    /** `ev wake n=<u32> up=<u32>`: the board heard 你好小智. */
    data class Wake(val n: UInt, val upMs: UInt) : TonoLinkVoiceEvent

    /** `ev listen_end n=<id> frames=<u32> reason=<r>`: the turn ended. */
    data class ListenEnd(val n: UInt, val frames: UInt, val reason: Reason) : TonoLinkVoiceEvent

    /** The closed set of `reason=` values. */
    enum class Reason(val wire: String) {
        VAD("vad"),
        NO_SPEECH("no_speech"),
        MAX("max"),
        CANCEL("cancel"),
        ERROR("error"),
    }

    companion object {
        /**
         * A `status` line, or null when it is not one of the two events.
         *
         * Members are `key=value` tokens after the event name; the first value
         * for a key wins, and unknown keys are ignored. A member without `=`
         * invalidates the line, as does any non-decimal value for a required
         * member (§4.1: ignored, never treated as an event).
         */
        fun parse(line: String): TonoLinkVoiceEvent? {
            val tokens = line.trim().split(' ').filter { it.isNotEmpty() }
            if (tokens.size < 2 || tokens[0] != "ev") return null
            val members = LinkedHashMap<String, String>()
            for (token in tokens.drop(2)) {
                val equals = token.indexOf('=')
                if (equals < 0) return null
                members.putIfAbsent(token.substring(0, equals), token.substring(equals + 1))
            }
            return when (tokens[1]) {
                "wake" -> {
                    val n = decimal(members["n"]) ?: return null
                    val up = decimal(members["up"]) ?: return null
                    Wake(n = n, upMs = up)
                }

                "listen_end" -> {
                    val n = decimal(members["n"]) ?: return null
                    val frames = decimal(members["frames"]) ?: return null
                    val reason = Reason.entries.firstOrNull { it.wire == members["reason"] } ?: return null
                    ListenEnd(n = n, frames = frames, reason = reason)
                }

                else -> null
            }
        }

        /** Plain ASCII decimal digits only: `+1`, `-1`, `0x1` and empty are rejected. */
        private fun decimal(value: String?): UInt? {
            if (value.isNullOrEmpty()) return null
            if (!value.all { it in '0'..'9' }) return null
            return value.toUIntOrNull()
        }
    }
}

/** One `audio` notification of the current turn. */
class TonoLinkVoicePacket(
    val seq: Int,
    val first: Boolean,
    val last: Boolean,
    /** The raw Opus frame, forwarded unchanged; empty only on a last packet. */
    val opus: ByteArray,
) {
    /** Nil when the packet is malformed or belongs to another turn (§4.1: dropped). */
    companion object {
        const val HEADER_BYTES = 4
        const val OPUS_MAX_BYTES = 160
        const val FRAME_MS = 20
        const val FLAG_FIRST = 1
        const val FLAG_LAST = 2

        fun parse(data: ByteArray, turnId: UInt): TonoLinkVoicePacket? {
            if (data.size < HEADER_BYTES || data.size > HEADER_BYTES + OPUS_MAX_BYTES) return null
            if ((data[3].toInt() and 0xFF) != (turnId.toInt() and 0xFF)) return null
            val flags = data[2].toInt() and 0xFF
            val opus = data.copyOfRange(HEADER_BYTES, data.size)
            if (opus.isEmpty() && flags and FLAG_LAST == 0) return null
            return TonoLinkVoicePacket(
                seq = (data[0].toInt() and 0xFF) or ((data[1].toInt() and 0xFF) shl 8),
                first = flags and FLAG_FIRST != 0,
                last = flags and FLAG_LAST != 0,
                opus = opus,
            )
        }
    }

    override fun equals(other: Any?): Boolean =
        this === other ||
            (other is TonoLinkVoicePacket &&
                seq == other.seq &&
                first == other.first &&
                last == other.last &&
                opus.contentEquals(other.opus))

    override fun hashCode(): Int {
        var result = seq
        result = 31 * result + first.hashCode()
        result = 31 * result + last.hashCode()
        result = 31 * result + opus.contentHashCode()
        return result
    }

    override fun toString(): String =
        "TonoLinkVoicePacket(seq=$seq, first=$first, last=$last, opus=${opus.size} bytes)"
}

/** `<seq> listen <id>`: starts one recording turn. */
object TonoLinkVoiceCommand {
    /**
     * The exact `cmd` line for one turn. `id` 0 would let the board number the
     * turn, so it is not allowed here (§4.1: the phone numbers it 1…2³²−1).
     */
    fun listen(seq: Int, id: UInt): ByteArray {
        require(seq in 0..0xFFFF) { "listen seq must be 0…65535" }
        require(id != 0u) { "listen id must be 1…4294967295" }
        return "$seq listen ${id.toString()}".toByteArray(Charsets.US_ASCII)
    }
}

/** Counts what arrived in one turn, for diagnostics (`seq` gaps are counted, not filled). */
class TonoLinkVoiceTally {
    var packets: Int = 0
        private set
    var gaps: Int = 0
        private set
    var dropped: Int = 0
        private set
    private var nextSeq: Int? = null

    fun record(packet: TonoLinkVoicePacket?) {
        if (packet == null) {
            dropped += 1
            return
        }
        val expected = nextSeq
        if (expected != null && packet.seq != expected) gaps += 1
        nextSeq = (packet.seq + 1) and 0xFFFF
        packets += 1
    }
}
