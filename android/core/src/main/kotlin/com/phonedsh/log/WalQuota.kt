// wal.md §9: the WAL quota, the droppable-segment rule and §7.2-order compaction.
// SPDX-License-Identifier: MIT

package com.phonedsh.log

import com.phonedsh.wire.WalException
import java.io.IOException
import java.nio.file.Files
import java.nio.file.LinkOption
import java.nio.file.Path

/**
 * The `wal.md` §9 decision for one segment: *is this segment droppable?*
 *
 * The rule is deliberately a pure function over evidence that [WalQuota] has
 * already established, so the three conditions can be proved one at a time
 * without a filesystem. It is the only place allowed to answer "may this
 * segment be unlinked to free space"; Tono's data-safety red line is that a
 * false negative (retain, fail loud) is acceptable and a false positive is not.
 */
internal object DroppableRule {
    /**
     * §9's conditions 1–2 plus both "never droppable" cases.
     *
     * Every argument is **evidence**, never a preference:
     *
     * @param name the candidate segment.
     * @param openSegment the segment of the open epoch, or `null` between a
     *   close and the next append.
     * @param newestEpochCloseSegment the retained segment that holds the newest
     *   epoch-close record; D19 step 4 derives `durable_mseq` from it.
     * @param listedLastMseq the highest mutation mseq recorded for the segment
     *   (`manifest.json` `segments[].last_mseq`, raised to the live summary
     *   when the file holds more), or `null` when the manifest does not list
     *   it.
     * @param durableEpoch `last_durable_epoch`: the manifest marker written only
     *   by D18 step 5, so every epoch at or below it closed in the D18 order
     *   and was listed.
     * @param watermark `materialized_upto_mseq`, the strictly contiguous
     *   watermark of `wal.md` §7.
     * @return `true` only when every condition holds; anything unproven is
     *   `false`.
     */
    fun isDroppable(
        name: WalSegmentName,
        openSegment: WalSegmentName?,
        newestEpochCloseSegment: WalSegmentName?,
        listedLastMseq: Long?,
        durableEpoch: Int,
        watermark: Long,
    ): Boolean = when {
        // "Never droppable": the open epoch (§9), even when every mutation it
        // holds is already materialized.
        name == openSegment -> false
        // "Never droppable": the newest epoch-close segment (§9).
        name == newestEpochCloseSegment -> false
        // Condition 2: its epoch is durable. The manifest's segments[] list is
        // the only proof that the close in D18 step 5 ran and listed it, so an
        // unlisted segment is never droppable no matter how small it is.
        listedLastMseq == null -> false
        // Condition 2 continued: closed in the D18 order — `last_durable_epoch`
        // is written at step 5, after steps 3 and 4 F_FULLFSYNCed the epoch.
        name.epoch > durableEpoch -> false
        // Condition 1: every mutation at or below the watermark.
        listedLastMseq > watermark -> false
        else -> true
    }

    /**
     * The record-level half of §9 condition 1: read the candidate's own records
     * and require every **mutation** at or below [watermark].
     *
     * An epoch-close record is not a mutation (`wal.md` §4): it never advances
     * the watermark and, in the idle-epoch case of
     * `golden/wal/segment-epoch-only.json`, its mseq is even below the
     * segment's `first_mseq`. It therefore never blocks the decision.
     *
     * The proof reads record **metadata**, not bodies: a candidate can be a
     * 15 MiB mutation, and the §9 decision only needs its mseq and path
     * ([WorkspaceLog.readSegmentRecordRefs]).
     *
     * @param records the complete, CRC-verified records of the candidate.
     * @param watermark `materialized_upto_mseq`.
     */
    fun everyMutationAtOrBelow(
        records: List<WorkspaceLog.SegmentRecordRef>,
        watermark: Long,
    ): Boolean = records.all { record -> !record.isMutation || record.mseq <= watermark }
}

