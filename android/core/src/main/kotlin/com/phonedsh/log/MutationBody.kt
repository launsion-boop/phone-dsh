// The mutation body of wal.md §3 (the VFS_MUT payload without its mseq).
// SPDX-License-Identifier: MIT

package com.phonedsh.log

import com.phonedsh.wire.WalException
import java.nio.ByteBuffer

/**
 * The four VFS mutation ops of `channel.md` §3.1 / `wal.md` §3.
 *
 * @property code the `op` byte.
 */
enum class VfsOp(val code: Int) {
    /** A complete write (or, with `appended`, a suffix from `append_from`). */
    WRITE(1),

    /** A directory create. */
    MKDIR(2),

    /** A remove; a directory means its whole subtree. */
    REMOVE(3),

    /** A POSIX mode change. */
    CHMOD(4),
    ;

    companion object {
        /** The op for [code], or `null` for an unknown byte. */
        fun fromCode(code: Int): VfsOp? = entries.firstOrNull { it.code == code }
    }
}

/**
 * One mutation body: the `VFS_MUT` payload of `channel.md` §3.1 **without** its
 * leading `mseq` (`wal.md` §3).
 *
 * The body is:
 * ```
 * op u8 | mode u32 | mflags u8 | append_from u64 | path_len u16 | path |
 * data_len u32 | data
 * ```
 * The invariants of `channel.md` §3.1 apply unchanged and [validate] enforces
 * them: op 1 write, 2 mkdir, 3 remove, 4 chmod; `mode <= 0o7777`; only a write
 * may set the `appended` flag, and then `data` is the suffix from
 * [appendFrom]; mkdir/remove/chmod carry no data. The D4 path grammar and sink
 * scope are checked too, because the materializer resolves the path below a
 * real directory.
 *
 * `data` is compared by content, not by array identity: two decoded records with
 * the same bytes are the same mutation.
 *
 * @property op the mutation op.
 * @property mode POSIX permission bits, at most `0o7777`; 0 for remove.
 * @property path the absolute VFS path, validated by [VfsPath].
 * @property data the file bytes of a write; empty for mkdir/remove/chmod.
 * @property appended `mflags` bit 1: [data] is the suffix from [appendFrom].
 * @property appendFrom the byte offset an appended suffix starts at; 0 unless
 *   [appended].
 * @property entryChanged `mflags` bit 0, the `channel.md` §3.1 entry-changed
 *   hint. It is recorded faithfully and has no materialization effect.
 */
