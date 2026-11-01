// D19: a torn tail is truncated and logged; a non-tail failure is WAL_CORRUPT.
// SPDX-License-Identifier: MIT

package com.phonedsh.log

import java.nio.file.Files
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class RecoveryTailTest {
    @get:Rule
    val temporary = TemporaryFolder()

    @Test
    fun tornTailIsTruncatedToTheLastCompleteRecordWithoutError() = runBlocking {
        val root = temporary.newFolder("torn").toPath()
        val paths = WalPaths(root)
        val first = newLog(root, RecordingDurability(root))
        assertTrue(first.recover() is RecoveryOutcome.Recovered)
        repeat(3) { index ->
            first.appendMutation(writeMutation("/dsh/workspace/f$index.txt", "x"))
        }
        first.closeEpoch()
        // Epoch 2 segment 0: two unclosed mutations, then the last record's
        // tail bytes are cut away (the power-loss shape D19 describes).
        assertEquals(4L, first.appendMutation(writeMutation("/dsh/workspace/g0.txt", "g0")).mseq)
        assertEquals(5L, first.appendMutation(writeMutation("/dsh/workspace/g1.txt", "g1")).mseq)
        val epochTwo = WalSegmentName(2, 0)
        val original = segmentBytes(paths, epochTwo)
        val lastRecordStart = recordStarts(original).last()
        tearTail(paths.segment(epochTwo), 5)
        val tornLength = Files.size(paths.segment(epochTwo))
        assertTrue("the fixture must really tear the last record", tornLength > lastRecordStart)

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

        val truncation = outcome.truncated.single()
        assertEquals(epochTwo, truncation.segment)
        assertEquals("truncate to the last complete record", lastRecordStart.toLong(), truncation.keepLen)
        assertEquals(tornLength - lastRecordStart, truncation.droppedBytes)
        assertEquals(lastRecordStart.toLong(), Files.size(paths.segment(epochTwo)))

        val logged = events.filterIsInstance<WalLogEvent.TruncatedTail>().single()
        assertEquals(epochTwo, logged.segment)
        assertEquals(lastRecordStart.toLong(), logged.keepLen)
        assertEquals(tornLength - lastRecordStart, logged.droppedBytes)
        assertEquals(tornLength, logged.previousLength)

        // Record 4 survived; record 5 never became durable and is not reported
        // as corrupt. wal.md §7.2 defines next_mseq from the verified tail.
        assertEquals(4L, outcome.records.filterIsInstance<WalRecord.Mutation>().maxOf { it.mseq })
        assertEquals(4L, outcome.effectiveTail)
        assertEquals(5L, outcome.nextMseq)
        assertEquals("g0", materializedText(paths, "/dsh/workspace/g0.txt"))
        // The live process materialized g1 before the tear; the WAL no longer
        // proves it, but the derived copy is not an input and is left alone.
        assertEquals("g1", materializedText(paths, "/dsh/workspace/g1.txt"))

        // The log is writable again and allocates the lost mseq 5 afresh: it
        // was never durable, so no acknowledged record is overwritten.
        assertEquals(5L, reopened.appendMutation(writeMutation("/dsh/workspace/g1.txt", "g1")).mseq)
    }

    @Test
    fun nonTailCrcFailureIsCorruptAndNeverTruncates() = runBlocking {
        val root = temporary.newFolder("corrupt").toPath()
        val paths = WalPaths(root)
        val first = newLog(root, RecordingDurability(root))
        assertTrue(first.recover() is RecoveryOutcome.Recovered)
        repeat(3) { index ->
            first.appendMutation(writeMutation("/dsh/workspace/f$index.txt", "x"))
        }
        val segment = segmentFiles(paths).single()
        val bytes = Files.readAllBytes(segment)
        // File offset 56 = header 40 + len 4 + crc 4 + mseq 8: the first body
        // byte of record 1, covered by its CRC32C. Records 2 and 3 after it are
        // complete, so this is not the tail.
        bytes[56] = (bytes[56].toInt() xor 0xFF).toByte()
        Files.write(segment, bytes)
        val before = Files.size(segment)

        val reopened = newLog(root, RecordingDurability(root), bootId = BootId.random())
        val outcome = reopened.recover()
        assertTrue("a non-tail CRC failure must fail loud: $outcome", outcome is RecoveryOutcome.Failed)
        outcome as RecoveryOutcome.Failed
        assertEquals("WAL_CORRUPT", outcome.code)
        assertEquals("no byte may be dropped", before, Files.size(segment))
        assertTrue(
            "the detail names the segment: ${outcome.detail}",
            outcome.detail.contains(segment.fileName.toString()),
        )

        val error = assertThrows(LogException::class.java) {
            runBlocking {
                reopened.appendMutation(writeMutation("/dsh/workspace/late.txt", "late"))
            }
        }
        assertEquals(LogFailure.NOT_READY, error.failure)
    }

    @Test
    fun aListedNewestSegmentMayBeShorterThanItsRecordedRange() = runBlocking {
        // wal.md §7.2 "manifest range versus file range": a listed segment may
        // hold fewer records than segments[] records for it only when it is the
        // newest segment, recovery truncated it under D19, and the recorded
        // range is at or below the watermark.
        val root = temporary.newFolder("short-listed").toPath()
        val paths = WalPaths(root)
        val first = newLog(root, RecordingDurability(root))
        assertTrue(first.recover() is RecoveryOutcome.Recovered)
        repeat(3) { index ->
            first.appendMutation(writeMutation("/dsh/workspace/f$index.txt", "x"))
        }
        first.closeEpoch()
        first.appendMutation(writeMutation("/dsh/workspace/g0.txt", "g0"))
        first.appendMutation(writeMutation("/dsh/workspace/g1.txt", "g1"))
        first.closeEpoch()
        assertEquals(2, segmentFiles(paths).size)
        val manifest = readManifest(paths)
        assertEquals(5L, manifest.lastMseq)
        assertEquals(5L, manifest.materializedUptoMseq)

        // The pathological shape the rule defends against: the newest file lost
        // the tail of its last mutation record (and the close record behind it),
        // while the durable manifest already recorded mutation 5.
        val newest = WalSegmentName(2, 0)
        val original = segmentBytes(paths, newest)
        val starts = recordStarts(original)
        val mutationFiveStart = starts[1]
        val closeStart = starts[2]
        val torn = original.copyOfRange(0, closeStart).copyOf(closeStart - 5)
        Files.write(paths.segment(newest), torn)
        val tornLength = Files.size(paths.segment(newest))
        assertTrue(tornLength > mutationFiveStart)

        val reopened = newLog(root, RecordingDurability(root), bootId = BootId.random())
        val outcome = reopened.recover()
        assertTrue("$outcome", outcome is RecoveryOutcome.Recovered)
        outcome as RecoveryOutcome.Recovered
        assertEquals(mutationFiveStart.toLong(), outcome.truncated.single().keepLen)
        assertEquals(tornLength - mutationFiveStart, outcome.truncated.single().droppedBytes)
        assertEquals(4L, outcome.records.filterIsInstance<WalRecord.Mutation>().maxOf { it.mseq })
        // D17: last_mseq never decreases, so the recorded 5 is not lowered even
        // though the record is gone; next_mseq stays 6.
        assertEquals(5L, outcome.effectiveTail)
        assertEquals(6L, outcome.nextMseq)
        assertEquals(5L, outcome.materializedUptoMseq)
        assertTrue(outcome.manifestRewritten)
        val rewritten = readManifest(paths)
        assertEquals(5L, rewritten.lastMseq)
        assertEquals(4L, rewritten.segments.single { it.name == newest }.lastMseq)
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
