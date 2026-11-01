// D18: the epoch-close fsync order, observed through the Durability SPI.
// SPDX-License-Identifier: MIT

package com.phonedsh.log

import com.phonedsh.wire.NativeWal
import com.phonedsh.wire.WalJsonParser
import com.phonedsh.wire.arrayItems
import com.phonedsh.wire.member
import com.phonedsh.wire.numberValue
import com.phonedsh.wire.stringValue
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

/**
 * Proves the one order D18 fixes, using a [RecordingDurability] that records
 * every SPI call. The assertion is an **exact event list**, not a set: a close
 * that fsyncs the right paths in the wrong order fails here.
 */
class EpochCloseOrderTest {
    @get:Rule
    val temporary = TemporaryFolder()

    @Test
    fun closeEpochRunsTheD18Order() = runBlocking {
        val root = temporary.root.toPath()
        val durability = RecordingDurability(root)
        // A 100-byte roll limit forces one segment per record, so step 3 must
        // fsync every segment of the epoch rather than a single lucky one.
        val log = newLog(root, durability, rollBytes = 100)
        assertTrue(log.recover() is RecoveryOutcome.Recovered)

        assertEquals(1L, log.appendMutation(writeMutation("/dsh/workspace/notes.txt", "hello\n")).mseq)
        assertEquals(2L, log.appendMutation(writeMutation("/dsh/workspace/sub/a.txt", "a")).mseq)
        assertEquals(3L, log.appendMutation(chmodMutation("/dsh/workspace/notes.txt", 384)).mseq)

        durability.clear()
        val close = log.closeEpoch()

        assertEquals(
            listOf(
                // 1. every materialized file and changed directory, deepest first
                "fsync:materialized/workspace/sub/a.txt",
                "fsync:materialized/workspace/notes.txt",
                "fsync:materialized/workspace/sub",
                "fsync:materialized/workspace",
                // 2. the close record was appended to the third segment
                // 3. every segment written in this epoch
                "fsync:wal/00000001.000000.xlwal",
                "fsync:wal/00000001.000001.xlwal",
                "fsync:wal/00000001.000002.xlwal",
                // 4. the wal/ directory
                "fsync:wal",
                // 5. the manifest atomically, then its directory
                "atomicReplace:manifest.json",
                "fsync:.",
            ),
            durability.events,
        )

        // The same order as phase predicates over the typed calls, so a future
        // extra event cannot make the exact-list assertion pass by accident.
        val calls = durability.calls
        val materializedFsyncs = calls.withIndex().filter { (_, call) ->
            call is RecordingDurability.Call.Fsync &&
                call.path.startsWith(root.toAbsolutePath().normalize().resolve("materialized"))
        }
        val lastMaterialized = materializedFsyncs.maxOf { it.index }
        val segmentFsyncs = calls.withIndex().filter { (_, call) ->
            call is RecordingDurability.Call.Fsync &&
                call.path.parent == root.toAbsolutePath().normalize().resolve("wal")
        }
        val firstSegment = segmentFsyncs.minOf { it.index }
        val lastSegment = segmentFsyncs.maxOf { it.index }
        val walDirectoryIndex = calls.indexOfFirst {
            it is RecordingDurability.Call.Fsync && it.path == root.toAbsolutePath().normalize().resolve("wal")
        }
        val manifestIndex = calls.indexOfFirst {
            it is RecordingDurability.Call.AtomicReplace &&
                it.target == root.toAbsolutePath().normalize().resolve("manifest.json")
        }
        val manifestDirectoryIndex = calls.indexOfLast {
            it is RecordingDurability.Call.Fsync && it.path == root.toAbsolutePath().normalize()
        }
        assertEquals("every segment of the epoch is fsynced", 3, segmentFsyncs.size)
        assertTrue("materialized copy before WAL", lastMaterialized < firstSegment)
        assertTrue("segments before the wal directory", lastSegment < walDirectoryIndex)
        assertTrue("wal directory before the manifest", walDirectoryIndex < manifestIndex)
        assertTrue("manifest before its directory fsync", manifestIndex < manifestDirectoryIndex)

        // Deepest-first inside phase 1: relative depth must not increase.
        val depths = materializedFsyncs.map { (_, call) ->
            root.relativize((call as RecordingDurability.Call.Fsync).path).nameCount
        }
        assertEquals(depths.sortedDescending(), depths)

        // Level 2 is only returned after the whole order ran, and the close
        // record carries durable_upto = 3 in the last segment.
        assertEquals(AckLevel.LEVEL_2, close.level)
        assertEquals(3L, close.durableUpto)
        assertEquals(3, log.materializedUptoMseq)
        assertEquals(3, close.segments.size)
        assertEquals(listOf("notes.txt", "sub", "sub/a.txt"), materializedTree(root))

        val closeSegment = close.segments.single { it.segment == 2 }
        val records = WalJsonParser.parse(
            NativeWal.records(segmentBytes(WalPaths(root), closeSegment)),
        ).arrayItems()
        val closeRecord = records.last()
        assertEquals("epoch_close", closeRecord.member("kind").stringValue())
        assertEquals(3L, closeRecord.member("durable_upto").numberValue())
        assertEquals(3L, closeRecord.member("mseq").numberValue())
    }

    @Test
    fun idleEpochCreatesACloseOnlySegment() = runBlocking {
        val root = temporary.root.toPath()
        val durability = RecordingDurability(root)
        val log = newLog(root, durability)
        assertTrue(log.recover() is RecoveryOutcome.Recovered)
        assertEquals(1L, log.appendMutation(writeMutation("/dsh/workspace/a.txt", "a")).mseq)
        log.closeEpoch()

        durability.clear()
        // No mutation after the close: the idle epoch keeps
        // first_mseq = durable_upto + 1 and writes only the close record
        // (wal.md §2/§4, golden/wal/segment-epoch-only.json).
        val idle = log.closeEpoch()
        val segment = idle.segments.single { it.epoch == 2 }
        val header = WalSegmentHeader.decode(segmentBytes(WalPaths(root), segment))
        assertEquals(2L, header.firstMseq)
        assertEquals(1L, idle.durableUpto)

        val records = WalJsonParser.parse(
            NativeWal.records(segmentBytes(WalPaths(root), segment)),
        ).arrayItems()
        assertEquals(1, records.size)
        assertEquals("epoch_close", records.single().member("kind").stringValue())
        assertEquals(1L, records.single().member("mseq").numberValue())
    }

    private fun materializedTree(root: java.nio.file.Path): List<String> {
        val materialized = root.resolve("materialized/workspace")
        return java.nio.file.Files.walk(materialized).use { stream ->
            stream
                .filter { java.nio.file.Files.isRegularFile(it) || java.nio.file.Files.isDirectory(it) }
                .map { materialized.relativize(it).toString() }
                .filter { it.isNotEmpty() }
                .sorted()
                .toList()
        }
    }
}
