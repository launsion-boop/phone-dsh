// Projection rules that the golden fixtures do not exercise.
// SPDX-License-Identifier: MIT
//
// Each test names the spec sentence it enforces. The corpus covers the five
// happy paths; these cover the edges the state machine depends on: the ordering
// window, the duplicate rule, the writer's own ordinal for a best-effort row,
// the reasoning summary, the stopped-tools rewrite and the "no fabricated row"
// rule for best-effort or folded event kinds.
package com.phonedsh.ui.projection

import com.phonedsh.agentcore.HarnessEvent
import com.phonedsh.agentcore.HarnessKind
import com.phonedsh.agentcore.HarnessPermissionRequest
import com.phonedsh.agentcore.HarnessQuestion
import com.phonedsh.agentcore.HarnessToolRisk
import com.phonedsh.agentcore.HarnessTurnEnd
import com.phonedsh.agentcore.JsonNumber
import com.phonedsh.agentcore.JsonObject
import com.phonedsh.agentcore.JsonString
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

class UiStateProjectorRulesTest {
    @Test
    fun `duplicate seq fails with DUPLICATE_SEQ`() {
        val events = listOf(
            event(HarnessKind.UserMessage("a", "user"), 1),
            event(HarnessKind.UserMessage("b", "user"), 1),
        )
        assertEquals("DUPLICATE_SEQ", codeOf { UiStateProjector.project(events) })
    }

    @Test
    fun `a full reversal of seventeen rows stays inside the window`() {
        val rows = (1..17).map { event(HarnessKind.UserMessage("m$it", "user"), it.toLong()) }
        val nodes = UiStateProjector.project(rows.reversed())
        val bubbles = nodes.filter { it.kind == UiStateKind.BUBBLE }
        assertEquals(17, bubbles.size)
        assertEquals("the window restores the authored order", (1..17).map { "m$it" }, bubbles.map { it.text })
    }

    @Test
    fun `a reversal of eighteen rows fails with OUT_OF_WINDOW`() {
        val rows = (1..18).map { event(HarnessKind.UserMessage("m$it", "user"), it.toLong()) }
        assertEquals("OUT_OF_WINDOW", codeOf { UiStateProjector.project(rows.reversed()) })
    }

    @Test
    fun `a turn id with no integer turn fails loud`() {
        val events = listOf(event(HarnessKind.TurnStarted("not-a-turn"), 1))
        assertEquals("UNSTABLE_NODE_ID", codeOf { UiStateProjector.project(events) })
    }

    @Test
    fun `an integer turn id is formatted turn-NNNN`() {
        val events = listOf(
            event(HarnessKind.TurnStarted("7"), 1),
            event(HarnessKind.UserMessage("hi", "user"), 2),
        )
        val nodes = UiStateProjector.project(events)
        assertEquals("session/sess-1/turn/turn-0007", nodes[2].nodeID)
        assertEquals("the event anchor sits between the turn and its slot", "session/sess-1/turn/turn-0007/event/2", nodes[3].nodeID)
        assertEquals(UiStateKind.TURN_EVENT, nodes[3].kind)
        assertEquals("session/sess-1/turn/turn-0007/event/2/user-message", nodes[4].nodeID)
        assertEquals("turn-0007", nodes[4].turnID)
    }

    @Test
    fun `each event yields one turn-event node and its rows hang below it`() {
        // §7: a slot is event/<seq>/<slot>, so its parent is the event node. Two
        // rows of one event share that node; two events get two nodes.
        val events = listOf(
            event(HarnessKind.TurnStarted("1"), 1),
            event(HarnessKind.ReasoningDelta("thinking\n\n**summary**"), seq = null),
            event(HarnessKind.AssistantMessage("answer"), 2),
            event(HarnessKind.ToolCall("call-1", "exec", JsonObject(emptyMap())), 3),
        )
        val nodes = UiStateProjector.project(events)
        val eventNodes = nodes.filter { it.kind == UiStateKind.TURN_EVENT }
        assertEquals("one turn-event node per projected event", 2, eventNodes.size)
        assertEquals(
            listOf("session/sess-1/turn/turn-0001/event/2", "session/sess-1/turn/turn-0001/event/3"),
            eventNodes.map { it.nodeID },
        )
        assertEquals(
            "an event node's parent is its turn",
            listOf("session/sess-1/turn/turn-0001", "session/sess-1/turn/turn-0001"),
            eventNodes.map { it.parentID },
        )
        val pill = nodes.single { it.kind == UiStateKind.THINKING_PILL }
        val bubble = nodes.single { it.kind == UiStateKind.BUBBLE }
        val tool = nodes.single { it.kind == UiStateKind.TOOL_ROW }
        assertEquals("the pill hangs under the shared event node", eventNodes[0].nodeID, pill.parentID)
        assertEquals("the bubble hangs under the same event node", eventNodes[0].nodeID, bubble.parentID)
        assertEquals("a later event's row hangs under its own event node", eventNodes[1].nodeID, tool.parentID)
        assertEquals("both rows of one event share the event ordinal", pill.seq, bubble.seq)
        assertEquals("the event node carries that ordinal too", pill.seq, eventNodes[0].seq)
    }

