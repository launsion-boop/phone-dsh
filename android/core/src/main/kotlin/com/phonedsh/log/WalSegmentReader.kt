// Streaming frame reader for one WAL segment: recovery's bounded-memory path.
// SPDX-License-Identifier: MIT

package com.phonedsh.log

import com.phonedsh.wire.NativeWire
import com.phonedsh.wire.WalException
import java.io.Closeable
import java.io.IOException
import java.nio.ByteBuffer
import java.nio.channels.FileChannel
import java.nio.file.Path
import java.nio.file.StandardOpenOption

/**
 * Reads one `wal/<epoch>.<segment>.xlwal` **one record frame at a time**.
 *
 * Recovery must not hold a whole segment (or worse, the whole WAL) on the Java
 * heap: `budgets.md` §4 allows a 128 MiB single file on the 8 GiB row while the
 * app process budget is 230 MB and the engine heap 448 MB, so loading every
 * record body at once is larger than the whole process is allowed to be. This
 * reader allocates one frame (at most one 15 MiB mutation, `channel.md` §3.1)
 * plus that record's decoded body, hands the [WalRecord] to the caller and
 * drops it before the next frame.
 *
 * The frame is `len u32 | crc32c u32 | mseq u64 | body` (`wal.md` §3). The
 * layout decision is not duplicated here: [MutationBody.decodeBody] is the
 * inverse of the same [MutationBody.encodeBody] the write path uses, and the
 * CRC is [NativeWire.crc32c] — this package never grows a second CRC32C or a
 * second body codec.
 *
 * ### The 15 MiB bound is a refusal, not an OOM
 *
 * `channel.md` §3.1 caps `op = 1` data at 15 MiB and `channel.md` §6 says the
 * host rejects a larger `data_len` with `BAD_PAYLOAD`; `wal.md` §3 applies
 * those invariants to the WAL body unchanged. A frame whose declared length
 * could carry more than [MutationBody.MAX_DATA_BYTES] is therefore not a
 * record this host can have written. It is refused with
 * [WAL_RECORD_TOO_LARGE] **before** the payload is allocated, so a hand-crafted
 * or foreign segment cannot turn recovery into an `OutOfMemoryError`.
 *
 * A torn tail is not handled here: `wal.md` §10 step 2 truncates it before the
 * readers run (`NativeWal.scanSegment`/`classifyTail` decide it), so a short
 * frame at this layer is either a post-truncation corruption or a concurrent
 * writer, and is reported as [WAL_TRUNCATED]/[WAL_CORRUPT].
 */
