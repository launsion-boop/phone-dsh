// phone-dsh — :dsh unit test: the EXEC_REQ → EXEC_EVT bridge rules.
// SPDX-License-Identifier: MIT
//
// The required assertions:
//   1. admission closed  → one terminal error, the fake tool is never called;
//   2. repeated idem_key → replayed events, the fake tool still ran once;
//   3. seq from 0, `exit` its own event, never merged;
//   4. unknown command   → stable `unsupported`, no argv path in the event;
// plus the two readiness facts exec.md §2.1/§2.2 require: requires_mseq never
// dispatches early, and an expired deadline starts nothing.

package com.phonedsh.dsh.exec

import java.util.concurrent.atomic.AtomicInteger
import kotlinx.coroutines.flow.toList
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ExecBridgeTest {
    private fun collected(bridge: ExecBridge, request: ExecRequest): List<ExecEvent> =
        runBlocking { bridge.onRequest(request).toList() }

    private fun errorOf(events: List<ExecEvent>): ExecEvent.Error {
        assertEquals("expected exactly one terminal event, got ${events.map { it.type }}", 1, events.size)
        return events.single() as ExecEvent.Error
    }

    @Test
    fun admissionClosedStartsNoExecutionAndAnswersOneTerminalError() {
        val tool = CountingTool()
        val bridge = ExecFixtures.bridge(tool = tool, admission = AdmissionGate.Closed)

        val events = collected(bridge, ExecFixtures.request())

        val error = errorOf(events)
        assertEquals(ExecBridge.CODE_ADMISSION_CLOSED, error.code)
        assertEquals(ExecEvent.SEQUENCE_START, error.seq)
        assertEquals(ExecFixtures.EXEC_ID, error.execId)
        assertEquals("the fake tool must not be called", 0, tool.calls.get())
    }

    @Test
    fun aRepeatedIdemKeyReplaysTheRecordedEventsWithoutRunningTheToolAgain() {
        val tool = CountingTool()
        val bridge = ExecFixtures.bridge(tool = tool)

        val first = collected(bridge, ExecFixtures.request(execId = ExecFixtures.EXEC_ID))
        assertEquals(1, tool.calls.get())

        val replay = collected(bridge, ExecFixtures.request(execId = ExecFixtures.OTHER_EXEC_ID))

        assertEquals("D10: never execute twice", 1, tool.calls.get())
        assertEquals(first.size, replay.size)
        assertEquals(listOf("start", "output", "exit"), first.map { it.type })

        val firstStart = first.first() as ExecEvent.Start
        val replayStart = replay.first() as ExecEvent.Start
        assertFalse(firstStart.replayed)
        assertTrue("a replay marks its start event", replayStart.replayed)
        assertEquals("replayed events keep the recorded exec_id", ExecFixtures.EXEC_ID, replayStart.execId)
        assertEquals(first.drop(1), replay.drop(1))
        assertEquals(first.map { it.seq }, replay.map { it.seq })
    }

    @Test
    fun theSequenceStartsAtZeroAndExitIsItsOwnUnmergedEvent() {
        val tool = CountingTool(
            ExecFixtures.resultJson(
                stdout = "hello\n".encodeToByteArray(),
                stderr = "warn\n".encodeToByteArray(),
            ),
        )
        val bridge = ExecFixtures.bridge(tool = tool)

        val events = collected(bridge, ExecFixtures.request())

        assertEquals(listOf("start", "output", "output", "exit"), events.map { it.type })
        assertEquals(listOf(0L, 1L, 2L, 3L), events.map { it.seq })
        assertEquals("exit is emitted once", 1, events.count { it is ExecEvent.Exit })

        val outputs = events.filterIsInstance<ExecEvent.Output>()
        assertEquals(
            listOf(ExecEvent.Stream.STDOUT, ExecEvent.Stream.STDERR),
            outputs.map { it.stream },
        )
        assertEquals("hello\n", String(java.util.Base64.getDecoder().decode(outputs[0].data)))
        assertEquals("warn\n", String(java.util.Base64.getDecoder().decode(outputs[1].data)))

        val exit = events.last() as ExecEvent.Exit
        assertEquals(ExecEvent.ExitStatus.EXITED, exit.status)
        assertEquals(0, exit.code)
        assertEquals(6L, exit.stdoutBytes)
        assertEquals(5L, exit.stderrBytes)
        assertTrue("no background children", exit.quiescent)
        assertTrue("output precedes its own exit event", outputs.maxOf { it.seq } < exit.seq)
    }

    @Test
    fun anUnknownCommandAnswersAnUnsupportedErrorWithoutTheArgvPath() {
        val secret = "/dsh/home/secret"
        val tool = CountingTool()
        val bridge = ExecFixtures.bridge(tool = tool)

        val events = collected(
            bridge,
            ExecFixtures.request(argv = listOf(secret, "--json")),
        )

        val error = errorOf(events)
        assertEquals("a stable code, per exec.md §3", ExecBridge.CODE_UNSUPPORTED, error.code)
        assertEquals(ExecEvent.SEQUENCE_START, error.seq)
        assertFalse("argv must not reach the message", error.message.contains(secret))
        assertFalse("argv must not reach the message", error.message.contains("secret"))
        assertFalse(error.fieldsJson().contains(secret))
        val frame = error.encode(frameSeq = 1L)
        val payload = String(frame.copyOfRange(16, frame.size), Charsets.UTF_8)
        assertFalse("argv must not reach the frame", payload.contains(secret))
        assertEquals("nothing may run", 0, tool.calls.get())
    }

    @Test
    fun requiresMseqIsNeverDispatchedEarly() {
        val tool = CountingTool()
        val bridge = ExecFixtures.bridge(
            tool = tool,
            workspace = ExecWorkspace { 3L },
            waitLimitMs = 25L,
        )

        val events = collected(bridge, ExecFixtures.request(requiresMseq = 7L))

        val error = errorOf(events)
        assertEquals(ExecBridge.CODE_WORKSPACE_NOT_READY, error.code)
        assertEquals("a view below requires_mseq must not run the tool", 0, tool.calls.get())
    }

    @Test
    fun requiresMseqDispatchesOnceTheAppliedWatermarkCoversIt() {
        val reads = AtomicInteger()
        val tool = CountingTool()
        val bridge = ExecFixtures.bridge(
            tool = tool,
            workspace = ExecWorkspace { if (reads.incrementAndGet() >= 3) 7L else 3L },
            waitLimitMs = 100L,
        )

        val events = collected(bridge, ExecFixtures.request(requiresMseq = 7L))

        assertEquals(1, tool.calls.get())
        assertEquals("start", events.first().type)
        assertEquals("exit", events.last().type)
    }

    @Test
    fun aDeadlineThatAlreadyPassedStartsNoExecution() {
        val clock = TestClock(wall = 1_800_000_000_000L)
        val tool = CountingTool()
        val bridge = ExecFixtures.bridge(tool = tool, clock = clock)

        val events = collected(
            bridge,
            ExecFixtures.request(deadline = clock.wall - 1L),
        )

        val error = errorOf(events)
        assertEquals(ExecBridge.CODE_DEADLINE_EXCEEDED, error.code)
        assertEquals(0, tool.calls.get())
    }

    @Test
    fun aRepeatedKeyWithAnotherArgvIsAConflictAndLeavesTheRecordUntouched() {
        val tool = CountingTool()
        val bridge = ExecFixtures.bridge(tool = tool)

        collected(bridge, ExecFixtures.request(argv = listOf("rg", "one")))
        assertEquals(1, tool.calls.get())

        val conflict = collected(
            bridge,
            ExecFixtures.request(execId = ExecFixtures.OTHER_EXEC_ID, argv = listOf("rg", "two")),
        )
        val error = errorOf(conflict)
        assertEquals(ExecBridge.CODE_EXEC_ID_CONFLICT, error.code)
        assertEquals("conflict detection compares argv; nothing runs", 1, tool.calls.get())

        // The recorded entry was not rewritten: the original call still replays.
        val replay = collected(bridge, ExecFixtures.request(argv = listOf("rg", "one")))
        assertEquals(1, tool.calls.get())
        assertTrue((replay.first() as ExecEvent.Start).replayed)
    }

    @Test
    fun anExecIdMayNotBeReusedForAnotherIdemKey() {
        val tool = CountingTool()
        val bridge = ExecFixtures.bridge(tool = tool)

        collected(bridge, ExecFixtures.request(idemKey = ExecFixtures.IDEM_A))
        assertEquals(1, tool.calls.get())

        val events = collected(
            bridge,
            ExecFixtures.request(idemKey = ExecFixtures.IDEM_B),
        )
        val error = errorOf(events)
        assertEquals(ExecBridge.CODE_EXEC_ID_CONFLICT, error.code)
        assertEquals(1, tool.calls.get())
    }
}
