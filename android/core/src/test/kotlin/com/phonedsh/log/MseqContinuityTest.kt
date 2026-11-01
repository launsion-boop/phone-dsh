// D17: mseq is strictly consecutive and never reused.
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

class MseqContinuityTest {
    @get:Rule
    val temporary = TemporaryFolder()

    @Test
    fun mseqIsConsecutiveAndSurvivesAReopen() = runBlocking {
        val root = temporary.newFolder("reopen").toPath()
        val paths = WalPaths(root)
        val first = newLog(root, RecordingDurability(root))
        assertTrue(first.recover() is RecoveryOutcome.Recovered)

        assertEquals(1L, first.appendMutation(writeMutation("/dsh/workspace/a.txt", "a")).mseq)
        assertEquals(2L, first.appendMutation(writeMutation("/dsh/workspace/b.txt", "b")).mseq)
        assertEquals(3L, first.appendMutation(writeMutation("/dsh/workspace/c.txt", "c")).mseq)
        assertEquals(4L, first.nextMseq)
        assertEquals(3L, first.closeEpoch().durableUpto)
        assertEquals(3L, readManifest(paths).lastMseq)

        // A new process boot: no memory is trusted, next_mseq comes from the
        // checkpoint and the WAL tail (D17, wal.md §10 step 4).
        val second = newLog(root, RecordingDurability(root), bootId = BootId.random())
        val outcome = second.recover()
        assertTrue("$outcome", outcome is RecoveryOutcome.Recovered)
        assertEquals(4L, (outcome as RecoveryOutcome.Recovered).nextMseq)
        assertEquals(4L, second.nextMseq)
        assertEquals(3L, second.materializedUptoMseq)

        assertEquals(4L, second.appendMutation(writeMutation("/dsh/workspace/d.txt", "d")).mseq)
        assertEquals(5L, second.nextMseq)
        second.closeEpoch()
        assertEquals(4L, readManifest(paths).lastMseq)
    }

    @Test
    fun d17DoesNotLowerLastMseqAfterACompactionBelowTheTail() = runBlocking {
        val root = temporary.newFolder("compacted").toPath()
        val paths = WalPaths(root)
        val log = newLog(root, RecordingDurability(root))
        assertTrue(log.recover() is RecoveryOutcome.Recovered)
        assertEquals(1L, log.appendMutation(writeMutation("/dsh/workspace/a.txt", "a")).mseq)
        assertEquals(2L, log.appendMutation(writeMutation("/dsh/workspace/b.txt", "b")).mseq)
        assertEquals(3L, log.appendMutation(writeMutation("/dsh/workspace/c.txt", "c")).mseq)
        log.closeEpoch()

        // Simulate §9 compaction: the durable manifest no longer lists the
        // segment and the file is gone, so the WAL tail is 0 while last_mseq is
        // 3. D17 requires next_mseq 4, never 1.
        val manifest = readManifest(paths)
        Files.write(paths.manifestFile, manifest.copy(segments = emptyList()).encode())
        segmentFiles(paths).forEach { Files.delete(it) }

        val reopened = newLog(root, RecordingDurability(root), bootId = BootId.random())
        val outcome = reopened.recover()
        assertTrue("$outcome", outcome is RecoveryOutcome.Recovered)
        outcome as RecoveryOutcome.Recovered
        assertEquals(3L, outcome.effectiveTail)
        assertEquals(4L, outcome.nextMseq)
        assertEquals(2, outcome.nextEpoch)
        assertFalse(outcome.manifestRewritten)
        assertEquals(4L, reopened.appendMutation(writeMutation("/dsh/workspace/d.txt", "d")).mseq)
    }

