// SPDX-License-Identifier: MIT
package com.phonedsh.probe

import com.phonedsh.agentcore.*
import com.phonedsh.dsh.turn.PendingRemoteRequest
import com.phonedsh.hostevents.HostEvent
import com.phonedsh.ui.page.ChatSubagentEntry
import com.phonedsh.ui.state.*
import com.phonedsh.domain.DomainStoreCore
import com.phonedsh.domain.QuotaPolicy
import com.phonedsh.domain.testing.InMemoryConnectionFactory
import com.phonedsh.platform.Clock
import com.phonedsh.ui.nav.confirms
import org.junit.Assert.*
import org.junit.Test

class ChatSessionSnapshotTest {
    private fun json(text: String): JsonValue = JsonValue.parse(text)

    private fun domainStore() = DomainStoreCore(
        InMemoryConnectionFactory(), QuotaPolicy.uniform(4L * 1024 * 1024), object : Clock {
            override fun nowMillis() = 1L
            override fun monotonicMillis() = 1L
        },
    )

    private fun chatStore(): ChatSessionStore = ChatSessionStore(domainStore())

    @Test fun `chat write receipt follows atomic persisted archive and rename round trip`() {
        val store = chatStore()
        store.save(ChatRecord("chat-a", "First", 10, listOf("worker-a"), emptyList()))

        val archived = store.setArchived("chat-a", true, StateRequestId("archive-1"))
        assertEquals(StateRequestId("archive-1"), archived.requestId)
        assertEquals("chat-a", archived.sessionId)
        assertEquals(StateRevision(2), archived.revision)
        assertEquals(ChatWriteOutcome.Persisted, archived.outcome)

        val stale = store.rename("chat-a", "stale title", StateRequestId("rename-stale"), StateRevision(1))
        assertEquals(ChatWriteOutcome.Stale, stale.outcome)
        assertEquals("First", store.load("chat-a")?.title)

        val renamed = store.rename("chat-a", "  Second  ", StateRequestId("rename-1"))
        assertEquals(ChatWriteOutcome.Persisted, renamed.outcome)
        assertEquals("Second", store.load("chat-a")?.title)
        assertTrue(store.load("chat-a")?.archived == true)
        assertEquals(3L, store.load("chat-a")?.revision)
    }

    @Test fun `older timestamp chat write is persisted with a clamped updatedAt`() {
        val store = chatStore()
        store.save(ChatRecord("chat-a", "new", 20, emptyList(), emptyList()))
        val first = store.load("chat-a")!!
        assertEquals(1L, first.revision)

        // A wall clock that moved backwards must not lose the write: the row's
        // revision remains the concurrency authority, and the display time is
        // clamped so the list order never regresses.
        store.save(ChatRecord(
            "chat-a", "older", 10, emptyList(),
            listOf(contextLostNode("chat-a", "turn-older", "older content landed")),
        ))

        val persisted = store.load("chat-a")!!
        assertEquals("older", persisted.title)
        assertEquals(listOf("older content landed"), persisted.nodes.map { it.text })
        assertEquals(20L, persisted.updatedAtMs)
        assertEquals(2L, persisted.revision)
    }

    @Test fun `updateContent accepts an older timestamp and clamps the stored time`() {
        val store = chatStore()
        store.save(ChatRecord("chat-a", "new", 20, listOf("worker-a"), emptyList()))
        val before = store.load("chat-a")!!

        // The review scenario: write with a future clock, then write with an
        // earlier one. Revision CAS, not the timestamp, decides acceptance.
        val receipt = store.updateContent(
            id = "chat-a",
            title = "older content",
            updatedAtMs = 10,
            workerSessionIds = listOf("worker-a", "worker-b"),
            nodes = listOf(contextLostNode("chat-a", "turn-older", "still persisted")),
            requestId = StateRequestId("older-content-write"),
            expectedRevision = StateRevision(before.revision),
        )

        assertEquals(ChatWriteOutcome.Persisted, receipt.outcome)
        assertEquals(StateRevision(before.revision + 1), receipt.revision)
        val persisted = store.load("chat-a")!!
        assertEquals("older content", persisted.title)
        assertEquals(listOf("worker-a", "worker-b"), persisted.workerSessionIds)
        assertEquals(listOf("still persisted"), persisted.nodes.map { it.text })
        assertEquals(20L, persisted.updatedAtMs)
        assertEquals(before.revision + 1, persisted.revision)
    }

    @Test fun `missing chat record refusal reaches the chat banner`() {
        val current = ChatUiState(chatId = "chat-a", bannerDismissed = true)
        val missing = chatWriteFailureState(current, "chat-a", existing = null, outcome = null)
        assertEquals("聊天记录不存在，本次内容没有保存。", missing.error)
        assertFalse(missing.bannerDismissed)

        val row = ChatRecord("chat-a", "title", 20, emptyList(), emptyList())
        val stale = chatWriteFailureState(current, "chat-a", row, ChatWriteOutcome.Stale)
        assertEquals("聊天记录已在别处更新，本次内容没有保存；请重试。", stale.error)
        assertFalse(stale.bannerDismissed)

        // A late write for a conversation that is no longer on screen must not
        // overwrite the current chat's state.
        val other = ChatUiState(chatId = "chat-b")
        assertSame(other, chatWriteFailureState(other, "chat-a", existing = null, outcome = null))
    }

