// SPDX-License-Identifier: MIT
// Diagnostics: only state/reason/gap are representable, and the file rotates at
// 256 KiB (design §5.3, PC-20261110-pclink-workspace-cache §2).
package com.phonedsh.probe.pc

import com.phonedsh.pclink.PclinkOfflineReason
import java.nio.file.Files
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class PcDiagnosticsLogTest {
    private fun directory() = Files.createTempDirectory("pclink-diag").toFile()

    @Test
    fun `a line carries only the state reason and gap`() {
        val directory = directory()
        val log = PcDiagnosticsLog(directory, clockMillis = { 1_700_000_000_000L })
        log.append(PcDiagnosticEvent("reconnecting", "peer_offline"))
        log.append(PcDiagnosticEvent("online", null, gapSeconds = 2.25))

        val lines = log.read()
        assertEquals(2, lines.size)
        assertEquals("2023-11-14T22:13:20Z state=reconnecting reason=peer_offline", lines[0])
        assertEquals("2023-11-14T22:13:20Z state=online gap=2.3s", lines[1])
        // The format has no title/message/key field, and the input type has no
        // way to smuggle one in.
        assertFalse(lines.joinToString("\n").contains("session"))
    }

    @Test
    fun `input tokens are folded to one safe token`() {
        val directory = directory()
        val log = PcDiagnosticsLog(directory, clockMillis = { 0L })
        log.append(PcDiagnosticEvent("ONLINE with a space", "reason=with=equals"))
        val line = log.read().single()
        assertTrue(line.contains("state=online_with_a_space"))
        assertTrue(line.contains("reason=reason_with_equals"))
        assertFalse(line.contains("with a space"))
    }

    @Test
    fun `rotation keeps one previous file and stays under the cap`() {
        val directory = directory()
        val log = PcDiagnosticsLog(directory, clockMillis = { 0L }, maxBytes = 180)
        repeat(20) { log.append(PcDiagnosticEvent("offline", "network")) }

        assertTrue(log.file.isFile)
        assertTrue(log.rotatedFile.isFile)
        assertTrue(log.file.length() <= 180)
        assertTrue("only one rotated generation", log.readRotated().isNotEmpty())
        assertTrue(log.read().size < 20)
    }

    @Test
    fun `reason names are the frozen case names`() {
        assertEquals("not_started", PcDiagnosticsLog.reasonName(PclinkOfflineReason.NotStarted))
        assertEquals("network", PcDiagnosticsLog.reasonName(PclinkOfflineReason.Network))
        assertEquals("peer_offline", PcDiagnosticsLog.reasonName(PclinkOfflineReason.PeerOffline))
        assertEquals("replaced", PcDiagnosticsLog.reasonName(PclinkOfflineReason.Replaced))
        assertEquals("authentication_failed", PcDiagnosticsLog.reasonName(PclinkOfflineReason.AuthenticationFailed))
        assertEquals("version_unsupported", PcDiagnosticsLog.reasonName(PclinkOfflineReason.VersionUnsupported))
        assertEquals("unpaired_prompt", PcDiagnosticsLog.reasonName(PclinkOfflineReason.UnpairedPrompt))
        assertEquals(
            "protocol_error",
            PcDiagnosticsLog.reasonName(PclinkOfflineReason.ProtocolError("x")),
        )
        assertEquals("storage", PcDiagnosticsLog.reasonName(PclinkOfflineReason.Storage("x")))
        assertEquals(null, PcDiagnosticsLog.reasonName(null))
    }
}