    @Test
    fun `a best-effort permission row takes the writer's own next ordinal`() {
        // event-kinds.md §2: `permission/result` carries the writer's ordinal, and the
        // golden writes the request at 1 and the result at 2.
        val events = listOf(
            event(HarnessKind.TurnStarted("1"), 1),
            event(HarnessKind.UserMessage("run", "user"), 2),
            event(HarnessKind.PermissionRequested(permission()), seq = null),
            event(HarnessKind.ToolCall("call-1", "exec", JsonObject(emptyMap())), 4),
        )
        val nodes = UiStateProjector.project(events)
        val card = nodes.single { it.kind == UiStateKind.APPROVAL_CARD }
        assertEquals("the writer's next ordinal after 2", 3, card.seq)
        assertEquals("session/sess-1/turn/turn-0001/event/3/permission-request", card.nodeID)
        assertEquals("approval-card", card.surface.wire)
    }

    @Test
    fun `a durable row that would collide with a writer ordinal is bumped, never duplicated`() {
        val events = listOf(
            event(HarnessKind.PermissionRequested(permission()), seq = null),
            event(HarnessKind.UserMessage("after", "user"), 1),
        )
        val nodes = UiStateProjector.project(events)
        val ids = nodes.map { it.nodeID }
        assertEquals("nodeIDs stay unique", ids.size, ids.toSet().size)
        assertEquals("the writer took 1", 1, nodes.single { it.kind == UiStateKind.APPROVAL_CARD }.seq)
        assertEquals("the durable row that claimed 1 is bumped to 2", 2, nodes.single { it.kind == UiStateKind.BUBBLE }.seq)
    }

    @Test
    fun `reasoning deltas become one pill summary that shares the message ordinal`() {
        val events = listOf(
            event(HarnessKind.TurnStarted("1"), 1),
            event(HarnessKind.ReasoningDelta("先看目录结构。\n再决定归档方式。\n\n**归档方式**：按天分组。"), seq = null),
            event(HarnessKind.AssistantMessage("我先看一下工作区。"), 2),
        )
        val nodes = UiStateProjector.project(events)
        val pill = nodes.single { it.kind == UiStateKind.THINKING_PILL }
        val bubble = nodes.single { it.kind == UiStateKind.BUBBLE }
        assertEquals("归档方式：按天分组。", pill.text)
        assertEquals("thinking-pill", pill.surface.wire)
        assertEquals("session/sess-1/turn/turn-0001/event/2/thinking", pill.nodeID)
        assertEquals("session/sess-1/turn/turn-0001/event/2/assistant-message", bubble.nodeID)
        assertEquals("both rows share the event ordinal", pill.seq, bubble.seq)
    }

    @Test
    fun `empty reasoning produces no pill`() {
        val events = listOf(
            event(HarnessKind.TurnStarted("1"), 1),
            event(HarnessKind.ReasoningDelta("   \n\n  "), seq = null),
            event(HarnessKind.AssistantMessage("answer"), 2),
        )
        assertTrue(UiStateProjector.project(events).none { it.kind == UiStateKind.THINKING_PILL })
    }

