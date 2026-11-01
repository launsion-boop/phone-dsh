// Missing versus unknown manifest members, and the missing-manifest rule in recovery.
// SPDX-License-Identifier: MIT

package com.phonedsh.log

import java.nio.file.Files
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class ManifestRecoveryTest {
    @get:Rule
    val temporary = TemporaryFolder()

    @Test
    fun unknownMemberIsNotAMissingManifest() = runBlocking {
        val root = temporary.newFolder("unknown-member").toPath()
        val paths = WalPaths(root)
        val first = newLog(root, RecordingDurability(root))
        assertTrue(first.recover() is RecoveryOutcome.Recovered)
        assertEquals(1L, first.appendMutation(writeMutation("/dsh/workspace/a.txt", "a")).mseq)
        assertEquals(2L, first.appendMutation(writeMutation("/dsh/workspace/b.txt", "b")).mseq)
        first.closeEpoch()

        val manifest = readManifest(paths)
        val withUnknown = manifest.toJson()
            .replaceFirst("{\"boot_id\"", "{\"future_member\":{\"x\":1},\"boot_id\"")
            .replaceFirst("\"epoch\":", "\"future_segment_member\":true,\"epoch\":")
        Files.write(paths.manifestFile, withUnknown.toByteArray())
        assertNotEquals(manifest.toJson(), String(Files.readAllBytes(paths.manifestFile)))

        val reopened = newLog(root, RecordingDurability(root), bootId = BootId.random())
        val outcome = reopened.recover()
        assertTrue("$outcome", outcome is RecoveryOutcome.Recovered)
        outcome as RecoveryOutcome.Recovered
        assertFalse("an unknown member must not trigger a rewrite", outcome.manifestRewritten)
        assertFalse("an unknown member must not trigger a reconcile", outcome.fullReconcile)
        assertEquals(3L, outcome.nextMseq)
        assertEquals(2L, readManifest(paths).lastMseq)
        assertEquals(1, outcome.segments.size)
    }

    @Test
    fun missingRequiredMemberFollowsTheMissingManifestRule() = runBlocking {
        val root = temporary.newFolder("missing-member").toPath()
        val paths = WalPaths(root)
        val first = newLog(root, RecordingDurability(root))
        assertTrue(first.recover() is RecoveryOutcome.Recovered)
        assertEquals(1L, first.appendMutation(writeMutation("/dsh/workspace/notes.txt", "hello\n")).mseq)
        first.closeEpoch()

        // A schema-invalid manifest is "missing" for §7.2. The WAL starts at
        // mseq 1, so recovery rebuilds the copy from the empty tree.
        Files.write(paths.manifestFile, """{"format":1}""".toByteArray())
        Files.delete(paths.materialized("/dsh/workspace/notes.txt"))

        val reopened = newLog(root, RecordingDurability(root), bootId = BootId.random())
        val outcome = reopened.recover()
        assertTrue("$outcome", outcome is RecoveryOutcome.Recovered)
        outcome as RecoveryOutcome.Recovered
        assertTrue("the missing-manifest rebuild is the staged reconcile", outcome.fullReconcile)
        assertTrue(outcome.manifestRewritten)
        assertEquals(2L, outcome.nextMseq)
        assertEquals(1L, outcome.materializedUptoMseq)
        assertEquals("hello\n", materializedText(paths, "/dsh/workspace/notes.txt"))

        val rewritten = readManifest(paths)
        assertEquals(1L, rewritten.lastMseq)
        assertEquals(1L, rewritten.materializedUptoMseq)
        assertEquals(1, rewritten.segments.size)
        assertFalse("the marker is deleted after the exchange", Files.exists(paths.reconcileMarker))
        assertFalse(Files.exists(paths.stagingDirectory))
    }

    @Test
    fun outOfRangeKnownMemberIsAlsoMissing() = runBlocking {
        val root = temporary.newFolder("out-of-range").toPath()
        val paths = WalPaths(root)
        val first = newLog(root, RecordingDurability(root))
        assertTrue(first.recover() is RecoveryOutcome.Recovered)
        assertEquals(1L, first.appendMutation(writeMutation("/dsh/workspace/a.txt", "a")).mseq)
        first.closeEpoch()

        val manifest = readManifest(paths)
        val outOfRange = manifest.toJson()
            .replace("\"last_durable_epoch\":1", "\"last_durable_epoch\":100000000")
        Files.write(paths.manifestFile, outOfRange.toByteArray())
        Files.delete(paths.materialized("/dsh/workspace/a.txt"))

        val reopened = newLog(root, RecordingDurability(root), bootId = BootId.random())
        val outcome = reopened.recover()
        assertTrue("$outcome", outcome is RecoveryOutcome.Recovered)
        outcome as RecoveryOutcome.Recovered
        assertTrue(outcome.fullReconcile)
        assertEquals("a", materializedText(paths, "/dsh/workspace/a.txt"))
        assertEquals(1, readManifest(paths).segments.size)
    }

    @Test
    fun aContentCopyWithoutAnyHistoryIsNotANewWorkspace() = runBlocking {
        val root = temporary.newFolder("orphan-copy").toPath()
        val paths = WalPaths(root)
        val first = newLog(root, RecordingDurability(root))
        assertTrue(first.recover() is RecoveryOutcome.Recovered)
        assertEquals(1L, first.appendMutation(writeMutation("/dsh/workspace/a.txt", "a")).mseq)
        first.closeEpoch()

        // Both authorities are gone but the applied tree remains: this is not a
        // new workspace, and adopting it would leave unverifiable history.
        Files.delete(paths.manifestFile)
        segmentFiles(paths).forEach { Files.delete(it) }

        val reopened = newLog(root, RecordingDurability(root), bootId = BootId.random())
        val outcome = reopened.recover()
        assertTrue("$outcome", outcome is RecoveryOutcome.Failed)
        assertEquals("WAL_CORRUPT", (outcome as RecoveryOutcome.Failed).code)
        assertTrue(Files.exists(paths.materialized("/dsh/workspace/a.txt")))
    }

    @Test
    fun impossibleCheckpointFailsLoudInsteadOfRebuilding() = runBlocking {
        val root = temporary.newFolder("impossible").toPath()
        val paths = WalPaths(root)
        val first = newLog(root, RecordingDurability(root))
        assertTrue(first.recover() is RecoveryOutcome.Recovered)
        assertEquals(1L, first.appendMutation(writeMutation("/dsh/workspace/a.txt", "a")).mseq)
        first.closeEpoch()

        // Schema-valid values, impossible checkpoint: the watermark is above
        // last_mseq. This is WAL_CORRUPT, not the missing-manifest rule.
        val impossible = readManifest(paths).toJson()
            .replace("\"materialized_upto_mseq\":1", "\"materialized_upto_mseq\":2")
        Files.write(paths.manifestFile, impossible.toByteArray())

        val reopened = newLog(root, RecordingDurability(root), bootId = BootId.random())
        val outcome = reopened.recover()
        assertTrue("$outcome", outcome is RecoveryOutcome.Failed)
        assertEquals("WAL_CORRUPT", (outcome as RecoveryOutcome.Failed).code)
        assertTrue("the invalid checkpoint is left for inspection", Files.exists(paths.manifestFile))
    }
}
