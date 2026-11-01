// The host's screen around the sessions page: the drawer's 会话 body.
// SPDX-License-Identifier: MIT
//
// The page itself is a pure function of (host facts, local UI events). This file
// owns only the second half: the search query, the folds, the open menus and the
// inline editors, exactly the view-local decisions `spec/ui/v1/README.md` §3.1
// leaves to the caller. The facts come from `buildSessionsFacts`; nothing here
// reads the engine's session state, the clock or the filesystem.
//
// This host has no session write command (no create, switch, rename, archive or
// workspace mutation). Every such gesture is logged with one token-free line,
// handed off and surfaced on the shell's note bar with the same wording the
// routed pages use; no gesture moves a fact, so the page never shows a success
// this host did not observe. The read-only source is the journal lane, and the
// only refresh is [ProbeEngineViewModel.refreshSessions].
package com.phonedsh.probe

import android.util.Log
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import com.phonedsh.engine.EngineState
import com.phonedsh.ui.page.ArchivedRowView
import com.phonedsh.ui.page.SessionRowView
import com.phonedsh.ui.page.SessionWorkspaceView
import com.phonedsh.ui.page.SessionsLocalState
import com.phonedsh.ui.page.SessionsPage
import java.time.ZoneId

/**
 * Renders the sessions page from the host's session read.
 *
 * The relative-time labels are anchored to one wall-clock reading per page
 * visit: the page is pure, so the host reads the clock once instead of letting
 * every recomposition move the labels.
 *
 * @param engine the composition root (its session read and its clock).
 * @param state the engine lifecycle state (the 新建会话 blocked reason).
 * @param turn the one turn's state (the other blocked reason).
 * @param onBack leave the page and return to the native face.
 * @param onHostNotice show one host line for a handed-off write gesture; the
 *   shell owns the four-second fallback and the bar itself.
 * @param modifier the space the shell gives this page (the note bar takes the
 *   top when a line is showing).
 */
