// wal.md §9: the quota, the droppable rule and §7.2-order compaction.
// SPDX-License-Identifier: MIT

package com.phonedsh.log

import com.phonedsh.platform.Durability
import com.phonedsh.platform.DurabilityLevel
import java.nio.file.Files
import java.nio.file.Path
import java.nio.file.StandardCopyOption
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

/**
 * `wal.md` §9, end to end: which segment may be dropped, the exact order of
 * the compaction steps, the fail-loud branch, and a real rolling WAL whose
 * compacted history still recovers every materialized byte.
 */
class WalQuotaTest {
    @get:Rule
    val temporary = TemporaryFolder()

    /**
     * Three segments that exercise the three §9 cases at once:
     *
     * - `1.0` — mseq 1 plus the epoch-1 close: **droppable**, because epoch 1
     *   is durable and listed and every mutation is at or below the watermark;
     * - `2.0` — mseq 2 plus the epoch-2 close: **never**, because it is the
     *   newest epoch-close segment;
     * - `3.0` — mseq 3, then mseq 4 above the watermark: **never**, because it
     *   holds a mutation above the watermark (and its epoch is the open one).
     *
     * mseq 4 is an appended suffix with no base, so D9/§6.2 reports a base
     * mismatch and the watermark stops at 3 while the WAL keeps the record.
     */
    private suspend fun threeSegmentLog(root: Path, durability: Durability): WorkspaceLog {
        val log = newLog(root, durability, rollBytes = 4096)
        val outcome = log.recover()
        assertTrue("$outcome", outcome is RecoveryOutcome.Recovered)
        assertEquals(1L, log.appendMutation(writeMutation("/dsh/workspace/a.txt", "a")).mseq)
        log.closeEpoch()
        assertEquals(2L, log.appendMutation(writeMutation("/dsh/workspace/b.txt", "b")).mseq)
        log.closeEpoch()
        assertEquals(3L, log.appendMutation(writeMutation("/dsh/workspace/c.txt", "c")).mseq)
        assertEquals(
            4L,
            log.appendMutation(appendedMutation("/dsh/workspace/absent.txt", 0, "zz")).mseq,
        )
        assertEquals("the mismatch must hold the watermark", 3L, log.materializedUptoMseq)
        return log
    }

    @Test
    fun onlyTheProvablyDroppableSegmentIsUnlinked() = runBlocking {
        val root = temporary.newFolder("droppable").toPath()
        val paths = WalPaths(root)
        val log = threeSegmentLog(root, RecordingDurability(root))

        val names = segmentNames(paths)
        assertEquals(
            listOf(WalSegmentName(1, 0), WalSegmentName(2, 0), WalSegmentName(3, 0)),
            names,
        )
        val first = names.first()
        val firstSize = Files.size(paths.segment(first))
        val before = walSize(paths)

        // A limit that the removal of exactly one segment satisfies.
        val quota = WalQuota(log, limitBytes = before - firstSize)
        val outcome = quota.enforce()
        assertTrue("$outcome", outcome is QuotaOutcome.Compacted)
        outcome as QuotaOutcome.Compacted
        assertEquals(before, outcome.bytesBefore)
        assertEquals(before - firstSize, outcome.bytes)
        assertEquals(before - firstSize, quota.usedBytes())
        assertEquals(listOf(first), outcome.dropped)

        assertFalse("the droppable segment is gone", Files.exists(paths.segment(first)))
        for (name in names.drop(1)) {
            assertTrue("$name must be retained", Files.exists(paths.segment(name)))
        }

        // The shorter manifest no longer lists it, still lists the retained
        // segments, and keeps D17's high-water mseq (4) and the watermark (3).
        val manifest = readManifest(paths)
        assertEquals(
            names.drop(1).map { it.manifestFile },
            manifest.segments.map { it.file },
        )
        assertEquals(4L, manifest.lastMseq)
        assertEquals(3L, manifest.materializedUptoMseq)
        assertEquals(2, manifest.lastDurableEpoch)

        // The dropped segment's output is still materialized.
        assertEquals("a", materializedText(paths, "/dsh/workspace/a.txt"))

        // A second, impossible limit must consider the two survivors and refuse
        // both: 2.0 because it holds the newest close record, 3.0 because its
        // epoch is not durable and it holds a mutation above the watermark.
        // Nothing more is unlinked.
        val survivors = segmentNames(paths)
        val stuck = WalQuota(log, limitBytes = 1L).enforce()
        assertTrue("$stuck", stuck is QuotaOutcome.Exceeded)
        stuck as QuotaOutcome.Exceeded
        assertTrue(stuck.dropped.isEmpty())
        assertEquals(1L, stuck.limit)
        assertEquals(walSize(paths), stuck.bytes)
        assertEquals(survivors, segmentNames(paths))
        assertTrue(stuck.bytes > stuck.limit)
    }

