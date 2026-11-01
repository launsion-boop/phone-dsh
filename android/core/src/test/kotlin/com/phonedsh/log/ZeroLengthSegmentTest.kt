// BUG-1: a zero-length segment has no header and no record; it is dropped, not WAL_CORRUPT.
// SPDX-License-Identifier: MIT

package com.phonedsh.log

import java.nio.file.Files
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

/**
 * The three-way classification of `wal.md` §7.2/§10 step 1:
 *
 * 1. length 0 (no header, no record) → dropped with a diagnostic;
 * 2. a complete header whose record region is torn at the tail → truncated and logged;
 * 3. a non-zero file whose header is damaged → still `WAL_CORRUPT` → `Failed`.
 *
 * The P6 measurement (`docs/receipts/android-p6-kill-matrix-2026-11-01.md`, A7) left two
 * zero-length segments after `adb emu kill`; before this fix they made the whole workspace
 * permanently unreadable even though every byte of the retained prefix was intact.
 */
class ZeroLengthSegmentTest {
    @get:Rule
    val temporary = TemporaryFolder()

    @Test
    fun twoZeroLengthSegmentsAreDroppedAndThePrefixRecovers() = runBlocking {
        val root = temporary.newFolder("zero-length").toPath()
        val paths = WalPaths(root)
        val first = newLog(root, RecordingDurability(root))
        assertTrue(first.recover() is RecoveryOutcome.Recovered)
        assertEquals(1L, first.appendMutation(writeMutation("/dsh/workspace/a.txt", "a")).mseq)
        first.closeEpoch()

        // The A7 shape: files whose dirent survived a crash but whose 40-byte header never
        // reached the file. They are not listed in the manifest and hold no record.
        val emptyA = WalSegmentName(9, 0)
        val emptyB = WalSegmentName(9, 1)
        Files.write(paths.segment(emptyA), ByteArray(0))
        Files.write(paths.segment(emptyB), ByteArray(0))

        val events = mutableListOf<WalLogEvent>()
        val reopened = newLog(
            root,
            RecordingDurability(root),
            bootId = BootId.random(),
            sink = WalLogSink { events += it },
        )
        val outcome = reopened.recover()
        assertTrue("a zero-length segment must not brick the workspace: $outcome", outcome is RecoveryOutcome.Recovered)
        outcome as RecoveryOutcome.Recovered

        assertEquals(listOf(emptyA, emptyB), outcome.droppedEmpty)
        assertEquals("the prefix is still replayable", 1L, outcome.effectiveTail)
        assertEquals(2L, outcome.nextMseq)
        assertEquals("a", materializedText(paths, "/dsh/workspace/a.txt"))
        assertFalse("the empty file is unlinked", Files.exists(paths.segment(emptyA)))
        assertFalse("the empty file is unlinked", Files.exists(paths.segment(emptyB)))

        val diagnostics = events.filterIsInstance<WalLogEvent.EmptySegmentDropped>()
        assertEquals(listOf(emptyA, emptyB), diagnostics.map { it.segment })
        assertTrue("both files were really removed: $diagnostics", diagnostics.all { it.removed })

        // The log is writable again at the recovered tail.
        assertEquals(2L, reopened.appendMutation(writeMutation("/dsh/workspace/b.txt", "b")).mseq)
        assertEquals("ab", materializedText(paths, "/dsh/workspace/a.txt") + materializedText(paths, "/dsh/workspace/b.txt"))
    }

