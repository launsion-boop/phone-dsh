// phone-dsh — :dsh / com.phonedsh.dsh.journal: the JOURNAL → fsync → ACK sink.
// SPDX-License-Identifier: MIT
//
// ---- the lane this closes --------------------------------------------------
// N1's device evidence: the host did not implement JOURNAL at all, so the worker
// waited out its 30 s durability acknowledgement window, reconnected and hit a
// 409. The test surface kept the channel alive with a seam that answered
// `JOURNAL_ACK` level 1 without writing a byte, and labelled itself "not
// durability evidence". This class is the real path: the record goes through
// [JournalStore], which writes and fsyncs it, and only the return of that call
// can produce an acknowledgement.
//
// ---- level: 2, and why that is also the level-1 answer ---------------------
// §3.6 defines level 1 as "journal write() returned" and level 2 as "journal
// fsync". Every record here is appended *and fsynced* before its ACK exists, so
// the honest level is 2 — the write() of level 1 has necessarily returned too.
// The worker's `AckTracker` treats a level-2 acknowledgement as implying level 1
// for the same sequence (`resolve` advances both), so a `tool-journal` append
// waiting on level 1 resolves on this frame, and a checkpoint waiting on level 2
// is satisfied at the same moment. No timer, no group commit and no "ack now,
// persist later" seam is involved.
//
// ---- deduplication and the forward gap (§3.5, §9.3) -----------------------
// The worker keeps a jseq after a reconnect and re-sends it; the host dedupes by
// `(session_id, jseq)`. A jseq at or below the highest appended value is a
// duplicate: nothing is written and the cumulative watermark is acked again.
// A jseq above `highest + 1` is a forward gap and is `BAD_PAYLOAD`, which the
// channel answers with one closing `ERROR`. Watermarks survive a boot through
// [JournalStore.recover] (including a pruned file's `pruned_upto`), so a worker
// restart cannot replay a number the store already accepted.
//
// ---- capability ------------------------------------------------------------
// `channel.md` §4.1 defines **no host journal capability**: host caps are
// `channel/1`, `wal/1`, `exec/1` and `accelerator:*`, and only the *worker* caps
// are `["channel/1","vfs-sink/1","journal/1","api/1"]`. This lane therefore
// invents no string and changes no HELLO. The gate is internal: [isOpen] is
// `true` only after [open] on a successful store recovery, and `HostChannel`
// ignores JOURNAL frames while it is `false`, exactly as it ignores `VFS_MUT`
// before the host HELLO.

package com.phonedsh.dsh.journal

import com.phonedsh.dsh.host.HostLog
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

/** The outbound side of one journal connection; implemented by the channel. */
fun interface JournalSender {
    /** Sends one `JOURNAL_ACK`; the channel owns the frame's `seq`. */
    suspend fun send(ack: JournalAck)
}

/**
 * The journal lane: `JOURNAL(0x30)` in, one durable append, `JOURNAL_ACK(0x31)` out.
 *
 * One instance is owned by the facade for the boot. [open] is called once, from
 * the boot job, after [JournalStore.recover] succeeded; the channel attaches and
 * detaches the one connection that receives acknowledgements.
 *
 * @param store the durable store; it owns every byte and the quota.
 * @param logger the token-free log seam.
 */
