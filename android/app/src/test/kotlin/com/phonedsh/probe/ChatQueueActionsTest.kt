// The Android queue transaction over the real ViewModel state: success, failure,
// not-found and the local SENDING echo. The transport is scripted because the
// Worker is the external edge; every assertion here is on the published
// ChatUiState the page consumes.
// SPDX-License-Identifier: MIT
package com.phonedsh.probe

import com.phonedsh.dsh.turn.DshTurnException
import com.phonedsh.ui.state.CommandOutcome
import com.phonedsh.ui.state.EnterMode
import com.phonedsh.ui.state.ManagedQueueItemState
import com.phonedsh.ui.state.QueueAction
import com.phonedsh.ui.state.QueueItemId
import com.phonedsh.ui.state.QueueItemStatus
import com.phonedsh.ui.state.StateRequestId
import com.phonedsh.ui.state.reconcileQueueRows
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ChatQueueActionsTest {
    private fun row(
        id: String,
        text: String = "queued $id",
        lane: String = "next-turn",
    ): ManagedQueueItemState = ManagedQueueItemState(
        id = QueueItemId.Durable(id),
        text = text,
        state = QueueItemStatus.QUEUED,
        canEdit = true,
        canRemove = true,
        canSteer = true,
        lane = lane,
        sessionId = WORKER,
    )

    private fun uiState(
        queueItems: List<ManagedQueueItemState>,
        localQueueItems: List<ManagedQueueItemState> = emptyList(),
        draft: String = "",
        running: Boolean = true,
    ): ChatUiState = ChatUiState(
        chatId = CHAT,
        workerSessionId = WORKER,
        running = running,
        draft = draft,
        sessionSnapshot = ChatSessionSnapshot(queueItems = queueItems),
        localQueueItems = localQueueItems,
    )

    private fun actions(
        chat: MutableStateFlow<ChatUiState>,
        transport: ChatQueueTransport,
        refresh: () -> Unit = {},
    ): ChatQueueActions = ChatQueueActions(
        chat = chat,
        scope = CoroutineScope(Dispatchers.Unconfined),
        transport = transport,
        refresh = refresh,
        log = {},
    )

    @Test
    fun `not found removes the consumed row instead of restoring the captured snapshot`() {
        val target = row("q-target")
        val other = row("q-old-other")
        val added = row("q-added", "added while the action ran")
        val state = MutableStateFlow(uiState(listOf(target, other)))
        val transport = ScriptedTransport().apply {
            updateFailure = DshTurnException("session/queue-item-not-found", "the item was claimed")
            rows = listOf(other, added)
        }

        assertTrue(actions(state, transport).updateQueueItem(target, QueueAction.REMOVE, StateRequestId("act-1")))

        val after = state.value.sessionSnapshot.queueItems.orEmpty()
        assertEquals(listOf(QueueItemId.Durable("q-old-other"), QueueItemId.Durable("q-added")), after.map { it.id })
        assertTrue(after.none { it.id == target.id })
    }

    @Test
    fun `steer unavailable converges silently to the fresh projection`() {
        val target = row("q-target")
        val other = row("q-other")
        val added = row("q-added", "added while the steer ran")
        val state = MutableStateFlow(uiState(listOf(target, other)))
        val transport = ScriptedTransport().apply {
            updateFailure = DshTurnException("session/steer-unavailable", "the turn already ended")
            rows = listOf(target, other, added)
        }

        assertTrue(actions(state, transport).updateQueueItem(target, QueueAction.STEER, StateRequestId("steer-1")))

        val after = state.value.sessionSnapshot.queueItems.orEmpty()
        assertEquals(listOf(target.id, other.id, added.id), after.map { it.id })
        val restored = after.first { it.id == target.id }
        assertNull(restored.receipt)
        assertEquals(false, restored.busy)
        assertNull(restored.actionRequestId)
    }

    @Test
    fun `failed action with a failed readback mutates the target row and keeps newer rows`() {
        val target = row("q-target")
        val other = row("q-other")
        val added = row("q-added", "arrived during the action")
        val state = MutableStateFlow(uiState(listOf(target, other)))
        val transport = ScriptedTransport().apply {
            updateFailure = DshTurnException("gateway/unavailable", "transport closed")
            readFailure = DshTurnException("gateway/unavailable", "transport closed")
            onUpdate = {
                state.value = state.value.copy(
                    sessionSnapshot = state.value.sessionSnapshot.copy(
                        queueItems = listOf(target, other, added),
                    ),
                )
            }
        }

        assertTrue(actions(state, transport).updateQueueItem(target, QueueAction.EDIT, StateRequestId("edit-1"), "new text"))

        val after = state.value.sessionSnapshot.queueItems.orEmpty()
        assertEquals(listOf(target.id, other.id, added.id), after.map { it.id })
        val failed = after.first { it.id == target.id }
        assertEquals(CommandOutcome.FAILED, failed.receipt?.outcome)
        assertEquals("edit-1", failed.actionRequestId?.value)
        assertEquals(false, failed.busy)
    }

    @Test
    fun `edit success publishes the readback and a success receipt`() {
        val target = row("q-target", "old text")
        val other = row("q-other")
        val edited = target.copy(text = "new text")
        val state = MutableStateFlow(uiState(listOf(target, other)))
        val transport = ScriptedTransport().apply { rows = listOf(edited, other) }

        assertTrue(actions(state, transport).updateQueueItem(target, QueueAction.EDIT, StateRequestId("edit-2"), "new text"))

        val after = state.value.sessionSnapshot.queueItems.orEmpty()
        assertEquals("new text", after.first { it.id == target.id }.text)
        assertEquals(CommandOutcome.SUCCEEDED, after.first { it.id == target.id }.receipt?.outcome)
        assertEquals(listOf(QueueAction.EDIT), transport.updates.map { it.action })
    }

    @Test
    fun `accepted prompt retires its local row even when the readback fails`() {
        val state = MutableStateFlow(uiState(emptyList(), draft = "  hello worker  "))
        val transport = ScriptedTransport().apply {
            readFailure = DshTurnException("invalid_response", "projection read failed")
        }

        assertTrue(
            actions(state, transport).submitWhileRunning(
                WORKER, StateRequestId("submit-1"), "hello worker", EnterMode.QUEUE,
            ),
        )

        val after = state.value
        assertTrue(after.localQueueItems.isEmpty())
        assertTrue(after.localQueueItems.none { it.state == QueueItemStatus.SENDING })
        assertEquals("", after.draft)
        assertEquals("hello worker", after.lastSubmission)
        assertNull(after.retryBusyPromptRequestId)
        assertEquals(1, transport.prompts.size)
    }

    @Test
    fun `accepted prompt retires its local row and publishes the durable readback`() {
        val durable = ManagedQueueItemState(
            id = QueueItemId.Durable("q-accepted"),
            text = "hello worker",
            state = QueueItemStatus.QUEUED,
            lane = "next-turn",
            sessionId = WORKER,
            promptRequestId = StateRequestId("submit-5"),
        )
        val state = MutableStateFlow(uiState(emptyList(), draft = "hello worker"))
        val transport = ScriptedTransport().apply { rows = listOf(durable) }

        assertTrue(
            actions(state, transport).submitWhileRunning(
                WORKER, StateRequestId("submit-5"), "hello worker", EnterMode.QUEUE,
            ),
        )

        assertTrue(state.value.localQueueItems.isEmpty())
        assertEquals(listOf(QueueItemId.Durable("q-accepted")), state.value.sessionSnapshot.queueItems?.map { it.id })
    }

    @Test
    fun `failed prompt becomes a visible failed row instead of a permanent sending spinner`() {
        val state = MutableStateFlow(uiState(emptyList(), draft = "hello worker"))
        val transport = ScriptedTransport().apply {
            promptFailure = DshTurnException("channel_closed", "the worker restarted")
        }

        assertTrue(
            actions(state, transport).submitWhileRunning(
                WORKER, StateRequestId("submit-2"), "hello worker", EnterMode.QUEUE,
            ),
        )

        val after = state.value
        val failed = after.localQueueItems.single()
        assertEquals(QueueItemStatus.QUEUED, failed.state)
        assertEquals(false, failed.busy)
        assertEquals(CommandOutcome.FAILED, failed.receipt?.outcome)
        assertEquals("hello worker", after.draft)
        assertEquals(StateRequestId(failed.promptRequestId!!.value), after.retryBusyPromptRequestId)
    }

    @Test
    fun `retrying a failed busy prompt reuses its identity and never duplicates the row`() {
        val state = MutableStateFlow(uiState(emptyList(), draft = "hello worker"))
        val durable = ManagedQueueItemState(
            id = QueueItemId.Durable("q-accepted"),
            text = "hello worker",
            state = QueueItemStatus.QUEUED,
            lane = "next-turn",
            sessionId = WORKER,
            promptRequestId = StateRequestId("reused-prompt"),
        )
        val transport = ScriptedTransport().apply {
            promptFailure = DshTurnException("channel_closed", "the worker restarted")
        }
        val actions = actions(state, transport)
        assertTrue(actions.submitWhileRunning(WORKER, StateRequestId("submit-3"), "hello worker", EnterMode.QUEUE))
        val failed = state.value.localQueueItems.single()
        val reused = failed.promptRequestId!!

        // The reconnect read now sees the server-side row for the same rpcId.
        transport.promptFailure = null
        transport.rows = listOf(durable.copy(promptRequestId = reused))
        assertEquals(
            listOf(QueueItemId.Durable("q-accepted")),
            reconcileQueueRows(transport.rows, state.value.localQueueItems).map { it.id },
        )
        assertTrue(actions.submitWhileRunning(WORKER, StateRequestId("submit-4"), "hello worker", EnterMode.QUEUE))

        assertEquals(listOf(reused, reused), transport.promptRequestIds.map { StateRequestId(it) })
        assertTrue(state.value.localQueueItems.isEmpty())
        assertEquals(listOf(QueueItemId.Durable("q-accepted")), state.value.sessionSnapshot.queueItems?.map { it.id })
    }

    private class ScriptedTransport : ChatQueueTransport {
        data class UpdateCall(val workerSessionId: String, val itemId: String, val action: QueueAction, val replacement: String?)

        val updates = mutableListOf<UpdateCall>()
        val prompts = mutableListOf<String>()
        val promptRequestIds = mutableListOf<String>()
        var rows: List<ManagedQueueItemState> = emptyList()
        var updateFailure: Exception? = null
        var promptFailure: Exception? = null
        var readFailure: Exception? = null
        var onUpdate: suspend () -> Unit = {}

        override suspend fun updateQueue(
            workerSessionId: String,
            itemId: String,
            action: QueueAction,
            replacement: String?,
        ) {
            updates += UpdateCall(workerSessionId, itemId, action, replacement)
            onUpdate()
            updateFailure?.let { throw it }
        }

        override suspend fun readQueue(workerSessionId: String): List<ManagedQueueItemState> =
            readFailure?.let { throw it } ?: rows

        override suspend fun prompt(workerSessionId: String, text: String, requestId: String, mode: String) {
            prompts += "$mode:$text"
            promptRequestIds += requestId
            promptFailure?.let { throw it }
        }
    }

    private companion object {
        const val CHAT = "chat-1"
        const val WORKER = "worker-1"
    }
}
