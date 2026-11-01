// Host contract 1 — the projection crosswalk, pinned against event-kinds.md §1.
// SPDX-License-Identifier: MIT

package com.phonedsh.hostevents

import com.phonedsh.agentcore.JsonObject
import com.phonedsh.agentcore.JsonValue
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class HostEventProjectionTest {
    @Test
    fun theEnumCoversAllFifteenHostKinds() {
        val expected = setOf(
            "assistant_message",
            "permission_requested",
            "question_requested",
            "session_status",
            "tool_call",
            "tool_result",
            "turn_ended",
            "turn_started",
            "user_message",
            "usage",
            "assistant_delta",
            "reasoning_delta",
            "progress",
            "exited",
            "inbox_spliced",
        )
        assertEquals(15, HostEventKind.entries.size)
        assertEquals(expected, HostEventKind.entries.map { it.wire }.toSet())
        assertEquals(expected.size, HostEventProjection.kindNames().size)
        for (name in expected) assertNotNull(name, HostEventKind.fromWire(name))
        assertNull(HostEventKind.fromWire("assistant/delta"))
    }

    @Test
    fun theNineProjectionRowsMapTheirDshTypes() {
        val rows = mapOf(
            "assistant/message" to HostEventKind.ASSISTANT_MESSAGE,
            "permission/request" to HostEventKind.PERMISSION_REQUESTED,
            "question/request" to HostEventKind.QUESTION_REQUESTED,
            "session/start" to HostEventKind.SESSION_STATUS,
            "tool/call" to HostEventKind.TOOL_CALL,
            "tool/result" to HostEventKind.TOOL_RESULT,
            "turn/end" to HostEventKind.TURN_ENDED,
            "turn/start" to HostEventKind.TURN_STARTED,
            "user/message" to HostEventKind.USER_MESSAGE,
        )
        for ((dshType, kind) in rows) {
            assertEquals(dshType, kind, HostEventProjection.hostKindOf(dshType))
        }
        assertNull(HostEventProjection.hostKindOf("progress"))
        assertNull(HostEventProjection.hostKindOf("metric/sample"))
        assertNull(HostEventProjection.hostKindOf("dsh/unknown"))
    }

    @Test
    fun aTurnStartProjectsWithItsSeqAndTurnId() {
        val raw = objectOf(
            "\"type\":\"turn/start\",\"seq\":4,\"data\":{\"turn\":1}",
        )
        val event = HostEvent.project(raw)
        assertNotNull(event)
        event!!
        assertEquals(HostEventKind.TURN_STARTED, event.kind)
        assertEquals(4L, event.seq)
        assertEquals("turn-0001", event.turnId)
        assertEquals("turn/start", event.projectionType)
        assertTrue(event.durable)
    }

    @Test
    fun aTurnEndCarriesItsReason() {
        val raw = objectOf(
            "\"type\":\"turn/end\",\"seq\":9,\"data\":{\"turn\":2,\"reason\":{\"kind\":\"completed\"}}",
        )
        val event = HostEvent.project(raw)!!
        assertEquals(HostEventKind.TURN_ENDED, event.kind)
        assertEquals("completed", event.turnEndReason)
        assertTrue(event.describe().contains("reason=completed"))
        assertTrue(event.describe().contains("turn=turn-0002"))
    }

    @Test
    fun aToolCallAndResultKeepTheirIds() {
        val call = HostEvent.project(
            objectOf(
                "\"type\":\"tool/call\",\"seq\":5,\"data\":{\"turn\":1," +
                    "\"name\":\"bash\",\"callId\":\"toolu_1\"}",
            ),
        )!!
        assertEquals(HostEventKind.TOOL_CALL, call.kind)
        assertTrue(call.describe().contains("tool=bash"))
        assertTrue(call.describe().contains("call=toolu_1"))
        val result = HostEvent.project(
            objectOf(
                "\"type\":\"tool/result\",\"seq\":6,\"data\":{\"turn\":1," +
                    "\"callId\":\"toolu_1\",\"isError\":false}",
            ),
        )!!
        assertEquals(HostEventKind.TOOL_RESULT, result.kind)
        assertTrue(result.describe().contains("isError=false"))
    }

    @Test
    fun bestEffortEventsHaveNoSeqAndNeverBecomeDurable() {
        val event = HostEvent.project(
            objectOf("\"type\":\"session/start\",\"data\":{\"sessionId\":\"s-1\"}"),
        )!!
        assertEquals(HostEventKind.SESSION_STATUS, event.kind)
        assertNull(event.seq)
        assertFalse(event.durable)
        assertNull(event.turnId)
    }

    @Test
    fun anUnknownAuthoringTypeIsDroppedNotRenamed() {
        assertNull(HostEvent.project(objectOf("\"type\":\"metric/sample\",\"seq\":1,\"data\":{}")))
        assertTrue(HostEventProjection.projectAll(objectOf("\"seq\":1,\"data\":{}")).isEmpty())
    }

    @Test
    fun anAssistantMessageWithUsageFoldsTheUsageRow() {
        val raw = objectOf(
            "\"type\":\"assistant/message\",\"seq\":8,\"data\":{\"turn\":1," +
                "\"text\":\"done\",\"usage\":{\"input_tokens\":64,\"output_tokens\":24}}",
        )
        val events = HostEventProjection.projectAll(raw)
        assertEquals(2, events.size)
        assertEquals(HostEventKind.ASSISTANT_MESSAGE, events[0].kind)
        assertEquals(HostEventKind.USAGE, events[1].kind)
        assertEquals(8L, events[1].seq)
        assertEquals("assistant/message", events[1].projectionType)
    }

    @Test
    fun aTurnIdIsTakenFromTurnIdWhenTurnIsAbsent() {
        val event = HostEvent.project(
            objectOf("\"type\":\"turn/start\",\"seq\":2,\"data\":{\"turn_id\":12}"),
        )!!
        assertEquals("turn-0012", event.turnId)
    }

    private fun objectOf(body: String): JsonObject = JsonValue.parse("{$body}") as JsonObject
}
