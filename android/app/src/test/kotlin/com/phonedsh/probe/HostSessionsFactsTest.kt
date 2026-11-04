// The sessions page only gets workspace membership the host actually measured.
// SPDX-License-Identifier: MIT

package com.phonedsh.probe

import com.phonedsh.platform.EngineHostState
import com.phonedsh.ui.nav.PdshActionOutcome
import com.phonedsh.ui.nav.PdshActionAvailability
import com.phonedsh.ui.nav.PdshActionKey
import com.phonedsh.ui.nav.PdshUiHostCommand
import com.phonedsh.ui.nav.PdshUnavailableReason
import com.phonedsh.ui.nav.PdshWorkspaceSelection
import com.phonedsh.ui.nav.confirms
import com.phonedsh.ui.state.StateRequestId
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test

class HostSessionsFactsTest {
    @Test
    fun `permission defaults expose only modes the host actually offered`() {
        val measured = PermissionDefaultsHostState(
            currentModeId = "read-only",
            availableModeIds = setOf("read-only", "danger-full-access"),
            writable = false,
        )
        assertEquals(com.phonedsh.ui.page.PermissionTier.VIEW_ONLY, measured.currentTier)
        assertEquals(
            setOf(com.phonedsh.ui.page.PermissionTier.VIEW_ONLY, com.phonedsh.ui.page.PermissionTier.FULL_ACCESS),
            measured.availableTiers,
        )
        assertEquals(false, measured.writable)
    }

    @Test
    fun `device connector absence stays unread with explicit unavailable actions`() {
        val facts = hostDeviceFacts()
        assertNull(facts.devices)
        assertEquals(false, facts.canConnect)
        val availability = hostDeviceActionAvailability()
        listOf(PdshActionKey.DEVICE_CONNECT, PdshActionKey.DEVICE_SESSION).forEach { key ->
            val state = availability.forAction(key)
            assertTrue(state is PdshActionAvailability.Unavailable)
            assertEquals(PdshUnavailableReason.NOT_IMPLEMENTED, (state as PdshActionAvailability.Unavailable).reason)
        }
    }

    @Test
    fun `archive and rename receipts follow actual store readback`() {
        val store = ChatSessionStore(MemoryDomainStore())
        store.save(ChatRecord("chat-1", "before", 10L, emptyList(), emptyList()))

        val renamed = requireNotNull(applyHostSessionCommand(
            store,
            PdshUiHostCommand.SessionRename("chat-1", "after", StateRequestId("rename-1")),
        ))
        assertEquals("rename-1", renamed.requestId.value)
        assertEquals(PdshActionOutcome.SUCCEEDED, renamed.outcome)
        assertTrue((renamed.revision?.value ?: 0L) > 0L)
        assertEquals("after", store.load("chat-1")?.title)

        val archived = requireNotNull(applyHostSessionCommand(
            store,
            PdshUiHostCommand.SessionArchive("chat-1", StateRequestId("archive-1")),
        ))
        assertEquals("archive-1", archived.requestId.value)
        assertEquals("chat-1", archived.sessionId)
        assertEquals(PdshActionOutcome.SUCCEEDED, archived.outcome)
        assertTrue(store.load("chat-1")!!.archived)
    }

    @Test
    fun `failed session mutation does not claim a persisted success`() {
        val store = ChatSessionStore(MemoryDomainStore())
        val receipt = requireNotNull(applyHostSessionCommand(
            store,
            PdshUiHostCommand.SessionArchive("missing", StateRequestId("archive-missing")),
        ))
        assertEquals("archive-missing", receipt.requestId.value)
        assertEquals("missing", receipt.sessionId)
        assertEquals(PdshActionOutcome.FAILED, receipt.outcome)
    }