internal class WalSegmentReader private constructor(
    private val name: WalSegmentName,
    private val channel: FileChannel,
    /** The verified 40-byte header of the open segment. */
    val header: WalSegmentHeader,
) : Closeable {
    private val prefix = ByteArray(WalRecordCodec.PREFIX_BYTES)
    private var offset: Long = WalSegmentHeader.BYTES.toLong()

    /** Hands every complete, CRC-verified record to [action], in file order. */
    fun forEachRecord(action: (WalRecord) -> Unit) {
        while (true) {
            val prefixBytes = readFully(prefix, WalRecordCodec.PREFIX_BYTES)
            if (prefixBytes == 0) return
            if (prefixBytes < WalRecordCodec.PREFIX_BYTES) {
                throw WalException(
                    "WAL_TRUNCATED",
                    "${name.manifestFile}: a record prefix is $prefixBytes of " +
                        "${WalRecordCodec.PREFIX_BYTES} bytes at offset $offset",
                )
            }
            val prefixBuffer = ByteBuffer.wrap(prefix)
            val declared = prefixBuffer.int.toLong() and 0xFFFF_FFFFL
            val storedCrc = prefixBuffer.int
            if (declared < WalRecordCodec.MSEQ_BYTES + 1L) {
                throw WalException(
                    "WAL_CORRUPT",
                    "${name.manifestFile}: record at offset $offset declares $declared payload " +
                        "bytes, fewer than the 9-byte mseq+op prefix",
                )
            }
            if (declared > WalRecordCodec.MAX_RECORD_PAYLOAD_BYTES) {
                throw WalException(
                    "WAL_RECORD_TOO_LARGE",
                    "${name.manifestFile}: record at offset $offset declares $declared payload " +
                        "bytes; the largest mutation a VFS_MUT can carry is " +
                        "${MutationBody.MAX_DATA_BYTES} data bytes (channel.md §3.1), i.e. " +
                        "${WalRecordCodec.MAX_RECORD_PAYLOAD_BYTES} payload bytes. " +
                        "Recovery refuses this record instead of allocating it on the heap",
                )
            }
            val payload = ByteArray(declared.toInt())
            val payloadBytes = readFully(payload, payload.size)
            if (payloadBytes < payload.size) {
                throw WalException(
                    "WAL_TRUNCATED",
                    "${name.manifestFile}: record at offset $offset declares $declared payload " +
                        "bytes but only $payloadBytes are present",
                )
            }
            val computed = NativeWire.crc32c(payload)
            if (computed != storedCrc) {
                throw WalException(
                    "WAL_CORRUPT",
                    "${name.manifestFile}: record at offset $offset CRC32C is " +
                        "${storedCrc.toUInt().toString(16)} but its payload hashes to " +
                        computed.toUInt().toString(16),
                )
            }
            action(decode(payload, offset))
            offset += WalRecordCodec.PREFIX_BYTES + declared
        }
    }

    private fun decode(payload: ByteArray, offset: Long): WalRecord {
        val buffer = ByteBuffer.wrap(payload)
        val mseq = buffer.long
        val op = buffer.get().toInt() and 0xFF
        if (op == WalRecordCodec.OP_EPOCH_CLOSE) {
            if (payload.size != WalRecordCodec.MSEQ_BYTES + WalRecordCodec.EPOCH_CLOSE_BODY_BYTES) {
                throw WalException(
                    "WAL_CORRUPT",
                    "${name.manifestFile}: epoch-close record at offset $offset is " +
                        "${payload.size} payload bytes, expected " +
                        "${WalRecordCodec.MSEQ_BYTES + WalRecordCodec.EPOCH_CLOSE_BODY_BYTES}",
                )
            }
            val wallMs = buffer.long
            val durableUpto = buffer.long
            if (mseq != durableUpto) {
                throw WalException(
                    "WAL_CORRUPT",
                    "${name.manifestFile}: epoch-close record at offset $offset carries mseq " +
                        "$mseq but durable_upto $durableUpto (wal.md §4: the mseq field IS " +
                        "durable_upto)",
                )
            }
            return WalRecord.EpochClose(wallMs = wallMs, durableUpto = durableUpto)
        }
        if (mseq < 1L) {
            throw WalException(
                "WAL_CORRUPT",
                "${name.manifestFile}: mutation record at offset $offset has mseq $mseq (wal.md §3: " +
                    "mutation mseq is at least 1)",
            )
        }
        val body = MutationBody.decodeBody(
            payload,
            offset = WalRecordCodec.MSEQ_BYTES,
            length = payload.size - WalRecordCodec.MSEQ_BYTES,
        )
        return WalRecord.Mutation(mseq, body)
    }

    /** Reads up to `length` bytes into [into]; returns how many were read. */
    private fun readFully(into: ByteArray, length: Int): Int {
        val buffer = ByteBuffer.wrap(into, 0, length)
        while (buffer.hasRemaining()) {
            val read = try {
                channel.read(buffer)
            } catch (error: IOException) {
                throw LogException(
                    LogFailure.WAL_DIRECTORY_IO,
                    "cannot read ${name.manifestFile}: ${error.message}",
                    error,
                )
            }
            if (read < 0) break
        }
        return buffer.position()
    }

    override fun close() {
        try {
            channel.close()
        } catch (_: IOException) {
            // Closing the reader is not a durability operation; a failed close
            // cannot lose a record that was already read.
        }
    }

    companion object {
        /**
         * The largest conforming segment file: 40-byte header, one maximum
         * mutation record and one epoch-close record.
         *
         * `wal.md` §1 rolls before a record that would exceed 8 MiB and states
         * that "a record larger than 8 MiB occupies a segment alone", and the
         * epoch-close record is appended without a roll to the current segment.
         * A segment can therefore not legally hold a second record next to a
         * maximum one, so a file above this size cannot be a conforming
         * segment. Recovery refuses it before reading, which is what keeps a
         * hand-crafted 128 MiB record from becoming a 128 MiB allocation.
         */
        val MAX_SEGMENT_BYTES: Long =
            (WalSegmentHeader.BYTES +
                WalRecordCodec.MAX_RECORD_FRAME_BYTES +
                WalRecordCodec.PREFIX_BYTES +
                WalRecordCodec.MSEQ_BYTES +
                WalRecordCodec.EPOCH_CLOSE_BODY_BYTES).toLong()

        /**
         * Opens [name] from [paths] and verifies its header.
         *
         * @throws WalException `WAL_TRUNCATED` for a short header,
         *   `WAL_HEADER_INVALID` for a bad one and `WAL_RECORD_TOO_LARGE` when
         *   the file is above [MAX_SEGMENT_BYTES].
         */
        fun open(paths: WalPaths, name: WalSegmentName): WalSegmentReader {
            val path: Path = paths.segment(name)
            val size = try {
                java.nio.file.Files.size(path)
            } catch (error: IOException) {
                throw LogException(
                    LogFailure.WAL_DIRECTORY_IO,
                    "cannot size ${paths.label(path)}: ${error.message}",
                    error,
                )
            }
            if (size > MAX_SEGMENT_BYTES) {
                throw WalException(
                    "WAL_RECORD_TOO_LARGE",
                    "${name.manifestFile} is $size bytes; a conforming segment holds at most " +
                        "one record of ${MutationBody.MAX_DATA_BYTES} data bytes " +
                        "(channel.md §3.1) and is at most $MAX_SEGMENT_BYTES bytes. " +
                        "Recovery refuses the file instead of loading it on the heap",
                )
            }
            val channel = try {
                FileChannel.open(path, StandardOpenOption.READ)
            } catch (error: IOException) {
                throw LogException(
                    LogFailure.WAL_DIRECTORY_IO,
                    "cannot read ${paths.label(path)}: ${error.message}",
                    error,
                )
            }
            var open = true
            try {
                val headerBytes = ByteArray(WalSegmentHeader.BYTES)
                var read = 0
                while (read < headerBytes.size) {
                    val count = channel.read(ByteBuffer.wrap(headerBytes, read, headerBytes.size - read))
                    if (count < 0) break
                    read += count
                }
                if (read < headerBytes.size) {
                    throw WalException(
                        "WAL_TRUNCATED",
                        "${name.manifestFile}: header needs ${WalSegmentHeader.BYTES} bytes, " +
                            "have $read",
                    )
                }
                val header = WalSegmentHeader.decode(headerBytes)
                open = false
                return WalSegmentReader(name, channel, header)
            } finally {
                if (open) {
                    try {
                        channel.close()
                    } catch (_: IOException) {
                        // Best effort on the failure path.
                    }
                }
            }
        }
    }
}
