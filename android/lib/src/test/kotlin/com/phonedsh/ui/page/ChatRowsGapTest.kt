// SPDX-License-Identifier: MIT
package com.phonedsh.ui.page

import androidx.compose.runtime.SideEffect
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.test.junit4.createComposeRule
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
class ChatRowsGapTest {
    @get:Rule
    val compose = createComposeRule()
    private val gapInput = mutableStateOf<Pair<ChatRow?, ChatRow>>(null to ChatRow.User("initial", ""))
    private var installed = false
    private var actual: Dp? = null

    @Test
    fun `user messages use the paragraph gap and following process rows use the block gap`() {
        assertGap(previous = ChatRow.User("u", "hello"), current = ChatRow.Thinking("t", "thinking", false), expected = 16.dp)
        assertGap(previous = ChatRow.Thinking("t", "thinking", false), current = ChatRow.ToolRun("tools", emptyList()), expected = 20.dp)
        assertGap(previous = ChatRow.User("u", "hello"), current = ChatRow.QuestionReply("q", "reply"), expected = 16.dp)
    }

    @Test
    fun `assistant response and other non-user blocks use the twenty point block gap`() {
        assertGap(previous = ChatRow.User("u", "hello"), current = ChatRow.Assistant("a", "answer"), expected = 16.dp)
        assertGap(previous = ChatRow.Assistant("a", "answer"), current = ChatRow.ToolRun("tools", emptyList()), expected = 20.dp)
    }

    @Test
    fun `turn process and tail obey the user paragraph and block gap rules`() {
        val process = ChatRow.TurnProcess("turn-process/t1", "t1", ChatTurnState.COMPLETED)
        val tail = ChatRow.TurnTail("turn-tail/t1", "t1", "answer")
        assertGap(previous = ChatRow.User("u", "prompt"), current = process, expected = 16.dp)
        assertGap(previous = process, current = ChatRow.Assistant("a", "answer"), expected = 20.dp)
        assertGap(previous = process, current = tail, expected = 20.dp)
        assertGap(previous = ChatRow.Assistant("a", "answer"), current = tail, expected = 20.dp)
        assertGap(previous = ChatRow.User("u", "prompt"), current = tail, expected = 16.dp)
    }

    @Test
    fun `first transcript row has no added gap`() {
        assertGap(previous = null, current = ChatRow.User("u", "hello"), expected = null)
    }

    private fun assertGap(previous: ChatRow?, current: ChatRow, expected: Dp?) {
        if (installed) {
            compose.runOnIdle { gapInput.value = previous to current }
        } else {
            gapInput.value = previous to current
            compose.setContent {
                PdshTheme {
                    val input = gapInput.value
                    val measured = rowGap(input.first, input.second)
                    SideEffect { actual = measured }
                }
            }
            installed = true
        }
        compose.waitForIdle()
        assertEquals(expected, actual)
    }
}
