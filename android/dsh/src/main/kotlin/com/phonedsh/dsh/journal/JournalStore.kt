// phone-dsh — :dsh / com.phonedsh.dsh.journal: the durable journal store.
// SPDX-License-Identifier: MIT
//
// ---- what this file is -----------------------------------------------------
// The host's half of the tool journal. The worker sends `JOURNAL` (`0x30`) with
// an opaque NDJSON-style record; this store appends that record to a per-session
// file, **fsyncs it**, and only then may the sink answer `JOURNAL_ACK` (`0x31`).
// That ordering is the whole point of the lane: the N1 device evidence showed a
// worker waiting 30 s on a durability acknowledgement and then reconnecting into
// a 409, because the host had no journal at all and the test seam answered ACK
// without persisting anything.
//
// ---- the file format (independent of the WAL) -----------------------------
// One file per session, named by the hex of the session id (JournalPaths). No
// WAL layout is reused: the WAL's `len | crc32c | mseq | body` records carry
// `MutationBody` bytes and are parsed by `pdsh_wal`, while these records are
// opaque. The format here is:
//
//   header: magic `u32` ("PJNL") | version `u8` | flags `u8` | sid_len `u16`
//           | session_id bytes | pruned_upto `u64`
//   record: len `u32` (> 0) | crc32c `u32` (over jseq ‖ record) | jseq `u64`
//           | record bytes
//
// `pruned_upto` is the highest jseq this host ever removed by pruning. It is
// what keeps a **forward gap** from being invented after a prune: the store can
// answer a re-sent `(session, jseq)` as a duplicate even when no record for it
// survives, and a worker restart cannot reuse a number the old worker used.
//
// ---- fsync before ACK ------------------------------------------------------
// [append] writes the record, calls [Durability.fsyncPath] on the file and (for
// a new file) on `journal/`, and returns only after both returned. The sink
// emits the acknowledgement after that return, so no ACK can name a byte that
// was not synced. The CRC and the monotonic `jseq` make the other half of the
// proof: recovery can tell a torn tail (never acknowledged) from a corrupt
// middle (a real defect) and truncates only the former.
//
// ---- the quota (budgets.md §5) --------------------------------------------
// 64 MiB `DEFAULT_LIMIT_BYTES`, measured over the session files. Before a write
// that would cross it, [pruneLocked] drops journaled-and-durable step groups,
// oldest first (JournalPruneRule), and if the write still does not fit the
// append is refused with `JOURNAL_QUOTA_EXCEEDED` and nothing is written. The
// `Failed` state itself is the controller's call: this store reports, it does
// not drive the host state machine.
//
// ---- single writer ---------------------------------------------------------
// One [Mutex] serialises recovery, append, prune and the diagnostic read; the
// host is single-writer, but a coroutine cannot be assumed to be.

package com.phonedsh.dsh.journal

import com.phonedsh.dsh.host.HostLog
import com.phonedsh.platform.Durability
import com.phonedsh.wire.WireCodec
import java.io.IOException
import java.nio.ByteBuffer
import java.nio.channels.FileChannel
import java.nio.file.Files
import java.nio.file.LinkOption
import java.nio.file.Path
import java.nio.file.StandardOpenOption
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

/**
 * One torn tail recovery removed before the journal was opened.
 *
 * @property file the workspace-relative label of the session file.
 * @property droppedBytes the unacknowledged bytes after the last complete record.
 */
data class JournalTailTruncation(val file: String, val droppedBytes: Long)

/**
 * What cold recovery found in `journal/`.
 *
 * @property highestJseq the highest appended jseq per session, including the
 *   `pruned_upto` of a fully pruned file, so a reconnect can deduplicate a
 *   record whose bytes were pruned.
 * @property usedBytes the quota measurement after recovery, in bytes.
 * @property truncatedTails the torn tails that were removed; a torn tail was
 *   never acknowledged, so dropping it loses no acknowledged record.
 */
