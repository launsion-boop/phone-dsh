// The host WAL: append, epoch close in the D18 order, recovery and the manifest.
// SPDX-License-Identifier: MIT

package com.phonedsh.log

import com.phonedsh.platform.Clock
import com.phonedsh.platform.Durability
import com.phonedsh.platform.DurabilityLevel
import com.phonedsh.wire.WalException
import java.io.IOException
import java.nio.ByteBuffer
import java.nio.channels.FileChannel
import java.nio.file.FileVisitResult
import java.nio.file.Files
import java.nio.file.LinkOption
import java.nio.file.Path
import java.nio.file.SimpleFileVisitor
import java.nio.file.StandardCopyOption
import java.nio.file.StandardOpenOption
import java.nio.file.attribute.BasicFileAttributes
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

/**
 * The two acknowledgement levels of `channel.md` §3.2 / `wal.md` §5.
 *
 * [LEVEL_1] promises survival of **process death**: `write()` returned, so the
 * bytes are in the kernel page cache. It does **not** promise survival of power
 * loss. [LEVEL_2] is emitted only by [WorkspaceLog.closeEpoch] after the D18
 * order has made the materialized copy, every segment of the epoch and the
 * manifest durable.
 *
 * @property wireLevel the channel's numeric level.
 */
enum class AckLevel(val wireLevel: Int) {
    /** `write()` returned (group commit, `wal.md` §5 step 3). */
    LEVEL_1(1),

    /** The epoch closed in the D18 order (`wal.md` §5.2). */
    LEVEL_2(2),
}

/**
 * A `VFS_RESYNC` request of `wal.md` §5.1.
 *
 * @property path the VFS path whose appended base did not match.
 * @property mseq the record's mseq; the watermark stays below it until the
 *   worker's complete write is applied.
 */
data class ResyncRequest(val path: String, val mseq: Long)

/**
 * The cumulative level-1 acknowledgement for one accepted mutation.
 *
 * @property mseq the allocated mutation number.
 * @property level always [AckLevel.LEVEL_1]; level 2 belongs to the epoch close.
 * @property materializedUptoMseq the strictly contiguous watermark after this
 *   mutation was materialized, or below [mseq] when it was held for a resync.
 * @property resync the outstanding §5.1 repair request, or `null`.
 */
data class AppendAck(
    val mseq: Long,
    val level: AckLevel,
    val materializedUptoMseq: Long,
    val resync: ResyncRequest? = null,
)

/**
 * The result of a D18 epoch close.
 *
 * [level] is [AckLevel.LEVEL_2] only when the whole order completed: the
 * materialized copy fsynced, the epoch-close record appended, every segment of
 * the epoch fsynced, the `wal/` directory fsynced and the manifest atomically
 * replaced and its directory fsynced.
 *
 * @property epoch the epoch that closed.
 * @property durableUpto the close record's `durable_upto` (the global highest
 *   mutation mseq at the close).
 * @property level always [AckLevel.LEVEL_2].
 * @property manifest the checkpoint written by the close.
 * @property segments the segments the manifest lists.
 */
data class EpochCloseResult(
    val epoch: Int,
    val durableUpto: Long,
    val level: AckLevel,
    val manifest: Manifest,
    val segments: List<WalSegmentName>,
)

/** One diagnostic event of the log; recovery's truncation log uses it. */
sealed interface WalLogEvent {
    /**
     * A D19 torn tail was truncated (`wal.md` §10 step 2): boot id, segment,
     * byte offset and dropped bytes.
     *
     * @property bootId the current boot.
     * @property segment the truncated segment.
     * @property keepLen the new file length (header included).
     * @property droppedBytes the bytes removed.
     * @property previousLength the file length before the truncation.
     */
    data class TruncatedTail(
        val bootId: BootId,
        val segment: WalSegmentName,
        val keepLen: Long,
        val droppedBytes: Long,
        val previousLength: Long,
    ) : WalLogEvent

    /** A §5.1 resync request raised during replay. */
    data class ResyncRequired(val path: String, val mseq: Long) : WalLogEvent

    /**
     * A zero-length segment was excluded from recovery (`wal.md` §7.2).
     *
     * A zero-length file has no header and no record: it is a crash artifact,
     * not damaged WAL content, so recovery drops it instead of failing with
     * `WAL_CORRUPT`. The event is the required non-silent diagnostic.
     *
     * @property segment the dropped segment.
     * @property removed whether the file was unlinked; `false` means the
     *   exclusion succeeded but the cleanup could not, and the next boot will
     *   classify the still-present file the same way.
     */
    data class EmptySegmentDropped(
        val segment: WalSegmentName,
        val removed: Boolean,
    ) : WalLogEvent

    /**
     * [recover] refused the workspace and admission stays closed.
     *
     * `budgets.md` §1/§2 make `Failed` a state the user must act on, and a
     * refusal whose reason exists only in a stack trace is not fail-loud. The
     * sink receives the same code and workspace-relative detail as
     * [RecoveryOutcome.Failed], so a host can put the reason in front of the
     * user instead of only the code. The detail never contains payload bytes.
     *
     * @property code the wire code (`WAL_CORRUPT`, `WAL_RECORD_TOO_LARGE`, …).
     * @property detail the workspace-relative reason.
     */
    data class RecoveryFailed(val code: String, val detail: String) : WalLogEvent
}

/**
 * The log's diagnostic sink.
 *
 * `wal.md` §10 requires a torn-tail truncation to be **logged** with boot id,
 * segment, byte offset and dropped bytes; this is that sink. The default
 * [NONE] is intentional: a caller that wants the record supplies a sink, and a
 * library never writes to stdout.
 */
fun interface WalLogSink {
    /** Receives one event. */
    fun onEvent(event: WalLogEvent)

    companion object {
        /** A sink that drops every event. */
        val NONE: WalLogSink = WalLogSink { }
    }
}

/**
 * The host WAL of one workspace: the write path, the epoch close, the
 * checkpoint and cold recovery (`spec/v1/wal.md`, D7–D19).
 *
 * ### Ownership
 *
 * The in-memory VFS is the single authority while it runs; this class owns the
 * recovery log of every committed mutation, the materialized copy derived from
 * it and the `manifest.json` checkpoint. The Rust kernel
 * ([com.phonedsh.wire.NativeWal]) decides **format and plan** and performs no
 * I/O; every read, write, truncate, fsync, rename and unlink happens here.
 *
 * ### Sequence
 *
 * 1. [recover] — scans `wal/`, asks the kernel for the D11 plan, executes it and
 *    returns a [RecoveryOutcome]. No write is accepted before it succeeds.
 * 2. [appendMutation] — allocates the D17 mseq, frames `len | crc32c | mseq |
 *    body`, appends, then materializes (`wal.md` §5: WAL first, copy second).
 *    Before a write that would cross [walLimitBytes] it compacts through
 *    [quota]; a record that still does not fit fails loud (D17's mseq is not
 *    spent).
 * 3. [closeEpoch] — the D18 order, then level 2.
 *
 * Calls are serialized by one [Mutex], [WalQuota.enforce] included: the host is
 * single-writer, but a coroutine cannot be assumed to be.
 *
 * ### Durability claim
 *
 * [durabilityClaim] is a **passthrough** of the injected
 * [Durability.level]. This class never promotes a level: on the bench-absent
 * device the platform reports `LEVEL_2_POWER_LOSS_UNVERIFIED`, and a caller
 * must treat that exactly like level 1 (`supportsLevel2Claim()` is the only
 * place allowed to turn it into a product claim). See [durabilityClaim].
 *
 * @param paths the workspace layout.
 * @param durability the platform fsync/atomic-replace SPI.
 * @param clock the only time source; the epoch-close `wall_ms` comes from it.
 * @param bootId this process boot's identity. Every process start is a cold
 *   recovery (`wal.md` §10 step 4).
 * @param segmentRollBytes the §1 roll limit, 8 MiB. A test may lower it to
 *   exercise the roll without writing 8 MiB.
 * @param sink the truncation/diagnostic sink.
 * @param walLimitBytes the §9 WAL quota, 512 MiB. A test may lower it to reach
 *   compaction without writing 512 MiB.
 */
