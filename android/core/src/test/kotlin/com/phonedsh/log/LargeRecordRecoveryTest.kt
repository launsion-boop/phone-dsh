// A torn large record is a D19 tail tear, not WAL_CORRUPT.
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
 * The large-record recovery shapes.
 *
 * A mutation may carry up to 15 MiB of data (`channel.md` §3.1), so one legal
 * record can be far larger than the WAL kernel's 4 MiB fallback CRC budget. A
 * process killed inside such a record leaves a valid header plus a prefix of
 * the record: `wal.md` §10 defines that as a torn tail to truncate, but the
 * budget-based tail search used to call it `WAL_CORRUPT`. That turned every
 * killed big-file turn into a permanently unreadable workspace.
 */
class LargeRecordRecoveryTest {
    @get:Rule
    val temporary = TemporaryFolder()

    @Test
    fun aTornLargeRecordIsATailTearNotCorruption() = runBlocking {
        val root = temporary.newFolder("torn-big").toPath()
        val paths = WalPaths(root)
        val first = newLog(root, RecordingDurability(root))
        assertTrue(first.recover() is RecoveryOutcome.Recovered)
        val big = ByteArray(9 * 1024 * 1024) { (it % 251).toByte() }
        assertEquals(
            1L,
            first.appendMutation(
                MutationBody(
                    op = VfsOp.WRITE,
                    mode = 420,
                    path = "/dsh/workspace/big.bin",
                    data = big,
                    entryChanged = true,
                ),
            ).mseq,
        )
        val segment = segmentFiles(paths).single()
        // Simulate a kill in the middle of the one large record: keep the header and
        // the first part of the body, drop the rest.
        tearTail(segment, 5 * 1024 * 1024)
        val tornLength = Files.size(segment)
        assertTrue(tornLength > WalSegmentHeader.BYTES)

        val reopened = newLog(root, RecordingDurability(root), bootId = BootId.random())
        val outcome = reopened.recover()
        assertTrue(
            "a torn large record is a D19 tail tear, not WAL_CORRUPT: $outcome",
            outcome is RecoveryOutcome.Recovered,
        )
        outcome as RecoveryOutcome.Recovered
        assertEquals(WalSegmentHeader.BYTES.toLong(), outcome.truncated.single().keepLen)
        assertEquals(tornLength - WalSegmentHeader.BYTES, outcome.truncated.single().droppedBytes)
        assertEquals(0L, outcome.effectiveTail)
        assertEquals(1L, outcome.nextMseq)
    }

    @Test
    fun aCompleteLargeWriteAndRemoveStillRecovers() = runBlocking {
        val root = temporary.newFolder("big-clean").toPath()
        val paths = WalPaths(root)
        val first = newLog(root, RecordingDurability(root))
        assertTrue(first.recover() is RecoveryOutcome.Recovered)
        val big = ByteArray(9 * 1024 * 1024) { (it % 251).toByte() }
        assertEquals(
            1L,
            first.appendMutation(
                MutationBody(
                    op = VfsOp.WRITE,
                    mode = 420,
                    path = "/dsh/workspace/big.bin",
                    data = big,
                    entryChanged = true,
                ),
            ).mseq,
        )
        assertEquals(2L, first.appendMutation(removeMutation("/dsh/workspace/big.bin")).mseq)
        first.closeEpoch()
        assertFalse(Files.exists(paths.materialized("/dsh/workspace/big.bin")))

        val reopened = newLog(root, RecordingDurability(root), bootId = BootId.random())
        val outcome = reopened.recover()
        assertTrue("a large write+remove must recover after a clean restart: $outcome", outcome is RecoveryOutcome.Recovered)
        outcome as RecoveryOutcome.Recovered
        assertEquals(2L, outcome.effectiveTail)
        assertEquals(3L, outcome.nextMseq)
    }
}
