// The in-memory implementation of the read-only session seam.
// SPDX-License-Identifier: MIT
//
// Same role and same reasoning as [InMemoryConnector]: the real device session
// transport does not exist yet (iOS ships a `nil` connector factory and says so in
// its known limits), so the pages above this seam need one deterministic stand-in
// that can be scripted from a test, a screenshot harness or the composition root.
// It lives in `src/main` because `:domain` has no test-fixtures source set and the
// pages are what consume it.
//
// It is a double, not a backend: it opens no socket, reads no clock and derives
// nothing from the device. What it does give is a truthful paging window — an
// ordered record list, a `maxMessages` window and an honest `hasMore` — so the
// pager, the merge and the page are exercised against real arithmetic rather than
// against a fixture that always says "done".
package com.phonedsh.domain.connector

import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flow

/**
 * A [ReadOnlyDeviceSessionTransport] over a fixed record list and a fixed live
 * script.
 *
 * @param records the durable transcript, in consequence order. The paging window
 *   is cut from it exactly as `session/page` would cut it.
 * @param live the events the live stream replays, in order. The flow completes
 *   those and then parks until the collector is cancelled, which is what a real
 *   follow stream does.
 */
class InMemoryDeviceSessionTransport(
    private val records: List<DeviceTranscriptRecord>,
    private val live: List<DeviceLiveEvent> = emptyList(),
) : ReadOnlyDeviceSessionTransport {
    init {
        val seqs = records.map { it.seq }
        require(seqs.size == seqs.toSet().size) { "records must have unique seq values" }
        require(seqs == seqs.sorted()) { "records must be in consequence order" }
    }

    /** How many reads this transport served; a test reads it to prove a page was read. */
    var readCount: Int = 0
        private set

    /** The windows this transport was asked for, in order. */
    val requests: MutableList<DeviceHistoryRequest> = mutableListOf()

    override suspend fun readHistory(
        sessionId: String,
        request: DeviceHistoryRequest,
    ): DeviceHistoryPage {
        readCount += 1
        requests += request
        val ceiling = request.throughSeq
        val cursor = request.beforeSeq
        val window = records
            .filter { ceiling == null || it.seq <= ceiling }
            .filter { cursor == null || it.seq < cursor }
            .takeLast(request.maxMessages)
        val oldestInWindow = window.minOfOrNull { it.seq }
        val hasMore = if (oldestInWindow == null) {
            false
        } else {
            records.any { it.seq < oldestInWindow && (ceiling == null || it.seq <= ceiling) }
        }
        return DeviceHistoryPage(records = window, hasMore = hasMore)
    }

    override fun liveEvents(sessionId: String, afterSeq: Long?): Flow<DeviceLiveEvent> = flow {
        live.forEach { event ->
            val seq = event.seq
            if (seq == null || afterSeq == null || seq > afterSeq) emit(event)
        }
        awaitCancellation()
    }

    companion object {
        /** The session the shipped double serves. */
        const val DEMO_SESSION_ID: String = "device-session-demo"

        /**
         * The scripted transcript the app and the screenshot harness use: 35
         * simple turns of four records each, so the first window ends exactly on a
         * turn boundary and older pages are whole turns too.
         */
        fun demoRecords(turns: Int = DEMO_TURNS): List<DeviceTranscriptRecord> {
            require(turns >= 0) { "turns must not be negative" }
            val records = mutableListOf<DeviceTranscriptRecord>()
            var seq = 1L
            for (turn in 1..turns) {
                val stamp = FIRST_TURN_TIME_MS + (turn - 1) * TURN_SPACING_MS
                records += DeviceTranscriptRecord.UserMessage(
                    seq = seq++,
                    text = "第 $turn 轮：客厅现在怎么样了？",
                    turn = turn,
                    timeMs = stamp,
                    deviceOrigin = turn % 2 == 0,
                )
                records += DeviceTranscriptRecord.AssistantMessage(
                    seq = seq++,
                    turn = turn,
                    timeMs = stamp + 1_000,
                    blocks = listOf(
                        DeviceContentBlock.Reasoning("先读一次传感器，再回答第 $turn 轮。"),
                        DeviceContentBlock.Text("客厅温度稳定，第 $turn 轮读数见工具结果。"),
                    ),
                )
                records += DeviceTranscriptRecord.ToolCall(
                    seq = seq++,
                    turn = turn,
                    step = 1,
                    timeMs = stamp + 2_000,
                    callId = "call-$turn",
                    name = "sensor.read",
                    argumentsJson = "{\"room\":\"living\",\"turn\":$turn}",
                )
                records += DeviceTranscriptRecord.ToolResult(
                    seq = seq++,
                    turn = turn,
                    step = 1,
                    timeMs = stamp + 3_000,
                    callId = "call-$turn",
                    isError = turn == FAILING_TURN,
                    output = if (turn == FAILING_TURN) {
                        "{\"error\":\"sensor timeout\"}"
                    } else {
                        "{\"celsius\":23.5,\"turn\":$turn}"
                    },
                )
            }
            // Two producing calls close the script: one names its verb directly
            // (`doc.write`) and one through the `phone` tool's `arguments.name`
            // (`sheet.write`), which is the pair the artifact attribution has to read
            // differently. Both outputs name an `art_` id, so the artifacts page's
            // 本 session section is driven by this transcript rather than by a fixture.
            val lastTurn = turns.coerceAtLeast(1)
            val stamp = FIRST_TURN_TIME_MS + (lastTurn - 1) * TURN_SPACING_MS + 4_000
            records += DeviceTranscriptRecord.ToolCall(
                seq = seq++,
                turn = lastTurn,
                step = 2,
                timeMs = stamp,
                callId = "call-doc",
                name = "doc.write",
                argumentsJson = "{\"file\":\"weekly-report.docx\"}",
            )
            records += DeviceTranscriptRecord.ToolResult(
                seq = seq++,
                turn = lastTurn,
                step = 2,
                timeMs = stamp + 1_000,
                callId = "call-doc",
                isError = false,
                output = "{\"fileId\":\"art_weekly_doc\",\"bytes\":48120}",
            )
            records += DeviceTranscriptRecord.ToolCall(
                seq = seq++,
                turn = lastTurn,
                step = 3,
                timeMs = stamp + 2_000,
                callId = "call-sheet",
                name = "phone",
                argumentsJson = "{\"name\":\"sheet.write\",\"path\":\"budget.xlsx\"}",
            )
            records += DeviceTranscriptRecord.ToolResult(
                seq = seq++,
                turn = lastTurn,
                step = 3,
                timeMs = stamp + 3_000,
                callId = "call-sheet",
                isError = false,
                output = "{\"fileId\":\"art_budget_sheet\",\"bytes\":12800}",
            )
            return records
        }

        /**
         * The live tail the shipped double replays: a device message, a streaming
         * reasoning row, an assistant row that grows by two deltas, a tool call
         * with its result, and the turn closing.
         *
         * It is ordered on purpose: the page's live half must read the way a
         * session actually arrives, and a test pins the coalesced result.
         */
        fun demoLive(): List<DeviceLiveEvent> {
            // Live sequence numbers continue the durable ones: they are positions in
            // the same session, not a second numbering.
            val base = demoRecords().size.toLong()
            return listOf(
                DeviceLiveEvent.TurnStarted(turnId = DEMO_TURNS + 1L, seq = base),
                DeviceLiveEvent.UserMessage("把客厅的灯调到 40%", seq = base + 1),
                DeviceLiveEvent.ReasoningDelta("先确认网关在线…", seq = base + 2),
                DeviceLiveEvent.ReasoningDelta("再下发亮度。", seq = base + 3),
                DeviceLiveEvent.AssistantDelta("好的，", seq = base + 4),
                DeviceLiveEvent.AssistantDelta("正在下发。", seq = base + 5),
                DeviceLiveEvent.ToolCall(
                    callId = "call-live-1",
                    name = "light.set",
                    argumentsJson = "{\"room\":\"living\",\"percent\":40}",
                    seq = base + 6,
                ),
                DeviceLiveEvent.ToolResult(
                    callId = "call-live-1",
                    isError = false,
                    output = "{\"percent\":40,\"applied\":true}",
                    seq = base + 7,
                ),
                DeviceLiveEvent.AssistantMessage("客厅灯已经到 40%。", seq = base + 8),
                DeviceLiveEvent.TurnEnded(seq = base + 9),
            )
        }

        /** The shipped double: the demo transcript and its live tail. */
        fun demo(): InMemoryDeviceSessionTransport =
            InMemoryDeviceSessionTransport(demoRecords(), demoLive())

        private const val DEMO_TURNS: Int = 35
        private const val FAILING_TURN: Int = 7
        private const val FIRST_TURN_TIME_MS: Long = 1_733_000_000_000L
        private const val TURN_SPACING_MS: Long = 60_000L
    }
}
