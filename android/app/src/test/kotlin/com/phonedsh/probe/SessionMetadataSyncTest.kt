// HostShell session commands must reach the engine's session facts, not only the
// durable store. SPDX-License-Identifier: MIT
//
// The device bug was two symptoms of one root cause: renaming the open chat kept
// the old title in `mutableChat` (so the next save wrote it back), and
// archive/restore left `sessionSnapshot.archivedSessions` untouched (so settings
// kept its old count and list). These tests drive the real ChatSessionStore and
// the same `reloadChatMetadataInto` projection the view model calls, then take the
// value through the same `ChatUiState`/`HostSessionSnapshot` reads HostShell uses.
package com.phonedsh.probe

import com.phonedsh.domain.DomainStoreCore
import com.phonedsh.domain.QuotaPolicy
import com.phonedsh.domain.testing.InMemoryConnectionFactory
import com.phonedsh.platform.Clock
import com.phonedsh.ui.nav.PdshActionOutcome
import com.phonedsh.ui.nav.PdshUiHostCommand
import com.phonedsh.ui.state.StateRequestId
import com.phonedsh.ui.state.StateRevision
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class SessionMetadataSyncTest {

    private fun domainStore(): DomainStoreCore = DomainStoreCore(
        InMemoryConnectionFactory(),
        QuotaPolicy.uniform(4L * 1024 * 1024),
        object : Clock {
            override fun nowMillis() = 1L
            override fun monotonicMillis() = 1L
        },
    )

    @Test
    fun `rename reload updates the open title and the next chat save keeps it`() = runBlocking {
        val domain = domainStore()
        val store = ChatSessionStore(domain)
        store.save(ChatRecord("chat-1", "旧名字", 10L, listOf("worker-1"), emptyList()))
        store.selectCurrentSession("chat-1", StateRequestId("select-before-rename"))

        val sessions = MutableStateFlow(
            HostSessionSnapshot(
                waiting = false,
                sessions = listOf(HostSessionRecord("chat-1", 10L, "旧名字")),
                currentSessionID = "chat-1",
            ),
        )
        val chat = MutableStateFlow(
            ChatUiState(
                chatId = "chat-1",
                title = "旧名字",
                updatedAtMs = 10L,
                workerSessionId = "worker-1",
            ),
        )

        val renamed = requireNotNull(
            applyHostSessionCommand(
                store,
                PdshUiHostCommand.SessionRename("chat-1", "新名字", StateRequestId("rename-open")),
            ),
        )
        assertEquals(PdshActionOutcome.SUCCEEDED, renamed.outcome)

        reloadChatMetadataInto(store, sessions, chat)

        assertEquals("新名字", chat.value.title)
        assertEquals("新名字", sessions.value.sessions.single().title)

        // The next turn's save is exactly persistChat's updateContent call: it
        // reads the live ChatUiState title. If reload had not mirrored the stored
        // title, this write would put 旧名字 back.
        val live = chat.value
        val existing = requireNotNull(store.load("chat-1"))
        val saved = store.updateContent(
            id = live.chatId,
            title = live.title,
            updatedAtMs = live.updatedAtMs,
            workerSessionIds = existing.workerSessionIds + listOfNotNull(live.workerSessionId),
            nodes = live.nodes,
            requestId = StateRequestId("chat-content-after-rename"),
            expectedRevision = StateRevision(existing.revision),
        )
        assertEquals(ChatWriteOutcome.Persisted, saved.outcome)

        // A new store over the same backing database is the cold-start read.
        val cold = ChatSessionStore(domain)
        assertEquals("新名字", cold.load("chat-1")?.title)
        assertEquals("新名字", requireNotNull(cold.load("chat-1")).toUiState().title)
    }

    @Test
    fun `archive reload moves the session to the archived facts and restore brings it back`() = runBlocking {
        val domain = domainStore()
        val store = ChatSessionStore(domain)
        store.save(ChatRecord("chat-archive-me", "归档我", 20L, emptyList(), emptyList()))
        store.save(ChatRecord("chat-keep", "保留", 30L, emptyList(), emptyList()))
        store.selectCurrentSession("chat-keep", StateRequestId("select-keep"))

        val sessions = MutableStateFlow(
            HostSessionSnapshot(
                waiting = false,
                sessions = listOf(
                    HostSessionRecord("chat-keep", 30L, "保留"),
                    HostSessionRecord("chat-archive-me", 20L, "归档我"),
                ),
                currentSessionID = "chat-keep",
            ),
        )
        val chat = MutableStateFlow(ChatUiState(chatId = "chat-keep", title = "保留"))

        val archived = requireNotNull(
            applyHostSessionCommand(
                store,
                PdshUiHostCommand.SessionArchive("chat-archive-me", StateRequestId("archive-row")),
            ),
        )
        assertEquals(PdshActionOutcome.SUCCEEDED, archived.outcome)
        reloadChatMetadataInto(store, sessions, chat)

        assertEquals(listOf("chat-archive-me"), sessions.value.archivedSessions.map { it.id })
        assertEquals(1, sessions.value.archivedSessions.size)
        assertTrue(sessions.value.sessions.none { it.id == "chat-archive-me" })
        assertTrue(sessions.value.sessions.any { it.id == "chat-keep" })
        assertEquals("保留", chat.value.title)

        val restored = requireNotNull(
            applyHostSessionCommand(
                store,
                PdshUiHostCommand.SessionRestore("chat-archive-me", StateRequestId("restore-row")),
            ),
        )
        assertEquals(PdshActionOutcome.SUCCEEDED, restored.outcome)
        reloadChatMetadataInto(store, sessions, chat)

        assertTrue(sessions.value.archivedSessions.isEmpty())
        assertEquals(0, sessions.value.archivedSessions.size)
        assertTrue(sessions.value.sessions.any { it.id == "chat-archive-me" })
        assertTrue(sessions.value.sessions.any { it.id == "chat-keep" })
        assertEquals("保留", chat.value.title)
    }
}
