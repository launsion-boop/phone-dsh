// phone-dsh — :dsh / com.phonedsh.dsh.host: the VFS sink behind wal/1.
// SPDX-License-Identifier: MIT
//
// ---- what "wal/1" means here ----------------------------------------------
// `channel.md` §3.2 defines `VFS_ACK.level = 1` as "the WAL write() returned".
// Claiming `wal/1` therefore means the host decodes `VFS_MUT`, appends the
// mutation to a recovered `WorkspaceLog`, and answers with a level-1 ACK. This
// class is that path. It is the reason [WalUplink.Up] exists only behind a
// [VfsSink.Wired] proof: until this sink is opened on a recovered log, the host
// has no business telling the worker its writes are durable.
//
// ---- what it deliberately does not do -------------------------------------
// * No group commit. Every accepted `VFS_MUT` gets its own level-1 ACK, which
//   §3.2 explicitly allows ("acks are cumulative and may coalesce"; coalescing
//   is an optimization, not a requirement). A 2 ms group commit can replace the
//   per-append `emit` later without changing the wire contract.
// * No level-2 ACK from a barrier. A `VFS_BARRIER(want_level = 2)` is recorded
//   and answered only by [closeEpoch], which is the one operation that has
//   fsynced the materialized tree, every segment and the manifest (D18). The
//   barrier itself returns immediately, so it cannot reorder or block other
//   frames.
// * No reconnect/seq state. The channel owns seq numbers; this sink only sees
//   the decoded frame and the inbound `ref_seq` for an ERROR.
//
// ---- duplicate mseq (D9) and the one allocator ------------------------------
// The worker re-sends mutations above `acked_mseq` after a reconnect, so a
// `VFS_MUT` whose mseq this sink already admitted is a replay: the WAL holds it,
// the sink appends nothing and answers with the current level-1 watermark. The
// sink treats `mseq` as the idempotency key; it does not compare the body of a
// replayed frame, because a worker that changed the body under the same mseq
// would be violating the reconnect rule in §9.2.
//
// The number itself is never this class's to allocate. `channel.md` §8 makes the
// host the allocator and `wal.md` §7.2 derives `next_mseq` from the WAL tail, so
// the expected mseq is read from [HostWal.allocator] at the moment the frame is
// handled and the append is re-checked inside the log's lock. An earlier version
// cached the pair at `open()`; an App-side workspace write then advanced the log
// behind the sink, the next `VFS_MUT` was appended at a number the host had
// already spent, and the mismatch closed the ordered channel for the rest of the
// session (`WAL allocated mseq N+1 for the worker's N`, measured on API 35).
//
// A frame below the tail that this sink never admitted is therefore not a replay
// but a Worker whose numbering the **host lane** overtook: it is answered
// `BAD_MSEQ` (§8/§10 closes) and never appended anywhere. The next connection's
// HELLO carries the live numbers and re-anchors the Worker (§9.2); the facade
// also restarts a live Worker after a host-lane write so its VFS sees the file
// at all (wal.md §7.2 "Host-side writes").