    @Test
    fun d17AdoptsAnUnlistedEpochThatSpansTwoSegments() = runBlocking {
        val root = temporary.newFolder("multi-segment-adopt").toPath()
        val paths = WalPaths(root)
        val first = newLog(root, RecordingDurability(root))
        assertTrue(first.recover() is RecoveryOutcome.Recovered)
        repeat(6) { index ->
            first.appendMutation(writeMutation("/dsh/workspace/a$index.txt", "a")).mseq
        }
        first.closeEpoch()
        assertEquals(6L, readManifest(paths).lastMseq)

        // The next epoch opens and rolls once: the unlisted tail is 519..550 +
        // 551..582 in epoch 8 terms, here 7..8 and 9..10, with the manifest
        // still at last_mseq 6. The second segment starts above watermark + 1
        // but exactly at the first segment's end: this is one legal adopted tail,
        // not a gap.
        val second = newLog(
            root,
            RecordingDurability(root),
            bootId = BootId.random(),
            rollBytes = 200,
        )
        assertTrue(second.recover() is RecoveryOutcome.Recovered)
        assertEquals(7L, second.appendMutation(writeMutation("/dsh/workspace/b0.txt", "b")).mseq)
        assertEquals(8L, second.appendMutation(writeMutation("/dsh/workspace/b1.txt", "b")).mseq)
        assertEquals(9L, second.appendMutation(writeMutation("/dsh/workspace/b2.txt", "b")).mseq)
        assertEquals(10L, second.appendMutation(writeMutation("/dsh/workspace/b3.txt", "b")).mseq)
        assertEquals(
            listOf("00000002.000000.xlwal", "00000002.000001.xlwal"),
            segmentFiles(paths)
                .map { it.fileName.toString() }
                .filter { it.startsWith("00000002.") },
        )
        assertEquals(6L, readManifest(paths).lastMseq)

        val reopened = newLog(root, RecordingDurability(root), bootId = BootId.random())
        val outcome = reopened.recover()
        assertTrue("a multi-segment adopted epoch must recover: $outcome", outcome is RecoveryOutcome.Recovered)
        outcome as RecoveryOutcome.Recovered
        assertEquals(10L, outcome.effectiveTail)
        assertEquals(11L, outcome.nextMseq)
        assertEquals(
            listOf(WalSegmentName(2, 0), WalSegmentName(2, 1)),
            outcome.adopted,
        )
        assertEquals(10L, readManifest(paths).lastMseq)
        assertEquals("b", materializedText(paths, "/dsh/workspace/b3.txt"))
        assertEquals(11L, reopened.appendMutation(writeMutation("/dsh/workspace/c.txt", "c")).mseq)
    }

    @Test
    fun d17AdoptsTheWalTailAboveALaggingManifest() = runBlocking {
        val root = temporary.newFolder("lagging").toPath()
        val paths = WalPaths(root)
        val log = newLog(root, RecordingDurability(root))
        assertTrue(log.recover() is RecoveryOutcome.Recovered)
        assertEquals(1L, log.appendMutation(writeMutation("/dsh/workspace/a.txt", "a")).mseq)
        assertEquals(2L, log.appendMutation(writeMutation("/dsh/workspace/b.txt", "b")).mseq)
        assertEquals(3L, log.appendMutation(writeMutation("/dsh/workspace/c.txt", "c")).mseq)
        log.closeEpoch()
        // The tail continues in a new epoch that never closed: the manifest
        // still says last_mseq 3.
        assertEquals(4L, log.appendMutation(writeMutation("/dsh/workspace/d.txt", "d")).mseq)
        assertEquals(5L, log.appendMutation(writeMutation("/dsh/workspace/e.txt", "e")).mseq)
        assertEquals(3L, readManifest(paths).lastMseq)

        val reopened = newLog(root, RecordingDurability(root), bootId = BootId.random())
        val outcome = reopened.recover()
        assertTrue("$outcome", outcome is RecoveryOutcome.Recovered)
        outcome as RecoveryOutcome.Recovered
        assertEquals(5L, outcome.effectiveTail)
        assertEquals(6L, outcome.nextMseq)
        assertTrue(
            "the unlisted tail is adopted: ${outcome.adopted}",
            outcome.adopted.contains(WalSegmentName(2, 0)),
        )
        assertEquals(5L, readManifest(paths).lastMseq)
        assertEquals("d", materializedText(paths, "/dsh/workspace/d.txt"))
        assertEquals(6L, reopened.appendMutation(writeMutation("/dsh/workspace/f.txt", "f")).mseq)
    }
}