    @Test
    fun anUnlistedValidTailAndZeroLengthSegmentsBothSurviveThePlan() = runBlocking {
        // The exact A7 durable shape: two acknowledged records in an unlisted open-epoch
        // segment, no epoch close (so the manifest still says last_mseq 0 / segments []),
        // then a crash leaves two zero-length segment files.
        val root = temporary.newFolder("unlisted-tail-plus-zero").toPath()
        val paths = WalPaths(root)
        val first = newLog(root, RecordingDurability(root))
        assertTrue(first.recover() is RecoveryOutcome.Recovered)
        assertEquals(1L, first.appendMutation(writeMutation("/dsh/workspace/a.txt", "a")).mseq)
        assertEquals(2L, first.appendMutation(writeMutation("/dsh/workspace/b.txt", "b")).mseq)
        assertEquals(0L, readManifest(paths).lastMseq)
        assertTrue(readManifest(paths).segments.isEmpty())

        val emptyA = WalSegmentName(2, 0)
        val emptyB = WalSegmentName(3, 0)
        Files.write(paths.segment(emptyA), ByteArray(0))
        Files.write(paths.segment(emptyB), ByteArray(0))

        val reopened = newLog(root, RecordingDurability(root), bootId = BootId.random())
        val outcome = reopened.recover()
        assertTrue("$outcome", outcome is RecoveryOutcome.Recovered)
        outcome as RecoveryOutcome.Recovered
        assertEquals(listOf(WalSegmentName(1, 0)), outcome.adopted)
        assertEquals(listOf(emptyA, emptyB), outcome.droppedEmpty)
        assertEquals(2L, outcome.effectiveTail)
        assertEquals(3L, outcome.nextMseq)
        assertEquals("a", materializedText(paths, "/dsh/workspace/a.txt"))
        assertEquals("b", materializedText(paths, "/dsh/workspace/b.txt"))
        assertFalse(Files.exists(paths.segment(emptyA)))
        assertFalse(Files.exists(paths.segment(emptyB)))
    }

    @Test
    fun aListedZeroLengthSegmentAboveTheWatermarkStillFailsLoud() = runBlocking {
        val root = temporary.newFolder("listed-zero").toPath()
        val paths = WalPaths(root)
        val first = newLog(root, RecordingDurability(root))
        assertTrue(first.recover() is RecoveryOutcome.Recovered)
        assertEquals(1L, first.appendMutation(writeMutation("/dsh/workspace/a.txt", "a")).mseq)
        first.closeEpoch()

        // The manifest says the segment held mutation 2 and the copy is only at 1: its bytes
        // are gone. This is not a crash-before-header artifact and must not be dropped.
        val ghost = WalSegmentName(9, 0)
        val manifest = readManifest(paths)
        Files.write(
            paths.manifestFile,
            manifest.copy(
                lastMseq = 2L,
                segments = manifest.segments + ManifestSegment.of(ghost, firstMseq = 2L, lastMseq = 2L),
            ).encode(),
        )
        Files.write(paths.segment(ghost), ByteArray(0))

        val reopened = newLog(root, RecordingDurability(root), bootId = BootId.random())
        val outcome = reopened.recover()
        assertTrue("a listed empty segment above the watermark is data loss: $outcome", outcome is RecoveryOutcome.Failed)
        outcome as RecoveryOutcome.Failed
        assertEquals("WAL_CORRUPT", outcome.code)
        assertTrue(
            "the detail names the listed segment: ${outcome.detail}",
            outcome.detail.contains(ghost.fileName),
        )
        assertTrue("nothing is unlinked on a failed recovery", Files.exists(paths.segment(ghost)))
    }

    @Test
    fun aPartialOrDamagedHeaderIsStillCorruptAndIsNeverTruncated() = runBlocking {
        val root = temporary.newFolder("damaged-header").toPath()
        val paths = WalPaths(root)
        val first = newLog(root, RecordingDurability(root))
        assertTrue(first.recover() is RecoveryOutcome.Recovered)
        assertEquals(1L, first.appendMutation(writeMutation("/dsh/workspace/a.txt", "a")).mseq)
        first.closeEpoch()

        // A complete 40-byte header whose magic is wrong: the header itself is damaged.
        // It must not be treated like the length-0 case even though nothing can be replayed.
        val damaged = WalSegmentName(9, 0)
        val header = WalSegmentHeader(firstMseq = 2L, bootId = TEST_BOOT_ID).encode()
        header[0] = 'Y'.code.toByte()
        Files.write(paths.segment(damaged), header)
        val before = Files.size(paths.segment(damaged))

        val reopened = newLog(root, RecordingDurability(root), bootId = BootId.random())
        val outcome = reopened.recover()
        assertTrue("header damage must stay fail-loud: $outcome", outcome is RecoveryOutcome.Failed)
        outcome as RecoveryOutcome.Failed
        assertEquals("WAL_CORRUPT", outcome.code)
        assertEquals("no byte is dropped from a damaged header", before, Files.size(paths.segment(damaged)))
        assertTrue(Files.exists(paths.segment(damaged)))
    }

