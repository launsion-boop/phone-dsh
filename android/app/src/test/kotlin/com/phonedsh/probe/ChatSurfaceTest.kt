// The chat lane's state tests: Worker events -> nodes -> the screen state.
// SPDX-License-Identifier: MIT
//
// The grep-able defect this lane fixes was "the page opens, the composer is dead".
// These tests pin the three properties that make it alive, at the JVM layer:
// a durable event becomes the row the page draws, the live text is drawn *while*
// the turn runs, and a stored conversation comes back byte-for-byte after a
// process restart.
package com.phonedsh.probe

import com.phonedsh.agentcore.JsonBool
import com.phonedsh.agentcore.JsonObject
import com.phonedsh.agentcore.JsonString
import com.phonedsh.agentcore.JsonValue
import com.phonedsh.domain.DomainEntry
import com.phonedsh.domain.DomainStore
import com.phonedsh.domain.DomainTransaction
import com.phonedsh.hostevents.HostEvent
import com.phonedsh.hostevents.HostEventProjection
import com.phonedsh.ui.state.ChatAttachment
import com.phonedsh.ui.state.ChatPhase
import com.phonedsh.ui.state.ChatRow
import com.phonedsh.ui.state.ManagedQueueItemState
import com.phonedsh.ui.state.QueueItemId
import com.phonedsh.ui.state.SessionStats
import com.phonedsh.ui.state.SessionTokenUsage
import com.phonedsh.ui.state.ContextPressure
import com.phonedsh.ui.state.ContextBreakdown
import com.phonedsh.ui.state.ComposerStatsMode
import com.phonedsh.ui.page.PerformanceUsage
import com.phonedsh.ui.composer.ComposerSendLayout
import com.phonedsh.ui.composer.ComposerSendRule
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ChatSurfaceTest {
    @Test
    fun `admitted duplicate text is a new bubble unless its request matches the optimistic prompt`() {
        val ui = ChatUiState(
            chatId = "chat",
            running = true,
            turnToken = "live",
            activeTurnNodeId = "live-turn-0002",
            lastPromptRequestId = "first",
            nodes = listOf(userNodeOf("chat", "live", "repeat", 1)),
        )
        fun message(seq: Int, rpcId: String): HostEvent = HostEvent.project(JsonValue.parse(
            """{"seq":$seq,"type":"user/message","data":{"source":{"kind":"user","rpcId":"$rpcId"},"content":[{"type":"text","text":"repeat"}]}}""",
        ) as JsonObject)!!
        val first = ui.applyChatEvent("chat", message(2, "first"), 2)
        assertEquals(ui.nodes, first.nodes)
        val admitted = first.applyChatEvent("chat", message(3, "queued"), 3)
        assertEquals(listOf("repeat", "repeat"), admitted.nodes.map { it.text })
        assertEquals("live-turn-0002", admitted.nodes.last().turnID)
        assertEquals(admitted.nodes, admitted.applyChatEvent("chat", message(3, "queued"), 4).nodes)
    }

    @Test
    fun `session metrics and stored compact choice reach the page state`() {
        val snapshot = ChatSessionSnapshot(
            sessionStats = SessionStats(2, 3, 1.0, 2.0, 3.0, 1, 1000.0, 25),
            tokenUsage = SessionTokenUsage(10, 4, 5, 1),
            contextPressure = ContextPressure(40, 50, 100),
            contextBreakdown = ContextBreakdown(5, 10, 35),
        )
        val state = chatScreenState(
            ui = ChatUiState(chatId = "chat", sessionSnapshot = snapshot),
            engineStarted = true,
            providerNeedsKey = false,
            canSend = true,
            performanceUsage = PerformanceUsage.COMPACT,
        )
        assertEquals(snapshot.sessionStats, state.sessionStats)
        assertEquals(snapshot.tokenUsage, state.tokenUsage)
        assertEquals(snapshot.contextPressure?.percent, state.contextPercent)
        assertEquals(snapshot.contextBreakdown, state.contextBreakdown)
        assertEquals(ComposerStatsMode.COMPACT, state.composerStatsMode)
    }

    @Test
    fun `only next-turn queue rows expose the steer action`() {
        val state = chatScreenState(
            ui = ChatUiState(
                chatId = "chat",
                running = true,
                sessionSnapshot = ChatSessionSnapshot(queueItems = listOf(
                    ManagedQueueItemState(
                        id = QueueItemId.Durable("q-next-step"),
                        text = "steered into the current turn",
                        lane = "next-step",
                    ),
                    ManagedQueueItemState(
                        id = QueueItemId.Durable("q-next-turn"),
                        text = "waiting for the next turn",
                        lane = "next-turn",
                    ),
                )),
            ),
            engineStarted = true,
            providerNeedsKey = false,
            canSend = true,
            canSteer = true,
        )

        val rows = state.queueItems.orEmpty().associateBy { it.id }
        assertEquals(false, rows[QueueItemId.Durable("q-next-step")]?.canSteer)
        assertEquals(true, rows[QueueItemId.Durable("q-next-turn")]?.canSteer)
    }

    @Test
    fun `a settled assistant message becomes an assistant row`() {
        val event = project(
            """{"type":"assistant/message","seq":3,"data":{"turn":1,"message":{"content":[
                 {"type":"text","text":"CSV 一共 3 行。"},{"type":"reasoning","text":"internal"}]}}}""",
        )
        val node = requireNotNull(chatNodeOf("chat-1", "", event, 1))
        assertEquals("assistant", node.props.string("role"))
        assertEquals("CSV 一共 3 行。", node.text)
        assertEquals("session/chat-1/turn/turn-0001/event/3/assistant-message", node.nodeID)
    }

    @Test
    fun `a flat text member is read too`() {
        val event = project("""{"type":"assistant/message","seq":2,"data":{"turn":1,"text":"done"}}""")
        assertEquals("done", assistantTextOf(event))
    }

    @Test
    fun `a completed turn end remains available for process and tail projection`() {
        val event = project(
            """{"type":"turn/end","seq":4,"data":{"turn":1,"reason":{"kind":"completed"}}}""",
        )
        val node = requireNotNull(chatNodeOf("chat-1", "", event, 1))
        assertEquals(JsonString("completed"), node.props["reason"])
    }

    @Test
    fun `an interrupted turn end becomes a system event row`() {
        val event = project(
            """{"type":"turn/end","seq":4,"data":{"turn":1,"reason":{"kind":"interrupted"}}}""",
        )
        val node = requireNotNull(chatNodeOf("chat-1", "", event, 1))
        assertEquals("interrupted", node.props.string("reason"))
    }

    @Test
    fun `tool call and result form one disclosure entry`() {
        val call = project(
            """{"type":"tool/call","seq":2,"data":{"turn":1,"name":"bash","callId":"c1"}}""",
        )
        val result = project(
            """{"type":"tool/result","seq":3,"data":{"turn":1,"callId":"c1","isError":false,
                 "result":{"content":[{"type":"text","text":"a,b\n1,2"}]}}}""",
        )
        val nodes = listOfNotNull(
            chatNodeOf("chat-1", "", call, 1),
            chatNodeOf("chat-1", "", result, 2),
        )
        val state = chatScreenState(
            ChatUiState(chatId = "chat-1", nodes = nodes),
            engineStarted = true,
            providerNeedsKey = false,
            canSend = true,
        )
        val group = state.rows.single() as ChatRow.ProcessGroup
        val run = group.entries.single() as ChatRow.ToolRun
        assertEquals("bash", run.title)
        assertEquals("a,b", run.summary)
        assertEquals(1, run.entries.size)
    }

    @Test
    fun `the composer is live on an empty conversation once the engine is up`() {
        val state = chatScreenState(
            ChatUiState(chatId = "chat-1", draft = "你好"),
            engineStarted = true,
            providerNeedsKey = false,
            canSend = true,
        )
        assertTrue("an empty conversation must not lock the dock", state.composer.enabled)
        assertTrue("typed text can be sent", state.composer.canSubmit)
        assertEquals(
            ComposerSendLayout.SEND,
            ComposerSendRule.layout(state.composer.running, state.composer.canSubmit),
        )
        assertEquals(ChatPhase.IDLE, state.phase)
    }

    @Test
    fun `the live text is drawn while the turn runs and the dock offers stop`() {
        val streaming = chatScreenState(
            ChatUiState(
                chatId = "chat-1",
                running = true,
                streaming = "正在读取 CSV",
                activeTurnNodeId = "turn-0001",
            ),
            engineStarted = true,
            providerNeedsKey = false,
            canSend = true,
        )
        assertEquals(ChatPhase.RUNNING, streaming.phase)
        val live = streaming.rows.last() as ChatRow.Assistant
        assertEquals("正在读取 CSV", live.text)
        assertTrue("the live row is a streaming row", live.streaming)
        assertEquals(
            ComposerSendLayout.STOP,
            ComposerSendRule.layout(streaming.composer.running, streaming.composer.canSubmit),
        )
    }

    @Test
    fun `a send failure raises the banner and keeps the rows`() {
        val state = chatScreenState(
            ChatUiState(chatId = "chat-1", error = "消息发送失败（timeout）"),
            engineStarted = true,
            providerNeedsKey = false,
            canSend = true,
        )
        assertEquals("消息发送失败（timeout）", state.userFacingError)
        assertEquals(ChatPhase.FAILED, state.phase)
        assertTrue(state.banners.single().dismissible)
    }

    @Test
    fun `imports are pending attachments with a workspace path`() {
        val attachment = ChatAttachment(name = "rows.csv", mimeType = "text/csv", path = "/dsh/workspace/rows.csv")
        val state = chatScreenState(
            ChatUiState(chatId = "chat-1", attachments = listOf(attachment), draft = ""),
            engineStarted = true,
            providerNeedsKey = false,
            canSend = true,
        )
        assertEquals(listOf(attachment), state.composer.attachments)
        assertTrue("an attachment alone can be sent", state.composer.canSubmit)
    }

    @Test
    fun `a stored conversation round-trips through the store`() {
        val store = MemoryDomainStore()
        val chatStore = ChatSessionStore(store)
        val nodes = listOf(
            sessionNode("chat-1"),
            userNodeOf("chat-1", "t1", "统计这个 CSV", 1),
            chatNodeOf(
                "chat-1",
                "t1",
                project("""{"type":"assistant/message","seq":5,"data":{"turn":1,"text":"3 行"}}"""),
                2,
            )!!,
        )
        val record = ChatRecord(
            id = "chat-1",
            title = "CSV 统计",
            updatedAtMs = 1_700_000_000_000L,
            workerSessionIds = listOf("sess-a", "sess-b"),
            nodes = nodes,
        )
        chatStore.save(record)
        val loaded = requireNotNull(chatStore.load("chat-1"))
        assertEquals("CSV 统计", loaded.title)
        assertEquals(listOf("sess-a", "sess-b"), loaded.workerSessionIds)
        assertEquals(nodes, loaded.nodes)
        assertEquals(ChatSessionStore.DEFAULT_WORKSPACE_ID, loaded.workspaceID)
        assertFalse(loaded.archived)
        assertFalse(loaded.pinned)
    }

    @Test
    fun `archive and pin metadata survives a store update without changing the transcript`() {
        val store = MemoryDomainStore()
        val chatStore = ChatSessionStore(store)
        val nodes = listOf(sessionNode("chat-1"), userNodeOf("chat-1", "t1", "hello", 1))
        chatStore.save(
            ChatRecord(
                id = "chat-1",
                title = "hello",
                updatedAtMs = 10L,
                workerSessionIds = listOf("worker-1"),
                nodes = nodes,
            ),
        )

        assertTrue(chatStore.setArchived("chat-1", true))
        assertTrue(chatStore.setPinned("chat-1", true))
        val loaded = requireNotNull(chatStore.load("chat-1"))
        assertTrue(loaded.archived)
        assertTrue(loaded.pinned)
        assertEquals(ChatSessionStore.DEFAULT_WORKSPACE_ID, loaded.workspaceID)
        assertEquals("hello", loaded.title)
        assertEquals(listOf("worker-1"), loaded.workerSessionIds)
        assertEquals(nodes, loaded.nodes)
        assertFalse(chatStore.setArchived("missing", true))
    }

    @Test
    fun `a damaged row reads as absent, not as half a transcript`() {
        val store = MemoryDomainStore()
        store.put(ChatSessionStore.DOMAIN, "chat/broken", "{not json".toByteArray())
        assertNull(ChatSessionStore(store).load("broken"))
    }

    @Test
    fun `conversations load newest first`() {
        val store = MemoryDomainStore()
        val chatStore = ChatSessionStore(store)
        chatStore.save(ChatRecord("chat-1", "older", 10L, emptyList(), emptyList()))
        chatStore.save(ChatRecord("chat-2", "newer", 20L, emptyList(), emptyList()))
        assertEquals(listOf("chat-2", "chat-1"), chatStore.loadAll().map { it.id })
    }

    @Test
    fun `the assistant text is never taken from a reasoning block`() {
        val event = project(
            """{"type":"assistant/message","seq":1,"data":{"turn":1,"message":{"content":[
                 {"type":"reasoning","text":"secret"},{"type":"text","text":"visible"}]}}}""",
        )
        assertEquals("visible", assistantTextOf(event))
    }

    @Test
    fun `assistant node retains full reasoning payload and reports truncation`() {
        val event = project(
            """{"type":"assistant/message","seq":4,"data":{"turn":1,"message":{"content":[
                 {"type":"reasoning","text":"first thought"},{"type":"text","text":"answer"},
                 {"type":"reasoning","text":"second thought"}]}}}""",
        )
        val node = requireNotNull(chatNodeOf("chat-1", "", event, 1))
        assertEquals("first thought\nsecond thought", node.props.string("fullReasoning"))
        assertEquals(false, (node.props["fullReasoningTruncated"] as JsonBool).value)
    }

    @Test
    fun `assistant node marks reasoning clipped to ui state limit`() {
        val reasoning = "r".repeat(20_001)
        val event = project(
            """{"type":"assistant/message","seq":5,"data":{"turn":1,"message":{"content":[
                 {"type":"reasoning","text":"$reasoning"},{"type":"text","text":"answer"}]}}}""",
        )
        val node = requireNotNull(chatNodeOf("chat-1", "", event, 1))
        assertEquals(20_000, node.props.string("fullReasoning")?.length)
        assertEquals(true, (node.props["fullReasoningTruncated"] as JsonBool).value)
    }

    @Test
    fun `the tool result keeps the first line only`() {
        val event = project(
            """{"type":"tool/result","seq":2,"data":{"turn":1,"callId":"c","isError":false,
                 "result":"line one\nline two"}}""",
        )
        val node = requireNotNull(chatNodeOf("chat-1", "", event, 1))
        assertEquals("line one", node.text)
        assertEquals("ok", node.props.string("state"))
    }

    @Test
    fun `an error result is an error row`() {
        val event = project(
            """{"type":"tool/result","seq":2,"data":{"turn":1,"callId":"c","isError":true,
                 "result":"ENOENT"}}""",
        )
        val node = requireNotNull(chatNodeOf("chat-1", "", event, 1))
        assertEquals(true, (node.props["isError"] as JsonBool).value)
        assertEquals("error", node.props.string("state"))
    }

    private fun project(json: String): HostEvent {
        val raw = JsonValue.parse(json) as JsonObject
        val events = HostEventProjection.projectAll(raw)
        assertNotNull("the fixture must project at least one host event", events.firstOrNull())
        return events.first()
    }

    private fun JsonObject.string(key: String): String? = (this[key] as? JsonString)?.value
}

