// The projection that makes the changed-files card real.
// SPDX-License-Identifier: MIT
//
// iOS derives the card from the turn's tool calls, not from a second event stream:
// `NativeTranscriptProjector.changes(forTurn:in:)` scans the turn's `toolCall`
// items whose state settled to `.ok`, reads `file_path` / `old_string` /
// `new_string` (or the `str_replace_editor` command form) from the arguments, and
// runs the line diff. `ChatScreenState.from` does the same over the UiState nodes
// and hangs the result on the closing assistant row, which is where the iOS page
// draws the card (`ChatPage.swift:3699-3701`).
package com.phonedsh.ui.state

import com.phonedsh.agentcore.JsonBool
import com.phonedsh.agentcore.JsonObject
import com.phonedsh.agentcore.JsonString
import com.phonedsh.agentcore.JsonValue
import com.phonedsh.ui.projection.UiStateKind
import com.phonedsh.ui.projection.UiStateNode
import com.phonedsh.ui.surface.ChatFileChange
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class ChangedFilesProjectionTest {
    @Test
    fun `a settled edit becomes one changed file on the closing answer`() {
        val state = ChatScreenState.from(nodes(toolCall(), toolResult()))
        val assistant = allTurnRows(state.rows).filterIsInstance<ChatRow.Assistant>().single()
        assertTrue("a closed turn's last answer is the closing row", assistant.closing)
        assertEquals(
            listOf(ChatFileChange("notes/a.md", "notes/a.md", 1, 1)),
            assistant.changes,
        )
    }

    @Test
    fun `write and str_replace_editor arguments are read the way the iOS projector reads them`() {
        val write = toolCall(
            id = "write",
            name = "write",
            arguments = """{"file_path":"notes/new.md","content":"one\ntwo"}""",
        )
        val create = toolCall(
            id = "create",
            name = "str_replace_editor",
            arguments = """{"command":"create","path":"notes/created.md","file_text":"x"}""",
        )
        val state = ChatScreenState.from(
            nodes(
                write,
                toolResult("write"),
                create,
                toolResult("create", slot = "tool-result-2", seq = 6),
            ),
        )
        val changes = allTurnRows(state.rows).filterIsInstance<ChatRow.Assistant>().single().changes
        assertEquals(
            listOf(
                // A write has no old text: iOS sees one empty old line, so +2 -1.
                ChatFileChange("notes/new.md", "notes/new.md", 2, 1),
                ChatFileChange("notes/created.md", "notes/created.md", 1, 1),
            ),
            changes,
        )
    }

    @Test
    fun `a failed or still-running edit is not counted`() {
        val state = ChatScreenState.from(
            nodes(
                toolCall(id = "failed"),
                toolResult(id = "failed", isError = true),
                toolCall(id = "running", seq = 9, slot = "tool-call-2"),
            ),
        )
        assertTrue(allTurnRows(state.rows).filterIsInstance<ChatRow.Assistant>().single().changes.isEmpty())
    }

    @Test
    fun `a non-writing tool is not a changed file`() {
        val state = ChatScreenState.from(
            nodes(
                toolCall(name = "bash", arguments = """{"command":"ls"}"""),
                toolResult(),
            ),
        )
        assertTrue(allTurnRows(state.rows).filterIsInstance<ChatRow.Assistant>().single().changes.isEmpty())
    }

    @Test
    fun `two edits to one path keep one entry, the later call winning`() {
        val state = ChatScreenState.from(
            nodes(
                toolCall(
                    id = "first",
                    // Three added lines vs one: if the later call did not win, the
                    // expected entry below would read +3 -1.
                    arguments = """{"file_path":"notes/a.md","old_string":"a","new_string":"a\nb\nc"}""",
                ),
                toolResult(id = "first"),
                toolCall(
                    id = "second",
                    seq = 9,
                    slot = "tool-call-2",
                    arguments = """{"file_path":"notes/a.md","old_string":"a\nb\nc","new_string":"a\nc"}""",
                ),
                toolResult(id = "second", slot = "tool-result-2", seq = 10),
            ),
        )
        assertEquals(
            listOf(ChatFileChange("notes/a.md", "notes/a.md", 0, 1)),
            allTurnRows(state.rows).filterIsInstance<ChatRow.Assistant>().single().changes,
        )
    }

    // ------------------------------------------------------------------ fixtures

    /** Inspect all source content, including entries hidden by the default completed-turn fold. */
    private fun allTurnRows(rows: List<ChatRow>): List<ChatRow> = rows.flatMap { row ->
        when (row) {
            is ChatRow.ProcessGroup -> allTurnRows(row.entries)
            is ChatRow.TurnProcess -> allTurnRows(row.entries)
            is ChatRow.TurnTail -> emptyList()
            else -> listOf(row)
        }
    }

    private val turnID: String = "session/s1/turn/turn-0001"

    private fun nodes(vararg extra: UiStateNode): List<UiStateNode> = listOf(
        UiStateNode(UiStateKind.TURN, turnID, "session/s1", "s1", "turn-0001", 0),
        *extra,
        UiStateNode(
            kind = UiStateKind.BUBBLE,
            nodeID = "$turnID/event/4/assistant-message",
            parentID = "$turnID/event/4",
            sessionID = "s1",
            turnID = "turn-0001",
            seq = 4,
            text = "Done.",
            props = JsonObject(mapOf("role" to JsonString("assistant"))),
        ),
        UiStateNode(
            kind = UiStateKind.STATUS,
            nodeID = "$turnID/event/5/turn",
            parentID = "$turnID/event/5",
            sessionID = "s1",
            turnID = "turn-0001",
            seq = 5,
            props = JsonObject(mapOf("reason" to JsonString("completed"))),
        ),
    )

    private fun toolCall(
        id: String = "edit",
        name: String = "edit",
        arguments: String =
            """{"file_path":"notes/a.md","old_string":"旧结构","new_string":"官方原生结构"}""",
        seq: Int = 2,
        slot: String = "tool-call",
    ): UiStateNode = UiStateNode(
        kind = UiStateKind.TOOL_ROW,
        nodeID = "$turnID/event/$seq/$slot",
        parentID = "$turnID/event/$seq",
        sessionID = "s1",
        turnID = "turn-0001",
        seq = seq,
        props = JsonObject(
            mapOf(
                "arguments" to JsonString(arguments),
                "callId" to JsonString(id),
                "name" to JsonString(name),
                "phase" to JsonString("call"),
                "state" to JsonString("running"),
            ),
        ),
    )

    private fun toolResult(
        id: String = "edit",
        isError: Boolean = false,
        seq: Int = 3,
        slot: String = "tool-result",
    ): UiStateNode = UiStateNode(
        kind = UiStateKind.TOOL_ROW,
        nodeID = "$turnID/event/$seq/$slot",
        parentID = "$turnID/event/$seq",
        sessionID = "s1",
        turnID = "turn-0001",
        seq = seq,
        props = JsonObject(
            mapOf(
                "callId" to JsonString(id),
                "isError" to JsonBool(isError),
                "phase" to JsonString("result"),
                "state" to JsonString(if (isError) "error" else "ok"),
            ),
        ),
    )
}
