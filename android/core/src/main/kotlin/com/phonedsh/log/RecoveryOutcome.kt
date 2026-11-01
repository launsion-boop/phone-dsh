// The result of wal.md §10 recovery: what was replayed, truncated and retained.
// SPDX-License-Identifier: MIT

package com.phonedsh.log

/**
 * One D19 torn-tail truncation (`wal.md` §10 step 2).
 *
 * @property segment the truncated segment.
 * @property keepLen the file length kept, in bytes (header included).
 * @property droppedBytes the bytes removed from the tail.
 */
data class Truncation(
    val segment: WalSegmentName,
    val keepLen: Long,
    val droppedBytes: Long,
)

/**
 * One segment that `wal.md` §7.2 classifies as **stale**: present in `wal/`,
 * not listed in the manifest, and holding nothing above the
 * `materialized_upto_mseq` watermark.
 *
 * The revised §7.2 rule is "retained and re-listed", not "unlinked": the
 * unlisted segment may be the only surviving history of acknowledged writes,
 * because the manifest can lag the WAL tail. [verified] records whether the
 * materialized copy agreed with every path the segment's records could prove.
 *
 * @property name the retained segment.
 * @property verified `true` when every provable path matched the copy and no
 *   divergence was found.
 * @property unprovable paths the segment touches whose retained base mutation
 *   is missing, so no comparison is possible (reported, not a failure).
 * @property divergences paths whose materialized bytes or mode disagree with
 *   the WAL-derived state; a non-empty list that cannot be repaired is
 *   `WAL_CORRUPT`.
 */
data class StaleSegment(
    val name: WalSegmentName,
    val verified: Boolean,
    val unprovable: List<String> = emptyList(),
    val divergences: List<String> = emptyList(),
)

/**
 * One retained segment, as recovery read it.
 *
 * Recovery streams a segment's records and does not keep their bodies: a
 * contract-legal 128 MiB file is nine 15 MiB records (`channel.md` §3.1) and
 * retaining all nine would exceed the app's heap (`budgets.md` §4). The
 * metadata here is complete; the record bodies are in
 * [RecoveryOutcome.Recovered.records] only up to its retention budget.
 *
 * @property name the segment.
 * @property header the verified 40-byte header.
 * @property firstMseq the header's `first_mseq`.
 * @property lastMutationMseq the highest mutation mseq in the verified prefix,
 *   0 when the segment holds none.
 * @property recordCount every complete, CRC-verified record in the segment; a
 *   D19 torn tail is already truncated away.
 * @property hasEpochClose whether the segment holds the §4 epoch-close record.
 */
data class RecoveredSegment(
    val name: WalSegmentName,
    val header: WalSegmentHeader,
    val firstMseq: Long,
    val lastMutationMseq: Long,
    val recordCount: Int,
    val hasEpochClose: Boolean,
)

/**
 * The outcome of [WorkspaceLog.recover] (`wal.md` §10, D11, D19).
 *
 * [Failed] is the `Failed` host state: admission closes and no write is
 * accepted. [Recovered] means the retained WAL is consistent with the
 * checkpoint and the materialized copy, and [Recovered.nextMseq] is the
 * D17-allocated next mutation number.
 */
sealed interface RecoveryOutcome {
    /**
     * Recovery succeeded.
     *
     * @property manifest the checkpoint in force after recovery (rewritten when
     *   [manifestRewritten]).
     * @property manifestRewritten whether a manifest write happened during
     *   recovery.
     * @property segments every retained segment, in `<epoch,segment>` order.
     * @property records the diagnostic record list: **every** epoch-close
     *   record, plus the mutation records whose bodies recovery retained, in
     *   file order. Bodies are retained only while
     *   [WorkspaceLog.RETAINED_RECORD_BYTES] allows, because
     *   `budgets.md` §4 allows a 128 MiB single file while the app process is
     *   capped at 230 MB; retaining every body is exactly the `OutOfMemoryError`
     *   this outcome must not cause. [recordCount] is the true number of
     *   verified records and the per-segment metadata in [segments] is complete
     *   — only the diagnostic bodies are bounded. `HostWal` needs the closes,
     *   which are always present.
     * @property recordCount every complete, CRC-verified record of [segments].
     * @property truncated torn tails that were truncated.
     * @property adopted unlisted segments the plan adopted into `segments[]`
     *   (`wal.md` §7.2's adopted tail or a newer epoch close).
     * @property stale unlisted segments retained and verified, never unlinked.
     * @property droppedMissing listed segment entries dropped because the file
     *   is gone and every recorded mutation is at or below the watermark.
     * @property droppedEmpty zero-length segments excluded from recovery.
     *   Recovery unlinks each one once the checkpoint no longer lists it
     *   (`wal.md` §7.2); a zero-length file has no header and no record, so
     *   dropping it is not data loss. `WorkspaceLog` logs each one through
     *   `WalLogEvent.EmptySegmentDropped`.
     * @property effectiveTail `max(last_mseq, highest mutation mseq in the
     *   retained WAL)`; it may be below the watermark after truncation.
     * @property nextMseq `max(last_mseq, WAL tail) + 1` (D17).
     * @property nextEpoch the epoch of the next segment 0 (`wal.md` §1).
     * @property materializedUptoMseq the strictly contiguous watermark after
     *   the replay.
     * @property fullReconcile whether the staged `wal.md` §7.2 reconcile ran.
     * @property resyncRequired paths whose appended base did not match, in
     *   `mseq` order; the caller sends `VFS_RESYNC` and holds the watermark
     *   below them (`wal.md` §5.1).
     */
    data class Recovered(
        val manifest: Manifest,
        val manifestRewritten: Boolean,
        val segments: List<RecoveredSegment>,
        val records: List<WalRecord>,
        val recordCount: Int,
        val truncated: List<Truncation>,
        val adopted: List<WalSegmentName>,
        val stale: List<StaleSegment>,
        val droppedMissing: List<WalSegmentName>,
        val droppedEmpty: List<WalSegmentName> = emptyList(),
        val effectiveTail: Long,
        val nextMseq: Long,
        val nextEpoch: Int,
        val materializedUptoMseq: Long,
        val fullReconcile: Boolean,
        val resyncRequired: List<String>,
    ) : RecoveryOutcome {
        /** The retained segment names, in `<epoch,segment>` order. */
        val segmentNames: List<WalSegmentName>
            get() = segments.map { it.name }
    }

    /**
     * Recovery failed loud: `WAL_CORRUPT` (D19/§7.2) or a schema-invalid
     * checkpoint that cannot be rebuilt.
     *
     * @property code the wire code, always `WAL_CORRUPT` for a D19/D11 failure.
     * @property detail the workspace-relative reason.
     */
    data class Failed(val code: String, val detail: String) : RecoveryOutcome
}