    @Test
    fun compactionRunsInTheSection92Order() = runBlocking {
        val root = temporary.newFolder("order").toPath()
        val paths = WalPaths(root)
        val probe = CompactionProbe(root, WalSegmentName(1, 0))
        val log = threeSegmentLog(root, probe)

        val firstSize = Files.size(paths.segment(WalSegmentName(1, 0)))
        val before = walSize(paths)
        probe.clear()

        val outcome = WalQuota(log, limitBytes = before - firstSize).enforce()
        assertTrue("$outcome", outcome is QuotaOutcome.Compacted)

        // The exact §9 order: materialized fsync, then the atomic manifest,
        // then (invisible to the SPI) the unlink, then the wal/ directory.
        assertEquals(
            listOf(
                "fsync:materialized/workspace/a.txt",
                "fsync:materialized/workspace",
                "atomicReplace:manifest.json",
                "fsync:.",
                "fsync:wal",
            ),
            probe.events,
        )

        // "Delete a segment only after a durable manifest that no longer lists
        // it" (§7.2): when the shorter manifest is published, the file is still
        // present and the manifest on disk already omits it.
        val published = probe.steps.first { it.event == "atomicReplace:manifest.json" }
        assertTrue("the segment must still exist at the manifest write", published.hasSegment)
        assertFalse("the manifest must already omit it", published.manifestListsSegment)
        // Nothing may be unlinked before the manifest is durable.
        for (step in probe.steps.takeWhile { it.event != "atomicReplace:manifest.json" }) {
            assertTrue("${step.event} unlinked early", step.hasSegment)
        }
        // The unlink comes before the wal/ directory fsync that publishes it.
        val last = probe.steps.last()
        assertEquals("fsync:wal", last.event)
        assertFalse("the segment must be gone before the directory fsync", last.hasSegment)
        assertFalse(last.manifestListsSegment)
    }

    @Test
    fun aWalThatCannotBeCompactedFailsLoudWithoutDeletingAnything() = runBlocking {
        val root = temporary.newFolder("stuck").toPath()
        val paths = WalPaths(root)
        val log = newLog(root, RecordingDurability(root), rollBytes = 100)
        assertTrue(log.recover() is RecoveryOutcome.Recovered)
        for (index in 0 until 3) {
            log.appendMutation(writeMutation("/dsh/workspace/f$index.txt", "x".repeat(60)))
        }
        val before = segmentNames(paths)
        assertTrue("the roll must have produced several segments", before.size >= 2)
        val bytes = walSize(paths)

        // No epoch ever closed: nothing is listed and no epoch is durable, so
        // no segment satisfies §9 even at an absurdly small limit.
        val outcome = WalQuota(log, limitBytes = 1L).enforce()
        assertTrue("$outcome", outcome is QuotaOutcome.Exceeded)
        outcome as QuotaOutcome.Exceeded
        assertEquals(1L, outcome.limit)
        assertEquals(bytes, outcome.bytes)
        assertTrue(outcome.bytes > outcome.limit)
        assertTrue("nothing may be dropped", outcome.dropped.isEmpty())
        assertEquals("every segment file is still on disk", before, segmentNames(paths))
    }

    @Test
    fun anAppendThatCannotFitFailsWithAStableCodeAndSpendsNoMseq() = runBlocking {
        val root = temporary.newFolder("write-path").toPath()
        val paths = WalPaths(root)
        // Two 116-byte records fit under 300 bytes; the third would reach 388.
        val log = newLog(root, RecordingDurability(root), limitBytes = 300L)
        assertTrue(log.recover() is RecoveryOutcome.Recovered)
        assertEquals(
            1L,
            log.appendMutation(writeMutation("/dsh/workspace/a.txt", "a".repeat(60))).mseq,
        )
        assertEquals(
            2L,
            log.appendMutation(writeMutation("/dsh/workspace/b.txt", "b".repeat(60))).mseq,
        )
        assertEquals(3L, log.nextMseq)

        val sizesBefore = segmentSizes(paths)
        val bytesBefore = walSize(paths)

        var failure: LogException? = null
        try {
            log.appendMutation(writeMutation("/dsh/workspace/c.txt", "c".repeat(60)))
        } catch (error: LogException) {
            failure = error
        }
        assertNotNull("an append above the quota must fail loud", failure)
        val quotaFailure = failure ?: error("unreachable")
        assertEquals(LogFailure.QUOTA_EXCEEDED, quotaFailure.failure)
        assertEquals("WAL_QUOTA_EXCEEDED", quotaFailure.failure.code)

        // No half record, no spent mseq, no materialized side effect.
        assertEquals(3L, log.nextMseq)
        assertEquals(bytesBefore, walSize(paths))
        assertEquals(sizesBefore, segmentSizes(paths))
        assertFalse(Files.exists(paths.materialized("/dsh/workspace/c.txt")))

        // Admission stays closed with the same stable code.
        var again: LogException? = null
        try {
            log.appendMutation(writeMutation("/dsh/workspace/d.txt", "d"))
        } catch (error: LogException) {
            again = error
        }
        assertEquals(LogFailure.QUOTA_EXCEEDED, (again ?: error("unreachable")).failure)
    }