    @Test
    fun aHeaderBearingTornTailIsTruncatedWhileAnEmptySegmentIsDropped() = runBlocking {
        val root = temporary.newFolder("torn-plus-empty").toPath()
        val paths = WalPaths(root)
        val first = newLog(root, RecordingDurability(root))
        assertTrue(first.recover() is RecoveryOutcome.Recovered)
        repeat(3) { index ->
            first.appendMutation(writeMutation("/dsh/workspace/f$index.txt", "x"))
        }
        first.closeEpoch()
        assertEquals(4L, first.appendMutation(writeMutation("/dsh/workspace/g0.txt", "g0")).mseq)
        assertEquals(5L, first.appendMutation(writeMutation("/dsh/workspace/g1.txt", "g1")).mseq)
        val epochTwo = WalSegmentName(2, 0)
        val original = segmentBytes(paths, epochTwo)
        val lastRecordStart = recordStarts(original).last()
        tearTail(paths.segment(epochTwo), 5)
        val tornLength = Files.size(paths.segment(epochTwo))
        assertTrue("the fixture must really tear the last record", tornLength > lastRecordStart)

        val empty = WalSegmentName(9, 0)
        Files.write(paths.segment(empty), ByteArray(0))

        val events = mutableListOf<WalLogEvent>()
        val reopened = newLog(
            root,
            RecordingDurability(root),
            bootId = BootId.random(),
            sink = WalLogSink { events += it },
        )
        val outcome = reopened.recover()
        assertTrue("$outcome", outcome is RecoveryOutcome.Recovered)
        outcome as RecoveryOutcome.Recovered

        // Rule 2 and rule 1 are independent: the torn tail is truncated to its last
        // complete record, and the empty segment is dropped, in one recovery.
        val truncation = outcome.truncated.single()
        assertEquals(epochTwo, truncation.segment)
        assertEquals(lastRecordStart.toLong(), truncation.keepLen)
        assertEquals(tornLength - lastRecordStart, truncation.droppedBytes)
        assertEquals(lastRecordStart.toLong(), Files.size(paths.segment(epochTwo)))
        assertEquals(listOf(empty), outcome.droppedEmpty)
        assertFalse(Files.exists(paths.segment(empty)))

        assertEquals(4L, outcome.records.filterIsInstance<WalRecord.Mutation>().maxOf { it.mseq })
        assertEquals(4L, outcome.effectiveTail)
        assertEquals(5L, outcome.nextMseq)
        assertEquals("g0", materializedText(paths, "/dsh/workspace/g0.txt"))
        assertEquals(2, events.count { it is WalLogEvent.TruncatedTail } + events.count { it is WalLogEvent.EmptySegmentDropped })
    }

    /** The file offsets of every complete record frame. */
    private fun recordStarts(segment: ByteArray): List<Int> {
        val starts = ArrayList<Int>()
        var offset = WalSegmentHeader.BYTES
        while (offset + 8 <= segment.size) {
            val length = java.nio.ByteBuffer.wrap(segment, offset, 4).int
            val frame = 8 + length
            if (length < 8 || offset + frame > segment.size) break
            starts.add(offset)
            offset += frame
        }
        return starts
    }
}