    @Test fun `workspace group rename and delete preserve assigned conversation`() {
        val store = chatStore()
        store.save(ChatRecord("chat-a", "A", 10, emptyList(), emptyList(), workspaceGroupId = "daily"))
        val created = store.putWorkspaceGroup(ChatWorkspaceGroup("daily", "日常"), StateRequestId("group-save"))
        assertEquals(ChatWriteOutcome.Persisted, created.outcome)
        val renamed = store.putWorkspaceGroup(ChatWorkspaceGroup("daily", "项目"), StateRequestId("group-rename"))
        assertEquals(ChatWriteOutcome.Persisted, renamed.outcome)
        assertEquals(StateRevision(2), renamed.revision)
        assertEquals("项目", store.loadWorkspaceGroups().single().name)
        val stale = store.deleteWorkspaceGroup("daily", StateRequestId("group-delete-stale"), StateRevision(1))
        assertEquals(ChatWriteOutcome.Stale, stale.outcome)
        assertEquals("项目", store.loadWorkspaceGroups().single().name)
        val deleted = store.deleteWorkspaceGroup("daily", StateRequestId("group-delete"))
        assertEquals(ChatWriteOutcome.Persisted, deleted.outcome)
        assertEquals(StateRevision(3), deleted.revision)
        assertEquals("daily", store.load("chat-a")?.workspaceGroupId)
        assertEquals("chat-a", store.loadAll().single().id)
        assertEquals("未分配", workspaceGroupTitle(store.load("chat-a")!!, store.loadWorkspaceGroups()))
        val unknown = ChatRecord("chat-b", "B", 11, emptyList(), emptyList(), workspaceGroupId = null)
        assertEquals("未分配", workspaceGroupTitle(unknown, store.loadWorkspaceGroups()))
    }

    @Test fun `create in folder worker persistence rename and cold reload retain metadata and current selection`() {
        val database = domainStore()
        val store = ChatSessionStore(database)
        store.ensureDefaultWorkspaceGroup(StateRequestId("seed-default"))
        store.putWorkspaceGroup(ChatWorkspaceGroup("ui-qa", "UI-PR22-QA"), StateRequestId("folder-create"))
        val create = createHostChatSession(
            store = store,
            sessionId = "chat-ui-qa",
            updatedAtMs = 100L,
            workspaceGroupId = "ui-qa",
            requestId = StateRequestId("create-in-folder"),
        )
        assertTrue(create.confirms(StateRequestId("create-in-folder"), "chat-ui-qa", null))
        assertEquals("chat-ui-qa", store.currentSessionId())

        val pending = pendingRequestNode("chat-ui-qa", PendingRemoteRequest(
            "approval-1", "client-1", json("""{"reason":"confirm"}"""), "approval/request",
        ))
        val created = store.load("chat-ui-qa")!!
        val withForwardMetadata = created.copy(
            pinned = true,
            pendingNodes = listOf(pending),
            queuedPrompts = listOf("second prompt"),
            unknownFields = mapOf("futureOwnerField" to JsonObject(mapOf("keep" to JsonBool(true)))),
        )
        store.save(withForwardMetadata)
        val beforeWorkerPersist = store.load("chat-ui-qa")!!
        val attached = store.updateContent(
            id = beforeWorkerPersist.id,
            title = "UI-PR22-QA",
            updatedAtMs = 101L,
            workerSessionIds = listOf("worker-ui-qa"),
            nodes = listOf(contextLostNode("chat-ui-qa", "turn-1", "context retained")),
            requestId = StateRequestId("worker-attach-persist"),
            expectedRevision = StateRevision(beforeWorkerPersist.revision),
        )
        assertEquals(ChatWriteOutcome.Persisted, attached.outcome)

        val beforeRename = store.load("chat-ui-qa")!!
        val rename = store.updateContent(
            id = beforeRename.id,
            title = "Renamed QA chat",
            updatedAtMs = 102L,
            workerSessionIds = beforeRename.workerSessionIds,
            nodes = beforeRename.nodes,
            requestId = StateRequestId("rename-after-worker-attach"),
            expectedRevision = StateRevision(beforeRename.revision),
        )
        assertEquals(ChatWriteOutcome.Persisted, rename.outcome)

        // A newer record demonstrates that cold start must honor the stored id,
        // not simply choose the row with the newest timestamp.
        store.save(ChatRecord("chat-newer", "Newer", 200L, emptyList(), emptyList()))
        val reloadedStore = ChatSessionStore(database)
        val selectedId = reloadedStore.currentSessionId()
        assertEquals("chat-ui-qa", selectedId)
        val coldSelection = selectRestoredChatSession(reloadedStore.loadAll(), selectedId)
        assertEquals("chat-ui-qa", coldSelection?.id)

        val reloaded = reloadedStore.load("chat-ui-qa")!!
        assertEquals("Renamed QA chat", reloaded.title)
        assertEquals("ui-qa", reloaded.workspaceGroupId)
        assertEquals(listOf("worker-ui-qa"), reloaded.workerSessionIds)
        assertEquals("context retained", reloaded.nodes.single().text)
        assertEquals(listOf("approval-1"), reloaded.pendingNodes?.map { (it.props["requestId"] as JsonString).value })
        assertEquals(listOf("second prompt"), reloaded.queuedPrompts)
        assertTrue(reloaded.pinned)
        assertEquals(withForwardMetadata.unknownFields, reloaded.unknownFields)

        val stale = reloadedStore.updateContent(
            id = reloaded.id,
            title = "stale overwrite",
            updatedAtMs = 103L,
            workerSessionIds = emptyList(),
            nodes = emptyList(),
            requestId = StateRequestId("stale-content-write"),
            expectedRevision = StateRevision(beforeRename.revision),
        )
        assertEquals(ChatWriteOutcome.Stale, stale.outcome)
        assertEquals("Renamed QA chat", reloadedStore.load(reloaded.id)?.title)
        assertEquals("ui-qa", reloadedStore.load(reloaded.id)?.workspaceGroupId)
        assertEquals(withForwardMetadata.unknownFields, reloadedStore.load(reloaded.id)?.unknownFields)
    }