/**
 * The result of [WalQuota.enforce] (`wal.md` §9).
 *
 * [bytes] is the WAL's size after the call — the sum of the segment files
 * including their 40-byte headers — and [limit] the quota it was measured
 * against. A caller that sees [Exceeded] must close admission and report the
 * `Failed` state; it must never treat the log as usable "for a few more
 * records".
 */
sealed interface QuotaOutcome {
    /** The WAL size at the end of the call, in bytes. */
    val bytes: Long

    /** The quota the WAL was measured against, in bytes. */
    val limit: Long

    /** The segments this call unlinked, in `<epoch,segment>` order. */
    val dropped: List<WalSegmentName>

    /**
     * The WAL was at or below the limit; nothing was dropped.
     *
     * @property bytes the measured size.
     * @property limit the quota.
     */
    data class WithinLimit(
        override val bytes: Long,
        override val limit: Long,
    ) : QuotaOutcome {
        override val dropped: List<WalSegmentName>
            get() = emptyList()
    }

    /**
     * Compaction ran and the WAL is now within the limit.
     *
     * @property bytesBefore the size before compaction.
     * @property bytes the size after the unlinks.
     * @property limit the quota.
     * @property dropped the unlinked segments.
     */
    data class Compacted(
        val bytesBefore: Long,
        override val bytes: Long,
        override val limit: Long,
        override val dropped: List<WalSegmentName>,
    ) : QuotaOutcome

    /**
     * The WAL is still above the limit after compaction; `wal.md` §9 requires
     * the host to fail loud.
     *
     * @property bytes the size after the attempt, in bytes.
     * @property limit the quota.
     * @property dropped the segments that were still provably droppable and
     *   were unlinked; it is empty when no segment qualified.
     */
    data class Exceeded(
        override val bytes: Long,
        override val limit: Long,
        override val dropped: List<WalSegmentName> = emptyList(),
    ) : QuotaOutcome
}

/**
 * `wal.md` §9 for one workspace: measure the WAL, compact provably droppable
 * data, and fail loud when that is not enough.
 *
 * ### The limit
 *
 * 512 MiB, "the sum of the segment files including headers". [limitBytes] is
 * the whole accounting: `manifest.json`, the materialized copy and the other
 * workspace files are not WAL segments and are not charged here.
 *
 * ### A segment is droppable only when all of this holds (§9)
 *
 * 1. every mutation in it has `mseq <= materialized_upto_mseq`;
 * 2. its epoch is durable — closed in the D18 order, `F_FULLFSYNC`ed and
 *    listed in `manifest.json` (`last_durable_epoch` and `segments[]` are the
 *    only evidence);
 * 3. it is neither the newest epoch-close segment nor the open epoch.
 *
 * [DroppableRule] encodes the decision; every candidate is then **read back**
 * and its own records are checked again before anything is unlinked, because
 * the manifest may only ever be weaker than the file.
 *
 * ### Compaction order
 *
 * Only after the D18 close order of the candidate's epoch has completed, and
 * then exactly:
 *
 * 1. `fsync` the materialized files and directories the dropped segments
 *    produced, deepest first (§5.2 step 1's order);
 * 2. atomically replace `manifest.json` without the dropped segments and fsync
 *    its directory — "delete a segment only after a durable manifest that no
 *    longer lists it" (§7.2, §7.1);
 * 3. unlink the whole segment files — a segment is never partially truncated
 *    except by the §10 torn-tail rule;
 * 4. `fsync` `wal/`, publishing the unlinks.
 *
 * A crash between 2 and 3 leaves listed-and-missing files whose every mutation
 * is at or below the watermark: §7.2 drops them silently. A crash inside 3
 * leaves unlisted files at or below the watermark: §7.2 classifies them
 * **stale**, retains and re-lists them. Neither path loses a record.
 *
 * @param log the log whose segments this quota measures and compacts.
 * @param limitBytes the §9 limit in bytes; a test may lower it.
 */
