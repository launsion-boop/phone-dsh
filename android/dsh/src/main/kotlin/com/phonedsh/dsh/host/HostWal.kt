// phone-dsh — :dsh / com.phonedsh.dsh.host: the WAL seam the facade consumes.
// SPDX-License-Identifier: MIT
//
// ---- why an interface, not WorkspaceLog directly ----------------------------
// The facade needs a small, testable part of `:core`'s log: cold recovery, the
// durability claim, the append, and the epoch close. A test that had to
// construct a real `WorkspaceLog` for every facade assertion would fsync real
// directories to prove controller wiring that has nothing to do with the WAL,
// and it could not make recovery fail on demand.
//
// [HostWal] is that seam. Production passes [asHostWal], which wraps the real
// `WorkspaceLog` and projects its `RecoveryOutcome` into [WalRecovery]; tests
// implement the interface. The projection is the only place that knows how the
// WAL's numbers map onto the HELLO's three members.
//
// ---- what it deliberately does not abstract --------------------------------
// It does not hide recovery failure or turn it into an empty log: [recover]
// either reports [WalRecovery.Recovered] with the numbers the log itself
// reports, or [WalRecovery.Failed]/an exception. The facade decides that `wal/1`
// stays off; this seam never invents a success.

package com.phonedsh.dsh.host

import com.phonedsh.log.MseqAllocator
import com.phonedsh.log.MutationBody
import com.phonedsh.log.RecoveryOutcome
import com.phonedsh.log.WalRecord
import com.phonedsh.log.WorkerLaneAppend
import com.phonedsh.log.WorkspaceLog
import com.phonedsh.platform.DurabilityLevel
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.emptyFlow

/**
 * The WAL operations a host HELLO and the VFS sink need.
 *
 * Implementations are a thin adapter over the real log or a test double. The
 * facade calls [recover] once from `start()`; it never reads a number that was
 * not returned by that call. [append] and [closeEpoch] are the write path the
 * VFS sink uses after recovery.
 */
interface HostWal {
    /**
     * Runs cold recovery (idempotent) and returns the numbers in force.
     *
     * A failure is reported as [WalRecovery.Failed] or by throwing; the facade
     * treats both the same way: `wal/1` stays off and the HELLO keeps the
     * not-wired watermark.
     *
     * @throws Exception when recovery cannot run at all (missing kernel,
     *   unreadable directory, host defect).
     */
    suspend fun recover(): WalRecovery

    /**
     * Discards the cached recovery result and a sticky host failure so a later
     * [recover] really re-runs (`budgets.md` §2 `Failed -> Recovering`).
     *
     * Only the explicit user reset calls this. A test double that never caches
     * recovery may leave it empty; production's adapter forwards to
     * `WorkspaceLog.resetForRecovery()`.
     */
    suspend fun resetForRecovery() = Unit

    /**
     * The outstanding §5.1 repair request, or `null`.
     *
     * The facade's periodic epoch-close guard reads this before closing:
     * `wal.md` §5.2 makes an unrepaired mismatch at a close a `Failed`
     * condition, so the periodic lane defers the close and records the path
     * and mseq while a repair is still outstanding.
     */
    fun pendingResync(): WalResync? = null

    /**
     * The durability this WAL can actually honour.
     *
     * A passthrough of the platform SPI: never promoted here. On the
     * bench-absent device this is
     * [DurabilityLevel.LEVEL_2_POWER_LOSS_UNVERIFIED], which must be treated
     * exactly like level 1.
     */
    fun durabilityClaim(): DurabilityLevel

    /**
     * The highest contiguous mseq applied to the materialized copy
     * (`WorkspaceLog.materializedUptoMseq`), or 0 when no log is attached.
     *
     * This is the value `exec.md` §2.1 calls the applied watermark; it is
     * weaker than [WalAppend.mseq] only in that it may lag a held resync, which
     * is exactly why `requires_mseq` must use it.
     */
    fun appliedMseq(): Long