    @Test
    fun `new chat session readback preserves the stable folder id`() {
        val store = ChatSessionStore(MemoryDomainStore())
        val folder = requireNotNull(applyHostWorkspaceCommand(
            store,
            PdshUiHostCommand.WorkspaceFolderCreate("Research", StateRequestId("folder-create")),
        ))
        assertEquals(PdshActionOutcome.SUCCEEDED, folder.outcome)
        val folderId = store.loadWorkspaceGroups().single { it.name == "Research" }.id

        val created = createHostChatSession(
            store = store,
            sessionId = "chat-in-research",
            updatedAtMs = 123L,
            workspaceGroupId = folderId,
            requestId = StateRequestId("new-in-research"),
        )
        assertTrue(created.confirms(StateRequestId("new-in-research"), "chat-in-research", null))
        assertEquals(folderId, store.load("chat-in-research")?.workspaceGroupId)
    }

    @Test
    fun `new chat cannot claim a missing folder and leaves no session row`() {
        val store = ChatSessionStore(MemoryDomainStore())
        val failed = createHostChatSession(
            store = store,
            sessionId = "chat-missing-folder",
            updatedAtMs = 123L,
            workspaceGroupId = "folder-gone",
            requestId = StateRequestId("new-in-gone"),
        )
        assertEquals(PdshActionOutcome.FAILED, failed.outcome)
        assertNull(store.load("chat-missing-folder"))
        assertTrue(store.loadWorkspaceGroups().isEmpty())
    }

    @Test
    fun `folder deletion retains session rows and maps them to unassigned on readback`() {
        val store = ChatSessionStore(MemoryDomainStore())
        store.ensureDefaultWorkspaceGroup(StateRequestId("seed-default"))
        val created = requireNotNull(applyHostWorkspaceCommand(
            store,
            PdshUiHostCommand.WorkspaceFolderCreate("Research", StateRequestId("folder-create-retain")),
        ))
        assertEquals(PdshActionOutcome.SUCCEEDED, created.outcome)
        val folderId = store.loadWorkspaceGroups().single { it.name == "Research" }.id
        store.save(ChatRecord("session-kept", "Kept", 1L, emptyList(), emptyList(), workspaceGroupId = folderId))

        val deleted = requireNotNull(applyHostWorkspaceCommand(
            store,
            PdshUiHostCommand.WorkspaceFolderDelete(folderId, StateRequestId("folder-delete-retain")),
        ))
        assertEquals(PdshActionOutcome.SUCCEEDED, deleted.outcome)
        assertNotNull(store.load("session-kept"))
        assertTrue(store.loadWorkspaceGroups().none { it.id == folderId })
    }

    @Test
    fun `workspace group actions read back durable groups and membership`() {
        val store = ChatSessionStore(MemoryDomainStore())
        store.ensureDefaultWorkspaceGroup(StateRequestId("seed-default"))
        store.save(ChatRecord("chat-1", "chat", 10L, emptyList(), emptyList()))
        val before = readHostWorkspaces(store, "chat-1")

        val created = requireNotNull(applyHostWorkspaceCommand(
            store,
            PdshUiHostCommand.WorkspaceFolderCreate("Research", StateRequestId("workspace-create-1")),
            expectedRevision = before.revision,
        ))
        assertEquals(PdshActionOutcome.SUCCEEDED, created.outcome)
        assertTrue((created.revision?.value ?: 0L) > before.revision.value)
        assertNull(created.sessionId)
        val group = store.loadWorkspaceGroups().single { it.name == "Research" }

        val staleRename = requireNotNull(applyHostWorkspaceCommand(
            store,
            PdshUiHostCommand.WorkspaceFolderRename(group.id, "stale", StateRequestId("workspace-rename-stale")),
            expectedRevision = before.revision,
        ))
        assertEquals(PdshActionOutcome.FAILED, staleRename.outcome)
        assertEquals("Research", store.loadWorkspaceGroups().single { it.id == group.id }.name)

        val renamed = requireNotNull(applyHostWorkspaceCommand(
            store,
            PdshUiHostCommand.WorkspaceFolderRename(group.id, "Research 2", StateRequestId("workspace-rename-1")),
            expectedRevision = store.workspaceGroupsRevision(),
        ))
        assertEquals(PdshActionOutcome.SUCCEEDED, renamed.outcome)
        assertEquals("Research 2", store.loadWorkspaceGroups().single { it.id == group.id }.name)
        assertEquals(
            PdshWorkspaceSelection.DailyDefault,
            readHostWorkspaces(store, "chat-1").selection,
        )
    }

