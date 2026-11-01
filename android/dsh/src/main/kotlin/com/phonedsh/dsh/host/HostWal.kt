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

import com.phonedsh.log.MutationBody
import com.phonedsh.log.RecoveryOutcome
import com.phonedsh.log.WalRecord
import com.phonedsh.log.WorkspaceLog
import com.phonedsh.platform.DurabilityLevel

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
     * Appends one structurally validated mutation at the next D17 mseq and
     * materializes it (`wal.md` §5, D8).
     *
     * @throws Exception when the WAL refuses the write or has failed.
     */
    suspend fun append(body: MutationBody): WalAppend

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
 * The level-2 watermark an epoch close established.
 *
 * @property durableUpto the close record's `durable_upto`: the highest mutation
 *   mseq in the epoch that closed.
 */
data class WalClose(val durableUpto: Long)

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
            )

            is RecoveryOutcome.Failed -> WalRecovery.Failed(outcome.code, outcome.detail)
        }

    override fun durabilityClaim(): DurabilityLevel = log.durabilityClaim()

    override fun appliedMseq(): Long = log.materializedUptoMseq

    override suspend fun append(body: MutationBody): WalAppend {
        val ack = log.appendMutation(body)
        return WalAppend(
            mseq = ack.mseq,
            materializedUptoMseq = ack.materializedUptoMseq,
            resyncPath = ack.resync?.path,
        )
    }

    override suspend fun closeEpoch(): WalClose = WalClose(log.closeEpoch().durableUpto)

    /** The last closed epoch's `durable_upto`, or 0 when none ever closed. */
    private fun lastDurableUpto(outcome: RecoveryOutcome.Recovered): Long =
        outcome.records
            .filterIsInstance<WalRecord.EpochClose>()
            .maxOfOrNull { close -> close.durableUpto } ?: 0L
}
