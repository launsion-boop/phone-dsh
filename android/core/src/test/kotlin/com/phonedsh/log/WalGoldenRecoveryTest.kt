// The two WAL golden vectors through the real recover(): file bytes to records.
// SPDX-License-Identifier: MIT

package com.phonedsh.log

import com.phonedsh.wire.WalGoldenCorpus
import com.phonedsh.wire.WalGoldenVector
import com.phonedsh.wire.bytesToHex
import com.phonedsh.wire.hexToBytes
import com.phonedsh.wire.numberValue
import com.phonedsh.wire.objectMembers
import com.phonedsh.wire.stringValue
import java.nio.file.Files
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

/**
 * `spec/v1/golden/wal/<name>.json` through the full recovery path: the golden
 * `file_hex` becomes a real `wal/` segment on disk, a matching §7 checkpoint is
 * written, and `recover()` must decode exactly the golden `records[]` sequence.
 *
 * The checkpoint mirrors what a host that received these segments would hold:
 * every golden mutation is at or below the watermark, so recovery reads them
 * without replaying them onto an empty copy (the golden's first mseq is 42, so
 * the copy could not be rebuilt from the WAL in any case).
 */
class WalGoldenRecoveryTest {
    @get:Rule
    val temporary = TemporaryFolder()

    @Test
    fun segmentOneDecodesTheGoldenSequence() = runBlocking {
        val vector = WalGoldenCorpus.load().single { it.name == "segment-1.json" }
        val outcome = recoverGolden(
            vector = vector,
            directory = "golden-segment-1",
            epoch = 1,
            manifest = { segment ->
                Manifest(
                    lastMseq = 46,
                    segments = listOf(
                        ManifestSegment.of(segment, firstMseq = 42, lastMseq = 46),
                    ),
                    lastDurableEpoch = 1,
                    bootId = TEST_BOOT_ID,
                    materializedUptoMseq = 46,
                )
            },
        )
        assertEquals(6, outcome.records.size)
        assertEquals(47L, outcome.nextMseq)
        assertEquals(46L, outcome.effectiveTail)
        assertFalse(outcome.manifestRewritten)
        assertTrue(outcome.truncated.isEmpty())
    }

    @Test
    fun epochOnlyDecodesTheIdleClose() = runBlocking {
        val vector = WalGoldenCorpus.load().single { it.name == "segment-epoch-only.json" }
        val outcome = recoverGolden(
            vector = vector,
            directory = "golden-epoch-only",
            epoch = 1,
            manifest = { segment ->
                Manifest(
                    lastMseq = 87,
                    segments = listOf(
                        // first_mseq 88, no mutation: the idle-epoch case of §2.
                        ManifestSegment.of(segment, firstMseq = 88, lastMseq = 0),
                    ),
                    lastDurableEpoch = 1,
                    bootId = TEST_BOOT_ID,
                    materializedUptoMseq = 87,
                )
            },
        )
        assertEquals(1, outcome.records.size)
        val close = outcome.records.single() as WalRecord.EpochClose
        assertEquals(87L, close.durableUpto)
        assertEquals(87L, close.mseq)
        assertEquals(1_792_800_060_000L, close.wallMs)
        // The idle close does not advance the mutation tail: next_mseq is 88,
        // exactly the segment's first_mseq, even though durable_upto is 87.
        assertEquals(88L, outcome.nextMseq)
        assertEquals(2, outcome.nextEpoch)
        assertFalse(outcome.manifestRewritten)
    }

    private fun recoverGolden(
        vector: WalGoldenVector,
        directory: String,
        epoch: Int,
        manifest: (WalSegmentName) -> Manifest,
    ): RecoveryOutcome.Recovered = runBlocking {
        val root = temporary.newFolder(directory).toPath()
        val paths = WalPaths(root)
        val name = WalSegmentName(epoch, 0)
        Files.createDirectories(paths.walDirectory)
        Files.write(paths.segment(name), hexToBytes(vector.fileHex))
        Files.write(paths.manifestFile, manifest(name).encode())

        val log = newLog(root, RecordingDurability(root), bootId = BootId.random())
        val outcome = log.recover()
        assertTrue("$outcome", outcome is RecoveryOutcome.Recovered)
        outcome as RecoveryOutcome.Recovered
        assertGoldenRecords(vector, outcome)
        outcome
    }

    private fun assertGoldenRecords(vector: WalGoldenVector, outcome: RecoveryOutcome.Recovered) {
        assertEquals("${vector.name}: record count", vector.records.size, outcome.records.size)
        assertEquals(
            "${vector.name}: the metadata count is the true record count",
            vector.records.size,
            outcome.recordCount,
        )
        vector.records.forEachIndexed { index, golden ->
            val expected = golden.objectMembers()
            val expectedFields = expected.getValue("fields").objectMembers()
            val actual = outcome.records[index]
            val label = "${vector.name} record $index"

            assertEquals(
                "$label kind",
                expected.getValue("kind").stringValue(),
                when (actual) {
                    is WalRecord.Mutation -> "mutation"
                    is WalRecord.EpochClose -> "epoch_close"
                },
            )
            assertEquals(
                "$label mseq",
                expectedFields.getValue("mseq").numberValue(),
                actual.mseq,
            )
            when (actual) {
                is WalRecord.Mutation -> {
                    val body = actual.body
                    assertEquals("$label op", expectedFields.getValue("op").numberValue().toInt(), body.op.code)
                    assertEquals("$label mode", expectedFields.getValue("mode").numberValue().toInt(), body.mode)
                    assertEquals(
                        "$label mflags",
                        expectedFields.getValue("mflags").numberValue().toInt(),
                        body.mflags,
                    )
                    assertEquals(
                        "$label append_from",
                        expectedFields.getValue("append_from").numberValue(),
                        body.appendFrom,
                    )
                    assertEquals("$label path", expectedFields.getValue("path").stringValue(), body.path)
                    assertEquals(
                        "$label data_hex",
                        expectedFields.getValue("data_hex").stringValue(),
                        bytesToHex(body.data),
                    )
                }
                is WalRecord.EpochClose -> {
                    assertEquals(
                        "$label wall_ms",
                        expectedFields.getValue("wall_ms").numberValue(),
                        actual.wallMs,
                    )
                    assertEquals(
                        "$label durable_upto",
                        expectedFields.getValue("durable_upto").numberValue(),
                        actual.durableUpto,
                    )
                }
            }
        }
    }
}
