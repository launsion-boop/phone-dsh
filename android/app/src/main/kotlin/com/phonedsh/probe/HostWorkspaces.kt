// SPDX-License-Identifier: MIT
package com.phonedsh.probe

import com.phonedsh.ui.nav.PdshActionOutcome
import com.phonedsh.ui.nav.PdshActionReceipt
import com.phonedsh.ui.nav.PdshUiHostCommand
import com.phonedsh.ui.nav.PdshWorkspaceSelection
import com.phonedsh.ui.state.StateRevision
import java.util.UUID

/** A readback of the user's durable workspace groups and this chat's membership. */
internal data class HostWorkspaceSnapshot(
    val groups: List<ChatWorkspaceGroup>,
    val selection: PdshWorkspaceSelection,
    val revision: StateRevision,
)

/** Reads workspace facts from the durable chat store; no materialized-folder guess. */
internal fun readHostWorkspaces(store: ChatSessionStore, currentChatId: String?): HostWorkspaceSnapshot {
    val groups = store.loadWorkspaceGroups().sortedBy { it.name.lowercase() }
    val chat = currentChatId?.let(store::load)
    val selection = when {
        currentChatId == null || chat == null -> PdshWorkspaceSelection.Unknown
        chat.workspaceGroupId == null -> PdshWorkspaceSelection.Unassigned
        chat.workspaceGroupId == ChatSessionStore.DEFAULT_WORKSPACE_GROUP_ID && groups.any {
            it.id == ChatSessionStore.DEFAULT_WORKSPACE_GROUP_ID
        } -> PdshWorkspaceSelection.DailyDefault
        groups.none { it.id == chat.workspaceGroupId } -> PdshWorkspaceSelection.Unassigned
        else -> PdshWorkspaceSelection.Assigned(chat.workspaceGroupId)
    }
    return HostWorkspaceSnapshot(groups, selection, store.workspaceGroupsRevision())
}

/**
 * Applies a workspace metadata command to the persistent group store and returns
 * a request-correlated receipt. A successful callback is not considered a write;
 * the ChatSessionStore's durable receipt is authoritative.
 */
internal fun applyHostWorkspaceCommand(
    store: ChatSessionStore,
    command: PdshUiHostCommand,
    expectedRevision: StateRevision? = null,
): PdshActionReceipt? {
    val receipt = when (command) {
        is PdshUiHostCommand.WorkspaceFolderCreate -> {
            val name = command.name.trim()
            if (name.isEmpty()) return failedWorkspaceReceipt(command, StateRevision(0))
            val id = "workspace-${UUID.randomUUID()}"
            store.putWorkspaceGroup(ChatWorkspaceGroup(id, name), command.requestId, expectedRevision)
        }
        is PdshUiHostCommand.WorkspaceFolderRename -> {
            val name = command.name.trim()
            if (name.isEmpty()) return failedWorkspaceReceipt(command, StateRevision(0))
            val old = store.loadWorkspaceGroups().firstOrNull { it.id == command.folderId }
                ?: return failedWorkspaceReceipt(command, StateRevision(0))
            store.putWorkspaceGroup(old.copy(name = name), command.requestId, expectedRevision)
        }
        is PdshUiHostCommand.WorkspaceFolderDelete -> {
            if (command.folderId == ChatSessionStore.DEFAULT_WORKSPACE_GROUP_ID) {
                return failedWorkspaceReceipt(command, StateRevision(0))
            }
            store.deleteWorkspaceGroup(command.folderId, command.requestId, expectedRevision)
        }
        else -> return null
    }
    val succeeded = receipt.outcome is ChatWriteOutcome.Persisted
    return PdshActionReceipt(
        requestId = receipt.requestId,
        sessionId = null,
        revision = receipt.revision,
        outcome = if (succeeded) PdshActionOutcome.SUCCEEDED else PdshActionOutcome.FAILED,
    )
}

private fun failedWorkspaceReceipt(
    command: PdshUiHostCommand,
    revision: StateRevision,
): PdshActionReceipt = PdshActionReceipt(
    requestId = when (command) {
        is PdshUiHostCommand.WorkspaceFolderCreate -> command.requestId
        is PdshUiHostCommand.WorkspaceFolderRename -> command.requestId
        is PdshUiHostCommand.WorkspaceFolderDelete -> command.requestId
        else -> error("not a workspace mutation")
    },
    sessionId = null,
    revision = revision,
    outcome = PdshActionOutcome.FAILED,
)