class JournalSink(
    private val store: JournalStore,
    private val logger: HostLog = HostLog.None,
) {
    /** Serialises append/ack pairs, so two frames cannot interleave watermarks. */
    private val mutex = Mutex()

    /** Guards [highest] and is readable from any thread (tests, the facade). */
    private val stateLock = Any()

    /** Guards [sender]. */
    private val senderLock = Any()

    /** The highest appended jseq per session, seeded by [open]. */
    private val highest = LinkedHashMap<String, Long>()

    @Volatile
    private var opened: Boolean = false

    /** The one connection that may receive acknowledgements. */
    private var sender: JournalSender? = null

    /** `true` only after [open] on a successful store recovery. */
    val isOpen: Boolean get() = opened

    /** A snapshot of the durable watermark per session, for logs and diagnostics. */
    fun watermarks(): Map<String, Long> = synchronized(stateLock) { LinkedHashMap(highest) }

    /**
     * The highest `jseq` whose fsync returned for [sessionId], 0 when none.
     *
     * This is the value a `JOURNAL_ACK` names. It never comes from a write buffer:
     * [onJournal] sets it from [JournalStore.append]'s return, after the fsync.
     */
    fun durableUpto(sessionId: String): Long =
        synchronized(stateLock) { highest[sessionId] ?: 0L }

    /**
     * Seeds the sink from a successful recovery and opens the lane.
     *
     * Idempotent: a `start()` after `stop()` reseeds the same watermarks.
     */
    internal suspend fun open(recovery: JournalRecovery) = mutex.withLock {
        synchronized(stateLock) {
            highest.clear()
            highest.putAll(recovery.highestJseq)
        }
        opened = true
        logger.info(
            "journal: open (${recovery.highestJseq.size} session(s), ${recovery.usedBytes} bytes, " +
                "${recovery.truncatedTails.size} torn tail(s) removed)",
        )
    }

    /** Attaches the connection that receives acknowledgements. */
    fun attach(sender: JournalSender) {
        synchronized(senderLock) { this.sender = sender }
    }

    /**
     * Closes the lane until the next [open].
     *
     * The facade calls this before it retries recovery on a later `start()`, so a
     * sink that opened on a previous boot can never accept a frame while the
     * store is being re-scanned (or after that rescan failed). Closing clears no
     * watermarks: they are re-seeded from the store by [open].
     */
    internal fun close() {
        opened = false
    }

    /**
     * Detaches [sender] if it is still the current one.
     *
     * The in-memory watermarks are kept: a cumulative ACK after a reconnect is
     * still true, and the worker re-sends what it still needs (§9.3).
     */
    fun detach(sender: JournalSender?) {
        synchronized(senderLock) {
            if (sender == null || this.sender === sender) this.sender = null
        }
    }

    /**
     * Handles one `JOURNAL` frame.
     *
     * The acknowledgement is emitted **after** [JournalStore.append] returned,
     * i.e. after the record's `fsync`. A duplicate emits the current watermark
     * without a write; a forward gap, a malformed frame or an unwritable store
     * emits nothing.
     *
     * @param frame the whole frame, header included, so the Rust codec decodes it.
     * @throws JournalException `JOURNAL_PROTOCOL` with a §10 `wireCode` for a
     *   refused frame, or a host-side failure from the store (`JOURNAL_QUOTA_EXCEEDED`,
     *   `JOURNAL_IO`, …). The channel turns the former into one closing `ERROR`
     *   and lets the latter close the transport without a protocol error.
     */
    suspend fun onJournal(frame: ByteArray) {
        mutex.withLock {
            if (!opened) {
                throw JournalException(
                    JournalFailure.NOT_READY,
                    "journal/1 is not open this boot; no record was written",
                )
            }
            val record = when (val decoded = JournalFrame.parse(frame)) {
                is JournalFrame.Invalid -> throw JournalException(
                    JournalFailure.PROTOCOL,
                    decoded.detail,
                    wireCode = decoded.code,
                )

                is JournalFrame.Parsed -> decoded.value
            }
            val sessionId = record.sessionId
            val current = synchronized(stateLock) { highest[sessionId] ?: 0L }
            if (record.jseq <= current) {
                // A reconnect re-send (§9.3) or an append whose ACK was lost. The
                // bytes are already durable, so the cumulative watermark is true
                // and no second record is written.
                emit(JournalAck(JournalAck.LEVEL_FSYNC, sessionId, current))
                return@withLock
            }
            if (record.jseq > current + 1L) {
                // §3.5: "a forward gap is BAD_PAYLOAD". Nothing is written.
                throw JournalException(
                    JournalFailure.PROTOCOL,
                    "expected jseq ${current + 1L}, got ${record.jseq}",
                    wireCode = "BAD_PAYLOAD",
                )
            }
            val appended = store.append(sessionId, record.jseq, record.record)
            synchronized(stateLock) { highest[sessionId] = appended.jseq }
            emit(JournalAck(JournalAck.LEVEL_FSYNC, sessionId, appended.jseq))
        }
    }

    /**
     * Sends one acknowledgement, or drops it when no connection is attached.
     *
     * A dropped ACK is not a lost record: the next connection makes the worker
     * re-send the jseq, and the duplicate branch above acks it from the durable
     * watermark. Acking a record that was never written is the failure this
     * class exists to prevent; failing to deliver a true ACK is recoverable.
     */
    private suspend fun emit(ack: JournalAck) {
        val target = synchronized(senderLock) { sender }
        if (target == null) {
            logger.warn(
                "journal: no channel attached; dropping JOURNAL_ACK for ${ack.sessionId} " +
                    "jseq ${ack.uptoJseq} (the worker re-sends it)",
            )
            return
        }
        target.send(ack)
    }
}
