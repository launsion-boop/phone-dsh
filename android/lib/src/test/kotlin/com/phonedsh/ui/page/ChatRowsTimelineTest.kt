// SPDX-License-Identifier: MIT
package com.phonedsh.ui.page

import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import com.phonedsh.ui.state.ChatProcessCategory
import com.phonedsh.ui.state.ChatRow
import com.phonedsh.ui.state.ChatTurnState
import com.phonedsh.ui.theme.PdshTheme
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
class ChatRowsTimelineTest {
    @get:Rule
    val compose = createComposeRule()

    @Test
    fun `folded turn keeps its final answer and toggle addresses the real turn`() {
        var toggled: String? = null
        val closing = ChatRow.Assistant(id = "answer", text = "final answer")
        val row = ChatRow.TurnProcess(
            id = "turn-process/t1",
            turnID = "t1",
            outcome = ChatTurnState.COMPLETED,
            foldable = true,
            expanded = false,
            entries = listOf(ChatRow.Thinking("think", "private reasoning", false), closing),
            closingAssistant = closing,
        )
        compose.setContent {
            PdshTheme {
                ChatRowItem(row, expandedRowIds = emptySet(), onToggleRow = { toggled = it })
            }
        }
        compose.onNodeWithTag("pdsh.chat.turn-process").assertIsDisplayed()
        compose.onNodeWithText("final answer").assertIsDisplayed()
        compose.onNodeWithText("private reasoning").assertDoesNotExist()
        compose.onNodeWithTag("pdsh.chat.turn-process").performClick()
        assertEquals("turn-process/t1", toggled)
    }

    @Test
    fun `process group starts open and can be folded through its group id`() {
        var toggled: String? = null
        val row = ChatRow.ProcessGroup(
            id = "process/t1/tools",
            turnID = "t1",
            entries = listOf(ChatRow.Thinking("think", "分析中", false)),
            categories = listOf(ChatProcessCategory.THINKING),
            title = "已完成分析",
            running = false,
            showsHeader = true,
        )
        compose.setContent {
            PdshTheme {
                ChatRowItem(row, expandedRowIds = emptySet(), onToggleRow = { toggled = it })
            }
        }
        compose.onNodeWithTag("pdsh.chat.process-group").assertIsDisplayed()
        compose.onNodeWithText("分析中").assertIsDisplayed()
        compose.onNodeWithTag("pdsh.chat.process-group").performClick()
        assertEquals("process/t1/tools", toggled)
    }

    @Test
    fun `turn tail copy provides immediate feedback`() {
        val row = ChatRow.TurnTail(id = "tail", turnID = "t1", assistantText = "whole turn answer")
        compose.setContent {
            PdshTheme {
                ChatRowItem(row, expandedRowIds = emptySet(), onToggleRow = {})
            }
        }
        compose.onNodeWithContentDescription("复制").performClick()
        compose.onNodeWithContentDescription("复制成功").assertIsDisplayed()
    }

    @Test
    fun `thinking disclosure shows only the actual bounded reasoning and its truncation receipt`() {
        val row = ChatRow.Thinking(
            id = "think-source",
            summary = "summary only",
            streaming = false,
            fullReasoning = "reasoning from source",
            fullReasoningTruncated = true,
        )
        compose.setContent {
            PdshTheme {
                ChatRowItem(row, expandedRowIds = setOf(row.id), onToggleRow = {})
            }
        }
        compose.onNodeWithText("reasoning from source").assertIsDisplayed()
        compose.onNodeWithText("仅显示部分思考内容").assertIsDisplayed()
    }

    @Test
    fun `assistant markdown preserves the full resource URI through its host route`() {
        val resource = "dsh-resource://file/session/session-A/dsh/workspace/docs/readme.md"
        var opened: String? = null
        compose.setContent {
            PdshTheme {
                ChatRowItem(
                    ChatRow.Assistant("answer", "[Open file]($resource)"),
                    expandedRowIds = emptySet(),
                    onToggleRow = {},
                    onOpenResource = { opened = it },
                )
            }
        }
        // The shared menu wrapper is one merged long-press node (rule 1), so the
        // link lives in the unmerged tree; a tap on the link's own glyphs is still
        // the markdown body's action, not the row's.
        compose.onNodeWithText("Open file", useUnmergedTree = true).performClick()
        assertEquals(resource, opened)
    }
}
