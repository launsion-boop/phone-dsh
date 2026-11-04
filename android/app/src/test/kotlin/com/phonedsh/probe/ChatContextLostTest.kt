// The one state this lane must never produce silently (L85 P0).
// SPDX-License-Identifier: MIT
//
// ---- what this test pins ------------------------------------------------
// When the Worker answers `session/not-found` for a conversation's stored
// session, the send can only continue in a new session — but the transcript
// still shows the earlier bubbles. That is the worst state for a person: the
// model looks like it is pretending not to remember, while the UI says it
// should. The App's answer is a durable `status` row written into the
// transcript plus the transient banner, both produced from
// [contextLostNode]/[ChatUiState.error]. This test proves the two surfaces
// really appear for that node, so the notice cannot regress into a log line.
package com.phonedsh.probe

import com.phonedsh.agentcore.JsonString
import com.phonedsh.ui.state.ChatRow
import com.phonedsh.ui.projection.UiStateKind
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class ChatContextLostTest {
    private val sentence =
        "上一段上下文已丢失：之前那轮对话的 Worker 会话已经无法恢复（session/not-found），" +
            "这条消息开了一个新会话，模型看不到本对话更早的内容。"

    @Test
    fun theRowNamesTheConversationAndTheReason() {
        val node = contextLostNode("chat-42", "t7-3", sentence)
        assertEquals(UiStateKind.STATUS, node.kind)
        assertEquals("context_lost", (node.props["reason"] as? JsonString)?.value)
        assertEquals(sentence, (node.props["detail"] as? JsonString)?.value)
        assertEquals(sentence, node.text)
        // The row must be persisted with the transcript: its id is a normal
        // transcript path, not a transient banner slot.
        assertTrue(
            "the context-lost row is not a transcript node: ${node.nodeID}",
            node.nodeID.startsWith("session/chat-42/turn/") && node.nodeID.endsWith("/context-lost"),
        )
        assertEquals("session/chat-42/turn/t7-3-context-lost", node.parentID)
    }

    @Test
    fun theChatShowsTheRowAndTheBanner() {
        val node = contextLostNode("chat-42", "t7-3", sentence)
        val state = chatScreenState(
            ui = ChatUiState(
                chatId = "chat-42",
                nodes = listOf(node),
                error = sentence,
                bannerDismissed = false,
            ),
            engineStarted = true,
            providerNeedsKey = false,
            canSend = true,
        )
        val row = state.rows.filterIsInstance<ChatRow.SystemEvent>()
            .firstOrNull { it.id == node.nodeID }
        assertTrue(
            "the transcript does not render the context-lost node as a system event; " +
                "rows=${state.rows.map { it::class.simpleName }}",
            row != null,
        )
        assertEquals("the row must carry the sentence, not a bare reason token", sentence, row?.text)
        assertTrue(
            "no fail-loud banner carries the context-lost sentence",
            state.banners.any { it.message == sentence },
        )
    }

    @Test
    fun theRowSurvivesTheTranscriptProjection() {
        // The page folds every stored row; a status row with a reason that is not
        // a turn end must not be dropped by the fold.
        val node = contextLostNode("chat-42", "t7-3", sentence)
        val state = chatScreenState(
            ui = ChatUiState(chatId = "chat-42", nodes = listOf(node)),
            engineStarted = true,
            providerNeedsKey = false,
            canSend = true,
        )
        assertTrue(
            "the persisted row disappeared when the chat was reopened without a banner",
            state.rows.any { it is ChatRow.SystemEvent && it.text == sentence },
        )
    }
}