// ---- admission (D14): the write path is deliberately NOT gated by it ------
// P26 removed an `AdmissionGate` check from this file. It used to answer a
// `VFS_MUT` that arrived while admission was closed with `VFS_RESYNC`, appending
// and acknowledging nothing. That is not what the contract says, and it burned
// the worker's mseq space:
//
//   * channel.md §7 item 6 draws the line explicitly: "While admission is closed
//     the worker starts no new tool work and sends no new EXEC_REQ; the host
//     starts none and answers one with a terminal `error`; **flushing and
//     in-flight work continue**." A `VFS_MUT` is the flush of work that was
//     already admitted, so it must keep flowing.
//   * budgets.md §1 says the same for the state that closes admission on the way
//     out: `Draining` is "Close admission, **wait for in-flight work**, close a
//     WAL epoch; 20 s deadline."
//   * channel.md §3.4 defines `VFS_RESYNC` as "Asks for a complete re-send of
//     `path` after an appended mutation could not be materialized" — a repair
//     for an **accepted** record (wal.md §5.1 keeps "the mismatching record and
//     every later append of the path in the WAL"), never a refusal. The worker
//     answers it with a complete write at the **next** mseq, so a host that
//     sends it for a mutation it did not append has just told the worker to
//     advance while `expected_mseq` stays put: the next frame is `BAD_MSEQ` by
//     construction.
//   * The reference implementation behaves the same way: `Sources/PhoneDSHLoopback/
//     ChannelServer.swift` handles `.vfsMutation` with no admission check (it
//     checks admission on `.execRequest` in `DefaultChannelHandling.swift`), and
//     `Sources/PhoneDSH/PhoneDSHHost.swift:608-612` states it outright — "VFS_MUT
//     frames are not admission-gated on an already-connected channel".
//
// The defect this closes, reproduced on an AVD (P26): `Running -> Backoff`
// closed admission, 480 in-flight mutations arrived, each got a `VFS_RESYNC` and
// no ACK, the worker's mseq ran 105 -> 585, and admission reopening made the
// next frame `BAD_MSEQ: expected mseq 105, got 585`; the worker closed the
// ordered channel and the turn failed. A state that must not advance the WAL (a
// handoff, a remote authority) stops the mutation source; it does not refuse
// frames on an already-connected channel.

// ---- the single-file budget (budgets.md §4, channel.md §6/§8) --------------
// `single_file_limit` is the boot's `single_file_limit` from [HostBudgetTier]:
// budgets.md:104 fixes the per-tier value (256 / 128 / 48 / 32 / 16 MiB) and
// budgets.md:120-123 says the limit is enforced at write time.
//
// The host-side check is the *backstop*. The primary refusal is the Worker's
// own `EFBIG` before it publishes anything (channel.md:264-268), which is what
// `PDSH_SINGLE_FILE_LIMIT_BYTES` in the Worker environment enables. This sink
// still has to answer a mutation that would grow a file past the limit, because
// a Worker with a stale or absent environment would otherwise push the bytes
// into the WAL and only recovery would notice:
//
//   - the mutation is structurally valid, so this is **not** a protocol error:
//     one `ERROR VFS_REFUSED` with `path`/`limit`/`reason` plus the refused
//     `mseq` and its accepted prefix `accepted_bytes` (channel.md:236, §4.8),
//     `ref_seq` naming the refused frame, and no closing code (channel.md:362);
//   - nothing is appended, `expected_mseq` is unchanged, and the Worker resends
//     the same `mseq` after shrinking to `limit - accepted_bytes` (§4.8, §8);
//   - the host never treats the refusal as a connection error and does not enter
//     `Failed` (§8 "Resource refusal is not structural").
//
// The post-write logical size is the mutation's own claim: `append_from` plus
// the suffix length for an appended mutation (channel.md:264-266 makes
// `append_from` the accepted logical length), and the data length alone for a
// complete write (one complete write replaces the file). `accepted_bytes` is
// therefore `append_from` of an appended mutation, or 0 for a complete write —
// exactly the two structured members §4.8 defines.

// ---- a failed append is a D14 failure (budgets.md §2/§5) -------------------
// A structurally valid mutation the WAL cannot persist is not a worker error,
// so no §10 ERROR is invented for it. It is a host write failure: the
// attributable codes of [HostFailureRules] are reported through [WriteFailureSink],
// which closes admission and moves the controller to `Failed`, and the
// exception is still rethrown so the transport closes. Keeping every durable
// byte is the controller's `KEEP_DURABLE_BYTES` effect; this sink only reports.

package com.phonedsh.dsh.host

import com.phonedsh.controller.ControllerBudgets
import com.phonedsh.log.MutationBody
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

