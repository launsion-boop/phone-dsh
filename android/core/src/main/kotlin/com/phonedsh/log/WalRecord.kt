// The record frames of wal.md §3 and the §4 epoch close.
// SPDX-License-Identifier: MIT

package com.phonedsh.log

import com.phonedsh.wire.NativeWire
import java.nio.ByteBuffer

/**
 * One record of a WAL segment: a mutation (`wal.md` §3) or an epoch close
 * (`wal.md` §4). Those are the only two kinds that exist.
 *
 * The record's wire `mseq` is the first payload field, after `len` and
 * `crc32c`. For an epoch close that field **is** `durable_upto` (D7), which is
 * why [EpochClose.mseq] is derived from [EpochClose.durableUpto] rather than
 * stored separately: a close that advanced the mutation sequence would be a
 * different record kind, and no code path here can make one.
 */
sealed interface WalRecord {
    /** The `mseq` field of the record payload. */
    val mseq: Long

    /**
     * A mutation record (`wal.md` §3).
     *
     * @property mseq the mutation's VFS mseq, at least 1 and consecutive.
     * @property body the §3 mutation body.
     */
    data class Mutation(
        override val mseq: Long,
        val body: MutationBody,
    ) : WalRecord

    /**
     * The epoch-close record (`wal.md` §4).
     *
     * @property wallMs Unix epoch milliseconds at the close.
     * @property durableUpto the global maximum mutation mseq appended at the
     *   close, 0 when none. It may be below the segment's `first_mseq` (the idle
     *   epoch of `golden/wal/segment-epoch-only.json`).
     */
    data class EpochClose(
        val wallMs: Long,
        val durableUpto: Long,
    ) : WalRecord {
        /** The record's `mseq` field is [durableUpto] (D7). */
        override val mseq: Long
            get() = durableUpto
    }
}

/**
 * The `len | crc32c | mseq | body` framing of `wal.md` §3.
 *
 * `len` is a `u32` that covers `mseq` and `body` and excludes `len` and
 * `crc32c`; `crc32c` covers `mseq ‖ body` only. The CRC is reached through
 * [NativeWire.crc32c] — this package must never grow a second CRC32C.
 */
internal object WalRecordCodec {
    /** `len` and `crc32c` in front of every payload. */
    const val PREFIX_BYTES: Int = 8

    /** The `op` byte of the epoch-close body (`wal.md` §4). */
    const val OP_EPOCH_CLOSE: Int = 0xFF

    /** The fixed `op | wall_ms | durable_upto` close body. */
    const val EPOCH_CLOSE_BODY_BYTES: Int = 17

    /** The `u64` mseq in front of every body. */
    const val MSEQ_BYTES: Int = 8

    /**
     * The largest `len` a conforming record can declare: the mseq, the §3 body
     * header, the largest `u16` path, the `u32` `data_len` and at most
     * [MutationBody.MAX_DATA_BYTES] of data.
     *
     * `channel.md` §3.1 caps a mutation's `data` at 15 MiB and §6 says the host
     * rejects a larger `data_len` with `BAD_PAYLOAD`; `wal.md` §3 applies those
     * invariants to the WAL body unchanged. A declared length above this bound
     * is therefore not a record this host can have written, and
     * [WalSegmentReader] refuses it before allocating the frame.
     */
    val MAX_RECORD_PAYLOAD_BYTES: Int =
        MSEQ_BYTES + MutationBody.BODY_HEADER_BYTES + MutationBody.MAX_PATH_BYTES + 4 +
            MutationBody.MAX_DATA_BYTES

    /** The largest conforming record frame: the 8-byte prefix plus [MAX_RECORD_PAYLOAD_BYTES]. */
    val MAX_RECORD_FRAME_BYTES: Int = PREFIX_BYTES + MAX_RECORD_PAYLOAD_BYTES

    /**
     * Encodes one mutation record, frame included.
     *
     * @throws IllegalArgumentException for an mseq below 1 or a body whose
     *   `len` does not fit a `u32`.
     */
    fun encodeMutation(mseq: Long, body: MutationBody): ByteArray {
        require(mseq >= 1) { "a mutation mseq is at least 1, was $mseq" }
        val bodyBytes = body.encodeBody()
        return frame(mseq, bodyBytes)
    }

    /**
     * Encodes the §4 epoch-close record, frame included.
     *
     * The body is `op = 0xFF`, `wall_ms u64`, `durable_upto u64`, and the
     * record's mseq is [durableUpto].
     */
    fun encodeEpochClose(wallMs: Long, durableUpto: Long): ByteArray {
        require(durableUpto >= 0) { "durable_upto is not negative, was $durableUpto" }
        require(wallMs >= 0) { "wall_ms is not negative, was $wallMs" }
        val body = ByteBuffer.allocate(EPOCH_CLOSE_BODY_BYTES)
            .put(OP_EPOCH_CLOSE.toByte())
            .putLong(wallMs)
            .putLong(durableUpto)
            .array()
        return frame(durableUpto, body)
    }

    /** The total frame length of a body of [bodyBytes] bytes. */
    fun frameLength(bodyBytes: Int): Int = PREFIX_BYTES + MSEQ_BYTES + bodyBytes

    private fun frame(mseq: Long, body: ByteArray): ByteArray {
        val payloadLength = MSEQ_BYTES + body.size
        val payload = ByteBuffer.allocate(payloadLength)
            .putLong(mseq)
            .put(body)
            .array()
        val crc = NativeWire.crc32c(payload)
        return ByteBuffer.allocate(PREFIX_BYTES + payloadLength)
            .putInt(payloadLength)
            .putInt(crc)
            .put(payload)
            .array()
    }
}