data class JournalRecovery(
    val highestJseq: Map<String, Long>,
    val usedBytes: Long,
    val truncatedTails: List<JournalTailTruncation> = emptyList(),
) {
    init {
        require(usedBytes >= 0L) { "usedBytes must be non-negative, was $usedBytes" }
        for ((sessionId, jseq) in highestJseq) {
            require(jseq >= 0L) { "highest jseq of \"$sessionId\" must be non-negative, was $jseq" }
        }
    }
}

/**
 * The result of one accepted [JournalStore.append].
 *
 * @property jseq the jseq that is now durable.
 * @property bytes the session file's size after the append.
 */
data class JournalAppend(val jseq: Long, val bytes: Long) {
    init {
        require(jseq >= 1L) { "an appended jseq starts at 1, was $jseq" }
        require(bytes >= 0L) { "the file size must be non-negative, was $bytes" }
    }
}

/**
 * What one quota prune removed.
 *
 * @property entries the records dropped (whole journaled step groups).
 * @property bytes the bytes those records occupied.
 * @property sessions the session files rewritten.
 */
data class JournalPrune(val entries: Int, val bytes: Long, val sessions: Int) {
    init {
        require(entries >= 0) { "entries must be non-negative, was $entries" }
        require(bytes >= 0L) { "bytes must be non-negative, was $bytes" }
        require(sessions >= 0) { "sessions must be non-negative, was $sessions" }
    }
}

/** One record read back from a session file, for tests and diagnostics. */
internal class JournalStoredRecord(val jseq: Long, val record: ByteArray)

/**
 * The durable journal of one workspace.
 *
 * Construct one per boot, call [recover] once (idempotent) and then [append] for
 * every accepted `JOURNAL`. [JournalSink] owns the protocol state on top; this
 * class owns the bytes.
 *
 * @param paths the `journal/` layout of the workspace.
 * @param durability the platform fsync/atomic-replace SPI. Every append fsyncs
 *   through it before returning, and every compaction replaces its file
 *   atomically through it.
 * @param logger the token-free log seam.
 * @param limitBytes budgets.md §5's 64 MiB. A test may lower it to reach
 *   pruning without writing 64 MiB, exactly as `WalQuota` allows for its 512 MiB.
 */