    @Test
    fun `workspace deletion preserves chat rows and renders removed membership as unassigned`() {
        val store = ChatSessionStore(MemoryDomainStore())
        store.ensureDefaultWorkspaceGroup(StateRequestId("seed-default"))
        store.putWorkspaceGroup(ChatWorkspaceGroup("workspace-x", "Project"), StateRequestId("create-x"))
        store.save(ChatRecord(
            "chat-1", "chat", 10L, emptyList(), emptyList(), workspaceGroupId = "workspace-x",
        ))
        val revision = store.workspaceGroupsRevision()
        val receipt = requireNotNull(applyHostWorkspaceCommand(
            store,
            PdshUiHostCommand.WorkspaceFolderDelete(
                "workspace-x",
                StateRequestId("workspace-delete-used"),
            ),
            expectedRevision = revision,
        ))
        assertEquals(PdshActionOutcome.SUCCEEDED, receipt.outcome)
        assertTrue((receipt.revision?.value ?: 0L) > revision.value)
        assertEquals("chat", store.load("chat-1")?.title)
        assertEquals(PdshWorkspaceSelection.Unassigned, readHostWorkspaces(store, "chat-1").selection)
        assertEquals(listOf(ChatSessionStore.DEFAULT_WORKSPACE_GROUP_ID), store.loadWorkspaceGroups().map { it.id })
    }

    @Test
    fun `one measured workspace groups only app chats with that recorded cwd`() {
        val snapshot = HostSessionSnapshot(
            waiting = false,
            sessions = listOf(
                HostSessionRecord(
                    id = "chat-1",
                    lastActivityMs = 10L,
                    title = "app chat",
                    workspaceID = DEFAULT_WORKSPACE_ID,
                    pinned = true,
                ),
                HostSessionRecord(
                    id = "journal-only",
                    lastActivityMs = 5L,
                    title = "legacy session",
                ),
            ),
            currentSessionID = "chat-1",
            archivedSessions = listOf(
                HostSessionRecord(
                    id = "chat-archived",
                    lastActivityMs = 2L,
                    title = "archived",
                    workspaceID = DEFAULT_WORKSPACE_ID,
                ),
            ),
            pinnedSessionIDs = setOf("chat-1"),
        )

        val facts = buildSessionsFacts(
            state = EngineHostState.Stopped,
            turn = AppTurnState.Idle,
            snapshot = snapshot,
            workspacePresent = true,
            workspacePath = "/dsh/workspace",
        )

        val workspace = facts.workspaces!!.single()
        assertEquals(DEFAULT_WORKSPACE_ID, workspace.id)
        assertEquals("/dsh/workspace", workspace.title)
        assertEquals(listOf("chat-1"), workspace.sessionIDs)
        assertEquals(listOf("journal-only"), facts.sessions.filter { it.id !in workspace.sessionIDs }.map { it.id })
        assertEquals(listOf("chat-archived"), facts.archivedSessions!!.map { it.id })
        assertEquals(listOf("chat-1"), facts.pinnedSessionIDs)
    }

    @Test
    fun `a missing workspace directory does not claim an empty folder catalog`() {
        val facts = buildSessionsFacts(
            state = EngineHostState.Stopped,
            turn = AppTurnState.Idle,
            snapshot = HostSessionSnapshot(waiting = false),
            workspacePresent = false,
            workspacePath = "/dsh/workspace",
        )

        assertNull(facts.workspaces)
        assertTrue(facts.sessions.isEmpty())
    }
}
