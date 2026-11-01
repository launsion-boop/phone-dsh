// D1-c tests — the event kind set is closed at exactly fifteen values.
// SPDX-License-Identifier: MIT
package com.phonedsh.agentcore

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * Guards the contract's closed `kind` set against a sixteenth value slipping in.
 *
 * The expected table is copied from `spec/host/v1/event-kinds.md` §1 plus the
 * durable/best-effort split of host README §4; the test is intentionally a
 * second, independent statement of that table.
 */
class HarnessKindClosureTest {
    @Test
    fun enumHasExactlyTheFifteenContractKindsWithTheirDurability() {
        assertEquals(15, HarnessKindName.entries.size)
        assertEquals(EXPECTED_KINDS, HarnessKindName.entries.associate { it.wire to it.durable })
        assertEquals(9, HarnessKindName.entries.count { it.durable })
        assertEquals(6, HarnessKindName.entries.count { !it.durable })
    }

    @Test
    fun sealedPayloadHierarchyHasExactlyOneClassPerKind() {
        val payloadClasses = HarnessKind::class.java.declaredClasses
            .filter { HarnessKind::class.java.isAssignableFrom(it) }

        assertEquals(15, payloadClasses.size)
        assertEquals(EXPECTED_PAYLOAD_CLASSES, payloadClasses.map { it.simpleName }.toSet())
    }

    @Test
    fun everyKnownKindDecodesAndAnyNewerKindIsDropped() {
        assertEquals(15, SAMPLE_LINES.size)
        assertEquals(EXPECTED_KINDS.keys, SAMPLE_LINES.keys)

        for ((wire, json) in SAMPLE_LINES) {
            val event = HarnessJson.decodeEvent(json)
            assertNotNull("sample for '$wire' must decode", event)
            assertEquals("sample line has the wrong kind", wire, event!!.kind.kindName.wire)
        }

        // A hypothetical kind 16 introduced by a newer peer: drop it, never map it.
        val sixteenth = """{"session_id":"s","seq":16,"time_ms":16,"kind":"assistant_message_v2","text":"x"}"""
        assertNull(HarnessKindName.fromWire("assistant_message_v2"))
        assertNull(HarnessJson.decodeEvent(sixteenth))
    }

    private companion object {
        /** wire kind -> durable, from event-kinds.md §1 and host README §4. */
        private val EXPECTED_KINDS: Map<String, Boolean> = linkedMapOf(
            "assistant_delta" to false,
            "reasoning_delta" to false,
            "assistant_message" to true,
            "tool_call" to true,
            "tool_result" to true,
            "permission_requested" to false,
            "question_requested" to false,
            "user_message" to true,
            "inbox_spliced" to true,
            "turn_started" to true,
            "turn_ended" to true,
            "progress" to true,
            "session_status" to false,
            "usage" to true,
            "exited" to false,
        )

        /** Nested payload class names, one per expected kind. */
        private val EXPECTED_PAYLOAD_CLASSES: Set<String> = setOf(
            "AssistantDelta",
            "ReasoningDelta",
            "AssistantMessage",
            "ToolCall",
            "ToolResult",
            "PermissionRequested",
            "QuestionRequested",
            "UserMessage",
            "InboxSpliced",
            "TurnStarted",
            "TurnEnded",
            "Progress",
            "SessionStatus",
            "Usage",
            "Exited",
        )

        /** One minimal valid wire line per kind, exactly the schema's required members. */
        private val SAMPLE_LINES: Map<String, String> = linkedMapOf(
            "assistant_delta" to
                """{"session_id":"s","time_ms":1,"kind":"assistant_delta","text":"a"}""",
            "reasoning_delta" to
                """{"session_id":"s","time_ms":1,"kind":"reasoning_delta","text":"r"}""",
            "assistant_message" to
                """{"session_id":"s","seq":1,"time_ms":1,"kind":"assistant_message","text":"m"}""",
            "tool_call" to
                """{"session_id":"s","seq":2,"time_ms":2,"kind":"tool_call","call_id":"c","name":"shell","arguments":{"cmd":"ls"}}""",
            "tool_result" to
                """{"session_id":"s","seq":3,"time_ms":3,"kind":"tool_result","call_id":"c","is_error":false,"summary":"ok"}""",
            "permission_requested" to
                """{"session_id":"s","time_ms":4,"kind":"permission_requested","request":{"request_id":"r1","tool":"shell","summary":"run","risk":"side_effect"}}""",
            "question_requested" to
                """{"session_id":"s","time_ms":5,"kind":"question_requested","request":{"request_id":"q1","prompt":"which?","options":["a","b"]}}""",
            "user_message" to
                """{"session_id":"s","seq":4,"time_ms":4,"kind":"user_message","text":"u","source":"user"}""",
            "inbox_spliced" to
                """{"session_id":"s","seq":5,"time_ms":5,"kind":"inbox_spliced","messages":[{"text":"u","source":"user"}]}""",
            "turn_started" to
                """{"session_id":"s","seq":6,"time_ms":6,"kind":"turn_started","turn_id":"0"}""",
            "turn_ended" to
                """{"session_id":"s","seq":7,"time_ms":7,"kind":"turn_ended","turn_id":"0","reason":{"kind":"completed"}}""",
            "progress" to
                """{"session_id":"s","seq":8,"time_ms":8,"kind":"progress","phase":"step","step":1}""",
            "session_status" to
                """{"session_id":"s","time_ms":9,"kind":"session_status","status":"running"}""",
            "usage" to
                """{"session_id":"s","seq":9,"time_ms":10,"kind":"usage","input_tokens":1200,"output_tokens":80}""",
            "exited" to
                """{"session_id":"s","time_ms":11,"kind":"exited","reason":"the harness process ended"}""",
        )
    }
}