    @Test fun `cold selection falls back only when stored current id is not active`() {
        val database = domainStore()
        val store = ChatSessionStore(database)
        val older = ChatRecord("older", "Older", 10L, emptyList(), emptyList())
        val newer = ChatRecord("newer", "Newer", 20L, emptyList(), emptyList())
        val archived = ChatRecord("archived", "Archived", 30L, emptyList(), emptyList(), archived = true)
        store.save(older)
        store.save(newer)
        store.save(archived)

        assertEquals(
            ChatWriteOutcome.Persisted,
            store.selectCurrentSession("older", StateRequestId("select-older"), expectedCurrentId = null).outcome,
        )
        assertEquals(
            ChatWriteOutcome.Stale,
            store.selectCurrentSession("newer", StateRequestId("stale-select-newer"), expectedCurrentId = null).outcome,
        )
        val reloadedStore = ChatSessionStore(database)
        assertEquals("older", reloadedStore.currentSessionId())

        assertEquals("older", selectRestoredChatSession(listOf(newer, older), "older")?.id)
        assertEquals("newer", selectRestoredChatSession(listOf(newer, older), "missing")?.id)
        assertEquals("newer", selectRestoredChatSession(listOf(archived, newer), "archived")?.id)
        assertNull(selectRestoredChatSession(listOf(archived), "archived"))
    }

    @Test fun `folder created session keeps grouping and unknown metadata through worker persist rename and cold reload`() {
        val database = domainStore()
        val store = ChatSessionStore(database)
        store.ensureDefaultWorkspaceGroup(StateRequestId("seed-default"))
        store.putWorkspaceGroup(ChatWorkspaceGroup("folder-qa", "UI-PR22-QA"), StateRequestId("folder-create"))

        val created = createHostChatSession(
            store = store,
            sessionId = "chat-folder-qa",
            updatedAtMs = 100L,
            workspaceGroupId = "folder-qa",
            requestId = StateRequestId("create-in-folder"),
        )
        assertTrue(created.confirms(StateRequestId("create-in-folder"), "chat-folder-qa", null))
        assertEquals("chat-folder-qa", store.currentSessionId())

        val pending = pendingRequestNode("chat-folder-qa", PendingRemoteRequest(
            "ask-folder", "client-folder", json("""{"reason":"confirm"}"""), "approval/request",
        ))
        val initial = store.load("chat-folder-qa")!!
        val seededMetadata = initial.copy(
            pinned = true,
            pendingNodes = listOf(pending),
            queuedPrompts = listOf("queued prompt"),
            unknownFields = mapOf("futureOwnerField" to JsonObject(mapOf("keep" to JsonBool(true)))),
        )
        store.save(seededMetadata)
        val beforeWorkerPersist = store.load("chat-folder-qa")!!

        val workerAttached = store.updateContent(
            id = "chat-folder-qa",
            title = "UI-PR22-QA",
            updatedAtMs = 101L,
            workerSessionIds = listOf("worker-folder-qa"),
            nodes = listOf(sessionNode("chat-folder-qa")),
            requestId = StateRequestId("worker-attached-persist"),
            expectedRevision = StateRevision(beforeWorkerPersist.revision),
        )
        assertEquals(ChatWriteOutcome.Persisted, workerAttached.outcome)
        val attached = store.load("chat-folder-qa")!!
        assertEquals("folder-qa", attached.workspaceGroupId)
        assertEquals(seededMetadata.unknownFields, attached.unknownFields)
        assertEquals(listOf("ask-folder"), attached.pendingNodes?.map { (it.props["requestId"] as JsonString).value })
        assertEquals(listOf("queued prompt"), attached.queuedPrompts)
        assertTrue(attached.pinned)

        val renamed = store.updateContent(
            id = "chat-folder-qa",
            title = "Renamed in folder",
            updatedAtMs = 102L,
            workerSessionIds = attached.workerSessionIds,
            nodes = attached.nodes,
            requestId = StateRequestId("rename-after-worker-attach"),
            expectedRevision = StateRevision(attached.revision),
        )
        assertEquals(ChatWriteOutcome.Persisted, renamed.outcome)

        val coldStore = ChatSessionStore(database)
        val reloaded = coldStore.load("chat-folder-qa")!!
        assertEquals("Renamed in folder", reloaded.title)
        assertEquals("folder-qa", reloaded.workspaceGroupId)
        assertEquals("/dsh/workspace", reloaded.workspaceID)
        assertEquals(listOf("worker-folder-qa"), reloaded.workerSessionIds)
        assertEquals(seededMetadata.unknownFields, reloaded.unknownFields)
        assertEquals(listOf("queued prompt"), reloaded.queuedPrompts)
        assertTrue(reloaded.pinned)
        assertEquals("chat-folder-qa", coldStore.currentSessionId())

        val stale = coldStore.updateContent(
            id = "chat-folder-qa",
            title = "stale rename",
            updatedAtMs = 103L,
            workerSessionIds = emptyList(),
            nodes = emptyList(),
            requestId = StateRequestId("stale-content-write"),
            expectedRevision = StateRevision(attached.revision),
        )
        assertEquals(ChatWriteOutcome.Stale, stale.outcome)
        assertEquals("Renamed in folder", coldStore.load("chat-folder-qa")?.title)
        assertEquals("folder-qa", coldStore.load("chat-folder-qa")?.workspaceGroupId)
    }