class WorkspaceLog(
    val paths: WalPaths,
    internal val durability: Durability,
    private val clock: Clock,
    val bootId: BootId = BootId.random(),
    private val segmentRollBytes: Int = DEFAULT_SEGMENT_ROLL_BYTES,
    private val sink: WalLogSink = WalLogSink.NONE,
    val walLimitBytes: Long = WalQuota.DEFAULT_LIMIT_BYTES,
) {
    private val mutex = Mutex()

    private var outcome: RecoveryOutcome? = null
    private var ready: Boolean = false
    private var fatal: LogException? = null

    /** The next mutation number, `max(last_mseq, WAL tail) + 1` (D17). */
    var nextMseq: Long = 0L
        private set

    /** The highest mseq ever allocated; truncation never lowers it (D17). */
    var lastMseq: Long = 0L
        private set

    /** The strictly contiguous materialized watermark (`wal.md` §7). */
    var materializedUptoMseq: Long = 0L
        private set

    /** The epoch of the most recently closed (level-2) epoch. */
    var lastDurableEpoch: Int = 0
        private set

    /** The outcome of [recover], or `null` before it ran. */
    val recovery: RecoveryOutcome?
        get() = outcome

    private var epoch: Int = 1
    private var currentSegment: SegmentState? = null
    private val summaries = LinkedHashMap<WalSegmentName, SegmentSummary>()
    private val segmentsWritten = LinkedHashSet<Path>()
    private val changes = EpochChanges(paths)
    private val materializer = Materializer(paths, paths.materializedDirectory, changes)
    private var resync: ResyncRequest? = null
    private val pending = ArrayList<WalRecord.Mutation>()

    /**
     * The durability this log can actually honour: exactly
     * [Durability.level].
     *
     * This method deliberately does not inspect [closeEpoch]'s success or the
     * platform's mechanism. `LEVEL_2_POWER_LOSS_MEASURED` is a **product
     * claim** that only a device-class power-loss bench may establish; before
     * that bench the SPI reports `LEVEL_2_POWER_LOSS_UNVERIFIED` and this
     * method returns it unchanged. Nothing in this package may assume level 2.
     */
    fun durabilityClaim(): DurabilityLevel = durability.level()

    /**
     * `wal.md` §9: the quota, the droppable-segment rule and the §7.2-order
     * compaction.
     *
     * The write path consults it before every append; a host may also call
     * [WalQuota.enforce] on its own schedule. It is the same object, so the
     * accounting and the in-memory segment bookkeeping never diverge.
     */
    val quota: WalQuota = WalQuota(this, walLimitBytes)

    /**
     * Cold recovery of this workspace (`wal.md` §10).
     *
     * Scans `wal/` (never the manifest list, D11), classifies every segment with
     * `NativeWal.scanSegment`, asks `NativeWal.planRecovery` for the decision and
     * executes it:
     *
     * 1. a plan failure is [RecoveryOutcome.Failed] and no write is accepted;
     * 2. every D19 torn tail is truncated (and logged) with a real
     *    `FileChannel.truncate`; a non-tail failure never reaches here because
     *    the plan already failed;
     * 3. `drop_missing` is a manifest-entry drop, not a file operation;
     * 4. a stale segment is **retained and verified**, never unlinked (the
     *    revised `wal.md` §7.2 rule);
     * 5. `full_reconcile` runs only when the plan says so — the
     *    `reconcile.inprogress` marker or the missing-manifest rebuild — and uses
     *    the staged exchange of §7.2;
     * 6. the tail above the watermark is replayed with the §6 rules, including
     *    D9 for appended records;
     * 7. a manifest write happens when the checkpoint must change; it is
     *    ordered after the materialized fsyncs (§7.1).
     *
     * This method is idempotent: a second call returns the first outcome.
     */
    suspend fun recover(): RecoveryOutcome = mutex.withLock {
        outcome?.let { return@withLock it }
        val result = try {
            recoverLocked()
        } catch (error: WalException) {
            // A format failure the plan did not already report: the retained
            // WAL is not replayable, so admission must stay closed.
            RecoveryOutcome.Failed(error.code, error.detail)
        }
        if (result is RecoveryOutcome.Recovered) {
            ready = true
        } else {
            ready = false
            // budgets.md §1/§2: `Failed` is fail-loud and the reason must reach
            // the host, not only this object. The sink is the host's channel to
            // the user; a library never writes it itself.
            sink.onEvent(
                WalLogEvent.RecoveryFailed(
                    (result as RecoveryOutcome.Failed).code,
                    result.detail,
                ),
            )
        }
        outcome = result
        result
    }

    /**
     * Appends one mutation and materializes it (`wal.md` §5, D8).
     *
     * The order is fixed: structural validation, the WAL append (a `write()`
     * that returns — never an fsync), level 1, then materialization. The
     * materialized copy is never an input to the record.
     *
     * @return the level-1 ack. A §5.1 base mismatch is reported in
     *   [AppendAck.resync] and holds the watermark, it is not an exception.
     * @throws WalException `BAD_PATH`/`BAD_PAYLOAD` for a structurally invalid
     *   body: nothing is appended.
     * @throws LogException `WAL_NOT_READY`/`WAL_CLOSED` when recovery has not
     *   completed or a host defect closed the log,
     *   `WAL_QUOTA_EXCEEDED` when the §9 quota cannot be met even after
     *   compaction (admission closes, no record is written), and
     *   `WAL_MATERIALIZATION_FAILED` when the copy cannot be applied (the log
     *   closes admission, `wal.md` §5).
     */
    suspend fun appendMutation(body: MutationBody): AppendAck = mutex.withLock {
        ensureReady()
        body.validate()
        val mseq = nextMseq
        val frame = WalRecordCodec.encodeMutation(mseq, body)
        // wal.md §9: compact before a write that would cross the limit. The
        // decision is taken on the projected size, before the mseq is spent, so
        // a refusal leaves nextMseq and the segment bytes untouched.
        val previous = currentSegment
        val willRoll = previous == null ||
            (previous.hasRecords && previous.size + frame.size > segmentRollBytes)
        ensureQuotaFor(frame.size + if (willRoll) WalSegmentHeader.BYTES else 0)
        var segment = previous ?: createSegment(WalSegmentName(epoch, 0), mseq)
        if (previous != null && willRoll) {
            val next = try {
                WalSegmentName(segment.name.epoch, segment.name.segment + 1)
            } catch (error: IllegalArgumentException) {
                throw fatal(LogException(LogFailure.SEGMENT_IO, error.message ?: "segment roll failed"))
            }
            segment = createSegment(next, mseq)
        }
        appendFrame(segment, frame)
        segment.size += frame.size
        segment.hasRecords = true
        segment.lastMutationMseq = mseq
        summaryFor(segment).lastMutationMseq = mseq
        lastMseq = mseq
        nextMseq = mseq + 1

        val request = try {
            materialize(WalRecord.Mutation(mseq, body))
        } catch (error: LogException) {
            fatal(error)
        }
        AppendAck(
            mseq = mseq,
            level = AckLevel.LEVEL_1,
            materializedUptoMseq = materializedUptoMseq,
            resync = request,
        )
    }

    /**
     * Closes the current epoch in the D18 order and returns the level-2 ack.
     *
     * The order is normative (`wal.md` §5.2) and every step is observable
     * through the injected [Durability]:
     *
     * 1. [Durability.fsyncPath] on every materialized file and changed
     *    directory of this epoch, deepest first (including the parent of a
     *    chmod);
     * 2. append the §4 epoch-close record to the current (last) segment, with
     *    `durable_upto` = the highest mutation mseq appended so far;
     * 3. [Durability.fsyncPath] on **every** segment written in this epoch,
     *    including the one that received the close record;
     * 4. [Durability.fsyncPath] on `wal/`;
     * 5. [Durability.atomicReplace] the manifest, then [Durability.fsyncPath]
     *    on its directory.
     *
     * Only then does the result carry [AckLevel.LEVEL_2]. An idle epoch creates
     * segment 0 of the current epoch with `first_mseq = durable_upto + 1` and
     * writes only the close record (`wal.md` §2, §4).
     *
     * @throws LogException `WAL_CLOSED` after a host defect, `WAL_SEGMENT_IO`
     *   or `WAL_MATERIALIZATION_FAILED` if a step fails.
     */
    suspend fun closeEpoch(): EpochCloseResult = mutex.withLock {
        ensureReady()
        val held = resync
        if (held != null) {
            // wal.md §5.2: an unrepaired base mismatch at the close is a
            // failure, not a deferred repair: admission closes, Failed.
            throw fatal(
                LogException(
                    LogFailure.RESYNC_UNREPAIRED,
                    "cannot close epoch $epoch: the base mismatch at ${held.path} " +
                        "(mseq ${held.mseq}) is unrepaired",
                ),
            )
        }
        val closingEpoch = epoch
        // 1. fsync the changed materialized copy, deepest first.
        fsyncChanges(changes)
        // 2. append the epoch-close record to the current (last) segment.
        val segment = currentSegment ?: createSegment(WalSegmentName(closingEpoch, 0), nextMseq)
        val closeFrame = WalRecordCodec.encodeEpochClose(clock.nowMillis(), lastMseq)
        appendFrame(segment, closeFrame)
        segment.size += closeFrame.size
        segment.hasRecords = true
        summaryFor(segment).hasClose = true
        // 3. F_FULLFSYNC/fsync every segment written in this epoch.
        for (path in segmentsWritten) {
            durability.fsyncPath(path)
        }
        // 4. fsync the wal/ directory.
        durability.fsyncPath(paths.walDirectory)
        // 5. atomically replace the manifest, then fsync its directory.
        lastDurableEpoch = closingEpoch
        val manifest = currentManifest()
        writeManifestAtomically(manifest)
        val listed = manifest.segments.map { it.name }
        currentSegment = null
        epoch = closingEpoch + 1
        changes.clear()
        segmentsWritten.clear()
        EpochCloseResult(
            epoch = closingEpoch,
            durableUpto = manifest.lastMseq,
            level = AckLevel.LEVEL_2,
            manifest = manifest,
            segments = listed,
        )
    }

    // ---------------------------------------------------------------------
    // Recovery
    // ---------------------------------------------------------------------

    private suspend fun recoverLocked(): RecoveryOutcome {
        paths.createDirectories()
        val parsed = readManifest()
        val manifest = parsed.manifest
        val scan = scanWalDirectory(manifest)
        val facts = scan.facts
        if (manifest == null && facts.isEmpty() && materializedCopyHasContent()) {
            // "With no manifest or WAL, the workspace is new (manifest at 0)."
            // A new workspace has an empty copy; a non-empty one is an applied
            // tree whose history is gone, and adopting it as "new" would make
            // that history silently unverifiable.
            return RecoveryOutcome.Failed(
                "WAL_CORRUPT",
                "manifest.json and the WAL are missing but the materialized copy holds files; " +
                    "the copy cannot be adopted as a new workspace",
            )
        }
        val marker = Files.exists(paths.reconcileMarker, LinkOption.NOFOLLOW_LINKS)
        val plan = RecoveryPlanner.plan(facts, manifest?.toJson(), marker)
        plan.failure?.let { failure ->
            return RecoveryOutcome.Failed(failure.code, failure.detail)
        }

        val truncated = ArrayList<Truncation>()
        for (truncation in plan.truncate) {
            truncated.add(truncate(truncation))
        }

        // Recovery never holds more than one record body. The previous shape
        // decoded every retained segment into a List<WalRecord> up front, so a
        // contract-legal 128 MiB file (nine 15 MiB mutations, `channel.md`
        // §3.1) was re-materialized as ~128 MiB of bodies plus the hex/JSON
        // copies of every segment — more than the 192 MiB app heap measured on
        // the 2 GiB AVD, and an OutOfMemoryError on every boot. The passes below
        // stream one frame at a time, keep the per-segment metadata and drop the
        // body after it is applied.
        val factsByName = facts.associateBy { it.name }
        val replayNames = plan.replaySegments
        val staleNames = plan.stale.toSet()
        val retention = RetainedRecords()
        val staleTouched = LinkedHashMap<WalSegmentName, MutableSet<String>>()
        var watermark = parsed.manifest?.materializedUptoMseq ?: 0L
        var fullReconcileRan = false
        val resyncPaths = ArrayList<String>()
        val resyncMseqs = LinkedHashMap<String, Long>()
        val staleReports = LinkedHashMap<WalSegmentName, StaleSegment>()
        var replayed: List<RecoveredSegment>

        if (plan.fullReconcile) {
            val run = stagedReconcile(
                hadManifest = parsed.manifest != null,
                baseWatermark = watermark,
                names = replayNames,
                targetTail = plan.effectiveTail,
                resyncPaths = resyncPaths,
                resyncMseqs = resyncMseqs,
                retention = retention,
                staleNames = staleNames,
                staleTouched = staleTouched,
            )
            watermark = run.watermark
            replayed = run.segments
            fullReconcileRan = true
        } else {
            changes.clear()
            val run = replayInto(
                materializer = materializer,
                names = replayNames,
                startWatermark = watermark,
                resyncPaths = resyncPaths,
                resyncMseqs = resyncMseqs,
                retention = retention,
                staleNames = staleNames,
                staleTouched = staleTouched,
            )
            watermark = run.watermark
            replayed = run.segments
            verifyStale(plan, replayNames, facts, staleTouched, staleReports)
            if (staleReports.values.any { it.divergences.isNotEmpty() }) {
                if (retainedStartsAtOne(facts, replayNames)) {
                    // §7.2: divergence rebuilds the whole copy from the WAL only
                    // when the retained mutations start at mseq 1.
                    changes.clear()
                    val rebuilt = stagedReconcile(
                        hadManifest = false,
                        baseWatermark = 0L,
                        names = replayNames,
                        targetTail = plan.effectiveTail,
                        resyncPaths = resyncPaths,
                        resyncMseqs = resyncMseqs,
                        retention = null,
                        staleNames = staleNames,
                        staleTouched = staleTouched,
                    )
                    watermark = rebuilt.watermark
                    fullReconcileRan = true
                    verifyStale(plan, replayNames, facts, staleTouched, staleReports)
                } else {
                    val first = staleReports.values
                        .first { it.divergences.isNotEmpty() }
                    return RecoveryOutcome.Failed(
                        "WAL_CORRUPT",
                        "the materialized copy diverges from the retained WAL: " +
                            first.divergences.first(),
                    )
                }
            }
            if (!fullReconcileRan) {
                fsyncChanges(changes)
            }
        }

        val closedEpochs = replayNames
            .mapNotNull { name -> factsByName[name]?.takeIf { it.epochClose != null }?.name?.epoch }
            .maxOrNull() ?: 0
        val durableEpoch = maxOf(parsed.manifest?.lastDurableEpoch ?: 0, closedEpochs)

        summaries.clear()
        for (name in replayNames) {
            val fact = factsByName[name] ?: continue
            if (fact.firstMutationMseq == null && fact.epochClose == null) continue
            val summary = SegmentSummary(fact.firstMseq)
            summary.lastMutationMseq = fact.lastMutationMseq
            summary.hasClose = fact.epochClose != null
            summaries[name] = summary
        }

        val recovered = Manifest(
            lastMseq = plan.effectiveTail,
            segments = summariesToManifestSegments(),
            lastDurableEpoch = durableEpoch,
            bootId = bootId,
            materializedUptoMseq = watermark,
        )
        // A truncated segment changed on disk even when no manifest rewrite is
        // needed; fsync it (and wal/) before any checkpoint that names it.
        fsyncTruncated(truncated)
        val previous = parsed.manifest
        val needsWrite = fullReconcileRan ||
            parsed.wasInvalid ||
            previous == null ||
            plan.rebuildManifest ||
            plan.adopt.isNotEmpty() ||
            plan.stale.isNotEmpty() ||
            plan.dropMissing.isNotEmpty() ||
            differsFrom(previous, recovered)
        if (needsWrite) {
            writeManifestAtomically(recovered)
        }
        if (plan.clearReconcileMarker || fullReconcileRan) {
            deleteMarker()
        }
        if (fullReconcileRan) {
            deleteQuietly(paths.previousMaterializedDirectory)
        }
        val checkpoint = if (needsWrite) recovered else previous ?: recovered
        // §7.2: a zero-length file is not damaged content. It is excluded from
        // the plan above (or was a listed segment the missing-segment rule just
        // dropped) and is unlinked only now, after the checkpoint that omits it
        // is durable. The unlink is cleanup, not a durability claim: a lost
        // unlink is re-classified identically on the next boot.
        val droppedEmpty = dropZeroLengthSegments(scan.zeroLength, checkpoint)

        nextMseq = plan.nextMseq
        lastMseq = plan.effectiveTail
        materializedUptoMseq = watermark
        lastDurableEpoch = durableEpoch
        epoch = plan.nextEpoch
        currentSegment = null
        resync = resyncPaths.firstOrNull()?.let { path ->
            ResyncRequest(path, resyncMseqs[path] ?: lastMseq)
        }
        changes.clear()

        return RecoveryOutcome.Recovered(
            manifest = checkpoint,
            manifestRewritten = needsWrite,
            segments = replayed,
            records = retention.toList(),
            recordCount = replayed.sumOf { it.recordCount },
            truncated = truncated,
            adopted = plan.adopt,
            stale = staleReports.values.toList(),
            droppedMissing = plan.dropMissing,
            droppedEmpty = droppedEmpty,
            effectiveTail = plan.effectiveTail,
            nextMseq = plan.nextMseq,
            nextEpoch = plan.nextEpoch,
            materializedUptoMseq = watermark,
            fullReconcile = fullReconcileRan,
            resyncRequired = resyncPaths,
        )
    }

    private fun materializedCopyHasContent(): Boolean {
        for (root in listOf(paths.materializedHome, paths.materializedWorkspace)) {
            if (!Files.isDirectory(root, LinkOption.NOFOLLOW_LINKS)) continue
            try {
                Files.newDirectoryStream(root).use { stream ->
                    if (stream.iterator().hasNext()) return true
                }
            } catch (error: IOException) {
                throw fatal(
                    LogException(
                        LogFailure.WAL_DIRECTORY_IO,
                        "cannot list ${paths.label(root)}: ${error.message}",
                        error,
                    ),
                )
            }
        }
        return false
    }

    private data class ParsedManifest(val manifest: Manifest?, val wasInvalid: Boolean)

    private fun readManifest(): ParsedManifest {
        val path = paths.manifestFile
        if (!Files.exists(path, LinkOption.NOFOLLOW_LINKS)) {
            return ParsedManifest(null, wasInvalid = false)
        }
        val bytes = try {
            Files.readAllBytes(path)
        } catch (_: IOException) {
            // §7.2: unreadable is the missing-manifest rule.
            return ParsedManifest(null, wasInvalid = true)
        }
        return try {
            ParsedManifest(Manifest.parse(bytes), wasInvalid = false)
        } catch (error: WalException) {
            if (error.code == "WAL_MANIFEST_INVALID") {
                ParsedManifest(null, wasInvalid = true)
            } else {
                throw error
            }
        }
    }

    /**
     * Scans every `wal/` segment into facts (`wal.md` §10 step 1).
     *
     * A zero-length file is classified by its own length, not by the manifest:
     * it has no header and no record. Unlisted, it is excluded from the plan
     * and returned in [WalDirectoryScan.zeroLength] for §7.2's drop; listed, it
     * is reported to the planner as an unreadable segment so the
     * listed-missing rule (not a blind drop) decides whether its recorded range
     * may disappear.
     *
     * One segment is read at a time and its bytes are dropped after the kernel
     * scan, so recovery's peak is one segment — and a segment above
     * [WalSegmentReader.MAX_SEGMENT_BYTES] is refused **before** it is read.
     * Without that check a hand-crafted or foreign 128 MiB single-record
     * segment would become a 128 MiB `ByteArray` here, before the replay even
     * starts; `channel.md` §3.1/§6 bound one mutation at 15 MiB, so such a file
     * cannot be a segment this host wrote.
     */
    private fun scanWalDirectory(manifest: Manifest?): WalDirectoryScan {
        val directory = paths.walDirectory
        val names = ArrayList<WalSegmentName>()
        try {
            Files.newDirectoryStream(directory).use { stream ->
                for (entry in stream) {
                    if (!Files.isRegularFile(entry, LinkOption.NOFOLLOW_LINKS)) continue
                    val name = WalSegmentName.parse(entry.fileName.toString()) ?: continue
                    names.add(name)
                }
            }
        } catch (error: IOException) {
            throw fatal(
                LogException(
                    LogFailure.WAL_DIRECTORY_IO,
                    "cannot list ${paths.label(directory)}: ${error.message}",
                    error,
                ),
            )
        }
        names.sort()
        val listed: Set<WalSegmentName> = manifest?.segments?.mapTo(HashSet()) { it.name } ?: emptySet()
        val facts = ArrayList<SegmentFacts>(names.size)
        val zeroLength = ArrayList<WalSegmentName>()
        for (name in names) {
            val path = paths.segment(name)
            val size = try {
                Files.size(path)
            } catch (error: IOException) {
                throw fatal(
                    LogException(
                        LogFailure.WAL_DIRECTORY_IO,
                        "cannot size ${paths.label(path)}: ${error.message}",
                        error,
                    ),
                )
            }
            if (size > WalSegmentReader.MAX_SEGMENT_BYTES) {
                // A code, not an allocation: this is a refusal the user can be
                // shown. `recover()` turns it into RecoveryOutcome.Failed.
                throw WalException(
                    "WAL_RECORD_TOO_LARGE",
                    "${paths.label(path)} is $size bytes, above the " +
                        "${WalSegmentReader.MAX_SEGMENT_BYTES}-byte maximum of a conforming " +
                        "segment: one record may carry at most ${MutationBody.MAX_DATA_BYTES} " +
                        "data bytes (channel.md §3.1) and a larger segment cannot be decoded " +
                        "without loading a record above that bound. The workspace is not " +
                        "modified; recovery refuses it instead of running out of memory",
                )
            }
            val bytes = try {
                Files.readAllBytes(path)
            } catch (error: IOException) {
                throw fatal(
                    LogException(
                        LogFailure.WAL_DIRECTORY_IO,
                        "cannot read ${paths.label(path)}: ${error.message}",
                        error,
                    ),
                )
            }
            if (bytes.isEmpty()) {
                zeroLength.add(name)
                if (name in listed) facts.add(SegmentFacts.unreadable(name))
                continue
            }
            facts.add(WalScanner.scan(name, bytes))
        }
        return WalDirectoryScan(facts = facts, zeroLength = zeroLength)
    }

    /**
     * Deletes the zero-length segments a successful recovery did not keep.
     *
     * Only names absent from [checkpoint]'s `segments[]` are touched: a listed
     * zero-length segment was first decided by the listed-missing rule (drop or
     * `WAL_CORRUPT`), so §7.2's "manifest before deletion" order holds. A
     * failed unlink is reported through the event and is not fatal: the file
     * holds no record, and the next boot classifies it identically.
     */
    private fun dropZeroLengthSegments(
        names: List<WalSegmentName>,
        checkpoint: Manifest,
    ): List<WalSegmentName> {
        if (names.isEmpty()) return emptyList()
        val listed: Set<WalSegmentName> = checkpoint.segments.mapTo(HashSet()) { it.name }
        val dropped = ArrayList<WalSegmentName>()
        for (name in names) {
            if (name in listed) continue
            val removed = try {
                Files.deleteIfExists(paths.segment(name))
            } catch (_: IOException) {
                false
            }
            sink.onEvent(WalLogEvent.EmptySegmentDropped(name, removed))
            dropped.add(name)
        }
        return dropped
    }

    private fun truncate(truncation: Truncation): Truncation {
        val path = paths.segment(truncation.segment)
        val previous = try {
            Files.size(path)
        } catch (error: IOException) {
            throw fatal(
                LogException(
                    LogFailure.SEGMENT_IO,
                    "cannot size ${paths.label(path)}: ${error.message}",
                    error,
                ),
            )
        }
        try {
            FileChannel.open(path, StandardOpenOption.WRITE).use { channel ->
                channel.truncate(truncation.keepLen)
            }
        } catch (error: IOException) {
            throw fatal(
                LogException(
                    LogFailure.SEGMENT_IO,
                    "cannot truncate ${paths.label(path)}: ${error.message}",
                    error,
                ),
            )
        }
        sink.onEvent(
            WalLogEvent.TruncatedTail(
                bootId = bootId,
                segment = truncation.segment,
                keepLen = truncation.keepLen,
                droppedBytes = truncation.droppedBytes,
                previousLength = previous,
            ),
        )
        return truncation
    }

    /**
     * One record's `wal.md` §9 proof: its mseq and, for a mutation, its path.
     *
     * The §9 droppable rule needs only "every mutation at or below the
     * watermark" and the materialized paths to fsync, never a data body — so
     * the proof streams the segment and holds no payload.
     */
    internal data class SegmentRecordRef(
        val mseq: Long,
        val path: String?,
        val isMutation: Boolean,
    )

    /**
     * Reads one retained segment's header and record **metadata**.
     *
     * `wal.md` §9 uses it to **prove** a candidate droppable from its own bytes
     * before anything is unlinked, because the manifest may only ever be weaker
     * evidence than the file. No mutation body is kept.
     */
    internal fun readSegmentRecordRefs(name: WalSegmentName): List<SegmentRecordRef> =
        WalSegmentReader.open(paths, name).use { reader ->
            val refs = ArrayList<SegmentRecordRef>()
            reader.forEachRecord { record ->
                refs.add(
                    when (record) {
                        is WalRecord.Mutation ->
                            SegmentRecordRef(record.mseq, record.body.path, isMutation = true)

                        is WalRecord.EpochClose ->
                            SegmentRecordRef(record.mseq, null, isMutation = false)
                    },
                )
            }
            refs
        }

    /**
     * The bounded diagnostic record list of one recovery.
     *
     * Epoch-close records are tiny and always kept: `HostWal` derives
     * `durable_mseq` from the closes in
     * [RecoveryOutcome.Recovered.records]. Mutation bodies are kept only while
     * the shared [RETAINED_RECORD_BYTES] budget allows, so the outcome can never
     * pin a whole WAL on the heap; the per-segment `recordCount` and the
     * manifest still describe every verified record.
     */
    private class RetainedRecords(
        private val budgetBytes: Int = RETAINED_RECORD_BYTES,
    ) {
        private val records = ArrayList<WalRecord>()
        private var retainedMutationBytes = 0

        fun add(record: WalRecord) {
            when (record) {
                is WalRecord.EpochClose -> records.add(record)

                is WalRecord.Mutation -> {
                    if (retainedMutationBytes + record.body.data.size <= budgetBytes) {
                        records.add(record)
                        retainedMutationBytes += record.body.data.size
                    }
                }
            }
        }

        fun toList(): List<WalRecord> = records.toList()
    }

    /** One streaming replay pass: the segment metadata plus the watermark it reached. */
    private class ReplayRun(
        val segments: List<RecoveredSegment>,
        val watermark: Long,
    )

    /**
     * Replays [names] one record at a time into [materializer].
     *
     * The stream is in `<epoch,segment>` + file order; the planner has already
     * proven that the retained ranges are disjoint and that the tail above the
     * watermark is strictly contiguous, so file order is mseq order for every
     * record the pass applies. A record at or below [startWatermark] is skipped
     * (it is already in the copy), and the first record that is not
     * `watermark + 1` stops the replay — the same rule the pre-P19 sorted-list
     * pass used, except the body of each record is dropped as soon as it is
     * applied.
     *
     * @param retention where diagnostic bodies are collected, or `null` for a
     *   pass whose outcome is discarded (the §7.2 rebuild after a divergence).
     * @param staleNames segments the plan calls stale; their touched paths are
     *   collected for [verifyStale].
     */
    private fun replayInto(
        materializer: Materializer,
        names: List<WalSegmentName>,
        startWatermark: Long,
        resyncPaths: MutableList<String>,
        resyncMseqs: MutableMap<String, Long>,
        retention: RetainedRecords?,
        staleNames: Set<WalSegmentName>,
        staleTouched: MutableMap<WalSegmentName, MutableSet<String>>,
    ): ReplayRun {
        var watermark = startWatermark
        var applying = true
        val segments = ArrayList<RecoveredSegment>(names.size)
        for (name in names) {
            var recordCount = 0
            var lastMutationMseq = 0L
            var hasEpochClose = false
            WalSegmentReader.open(paths, name).use { reader ->
                reader.forEachRecord { record ->
                    recordCount++
                    when (record) {
                        is WalRecord.EpochClose -> {
                            hasEpochClose = true
                            retention?.add(record)
                        }

                        is WalRecord.Mutation -> {
                            lastMutationMseq = maxOf(lastMutationMseq, record.mseq)
                            if (name in staleNames) {
                                staleTouched.getOrPut(name) { LinkedHashSet() }.add(record.body.path)
                            }
                            if (applying && record.mseq > watermark) {
                                if (record.mseq == watermark + 1) {
                                    when (val result = materializer.apply(record.body)) {
                                        is MaterializeOutcome.Applied,
                                        is MaterializeOutcome.Skipped,
                                        -> watermark = record.mseq

                                        is MaterializeOutcome.Resync -> {
                                            resyncPaths.add(result.path)
                                            resyncMseqs[result.path] = record.mseq
                                            sink.onEvent(
                                                WalLogEvent.ResyncRequired(result.path, record.mseq),
                                            )
                                            applying = false
                                        }
                                    }
                                } else {
                                    applying = false
                                }
                            }
                            retention?.add(record)
                        }
                    }
                }
                val header = reader.header
                segments.add(
                    RecoveredSegment(
                        name = name,
                        header = header,
                        firstMseq = header.firstMseq,
                        lastMutationMseq = lastMutationMseq,
                        recordCount = recordCount,
                        hasEpochClose = hasEpochClose,
                    ),
                )
            }
        }
        return ReplayRun(segments, watermark)
    }

    /**
     * Verifies `wal.md` §7.2's stale segments against the materialized copy.
     *
     * The verifying pass streams the retained WAL again and feeds only the
     * mutations of a stale-touched path to [MaterializedInvariant], which
     * compares each record's bytes with the copy at the record's offset. No
     * file (and no record body beyond the one being read) is held on the heap.
     */
    private fun verifyStale(
        plan: RecoveryPlan,
        names: List<WalSegmentName>,
        facts: List<SegmentFacts>,
        staleTouched: Map<WalSegmentName, Set<String>>,
        reports: MutableMap<WalSegmentName, StaleSegment>,
    ) {
        if (plan.stale.isEmpty()) return
        val ranges = mutationRanges(facts, names)
        val tailMseq = ranges.lastOrNull()?.last ?: 0L
        val stalePaths = staleTouched.values.flatten().toHashSet()
        val invariant = MaterializedInvariant(paths, ranges, tailMseq)
        if (stalePaths.isNotEmpty()) {
            for (name in names) {
                WalSegmentReader.open(paths, name).use { reader ->
                    reader.forEachRecord { record ->
                        if (record is WalRecord.Mutation && record.body.path in stalePaths) {
                            invariant.observe(record)
                        }
                    }
                }
            }
        }
        for (name in plan.stale) {
            // A header-only stale segment is not in replay_segments: it holds no
            // record, so it has nothing to prove and is trivially verified.
            val report = invariant.report(staleTouched[name] ?: emptySet())
            reports[name] = StaleSegment(
                name = name,
                verified = report.divergences.isEmpty() && report.unprovable.isEmpty(),
                unprovable = report.unprovable.toList(),
                divergences = report.divergences,
            )
        }
    }

    /** The mutation ranges the retained segments hold, sorted by `mseq`. */
    private fun mutationRanges(
        facts: List<SegmentFacts>,
        names: List<WalSegmentName>,
    ): List<LongRange> {
        val byName = facts.associateBy { it.name }
        return names.mapNotNull { name ->
            val fact = byName[name] ?: return@mapNotNull null
            val first = fact.firstMutationMseq ?: return@mapNotNull null
            if (fact.lastMutationMseq < first) null else first..fact.lastMutationMseq
        }.sortedBy { it.first }
    }

    /**
     * §7.2's "the retained mutations start at mseq 1" precondition for a full
     * rebuild: the retained ranges must cover `[1, tail]` with no hole.
     */
    private fun retainedStartsAtOne(facts: List<SegmentFacts>, names: List<WalSegmentName>): Boolean {
        val ranges = mutationRanges(facts, names)
        if (ranges.isEmpty() || ranges.first().first != 1L) return false
        var cursor = 1L
        for (range in ranges) {
            if (range.last < cursor) continue
            if (range.first > cursor) return false
            cursor = range.last + 1
        }
        return true
    }

    private suspend fun stagedReconcile(
        hadManifest: Boolean,
        baseWatermark: Long,
        names: List<WalSegmentName>,
        targetTail: Long,
        resyncPaths: MutableList<String>,
        resyncMseqs: MutableMap<String, Long>,
        retention: RetainedRecords?,
        staleNames: Set<WalSegmentName>,
        staleTouched: MutableMap<WalSegmentName, MutableSet<String>>,
    ): ReplayRun {
        // §7.2 step 1: write the marker with the boot id, target tail and
        // materialized position, and fsync it before touching the tree.
        writeReconcileMarker(targetTail, baseWatermark)
        restorePreviousIfMissing()
        deleteRecursively(paths.stagingDirectory, required = true)
        if (hadManifest) {
            copyTree(paths.materializedDirectory, paths.stagingDirectory)
        } else {
            createStagingRoots()
        }
        val stagingChanges = EpochChanges(paths)
        val stagingMaterializer = Materializer(paths, paths.stagingDirectory, stagingChanges)
        val run = replayInto(
            materializer = stagingMaterializer,
            names = names,
            startWatermark = if (hadManifest) baseWatermark else 0L,
            resyncPaths = resyncPaths,
            resyncMseqs = resyncMseqs,
            retention = retention,
            staleNames = staleNames,
            staleTouched = staleTouched,
        )
        // §7.2 step 3: fsync the staging tree before the exchange.
        fsyncChanges(stagingChanges)
        // §7.2 step 4: exchange materialized/ and materialized.staging/.
        deleteRecursively(paths.previousMaterializedDirectory, required = false)
        try {
            if (Files.exists(paths.materializedDirectory, LinkOption.NOFOLLOW_LINKS)) {
                Files.move(
                    paths.materializedDirectory,
                    paths.previousMaterializedDirectory,
                    StandardCopyOption.ATOMIC_MOVE,
                )
            }
            Files.move(
                paths.stagingDirectory,
                paths.materializedDirectory,
                StandardCopyOption.ATOMIC_MOVE,
            )
        } catch (error: IOException) {
            throw fatal(
                LogException(
                    LogFailure.RECONCILE_FAILED,
                    "cannot exchange the materialized tree: ${error.message}",
                    error,
                ),
            )
        }
        durability.fsyncPath(paths.root)
        return run
    }

    private suspend fun writeReconcileMarker(targetTail: Long, baseWatermark: Long) {
        val text = buildString {
            append("boot_id=").append(bootId.hex).append('\n')
            append("target_tail=").append(targetTail).append('\n')
            append("materialized_upto_mseq=").append(baseWatermark).append('\n')
        }
        try {
            Files.write(paths.reconcileMarker, text.toByteArray(Charsets.UTF_8))
        } catch (error: IOException) {
            throw fatal(
                LogException(
                    LogFailure.RECONCILE_FAILED,
                    "cannot write ${paths.label(paths.reconcileMarker)}: ${error.message}",
                    error,
                ),
            )
        }
        // The marker must be durable before any tree change.
        durability.fsyncPath(paths.reconcileMarker)
        durability.fsyncPath(paths.root)
    }

    private fun restorePreviousIfMissing() {
        val materialized = paths.materializedDirectory
        val previous = paths.previousMaterializedDirectory
        if (!Files.exists(materialized, LinkOption.NOFOLLOW_LINKS) &&
            Files.exists(previous, LinkOption.NOFOLLOW_LINKS)
        ) {
            try {
                Files.move(previous, materialized, StandardCopyOption.ATOMIC_MOVE)
            } catch (error: IOException) {
                throw fatal(
                    LogException(
                        LogFailure.RECONCILE_FAILED,
                        "cannot restore the materialized tree: ${error.message}",
                        error,
                    ),
                )
            }
        }
    }

    private fun createStagingRoots() {
        try {
            Files.createDirectories(paths.stagingDirectory.resolve("home"))
            Files.createDirectories(paths.stagingDirectory.resolve("workspace"))
        } catch (error: IOException) {
            throw fatal(
                LogException(
                    LogFailure.RECONCILE_FAILED,
                    "cannot create the staging roots: ${error.message}",
                    error,
                ),
            )
        }
    }

    private fun copyTree(from: Path, to: Path) {
        try {
            Files.createDirectories(to)
            if (!Files.exists(from, LinkOption.NOFOLLOW_LINKS)) {
                createStagingRoots()
                return
            }
            Files.walkFileTree(
                from,
                object : SimpleFileVisitor<Path>() {
                    override fun preVisitDirectory(dir: Path, attrs: BasicFileAttributes): FileVisitResult {
                        val target = to.resolve(from.relativize(dir).toString())
                        Files.createDirectories(target)
                        PosixModes.set(target, PosixModes.read(dir))
                        return FileVisitResult.CONTINUE
                    }

                    override fun visitFile(file: Path, attrs: BasicFileAttributes): FileVisitResult {
                        val target = to.resolve(from.relativize(file).toString())
                        target.parent?.let { Files.createDirectories(it) }
                        Files.copy(
                            file,
                            target,
                            StandardCopyOption.REPLACE_EXISTING,
                            StandardCopyOption.COPY_ATTRIBUTES,
                        )
                        PosixModes.set(target, PosixModes.read(file))
                        return FileVisitResult.CONTINUE
                    }
                },
            )
        } catch (error: IOException) {
            throw fatal(
                LogException(
                    LogFailure.RECONCILE_FAILED,
                    "cannot stage the materialized tree: ${error.message}",
                    error,
                ),
            )
        }
    }

    // ---------------------------------------------------------------------
    // Write path
    // ---------------------------------------------------------------------

    private class SegmentState(
        val name: WalSegmentName,
        val firstMseq: Long,
        val path: Path,
        var size: Long,
        var hasRecords: Boolean = false,
        var lastMutationMseq: Long = 0L,
    )

    private class SegmentSummary(val firstMseq: Long) {
        var lastMutationMseq: Long = 0L
        var hasClose: Boolean = false

        fun hasRecords(): Boolean = lastMutationMseq > 0L || hasClose
    }

    private fun createSegment(name: WalSegmentName, firstMseq: Long): SegmentState {
        val path = paths.segment(name)
        val header = WalSegmentHeader(firstMseq, bootId)
        if (Files.exists(path, LinkOption.NOFOLLOW_LINKS)) {
            throw fatal(
                LogException(
                    LogFailure.SEGMENT_IO,
                    "${paths.label(path)} already exists; a segment is created once",
                ),
            )
        }
        try {
            FileChannel.open(path, StandardOpenOption.CREATE_NEW, StandardOpenOption.WRITE).use { channel ->
                val buffer = ByteBuffer.wrap(header.encode())
                while (buffer.hasRemaining()) {
                    channel.write(buffer)
                }
            }
        } catch (error: IOException) {
            throw fatal(
                LogException(
                    LogFailure.SEGMENT_IO,
                    "cannot create ${paths.label(path)}: ${error.message}",
                    error,
                ),
            )
        }
        val state = SegmentState(
            name = name,
            firstMseq = firstMseq,
            path = path,
            size = WalSegmentHeader.BYTES.toLong(),
        )
        currentSegment = state
        segmentsWritten.add(path)
        return state
    }

    private fun appendFrame(segment: SegmentState, frame: ByteArray) {
        try {
            FileChannel.open(segment.path, StandardOpenOption.WRITE).use { channel ->
                val size = channel.size()
                if (size != segment.size) {
                    throw fatal(
                        LogException(
                            LogFailure.SEGMENT_IO,
                            "${paths.label(segment.path)} is $size bytes, expected ${segment.size}",
                        ),
                    )
                }
                channel.position(size)
                val buffer = ByteBuffer.wrap(frame)
                while (buffer.hasRemaining()) {
                    channel.write(buffer)
                }
            }
        } catch (error: IOException) {
            throw fatal(
                LogException(
                    LogFailure.SEGMENT_IO,
                    "cannot append to ${paths.label(segment.path)}: ${error.message}",
                    error,
                ),
            )
        }
        segmentsWritten.add(segment.path)
    }

    private fun summaryFor(segment: SegmentState): SegmentSummary =
        summaries.getOrPut(segment.name) { SegmentSummary(segment.firstMseq) }

    /**
     * `wal.md` §9 at the write path: keep the WAL at or below [walLimitBytes].
     *
     * [reserveBytes] is the projected size of the append (segment header
     * included when this append would roll a new one). When the projection
     * crosses the limit, [WalQuota.enforceWithReserve] compacts provably
     * droppable data first; when the record still does not fit, this fails
     * loud with [LogFailure.QUOTA_EXCEEDED] and closes admission. Nothing is
     * truncated, no segment is dropped without the §9 proof, and the manifest
     * is only ever rewritten in the §7.2 order.
     *
     * The caller holds [mutex]; [quota] must not take it again.
     */
    private suspend fun ensureQuotaFor(reserveBytes: Int) {
        val limit = walLimitBytes
        if (quota.usedBytes() + reserveBytes <= limit) return
        val outcome = try {
            quota.enforceWithReserve(reserveBytes.toLong())
        } catch (error: LogException) {
            throw fatal(error)
        } catch (error: IOException) {
            throw fatal(
                LogException(
                    LogFailure.SEGMENT_IO,
                    "cannot enforce the WAL quota: ${error.message}",
                    error,
                ),
            )
        }
        if (outcome.bytes + reserveBytes > limit) {
            throw fatal(
                LogException(
                    LogFailure.QUOTA_EXCEEDED,
                    "the WAL holds ${outcome.bytes} bytes against a $limit byte quota " +
                        "after compaction dropped ${outcome.dropped.size} segment(s); " +
                        "the append needs $reserveBytes more and only provably " +
                        "droppable segments may be compacted",
                ),
            )
        }
    }

    private fun materialize(record: WalRecord.Mutation): ResyncRequest? {
        val held = resync
        if (held != null) {
            pending.add(record)
            return settle(held)
        }
        return when (val result = materializer.apply(record.body)) {
            is MaterializeOutcome.Applied, is MaterializeOutcome.Skipped -> {
                if (record.mseq == materializedUptoMseq + 1) {
                    materializedUptoMseq = record.mseq
                }
                null
            }
            is MaterializeOutcome.Resync -> {
                val request = ResyncRequest(result.path, record.mseq)
                resync = request
                pending.add(record)
                sink.onEvent(WalLogEvent.ResyncRequired(result.path, record.mseq))
                request
            }
        }
    }

    /**
     * §5.1 settlement: a complete write for the held path becomes the new base,
     * the path's pending appended records are re-applied under D9 (usually
     * skipped because the repair already contains the bytes), and the watermark
     * then advances across every record it had held back.
     */
    private fun settle(held: ResyncRequest): ResyncRequest? {
        val repair = pending.lastOrNull {
            it.body.op == VfsOp.WRITE && !it.body.appended && it.body.path == held.path
        } ?: return held
        when (val outcome = materializer.apply(repair.body)) {
            is MaterializeOutcome.Resync -> {
                val request = ResyncRequest(outcome.path, repair.mseq)
                resync = request
                return request
            }
            else -> Unit
        }
        val ordered = pending.sortedBy { it.mseq }
        for (record in ordered) {
            if (record.mseq <= materializedUptoMseq) {
                pending.removeAll { it.mseq == record.mseq }
                continue
            }
            if (record.mseq != materializedUptoMseq + 1) break
            when (val outcome = materializer.apply(record.body)) {
                is MaterializeOutcome.Resync -> {
                    val request = ResyncRequest(outcome.path, record.mseq)
                    resync = request
                    pending.removeAll { it.mseq >= record.mseq }
                    pending.addAll(ordered.filter { it.mseq >= record.mseq })
                    return request
                }
                else -> {
                    materializedUptoMseq = record.mseq
                    pending.removeAll { it.mseq == record.mseq }
                }
            }
        }
        if (pending.isEmpty()) {
            resync = null
            return null
        }
        return resync
    }

    // ---------------------------------------------------------------------
    // Manifest and durability helpers
    // ---------------------------------------------------------------------

    private fun currentManifest(): Manifest = Manifest(
        lastMseq = lastMseq,
        segments = summariesToManifestSegments(),
        lastDurableEpoch = lastDurableEpoch,
        bootId = bootId,
        materializedUptoMseq = materializedUptoMseq,
    )

    private fun summariesToManifestSegments(): List<ManifestSegment> = summaries.entries
        .filter { it.value.hasRecords() }
        .map { (name, summary) ->
            ManifestSegment.of(name, summary.firstMseq, summary.lastMutationMseq)
        }
        .sortedWith(compareBy({ it.epoch }, { it.file }))

    private fun differsFrom(previous: Manifest?, recovered: Manifest): Boolean {
        if (previous == null) return true
        return previous.lastMseq != recovered.lastMseq ||
            previous.materializedUptoMseq != recovered.materializedUptoMseq ||
            previous.lastDurableEpoch != recovered.lastDurableEpoch ||
            previous.sortedSegments() != recovered.sortedSegments()
    }

    /**
     * `wal.md` §5.2 step 1's fsync order over [changes]: deepest first, a
     * missing path skipped.
     *
     * Shared with §9 compaction, which must make the materialized output of the
     * segments it is about to drop durable before they disappear.
     */
    internal suspend fun fsyncChanges(changes: EpochChanges) {
        for (path in changes.ordered()) {
            if (!Files.exists(path, LinkOption.NOFOLLOW_LINKS)) continue
            durability.fsyncPath(path)
        }
    }

    private suspend fun fsyncTruncated(truncated: List<Truncation>) {
        for (truncation in truncated) {
            durability.fsyncPath(paths.segment(truncation.segment))
        }
        if (truncated.isNotEmpty()) {
            durability.fsyncPath(paths.walDirectory)
        }
    }

    /**
     * §7.1: `manifest.json.tmp` → fsync → rename → fsync the directory.
     *
     * [Durability.atomicReplace] performs the temp/rename sequence; the
     * explicit directory fsync afterwards is D18 step 5's observable "and then
     * fsync", not a duplicate of an implementation detail: the SPI's contract
     * already syncs the parent, and this call is what makes the order testable
     * through the SPI rather than inside it.
     *
     * §9 compaction replaces the checkpoint with this same primitive, which is
     * what makes "manifest before deletion" (§7.2) an ordered fact rather than
     * an intention.
     */
    internal suspend fun writeManifestAtomically(manifest: Manifest) {
        val bytes = manifest.encode()
        try {
            durability.atomicReplace(paths.manifestFile) { temporary ->
                Files.write(temporary, bytes)
            }
        } catch (error: IOException) {
            throw fatal(
                LogException(
                    LogFailure.SEGMENT_IO,
                    "cannot replace ${paths.label(paths.manifestFile)}: ${error.message}",
                    error,
                ),
            )
        }
        durability.fsyncPath(paths.root)
    }

    private suspend fun deleteMarker() {
        try {
            if (Files.deleteIfExists(paths.reconcileMarker)) {
                durability.fsyncPath(paths.root)
            }
        } catch (error: IOException) {
            throw fatal(
                LogException(
                    LogFailure.RECONCILE_FAILED,
                    "cannot remove ${paths.label(paths.reconcileMarker)}: ${error.message}",
                    error,
                ),
            )
        }
    }

    /**
     * Deletes [path] and its subtree; a missing path is a no-op.
     *
     * [required] selects the failure contract: a staging cleanup that cannot
     * delete must fail loud (the exchange would otherwise layer on a stale
     * tree), while the old-tree cleanup after a completed reconcile is
     * best-effort.
     */
    private fun deleteRecursively(path: Path, required: Boolean) {
        if (!Files.exists(path, LinkOption.NOFOLLOW_LINKS)) {
            return
        }
        try {
            Files.walkFileTree(
                path,
                object : SimpleFileVisitor<Path>() {
                    override fun visitFile(file: Path, attrs: BasicFileAttributes): FileVisitResult {
                        Files.deleteIfExists(file)
                        return FileVisitResult.CONTINUE
                    }

                    override fun postVisitDirectory(dir: Path, error: IOException?): FileVisitResult {
                        if (error != null) throw error
                        Files.deleteIfExists(dir)
                        return FileVisitResult.CONTINUE
                    }
                },
            )
        } catch (error: IOException) {
            if (required) {
                throw fatal(
                    LogException(
                        LogFailure.RECONCILE_FAILED,
                        "cannot delete ${paths.label(path)}: ${error.message}",
                        error,
                    ),
                )
            }
        }
    }

    private fun deleteQuietly(path: Path) {
        deleteRecursively(path, required = false)
    }

    // ---------------------------------------------------------------------
    // §9 compaction support (WalQuota)
    // ---------------------------------------------------------------------

    /**
     * Runs [block] under this log's single-writer [mutex].
     *
     * The write path already holds it; [WalQuota.enforce] is the public entry
     * that acquires it, so a host-driven compaction never interleaves with an
     * append or a close.
     */
    internal suspend fun <T> locked(block: suspend () -> T): T = mutex.withLock { block() }

    /** The open segment, or `null` between a close and the next append (§9). */
    internal fun openSegmentName(): WalSegmentName? = currentSegment?.name

    /**
     * The retained segment that received the newest epoch-close record (§9).
     *
     * It is the close record compaction must never drop: D19 step 4 derives
     * `durable_mseq` from the largest `durable_upto` among the **retained**
     * close records, so unlinking it would silently lower a durable watermark
     * that was already reported.
     */
    internal fun newestEpochCloseSegment(): WalSegmentName? =
        summaries.filterValues { it.hasClose }.keys.maxOrNull()

    /** The live highest mutation mseq of a retained segment; 0 when unknown. */
    internal fun segmentLastMutationMseq(name: WalSegmentName): Long =
        summaries[name]?.lastMutationMseq ?: 0L

    /** The checkpoint on disk, or `null` when absent or unreadable (§7.2). */
    internal fun manifestOnDisk(): Manifest? = readManifest().manifest

    /**
     * The checkpoint of a §9 compaction: everything current except [dropped].
     *
     * `last_mseq` is never lowered (D17), the watermark stays the strictly
     * contiguous one and `last_durable_epoch` stays the live marker.
     */
    internal fun manifestExcluding(dropped: Set<WalSegmentName>): Manifest = Manifest(
        lastMseq = lastMseq,
        segments = summariesToManifestSegments().filterNot { it.name in dropped },
        lastDurableEpoch = lastDurableEpoch,
        bootId = bootId,
        materializedUptoMseq = materializedUptoMseq,
    )

    /** Forgets segments after their §9 unlink, so no later manifest re-lists them. */
    internal fun forgetSegments(names: Collection<WalSegmentName>) {
        for (name in names) summaries.remove(name)
    }

    // ---------------------------------------------------------------------
    // State
    // ---------------------------------------------------------------------

    internal fun ensureReady() {
        fatal?.let { throw it }
        if (!ready) {
            throw LogException(
                LogFailure.NOT_READY,
                "recover() has not completed with a recovered workspace",
            )
        }
    }

    /** Records a host defect: no further write is accepted (`wal.md` §5). */
    private fun fatal(error: LogException): Nothing {
        fatal = error
        ready = false
        throw error
    }

    companion object {
        /** `wal.md` §1: a segment rolls before a mutation that would exceed 8 MiB. */
        const val DEFAULT_SEGMENT_ROLL_BYTES: Int = 8 * 1024 * 1024

        /**
         * How many mutation-body bytes one recovery keeps for diagnostics.
         *
         * Recovery is a **boot** path: `budgets.md` §4 allows a 128 MiB single
         * file on the 8 GiB row while the app process is capped at 230 MB and
         * the smallest tier at 100 MB, so the outcome must not pin the WAL's
         * bodies on the heap. Epoch-close records are always kept (they are 33
         * bytes and `HostWal` needs them); mutation bodies are kept in file
         * order until this budget is spent. Tests and goldens are far below it,
         * so their record lists are complete.
         */
        const val RETAINED_RECORD_BYTES: Int = 4 * 1024 * 1024
    }
}
