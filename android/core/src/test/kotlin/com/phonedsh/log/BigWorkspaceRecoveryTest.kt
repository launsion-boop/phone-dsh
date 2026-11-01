// P19: a contract-legal 128 MiB workspace recovers without loading the WAL.
// SPDX-License-Identifier: MIT

package com.phonedsh.log

import com.phonedsh.wire.WalException
import java.nio.file.Files
import java.nio.file.Path
import java.nio.file.Paths
import java.security.MessageDigest
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

/**
 * The P19 shape: `budgets.md` §4 allows one 128 MiB file on the 8 GiB row and
 * `channel.md` §3.1 splits it into one complete write plus appended suffixes of
 * at most 15 MiB each, so a boot finds nine 15 MiB records in nine segments.
 *
 * Recovery used to decode every retained segment into a `List<WalRecord>` and
 * then ask `NativeWal.records` for a `data_hex` JSON string, so the ninth
 * 15 MiB record's parse died in `AbstractStringBuilder` with
 * `OutOfMemoryError` on a 2 GiB AVD (growth limit 192 MiB) after ~23 s of GC
 * thrash — on **every** boot, with the workspace's only copy in the WAL.
 *
 * These tests pin the two contracts the fix restores:
 *
 * 1. a 128 MiB workspace recovers and materializes every byte, and recovery
 *    does not retain the bodies of the records it replayed;
 * 2. a record above the 15 MiB mutation bound is refused with a code
 *    (`WAL_RECORD_TOO_LARGE`), never with an `OutOfMemoryError`.
 */
class BigWorkspaceRecoveryTest {
    @get:Rule
    val temporary = TemporaryFolder()

    private val chunkBytes = 15 * 1024 * 1024
    private val totalBytes = 128 * 1024 * 1024

    @Test
    fun a128MiBFileWrittenAsNineMutationsRecoversWithBoundedBodies() = runBlocking {
        val root = temporary.newFolder("big-workspace").toPath()
        val paths = WalPaths(root)
        val expectedDigest = writeBigWorkspace(root)

        // The copy the write path produced is the expected 128 MiB file.
        val materialized = paths.materialized("/dsh/workspace/big.bin")
        assertEquals(totalBytes.toLong(), Files.size(materialized))
        assertEquals(expectedDigest, digestOf(materialized))

        val reopened = newLog(root, RecordingDurability(root), bootId = BootId.random())
        val outcome = reopened.recover()
        assertTrue("a 128 MiB workspace must recover: $outcome", outcome is RecoveryOutcome.Recovered)
        outcome as RecoveryOutcome.Recovered

        // Nine mutations plus the epoch-close record were verified and every
        // byte is still there.
        assertEquals(10, outcome.recordCount)
        assertEquals(9, outcome.segments.size)
        assertEquals(9L, outcome.effectiveTail)
        assertEquals(10L, outcome.nextMseq)
        assertEquals(9L, outcome.materializedUptoMseq)
        assertEquals(totalBytes.toLong(), Files.size(materialized))
        assertEquals(expectedDigest, digestOf(materialized))
        assertTrue("the recovery must not report a divergence", outcome.stale.isEmpty())

        // The diagnostic record list is bounded, not the WAL size: this is the
        // assertion that fails if recovery starts retaining every body again.
        val retainedBytes = outcome.records
            .filterIsInstance<WalRecord.Mutation>()
            .sumOf { it.body.data.size }
        assertTrue(
            "recovery retained $retainedBytes mutation bytes; the budget is " +
                WorkspaceLog.RETAINED_RECORD_BYTES,
            retainedBytes <= WorkspaceLog.RETAINED_RECORD_BYTES,
        )
        assertEquals(
            "the nine epoch-close records are always retained for HostWal",
            1,
            outcome.records.filterIsInstance<WalRecord.EpochClose>().size,
        )
    }