    @Test fun `cold restore prefers persisted current selection over newer session and ignores archived selection`() {
        val olderSelected = ChatRecord("selected-old", "Selected", 10L, emptyList(), emptyList())
        val newer = ChatRecord("newer", "Newer", 20L, emptyList(), emptyList())
        val archived = ChatRecord("archived", "Archived", 30L, emptyList(), emptyList(), archived = true)

        assertEquals(olderSelected, selectRestoredChatSession(listOf(newer, olderSelected), "selected-old"))
        assertEquals(newer, selectRestoredChatSession(listOf(newer, olderSelected), "missing"))
        assertEquals(newer, selectRestoredChatSession(listOf(archived, newer), "archived"))
        assertNull(selectRestoredChatSession(listOf(archived), "archived"))
    }

    @Test fun `日常 group is seeded once without overwriting an existing name`() {
        val store = chatStore()
        assertEquals(ChatWriteOutcome.Persisted, store.ensureDefaultWorkspaceGroup(StateRequestId("seed")).outcome)
        assertEquals("日常", store.loadWorkspaceGroups().single().name)
        store.putWorkspaceGroup(ChatWorkspaceGroup("daily", "My daily"), StateRequestId("rename"))
        assertEquals(ChatWriteOutcome.Persisted, store.ensureDefaultWorkspaceGroup(StateRequestId("seed-again")).outcome)
        assertEquals("My daily", store.loadWorkspaceGroups().single().name)
    }

    @Test fun `cold store restores pending and queued state as persisted facts`() {
        val store = chatStore()
        val pending = pendingRequestNode("chat-a", PendingRemoteRequest(
            "request-a", "client-a", json("""{"reason":"confirm"}"""), "approval/request",
        ))
        val lost = contextLostNode("chat-a", "turn-a", "上一段上下文已丢失")
        val record = ChatRecord("chat-a", "A", 10, listOf("worker-a"), listOf(lost),
            pendingNodes = listOf(pending), queuedPrompts = listOf("second prompt"))
        store.save(record)
        val restored = store.load("chat-a")!!
        assertEquals(listOf("request-a"), restored.pendingNodes?.map { (it.props["requestId"] as JsonString).value })
        assertEquals(listOf("second prompt"), restored.queuedPrompts)
        assertEquals("上一段上下文已丢失", restored.nodes.single().text)
    }

    @Test fun `queue projection exposes only the next-turn dock rows and keeps their source rpc id`() {
        val snapshot = sessionSnapshotOf(
            projections = json("""{"values":{"inbox":{
                "next-turn":[{"id":"q-next","content":[{"type":"text","text":"queued"}],
                    "source":{"kind":"user","rpcId":"prompt-one"}}],
                "next-step":[{"id":"q-step","content":[{"type":"text","text":"steered"}],
                    "source":{"kind":"user","rpcId":"prompt-two"}}]
            }}}"""),
            catalog = null,
            commandCatalog = null,
            sessionId = "worker-session",
        )
        val rows = snapshot.queueItems!!
        // The input dock renders only next-turn, exactly like DSH's QueueDock;
        // a next-step row belongs to the running turn, not to the dock.
        assertEquals(1, rows.size)
        assertEquals(QueueItemId.Durable("q-next"), rows[0].id)
        assertEquals("worker-session", rows[0].sessionId)
        assertEquals("next-turn", rows[0].lane)
        assertEquals(true, rows[0].canEdit)
        assertEquals(StateRequestId("prompt-one"), rows[0].promptRequestId)
        assertTrue(rows.none { it.id == QueueItemId.Durable("q-step") })
    }

