// phone-dsh — :dsh unit test: EXEC_CTL cancel reaches a CancellableTool.
// SPDX-License-Identifier: MIT
//
// The native `ssh` / `scp` accelerators own a network connection, so a cancel
// must close it (docs/native-ssh.md: cancellation closes the SSH channel and the
// connection). These tests drive the real bridge: the terminal `cancelled` exit
// is the bridge's own, the hook only reaches the tool, a cancelled key replays
// instead of re-running, and the names are advertised only when registered.

package com.phonedsh.dsh.exec

import com.phonedsh.dsh.host.HostCapabilities
import com.phonedsh.dsh.tools.CancellableTool
import com.phonedsh.dsh.tools.RegisteredTool
import com.phonedsh.dsh.tools.ToolInvocation
import com.phonedsh.dsh.tools.ToolOutcome
import java.util.Collections
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.async
import kotlinx.coroutines.flow.toList
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class ExecCancellableToolTest {
    private class ClosingTool : CancellableTool {
        val started = CompletableDeferred<Unit>()
        val closed = CompletableDeferred<String>()
        val cancelled: MutableList<String> = Collections.synchronizedList(ArrayList())
        var calls = 0

        override fun cancelExecution(execId: String) {
            cancelled.add(execId)
            closed.complete(execId)
        }

        override suspend fun invoke(invocation: ToolInvocation): ToolOutcome {
            calls += 1
            started.complete(Unit)
            // Like the SSH tool: the run ends only because its resource closed.
            closed.await()
            return ToolOutcome.Success(ExecFixtures.resultJson(code = 130))
        }
    }

    @Test
    fun cancelInvokesTheToolHookAndKeepsTheBridgesCancelledRecord() = runBlocking {
        val tool = ClosingTool()
        val bridge = ExecFixtures.bridge(tool = tool, name = "ssh")
        val request = ExecFixtures.request(argv = listOf("ssh", "demo", "sleep 30"))

        val collected = async { bridge.onRequest(request).toList() }
        tool.started.await()
        assertEquals(ExecControlOutcome.Applied, bridge.onControl(ExecControl.Cancel(ExecFixtures.EXEC_ID)))

        val events = collected.await()
        assertEquals(listOf(ExecFixtures.EXEC_ID), tool.cancelled.toList())
        assertEquals(listOf("start", "exit"), events.map { it.type })
        assertEquals(ExecEvent.ExitStatus.CANCELLED, (events.last() as ExecEvent.Exit).status)

        // The same idem_key replays the cancelled record; the remote command is
        // never started a second time.
        val replay = bridge.onRequest(
            ExecFixtures.request(execId = ExecFixtures.OTHER_EXEC_ID, argv = listOf("ssh", "demo", "sleep 30")),
        ).toList()
        assertEquals(1, tool.calls)
        assertTrue((replay.first() as ExecEvent.Start).replayed)
        assertEquals(ExecEvent.ExitStatus.CANCELLED, (replay.last() as ExecEvent.Exit).status)
    }

    @Test
    fun aCancelWithoutALiveExecutionDoesNotReachTheTool() {
        val tool = ClosingTool()
        val bridge = ExecFixtures.bridge(tool = tool, name = "ssh")
        assertEquals(ExecControlOutcome.Ignored, bridge.onControl(ExecControl.Cancel(ExecFixtures.EXEC_ID)))
        assertTrue(tool.cancelled.isEmpty())
    }

    @Test
    fun sshAndScpAreAdvertisedOnlyWhenRegistered() {
        val tool = ClosingTool()
        val withSsh = ExecCapability.of(RegisteredTool("phone", CountingTool()), RegisteredTool("ssh", tool), RegisteredTool("scp", tool))
        assertEquals(setOf("exec/1", "accelerator:phone", "accelerator:ssh", "accelerator:scp"), withSsh.caps())
        // channel.md §4.1 lists these names, so the host HELLO type accepts them.
        HostCapabilities(setOf(HostCapabilities.CHANNEL, HostCapabilities.EXEC) + withSsh.caps())

        val without = ExecCapability.of(RegisteredTool("phone", CountingTool()))
        assertEquals(setOf("exec/1", "accelerator:phone"), without.caps())

        // Names outside exec.md §3 stay refused.
        assertThrows(IllegalArgumentException::class.java) {
            ExecCapability.of(RegisteredTool("sftp", tool))
        }
        assertThrows(IllegalArgumentException::class.java) {
            HostCapabilities(setOf(HostCapabilities.CHANNEL, "accelerator:sftp"))
        }
    }
}