@Composable
internal fun HostSessionsScreen(
    engine: ProbeEngineViewModel,
    state: EngineState,
    turn: AppTurnState,
    onBack: () -> Unit,
    onHostNotice: (String) -> Unit,
    modifier: Modifier = Modifier,
) {
    // Every write gesture is handed off, never applied: the line is the same
    // wording the routed pages' host actions use, so one app has one style.
    val handOff: (String) -> Unit = { gesture ->
        Log.i(TAG_SESSIONS, "host session gesture handed off: $gesture")
        onHostNotice("宿主未实现：${sessionGestureLabel(gesture)}，本次未提交")
    }
    val sessionSnapshot by engine.sessions.collectAsState()
    // The first visit asks for a read; a later one is already fresh from the
    // last scan and a completed turn.
    LaunchedEffect(Unit) { engine.refreshSessions() }
    var local by remember { mutableStateOf(SessionsLocalState()) }
    val facts = remember(state, turn, sessionSnapshot) {
        buildSessionsFacts(state, turn, sessionSnapshot)
    }
    val nowMs = remember { engine.nowMillis() }
    val screenState = remember(facts, local, nowMs) {
        facts.toScreenState(local, nowMs, ZoneId.systemDefault())
    }
    // Pull-to-refresh drives the host's own scan; the spinner reflects the scan
    // the host is actually running, never a local timer.
    SessionsPage(
        state = screenState.copy(refreshInFlight = sessionSnapshot.scanInFlight),
        modifier = modifier,
        onRefresh = { engine.refreshSessions() },
        onSelect = { row ->
            // The host has no switch command. The local selection can only show
            // when the host has no current session, because the page's current
            // session wins; the gesture is still handed off, not swallowed.
            local = local.copy(selectedID = row.id)
            handOff("select")
        },
        onQueryChange = { query -> local = local.copy(query = query) },
        onRenameStart = { row ->
            local = local.copy(renameTargetID = row.id, renameDraft = row.title)
        },
        onRenameDraftChange = { draft -> local = local.copy(renameDraft = draft) },
        onRenameCommit = { _ ->
            // No session write exists; closing the editor is the only outcome
            // this host can honestly show. The title keeps its fact value.
            local = local.copy(renameTargetID = null, renameDraft = "")
            handOff("rename")
        },
        onRenameCancel = { local = local.copy(renameTargetID = null, renameDraft = "") },
        onNewSession = { handOff("new") },
        onRetry = { engine.refreshSessions() },
        onDismissFailure = { engine.clearSessionsFailure() },
        onBack = onBack,
        onToggleWorkspace = { workspace -> local = local.toggleWorkspace(workspace) },
        onWorkspaceMenuToggle = { workspace ->
            local = local.copy(
                workspaceMenuID = if (local.workspaceMenuID == workspace.id) null else workspace.id,
            )
        },
        onNewSessionInWorkspace = { handOff("new-in-workspace") },
        onRenameWorkspaceStart = { workspace ->
            local = local.copy(
                renameWorkspaceTargetID = workspace.id,
                renameWorkspaceDraft = workspace.title,
            )
        },
        onRenameWorkspaceDraftChange = { draft ->
            local = local.copy(renameWorkspaceDraft = draft)
        },
        onRenameWorkspaceCommit = { _ ->
            local = local.copy(renameWorkspaceTargetID = null, renameWorkspaceDraft = "")
            handOff("rename-workspace")
        },
        onRenameWorkspaceCancel = {
            local = local.copy(renameWorkspaceTargetID = null, renameWorkspaceDraft = "")
        },
        onDeleteWorkspaceRequest = { workspace ->
            local = local.copy(deleteWorkspaceTargetID = workspace.id)
        },
        onDeleteWorkspaceConfirm = { _ ->
            local = local.copy(deleteWorkspaceTargetID = null)
            handOff("delete-workspace")
        },
        onDeleteWorkspaceCancel = { local = local.copy(deleteWorkspaceTargetID = null) },
        onAddWorkspace = { local = local.copy(creatingWorkspace = true) },
        onWorkspaceDraftChange = { draft -> local = local.copy(newWorkspaceDraft = draft) },
        onCreateWorkspace = {
            local = local.copy(creatingWorkspace = false, newWorkspaceDraft = "")
            handOff("create-workspace")
        },
        onCancelCreateWorkspace = {
            local = local.copy(creatingWorkspace = false, newWorkspaceDraft = "")
        },
        onToggleArchived = { local = local.copy(showArchived = !local.showArchived) },
        onRestoreArchived = { _: ArchivedRowView ->
            local = local.copy(showArchived = true)
            handOff("restore-archived")
        },
        onSessionMenuToggle = { row ->
            local = local.copy(
                sessionMenuID = if (local.sessionMenuID == row.id) null else row.id,
            )
        },
        onArchiveSession = { _: SessionRowView ->
            local = local.copy(sessionMenuID = null)
            handOff("archive")
        },
    )
}

/** Flips one folder's fold; every folder starts expanded, like the baseline. */
private fun SessionsLocalState.toggleWorkspace(workspace: SessionWorkspaceView): SessionsLocalState =
    copy(
        collapsedWorkspaceIDs = if (workspace.id in collapsedWorkspaceIDs) {
            collapsedWorkspaceIDs - workspace.id
        } else {
            collapsedWorkspaceIDs + workspace.id
        },
    )

/** The person-facing name of one handed-off session gesture; token-free. */
private fun sessionGestureLabel(gesture: String): String = when (gesture) {
    "select" -> "切换会话"
    "new" -> "新建会话"
    "new-in-workspace" -> "在工作文件夹里新建会话"
    "rename" -> "重命名会话"
    "archive" -> "归档会话"
    "restore-archived" -> "恢复已归档的会话"
    "rename-workspace" -> "重命名工作文件夹"
    "delete-workspace" -> "删除工作文件夹"
    "create-workspace" -> "新建工作文件夹"
    else -> gesture
}

/** This screen's logcat tag; only the stable gesture names above reach it. */
private const val TAG_SESSIONS: String = "PDSHSessions"