    @Test fun `projection refresh keeps the in-flight marker on the same durable queue id`() {
        val actionRequest = StateRequestId("queue-action-1")
        val receipt = QueueActionReceipt(actionRequest, QueueAction.EDIT, CommandOutcome.FAILED, "waiting")
        val current = ChatSessionSnapshot(queueItems = listOf(
            ManagedQueueItemState(
                id = QueueItemId.Durable("q-busy"),
                text = "old text",
                busy = true,
                actionRequestId = actionRequest,
                receipt = receipt,
            ),
            ManagedQueueItemState(QueueItemId.Durable("q-gone"), "already consumed"),
        ))
        val measured = ChatSessionSnapshot(queueItems = listOf(
            ManagedQueueItemState(QueueItemId.Durable("q-busy"), "new text"),
            ManagedQueueItemState(QueueItemId.Durable("q-new"), "added"),
        ))

        val merged = current.withProjectionUpdate(measured)

        val busy = merged.queueItems!!.first { it.id == QueueItemId.Durable("q-busy") }
        assertEquals("new text", busy.text)
        assertEquals(true, busy.busy)
        assertEquals(actionRequest, busy.actionRequestId)
        assertEquals(receipt, busy.receipt)
        assertEquals(listOf(QueueItemId.Durable("q-busy"), QueueItemId.Durable("q-new")), merged.queueItems!!.map { it.id })
    }

    @Test fun `legacy chat row keeps unknown envelope fields and reports missing queue as unknown`() {
        val rawStore = domainStore()
        rawStore.put(ChatSessionStore.DOMAIN, "chat/legacy", """{
            "schema":"pdsh-chat-session/1","id":"legacy","title":"Old title",
            "updatedAtMs":9,"workerSessionIds":["worker-old"],"workspaceID":"/dsh/workspace",
            "nodes":"","futureOwnerField":{"keep":true}
        }""".trimIndent().toByteArray(Charsets.UTF_8))
        val store = ChatSessionStore(rawStore)
        val loaded = store.load("legacy")!!
        assertEquals("Old title", loaded.title)
        assertNull(loaded.pendingNodes)
        assertNull(loaded.queuedPrompts)
        assertEquals("/dsh/workspace", loaded.workspaceID)
        assertTrue(store.setArchived("legacy", true))
        val persisted = JsonValue.parse(rawStore.get(ChatSessionStore.DOMAIN, "chat/legacy")!!.toString(Charsets.UTF_8)) as JsonObject
        assertEquals(JsonObject(mapOf("keep" to JsonBool(true))), persisted["futureOwnerField"])
        assertEquals("Old title", store.load("legacy")?.title)
    }

    @Test fun `dock reads nested goal and filters unknown todo statuses`() {
        val snapshot = sessionSnapshotOf(json("""{"values":{
          "goal":{"goal":{"objective":"Ship the report","phase":"paused"}},
          "todos":[{"content":"Read CSV","status":"completed"},
                   {"content":"Write report","status":"in_progress"},
                   {"content":"Unknown","status":"invented"}],
          "permissions":{"currentValue":"read-only"}}}"""),
            json("""{"options":[{"value":"read-only","name":"Read Only"}]}"""),
            json("""[{"name":"goal","description":"Set goal","input":{}},
                      {"name":"clear","description":"Clear"}]"""))
        assertEquals(GoalBarState.Visible("paused", "Ship the report"), snapshot.goal)
        assertEquals(listOf("completed", "in_progress"), snapshot.todos.map { it.status })
        assertEquals("read-only", snapshot.currentAccessMode?.id)
        assertEquals(listOf(true, false), snapshot.commands.map { it.hasInput })
        assertNull(snapshot.accessError)
    }

    @Test fun `projection polling updates live metrics without discarding unread catalogs`() {
        val prior = sessionSnapshotOf(
            json("""{"values":{"permissions":{"currentValue":"read-only"}}}"""),
            json("""{"options":[{"value":"read-only","label":"Read only"}]}"""),
            json("""[{"name":"clear","description":"Clear"}]"""),
        )
        assertTrue(prior.accessModes.isNotEmpty())
        assertEquals("read-only", prior.currentAccessMode?.id)
        assertTrue(prior.commands.isNotEmpty())
        val poll = sessionSnapshotOf(json("""{"values":{
          "tokenUsage":{"uncachedInputTokens":100,"outputTokens":20,"cacheReadTokens":80,"cacheWriteTokens":10},
          "contextPressure":{"projectedTokens":900,"contextWindow":1000},
          "subagentCatalog":[]
        }}"""), null, null)
        val merged = prior.withProjectionUpdate(poll)
        assertEquals(prior.accessModes, merged.accessModes)
        assertEquals(prior.currentAccessMode, merged.currentAccessMode)
        assertEquals(prior.commands, merged.commands)
        assertEquals(prior.accessError, merged.accessError)
        assertEquals(prior.commandsError, merged.commandsError)
        assertEquals(210L, merged.tokenUsage?.totalTokens)
        assertEquals(90, merged.contextPressure?.percent)
        assertEquals(emptyList<ChatSubagentEntry>(), merged.subagents)
    }