    @Test
    fun aRealRollingWalCompactsAndRecoversEveryMaterializedFile() = runBlocking {
        val root = temporary.newFolder("scale").toPath()
        val paths = WalPaths(root)
        val limit = 24L * 1024L
        val log = newLog(root, RecordingDurability(root), rollBytes = 4096, limitBytes = limit)
        assertTrue(log.recover() is RecoveryOutcome.Recovered)

        val expected = LinkedHashMap<String, String>()
        val totals = ArrayList<Long>()
        val seen = LinkedHashSet<WalSegmentName>()
        var index = 0
        repeat(10) {
            repeat(20) {
                val path = "/dsh/workspace/file-$index.txt"
                val text = "record-$index:" + "x".repeat(180)
                assertEquals(index + 1L, log.appendMutation(writeMutation(path, text)).mseq)
                expected[path] = text
                index++
                totals += walSize(paths)
                seen += segmentNames(paths)
                assertTrue(
                    "append ${index - 1} left the WAL at ${totals.last()} > $limit",
                    totals.last() <= limit,
                )
            }
            log.closeEpoch()
        }

        // Compaction really ran: segments that existed earlier are gone, and the
        // WAL shrank between two appends while appends kept succeeding.
        val finalNames = segmentNames(paths).toSet()
        val dropped = seen - finalNames
        assertFalse("no segment was ever compacted", dropped.isEmpty())
        assertTrue(
            "the WAL never shrank between two appends",
            totals.zipWithNext().any { (before, after) -> after < before },
        )

        // The proof that compaction lost nothing: a cold recovery over the same
        // root still materializes every file, although the segments that once
        // held their records are unlinked.
        val reopened = newLog(
            root,
            RecordingDurability(root),
            bootId = BootId.random(),
            rollBytes = 4096,
            limitBytes = limit,
        )
        val outcome = reopened.recover()
        assertTrue("$outcome", outcome is RecoveryOutcome.Recovered)
        outcome as RecoveryOutcome.Recovered
        assertEquals("the WAL tail must not shrink (D17)", log.lastMseq, outcome.effectiveTail)
        assertEquals(log.lastMseq + 1, outcome.nextMseq)
        assertEquals(log.materializedUptoMseq, outcome.materializedUptoMseq)
        for ((path, text) in expected) {
            assertEquals(path, text, materializedText(paths, path))
        }

        // A second compaction, now driven from the recovered in-memory state
        // (the summaries are rebuilt from disk, not from this process), then a
        // third cold recovery: the bytes still survive.
        repeat(10) {
            val path = "/dsh/workspace/file-$index.txt"
            val text = "record-$index:" + "x".repeat(180)
            assertEquals(index + 1L, reopened.appendMutation(writeMutation(path, text)).mseq)
            expected[path] = text
            index++
        }
        reopened.closeEpoch()
        val second = WalQuota(reopened, limitBytes = 1L).enforce()
        assertTrue("$second", second is QuotaOutcome.Exceeded)
        second as QuotaOutcome.Exceeded
        assertFalse("the recovered state must still compact", second.dropped.isEmpty())

        val third = newLog(
            root,
            RecordingDurability(root),
            bootId = BootId.random(),
            rollBytes = 4096,
            limitBytes = limit,
        )
        val thirdOutcome = third.recover()
        assertTrue("$thirdOutcome", thirdOutcome is RecoveryOutcome.Recovered)
        assertEquals(reopened.lastMseq, (thirdOutcome as RecoveryOutcome.Recovered).effectiveTail)
        for ((path, text) in expected) {
            assertEquals(path, text, materializedText(paths, path))
        }
    }

