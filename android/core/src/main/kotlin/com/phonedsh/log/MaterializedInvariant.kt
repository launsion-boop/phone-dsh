// The materialized-copy invariant of wal.md §7.2, scoped to provable paths.
// SPDX-License-Identifier: MIT

package com.phonedsh.log

import java.io.IOException
import java.nio.ByteBuffer
import java.nio.channels.FileChannel
import java.nio.file.Files
import java.nio.file.LinkOption
import java.nio.file.Path
import java.nio.file.StandardOpenOption

/**
 * Checks the retained WAL against the materialized copy (`wal.md` §7.2)
 * **one record at a time**.
 *
 * Before the P19 fix this class took every retained mutation body and rebuilt
 * each touched file with `bytes = bytes + body.data`: a 128 MiB file in a stale
 * segment meant a 128 MiB array plus every intermediate append array on a
 * device whose whole app heap is 192 MiB. The comparison is now incremental:
 * [observe] is fed the record stream in mseq order and compares each record's
 * bytes with the file at the offset the record names, using one 64 KiB buffer;
 * no part of the file lands on the Java heap.
 *
 * The semantics of the revised §7.2 rule are unchanged:
 *
 * - a path is provable only when its last retained complete write and every
 *   global mutation mseq from that base through the retained tail are present
 *   with no hole; otherwise it is reported as **unprovable**, never as verified
 *   and never as a divergence;
 * - only bytes and POSIX mode are compared; a mode no retained record proves is
 *   not a divergence;
 * - a later complete write supersedes every earlier comparison for that path
 *   (the divergence candidate is cleared), so a record that a newer base
 *   replaces can never fail the verification.
 */