    @Test fun `session metrics project only complete valid host facts`() {
        val snapshot = sessionSnapshotOf(json("""{"values":{
          "sessionStats":{"turns":4,"steps":9,"llmMs":1200.5,"toolMs":300,
            "ttftMs":800,"ttftSteps":4,"decodeMs":2000,"decodeTokens":50},
          "tokenUsage":{"uncachedInputTokens":100,"outputTokens":20,"cacheReadTokens":80,"cacheWriteTokens":10},
          "contextPressure":{"pressureTokens":800,"projectedTokens":900,"contextWindow":1000},
          "contextBreakdown":{"systemTokens":30,"toolsTokens":40,"messageTokens":800}
        }}"""), null, null)
        assertEquals(SessionStats(4, 9, 1200.5, 300.0, 800.0, 4, 2000.0, 50), snapshot.sessionStats)
        assertEquals(SessionTokenUsage(100, 20, 80, 10), snapshot.tokenUsage)
        assertEquals(ContextPressure(800, 900, 1000), snapshot.contextPressure)
        assertEquals(ContextBreakdown(30, 40, 800), snapshot.contextBreakdown)
        assertEquals(25.0, snapshot.sessionStats?.tokensPerSecond)
        assertEquals(90, snapshot.contextPressure?.percent)
        assertEquals(210L, snapshot.tokenUsage?.totalTokens)
        assertEquals(80.0 / 190.0 * 100.0, snapshot.tokenUsage?.cacheHitPercent!!, 1e-9)
    }

    @Test fun `missing partial and invalid metrics remain unavailable`() {
        val absent = sessionSnapshotOf(json("""{"values":{}}"""), null, null)
        assertNull(absent.sessionStats)
        assertNull(absent.tokenUsage)
        assertNull(absent.contextPressure)
        assertNull(absent.contextBreakdown)

        val partial = sessionSnapshotOf(json("""{"values":{
          "sessionStats":{"turns":1,"steps":2},
          "tokenUsage":{"uncachedInputTokens":1,"outputTokens":2},
          "contextPressure":{"pressureTokens":4},
          "contextBreakdown":{"systemTokens":1,"toolsTokens":2}
        }}"""), null, null)
        assertNull(partial.sessionStats)
        assertNull(partial.tokenUsage)
        assertNull(partial.contextPressure)
        assertNull(partial.contextBreakdown)

        val invalid = sessionSnapshotOf(json("""{"values":{
          "sessionStats":{"turns":-1,"steps":2,"llmMs":1,"toolMs":1,"ttftMs":1,"ttftSteps":1,"decodeMs":1,"decodeTokens":2},
          "tokenUsage":{"uncachedInputTokens":1,"outputTokens":2,"cacheReadTokens":-1,"cacheWriteTokens":0},
          "contextPressure":{"pressureTokens":1,"projectedTokens":2,"contextWindow":0},
          "contextBreakdown":{"systemTokens":1,"toolsTokens":2,"messageTokens":-3}
        }}"""), null, null)
        assertNull(invalid.sessionStats)
        assertNull(invalid.tokenUsage)
        assertNull(invalid.contextPressure)
        assertNull(invalid.contextBreakdown)

        val aggregateOverflow = sessionSnapshotOf(json("""{"values":{
          "tokenUsage":{"uncachedInputTokens":9223372036854775807,"outputTokens":1,"cacheReadTokens":0,"cacheWriteTokens":0}
        }}"""), null, null)
        assertNull(aggregateOverflow.tokenUsage)
    }

    @Test fun `subagent projection distinguishes unread empty known and activity facts`() {
        val unread = sessionSnapshotOf(
            json("""{"values":{"todos":[]}}"""), null, null,
            sessionId = "worker-parent",
        )
        assertNull(unread.subagents)

        val empty = sessionSnapshotOf(
            json("""{"values":{"subagentCatalog":[]}}"""), null, null,
            sessionId = "worker-parent",
            sessionList = json("""{"items":[]}"""),
        )
        assertEquals(emptyList<ChatSubagentEntry>(), empty.subagents)

        val measured = sessionSnapshotOf(
            json("""{"values":{"subagentCatalog":[
              {"id":"worker-child","label":"Read the source","mode":"continuable","parentSessionId":"worker-parent"}
            ]}}"""), null, null,
            sessionId = "worker-parent",
            sessionList = json("""{"items":[{"sessionId":"worker-child","running":false,
              "updatedAt":1234,"projections":{"values":{"title":"Read the source"}}}]}"""),
        )
        val row = measured.subagents!!.single()
        assertEquals("worker-child", row.workerSessionId)
        assertEquals("Read the source", row.label)
        assertEquals("worker-parent", row.parentSessionId)
        assertEquals("Read the source", row.sessionTitle)
        assertEquals(1234L, row.updatedAtMs)
        assertFalse(row.running!!)
        assertTrue(row.workerSessionKnown!!)
        val withoutSessionList = sessionSnapshotOf(
            json("""{"values":{"subagentCatalog":[{"id":"worker-child","mode":"unknown"}]}}"""),
            null, null, sessionId = "worker-parent",
        )
        assertNull(withoutSessionList.subagents!!.single().workerSessionKnown)
        assertNull(withoutSessionList.subagents.single().running)
    }

