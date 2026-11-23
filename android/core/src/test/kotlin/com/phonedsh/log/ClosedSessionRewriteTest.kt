// SPDX-License-Identifier: MIT
package com.phonedsh.log

import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.nio.file.Files

class ClosedSessionRewriteTest {
    @get:Rule val temp = TemporaryFolder()

    @Test fun interruptedSuffixIsRecoveredWithoutRestoringErasedBytes() = runBlocking {
        val root = temp.newFolder().toPath().toRealPath()
        val log = newLog(root, RecordingDurability(root))
        log.recover()
        val path = "/dsh/home/sessions/archive/qa/session.v2.jsonl"
        log.appendMutation(writeMutation(path, "original marker and surviving messages"))
        log.closeEpoch()
        val file = log.paths.materialized(path)
        val clean = "tombstone\nsurviving messages\n".toByteArray()
        // Stop between the complete write and appended suffix, as if the process died.
        PendingSessionWrites(log).prepare(ClosedSessionRewrite.FileChange(file, ClosedSessionRewrite.digest(file), clean))
        log.appendMutation(writeMutation(path, "tombstone\n"))
        val reopened = newLog(root, RecordingDurability(root))
        assertTrue(reopened.recover() is RecoveryOutcome.Recovered)
        val writer = ClosedSessionRewrite(reopened)
        assertTrue(writer.recoverPending())
        assertArrayEquals(clean, Files.readAllBytes(file))
        assertFalse(writer.hasPending)
        assertFalse(writer.recoverPending())
    }

    @Test fun divergentFileIsNeverOverwrittenByAnInterruptedRewrite() = runBlocking {
        val root = temp.newFolder().toPath().toRealPath()
        val log = newLog(root, RecordingDurability(root))
        log.recover()
        val path = "/dsh/home/sessions/archive/qa/session.v2.jsonl"
        log.appendMutation(writeMutation(path, "prior value"))
        val file = log.paths.materialized(path)
        PendingSessionWrites(log).prepare(ClosedSessionRewrite.FileChange(file, ClosedSessionRewrite.digest(file), "clean".toByteArray()))
        log.appendMutation(writeMutation(path, "different content"))
        val writer = ClosedSessionRewrite(log)
        assertTrue(runCatching { writer.recoverPending() }.isFailure)
        assertEquals("different content", materializedText(log.paths, path))
        assertTrue(writer.hasPending)
    }

    @Test fun rewriteRemovesEarlierGenerationsAndWalBytesAndRecoversTheSurvivor() = runBlocking {
        val root = temp.newFolder().toPath().toRealPath()
        val log = newLog(root, RecordingDurability(root))
        log.recover()
        val prefix = "/dsh/home/sessions/archived/qa-session/"
        val marker = "UNIQUE-MEMORY-ERASURE-TEST"
        val survivor = """{"type":"assistant/message","seq":2,"data":{"text":"retained"}}"""
        val tombstone = """{"type":"phone-dsh/session-erasure","seq":1,"time":1,"ignorable":true,"data":{"erased":true,"erasureId":"test","record":"record://session/qa-session#1"}}"""
        val source = """{"type":"user/message","seq":1,"time":1,"data":{"text":"$marker"}}""" + "\n" + survivor + "\n"
        for (v in 1..2) log.appendMutation(writeMutation(prefix + "session.v$v.jsonl", source))
        log.closeEpoch()
        val cache = root.resolve("boot-overlay").resolve("old.tar")
        Files.createDirectories(cache.parent)
        Files.write(cache, marker.toByteArray())
        val latest = log.paths.materialized(prefix + "session.v2.jsonl")
        val older = log.paths.materialized(prefix + "session.v1.jsonl")
        val clean = "$tombstone\n$survivor\n"
        val changes = listOf(
            ClosedSessionRewrite.FileChange(latest, ClosedSessionRewrite.digest(latest), clean.toByteArray()),
            ClosedSessionRewrite.FileChange(older, ClosedSessionRewrite.digest(older), null),
        )
        ClosedSessionRewrite(log).apply(changes, setOf("qa-session"))
        assertFalse(Files.exists(older))
        assertFalse(Files.exists(cache))
        assertTrue(segmentFiles(log.paths).all { marker !in Files.readAllBytes(it).toString(Charsets.ISO_8859_1) })
        val reopened = newLog(root, RecordingDurability(root))
        assertTrue(reopened.recover() is RecoveryOutcome.Recovered)
        assertEquals(clean, materializedText(reopened.paths, prefix + "session.v2.jsonl"))
        assertFalse(Files.exists(older))
    }
}