internal class MaterializedInvariant(
    private val paths: WalPaths,
    /** The retained mutation ranges, sorted; used for the no-hole proof. */
    private val ranges: List<LongRange>,
    /** The highest mutation mseq the retained WAL holds, 0 when none. */
    private val tailMseq: Long,
) {
    /**
     * The per-path result of one verification pass.
     *
     * @property verified paths whose materialized bytes and mode matched.
     * @property unprovable paths whose base or intermediate mseq is not
     *   retained, so no comparison is claimed.
     * @property divergences one human-readable entry per mismatch, always
     *   naming the VFS path (never an absolute local path).
     */
    data class Report(
        val verified: Set<String>,
        val unprovable: Set<String>,
        val divergences: List<String>,
    )

    private class PathState {
        var exists: Boolean = true
        var directory: Boolean = false
        var mode: Int = 0
        var modeProvable: Boolean = false
        var baseMseq: Long? = null
        var expectedSize: Long = 0L

        /** The first divergence candidate; a later complete write clears it. */
        var divergence: String? = null

        /** Why this path cannot be compared; a later complete write clears it. */
        var unprovable: String? = null
    }

    private val states = HashMap<String, PathState>()

    /** Feeds one retained mutation, in mseq order. */
    fun observe(record: WalRecord.Mutation) {
        val body = record.body
        val state = states.getOrPut(body.path) { PathState() }
        val disk = VfsPath.resolve(paths.materializedDirectory, body.path)
        when (body.op) {
            VfsOp.WRITE -> {
                state.exists = true
                state.directory = false
                state.mode = body.mode and MutationBody.MAX_MODE
                state.modeProvable = true
                if (body.appended) {
                    val base = state.baseMseq
                    if (base == null) {
                        state.unprovable = "no retained complete write"
                        return
                    }
                    if (body.appendFrom != state.expectedSize) {
                        state.unprovable =
                            "appended mseq ${record.mseq} does not follow the retained base"
                        return
                    }
                    state.expectedSize = body.appendFrom + body.data.size
                    compare(state, disk, body.appendFrom, body.data)
                } else {
                    state.baseMseq = record.mseq
                    state.unprovable = null
                    state.divergence = null
                    state.expectedSize = body.data.size.toLong()
                    compare(state, disk, 0L, body.data)
                }
            }

            VfsOp.MKDIR -> {
                state.exists = true
                state.directory = true
                state.expectedSize = 0L
                state.mode = body.mode and MutationBody.MAX_MODE
                // An existing directory is not re-chmodded by §6.1, so a mkdir
                // record does not prove the mode it names.
                state.modeProvable = false
                state.divergence = null
                state.unprovable = null
            }

            VfsOp.REMOVE -> {
                // The path is absent in the final state: earlier byte and mode
                // comparisons no longer describe anything.
                state.exists = false
                state.directory = false
                state.expectedSize = 0L
                state.modeProvable = false
                state.divergence = null
                state.unprovable = null
            }

            VfsOp.CHMOD -> {
                state.mode = body.mode and MutationBody.MAX_MODE
                state.modeProvable = true
            }
        }
    }

    /** Verifies [vfsPaths] against the materialized copy. */
    fun report(vfsPaths: Collection<String>): Report {
        val verified = LinkedHashSet<String>()
        val unprovable = LinkedHashSet<String>()
        val divergences = ArrayList<String>()
        for (vfsPath in vfsPaths.sorted()) {
            val state = states[vfsPath]
            if (state == null) {
                unprovable.add(vfsPath)
                continue
            }
            val base = state.baseMseq
            if (base == null) {
                unprovable.add(vfsPath)
                state.unprovable?.let { divergences += "$vfsPath: $it" }
                continue
            }
            if (!covers(ranges, base, tailMseq)) {
                unprovable.add(vfsPath)
                continue
            }
            val unprovableReason = state.unprovable
            if (unprovableReason != null) {
                unprovable.add(vfsPath)
                divergences += "$vfsPath: $unprovableReason"
                continue
            }
            val disk = VfsPath.resolve(paths.materializedDirectory, vfsPath)
            val present = Files.exists(disk, LinkOption.NOFOLLOW_LINKS)
            if (!state.exists) {
                if (present) {
                    divergences += "$vfsPath should be absent but exists in the materialized copy"
                } else {
                    verified.add(vfsPath)
                }
                continue
            }
            if (!present) {
                divergences += "$vfsPath is missing from the materialized copy"
                continue
            }
            if (state.directory) {
                if (!Files.isDirectory(disk, LinkOption.NOFOLLOW_LINKS)) {
                    divergences += "$vfsPath should be a directory"
                    continue
                }
                if (state.modeProvable && PosixModes.read(disk) != state.mode) {
                    divergences +=
                        "$vfsPath mode is 0${PosixModes.read(disk).toString(8)}, " +
                            "expected 0${state.mode.toString(8)}"
                    continue
                }
                verified.add(vfsPath)
                continue
            }
            if (!Files.isRegularFile(disk, LinkOption.NOFOLLOW_LINKS)) {
                divergences += "$vfsPath should be a regular file"
                continue
            }
            val size = try {
                Files.size(disk)
            } catch (error: IOException) {
                divergences += "$vfsPath is unreadable: ${error.message}"
                continue
            }
            if (size != state.expectedSize) {
                divergences += "$vfsPath holds $size bytes, the WAL derives ${state.expectedSize}"
                continue
            }
            val divergence = state.divergence
            if (divergence != null) {
                divergences += "$vfsPath: $divergence"
                continue
            }
            if (state.modeProvable && PosixModes.read(disk) != state.mode) {
                divergences +=
                    "$vfsPath mode is 0${PosixModes.read(disk).toString(8)}, " +
                        "expected 0${state.mode.toString(8)}"
                continue
            }
            verified.add(vfsPath)
        }
        return Report(verified, unprovable, divergences)
    }

    /** Compares [data] with the copy at [offset]; records the first mismatch. */
    private fun compare(state: PathState, disk: Path, offset: Long, data: ByteArray) {
        if (state.divergence != null) return
        if (!Files.isRegularFile(disk, LinkOption.NOFOLLOW_LINKS)) {
            // A missing file or a directory is reported by report(); the byte
            // comparison only reports a content mismatch.
            return
        }
        val buffer = ByteBuffer.allocate(COMPARE_CHUNK_BYTES)
        try {
            FileChannel.open(disk, StandardOpenOption.READ).use { channel ->
                var compared = 0
                while (compared < data.size) {
                    val take = minOf(COMPARE_CHUNK_BYTES, data.size - compared)
                    buffer.clear()
                    buffer.limit(take)
                    var read = 0
                    while (buffer.hasRemaining()) {
                        val count = channel.read(buffer, offset + compared + read)
                        if (count < 0) break
                        read += count
                    }
                    if (read < take) {
                        state.divergence = "holds fewer bytes than the WAL derives at offset $offset"
                        return
                    }
                    for (index in 0 until take) {
                        if (buffer.get(index) != data[compared + index]) {
                            state.divergence =
                                "differs from the WAL at byte ${offset + compared + index}"
                            return
                        }
                    }
                    compared += take
                }
            }
        } catch (error: IOException) {
            state.divergence = "is unreadable: ${error.message}"
        }
    }

    /** Whether every mseq in `[from, to]` is covered by the retained ranges. */
    private fun covers(ranges: List<LongRange>, from: Long, to: Long): Boolean {
        if (to < from) return false
        var cursor = from
        for (range in ranges) {
            if (range.last < cursor) continue
            if (range.first > cursor) return false
            if (range.last >= to) return true
            cursor = range.last + 1
        }
        return false
    }

    private companion object {
        /** The largest bytes compared in one read; the WAL file never lands on the heap. */
        const val COMPARE_CHUNK_BYTES: Int = 64 * 1024
    }
}
