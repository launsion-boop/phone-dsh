// The 40-byte segment header of wal.md §2, encoded and verified through the wire CRC.
// SPDX-License-Identifier: MIT

package com.phonedsh.log

import com.phonedsh.wire.NativeWire
import com.phonedsh.wire.WalException
import java.nio.ByteBuffer

/**
 * The 40-byte segment header (`wal.md` §2).
 *
 * | Offset | Size | Field | Encoding |
 * |---|---|---|---|
 * | 0 | 8 | `magic` | `XLWAL1\0\0` |
 * | 8 | 2 | `format` | `u16 = 1` |
 * | 10 | 2 | `reserved` | `u16 = 0` |
 * | 12 | 8 | `first_mseq` | `u64`, `next_mseq` at creation |
 * | 20 | 16 | `boot_id` | raw bytes, no hex form |
 * | 36 | 4 | `header_crc32c` | CRC32C over bytes 0–35 |
 *
 * The CRC is the wire codec's Castagnoli CRC32C, reached through
 * [NativeWire.crc32c]; this package carries no CRC implementation of its own
 * (`wal.md` §2, README "CRC32C is Castagnoli"). A header is written once; only
 * the §10 torn-tail rule truncates, and it never touches the header.
 *
 * `first_mseq` is the mseq the first mutation of the segment will receive. An
 * idle epoch keeps `first_mseq = durable_upto + 1` and writes only the close
 * record, which is why the §2 golden `segment-epoch-only.json` has
 * `first_mseq = 88` for a close record that carries mseq 87.
 *
 * @property firstMseq the `u64` `next_mseq` at creation, at least 1.
 * @property bootId the boot identity, 16 raw bytes on disk.
 * @property format the only proto-1 value, 1.
 * @property reserved the always-zero `u16`.
 */
data class WalSegmentHeader(
    val firstMseq: Long,
    val bootId: BootId,
    val format: Int = FORMAT,
    val reserved: Int = 0,
) {
    init {
        require(firstMseq >= 1) { "a segment header first_mseq is at least 1, was $firstMseq" }
        require(format == FORMAT) { "header format must be $FORMAT, was $format" }
        require(reserved == 0) { "header reserved must be 0, was $reserved" }
    }

    /**
     * The 40 header bytes, including the CRC32C over bytes 0–35.
     *
     * The encoding is big-endian (`wal.md` "Binary integers are big-endian").
     */
    fun encode(): ByteArray {
        val header = ByteBuffer.allocate(BYTES)
        header.put(MAGIC)
        header.putShort(format.toShort())
        header.putShort(reserved.toShort())
        header.putLong(firstMseq)
        header.put(bootId.bytes)
        val crc = NativeWire.crc32c(header.array().copyOf(CRC_OFFSET))
        header.putInt(crc)
        return header.array()
    }

    companion object {
        /** Header size fixed by `wal.md` §2. */
        const val BYTES: Int = 40

        /** The 8 magic bytes, `58 4c 57 41 4c 31 00 00`. */
        val MAGIC: ByteArray = byteArrayOf(0x58, 0x4c, 0x57, 0x41, 0x4c, 0x31, 0x00, 0x00)

        /** The only proto-1 `format`. */
        const val FORMAT: Int = 1

        /** Bytes the header CRC covers. */
        const val CRC_OFFSET: Int = 36

        /**
         * Parses and verifies the first 40 bytes of [bytes].
         *
         * @throws WalException `WAL_TRUNCATED` when [bytes] holds fewer than
         *   [BYTES] bytes, `WAL_HEADER_INVALID` for a wrong magic, format,
         *   reserved value, zero `first_mseq` or header CRC.
         */
        fun decode(bytes: ByteArray): WalSegmentHeader {
            if (bytes.size < BYTES) {
                throw WalException(
                    "WAL_TRUNCATED",
                    "segment header needs $BYTES bytes, have ${bytes.size}",
                )
            }
            val buffer = ByteBuffer.wrap(bytes, 0, BYTES)
            val magic = ByteArray(MAGIC.size)
            buffer.get(magic)
            if (!magic.contentEquals(MAGIC)) {
                throw WalException("WAL_HEADER_INVALID", "segment magic is not XLWAL1")
            }
            val format = buffer.short.toInt() and 0xFFFF
            if (format != FORMAT) {
                throw WalException("WAL_HEADER_INVALID", "segment format $format is not $FORMAT")
            }
            val reserved = buffer.short.toInt() and 0xFFFF
            if (reserved != 0) {
                throw WalException("WAL_HEADER_INVALID", "segment reserved $reserved is not 0")
            }
            val firstMseq = buffer.long
            if (firstMseq < 1) {
                throw WalException(
                    "WAL_HEADER_INVALID",
                    "segment first_mseq $firstMseq is below 1",
                )
            }
            val bootIdBytes = ByteArray(BootId.BYTES)
            buffer.get(bootIdBytes)
            val stored = buffer.int
            val computed = NativeWire.crc32c(bytes.copyOf(CRC_OFFSET))
            if (stored != computed) {
                throw WalException(
                    "WAL_HEADER_INVALID",
                    "segment header CRC32C is ${stored.toUInt().toString(16)} but bytes 0-35 hash to " +
                        computed.toUInt().toString(16),
                )
            }
            return WalSegmentHeader(firstMseq = firstMseq, bootId = BootId.of(bootIdBytes))
        }
    }
}