    @Test
    fun `a cancelled turn stops its running tool rows and writes a status row`() {
        val events = listOf(
            event(HarnessKind.TurnStarted("1"), 1),
            event(HarnessKind.ToolCall("call-1", "exec", JsonObject(emptyMap())), 2),
            event(HarnessKind.TurnEnded("1", HarnessTurnEnd.Cancelled), 3),
        )
        val nodes = UiStateProjector.project(events)
        val tool = nodes.single { it.kind == UiStateKind.TOOL_ROW }
        assertEquals("stopped", (tool.props["state"] as JsonString).value)
        val status = nodes.single { it.kind == UiStateKind.STATUS }
        assertEquals("cancelled", status.text)
        assertTrue("a stop is not a failure, so no banner", nodes.none { it.kind == UiStateKind.FAIL_LOUD_BANNER })
    }

    @Test
    fun `a completed turn writes one turn-end node and no banner`() {
        // §6 rule ②: one event, one node. A completed turn end is a node so the
        // screen can tell "turn closed" from "turn still running"; rendering it as
        // a visible row is the ScreenState's decision, not the projector's.
        val events = listOf(
            event(HarnessKind.TurnStarted("1"), 1),
            event(HarnessKind.AssistantMessage("done"), 2),
            event(HarnessKind.TurnEnded("1", HarnessTurnEnd.Completed), 3),
        )
        val nodes = UiStateProjector.project(events)
        val status = nodes.single { it.kind == UiStateKind.STATUS }
        assertEquals("completed", status.text)
        assertEquals("completed", (status.props["reason"] as JsonString).value)
        assertTrue(nodes.none { it.kind == UiStateKind.FAIL_LOUD_BANNER })
    }

    @Test
    fun `a failed turn writes a status row and a fail-loud banner`() {
        val events = listOf(
            event(HarnessKind.TurnStarted("1"), 1),
            event(HarnessKind.TurnEnded("1", HarnessTurnEnd.Failed("model down")), 2),
        )
        val nodes = UiStateProjector.project(events)
        assertEquals("failed", nodes.single { it.kind == UiStateKind.STATUS }.text)
        val banner = nodes.single { it.kind == UiStateKind.FAIL_LOUD_BANNER }
        assertEquals("model down", banner.text)
        assertEquals("fail-loud-banner", banner.surface.wire)
        assertEquals("dismissible", true, (banner.props["dismissible"] as com.phonedsh.agentcore.JsonBool).value)
    }

    @Test
    fun `a tool error only marks the tool row, not the turn`() {
        val events = listOf(
            event(HarnessKind.TurnStarted("1"), 1),
            event(HarnessKind.ToolResult("call-1", isError = true, summary = "permission denied"), 2),
        )
        val nodes = UiStateProjector.project(events)
        val tool = nodes.single { it.kind == UiStateKind.TOOL_ROW }
        assertEquals("error", (tool.props["state"] as JsonString).value)
        assertEquals("permission denied", tool.text)
        assertTrue(nodes.none { it.kind == UiStateKind.FAIL_LOUD_BANNER })
    }

    @Test
    fun `usage, step progress and inbox splices never become rows`() {
        val events = listOf(
            event(HarnessKind.TurnStarted("1"), 1),
            event(HarnessKind.Usage(inputTokens = 12, outputTokens = 34), 2),
            event(HarnessKind.Progress(phase = "step", step = 1), 3),
            event(
                HarnessKind.InboxSpliced(listOf(com.phonedsh.agentcore.HarnessUserInput("queued text", "user"))),
                4,
            ),
        )
        val nodes = UiStateProjector.project(events)
        assertEquals("root + session + turn", 3, nodes.size)
    }

    @Test
    fun `a retry progress marker becomes a status row carrying its phase`() {
        val events = listOf(
            event(HarnessKind.TurnStarted("1"), 1),
            event(HarnessKind.Progress(phase = "llm/retry", step = 2, of = 3), 2),
        )
        val status = UiStateProjector.project(events).single { it.kind == UiStateKind.STATUS }
        assertEquals("llm/retry", (status.props["phase"] as JsonString).value)
        assertEquals("session/sess-1/turn/turn-0001/event/2/llm-retry", status.nodeID)
        assertNull("the row carries the marker, not a localised sentence", status.text)
    }

    @Test
    fun `an exited session becomes a status row`() {
        val events = listOf(event(HarnessKind.Exited("harness stopped"), seq = 1))
        val status = UiStateProjector.project(events).single { it.kind == UiStateKind.STATUS }
        assertEquals("harness stopped", status.text)
    }