class JournalStore(
    val paths: JournalPaths,
    private val durability: Durability,
    private val logger: HostLog = HostLog.None,
    val limitBytes: Long = DEFAULT_LIMIT_BYTES,
) {
    init {
        require(limitBytes > 0L) { "the journal quota must be positive, was $limitBytes" }
    }

    private val mutex = Mutex()
    private var ready: Boolean = false
    private var fatal: JournalException? = null

    /**
     * Runs cold recovery: creates `journal/`, validates every session file,
     * truncates a torn tail and returns the watermarks the sink seeds from.
     *
     * Idempotent. A second call rescans and reports the same facts, which is
     * what a `start()` after `stop()` needs.
     *
     * @throws JournalException `JOURNAL_CORRUPT` when a retained file is not a
     *   journal this host wrote, `JOURNAL_IO` when the directory or a file
     *   cannot be read, written or truncated. Either way the journal stays
     *   closed for the boot and the facade keeps `journal/1` dispatch off.
     */
    suspend fun recover(): JournalRecovery = mutex.withLock { recoverLocked() }

    /**
     * Appends one record and fsyncs it.
     *
     * The contract with [JournalSink]: **the returned [JournalAppend] is the
     * only proof that an acknowledgement may be sent.** No caller may ack a
     * `(session_id, jseq)` this method did not return for.
     *
     * @param sessionId a D6 session id already validated by [JournalFrame].
     * @param jseq the next consecutive jseq of that session.
     * @param record the opaque record bytes, at least one byte.
     * @return the durable append.
     * @throws JournalException `JOURNAL_NOT_READY` before [recover],
     *   `JOURNAL_QUOTA_EXCEEDED` when the write would cross [limitBytes] and
     *   nothing journaled-and-durable can be pruned, `JOURNAL_IO` when the
     *   write or fsync fails (the partial write is rolled back and the store
     *   closes), `JOURNAL_CORRUPT` when the session file is not this host's.
     */
    suspend fun append(sessionId: String, jseq: Long, record: ByteArray): JournalAppend =
        mutex.withLock { appendLocked(sessionId, jseq, record) }

    /** The store's current size: every session file, headers included. */
    fun usedBytes(): Long = measure()

    /**
     * Reads one session's retained records, oldest first.
     *
     * For tests and diagnostics; the host itself never reads the journal back.
     * A torn tail is a `JOURNAL_CORRUPT` here because recovery already removed
     * the one torn tail a boot can have.
     */
    internal suspend fun records(sessionId: String): List<JournalStoredRecord> = mutex.withLock {
        ensureReady()
        val path = paths.sessionFile(sessionId)
        if (!Files.exists(path, LinkOption.NOFOLLOW_LINKS)) return@withLock emptyList()
        walk(path, truncate = false, withFacts = false, collectRecords = true).records
    }

    // -----------------------------------------------------------------------
    // Recovery
    // -----------------------------------------------------------------------

    private suspend fun recoverLocked(): JournalRecovery {
        fatal?.let { throw it }
        try {
            paths.createDirectories()
            val files = sessionFiles()
            val highest = LinkedHashMap<String, Long>()
            val truncations = ArrayList<JournalTailTruncation>()
            for (file in files) {
                val walk = walk(file, truncate = true, withFacts = false, collectRecords = false)
                highest[walk.sessionId] = walk.highestJseq
                if (walk.truncatedBytes > 0L) {
                    truncations += JournalTailTruncation(paths.label(file), walk.truncatedBytes)
                    logger.warn(
                        "journal: dropped ${walk.truncatedBytes} torn bytes from ${paths.label(file)}",
                    )
                }
            }
            ready = true
            val used = measure(files)
            logger.info("journal: recovered ${highest.size} session(s), $used bytes")
            return JournalRecovery(highest, used, truncations)
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (error: JournalException) {
            fatal = error
            ready = false
            throw error
        } catch (error: RuntimeException) {
            val wrapped = JournalException(
                JournalFailure.IO,
                "journal recovery failed (${error.javaClass.simpleName})",
                cause = error,
            )
            fatal = wrapped
            ready = false
            throw wrapped
        }
    }

    private fun ensureReady() {
        fatal?.let { throw it }
        if (!ready) {
            throw JournalException(JournalFailure.NOT_READY, "the journal store has not recovered")
        }
    }

    // -----------------------------------------------------------------------
    // Write path
    // -----------------------------------------------------------------------

    private suspend fun appendLocked(sessionId: String, jseq: Long, record: ByteArray): JournalAppend {
        ensureReady()
        require(jseq >= 1L) { "a journal jseq starts at 1, was $jseq" }
        require(record.isNotEmpty()) { "a journal record carries at least one byte" }
        val path = paths.sessionFile(sessionId)
        try {
            val header = readHeaderOrNull(path)
            if (header != null && header.sessionId != sessionId) {
                throw corrupt("${paths.label(path)} belongs to another session")
            }
            val headerBytes = if (header == null) encodeHeader(sessionId, prunedUpto = 0L) else EMPTY_BYTES
            val frame = encodeRecord(jseq, record)
            ensureQuota(headerBytes.size.toLong() + frame.size.toLong())

            var created = false
            if (header == null) {
                FileChannel.open(path, StandardOpenOption.CREATE_NEW, StandardOpenOption.WRITE).use { channel ->
                    writeFully(channel, headerBytes)
                }
                created = true
            }
            val before = sizeOf(path)
            try {
                FileChannel.open(path, StandardOpenOption.WRITE).use { channel ->
                    channel.position(before)
                    writeFully(channel, frame)
                }
                // The fsync the acknowledgement is allowed to name. For a new
                // file the directory entry must be durable too, or a reboot can
                // lose the whole session file whose record was "acked".
                durability.fsyncPath(path)
                if (created) durability.fsyncPath(paths.journalDirectory)
            } catch (cancelled: CancellationException) {
                rollbackQuietly(path, before, created)
                throw cancelled
            } catch (failure: Exception) {
                rollbackQuietly(path, before, created)
                throw failure
            }
            val bytes = sizeOf(path)
            logger.debug("journal: appended jseq $jseq for $sessionId ($bytes bytes)")
            return JournalAppend(jseq = jseq, bytes = bytes)
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (error: JournalException) {
            if (error.failure != JournalFailure.QUOTA_EXCEEDED) fatal = error
            throw error
        } catch (error: IOException) {
            val wrapped = JournalException(
                JournalFailure.IO,
                "cannot append to ${paths.label(path)}: ${error.message}",
                cause = error,
            )
            fatal = wrapped
            throw wrapped
        }
    }

    /**
     * Undoes the bytes of a failed append, best effort.
     *
     * The record was never acknowledged, so truncating it is always legal; the
     * fsync publishes the shorter file. A rollback that itself fails leaves the
     * store [fatal], and the next boot's recovery sees either the complete
     * record (the data coalesced) or a torn tail (it did not) and decides with
     * the CRC.
     */
    private suspend fun rollbackQuietly(path: Path, before: Long, created: Boolean) {
        try {
            if (created) {
                Files.deleteIfExists(path)
                durability.fsyncPath(paths.journalDirectory)
            } else {
                FileChannel.open(path, StandardOpenOption.WRITE).use { channel -> channel.truncate(before) }
                durability.fsyncPath(path)
            }
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (error: Exception) {
            logger.error(
                "journal: could not roll back ${paths.label(path)} after a failed append " +
                    "(${error.javaClass.simpleName})",
            )
        }
    }

    // -----------------------------------------------------------------------
    // The quota (budgets.md §5)
    // -----------------------------------------------------------------------

    /**
     * Makes room for [reserveBytes] under [limitBytes], or refuses the write.
     *
     * Pruning runs only when the append would cross the quota, and it drops
     * only complete journaled-and-durable step groups (JournalPruneRule). A
     * refusal writes nothing: no record, no header and no `pruned_upto` change.
     */
    private suspend fun ensureQuota(reserveBytes: Long) {
        val used = measure()
        if (used + reserveBytes <= limitBytes) return
        logger.info(
            "journal: $used bytes with a $limitBytes byte quota; pruning journaled entries for " +
                "$reserveBytes bytes",
        )
        val pruned = pruneLocked(limitBytes - reserveBytes)
        val after = measure()
        if (after + reserveBytes > limitBytes) {
            throw JournalException(
                JournalFailure.QUOTA_EXCEEDED,
                "journal uses $after bytes of its $limitBytes byte quota after pruning " +
                    "${pruned.entries} journaled entries; the record is not written",
            )
        }
        logger.info(
            "journal: pruned ${pruned.entries} journaled entries in ${pruned.sessions} session(s), " +
                "${pruned.bytes} bytes",
        )
    }

    /**
     * Drops journaled-and-durable groups until the store fits [targetBytes].
     *
     * Groups are visited file by file and oldest first, and each chosen group is
     * dropped whole: a step's records are evidence as a set, so keeping half of
     * one would be worse than keeping all of it.
     */
    private suspend fun pruneLocked(targetBytes: Long): JournalPrune {
        val files = sessionFiles()
        val total = measure(files)
        if (total <= targetBytes) return JournalPrune(0, 0L, 0)

        val plans = ArrayList<RewritePlan>()
        var droppedEntries = 0
        var droppedBytes = 0L
        var enough = false
        for (file in files) {
            if (enough) break
            val walk = walk(file, truncate = false, withFacts = true, collectRecords = false)
            if (walk.entries.isEmpty()) continue
            val facts = walk.entries.map { it.facts ?: JournalPruneRule.UNPRUNABLE }
            val groups = JournalPruneRule.droppableGroups(facts)
            if (groups.isEmpty()) continue
            val dropped = HashSet<Int>()
            for (group in groups) {
                var groupBytes = 0L
                for (index in group) {
                    dropped += index
                    groupBytes += walk.entries[index].frameBytes.toLong()
                }
                droppedEntries += group.size
                droppedBytes += groupBytes
                if (total - droppedBytes <= targetBytes) {
                    enough = true
                    break
                }
            }
            if (dropped.isNotEmpty()) plans += RewritePlan(file, walk, dropped)
        }
        if (plans.isEmpty()) return JournalPrune(0, 0L, 0)

        for (plan in plans) rewrite(plan)
        return JournalPrune(droppedEntries, droppedBytes, plans.size)
    }

    private class RewritePlan(
        val path: Path,
        val walk: Walk,
        val dropped: Set<Int>,
    )

    /**
     * Rewrites one session file without [RewritePlan.dropped], atomically.
     *
     * `Durability.atomicReplace` fsyncs the temporary file, renames it over the
     * session file and fsyncs `journal/`; a crash therefore leaves either the
     * old or the new file, never a half-pruned one. The header's `pruned_upto`
     * is raised to the highest dropped jseq so the pruned sequence numbers stay
     * acknowledged forever.
     */
    private suspend fun rewrite(plan: RewritePlan) {
        var prunedUpto = plan.walk.prunedUpto
        for (index in plan.dropped) {
            prunedUpto = maxOf(prunedUpto, plan.walk.entries[index].jseq)
        }
        val header = encodeHeader(plan.walk.sessionId, prunedUpto)
        try {
            durability.atomicReplace(plan.path) { temporary ->
                FileChannel.open(
                    temporary,
                    StandardOpenOption.WRITE,
                    StandardOpenOption.TRUNCATE_EXISTING,
                ).use { destination ->
                    writeFully(destination, header)
                    FileChannel.open(plan.path, StandardOpenOption.READ).use { source ->
                        for (index in plan.walk.entries.indices) {
                            if (index in plan.dropped) continue
                            val entry = plan.walk.entries[index]
                            copyRange(source, destination, entry.offset, entry.frameBytes.toLong())
                        }
                    }
                }
            }
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (error: IOException) {
            throw JournalException(
                JournalFailure.IO,
                "cannot compact ${paths.label(plan.path)}: ${error.message}",
                cause = error,
            )
        }
    }

    // -----------------------------------------------------------------------
    // File format
    // -----------------------------------------------------------------------

    private class Header(val sessionId: String, val prunedUpto: Long, val headerBytes: Int)

    private class Entry(
        val offset: Long,
        val frameBytes: Int,
        val jseq: Long,
        val facts: JournalPruneRule.Facts?,
    )

    private class Walk(
        val sessionId: String,
        val prunedUpto: Long,
        val highestJseq: Long,
        val truncatedBytes: Long,
        val entries: List<Entry>,
        val records: List<JournalStoredRecord>,
    )

    /**
     * Scans [path] record by record.
     *
     * A **torn tail** — an incomplete final record, a bad final CRC, or a final
     * repeated jseq left by a retried append — is unacknowledged by
     * construction and is truncated when [truncate] is `true`. A bad record
     * followed by more bytes, a non-monotonic jseq, or a file name/session
     * mismatch is corruption and fails loud, because those bytes could be
     * acknowledged evidence.
     */
    private suspend fun walk(
        path: Path,
        truncate: Boolean,
        withFacts: Boolean,
        collectRecords: Boolean,
    ): Walk {
        val header = readHeaderOrNull(path) ?: throw corrupt("${paths.label(path)} has no header")
        if (path.fileName.toString() != JournalPaths.fileName(header.sessionId)) {
            throw corrupt("${paths.label(path)} does not match its session header")
        }
        val size = sizeOf(path)
        var offset = header.headerBytes.toLong()
        var previous = 0L
        var last = 0L
        var count = 0
        var tornAt = -1L
        val entries = ArrayList<Entry>()
        val records = if (collectRecords) ArrayList<JournalStoredRecord>() else null
        try {
            FileChannel.open(path, StandardOpenOption.READ).use { channel ->
                while (offset < size) {
                    val remaining = size - offset
                    if (remaining < RECORD_PREFIX_BYTES) {
                        tornAt = offset
                        break
                    }
                    val prefix = ByteBuffer.allocate(RECORD_PREFIX_BYTES)
                    readFully(channel, prefix, offset)
                    prefix.flip()
                    val length = prefix.int
                    val crc = prefix.int
                    val jseq = prefix.long
                    if (length <= 0 || length > MAX_RECORD_BYTES ||
                        remaining - RECORD_PREFIX_BYTES < length
                    ) {
                        tornAt = offset
                        break
                    }
                    val record = ByteArray(length)
                    readFully(channel, ByteBuffer.wrap(record), offset + RECORD_PREFIX_BYTES)
                    val end = offset + RECORD_PREFIX_BYTES + length
                    if (crc != journalCrc(jseq, record)) {
                        if (end == size) {
                            tornAt = offset
                            break
                        }
                        throw corrupt("${paths.label(path)} has a bad record CRC at byte $offset")
                    }
                    if (jseq < 1L) throw corrupt("${paths.label(path)} has jseq $jseq at byte $offset")
                    if (count > 0 && jseq <= previous) {
                        if (jseq == previous && end == size) {
                            tornAt = offset
                            break
                        }
                        throw corrupt(
                            "${paths.label(path)} has a non-increasing jseq at byte $offset",
                        )
                    }
                    previous = jseq
                    last = jseq
                    count += 1
                    entries += Entry(
                        offset = offset,
                        frameBytes = RECORD_PREFIX_BYTES + length,
                        jseq = jseq,
                        facts = if (withFacts) JournalPruneRule.facts(record) else null,
                    )
                    records?.add(JournalStoredRecord(jseq, record))
                    offset = end
                }
            }
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (error: IOException) {
            throw JournalException(
                JournalFailure.IO,
                "cannot read ${paths.label(path)}: ${error.message}",
                cause = error,
            )
        }
        val truncatedBytes = if (tornAt >= 0L) size - tornAt else 0L
        if (tornAt >= 0L) {
            if (!truncate) throw corrupt("${paths.label(path)} has a torn tail at byte $tornAt")
            truncateTail(path, tornAt)
        }
        return Walk(
            sessionId = header.sessionId,
            prunedUpto = header.prunedUpto,
            highestJseq = maxOf(header.prunedUpto, last),
            truncatedBytes = truncatedBytes,
            entries = entries,
            records = records ?: emptyList(),
        )
    }

    private suspend fun truncateTail(path: Path, keepBytes: Long) {
        try {
            FileChannel.open(path, StandardOpenOption.WRITE).use { channel -> channel.truncate(keepBytes) }
            durability.fsyncPath(path)
            durability.fsyncPath(paths.journalDirectory)
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (error: IOException) {
            throw JournalException(
                JournalFailure.IO,
                "cannot truncate ${paths.label(path)}: ${error.message}",
                cause = error,
            )
        }
    }

    private fun encodeHeader(sessionId: String, prunedUpto: Long): ByteArray {
        val sessionBytes = sessionId.toByteArray(Charsets.UTF_8)
        require(sessionBytes.size <= 0xFFFF) { "a session id does not fit a u16 length" }
        require(prunedUpto >= 0L) { "pruned_upto must be non-negative, was $prunedUpto" }
        val buffer = ByteBuffer.allocate(
            JournalPaths.HEADER_PREFIX_BYTES + sessionBytes.size + JournalPaths.HEADER_TRAILER_BYTES,
        )
        buffer.putInt(JournalPaths.MAGIC)
        buffer.put(JournalPaths.VERSION.toByte())
        buffer.put(0.toByte())
        buffer.putShort(sessionBytes.size.toShort())
        buffer.put(sessionBytes)
        buffer.putLong(prunedUpto)
        return buffer.array()
    }

    private fun encodeRecord(jseq: Long, record: ByteArray): ByteArray {
        val crc = journalCrc(jseq, record)
        val buffer = ByteBuffer.allocate(RECORD_PREFIX_BYTES + record.size)
        buffer.putInt(record.size)
        buffer.putInt(crc)
        buffer.putLong(jseq)
        buffer.put(record)
        return buffer.array()
    }

    /**
     * The record CRC, over `jseq ‖ record`.
     *
     * The jseq is covered on purpose: without it a bit flip in a final jseq
     * would look like a valid new high-water mark and silently ack a number
     * whose record is gone.
     */
    private fun journalCrc(jseq: Long, record: ByteArray): Int {
        val input = ByteArray(8 + record.size)
        ByteBuffer.wrap(input).putLong(jseq)
        System.arraycopy(record, 0, input, 8, record.size)
        return WireCodec.crc32c(input)
    }

    private fun readHeaderOrNull(path: Path): Header? {
        if (!Files.exists(path, LinkOption.NOFOLLOW_LINKS)) return null
        if (!Files.isRegularFile(path, LinkOption.NOFOLLOW_LINKS)) {
            throw corrupt("${paths.label(path)} is not a regular file")
        }
        try {
            FileChannel.open(path, StandardOpenOption.READ).use { channel ->
                val size = channel.size()
                val minimum = JournalPaths.HEADER_PREFIX_BYTES + JournalPaths.HEADER_TRAILER_BYTES
                if (size < minimum) throw corrupt("${paths.label(path)} is shorter than its header")
                val prefix = ByteBuffer.allocate(JournalPaths.HEADER_PREFIX_BYTES)
                readFully(channel, prefix, 0L)
                prefix.flip()
                val magic = prefix.int
                val version = prefix.get().toInt() and 0xFF
                val flags = prefix.get().toInt() and 0xFF
                val sessionLength = prefix.short.toInt() and 0xFFFF
                if (magic != JournalPaths.MAGIC) {
                    throw corrupt("${paths.label(path)} has a bad magic")
                }
                if (version != JournalPaths.VERSION) {
                    throw corrupt("${paths.label(path)} has version $version")
                }
                if (flags != 0) throw corrupt("${paths.label(path)} has reserved header flags set")
                val headerBytes = JournalPaths.HEADER_PREFIX_BYTES + sessionLength +
                    JournalPaths.HEADER_TRAILER_BYTES
                if (sessionLength <= 0 || headerBytes.toLong() > size) {
                    throw corrupt("${paths.label(path)} has an impossible session id length")
                }
                val sessionBytes = ByteArray(sessionLength)
                readFully(
                    channel,
                    ByteBuffer.wrap(sessionBytes),
                    JournalPaths.HEADER_PREFIX_BYTES.toLong(),
                )
                val sessionId = String(sessionBytes, Charsets.UTF_8)
                if (!JournalFrame.SESSION_ID.matches(sessionId)) {
                    throw corrupt("${paths.label(path)} has an invalid session id")
                }
                val trailer = ByteBuffer.allocate(JournalPaths.HEADER_TRAILER_BYTES)
                readFully(
                    channel,
                    trailer,
                    (JournalPaths.HEADER_PREFIX_BYTES + sessionLength).toLong(),
                )
                trailer.flip()
                val prunedUpto = trailer.long
                if (prunedUpto < 0L) throw corrupt("${paths.label(path)} has a negative pruned_upto")
                return Header(sessionId, prunedUpto, headerBytes)
            }
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (error: JournalException) {
            throw error
        } catch (error: IOException) {
            throw JournalException(
                JournalFailure.IO,
                "cannot read ${paths.label(path)}: ${error.message}",
                cause = error,
            )
        }
    }

    // -----------------------------------------------------------------------
    // File-system helpers
    // -----------------------------------------------------------------------

    /** Every session file, in a stable `<hex>.xljournal` order. */
    private fun sessionFiles(): List<Path> {
        val directory = paths.journalDirectory
        if (!Files.isDirectory(directory, LinkOption.NOFOLLOW_LINKS)) return emptyList()
        val files = ArrayList<Path>()
        try {
            Files.newDirectoryStream(directory).use { stream ->
                for (entry in stream) {
                    if (!Files.isRegularFile(entry, LinkOption.NOFOLLOW_LINKS)) continue
                    if (!entry.fileName.toString().endsWith(JournalPaths.FILE_SUFFIX)) continue
                    files.add(entry)
                }
            }
        } catch (error: IOException) {
            throw JournalException(
                JournalFailure.IO,
                "cannot list the journal directory: ${error.message}",
                cause = error,
            )
        }
        files.sortWith(compareBy { it.fileName.toString() })
        return files
    }

    private fun measure(files: List<Path> = sessionFiles()): Long =
        files.sumOf { sizeOf(it) }

    private fun sizeOf(path: Path): Long = try {
        Files.size(path)
    } catch (error: IOException) {
        throw JournalException(
            JournalFailure.IO,
            "cannot measure ${paths.label(path)}: ${error.message}",
            cause = error,
        )
    }

    private fun readFully(channel: FileChannel, buffer: ByteBuffer, position: Long) {
        var at = position
        while (buffer.hasRemaining()) {
            val read = channel.read(buffer, at)
            if (read < 0) throw IOException("unexpected end of file at byte $at")
            at += read
        }
    }

    private fun writeFully(channel: FileChannel, bytes: ByteArray) {
        val buffer = ByteBuffer.wrap(bytes)
        while (buffer.hasRemaining()) {
            channel.write(buffer)
        }
    }

    private fun copyRange(source: FileChannel, destination: FileChannel, offset: Long, length: Long) {
        val buffer = ByteBuffer.allocate(COPY_CHUNK_BYTES)
        var at = offset
        var remaining = length
        while (remaining > 0L) {
            buffer.clear()
            buffer.limit(minOf(remaining, COPY_CHUNK_BYTES.toLong()).toInt())
            val read = source.read(buffer, at)
            if (read < 0) throw IOException("unexpected end of file at byte $at")
            if (read == 0) continue
            at += read
            remaining -= read
            buffer.flip()
            while (buffer.hasRemaining()) {
                destination.write(buffer)
            }
        }
    }

    private fun corrupt(detail: String): JournalException =
        JournalException(JournalFailure.CORRUPT, detail)

    companion object {
        /** budgets.md §5: the journal row is 64 MiB. */
        const val DEFAULT_LIMIT_BYTES: Long = 64L * 1024L * 1024L

        /** `len u32 | crc32c u32 | jseq u64`. */
        private const val RECORD_PREFIX_BYTES: Int = 16

        /** The 16 MiB frame bound of channel.md §1 is the largest record possible. */
        private const val MAX_RECORD_BYTES: Int = 16 * 1024 * 1024

        private const val COPY_CHUNK_BYTES: Int = 64 * 1024

        private val EMPTY_BYTES: ByteArray = ByteArray(0)
    }
}
