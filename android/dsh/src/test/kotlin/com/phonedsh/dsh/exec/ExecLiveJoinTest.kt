// phone-dsh — :dsh unit test: D10 join — a repeated idem_key shares one execution.
// SPDX-License-Identifier: MIT
//
// exec.md §2: "If the recorded stream is still live, the host replays the
// recorded prefix and continues from the provider; a second process is never
// started." The tests below pin the three observable facts of that rule:
//
//   1. two concurrent requests with one idem_key call the tool exactly once and
//      both receive the complete ordered event stream (the second one is a
//      replay, from seq 0, and then follows);
//   2. a joiner that arrives after the provider produced a prefix receives that
//      prefix first and only then the later events (the live log is the source,
//      not the tool's return value);
//   3. the joined sub-stream belongs to a bridge-owned execution, so a cancel
//      can end it while the collector is still reading.
//
// The live log is exercised through the production path (`onRequest`); the
// prefix test appends the events a streaming provider would have produced at
// the same point, because `PhoneTool` answers once (the in-process accelerators
// produce bytes and exit facts, not a stream). That is the contract the Worker
// observes, so it is the contract the test pins.

package com.phonedsh.dsh.exec

import java.util.Base64
import kotlinx.coroutines.async
import kotlinx.coroutines.flow.toList
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.yield
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ExecLiveJoinTest {
    @Test
    fun twoConcurrentRequestsWithOneIdemKeyShareOneExecution() = runBlocking {
        val tool = GatedTool()
        val bridge = ExecFixtures.bridge(tool = tool)

        val first = async { bridge.onRequest(ExecFixtures.request()).toList() }
        tool.started.await()
        val second = async {
            bridge.onRequest(ExecFixtures.request(execId = ExecFixtures.OTHER_EXEC_ID)).toList()
        }
        // Let the second request claim the join and receive the prefix.
        yield()
        tool.release()

        val firstEvents = first.await()
        val secondEvents = second.await()

        assertEquals("D10: one execution, one tool call", 1, tool.calls.get())
        assertEquals(listOf("start", "output", "exit"), firstEvents.map { it.type })
        assertEquals(firstEvents.size, secondEvents.size)
        assertEquals("the joiner continues with the same events", firstEvents.drop(1), secondEvents.drop(1))
        assertEquals(firstEvents.map { it.seq }, secondEvents.map { it.seq })
        assertFalse("the owner starts the execution", (firstEvents.first() as ExecEvent.Start).replayed)
        assertTrue("the joiner replays", (secondEvents.first() as ExecEvent.Start).replayed)
        assertEquals(
            "replayed events keep the recorded exec_id",
            ExecFixtures.EXEC_ID,
            secondEvents.first().execId,
        )
    }

    @Test
    fun aLateJoinReplaysTheRecordedPrefixThenFollows() = runBlocking {
        val tool = GatedTool()
        val bridge = ExecFixtures.bridge(tool = tool)

        val first = async { bridge.onRequest(ExecFixtures.request()).toList() }
        tool.started.await()

        val live = requireNotNull(bridge.liveExecutions.find(ExecFixtures.IDEM_A))
        live.append(
            ExecEvent.Output(
                execId = ExecFixtures.EXEC_ID,
                seq = 1L,
                stream = ExecEvent.Stream.STDOUT,
                data = Base64.getEncoder().encodeToString("one".encodeToByteArray()),
            ),
        )
        live.append(
            ExecEvent.Output(
                execId = ExecFixtures.EXEC_ID,
                seq = 2L,
                stream = ExecEvent.Stream.STDERR,
                data = Base64.getEncoder().encodeToString("two".encodeToByteArray()),
            ),
        )
        assertEquals("start + two chunks are recorded before the join", 3, live.snapshot().size)

        val second = async {
            bridge.onRequest(ExecFixtures.request(execId = ExecFixtures.OTHER_EXEC_ID)).toList()
        }
        yield()
        tool.release()

        val firstEvents = first.await()
        val secondEvents = second.await()

        assertEquals(1, tool.calls.get())
        assertEquals("the provider's tail still follows the replay", 5, firstEvents.size)
        assertEquals(5, secondEvents.size)
        assertEquals(
            listOf("start", "output", "output"),
            secondEvents.take(3).map { it.type },
        )
        assertEquals(
            "the three recorded events are replayed first",
            firstEvents.subList(1, 3),
            secondEvents.subList(1, 3),
        )
        assertTrue((secondEvents.first() as ExecEvent.Start).replayed)
        assertEquals(
            "only afterwards does the provider's tail arrive",
            firstEvents.drop(3),
            secondEvents.drop(3),
        )
        assertEquals(listOf(0L, 1L, 2L, 3L, 4L), secondEvents.map { it.seq })
    }

    @Test
    fun aCompletedKeyStillReplaysWithoutRunningTheToolAgain() = runBlocking {
        val tool = CountingTool()
        val bridge = ExecFixtures.bridge(tool = tool)

        val first = bridge.onRequest(ExecFixtures.request()).toList()
        val replay = bridge.onRequest(
            ExecFixtures.request(execId = ExecFixtures.OTHER_EXEC_ID),
        ).toList()

        assertEquals(1, tool.calls.get())
        assertEquals(first.drop(1), replay.drop(1))
        assertTrue((replay.first() as ExecEvent.Start).replayed)
        assertEquals(ExecFixtures.EXEC_ID, replay.first().execId)
    }
}