    /**
     * The **live** mseq allocator (`wal.md` §7.2, D17): `next_mseq` is
     * `max(last_mseq, WAL tail) + 1` and `lastMseq` is the effective tail.
     *
     * Never cached: the HELLO's `next_mseq`/`acked_mseq` and the VFS sink's
     * expected mseq are read from here at the moment they are needed. A boot-time
     * snapshot of the same numbers is the L77 defect — an App-side workspace
     * write advances the allocator, the Worker's HELLO and the sink both keep the
     * old value, and the next `VFS_MUT` is answered `WAL allocated mseq N+1 for
     * the worker's N`.
     */
    fun allocator(): MseqAllocator

    /**
     * The App-lane workspace writes of this log (an attachment import through
     * `WorkspaceLog.appendMutation`), as the mseq each one consumed.
     *
     * The host listens so it can re-establish the invariant `wal.md` line 3
     * states — the Worker's in-memory VFS is the single authority while it runs —
     * by restarting the Worker instead of letting its next mutation collide with
     * a number the App took. Empty for a fake or a log with no App lane.
     */
    val hostLaneAppends: Flow<Long> get() = emptyFlow()

    /**
     * Appends one structurally validated mutation **at the Worker's mseq** and
     * materializes it (`wal.md` §5, D8).
     *
     * The decision is taken against the live allocator under the log's own lock,
     * so it cannot race the App lane: the answer is either "this was the next
     * mseq and here is its record", "this mseq is already behind the tail" or
     * "this mseq is ahead of the allocator". Nothing is appended for the last
     * two, which is what keeps a stale frame from spending a new mseq.
     *
     * @throws Exception when the WAL refuses the write or has failed.
     */
    suspend fun appendWorker(body: MutationBody, mseq: Long): WalWorkerAppend

    /**
     * Closes the current epoch in the D18 order.
     *
     * This is the only operation that may produce a `level = 2` ACK.
     *
     * @throws Exception when an fsync/manifest step fails or the log has failed.
     */
    suspend fun closeEpoch(): WalClose
}

/**
 * The WAL's answer to one append.
 *
 * @property mseq the allocated mutation number; the VFS sink accepts it only
 *   when it equals the worker's expected mseq.
 * @property materializedUptoMseq the materialized watermark after the append
 *   (`wal.md` §7); lower than [mseq] when a base mismatch is held.
 * @property resyncPath the path that needs a `VFS_RESYNC` (D8/§3.4), or `null`.
 */
data class WalAppend(
    val mseq: Long,
    val materializedUptoMseq: Long,
    val resyncPath: String? = null,
)

/**
 * The VFS sink's answer to one `VFS_MUT`, decided against the live allocator.
 *
 * This is the dsh projection of `:core`'s `WorkerLaneAppend`; it exists so the
 * sink never names `:core`'s log types directly.
 */
sealed interface WalWorkerAppend {
    /** The mseq was the live next one and the record is in the WAL. */
    data class Appended(val append: WalAppend) : WalWorkerAppend

    /** The mseq is at or below the WAL tail: nothing was appended. */
    data class Behind(val lastMseq: Long) : WalWorkerAppend

    /** The mseq is ahead of the live allocator: nothing was appended. */
    data class Ahead(val nextMseq: Long) : WalWorkerAppend
}

/**
 * The level-2 watermark an epoch close established.
 *
 * @property durableUpto the close record's `durable_upto`: the highest mutation
 *   mseq in the epoch that closed.
 */
data class WalClose(val durableUpto: Long)

/**
 * One outstanding §5.1 repair: the path and the mseq whose base did not match.
 *
 * This is a seam-local value, not a wire field: `VFS_RESYNC` carries only the
 * path (`channel.md` §3.4). The mseq is what the host uses for its diagnostics
 * and for deciding when the path's repair has advanced the watermark.
 */
data class WalResync(
    val path: String,
    val mseq: Long,
)

/**
 * The numbers recovery left in force, or the reason it did not.
 *
 * This is a snapshot, not a live view: the facade builds the HELLO once from it
 * and the VFS sink seeds its watermarks from it.
 */