    @Test
    fun everyConditionOfTheDroppableRuleIsNecessary() {
        val name = WalSegmentName(2, 1)
        val open = WalSegmentName(3, 0)
        val olderClose = WalSegmentName(1, 0)

        fun droppable(
            openSegment: WalSegmentName? = open,
            newestClose: WalSegmentName? = olderClose,
            listedLastMseq: Long? = 5L,
            durableEpoch: Int = 2,
            watermark: Long = 5L,
        ): Boolean = DroppableRule.isDroppable(
            name = name,
            openSegment = openSegment,
            newestEpochCloseSegment = newestClose,
            listedLastMseq = listedLastMseq,
            durableEpoch = durableEpoch,
            watermark = watermark,
        )

        assertTrue("every condition holds", droppable())
        // Condition 1: every mutation at or below the watermark.
        assertFalse("a mutation above the watermark", droppable(listedLastMseq = 6L))
        // Condition 2: its epoch is durable and listed.
        assertFalse("an unlisted segment", droppable(listedLastMseq = null))
        assertFalse("an epoch above last_durable_epoch", droppable(durableEpoch = 1))
        // "Never droppable": the open epoch and the newest epoch-close segment.
        assertFalse("the open epoch", droppable(openSegment = name))
        assertFalse("the newest epoch-close segment", droppable(newestClose = name))

        // Condition 1's record-level half: a close record is not a mutation.
        val close = WorkspaceLog.SegmentRecordRef(mseq = 0L, path = null, isMutation = false)
        assertTrue(DroppableRule.everyMutationAtOrBelow(listOf(close), watermark = 0L))
        val above = WorkspaceLog.SegmentRecordRef(
            mseq = 6L,
            path = "/dsh/workspace/x.txt",
            isMutation = true,
        )
        assertFalse(DroppableRule.everyMutationAtOrBelow(listOf(close, above), watermark = 5L))
    }

    // ---- helpers ------------------------------------------------------------

    /** The segment names present in `wal/`, in `<epoch,segment>` order. */
    private fun segmentNames(paths: WalPaths): List<WalSegmentName> =
        segmentFiles(paths).mapNotNull { WalSegmentName.parse(it.fileName.toString()) }.sorted()

    /** The WAL's size in bytes: every segment file, header included. */
    private fun walSize(paths: WalPaths): Long = segmentSizes(paths).values.sum()

    /** The size of every segment file, keyed by name. */
    private fun segmentSizes(paths: WalPaths): Map<WalSegmentName, Long> =
        segmentFiles(paths).associate { file ->
            WalSegmentName.parse(file.fileName.toString())!! to Files.size(file)
        }

    /**
     * A [Durability] that performs the real file work and records every SPI
     * call together with a snapshot of the `wal/` state **at that moment**.
     *
     * `unlink` has no SPI event, so the snapshot is what proves the §9 order:
     * the shorter manifest is durable while the segment file still exists, and
     * the file is gone before `wal/` is fsynced.
     */
    private class CompactionProbe(
        private val root: Path,
        private val dropped: WalSegmentName,
    ) : Durability {
        /** One recorded call plus the on-disk evidence at that moment. */
        data class Step(
            val event: String,
            val hasSegment: Boolean,
            val manifestListsSegment: Boolean,
        )

        private val history = ArrayList<Step>()

        val steps: List<Step>
            get() = history.toList()

        val events: List<String>
            get() = history.map { it.event }

        fun clear() {
            history.clear()
        }

        override fun level(): DurabilityLevel = DurabilityLevel.LEVEL_2_POWER_LOSS_UNVERIFIED

        override suspend fun fsyncPath(path: Path) {
            record("fsync:" + label(path))
        }

        override suspend fun atomicReplace(target: Path, write: (Path) -> Unit) {
            val absolute = target.toAbsolutePath().normalize()
            val parent = absolute.parent
                ?: throw IllegalArgumentException("target has no parent directory: $target")
            Files.createDirectories(parent)
            val temporary = Files.createTempFile(parent, ".${absolute.fileName}.", ".tmp")
            var published = false
            try {
                write(temporary)
                Files.move(
                    temporary,
                    absolute,
                    StandardCopyOption.ATOMIC_MOVE,
                    StandardCopyOption.REPLACE_EXISTING,
                )
                published = true
            } finally {
                if (!published) {
                    Files.deleteIfExists(temporary)
                }
            }
            record("atomicReplace:" + label(absolute))
        }

        private fun record(event: String) {
            val segment = root.resolve("wal").resolve(dropped.fileName)
            val manifest = root.resolve("manifest.json")
            val lists = Files.isRegularFile(manifest) &&
                String(Files.readAllBytes(manifest), Charsets.UTF_8)
                    .contains(dropped.manifestFile)
            history += Step(
                event = event,
                hasSegment = Files.isRegularFile(segment),
                manifestListsSegment = lists,
            )
        }

        private fun label(path: Path): String {
            val base = root.toAbsolutePath().normalize()
            val absolute = path.toAbsolutePath().normalize()
            if (absolute == base) return "."
            return try {
                base.relativize(absolute).toString()
            } catch (_: IllegalArgumentException) {
                path.fileName?.toString() ?: "?"
            }
        }
    }
}