    /**
     * The device condition, as a test: the same workspace recovered inside a
     * 128 MiB heap. The old implementation could not: nine 15 MiB bodies are
     * 128 MiB before the hex/JSON copies, which is why the 2 GiB AVD (192 MiB
     * growth limit) died on every boot. A child JVM makes the bound real
     * instead of a peak-heap assertion that depends on when the GC ran.
     */
    @Test
    fun the128MiBWorkspaceRecoversInsideA128MiBHeap() = runBlocking {
        val root = temporary.newFolder("small-heap").toPath()
        writeBigWorkspace(root)
        val java = Paths.get(System.getProperty("java.home"), "bin", "java").toString()
        val process = ProcessBuilder(
            java,
            "-Xmx128m",
            "-XX:+UseSerialGC",
            "-Djava.library.path=" + System.getProperty("java.library.path"),
            "-cp",
            System.getProperty("java.class.path"),
            "com.phonedsh.log.RecoveryInSmallHeap",
            root.toString(),
        ).redirectErrorStream(true).start()
        val output = process.inputStream.bufferedReader().readText()
        val exit = process.waitFor()
        assertEquals(
            "the 128 MiB workspace must recover inside a 128 MiB heap; child output:\n$output",
            0,
            exit,
        )
        assertTrue(
            "the child must report the recovered tail; output:\n$output",
            output.contains("RECOVERED next_mseq=10 acked=9 records=10"),
        )
    }

    @Test
    fun aRecordAboveTheMutationBoundFailsLoudInsteadOfAllocatingIt() = runBlocking {
        val root = temporary.newFolder("oversize-record").toPath()
        val paths = WalPaths(root)
        // The write path refuses to create this record now, so forge it with the
        // codec: 16 MiB of data is one byte above channel.md §3.1's 15 MiB.
        val oversized = MutationBody(
            op = VfsOp.WRITE,
            mode = 420,
            path = "/dsh/workspace/huge.bin",
            data = ByteArray(16 * 1024 * 1024),
            entryChanged = true,
        )
        val name = WalSegmentName(1, 0)
        Files.createDirectories(paths.walDirectory)
        Files.write(
            paths.segment(name),
            WalSegmentHeader(firstMseq = 1, bootId = TEST_BOOT_ID).encode() +
                WalRecordCodec.encodeMutation(1, oversized),
        )

        val log = newLog(root, RecordingDurability(root), bootId = BootId.random())
        val outcome = log.recover()
        assertTrue("an over-bound record must fail loud: $outcome", outcome is RecoveryOutcome.Failed)
        outcome as RecoveryOutcome.Failed
        assertEquals("WAL_RECORD_TOO_LARGE", outcome.code)
        assertTrue(
            "the refusal must name the 15 MiB bound and the spec: ${outcome.detail}",
            outcome.detail.contains("15728640") && outcome.detail.contains("channel.md §3.1"),
        )
    }

    @Test
    fun aHoleInsideOneSegmentIsWalCorruptNotASilentStop() = runBlocking {
        val root = temporary.newFolder("mseq-hole").toPath()
        val paths = WalPaths(root)
        Files.createDirectories(paths.walDirectory)
        // The old `NativeWal.records` path validated the mseq chain; the
        // streaming reader does not re-implement that check, so the kernel's
        // `chain_error` verdict must make the plan fail. A silent stop at the
        // gap would leave a record above the watermark unapplied.
        val frame1 = WalRecordCodec.encodeMutation(1, writeMutation("/dsh/workspace/a.txt", "a"))
        val frame3 = WalRecordCodec.encodeMutation(3, writeMutation("/dsh/workspace/b.txt", "b"))
        Files.write(
            paths.segment(WalSegmentName(1, 0)),
            WalSegmentHeader(firstMseq = 1, bootId = TEST_BOOT_ID).encode() + frame1 + frame3,
        )
        val outcome = newLog(root, RecordingDurability(root), bootId = BootId.random()).recover()
        assertTrue("a mseq hole must fail loud: $outcome", outcome is RecoveryOutcome.Failed)
        assertEquals("WAL_CORRUPT", (outcome as RecoveryOutcome.Failed).code)
    }