class WalQuota internal constructor(
    private val log: WorkspaceLog,
    val limitBytes: Long = DEFAULT_LIMIT_BYTES,
) {
    /**
     * The WAL's current size: every segment file, its 40-byte header included.
     *
     * The measurement lists the directory instead of trusting
     * `manifest.json`: §7.2's placement rule already establishes that a
     * present-but-unlisted segment is real history, so it must be charged
     * against the quota too.
     */
    fun usedBytes(): Long = segmentFiles().sumOf { it.size }

    /**
     * Enforces §9 against [limitBytes].
     *
     * Compaction runs only when the WAL is over the limit, and only on
     * segments that [DroppableRule] and their own records prove droppable. The
     * call takes the log's single-writer mutex, so it never interleaves with an
     * append or a close.
     *
     * A candidate whose bytes cannot be parsed is **retained** (never
     * unlinked), and the call then reports [QuotaOutcome.Exceeded] if the WAL
     * stays over the limit.
     *
     * @return [QuotaOutcome.WithinLimit], [QuotaOutcome.Compacted] or
     *   [QuotaOutcome.Exceeded]. An `Exceeded` is the caller's signal to close
     *   admission and report `Failed`; this class never does that on a
     *   caller's behalf.
     * @throws LogException `WAL_DIRECTORY_IO` when the WAL cannot be
     *   measured, `WAL_SEGMENT_IO` when the shorter manifest or an unlink
     *   fails. The checkpoint may already have been replaced in the unlink
     *   case, so the caller must treat every such failure like `Exceeded`:
     *   admission closes and the log accepts no further write. Nothing is
     *   lost — a later boot retains and re-lists whatever is still present
     *   (§7.2).
     */
    suspend fun enforce(): QuotaOutcome = log.locked {
        log.ensureReady()
        enforceWithReserve(0L)
    }

    /**
     * [enforce] with [reserveBytes] of headroom kept for a write that is about
     * to be appended.
     *
     * The write path must not let an append cross the limit, and compaction
     * must not run when the WAL is merely about to cross it, so the two calls
     * are one: compact until `size + reserve <= limit`. The outcome still
     * judges only the limit itself, not the reserve; the caller checks its own
     * frame against [QuotaOutcome.bytes].
     *
     * The caller must already hold the log's mutex ([WorkspaceLog.appendMutation]).
     */
    internal suspend fun enforceWithReserve(reserveBytes: Long): QuotaOutcome {
        val files = segmentFiles()
        val before = files.sumOf { it.size }
        val target = (limitBytes - reserveBytes).coerceAtLeast(0L)
        if (before <= target) {
            return QuotaOutcome.WithinLimit(before, limitBytes)
        }

        val manifest = log.manifestOnDisk()
        val listed = manifest?.segments?.associateBy { it.name } ?: emptyMap()
        val durableEpoch = maxOf(log.lastDurableEpoch, manifest?.lastDurableEpoch ?: 0)
        val watermark = log.materializedUptoMseq
        val open = log.openSegmentName()
        val newestClose = log.newestEpochCloseSegment()

        val chosen = ArrayList<WalSegmentName>()
        val changes = EpochChanges(log.paths)
        var freed = 0L
        for (file in files) {
            if (before - freed <= target) break
            val entry = listed[file.name] ?: continue
            val recorded = maxOf(entry.lastMseq, log.segmentLastMutationMseq(file.name))
            val droppable = DroppableRule.isDroppable(
                name = file.name,
                openSegment = open,
                newestEpochCloseSegment = newestClose,
                listedLastMseq = recorded,
                durableEpoch = durableEpoch,
                watermark = watermark,
            )
            if (!droppable) continue
            // Read the candidate back: the manifest is evidence, the bytes are
            // proof. A segment that cannot be read is never unlinked.
            val segment = try {
                log.readSegmentRecordRefs(file.name)
            } catch (_: WalException) {
                continue
            }
            if (!DroppableRule.everyMutationAtOrBelow(segment, watermark)) continue
            for (record in segment) {
                if (record.isMutation) {
                    record.path?.let { touchMaterialized(changes, it) }
                }
            }
            chosen += file.name
            freed += file.size
        }
        if (chosen.isEmpty()) {
            // Nothing is provably droppable: retain everything. The outcome
            // still reports §9's fact — over the limit or not — so the write
            // path, which passed a reserve, can tell "no headroom" from
            // "quota violated" itself.
            return if (before <= limitBytes) {
                QuotaOutcome.WithinLimit(before, limitBytes)
            } else {
                QuotaOutcome.Exceeded(before, limitBytes)
            }
        }

        // 1. §9: fsync what the dropped segments produced, deepest first.
        log.fsyncChanges(changes)
        // 2. §7.2: the shorter manifest must be durable before deletion.
        log.writeManifestAtomically(log.manifestExcluding(chosen.toSet()))
        // 3. Unlink whole segment files.
        val removed = ArrayList<WalSegmentName>()
        for (name in chosen) {
            val path = log.paths.segment(name)
            try {
                Files.deleteIfExists(path)
            } catch (error: IOException) {
                log.forgetSegments(removed)
                throw LogException(
                    LogFailure.SEGMENT_IO,
                    "cannot unlink ${log.paths.label(path)}: ${error.message}",
                    error,
                )
            }
            removed += name
        }
        log.forgetSegments(removed)
        // 4. Publish the unlinks.
        log.durability.fsyncPath(log.paths.walDirectory)

        val after = segmentFiles().sumOf { it.size }
        return if (after <= limitBytes) {
            QuotaOutcome.Compacted(before, after, limitBytes, chosen)
        } else {
            QuotaOutcome.Exceeded(after, limitBytes, chosen)
        }
    }

    /**
     * Records the materialized location of [body] for the pre-unlink fsync.
     *
     * §9 says "the materialized files and directories produced by the segments
     * to be dropped". The final state decides which is which: a live file is
     * fsynced with its parent, a live directory on its own, and a path a later
     * `remove` collapsed is proven durable by fsyncing its parent — the same
     * rule D18 step 1 uses for a removal.
     */
    private fun touchMaterialized(changes: EpochChanges, path: String) {
        val target = log.paths.materialized(path)
        when {
            Files.isDirectory(target, LinkOption.NOFOLLOW_LINKS) -> changes.touchDirectory(target)
            Files.isRegularFile(target, LinkOption.NOFOLLOW_LINKS) -> changes.touchFile(target)
            else -> target.parent?.let { changes.touchDirectory(it) }
        }
    }

    private class SegmentFile(val name: WalSegmentName, val path: Path, val size: Long)

    /** Every `wal/<epoch>.<segment>.xlwal` present, in `<epoch,segment>` order, with its size. */
    private fun segmentFiles(): List<SegmentFile> {
        val directory = log.paths.walDirectory
        val files = ArrayList<SegmentFile>()
        try {
            Files.newDirectoryStream(directory).use { stream ->
                for (entry in stream) {
                    if (!Files.isRegularFile(entry, LinkOption.NOFOLLOW_LINKS)) continue
                    val name = WalSegmentName.parse(entry.fileName.toString()) ?: continue
                    files += SegmentFile(name, entry, Files.size(entry))
                }
            }
        } catch (error: IOException) {
            throw LogException(
                LogFailure.WAL_DIRECTORY_IO,
                "cannot measure ${log.paths.label(directory)}: ${error.message}",
                error,
            )
        }
        files.sortWith(compareBy { it.name })
        return files
    }

    companion object {
        /** `wal.md` §9: 512 MiB, the sum of the segment files including headers. */
        const val DEFAULT_LIMIT_BYTES: Long = 512L * 1024L * 1024L
    }
}