/** The outbound side of one VFS connection; implemented by the channel. */
fun interface VfsSender {
    /** Sends one typed frame to the worker. */
    suspend fun send(frame: VfsFrame)
}

/**
 * The VFS write path: `VFS_MUT` → WAL append → `VFS_ACK(1)`, plus the barrier
 * queue and the epoch-close level-2 ACK.
 *
 * One instance is owned by the facade for the boot. [open] is called exactly
 * once recovery succeeded; after that the instance is ready. The channel calls
 * [onMut]/[onBarrier] for inbound frames and attaches/detaches the one
 * connection that receives outgoing frames.
 */
class VfsSink(
    private val wal: HostWal,
    private val logger: HostLog = HostLog.None,
    private val failures: WriteFailureSink = WriteFailureSink.None,
    /**
     * This boot's `single_file_limit` in bytes (budgets.md:104, :120-123),
     * selected once by [HostBudgetTier] from `MemoryInfo.totalMem`.
     *
     * The default is [HostBudgetTier.UNMEASURED] — the `≤ 3 GiB` row's 16 MiB,
     * the same answer a failed memory reading gets — so a sink constructed
     * without a measurement can never carry a quota larger than the smallest
     * row. The App measures and passes the selected row's value; this default is
     * only reachable from a caller with no device at all (the JVM test suite).
     */
    private val singleFileLimitBytes: Long = HostBudgetTier.UNMEASURED.singleFileBytes,
) {
    /**
     * Proof that a VFS sink exists and has opened on a recovered WAL.
     *
     * The constructor is private and [issuedBySink] is `internal`: outside
     * `:dsh` there is no way to obtain one, so `WalUplink.up` (which requires a
     * `Wired`) cannot advertise `wal/1` before this sink is real.
     */
    class Wired private constructor() {
        internal companion object {
            /** Mints the proof; only the sink's [open] calls it. */
            fun issuedBySink(): Wired = Wired()
        }
    }

    private val mutex = Mutex()
    private val senderLock = Any()
    private val pending = ArrayList<PendingBarrier>()

    /** The one connection currently allowed to receive VFS frames. */
    private var sender: VfsSender? = null

    /**
     * Paths whose §5.1 repair is still outstanding, with the mseq that raised
     * it. `wal.md` §5.1 allows at most one outstanding resync per path; this
     * map is that "one", retained across a connection loss so a reconnect can
     * re-request it (`channel.md` §9 item 6).
     *
     * Guarded by [senderLock] because [attach]/[detach] are not suspending.
     */
    private val outstandingResyncs = LinkedHashMap<String, Long>()

    /** Outstanding paths already requested on the current connection. */
    private val requestedResyncs = HashSet<String>()

    /**
     * The highest mseq **this sink** appended for the Worker.
     *
     * It is the only counter the sink owns, and it is not the allocator: the
     * number a mutation receives is decided by [HostWal.allocator] under the
     * log's lock. This value answers one question the log cannot — "did *I*
     * append this mseq?" — which is what separates a D9 replay (the Worker
     * re-sending what the host already has) from a stale Worker whose next
     * number an App-side write consumed. Seeded from recovery's effective tail
     * because every record at or below it came from an earlier Worker lane; a
     * re-send of one of those is a replay by the §9.2 rule.
     */
    private var acceptedThrough: Long = 0L

    private var durableMseq: Long = 0L
    private var opened: Boolean = false

    /** A barrier waiting for a watermark that has not been reached yet. */
    private data class PendingBarrier(
        val wantLevel: Int,
        val uptoMseq: Long,
        val refSeq: Long,
    )

    /**
     * Seeds the sink from a successful recovery and returns the `wal/1` proof.
     *
     * Idempotent: a second call (a `start()` after `stop()`) reseeds the same
     * numbers the log reports again. [WalUplink.up] is the only consumer of the
     * returned proof.
     *
     * @throws IllegalArgumentException when a number is negative (a broken
     *   fake; the real adapter only returns non-negative values).
     */
    internal suspend fun open(recovered: WalRecovery.Recovered): Wired = mutex.withLock {
        require(recovered.nextMseq >= 0L) { "nextMseq must be non-negative" }
        require(recovered.ackedMseq >= 0L) { "ackedMseq must be non-negative" }
        require(recovered.durableMseq >= 0L) { "durableMseq must be non-negative" }
        // The allocator itself is never seeded here: it lives in the log and
        // `open` only remembers what this sink has accepted so far.
        acceptedThrough = recovered.ackedMseq
        durableMseq = recovered.durableMseq
        synchronized(senderLock) {
            outstandingResyncs.clear()
            for (request in recovered.resync) {
                outstandingResyncs.putIfAbsent(request.path, request.mseq)
            }
            requestedResyncs.clear()
        }
        opened = true
        Wired.issuedBySink()
    }

    /** Attaches the connection that receives ACKs/RESYNC/ERROR. */
    fun attach(sender: VfsSender) {
        synchronized(senderLock) {
            this.sender = sender
            // A new connection has not received the outstanding requests yet;
            // `onHelloAnswered` re-sends one per path after the host HELLO.
            requestedResyncs.clear()
        }
    }

    /**
     * Detaches [sender] if it is still the current one.
     *
     * Pending barriers are kept: a cumulative ACK after a reconnect is still
     * true, and the worker re-sends barriers it still needs (§9).
     */
    fun detach(sender: VfsSender?) {
        synchronized(senderLock) {
            if (sender == null || this.sender === sender) this.sender = null
        }
    }

    /**
     * Re-requests every outstanding repair once on this connection, after the
     * host HELLO has opened its direction (`channel.md` §9 item 6,
     * `wal.md` §10 step 4).
     *
     * The outstanding set survives [detach]; only [open] replaces it from a new
     * recovery. A path already requested on this connection is skipped, which
     * keeps the "at most one resync outstanding per path" rule across
     * reconnects as well as live appends.
     */
    internal suspend fun onHelloAnswered() = mutex.withLock {
        if (!opened) return@withLock
        val toRequest = synchronized(senderLock) {
            outstandingResyncs.keys.filter { it !in requestedResyncs }
        }
        for (path in toRequest) {
            if (emit(VfsFrame.Resync(path))) {
                synchronized(senderLock) { requestedResyncs.add(path) }
            }
        }
    }

    /**
     * The highest mseq admitted at level 1, read live from the WAL.
     *
     * It is the allocator's tail, not a value this sink counted: an App-side
     * workspace write is also level-1 durable, so a cumulative ACK that names it
     * is true. A value cached at `open` would understate the log forever after
     * one import.
     */
    val ackedWatermark: Long get() = wal.allocator().lastMseq

    /** The highest mseq durable at level 2 (for tests and diagnostics). */
    val durableWatermark: Long get() = durableMseq

    /**
     * Handles one `VFS_MUT`.
     *
     * The D14 admission gate is deliberately not consulted: channel.md §7 item 6
     * keeps "flushing and in-flight work" running while admission is closed, so
     * a mutation is appended and level-1 acknowledged in every host state. See
     * the file header for the contract text and for the P26 defect the removed
     * `VFS_RESYNC` answer caused.
     *
     * @param frame the whole frame, header included, so the Rust codec can
     *   decode it.
     * @param refSeq the inbound frame's `seq`, used only in an ERROR.
     */
    suspend fun onMut(frame: ByteArray, refSeq: Long) = mutex.withLock {
        if (!opened) {
            emit(
                VfsFrame.Error(
                    code = "PROTO_MISMATCH",
                    message = "wal/1 is not available this boot",
                    refSeq = refSeq,
                    closeConnection = true,
                ),
            )
            return@withLock
        }
        when (val decoded = VfsMutFrame.parse(frame)) {
            is VfsMutFrame.Invalid ->
                emit(
                    VfsFrame.Error(
                        code = decoded.code,
                        message = decoded.detail,
                        refSeq = refSeq,
                        closeConnection = decoded.code != "VFS_REFUSED",
                    ),
                )

            is VfsMutFrame.Parsed -> append(decoded, refSeq)
        }
    }

    /**
     * Handles one `VFS_BARRIER`.
     *
     * Never waits: it answers immediately when the requested level already
     * covers the mseq, and otherwise queues the barrier for the append or
     * epoch-close path. That is the §3.3 "never reorders or blocks other
     * frames" rule.
     */
    suspend fun onBarrier(frame: ByteArray, refSeq: Long) = mutex.withLock {
        if (!opened) {
            emit(
                VfsFrame.Error(
                    code = "PROTO_MISMATCH",
                    message = "wal/1 is not available this boot",
                    refSeq = refSeq,
                    closeConnection = true,
                ),
            )
            return@withLock
        }
        when (val decoded = VfsBarrierFrame.parse(frame)) {
            is VfsBarrierFrame.Invalid ->
                emit(
                    VfsFrame.Error(
                        code = decoded.code,
                        message = decoded.detail,
                        refSeq = refSeq,
                        closeConnection = true,
                    ),
                )

            is VfsBarrierFrame.Parsed -> {
                val acked = ackedWatermark
                val covered = when (decoded.wantLevel) {
                    1 -> acked >= decoded.uptoMseq
                    else -> durableMseq >= decoded.uptoMseq
                }
                if (covered) {
                    emit(
                        VfsFrame.Ack(
                            level = decoded.wantLevel,
                            uptoMseq = if (decoded.wantLevel == 1) acked else durableMseq,
                        ),
                    )
                } else {
                    pending += PendingBarrier(decoded.wantLevel, decoded.uptoMseq, refSeq)
                }
            }
        }
    }

    /**
     * Closes the current epoch in the D18 order and emits the one level-2 ACK
     * that close is allowed to produce.
     *
     * The ACK names the close record's `durable_upto` — the highest mseq in the
     * epoch — not the barrier's requested value. Every queued level-2 barrier
     * at or below that point is satisfied; one above it stays queued for a later
     * close.
     *
     * A close the WAL refuses or cannot perform is reported through [failures]
     * (so admission closes and the state becomes `Failed`) and is then
     * rethrown; budgets.md §2 lists an unrepaired base mismatch at an epoch
     * close and a WAL I/O failure as fail-loud conditions.
     *
     * @return `durable_upto`, or `null` when the sink was never opened.
     * @throws Exception from the WAL's close path (fsync/manifest failure).
     */
    suspend fun closeEpoch(): Long? = mutex.withLock {
        if (!opened) return@withLock null
        val close = try {
            wal.closeEpoch()
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (failure: Exception) {
            reportFailure("WAL epoch close", failure)
            throw failure
        }
        durableMseq = maxOf(durableMseq, close.durableUpto)
        pending.removeAll { barrier ->
            barrier.wantLevel == 2 && barrier.uptoMseq <= durableMseq
        }
        // §3.2: level 2 is sent only by an epoch close, for the highest mseq in
        // that epoch. It is not conditioned on a barrier being queued.
        emit(VfsFrame.Ack(level = 2, uptoMseq = close.durableUpto))
        close.durableUpto
    }

    // -----------------------------------------------------------------------
    // Write path
    // -----------------------------------------------------------------------

    /**
     * Decides one `VFS_MUT` against the **live** allocator and appends it.
     *
     * The three answers of `channel.md` §8 are decided here, and none of them
     * keeps a private counter (the L77 defect: the sink compared against a
     * boot-time snapshot, so one App-side workspace write made every following
     * Worker mutation "misnumbered" and the `IllegalStateException` closed the
     * channel; 600 records were then appended at the wrong mseqs by the retries):
     *
     * * `mseq == next_mseq` — the record is appended, level-1 acked and
     *   materialized. The append itself is re-checked inside the log's lock
     *   ([HostWal.appendWorker]), so an App-side write that landed between the
     *   read and the append turns into one of the two cases below instead of a
     *   record with a different number;
     * * `mseq <= last_mseq` and this sink already accepted it — a D9 replay
     *   (§9.2): nothing is appended, the cumulative level-1 watermark answers;
     * * `mseq <= last_mseq` and this sink never accepted it — a **stale Worker**:
     *   the number was consumed by a host-side workspace write while the Worker's
     *   VFS was the authority, so its view of the workspace is behind. The frame
     *   is not a replay, and appending it at another number would silently
     *   renumber the Worker's stream; it is answered `BAD_MSEQ` (§8/§10) and the
     *   connection closes. The Worker's next HELLO carries the live numbers and
     *   re-anchors it (§9.2, and `plugins/channel`'s client adopts them), so the
     *   channel recovers instead of dying.
     */
    private suspend fun append(decoded: VfsMutFrame.Parsed, refSeq: Long) {
        val mseq = decoded.mseq
        val allocator = wal.allocator()
        if (mseq <= allocator.lastMseq) {
            if (mseq <= acceptedThrough) {
                // D9 replay: the WAL already holds this mseq. No append; the
                // worker still gets the cumulative level-1 watermark.
                emit(VfsFrame.Ack(level = 1, uptoMseq = allocator.lastMseq))
            } else {
                refuseStaleMseq(mseq, allocator.lastMseq, refSeq)
            }
            return
        }
        if (mseq > allocator.nextMseq) {
            refuseGap(mseq, allocator.nextMseq, refSeq)
            return
        }

        // Structural checks are done (mseq is the expected one, the path and the
        // op/mode/mflags are valid); only now is the *resource* budget checked,
        // so a refusal here can never be confused with a malformed frame.
        val acceptedBytes = if (decoded.body.appended) decoded.body.appendFrom else 0L
        val postWriteBytes = try {
            Math.addExact(acceptedBytes, decoded.body.data.size.toLong())
        } catch (_: ArithmeticException) {
            Long.MAX_VALUE
        }
        if (postWriteBytes > singleFileLimitBytes) {
            refuseTooLarge(
                body = decoded.body,
                acceptedBytes = acceptedBytes,
                postWriteBytes = postWriteBytes,
                refSeq = refSeq,
                mseq = mseq,
            )
            return
        }

        val outcome = try {
            wal.appendWorker(decoded.body, mseq)
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (failure: Exception) {
            // Not a protocol error: the worker's frame was valid and the host
            // failed to persist it. There is no §10 code for a host write
            // failure, so the transport is closed rather than blaming the
            // payload; a code HostFailureRules can attribute (quota, corrupt
            // bytes, I/O) is also recorded as the D14 failure it is.
            reportFailure("VFS append", failure)
            throw failure
        }

        when (outcome) {
            is WalWorkerAppend.Appended -> {
                val appended = outcome.append
                acceptedThrough = maxOf(acceptedThrough, appended.mseq)
                // The level-1 ACK is emitted only after the append returned: that
                // is exactly the §3.2 "WAL write() returned" fact.
                emit(VfsFrame.Ack(level = 1, uptoMseq = appended.mseq))
                // wal.md §5.1: at most one resync outstanding per path. The
                // append path reports the *current* held request on every
                // mutation while the repair is pending; only the first one on
                // this connection becomes a frame.
                appended.resyncPath?.let { path -> requestResyncOnce(path, appended.mseq) }
                clearSettledResyncs(appended.materializedUptoMseq)
                satisfyLevel1Barriers()
            }

            is WalWorkerAppend.Behind -> {
                // The App lane took this mseq between the read above and the
                // append. Same two answers, decided on the log's own numbers.
                if (mseq <= acceptedThrough) {
                    emit(VfsFrame.Ack(level = 1, uptoMseq = outcome.lastMseq))
                } else {
                    refuseStaleMseq(mseq, outcome.lastMseq, refSeq)
                }
            }

            is WalWorkerAppend.Ahead -> refuseGap(mseq, outcome.nextMseq, refSeq)
        }
    }

    /**
     * One `BAD_MSEQ` for a Worker whose numbering the host lane has overtaken.
     *
     * The frame is not appended anywhere: §8 accepts only `mseq == expected`,
     * and the Worker's view of the workspace no longer matches the WAL, so the
     * only honest answer is the protocol's own refusal. Nothing is logged from
     * the body; the numbers are host facts.
     */
    private suspend fun refuseStaleMseq(mseq: Long, tail: Long, refSeq: Long) {
        logger.error(
            "VFS_MUT mseq $mseq is behind the WAL tail $tail and was not appended by the VFS " +
                "lane: a host-side workspace write consumed it, so the Worker's VFS is stale. " +
                "Answering BAD_MSEQ and closing this connection; the next HELLO carries " +
                "next_mseq=${tail + 1} and re-anchors the Worker (channel.md §8, §9.2)",
        )
        emit(
            VfsFrame.Error(
                code = "BAD_MSEQ",
                message = "expected mseq ${tail + 1}, got $mseq",
                refSeq = refSeq,
                closeConnection = true,
            ),
        )
    }

    /** One `BAD_MSEQ` for a forward gap (no record is appended). */
    private suspend fun refuseGap(mseq: Long, next: Long, refSeq: Long) {
        emit(
            VfsFrame.Error(
                code = "BAD_MSEQ",
                message = "expected mseq $next, got $mseq",
                refSeq = refSeq,
                closeConnection = true,
            ),
        )
    }

    /**
     * Records one outstanding path and sends `VFS_RESYNC` at most once on the
     * current connection.
     *
     * The watermark is a strictly contiguous mseq, so a path whose held mseq
     * is at or below the watermark has been settled; [clearSettledResyncs]
     * drops it and allows a genuinely new mismatch on the same path to be
     * requested again.
     */
    private suspend fun requestResyncOnce(path: String, mseq: Long) {
        val shouldSend = synchronized(senderLock) {
            outstandingResyncs.putIfAbsent(path, mseq)
            path !in requestedResyncs
        }
        if (!shouldSend) return
        if (emit(VfsFrame.Resync(path))) {
            synchronized(senderLock) { requestedResyncs.add(path) }
        }
    }

    /** Drops paths whose held mseq the contiguous materialized watermark passed. */
    private fun clearSettledResyncs(materializedUptoMseq: Long) {
        synchronized(senderLock) {
            val iterator = outstandingResyncs.entries.iterator()
            while (iterator.hasNext()) {
                val entry = iterator.next()
                if (entry.value <= materializedUptoMseq) {
                    iterator.remove()
                    requestedResyncs.remove(entry.key)
                }
            }
        }
    }

    private suspend fun satisfyLevel1Barriers() {
        val acked = ackedWatermark
        val covered = pending.filter { it.wantLevel == 1 && it.uptoMseq <= acked }
        if (covered.isEmpty()) return
        pending.removeAll(covered)
        emit(VfsFrame.Ack(level = 1, uptoMseq = acked))
    }

    /**
     * One `VFS_REFUSED` for a mutation that would grow a file past
     * [singleFileLimitBytes] (channel.md:236, §4.8, §8).
     *
     * Nothing is appended and no watermark moves: the refused mutation consumed
     * no `mseq`, so `nextMseq`/`ackedMseq` are untouched and the Worker resends
     * the same `mseq` after shrinking to `limit - accepted_bytes`. The frame is
     * a diagnostic, so [VfsFrame.Error.closeConnection] is `false`
     * (channel.md:362) and the host does not enter `Failed` (§8).
     *
     * The three structured members §4.8 requires (`path`, `limit`, `reason`) are
     * present, as are the two a host reply adds (`mseq`, `accepted_bytes`) — the
     * latter is `append_from` of an appended mutation and 0 for a complete write.
     *
     * ---- evidence level: JVM only, no device capture -------------------------
     * There is **no device-level evidence** for this branch. On a real
     * device the Worker refuses first (`EFBIG`, channel.md:268) because the host
     * publishes its `single_file_limit` through
     * [HostBudgetTier.SINGLE_FILE_LIMIT_ENV], so a device can only reach this
     * backstop if that environment is dropped or ignored — i.e. by deliberately
     * desynchronising the two sides, which is not a supported configuration.
     * The branch's evidence is `VfsBudgetRefusalTest` on the JVM: the real
     * `HostChannel`, the real `VfsSink` and the real Rust codec, with a fake WAL.
     * Do not read the device run (2 GiB AVD: `EFBIG … limited to 16777216
     * bytes (16 MiB)`) as proof that this branch fired.
     *
     * @param body the structurally valid mutation that was refused.
     * @param acceptedBytes the logical prefix the worker already holds.
     * @param postWriteBytes `acceptedBytes + data length`, saturated on overflow.
     * @param refSeq the refused frame's inbound seq.
     * @param mseq the refused mutation's host-allocated mseq; never consumed.
     */
    private suspend fun refuseTooLarge(
        body: MutationBody,
        acceptedBytes: Long,
        postWriteBytes: Long,
        refSeq: Long,
        mseq: Long,
    ) {
        val limit = singleFileLimitBytes
        val detail = "${body.path} would grow to $postWriteBytes bytes, above the " +
            "single-file limit of $limit bytes (${limit / ControllerBudgets.MIB} MiB) for this " +
            "device tier; accepted $acceptedBytes bytes so far, so the largest legal suffix is " +
            "${(limit - acceptedBytes).coerceAtLeast(0L)} bytes"
        // §8 "records a diagnostic": the refusal is a resource event, not a
        // protocol error, and it names its own limit so a reader can tell a
        // tier mismatch from a malformed frame.
        logger.warn("VFS_REFUSED: $detail; no mseq consumed, channel stays open (channel.md §8)")
        emit(
            VfsFrame.Error(
                code = "VFS_REFUSED",
                message = detail,
                refSeq = refSeq,
                // §4.8/§8: a VFS_REFUSED is the one ERROR that must not close.
                closeConnection = false,
                path = body.path,
                limit = limit,
                reason = "file-too-large",
                mseq = mseq,
                acceptedBytes = acceptedBytes,
            ),
        )
    }

    /**
     * Turns one WAL write failure into a D14 failure when its code is
     * attributable, then always logs and lets the caller rethrow.
     *
     * The mapping is [HostFailureRules.wal]; an unattributable exception is the
     * pre-existing transport-close-only behavior and must not move the host to
     * `Failed`, because nothing says the durable store itself failed.
     */
    private fun reportFailure(operation: String, failure: Exception) {
        val reported = HostFailureRules.wal(failure)
        // The store's own message is workspace-relative for every attributable
        // code (LogException/WalException); it is what carries the held path and
        // mseq from `WorkspaceLog.closeEpoch` into logcat and the D14 reason
        // (budgets.md §1/§2 "record the condition").
        val detail = "$operation failed (${reported?.code ?: failure.javaClass.simpleName}): " +
            (failure.message ?: failure.javaClass.simpleName)
        if (reported != null) {
            failures.reportQuietly(reported.reason, detail, logger)
        }
        logger.error("$detail; closing the transport without a protocol ERROR")
    }

    private suspend fun emit(frame: VfsFrame): Boolean {
        val target = synchronized(senderLock) { sender }
        if (target == null) {
            logger.warn("no VFS connection attached; dropping ${frame.javaClass.simpleName}")
            return false
        }
        target.send(frame)
        return true
    }
}
