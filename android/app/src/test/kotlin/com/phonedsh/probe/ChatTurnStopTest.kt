// The stop path must close the turn it stopped.
// SPDX-License-Identifier: MIT
//
// ---- the device defect this pins ---------------------------------------
// A real turn was started (`bash sleep 45`), then 停止 was pressed. The old
// stop path wrote a turn-end for a synthetic `turnIdOf("stopped")`, so the real
// `TURN` node stayed open. The composer therefore kept saying 排入下一轮 and the
// record persisted that open node, which is why a cold start did not recover.
//
// These tests drive the production objects the ViewModel calls on stop and on
// restore/open (`ChatStopWiring`, `ChatRecordRepair`) plus the real
// `ChatSessionStore`, so the shared writer invocation, persistence, the
// in-flight send gate and the screen projection are all exercised.
package com.phonedsh.probe

import com.phonedsh.agentcore.JsonObject
import com.phonedsh.agentcore.JsonString
import com.phonedsh.agentcore.JsonValue
import com.phonedsh.domain.DomainStoreCore
import com.phonedsh.domain.QuotaPolicy
import com.phonedsh.domain.testing.InMemoryConnectionFactory
import com.phonedsh.hostevents.HostEvent
import com.phonedsh.hostevents.HostEventProjection
import com.phonedsh.platform.Clock
import com.phonedsh.ui.UiStrings
import com.phonedsh.ui.projection.UiStateKind
import com.phonedsh.ui.projection.UiStateNode
import com.phonedsh.ui.state.ChatPhase
import com.phonedsh.ui.state.ChatRow
import com.phonedsh.ui.state.ChatTurnState
import com.phonedsh.ui.composer.ComposerSendLayout
import com.phonedsh.ui.composer.ComposerSendRule
import java.util.concurrent.atomic.AtomicBoolean
import kotlinx.coroutines.flow.MutableStateFlow
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class ChatTurnStopTest {
    private val chatId = "chat-1793681100398-1"
    private val turnToken = "t1793681101000-1"
    private val realTurnId = "$turnToken-turn-0001"

    private fun event(json: String): HostEvent {
        val raw = JsonValue.parse(json) as JsonObject
        return HostEventProjection.projectAll(raw).first()
    }

    private fun runningState(): ChatUiState = ChatUiState(
        chatId = chatId,
        turnToken = turnToken,
        workerSessionId = "worker-1",
        running = true,
        draft = "",
    )

    private fun screen(ui: ChatUiState) = chatScreenState(
        ui = ui,
        engineStarted = true,
        providerNeedsKey = false,
        canSend = true,
    )

    @Test
    fun `stopping closes the real turn and frees the composer`() {
        var ui = runningState()
        ui = ui.applyChatEvent(
            chatId,
            event("""{"type":"turn/start","seq":1,"data":{"turn":1}}"""),
            0,
        )
        ui = ui.applyChatEvent(
            chatId,
            event("""{"type":"tool/call","seq":2,"data":{"turn":1,"name":"bash","callId":"c1"}}"""),
            1,
        )

        val before = screen(ui)
        assertEquals("a started turn must make the dock RUNNING", ChatPhase.RUNNING, before.phase)
        assertEquals(
            ComposerSendLayout.STOP,
            ComposerSendRule.layout(before.composer.running, before.composer.canSubmit),
        )

        val store = store()
        store.save(
            ChatRecord(
                id = chatId,
                title = "被停止的会话",
                updatedAtMs = 10L,
                workerSessionIds = listOf("worker-1"),
                nodes = ui.nodes,
            ),
        )
        val chat = MutableStateFlow(ui)
        val turnRunning = AtomicBoolean(true)
        val persistedIds = mutableListOf<String>()
        val stopped = ChatStopWiring(chat, turnRunning) { id ->
            persistedIds += id
            persistThroughSharedWriter(store, chat, id)
        }.stop(chatId, 1_790_000_000_000L)
        val after = screen(stopped.copy(draft = "继续"))

        assertEquals("stop must invoke the one shared writer", listOf(chatId), persistedIds)
        assertFalse("停止 must clear the in-flight gate for the next send", turnRunning.get())
        assertEquals("the Worker session is kept for model context", "worker-1", stopped.workerSessionId)
        val persisted = requireNotNull(store.load(chatId))
        assertEquals("the stop's closed transcript must reach the store", stopped.nodes, persisted.nodes)

        assertEquals("stop must leave the conversation idle", ChatPhase.IDLE, after.phase)
        assertFalse(after.composer.running)
        assertEquals(UiStrings.COMPOSER_PLACEHOLDER_IDLE, after.composer.placeholder)
        assertEquals(
            UiStrings.COMPOSER_SEND_LABEL,
            ComposerSendRule.sendLabel(after.composer.running, after.composer.steering),
        )
        assertTrue("the next message must be submittable at once", after.composer.canSubmit)
        assertTrue(
            "the stopped turn still reads as cancelled to the person",
            after.rows.any { row ->
                row is ChatRow.TurnProcess && row.outcome == ChatTurnState.STOPPED &&
                    row.entries.any { it is ChatRow.SystemEvent && it.title == UiStrings.SYSTEM_EVENT_TURN_CANCELLED }
            },
        )

        val end = stopped.nodes.single {
            it.kind == UiStateKind.STATUS && it.props.string("reason") == "cancelled"
        }
        assertEquals("session/$chatId/turn/$realTurnId/event/3/turn-end", end.nodeID)
        assertEquals("session/$chatId/turn/$realTurnId", end.parentID)
        assertEquals("the end must name the turn it closes", realTurnId, end.turnID)
    }

    @Test
    fun `stopping before TURN_STARTED is not RUNNING either`() {
        val chat = MutableStateFlow(runningState())
        val turnRunning = AtomicBoolean(true)
        val writerCalls = mutableListOf<String>()
        val stopped = ChatStopWiring(chat, turnRunning) { writerCalls += it }
            .stop(chatId, 1_790_000_000_001L)
        val after = screen(stopped.copy(draft = "继续"))

        assertEquals(listOf(chatId), writerCalls)
        assertFalse(turnRunning.get())
        assertEquals("worker-1", stopped.workerSessionId)
        assertNotEquals(ChatPhase.RUNNING, after.phase)
        assertEquals(ChatPhase.IDLE, after.phase)
        assertTrue(after.composer.canSubmit)
        assertEquals(UiStrings.COMPOSER_PLACEHOLDER_IDLE, after.composer.placeholder)
        // The person still sees one 回合已取消 row, even though the Worker had not
        // announced the turn yet. Its id must not be a real-turn lookalike.
        val end = stopped.nodes.single { it.kind == UiStateKind.STATUS }
        assertEquals("cancelled", end.props.string("reason"))
        assertEquals("session/$chatId/turn/$turnToken-stopped", end.parentID)
        assertTrue(
            after.rows.any { row ->
                row is ChatRow.TurnProcess && row.outcome == ChatTurnState.STOPPED &&
                    row.entries.any { it is ChatRow.SystemEvent && it.title == UiStrings.SYSTEM_EVENT_TURN_CANCELLED }
            },
        )
    }

    @Test
    fun `a stored conversation with an open TURN reopens idle and is repaired on disk`() {
        val store = store()
        val openTurn = turnNode(chatId, realTurnId)
        val tool = requireNotNull(
            chatNodeOf(
                chatId,
                turnToken,
                event("""{"type":"tool/call","seq":2,"data":{"turn":1,"name":"bash","callId":"c1"}}"""),
                1,
            ),
        )
        // The device row the old stop path wrote: an open real turn plus a
        // synthetic `-stopped` end that does not match it.
        val legacySynthetic = UiStateNode(
            kind = UiStateKind.STATUS,
            nodeID = "session/$chatId/turn/$turnToken-stopped/event/0/turn-end",
            parentID = "session/$chatId",
            sessionID = chatId,
            turnID = "$turnToken-stopped",
            seq = 0,
            text = "cancelled",
            props = JsonObject(mapOf(
                "reason" to JsonString("cancelled"),
                "detail" to JsonString(""),
            )),
        )
        store.save(
            ChatRecord(
                id = chatId,
                title = "被停止的会话",
                updatedAtMs = 10L,
                workerSessionIds = listOf("worker-1"),
                nodes = listOf(openTurn, tool, legacySynthetic),
            ),
        )
        val loaded = requireNotNull(store.load(chatId))
        assertEquals(ChatPhase.RUNNING, screen(loaded.toUiState().copy(running = true)).phase)

        val repaired = ChatRecordRepair(store).restore(
            records = listOf(loaded),
            liveChatId = "",
            turnRunning = false,
        ).single()
        val persisted = requireNotNull(store.load(chatId))

        assertNotEquals("the repair must be written back", loaded.nodes, persisted.nodes)
        assertEquals(repaired.nodes, persisted.nodes)
        val end = persisted.nodes.single {
            it.kind == UiStateKind.STATUS && it.props.string("reason") == "cancelled"
        }
        assertEquals("session/$chatId/turn/$realTurnId/event/3/turn-end", end.nodeID)
        assertEquals(realTurnId, end.turnID)

        val reopened = screen(persisted.toUiState().copy(draft = "继续"))
        assertEquals(ChatPhase.IDLE, reopened.phase)
        assertFalse(reopened.composer.running)
        assertTrue(reopened.composer.canSubmit)
        assertEquals(UiStrings.COMPOSER_PLACEHOLDER_IDLE, reopened.composer.placeholder)
    }

    @Test
    fun `a really running record keeps its open turn`() {
        val store = store()
        val openTurn = turnNode(chatId, realTurnId)
        store.save(
            ChatRecord(
                id = chatId,
                title = "仍运行的会话",
                updatedAtMs = 20L,
                workerSessionIds = listOf("worker-1"),
                nodes = listOf(openTurn),
            ),
        )
        val loaded = requireNotNull(store.load(chatId))

        val untouched = ChatRecordRepair(store).restore(
            records = listOf(loaded),
            liveChatId = chatId,
            turnRunning = true,
        ).single()

        assertEquals(loaded.nodes, untouched.nodes)
        assertEquals(loaded.nodes, requireNotNull(store.load(chatId)).nodes)
        assertEquals(ChatPhase.RUNNING, screen(untouched.toUiState().copy(running = true)).phase)
    }

    @Test
    fun `a late TURN_STARTED after stop cannot reopen the turn`() {
        var ui = runningState()
        ui = ui.applyChatEvent(
            chatId,
            event("""{"type":"turn/start","seq":1,"data":{"turn":1}}"""),
            0,
        )
        val chat = MutableStateFlow(ui)
        val stopped = ChatStopWiring(chat, AtomicBoolean(true)) {}.stop(chatId, 1_790_000_000_002L)
        val lateStart = event("""{"type":"turn/start","seq":2,"data":{"turn":2}}""")

        // The state transition itself rejects it; no stopChat re-entry is needed.
        val late = stopped.applyChatEvent(chatId, lateStart, 2)
        assertEquals(stopped.nodes, late.nodes)
        assertEquals(null, late.activeTurnNodeId)
        assertEquals(ChatPhase.IDLE, screen(late).phase)

        // The callback gate also rejects a frame whose generation stop invalidated.
        val gated = applyChatEventIfCurrent(
            current = stopped,
            chatId = chatId,
            event = lateStart,
            ordinal = 2,
            eventGeneration = 1,
            currentGeneration = 2,
        )
        assertEquals(stopped, gated)
    }

    @Test
    fun `restore repairs an inactive record and leaves the live one open`() {
        val store = store()
        val damagedId = "chat-damaged"
        val liveId = "chat-live"
        store.save(
            ChatRecord(
                id = damagedId,
                title = "损坏",
                updatedAtMs = 11L,
                workerSessionIds = listOf("worker-damaged"),
                nodes = listOf(turnNode(damagedId, realTurnId)),
            ),
        )
        store.save(
            ChatRecord(
                id = liveId,
                title = "运行中",
                updatedAtMs = 12L,
                workerSessionIds = listOf("worker-live"),
                nodes = listOf(turnNode(liveId, realTurnId)),
            ),
        )
        val records = listOf(
            requireNotNull(store.load(damagedId)),
            requireNotNull(store.load(liveId)),
        )

        val restored = ChatRecordRepair(store).restore(
            records = records,
            liveChatId = liveId,
            turnRunning = true,
        )
        val repaired = restored.first { it.id == damagedId }
        val untouched = restored.first { it.id == liveId }

        assertTrue(repaired.nodes.any { it.kind == UiStateKind.STATUS && it.props.string("reason") == "cancelled" })
        assertEquals(ChatPhase.IDLE, screen(repaired.toUiState()).phase)
        assertEquals(records.first { it.id == liveId }.nodes, untouched.nodes)
        assertEquals(ChatPhase.RUNNING, screen(untouched.toUiState().copy(running = true)).phase)
        assertEquals(repaired.nodes, requireNotNull(store.load(damagedId)).nodes)
        assertEquals(untouched.nodes, requireNotNull(store.load(liveId)).nodes)
    }

    @Test
    fun `stop does not overwrite a rename committed before it`() {
        val store = store()
        val openTurn = turnNode(chatId, realTurnId)
        store.save(
            ChatRecord(
                id = chatId,
                title = "改名后",
                updatedAtMs = 10L,
                workerSessionIds = listOf("worker-1"),
                nodes = listOf(openTurn),
            ),
        )
        val staleUi = runningState().copy(title = "旧标题", nodes = listOf(openTurn))
        val chat = MutableStateFlow(staleUi)
        val turnRunning = AtomicBoolean(true)

        ChatStopWiring(chat, turnRunning) { id ->
            // The shared writer (persistChat) reads the stored title; stop must
            // not carry a stale UI title into the store.
            persistThroughSharedWriter(store, chat, id)
        }.stop(chatId, 1_790_000_000_003L)

        val persisted = requireNotNull(store.load(chatId))
        assertEquals("改名后", persisted.title)
        assertTrue(persisted.nodes.any { it.kind == UiStateKind.STATUS && it.props.string("reason") == "cancelled" })
        assertFalse(turnRunning.get())
    }

    @Test
    fun `a completed turn is not rewritten`() {
        var ui = runningState()
        ui = ui.applyChatEvent(
            chatId,
            event("""{"type":"turn/start","seq":1,"data":{"turn":1}}"""),
            0,
        )
        ui = ui.applyChatEvent(
            chatId,
            event("""{"type":"turn/end","seq":2,"data":{"turn":1,"reason":{"kind":"completed"}}}"""),
            1,
        )
        // The real finish path clears `running` in the turn job's finally.
        ui = ui.copy(running = false)
        assertEquals("a completed turn already closes itself", ChatPhase.IDLE, screen(ui).phase)

        val store = store()
        store.save(
            ChatRecord(
                id = chatId,
                title = "正常完成",
                updatedAtMs = 30L,
                workerSessionIds = listOf("worker-1"),
                nodes = ui.nodes,
            ),
        )
        val loaded = requireNotNull(store.load(chatId))
        val repaired = ChatRecordRepair(store).open(
            record = loaded,
            liveChatId = "",
            turnRunning = false,
        )

        assertEquals(loaded.nodes, repaired.nodes)
        assertEquals(loaded.nodes, requireNotNull(store.load(chatId)).nodes)
        assertEquals(loaded.revision, requireNotNull(store.load(chatId)).revision)
        assertTrue(repaired.nodes.none { it.kind == UiStateKind.STATUS && it.props.string("reason") == "cancelled" })
    }

    /** Test-side implementation of the shared writer's contract: metadata from store. */
    private fun persistThroughSharedWriter(
        store: ChatSessionStore,
        chat: MutableStateFlow<ChatUiState>,
        id: String,
    ) {
        val latest = requireNotNull(store.load(id))
        val ui = chat.value
        val receipt = store.updateContent(
            id = id,
            title = latest.title,
            updatedAtMs = ui.updatedAtMs,
            workerSessionIds = latest.workerSessionIds + listOfNotNull(ui.workerSessionId),
            nodes = ui.nodes,
            requestId = com.phonedsh.ui.state.StateRequestId("test-stop:$id"),
            expectedRevision = com.phonedsh.ui.state.StateRevision(latest.revision),
        )
        assertTrue(receipt.outcome is ChatWriteOutcome.Persisted)
        assertEquals(ui.nodes, requireNotNull(store.load(id)).nodes)
    }

    private fun JsonObject.string(key: String): String? = (this[key] as? JsonString)?.value

    private fun store(): ChatSessionStore = ChatSessionStore(
        DomainStoreCore(
            InMemoryConnectionFactory(),
            QuotaPolicy.uniform(4L * 1024L * 1024L),
            object : Clock {
                override fun nowMillis() = 1L
                override fun monotonicMillis() = 1L
            },
        ),
    )
}