/** The smallest `DomainStore` that behaves like the SQLite one for these tests. */
internal class MemoryDomainStore : DomainStore {
    private val domains = LinkedHashMap<String, LinkedHashMap<String, ByteArray>>()
    private var stamp = 0L

    private fun rows(domain: String): LinkedHashMap<String, ByteArray> =
        domains.getOrPut(domain) { LinkedHashMap() }

    override fun get(domain: String, key: String): ByteArray? = rows(domain)[key]?.copyOf()

    override fun put(domain: String, key: String, value: ByteArray) {
        rows(domain)[key] = value.copyOf()
        stamp++
    }

    override fun delete(domain: String, key: String): Boolean = rows(domain).remove(key) != null

    override fun <T> transaction(block: DomainTransaction.() -> T): T =
        block(MemoryTransaction())

    override fun list(domain: String, prefix: String, limit: Int): List<DomainEntry> =
        rows(domain).entries
            .filter { it.key.startsWith(prefix) }
            .take(limit)
            .mapIndexed { index, entry -> DomainEntry(entry.key, entry.value.copyOf(), index.toLong()) }

    override fun usageBytes(domain: String): Long = rows(domain).values.sumOf { it.size.toLong() }

    override fun quotaBytes(domain: String): Long = 4L * 1024L * 1024L

    override fun close() = Unit

    private inner class MemoryTransaction : DomainTransaction {
        override fun get(domain: String, key: String): ByteArray? = this@MemoryDomainStore.get(domain, key)

        override fun put(domain: String, key: String, value: ByteArray) =
            this@MemoryDomainStore.put(domain, key, value)

        override fun delete(domain: String, key: String): Boolean =
            this@MemoryDomainStore.delete(domain, key)

        override fun list(domain: String, prefix: String, limit: Int): List<DomainEntry> =
            this@MemoryDomainStore.list(domain, prefix, limit)

        override fun usageBytes(domain: String): Long = this@MemoryDomainStore.usageBytes(domain)
    }
}
