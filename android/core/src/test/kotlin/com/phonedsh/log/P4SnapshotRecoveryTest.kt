// Temporary evidence harness: full recovery on P4's real bricked workspace.
// SPDX-License-Identifier: MIT

package com.phonedsh.log

import java.nio.file.Files
import java.nio.file.Path
import java.nio.file.StandardCopyOption
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assume
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

/**
 * Full recovery over P4's real bricked workspace (`/tmp/p4/snap`, 233 KiB).
 *
 * The snapshot is external evidence, not a committed fixture; the test is
 * skipped unless `PDSH_P4_SNAPSHOT` names the extracted directory. Run it with
 * `PDSH_P4_SNAPSHOT=/tmp/p4/snap ./gradlew :core:test --tests ...`.
 *
 * Stage 1 rebuilds the materialized copy at 518 from the listed segments (the
 * snapshot carries `wal/` and `manifest.json` only). Stage 2 restores the two
 * unlisted epoch-8 segments and proves the multi-segment adopted tail recovers.
 */
class P4SnapshotRecoveryTest {
    @get:Rule
    val temporary = TemporaryFolder()

    @Test
    fun p4SnapshotRecoversWithBothAdoptedSegments() = runBlocking {
        val sourceText = System.getenv("PDSH_P4_SNAPSHOT")
        Assume.assumeTrue("set PDSH_P4_SNAPSHOT to the extracted P4 snapshot", sourceText != null)
        val source = Path.of(sourceText!!)
        val root = temporary.newFolder("p4").toPath()
        val wal = root.resolve("wal")
        Files.createDirectories(wal)
        Files.list(source.resolve("wal")).use { stream ->
            stream.forEach { path ->
                Files.copy(path, wal.resolve(path.fileName.toString()), StandardCopyOption.REPLACE_EXISTING)
            }
        }
        // Stage 1: rebuild the materialized copy at 518 from the listed segments.
        val held = temporary.newFolder("held").toPath()
        val epochEight = Files.list(wal).use { stream ->
            stream.filter { it.fileName.toString().startsWith("00000008.") }.toList()
        }
        for (path in epochEight) {
            Files.move(path, held.resolve(path.fileName.toString()))
        }
        Files.deleteIfExists(root.resolve("manifest.json"))
        val first = newLog(root, RecordingDurability(root), bootId = BootId.random())
        val rebuilt = first.recover()
        assertTrue("P4 listed history rebuilds: $rebuilt", rebuilt is RecoveryOutcome.Recovered)
        rebuilt as RecoveryOutcome.Recovered
        assertEquals(518L, rebuilt.materializedUptoMseq)

        // Stage 2: the unlisted epoch 8 is back; both of its segments are adopted.
        for (path in epochEight) {
            Files.move(
                held.resolve(path.fileName.toString()),
                wal.resolve(path.fileName.toString()),
                StandardCopyOption.REPLACE_EXISTING,
            )
        }
        val second = newLog(root, RecordingDurability(root), bootId = BootId.random())
        val outcome = second.recover()
        assertTrue("P4 snapshot must recover: $outcome", outcome is RecoveryOutcome.Recovered)
        outcome as RecoveryOutcome.Recovered
        println(
            "P4 RECOVERED: next_mseq=${outcome.nextMseq} acked_mseq=${outcome.effectiveTail} " +
                "materialized=${outcome.materializedUptoMseq} adopted=${outcome.adopted}",
        )
        assertEquals(583L, outcome.nextMseq)
        assertEquals(582L, outcome.effectiveTail)
        assertEquals(582L, outcome.materializedUptoMseq)
        assertEquals(listOf(WalSegmentName(8, 0), WalSegmentName(8, 1)), outcome.adopted)
    }
}