    @Test fun `subagent session resolution requires a current verified worker and exact record lineage`() {
        val entry = ChatSubagentEntry(
            workerSessionId = "worker-child", label = "Child", mode = ChatSubagentEntry.MODE_CONTINUABLE,
            running = false, workerSessionKnown = true,
        )
        assertEquals(
            SubagentSessionTarget.AdoptKnownWorker("worker-child", null),
            resolveSubagentSessionTarget(entry, emptyList()),
        )
        assertNull(resolveSubagentSessionTarget(entry.copy(workerSessionKnown = null), emptyList()))
        assertNull(resolveSubagentSessionTarget(entry.copy(workerSessionKnown = false), emptyList()))
        assertNull(resolveSubagentSessionTarget(entry.copy(running = true), emptyList()))
        assertNull(resolveSubagentSessionTarget(entry.copy(mode = ChatSubagentEntry.MODE_EXTERNAL), emptyList()))

        val cached = ChatRecord(
            id = "chat-child", title = "Child", updatedAtMs = 10,
            workerSessionIds = listOf("worker-child"), nodes = listOf(sessionNode("chat-child")),
        )
        assertEquals(SubagentSessionTarget.CachedRecord(cached), resolveSubagentSessionTarget(entry, listOf(cached)))
        val staleLineage = cached.copy(workerSessionIds = listOf("worker-child", "worker-new"))
        assertNull(resolveSubagentSessionTarget(entry, listOf(staleLineage)))
        assertNull(resolveSubagentSessionTarget(entry, listOf(cached.copy(archived = true))))
    }

    @Test fun `subagent history uses the production event projector and refuses unknown user content`() {
        val projected = projectSubagentHistory("worker-child", listOf(
            json("""{"type":"user/message","seq":1,"data":{"turn":1,"content":[{"type":"text","text":"Do the task"}]}}""") as JsonObject,
            json("""{"type":"assistant/message","seq":2,"data":{"turn":1,"message":{"content":[{"type":"text","text":"Done"}]}}}""") as JsonObject,
        ))
        assertNull(projected.unsupportedReason)
        assertEquals(listOf("user", "assistant"), projected.nodes.map {
            (it.props["role"] as? JsonString)?.value ?: "assistant"
        })
        assertEquals(listOf("Do the task", "Done"), projected.nodes.map { it.text })

        val unsupported = projectSubagentHistory("worker-child", listOf(
            json("""{"type":"user/message","seq":1,"data":{"turn":1,"content":[{"type":"image","url":"opaque"}]}}""") as JsonObject,
        ))
        assertNotNull(unsupported.unsupportedReason)
        assertTrue(unsupported.nodes.isEmpty())
    }

    @Test fun `subagent catalog distinguishes unreported empty and session-list identity`() {
        val unreported = sessionSnapshotOf(
            json("""{"values":{"todos":[]}}"""), null, null,
            sessionId = "worker-parent",
        )
        assertNull(unreported.subagents)

        val empty = sessionSnapshotOf(
            json("""{"values":{"subagentCatalog":[]}}"""), null, null,
            sessionId = "worker-parent",
            sessionList = json("""{"items":[]}"""),
        )
        assertEquals(emptyList<ChatSubagentEntry>(), empty.subagents)

        val measured = sessionSnapshotOf(
            json("""{"values":{"subagentCatalog":[
              {"id":"worker-child","label":"Read the source","mode":"continuable","parentSessionId":"worker-parent"}
            ]}}"""), null, null,
            sessionId = "worker-parent",
            sessionList = json("""{"items":[{"sessionId":"worker-child","running":false,
              "updatedAt":1234,"projections":{"values":{"title":"Read the source"}}}]}"""),
        )
        val entry = measured.subagents!!.single()
        assertEquals("worker-child", entry.workerSessionId)
        assertEquals("Read the source", entry.label)
        assertEquals("worker-parent", entry.parentSessionId)
        assertEquals("Read the source", entry.sessionTitle)
        assertEquals(1234L, entry.updatedAtMs)
        assertEquals(false, entry.running)
        assertEquals(true, entry.workerSessionKnown)
    }

    @Test fun `subagent open target never invents an unknown or external Worker`() {
        val known = ChatSubagentEntry(
            workerSessionId = "worker-child", label = "Child", mode = "continuable",
            running = false, workerSessionKnown = true,
        )
        assertEquals(
            SubagentSessionTarget.AdoptKnownWorker("worker-child", null),
            resolveSubagentSessionTarget(known, emptyList()),
        )
        assertNull(resolveSubagentSessionTarget(known.copy(workerSessionKnown = null), emptyList()))
        assertNull(resolveSubagentSessionTarget(known.copy(running = true), emptyList()))
        assertNull(resolveSubagentSessionTarget(known.copy(mode = ChatSubagentEntry.MODE_EXTERNAL), emptyList()))

        val cached = ChatRecord(
            id = "chat-child", title = "Child", updatedAtMs = 20,
            workerSessionIds = listOf("worker-child"), nodes = listOf(sessionNode("chat-child")),
        )
        assertEquals(SubagentSessionTarget.CachedRecord(cached), resolveSubagentSessionTarget(known, listOf(cached)))
        val staleWorker = cached.copy(workerSessionIds = listOf("worker-child", "worker-new"))
        assertNull(resolveSubagentSessionTarget(known, listOf(staleWorker)))
    }

