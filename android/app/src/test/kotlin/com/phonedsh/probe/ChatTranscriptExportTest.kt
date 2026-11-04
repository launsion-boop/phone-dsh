// 导出对话记录 and the `@` menu's host facts.
// SPDX-License-Identifier: MIT
package com.phonedsh.probe

import com.phonedsh.agentcore.JsonObject
import com.phonedsh.agentcore.JsonString
import com.phonedsh.ui.UiStrings
import com.phonedsh.ui.state.ChatRow
import com.phonedsh.ui.state.ToolEntry
import com.phonedsh.ui.surface.ToolRowState
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class ChatTranscriptExportTest {
    @Test
    fun `Markdown follows the iOS section and title mapping`() {
        val rows = listOf(
            ChatRow.User("u1", "帮我看看这份 CSV"),
            ChatRow.User("u2", "顺便再查一下", badge = UiStrings.STEERED_TAG),
            ChatRow.Assistant("a1", "已经看完了。"),
            ChatRow.ToolRun(
                id = "run",
                entries = listOf(
                    ToolEntry(
                        id = "call",
                        title = "bash",
                        summary = UiStrings.TOOL_RUNNING,
                        state = ToolRowState.RUNNING,
                        arguments = JsonObject(mapOf("command" to JsonString("ls"))),
                    ),
                    ToolEntry(
                        id = "result",
                        title = "bash",
                        summary = "a.csv",
                        state = ToolRowState.OK,
                        body = "a.csv\nb.csv",
                    ),
                    ToolEntry(
                        id = "error",
                        title = "bash",
                        summary = "permission denied",
                        state = ToolRowState.ERROR,
                        body = "permission denied",
                    ),
                ),
            ),
            // The turn-end status is the one row kind the export skips.
            ChatRow.SystemEvent("status", "已停止", "interrupted", isError = true),
        )

        val markdown = chatTranscriptMarkdown("排查 CSV", rows)

        assertEquals(
            """
            # 排查 CSV

            ### 你

            帮我看看这份 CSV

            ### 你（补充说明）

            顺便再查一下

            ### DSH

            已经看完了。

            ### 工具调用 · bash

            {"command":"ls"}

            ### 工具结果

            a.csv
            b.csv

            ### 工具错误

            permission denied
            """.trimIndent(),
            markdown,
        )
    }

    @Test
    fun `an interrupted tool call keeps the result heading`() {
        val markdown = chatTranscriptMarkdown(
            "中断",
            listOf(
                ChatRow.ToolRun(
                    id = "run",
                    entries = listOf(
                        ToolEntry(
                            id = "stopped",
                            title = "bash",
                            summary = "interrupted",
                            state = ToolRowState.STOPPED,
                            body = "已停止",
                        ),
                    ),
                ),
            ),
        )

        assertEquals("# 中断\n\n### 工具结果\n\n已停止", markdown)
    }

    @Test
    fun `a closed turn exports its process entries once`() {
        val markdown = chatTranscriptMarkdown(
            "继续",
            listOf(
                ChatRow.TurnProcess(
                    id = "turn",
                    turnID = "t1",
                    outcome = com.phonedsh.ui.state.ChatTurnState.COMPLETED,
                    entries = listOf(ChatRow.Assistant("a", "答案")),
                ),
                ChatRow.TurnTail("tail", "t1", assistantText = "答案"),
            ),
        )
        assertEquals("# 继续\n\n### DSH\n\n答案", markdown)
    }

    @Test
    fun `the at menu projects workspace files and session titles`() {
        val files = listOf("reports/ui-smoke.csv", "notes.md")
        val sessions = listOf("ui-smoke review", "另一个会话")

        val all = chatScreenState(
            ChatUiState(chatId = "current", draft = "@"),
            engineStarted = true,
            providerNeedsKey = false,
            canSend = true,
            files = files,
            sessionTitles = sessions,
        )
        assertEquals(files, all.composer.reference?.files)
        assertTrue("an empty token lists no session titles", all.composer.reference?.sessions.orEmpty().isEmpty())

        val filtered = chatScreenState(
            ChatUiState(chatId = "current", draft = "@ui-smoke"),
            engineStarted = true,
            providerNeedsKey = false,
            canSend = true,
            files = files,
            sessionTitles = sessions,
        )
        assertEquals(listOf("reports/ui-smoke.csv"), filtered.composer.reference?.files)
        assertEquals(listOf("ui-smoke review"), filtered.composer.reference?.sessions)
    }

    @Test
    fun `mention titles skip the current and archived conversations`() {
        val records = listOf(
            ChatRecord("current", "当前会话", 3, emptyList(), emptyList()),
            ChatRecord("active", "ui-smoke", 2, emptyList(), emptyList()),
            ChatRecord("archived", "旧会话", 1, emptyList(), emptyList(), archived = true),
            ChatRecord("blank", "   ", 0, emptyList(), emptyList()),
        )
        assertEquals(listOf("ui-smoke"), chatMentionSessionTitles(records, "current"))
    }
}
