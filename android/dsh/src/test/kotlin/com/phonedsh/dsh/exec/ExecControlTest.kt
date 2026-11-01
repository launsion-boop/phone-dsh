// phone-dsh — :dsh unit test: EXEC_CTL (`0x22`), channel.md §4.4.
// SPDX-License-Identifier: MIT
//
// The two normative golden frames are decoded through the real Rust codec and
// then through ExecControl, so the accepted member set is pinned to the spec
// vector. The behavioural half covers what an in-process accelerator can do:
//
//   * cancel ends the live stream with one terminal `exit` (status `cancelled`)
//     and refuses every later event, even when the tool finally returns;
//   * `stdin.mode = pipe` is refused at dispatch with the stable `unsupported`
//     code (exec.md §3), never silently dropped;
//   * a stdin control is refused explicitly too (an in-process tool has no
//     stdin pipe), with the terminal error written into the live stream when
//     there is one and returned as a standalone terminal event when there is
//     not, mirroring the landed handler's "stdin is not supported" answer.

package com.phonedsh.dsh.exec

import com.phonedsh.wire.WireCodec
import java.util.Base64
import kotlinx.coroutines.async
import kotlinx.coroutines.flow.toList
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.yield
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class ExecControlTest {
    @Test
    fun theCancelGoldenFrameDecodesToACancelControl() {
        val control = controlFromGolden("exec-ctl-1.json")

        assertEquals(ExecControl.Cancel(ExecFixtures.EXEC_ID), control)
        assertEquals("cancel", control.op)
    }

    @Test
    fun theStdinGoldenFrameDecodesToTheBase64PipeBytes() {
        val control = controlFromGolden("exec-ctl-2.json")

        assertTrue(control is ExecControl.Stdin)
        val stdin = control as ExecControl.Stdin
        assertEquals(ExecFixtures.EXEC_ID, stdin.execId)
        assertEquals("stdin", stdin.op)
        assertEquals("hello\n", String(stdin.bytes, Charsets.UTF_8))
        assertEquals("aGVsbG8K", stdin.data)
    }

    @Test
    fun malformedControlsAreRefusedBeforeDispatch() {
        fun rejected(json: String): ExecControlException =
            assertThrows(ExecControlException::class.java) { ExecControl.parse(json) }

        val execId = ExecFixtures.EXEC_ID
        assertEquals("op", rejected("""{"exec_id":"$execId"}""").field)
        assertEquals("exec_id", rejected("""{"op":"cancel"}""").field)
        assertEquals("exec_id", rejected("""{"exec_id":"bad/id","op":"cancel"}""").field)
        assertEquals(
            ExecRequestException.Reason.BAD_IDENTIFIER,
            rejected("""{"exec_id":"bad/id","op":"cancel"}""").reason,
        )
        assertEquals("op", rejected("""{"exec_id":"$execId","op":"pause"}""").field)
        assertEquals(
            ExecRequestException.Reason.BAD_VALUE,
            rejected("""{"exec_id":"$execId","op":"pause"}""").reason,
        )
        assertEquals("data", rejected("""{"exec_id":"$execId","op":"stdin"}""").field)
        assertEquals(
            "data",
            rejected("""{"exec_id":"$execId","op":"stdin","data":"!!!"}""").field,
        )
        assertEquals(
            ExecRequestException.Reason.BAD_VALUE,
            rejected("""{"exec_id":"$execId","op":"stdin","data":"!!!"}""").reason,
        )
        assertEquals(
            "data",
            rejected("""{"exec_id":"$execId","op":"cancel","data":"aGVsbG8="}""").field,
        )
        assertEquals(
            ExecRequestException.Reason.UNKNOWN_MEMBER,
            rejected("""{"exec_id":"$execId","op":"cancel","eof":true}""").reason,
        )
        rejected("""{"exec_id":"$execId","data":"aGVsbG8="}""")
        rejected("[]")
        rejected("not json")
    }

    @Test
    fun pipeStdinIsRefusedWithTheStableUnsupportedCode() {
        val tool = CountingTool()
        val bridge = ExecFixtures.bridge(tool = tool)

        val events = runBlocking {
            bridge.onRequest(ExecFixtures.request(stdin = ExecFixtures.pipeStdin())).toList()
        }

        val error = events.single() as ExecEvent.Error
        assertEquals("exec.md §3's existing code, not a new one", ExecBridge.CODE_UNSUPPORTED, error.code)
        assertEquals(ExecEvent.SEQUENCE_START, error.seq)
        assertEquals("an unsupported stdin pipe must not run the tool", 0, tool.calls.get())
    }

    @Test
    fun suppliedStdinDataIsStillAccepted() {
        val tool = CountingTool()
        val bridge = ExecFixtures.bridge(tool = tool)
        val data = JSONObject()
            .put("mode", "data")
            .put("data", Base64.getEncoder().encodeToString("hello\n".encodeToByteArray()))

        val events = runBlocking {
            bridge.onRequest(ExecFixtures.request(stdin = data)).toList()
        }

        assertEquals(1, tool.calls.get())
        assertEquals(listOf("start", "output", "exit"), events.map { it.type })
    }

    @Test
    fun cancelEndsTheLiveStreamAndNoLaterEventIsEmitted() = runBlocking {
        val tool = GatedTool()
        val bridge = ExecFixtures.bridge(tool = tool)

        val collected = async { bridge.onRequest(ExecFixtures.request()).toList() }
        tool.started.await()

        assertEquals(
            ExecControlOutcome.Applied,
            bridge.onControl(ExecControl.Cancel(ExecFixtures.EXEC_ID)),
        )
        val events = collected.await()

        assertEquals(listOf("start", "exit"), events.map { it.type })
        assertEquals(listOf(0L, 1L), events.map { it.seq })
        val exit = events.last() as ExecEvent.Exit
        assertEquals(ExecEvent.ExitStatus.CANCELLED, exit.status)
        assertNull("no process was signalled", exit.signal)
        assertTrue(exit.quiescent)

        val afterCancel = requireNotNull(bridge.liveExecutions.find(ExecFixtures.IDEM_A)).snapshot()
        tool.release()
        tool.finished.await()

        assertEquals(
            "the tool's late result must not produce another event",
            afterCancel,
            requireNotNull(bridge.liveExecutions.find(ExecFixtures.IDEM_A)).snapshot(),
        )
        assertEquals(
            "a second cancel has nothing to do",
            ExecControlOutcome.Ignored,
            bridge.onControl(ExecControl.Cancel(ExecFixtures.EXEC_ID)),
        )

        val replay = bridge.onRequest(
            ExecFixtures.request(execId = ExecFixtures.OTHER_EXEC_ID),
        ).toList()
        assertEquals("a cancelled execution is terminal, never re-run", 1, tool.calls.get())
        assertEquals(listOf("start", "exit"), replay.map { it.type })
        assertTrue((replay.first() as ExecEvent.Start).replayed)
        assertEquals(ExecEvent.ExitStatus.CANCELLED, (replay.last() as ExecEvent.Exit).status)
    }

    @Test
    fun cancelWithoutALiveExecutionIsIgnored() {
        val bridge = ExecFixtures.bridge(tool = CountingTool())

        assertEquals(
            ExecControlOutcome.Ignored,
            bridge.onControl(ExecControl.Cancel(ExecFixtures.EXEC_ID)),
        )
    }

    @Test
    fun aStdinControlIsRefusedExplicitlyWhileTheExecutionRuns() = runBlocking {
        val tool = GatedTool()
        val bridge = ExecFixtures.bridge(tool = tool)

        val collected = async { bridge.onRequest(ExecFixtures.request()).toList() }
        tool.started.await()

        val outcome = bridge.onControl(
            ExecControl.Stdin(
                execId = ExecFixtures.EXEC_ID,
                data = Base64.getEncoder().encodeToString("hello\n".encodeToByteArray()),
            ),
        )
        assertEquals(ExecControlOutcome.Refused(ExecBridge.CODE_UNSUPPORTED), outcome)

        val events = collected.await()
        assertEquals(listOf("start", "error"), events.map { it.type })
        val error = events.last() as ExecEvent.Error
        assertEquals(ExecBridge.CODE_UNSUPPORTED, error.code)

        val afterRefusal = requireNotNull(bridge.liveExecutions.find(ExecFixtures.IDEM_A)).snapshot()
        tool.release()
        tool.finished.await()
        assertEquals(
            afterRefusal,
            requireNotNull(bridge.liveExecutions.find(ExecFixtures.IDEM_A)).snapshot(),
        )
    }

    @Test
    fun aStdinControlWithoutALiveExecutionReturnsAStandaloneTerminalError() {
        val bridge = ExecFixtures.bridge(tool = CountingTool())

        val outcome = bridge.onControl(
            ExecControl.Stdin(execId = ExecFixtures.EXEC_ID, data = "aGVsbG8K"),
        )

        assertTrue(outcome is ExecControlOutcome.Emit)
        val event = (outcome as ExecControlOutcome.Emit).event
        assertNotNull(event)
        assertEquals("error", event.type)
        assertEquals(ExecBridge.CODE_UNSUPPORTED, (event as ExecEvent.Error).code)
        assertEquals(ExecFixtures.EXEC_ID, event.execId)
        assertEquals(ExecEvent.SEQUENCE_START, event.seq)
    }

    private fun controlFromGolden(name: String): ExecControl {
        val golden = ExecSpec.golden(name)
        val frame = ExecSpec.hexBytes(golden.getString("frame_hex"))
        assertEquals(golden.getInt("type_byte"), frame[2].toInt() and 0xFF)
        assertEquals(0x22, frame[2].toInt() and 0xFF)
        assertEquals(
            golden.getString("payload_hex"),
            frame.copyOfRange(16, frame.size).hex(),
        )
        return ExecControl.parse(WireCodec.decode(frame))
    }
}