    @Test fun `subagent history projection reuses production event mapping and fails on unsupported user content`() {
        val projected = projectSubagentHistory("worker-child", listOf(
            json("""{"type":"user/message","seq":1,"data":{"turn":1,"content":[{"type":"text","text":"Do the task"}]}}""") as JsonObject,
            json("""{"type":"assistant/message","seq":2,"data":{"turn":1,"message":{"content":[{"type":"text","text":"Done"}]}}}""") as JsonObject,
        ))
        assertNull(projected.unsupportedReason)
        assertEquals(listOf("user", "assistant"), projected.nodes.map { it.props["role"]?.let { role -> (role as? JsonString)?.value } ?: "assistant" })
        assertEquals(listOf("Do the task", "Done"), projected.nodes.map { it.text })

        val unsupported = projectSubagentHistory("worker-child", listOf(
            json("""{"type":"user/message","seq":1,"data":{"turn":1,"content":[{"type":"image","url":"opaque"}]}}""") as JsonObject,
        ))
        assertNotNull(unsupported.unsupportedReason)
        assertTrue(unsupported.nodes.isEmpty())
    }

    @Test fun `rich live question reaches plan review carrier without losing metadata`() {
        val request = PendingRemoteRequest("ask-1", "client-1", json("""{
          "questions":[{"id":"plan","header":"Review","question":"Proceed?",
          "detail":"# Plan\nRead then write.","multiSelect":false,
          "options":[{"label":"Approve","description":"Start work"}],
          "intent":{"kind":"plan-review","approve":"Approve"}}]}"""), "user-questions/request")
        val node = pendingRequestNode("chat-1", request)
        val state = ChatScreenState.from(listOf(sessionNode("chat-1"), node))
        val question = state.pending.primary!!
        assertEquals("ask-1", question.requestId)
        assertEquals(true, question.channelAvailable)
        assertEquals("Review", question.questionItems.single().header)
        assertEquals("Start work", question.questionItems.single().options.single().description)
        assertEquals("Approve", question.questionItems.single().approveWireLabel)
    }

    @Test fun `answer wire preserves each question and separates custom input from selections`() {
        val request = PendingRemoteRequest("q", "client", json("""{"questions":[
          {"id":"one","options":[{"label":"A"}]},
          {"id":"two","options":[{"label":"B"}]}]}"""), "user-questions/request")
        val outcome = questionOutcome(request, """{"one":["A","Custom"],"two":[]}""")
        val value = outcome["value"] as JsonObject
        val answers = (value["answers"] as JsonArray).values.map { it as JsonObject }
        assertEquals(JsonArray(listOf(JsonString("A"))), answers[0]["selected"])
        assertEquals(JsonString("Custom"), answers[0]["custom"])
        assertEquals(JsonArray(emptyList()), answers[1]["selected"])
        assertFalse(answers[1].members.containsKey("custom"))
    }

    @Test fun `real worker result envelope matches call and retains every text block`() {
        val event = HostEvent.project(json("""{"type":"tool/result","seq":9,"time":3000,
          "data":{"turn":1,"message":{"toolCallId":"call-7","isError":false,
          "content":[{"type":"text","text":"first"},{"type":"text","text":"last"}]}}}""") as JsonObject)!!
        val node = chatNodeOf("chat", "t", event, 9)!!
        assertEquals(JsonString("call-7"), node.props["callId"])
        assertEquals(JsonString("first\nlast"), node.props["body"])
        assertEquals(JsonString("ok"), node.props["state"])
    }

    @Test fun `fold and host dock facts survive real app projection`() {
        val state = chatScreenState(ChatUiState(chatId = "chat", imeVisible = true,
            expandedRowIds = setOf("tool-1"), sessionSnapshot = ChatSessionSnapshot(
                todos = listOf(TodoDockItem("one", "Read CSV", "pending")),
                goal = GoalBarState.Visible("active", "Report"))), true, false, true)
        assertEquals(setOf("tool-1"), state.expandedRowIds)
        assertEquals(1, state.todoItems.size)
        assertEquals(GoalBarState.Visible("active", "Report"), state.goal)
    }
    @Test fun `subagent older pages must advance the cursor monotonically`() {
        assertTrue(subagentHistoryCursorAdvanced(previousBeforeSeq = 40, nextBeforeSeq = 39))
        assertFalse(subagentHistoryCursorAdvanced(previousBeforeSeq = 40, nextBeforeSeq = 40))
        assertFalse(subagentHistoryCursorAdvanced(previousBeforeSeq = 40, nextBeforeSeq = null))
    }

    @Test fun `terminal paging stalls stop offering more while preserving rows error state`() {
        val previous = SubagentTranscriptWindow(
            workerSessionId = "worker-child",
            throughSeq = 90,
            beforeSeq = 40,
            hasMore = true,
            loadingEarlier = true,
        )
        val stalled = transcriptAfterSubagentPageFailure(
            previous,
            message = "cursor did not advance",
            terminalPagination = true,
        )
        assertFalse(stalled.hasMore)
        assertFalse(stalled.loadingEarlier)
        assertEquals("cursor did not advance", stalled.error)
        assertEquals(previous.beforeSeq, stalled.beforeSeq)
        val transient = transcriptAfterSubagentPageFailure(
            previous,
            message = "temporary read error",
            terminalPagination = false,
        )
        assertTrue(transient.hasMore)
        assertFalse(transient.loadingEarlier)
        assertEquals("temporary read error", transient.error)
    }

}