    @Test
    fun aDeclaredLengthAboveTheBoundIsRefusedBeforeTheAllocation() {
        val root = temporary.newFolder("lying-length").toPath()
        val paths = WalPaths(root)
        Files.createDirectories(paths.walDirectory)
        val name = WalSegmentName(1, 0)
        // The file is far below MAX_SEGMENT_BYTES, so the scan's size guard does
        // not catch it; the declared payload length (20 MiB) does. The reader
        // must throw before `ByteArray(20 MiB)` — the point is to refuse, not to
        // allocate and hope.
        val prefix = java.nio.ByteBuffer.allocate(8)
            .putInt(20 * 1024 * 1024)
            .putInt(0)
            .array()
        Files.write(
            paths.segment(name),
            WalSegmentHeader(firstMseq = 1, bootId = TEST_BOOT_ID).encode() +
                prefix + ByteArray(16),
        )
        val failure = assertThrows(WalException::class.java) {
            WalSegmentReader.open(paths, name).use { reader -> reader.forEachRecord { } }
        }
        assertEquals("WAL_RECORD_TOO_LARGE", failure.code)
    }

    @Test
    fun theWritePathRefusesDataAboveTheMutationBound() = runBlocking {
        val root = temporary.newFolder("append-refusal").toPath()
        val log = newLog(root, RecordingDurability(root))
        assertTrue(log.recover() is RecoveryOutcome.Recovered)
        val before = log.nextMseq
        val failure = runCatching {
            log.appendMutation(
                MutationBody(
                    op = VfsOp.WRITE,
                    mode = 420,
                    path = "/dsh/workspace/big.bin",
                    data = ByteArray(15 * 1024 * 1024 + 1),
                    entryChanged = true,
                ),
            )
        }.exceptionOrNull()
        assertTrue("expected a BAD_PAYLOAD refusal, got $failure", failure is WalException)
        assertEquals("BAD_PAYLOAD", (failure as WalException).code)
        assertEquals("a refused append spends no mseq", before, log.nextMseq)
        assertFalse(Files.exists(log.paths.materialized("/dsh/workspace/big.bin")))
    }

    private fun digestOf(path: java.nio.file.Path): String {
        val digest = MessageDigest.getInstance("SHA-256")
        Files.newInputStream(path).use { stream ->
            val buffer = ByteArray(64 * 1024)
            while (true) {
                val read = stream.read(buffer)
                if (read < 0) break
                digest.update(buffer, 0, read)
            }
        }
        return digest.digest().joinToString("") { "%02x".format(it) }
    }

    /**
     * Writes the contract-legal 128 MiB file as one complete write plus eight
     * appended suffixes (channel.md §3.1) and closes the epoch.
     *
     * @return the SHA-256 of the bytes the WAL must recover.
     */
    private fun writeBigWorkspace(root: Path): String {
        val first = newLog(root, RecordingDurability(root))
        assertTrue(
            "the empty workspace must recover before the write",
            runBlocking { first.recover() } is RecoveryOutcome.Recovered,
        )
        val expected = MessageDigest.getInstance("SHA-256")
        var offset = 0
        var mseq = 0L
        while (offset < totalBytes) {
            val length = minOf(chunkBytes, totalBytes - offset)
            val chunk = ByteArray(length) { index -> ((offset + index) % 251).toByte() }
            expected.update(chunk)
            val body = MutationBody(
                op = VfsOp.WRITE,
                mode = 420,
                path = "/dsh/workspace/big.bin",
                data = chunk,
                appended = offset != 0,
                appendFrom = offset.toLong(),
                entryChanged = offset == 0,
            )
            mseq += 1
            assertEquals(mseq, runBlocking { first.appendMutation(body) }.mseq)
            offset += length
        }
        assertEquals(9L, mseq)
        val digest = expected.digest().joinToString("") { "%02x".format(it) }
        runBlocking { first.closeEpoch() }
        assertEquals(
            "the write path must materialize the whole file",
            totalBytes.toLong(),
            Files.size(WalPaths(root).materialized("/dsh/workspace/big.bin")),
        )
        return digest
    }
}
