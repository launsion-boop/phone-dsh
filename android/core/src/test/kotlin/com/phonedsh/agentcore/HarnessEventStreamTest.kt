// D1-c tests — transport loss/resubscribe and unknown-kind dropping.
// SPDX-License-Identifier: MIT
package com.phonedsh.agentcore

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.assertThrows
import org.junit.Test

class HarnessEventStreamTest {
    /**
     * The stream fails with `unavailable` after durable seq 3 was consumed.
     * Re-subscribing from the last durable seq (3) must deliver 4..6 exactly
     * once: no gap, no duplicate. The backend's reported `last_seq` (99) is
     * deliberately wrong and must never be used as the cursor.
     */
    @Test
    fun transportLossResubscribesFromLastDurableSeqWithoutGapsOrDuplicates() {
        val harness = FakeHarness(
            wire = (1L..6L).map { seq ->
                WireLine.Json(assistantMessage(seq = seq, text = "event-$seq"))
            },
            failAfterDeliveredSeq = 3,
            reportedLastSeq = 99,
        )

        val received = ArrayList<HarnessEvent>()
        var cursor: Long? = null
        var losses = 0

        while (true) {
            try {
                harness.events("sess-1", cursor).collectBlocking { event ->
                    received += event
                    event.seq?.let { cursor = it }
                }
                break
            } catch (loss: HarnessUnavailable) {
                losses += 1
                assertTrue("transport loss must be retryable", loss.retryable)
                assertEquals(HarnessErrorCode.UNAVAILABLE, loss.code)
                assertTrue("a second loss means the cursor did not advance", losses == 1)
            }
        }

        assertEquals(listOf(1L, 2L, 3L, 4L, 5L, 6L), received.map { it.seq })
        assertEquals("exactly one re-subscribe", 2, harness.eventsSubscriptions)
        assertEquals(
            "the re-subscribe starts strictly after the last durable seq consumed",
            listOf<Long?>(null, 3L),
            harness.subscriptionCursors(),
        )
        assertEquals(6L, cursor)
    }

    /**
     * An unknown kind is dropped: the stream keeps running, the line is not
     * emitted, and the decoded kind is never passed through.
     */
    @Test
    fun unknownKindIsDroppedAndTheStreamKeepsRunning() {
        val unknownLine = """
            {
              "session_id": "sess-1",
              "seq": 2,
              "time_ms": 2,
              "kind": "synthetic_telemetry",
              "payload": { "cpu": 42 }
            }
        """.trimIndent()
        val harness = FakeHarness(
            wire = listOf(
                WireLine.Json(assistantMessage(seq = 1, text = "one")),
                WireLine.Json(unknownLine),
                WireLine.Json(assistantMessage(seq = 3, text = "three")),
            ),
        )

        val received = ArrayList<HarnessEvent>()
        harness.events("sess-1", null).collectBlocking { received += it }

        assertEquals(2, received.size)
        assertEquals(
            listOf("one", "three"),
            received.map { (it.kind as HarnessKind.AssistantMessage).text },
        )
        assertEquals("one subscription, no restart", 1, harness.eventsSubscriptions)
        assertNull("the unknown kind must decode to no event", HarnessJson.decodeEvent(unknownLine))

        val dropped = HarnessJson.decodeEventLine(unknownLine)
        assertTrue(dropped is HarnessEventDecode.UnknownKindDropped)
        assertEquals("the dropped event's seq still counts as consumed", 2L, (dropped as HarnessEventDecode.UnknownKindDropped).seq)
        assertNull("an unknown kind is never a known HarnessKindName", HarnessKindName.fromWire("synthetic_telemetry"))
    }

    @Test
    fun seqPresenceMustMatchDurability() {
        val bestEffortWithSeq = """
            {"session_id":"s","seq":1,"time_ms":1,"kind":"assistant_delta","text":"x"}
        """.trimIndent()
        val durableWithoutSeq = """
            {"session_id":"s","time_ms":1,"kind":"assistant_message","text":"x"}
        """.trimIndent()

        val bestEffortFailure = assertThrows(HarnessDecodingException::class.java) {
            HarnessJson.decodeEvent(bestEffortWithSeq)
        }
        assertEquals("event", bestEffortFailure.path)
        assertEquals(HarnessErrorCode.INVALID_RESPONSE, bestEffortFailure.code)

        val durableFailure = assertThrows(HarnessDecodingException::class.java) {
            HarnessJson.decodeEvent(durableWithoutSeq)
        }
        assertEquals("event", durableFailure.path)
        assertEquals(HarnessErrorCode.INVALID_RESPONSE, durableFailure.code)

        // The legal forms still decode.
        val delta = HarnessJson.decodeEvent("""{"session_id":"s","time_ms":1,"kind":"assistant_delta","text":"x"}""")
        assertNull(delta!!.seq)
        assertEquals(false, delta.isDurable)
    }

    @Test
    fun eventJsonWithUnknownMembersStillDecodesAndKeepsEnvelopeFields() {
        val json = """
            {
              "session_id": "sess-1",
              "seq": 4,
              "time_ms": 1793400123000,
              "kind": "tool_result",
              "call_id": "call-42",
              "is_error": false,
              "summary": "pytest: 12 passed, 1 failed",
              "tool_result_detail": {
                "text": "line one\nline two",
                "truncated": false,
                "event_seq": 3,
                "session_log_path": "/dsh/home/sessions/*/sess-2f7c/session.*.jsonl",
                "future_detail_member": true
              },
              "future_envelope_member": { "a": 1 }
            }
        """.trimIndent()

        val event = HarnessJson.decodeEvent(json)!!

        assertEquals("sess-1", event.sessionId)
        assertEquals(4L, event.seq)
        assertEquals(1793400123000L, event.timeMs)
        assertEquals("line one\nline two", event.toolResultDetail!!.text)
        assertEquals("/dsh/home/sessions/*/sess-2f7c/session.*.jsonl", event.toolResultDetail!!.sessionLogPath)
        assertEquals(HarnessKindName.TOOL_RESULT, event.kind.kindName)
    }

    @Test
    fun turnEndedKeepsTheRawProducerLabelAlongsideTheProjection() {
        val json = """
            {
              "session_id": "s",
              "seq": 8,
              "time_ms": 8,
              "kind": "turn_ended",
              "turn_id": "0",
              "reason": { "kind": "budget_exhausted", "detail": "steps" },
              "raw_turn_end_kind": "max-tokens",
              "raw_turn_end_cause": "{\"limit\":40}"
            }
        """.trimIndent()

        val event = HarnessJson.decodeEvent(json)!!
        val turnEnded = event.kind as HarnessKind.TurnEnded

        assertEquals(HarnessTurnEnd.BudgetExhausted("steps"), turnEnded.reason)
        assertEquals("max-tokens", event.rawTurnEndKind)
        assertEquals("{\"limit\":40}", event.rawTurnEndCause)
    }

    @Test
    fun streamCompletesNormallyWithoutALoss() {
        val harness = FakeHarness(wire = listOf(WireLine.Json(assistantMessage(seq = 0, text = "first"))))
        val texts = ArrayList<String>()

        harness.events("s", null).collectBlocking { event ->
            texts += (event.kind as HarnessKind.AssistantMessage).text
        }

        assertEquals(listOf("first"), texts)
    }

    private fun assistantMessage(seq: Long, text: String): String =
        """{"session_id":"sess-1","seq":$seq,"time_ms":$seq,"kind":"assistant_message","text":"$text"}"""
}