    @Test
    fun `a question row carries its options without inventing a permission`() {
        val events = listOf(
            event(
                HarnessKind.QuestionRequested(
                    HarnessQuestion(
                        requestId = "q-1",
                        prompt = "pick one",
                        options = listOf("a", "b"),
                    ),
                ),
                seq = null,
            ),
        )
        val card = UiStateProjector.project(events).single { it.kind == UiStateKind.APPROVAL_CARD }
        assertEquals("question", (card.props["kind"] as JsonString).value)
        assertEquals("pick one", card.text)
    }

    @Test
    fun `oversized text is bounded with an explicit marker`() {
        val long = "x".repeat(UiStateProjector.TEXT_LIMIT + 50)
        val events = listOf(event(HarnessKind.UserMessage(long, "user"), 1))
        val bubble = UiStateProjector.project(events).single { it.kind == UiStateKind.BUBBLE }
        assertEquals(UiStateProjector.TEXT_LIMIT, bubble.text.orEmpty().length)
        assertTrue(bubble.text.orEmpty().endsWith("…[truncated]"))
        assertEquals(true, (bubble.props["truncated"] as com.phonedsh.agentcore.JsonBool).value)
    }

    @Test
    fun `canonical text keeps the reference writer's control escapes`() {
        // The pinned sequences carry no control character, so this pins the one
        // byte rule they cannot: the shared `:core` writer emits `\b` rather than
        // `\u0008` and lower-case `\u00XX`, the same bytes
        // `json.dumps(..., ensure_ascii=False)` writes in the trajectory oracle.
        val events = listOf(
            event(HarnessKind.TurnStarted("1"), 1),
            event(HarnessKind.UserMessage("a\u0008b\u0001/é", "user"), 2),
        )
        val line = UiStateProjector.project(events).single { it.kind == UiStateKind.BUBBLE }.toCanonicalJson()
        assertTrue("control escapes drifted: $line", line.contains("\"text\":\"a\\bb\\u0001/é\""))
    }

    @Test
    fun `a session-scope row materialises the session node only`() {
        val events = listOf(event(HarnessKind.SessionStatus("running"), seq = null))
        val nodes = UiStateProjector.project(events)
        assertEquals(2, nodes.size)
        assertEquals(UiStateKind.ROOT, nodes[0].kind)
        assertEquals(UiStateKind.SESSION, nodes[1].kind)
        assertEquals("session/sess-1", nodes[1].nodeID)
    }

    @Test
    fun `a reasoning summary keeps the last segment's first line`() {
        assertEquals("b", ReasoningSummary.summarize("a\n\n**b**\nsecond line"))
        assertEquals("", ReasoningSummary.summarize("\n\n  \n"))
        assertEquals("plain", ReasoningSummary.summarize("plain"))
    }

    private fun permission(): HarnessPermissionRequest = HarnessPermissionRequest(
        requestId = "perm-1",
        tool = "exec",
        summary = "allow exec?",
        risk = HarnessToolRisk.SIDE_EFFECT,
    )

    private fun event(kind: HarnessKind, seq: Long?): HarnessEvent =
        HarnessEvent(sessionId = SESSION, timeMs = 0L, seq = seq, kind = kind)

    @Test
    fun `canonical members sort by code point, not by UTF-16 code unit`() {
        // One astral character (U+1F600, encoded as a surrogate pair) and one BMP
        // character above U+E000 (U+FFFD). Code-unit order puts the surrogate first
        // (0xD83D < 0xFFFD); code-point order puts U+FFFD first (0xFFFD < 0x1F600).
        // Only this pair distinguishes the two rules, which is why the test exists:
        // every ASCII fixture passes under either.
        val astral = "\uD83D\uDE00"   // U+1F600
        val bmpHigh = "\uFFFD"         // U+FFFD

        val encoded = CanonicalJson.write(
            JsonObject(
                linkedMapOf(
                    astral to JsonNumber("1"),
                    bmpHigh to JsonNumber("2"),
                ),
            ),
        )

        assertEquals("{\"$bmpHigh\":2,\"$astral\":1}", encoded)
    }

    private fun codeOf(block: () -> Unit): String = try {
        block()
        fail("expected the projection to fail loud")
        ""
    } catch (error: UiStateProjectionException) {
        error.code
    }

    private companion object {
        const val SESSION: String = "sess-1"
    }
}