data class MutationBody(
    val op: VfsOp,
    val mode: Int,
    val path: String,
    val data: ByteArray = ByteArray(0),
    val appended: Boolean = false,
    val appendFrom: Long = 0L,
    val entryChanged: Boolean = false,
) {
    /** The `mflags` byte: bit 0 entry-changed, bit 1 appended. */
    val mflags: Int
        get() = (if (entryChanged) MFLAG_ENTRY_CHANGED else 0) or
            (if (appended) MFLAG_APPENDED else 0)

    /**
     * Enforces the `channel.md` §3.1 / `wal.md` §3 invariants and the D4 path
     * grammar.
     *
     * @throws WalException `BAD_PATH` for a path outside the sink scope or with
     *   a bad component, `BAD_PAYLOAD` for an op/mode/mflags/append_from
     *   inconsistency.
     */
    fun validate() {
        if (mode < 0 || mode > MAX_MODE) {
            throw WalException("BAD_PAYLOAD", "mode $mode is outside 0..4095 (0o7777)")
        }
        val pathBytes = path.toByteArray(Charsets.UTF_8)
        if (pathBytes.size > MAX_PATH_BYTES) {
            throw WalException("BAD_PAYLOAD", "path is ${pathBytes.size} bytes, above $MAX_PATH_BYTES")
        }
        VfsPath.requireValid(path)
        if (data.size > MAX_DATA_BYTES) {
            throw WalException(
                "BAD_PAYLOAD",
                "data is ${data.size} bytes, above the $MAX_DATA_BYTES-byte mutation bound " +
                    "(channel.md §3.1/§6: one VFS_MUT carries at most 15 MiB; a larger file is " +
                    "one complete write plus appended suffixes)",
            )
        }
        when (op) {
            VfsOp.WRITE -> {
                if (!appended && appendFrom != 0L) {
                    throw WalException("BAD_PAYLOAD", "a complete write must have append_from = 0")
                }
                if (appended && appendFrom < 0L) {
                    throw WalException("BAD_PAYLOAD", "append_from is negative")
                }
            }
            VfsOp.MKDIR, VfsOp.CHMOD -> {
                if (mflags != 0 || appendFrom != 0L) {
                    throw WalException("BAD_PAYLOAD", "mkdir/chmod carries no flags or offset")
                }
                if (data.isNotEmpty()) {
                    throw WalException("BAD_PAYLOAD", "mkdir/chmod carries no data")
                }
            }
            VfsOp.REMOVE -> {
                if (mode != 0) {
                    throw WalException("BAD_PAYLOAD", "remove has mode 0")
                }
                if (mflags != 0 || appendFrom != 0L) {
                    throw WalException("BAD_PAYLOAD", "remove carries no flags or offset")
                }
                if (data.isNotEmpty()) {
                    throw WalException("BAD_PAYLOAD", "remove carries no data")
                }
            }
        }
    }

    /** The §3 body bytes, without `len`, `crc32c` or `mseq`. */
    internal fun encodeBody(): ByteArray {
        val pathBytes = path.toByteArray(Charsets.UTF_8)
        val buffer = ByteBuffer.allocate(
            BODY_HEADER_BYTES + pathBytes.size + 4 + data.size,
        )
        buffer.put(op.code.toByte())
        buffer.putInt(mode)
        buffer.put(mflags.toByte())
        buffer.putLong(appendFrom)
        buffer.putShort(pathBytes.size.toShort())
        buffer.put(pathBytes)
        buffer.putInt(data.size)
        buffer.put(data)
        return buffer.array()
    }

    override fun equals(other: Any?): Boolean {
        if (this === other) return true
        if (other !is MutationBody) return false
        return op == other.op &&
            mode == other.mode &&
            path == other.path &&
            data.contentEquals(other.data) &&
            appended == other.appended &&
            appendFrom == other.appendFrom &&
            entryChanged == other.entryChanged
    }

    override fun hashCode(): Int {
        var result = op.hashCode()
        result = 31 * result + mode
        result = 31 * result + path.hashCode()
        result = 31 * result + data.contentHashCode()
        result = 31 * result + appended.hashCode()
        result = 31 * result + appendFrom.hashCode()
        result = 31 * result + entryChanged.hashCode()
        return result
    }

    override fun toString(): String =
        "MutationBody(op=$op, mode=$mode, path=$path, data=${data.size}B, " +
            "appended=$appended, appendFrom=$appendFrom, entryChanged=$entryChanged)"

    companion object {
        /** `channel.md` §3.1's largest `mode`. */
        const val MAX_MODE: Int = 4095

        /** `mflags` bit 0, entry changed. */
        const val MFLAG_ENTRY_CHANGED: Int = 1 shl 0

        /** `mflags` bit 1, appended suffix. */
        const val MFLAG_APPENDED: Int = 1 shl 1

        /** The fixed body prefix before `path` (`wal.md` §3). */
        const val BODY_HEADER_BYTES: Int = 16

        /** A `u16` `path_len`. */
        const val MAX_PATH_BYTES: Int = 0xFFFF

        /**
         * `channel.md` §3.1/§6: the largest `data` one mutation may carry.
         *
         * The wire frame is 15 MiB, the host rejects a larger `data_len` with
         * `BAD_PAYLOAD`, and `wal.md` §3 applies the §3.1 invariants to the WAL
         * body unchanged. This was `Int.MAX_VALUE`, which let this host append
         * a record it could not then recover on a memory-constrained device:
         * 128 MiB of data in one record meant a ~6x heap copy in recovery and
         * an `OutOfMemoryError` on every boot. A larger file is one complete
         * write plus appended suffixes, never one giant mutation.
         */
        const val MAX_DATA_BYTES: Int = 15 * 1024 * 1024

        /** The empty data array; shared to avoid an allocation per mkdir. */
        fun noData(): ByteArray = ByteArray(0)

        /**
         * Decodes one §3 body (without `len`, `crc32c` and `mseq`).
         *
         * This is the inverse of [encodeBody], the same codec the write path
         * uses, so recovery does not need a second interpretation of the body.
         * The `data_len` is checked against [MAX_DATA_BYTES] **before** the
         * data array is allocated: a record carrying more than one mutation's
         * 15 MiB is refused with a code, never with an `OutOfMemoryError`.
         *
         * @param bytes the buffer holding the body.
         * @param offset the first body byte in [bytes].
         * @param length the body length; `bytes.size - offset` by default.
         * @throws WalException `WAL_TRUNCATED` for a short body,
         *   `BAD_PAYLOAD` for an inconsistent one or data above
         *   [MAX_DATA_BYTES].
         */
        fun decodeBody(
            bytes: ByteArray,
            offset: Int = 0,
            length: Int = bytes.size - offset,
        ): MutationBody {
            if (offset < 0 || length < 0 || offset + length > bytes.size) {
                throw WalException(
                    "WAL_TRUNCATED",
                    "mutation body slice [$offset, ${offset + length}) is outside a " +
                        "${bytes.size}-byte buffer",
                )
            }
            if (length < BODY_HEADER_BYTES) {
                throw WalException("WAL_TRUNCATED", "mutation body is $length bytes")
            }
            val buffer = ByteBuffer.wrap(bytes, offset, length)
            val opCode = buffer.get().toInt() and 0xFF
            val op = VfsOp.fromCode(opCode)
                ?: throw WalException("BAD_PAYLOAD", "unknown VFS op $opCode")
            val mode = buffer.int
            val mflags = buffer.get().toInt() and 0xFF
            val appendFrom = buffer.long
            val pathLength = buffer.short.toInt() and 0xFFFF
            if (buffer.remaining() < pathLength + 4) {
                throw WalException("WAL_TRUNCATED", "mutation body path is short")
            }
            val pathBytes = ByteArray(pathLength)
            buffer.get(pathBytes)
            val dataLength = buffer.int
            if (dataLength < 0 || buffer.remaining() < dataLength) {
                throw WalException("WAL_TRUNCATED", "mutation body data is short")
            }
            if (dataLength > MAX_DATA_BYTES) {
                throw WalException(
                    "WAL_RECORD_TOO_LARGE",
                    "mutation body declares $dataLength data bytes; the host accepts at most " +
                        "$MAX_DATA_BYTES per VFS_MUT (channel.md §3.1/§6). The record is refused " +
                        "before the data array is allocated",
                )
            }
            val data = ByteArray(dataLength)
            buffer.get(data)
            if (buffer.hasRemaining()) {
                throw WalException("BAD_PAYLOAD", "mutation body has trailing bytes")
            }
            val body = MutationBody(
                op = op,
                mode = mode,
                path = String(pathBytes, Charsets.UTF_8),
                data = data,
                appended = mflags and MFLAG_APPENDED != 0,
                appendFrom = appendFrom,
                entryChanged = mflags and MFLAG_ENTRY_CHANGED != 0,
            )
            body.validate()
            return body
        }
    }
}