sealed interface WalRecovery {
    /**
     * Recovery succeeded and the log accepts writes.
     *
     * @property nextMseq the D17 next mutation number, `max(last_mseq, WAL
     *   tail) + 1`; at least 1 for a real log.
     * @property ackedMseq the effective tail: the highest mutation mseq the log
     *   has admitted at level 1.
     * @property durableMseq the `durable_upto` of the last closed epoch, 0 when
     *   no epoch has closed.
     */
    data class Recovered(
        val nextMseq: Long,
        val ackedMseq: Long,
        val durableMseq: Long,
        /**
         * Paths whose startup replay left a base mismatch. The sink re-sends
         * one `VFS_RESYNC` per path after the host HELLO (`wal.md` §10 step 4,
         * `channel.md` §9 item 6); duplicates are limited to one per connection
         * by [VfsSink].
         */
        val resync: List<WalResync> = emptyList(),
        /** Whether recovery ran the full-tree `wal.md` §7.2 rebuild. */
        val fullReconcile: Boolean = false,
    ) : WalRecovery

    /**
     * Recovery refused the workspace: no write is accepted this boot.
     *
     * @property code the wire code (`WAL_CORRUPT`, `WAL_MANIFEST_INVALID`, …).
     * @property detail a workspace-relative reason, never sent on the wire.
     */
    data class Failed(
        val code: String,
        val detail: String,
    ) : WalRecovery
}

/**
 * Wraps the real `:core` log as the facade's WAL seam.
 *
 * The three numbers come from the same `RecoveryOutcome`:
 * `next_mseq` is its `nextMseq` (D17), `acked_mseq` is its `effectiveTail`, and
 * `durable_mseq` is the highest `durable_upto` among the retained epoch-close
 * records.
 *
 * `WorkspaceLog` exposes `nextMseq`, `lastMseq` and `lastDurableEpoch`, but not
 * the last close's `durable_upto`; that number is on the close record and in
 * [RecoveryOutcome.Recovered.records], so this adapter derives it instead of
 * approximating it with [WorkspaceLog.materializedUptoMseq] (which may be ahead
 * of the last close and is a level-1 fact, not a level-2 one).
 */
fun WorkspaceLog.asHostWal(): HostWal = WorkspaceLogHostWal(this)

private class WorkspaceLogHostWal(
    private val log: WorkspaceLog,
) : HostWal {
    override suspend fun recover(): WalRecovery =
        when (val outcome = log.recover()) {
            is RecoveryOutcome.Recovered -> WalRecovery.Recovered(
                nextMseq = outcome.nextMseq,
                ackedMseq = outcome.effectiveTail,
                durableMseq = lastDurableUpto(outcome),
                resync = if (outcome.resyncRequests.isNotEmpty()) {
                    outcome.resyncRequests.map { WalResync(it.path, it.mseq) }
                } else {
                    outcome.resyncRequired.map { WalResync(it, outcome.materializedUptoMseq + 1) }
                },
                fullReconcile = outcome.fullReconcile,
            )

            is RecoveryOutcome.Failed -> WalRecovery.Failed(outcome.code, outcome.detail)
        }

    override suspend fun resetForRecovery() = log.resetForRecovery()

    override fun pendingResync(): WalResync? = log.outstandingResync()?.let { request ->
        WalResync(request.path, request.mseq)
    }

    override fun durabilityClaim(): DurabilityLevel = log.durabilityClaim()

    override fun appliedMseq(): Long = log.materializedUptoMseq

    override fun allocator(): MseqAllocator = log.allocator()

    override val hostLaneAppends: Flow<Long> get() = log.hostLaneAppends

    override suspend fun appendWorker(body: MutationBody, mseq: Long): WalWorkerAppend =
        when (val outcome = log.appendWorkerMutation(body, mseq)) {
            is WorkerLaneAppend.Appended -> WalWorkerAppend.Appended(
                WalAppend(
                    mseq = outcome.ack.mseq,
                    materializedUptoMseq = outcome.ack.materializedUptoMseq,
                    resyncPath = outcome.ack.resync?.path,
                ),
            )

            is WorkerLaneAppend.Behind -> WalWorkerAppend.Behind(outcome.lastMseq)

            is WorkerLaneAppend.Ahead -> WalWorkerAppend.Ahead(outcome.nextMseq)
        }

    override suspend fun closeEpoch(): WalClose = WalClose(log.closeEpoch().durableUpto)

    /** The last closed epoch's `durable_upto`, or 0 when none ever closed. */
    private fun lastDurableUpto(outcome: RecoveryOutcome.Recovered): Long =
        outcome.records
            .filterIsInstance<WalRecord.EpochClose>()
            .maxOfOrNull { close -> close.durableUpto } ?: 0L
}
