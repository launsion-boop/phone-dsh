// Paging and the live/durable merge: the two pieces of logic the session page exists for.
// SPDX-License-Identifier: MIT
//
// The page itself renders; these tests pin the arithmetic under it, on plain values:
//
//  * `DeviceSessionHistory` — a `seq`-keyed window, its two cursors, the overlap
//    dedupe, and the refusal to accept a page that does not move the cursor (the
//    iOS `historyDidNotAdvance` case).
//  * `DeviceLiveState` — delta coalescing, the streaming flags, and a live tool
//    result patching the durable row it names.
//  * `DeviceSessionSource` — the same two halves assembled into the snapshot the page
//    reads, end to end over the in-memory read-only transport.
package com.phonedsh.ui.page

import com.phonedsh.domain.connector.DeviceContentBlock
import com.phonedsh.domain.connector.DeviceHistoryPage
import com.phonedsh.domain.connector.DeviceHistoryRequest
import com.phonedsh.domain.connector.DeviceItemKind
import com.phonedsh.domain.connector.DeviceLiveEvent
import com.phonedsh.domain.connector.DeviceLiveState
import com.phonedsh.domain.connector.DeviceSessionFailure
import com.phonedsh.domain.connector.DeviceSessionHistory
import com.phonedsh.domain.connector.DeviceSessionSnapshot
import com.phonedsh.domain.connector.DeviceSessionSource
import com.phonedsh.domain.connector.DeviceSessionStatus
import com.phonedsh.domain.connector.DeviceToolState
import com.phonedsh.domain.connector.DeviceTranscriptProjector
import com.phonedsh.domain.connector.DeviceTranscriptRecord
import com.phonedsh.domain.connector.HistoryAdvance
import com.phonedsh.domain.connector.InMemoryDeviceSessionTransport
import com.phonedsh.domain.connector.ReadOnlyDeviceSessionTransport
import com.phonedsh.ui.UiStrings
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class DeviceSessionPagingTest {
    // ------------------------------------------------------------- the window

    @Test
    fun `a first window takes its cursor from its oldest record and keeps hasMore`() {
        val history = DeviceSessionHistory().reset(page(seqs = 5L..9L, hasMore = true), throughSeq = 9)
        assertEquals(listOf(5L, 6L, 7L, 8L, 9L), history.ordered.map { it.seq })
        assertEquals(5L, history.beforeSeq)
        assertEquals(9L, history.throughSeq)
        assertTrue(history.hasMore)
    }

    @Test
    fun `an older window prepends, moves the cursor and dedupes the overlap`() {
        val first = DeviceSessionHistory().reset(page(seqs = 5L..9L, hasMore = true), throughSeq = 9)
        // The device re-sends seq 5 at the window's edge; a map keyed by seq keeps one.
        val (second, advance) = first.applyEarlier(page(seqs = 1L..5L, hasMore = false))
        assertEquals(HistoryAdvance.ADVANCED, advance)
        assertEquals(listOf(1L, 2L, 3L, 4L, 5L, 6L, 7L, 8L, 9L), second.ordered.map { it.seq })
        assertEquals(1L, second.beforeSeq)
        assertFalse(second.hasMore)
    }

    @Test
    fun `a window that does not move the cursor stalls instead of looping forever`() {
        val first = DeviceSessionHistory().reset(page(seqs = 5L..9L, hasMore = true), throughSeq = 9)
        val (stalled, advance) = first.applyEarlier(page(seqs = 5L..9L, hasMore = true))
        assertEquals(HistoryAdvance.STALLED, advance)
        assertEquals("the window is unchanged", first.ordered, stalled.ordered)
        assertFalse("paging stops rather than offering the same button", stalled.hasMore)
    }

    @Test
    fun `an empty older window stalls too`() {
        val first = DeviceSessionHistory().reset(page(seqs = 5L..9L, hasMore = true), throughSeq = 9)
        val (stalled, advance) = first.applyEarlier(DeviceHistoryPage(records = emptyList(), hasMore = true))
        assertEquals(HistoryAdvance.STALLED, advance)
        assertFalse(stalled.hasMore)
    }

    // ---------------------------------------------------- the live/durable merge

    @Test
    fun `deltas coalesce into one streaming row and a turn end closes it`() {
        val session = "s1"
        var live = DeviceLiveState()
        live = live.apply(DeviceLiveEvent.ReasoningDelta("先", seq = 1), session)
        live = live.apply(DeviceLiveEvent.ReasoningDelta("读传感器", seq = 2), session)
        assertEquals(1, live.items.size)
        assertEquals("先读传感器", live.items.single().text)
        assertTrue(live.items.single().streaming)
        assertEquals(DeviceItemKind.REASONING, live.items.single().kind)

        live = live.apply(DeviceLiveEvent.AssistantDelta("好的", seq = 3), session)
        live = live.apply(DeviceLiveEvent.AssistantDelta("，正在下发", seq = 4), session)
        assertEquals(2, live.items.size)
        assertEquals("好的，正在下发", live.items.last().text)
        assertFalse("a new assistant row closes the open reasoning row", live.items.first().streaming)

        live = live.apply(DeviceLiveEvent.TurnEnded(seq = 5), session)
        assertTrue("a turn end leaves nothing streaming", live.items.none { it.streaming })
    }

    @Test
    fun `a completed assistant message replaces the streamed text and stops streaming`() {
        var live = DeviceLiveState()
            .apply(DeviceLiveEvent.AssistantDelta("半句", seq = 1), "s1")
            .apply(DeviceLiveEvent.AssistantMessage("整句。", seq = 2), "s1")
        assertEquals(1, live.items.size)
        assertEquals("整句。", live.items.single().text)
        assertFalse(live.items.single().streaming)
        live = live.apply(DeviceLiveEvent.AssistantMessage("", seq = 3), "s1")
        assertEquals("an empty completion does not blank the row", "整句。", live.items.single().text)
    }

    @Test
    fun `a live tool result patches the live call row it names`() {
        var live = DeviceLiveState()
            .apply(DeviceLiveEvent.ToolCall("call-1", "light.set", "{\"percent\":40}", seq = 1), "s1")
            .apply(DeviceLiveEvent.ToolResult("call-1", isError = false, output = "{\"ok\":true}", seq = 2), "s1")
        assertEquals(1, live.items.size)
        assertEquals(DeviceToolState.OK, live.items.single().toolState)
        assertEquals("{\"ok\":true}", live.items.single().outputText)
    }

    @Test
    fun `a live tool result patches the durable call row the window already published`() = runBlocking {
        // The durable half published the call; the result arrives live, before the
        // next history read. The monitor must patch the row instead of leaving it
        // "running" behind a finished call.
        val transport = object : ReadOnlyDeviceSessionTransport {
            override suspend fun readHistory(
                sessionId: String,
                request: DeviceHistoryRequest,
            ): DeviceHistoryPage = DeviceHistoryPage(
                records = listOf(
                    DeviceTranscriptRecord.ToolCall(
                        seq = 1,
                        callId = "call-1",
                        name = "sensor.read",
                        argumentsJson = "{}",
                    ),
                ),
                hasMore = false,
            )

            override fun liveEvents(sessionId: String, afterSeq: Long?): Flow<DeviceLiveEvent> = flow {
                emit(DeviceLiveEvent.ToolResult("call-1", isError = false, output = "23.5", seq = 2))
                kotlinx.coroutines.awaitCancellation()
            }
        }
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Unconfined)
        val source = DeviceSessionSource("dev", "s1", "客厅网关", transport)
        try {
            source.start(scope)
            val durable = source.snapshot.value.durable.single()
            assertEquals(DeviceItemKind.TOOL_CALL, durable.kind)
            assertEquals(DeviceToolState.OK, durable.toolState)
            assertEquals("23.5", durable.outputText)
            assertTrue("the live half carries no extra row: the result patched a call", source.snapshot.value.live.isEmpty())
        } finally {
            source.stop()
            scope.cancel()
        }
    }

    // ---------------------------------------------------------- the monitor

    @Test
    fun `the monitor reads one window, merges the live tail and pages backwards`() = runBlocking {
        val transport = InMemoryDeviceSessionTransport.demo()
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Unconfined)
        val source = DeviceSessionSource(
            deviceId = "esp32-8c4f01",
            sessionId = InMemoryDeviceSessionTransport.DEMO_SESSION_ID,
            displayName = "客厅网关",
            transport = transport,
            pageSize = 60,
        )
        try {
            source.start(scope)
            val first = source.snapshot.value
            assertEquals(DeviceSessionStatus.READY, first.status)
            val allRecords = InMemoryDeviceSessionTransport.demoRecords()
            assertEquals(60, transport.requests.first().maxMessages)
            assertNull(transport.requests.first().beforeSeq)
            assertEquals(
                "the first window is the newest 60 records, projected",
                DeviceTranscriptProjector.items(allRecords.takeLast(60), InMemoryDeviceSessionTransport.DEMO_SESSION_ID)
                    .map { it.id },
                first.durable.map { it.id },
            )
            assertTrue("the demo transcript is longer than one window", first.hasMore)
            assertEquals(first.durable.size + first.live.size, first.items.size)
            assertEquals(
                "the durable half comes first, the live tail last",
                first.durable.map { it.id } + first.live.map { it.id },
                first.items.map { it.id },
            )
            assertTrue(first.live.isNotEmpty())
            assertTrue(
                "the live assistant message closes the live half",
                first.items.last().kind == DeviceItemKind.ASSISTANT,
            )
            assertEquals(1, transport.requests.size)

            // One older page: the window grows, the cursor moves, hasMore stays true.
            source.loadEarlier()
            val second = source.snapshot.value
            assertEquals(
                "the second window is the newest 120 records",
                DeviceTranscriptProjector.items(allRecords.takeLast(120), InMemoryDeviceSessionTransport.DEMO_SESSION_ID)
                    .map { it.id },
                second.durable.map { it.id },
            )
            assertTrue(second.beforeSeq!! < first.beforeSeq!!)
            assertTrue(second.hasMore)
            assertEquals(60, transport.requests.last().maxMessages)
            assertEquals(first.beforeSeq, transport.requests.last().beforeSeq)
            assertEquals(first.throughSeq, transport.requests.last().throughSeq)

            // A second older page exhausts the transcript.
            source.loadEarlier()
            val third = source.snapshot.value
            assertFalse(third.hasMore)
            assertEquals(1L, third.beforeSeq)
            assertEquals(
                "the whole transcript is now in the window, one row per record",
                DeviceTranscriptProjector.items(allRecords, InMemoryDeviceSessionTransport.DEMO_SESSION_ID)
                    .map { it.id },
                third.durable.map { it.id },
            )

            // Nothing older: the call is a no-op, not another request.
            val requests = transport.requests.size
            source.loadEarlier()
            assertEquals(requests, transport.requests.size)
        } finally {
            source.stop()
            scope.cancel()
        }
    }

    @Test
    fun `a stalled page surfaces the reason and stops offering the action`() = runBlocking {
        // A transport whose second answer never moves the cursor.
        val stalling = object : ReadOnlyDeviceSessionTransport {
            var calls = 0
            override suspend fun readHistory(
                sessionId: String,
                request: DeviceHistoryRequest,
            ): DeviceHistoryPage {
                calls += 1
                return if (calls == 1) {
                    DeviceHistoryPage(records = records(5L..9L), hasMore = true)
                } else {
                    DeviceHistoryPage(records = records(5L..9L), hasMore = true)
                }
            }

            override fun liveEvents(sessionId: String, afterSeq: Long?): Flow<DeviceLiveEvent> =
                flow { }
        }
        val source = DeviceSessionSource(
            deviceId = "dev",
            sessionId = "s1",
            displayName = "客厅网关",
            transport = stalling,
        )
        source.start()
        assertTrue(source.snapshot.value.hasMore)
        source.loadEarlier()
        val after = source.snapshot.value
        assertEquals(DeviceSessionFailure.Stalled(5L), after.failure)
        assertFalse(after.hasMore)

        val page = DeviceSessionScreenState.from(after)
        assertEquals(UiStrings.DEVICE_SESSION_NO_PROGRESS.format(5L), page.failure)
    }

    @Test
    fun `a failed first read is a failure, not an empty transcript`() = runBlocking {
        val source = DeviceSessionSource(
            deviceId = "dev",
            sessionId = "s1",
            displayName = "客厅网关",
            transport = object : ReadOnlyDeviceSessionTransport {
                override suspend fun readHistory(
                    sessionId: String,
                    request: DeviceHistoryRequest,
                ): DeviceHistoryPage = throw IllegalStateException("socket closed")

                override fun liveEvents(sessionId: String, afterSeq: Long?): Flow<DeviceLiveEvent> =
                    flow { }
            },
        )
        source.start()
        val snapshot = source.snapshot.value
        assertEquals(DeviceSessionStatus.FAILED, snapshot.status)
        assertEquals(DeviceSessionFailure.Read("socket closed"), snapshot.failure)
        assertTrue(snapshot.items.isEmpty())
        assertFalse("a failed read is not 还没有交互记录", snapshot.empty)
        assertNull(snapshot.beforeSeq)
    }

    // -------------------------------------------------------------- fixtures

    private fun page(seqs: LongRange, hasMore: Boolean): DeviceHistoryPage =
        DeviceHistoryPage(records = records(seqs), hasMore = hasMore)

    private fun records(seqs: LongRange): List<DeviceTranscriptRecord> = seqs.map { seq ->
        DeviceTranscriptRecord.AssistantMessage(
            seq = seq,
            blocks = listOf(DeviceContentBlock.Text("第 $seq 条")),
            turn = seq.toInt(),
        )
    }
}
