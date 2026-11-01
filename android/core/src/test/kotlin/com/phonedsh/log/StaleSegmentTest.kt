// The revised wal.md §7.2 stale rule: retain, verify and re-list, never unlink.
// SPDX-License-Identifier: MIT

package com.phonedsh.log

import java.nio.file.Files
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class StaleSegmentTest {
    @get:Rule
    val temporary = TemporaryFolder()

    @Test
    fun staleSegmentIsRetainedVerifiedAndRelisted() = runBlocking {
        val root = temporary.newFolder("stale").toPath()
        val paths = WalPaths(root)
        val first = newLog(root, RecordingDurability(root))
        assertTrue(first.recover() is RecoveryOutcome.Recovered)
        // A complete write plus a D9 append: the stale verification must derive
        // the same bytes the live materializer wrote.
        assertEquals(1L, first.appendMutation(writeMutation("/dsh/workspace/notes.txt", "hello\n")).mseq)
        assertEquals(
            2L,
            first.appendMutation(appendedMutation("/dsh/workspace/notes.txt", 6, "world\n")).mseq,
        )
        first.closeEpoch()
        assertEquals("hello\nworld\n", materializedText(paths, "/dsh/workspace/notes.txt"))

        // A manifest that lags the WAL and forgets the segment: the G2-A09 shape.
        // The records are real and already applied; the file is the only
        // surviving history of two acknowledged writes.
        val manifest = readManifest(paths)
        assertEquals(2L, manifest.lastMseq)
        Files.write(paths.manifestFile, manifest.copy(segments = emptyList()).encode())
        val staleName = WalSegmentName(1, 0)

        val reopened = newLog(root, RecordingDurability(root), bootId = BootId.random())
        val outcome = reopened.recover()
        assertTrue("$outcome", outcome is RecoveryOutcome.Recovered)
        outcome as RecoveryOutcome.Recovered

        assertEquals(listOf(staleName), outcome.stale.map { it.name })
        val stale = outcome.stale.single()
        assertTrue(
            "the stale segment is verified against the materialized copy: " +
                "unprovable=${stale.unprovable} divergences=${stale.divergences}",
            stale.verified,
        )
        assertTrue(
            "a stale segment is retained, never unlinked (revised wal.md §7.2)",
            Files.exists(paths.segment(staleName)),
        )
        assertEquals("hello\nworld\n", materializedText(paths, "/dsh/workspace/notes.txt"))

        // §7.2: "retained and re-listed at the next manifest write". Recovery's
        // checkpoint write is that write because the segment list changed.
        assertTrue(outcome.manifestRewritten)
        val rewritten = readManifest(paths)
        assertEquals(
            listOf(ManifestSegment.of(staleName, firstMseq = 1, lastMseq = 2)),
            rewritten.segments,
        )
        assertEquals(2L, rewritten.lastMseq)
        assertEquals(2L, rewritten.materializedUptoMseq)
        assertEquals(1, rewritten.lastDurableEpoch)

        // The next epoch close lists it again: the file never lost its place.
        reopened.closeEpoch()
        assertTrue(readManifest(paths).segments.any { it.name == staleName })
        assertTrue(Files.exists(paths.segment(staleName)))
    }

    @Test
    fun anUnlistedHeaderOnlySegmentIsRetainedToo() = runBlocking {
        val root = temporary.newFolder("header-only").toPath()
        val paths = WalPaths(root)
        val first = newLog(root, RecordingDurability(root))
        assertTrue(first.recover() is RecoveryOutcome.Recovered)
        assertEquals(1L, first.appendMutation(writeMutation("/dsh/workspace/a.txt", "a")).mseq)
        first.closeEpoch()

        // A header-only segment is legal on disk (§1) and is never listed (§7).
        // It is "stale" in the plan (nothing above the watermark, no records),
        // and the revised rule still forbids unlinking it.
        val headerOnly = WalSegmentName(9, 3)
        val header = WalSegmentHeader(firstMseq = 99, bootId = TEST_BOOT_ID)
        Files.write(paths.segment(headerOnly), header.encode())

        val reopened = newLog(root, RecordingDurability(root), bootId = BootId.random())
        val outcome = reopened.recover()
        assertTrue("$outcome", outcome is RecoveryOutcome.Recovered)
        outcome as RecoveryOutcome.Recovered
        assertEquals(listOf(headerOnly), outcome.stale.map { it.name })
        assertTrue(Files.exists(paths.segment(headerOnly)))
        // A header-only segment is not content and is not listed in a rewrite.
        assertTrue(readManifest(paths).segments.none { it.name == headerOnly })
    }
}
