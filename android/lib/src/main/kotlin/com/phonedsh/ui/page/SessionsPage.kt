// The drawer (sessions, workspaces, archive) and the embedded queue page.
// SPDX-License-Identifier: MIT
//
// Spec: `spec/ui/v1/README.md` §1 (SessionsPage: 会话列表、重命名、删除、开关; the
// queue is one of the embedded sub-pages implemented with its parent) and §3.1
// (the two layers). The baseline is
// `examples/probe-app/PhoneDSHProbe/SessionsPage.swift`, which draws the drawer
// as eight `Section` blocks: five in the drawer itself and three in the
// `SessionQueuePage` that lives in the same file.
//
// The drawer's sections, in the baseline's order:
//   1. 新建会话, its blocked reason, the failure line and the ungrouped sessions;
//   2. the completely-empty block (no folder, no session, no archive);
//   3. one section per workspace: the folder row, its menu, then its sessions;
//   4. 添加工作文件夹 (hidden while the drawer is completely empty);
//   5. 已归档: a header with the count, then the archived rows and 恢复.
// The queue page's Sections 6-8 are: the loading line, one section per queued
// message (下一轮 / 当前步骤) and the error section.
//
// Two layers, kept apart on purpose (§3.1):
//   * host facts: sessions, workspace membership, archived ids, the current
//     session, the pinned order, the new-session block and the queue read;
//   * ScreenState: the folded workspaces, the archived fold, the overflow menus,
//     the editor dialogs, the search query and the visible row order.
// `SessionsScreenState.from(...)` is a pure function of (facts, local UI events,
// nowMs, zone): no clock, no engine, no network, so a JVM replay yields the same
// rows on every machine.
//
// A fact the host did not report travels as `null`, never as an invented empty
// list: `workspaces == null` and `archivedSessions == null` make the page say
// 未知, and only a list the host actually reported can make the drawer claim to
// be empty.
//
// The session list's own 删除 action is not part of the baseline (the engine only
// archives); the callbacks stay on the signature so a host compiled against the
// previous page still links, and the page never renders that action.
//
// Interaction parity uses the Compose standard controls the baseline itself uses,
// not page-local imitations: an alert is an `AlertDialog`, a `Menu`/`contextMenu`
// is a `DropdownMenu`, and `.refreshable` is a `PullToRefreshBox`. The one
// presentation difference left is the search field: iOS puts it in the navigation
// bar and the drawer pins it above the list; the query and the title filter are
// the same.
//
// Geometry: the page margin and the three row floors are page-level tokens from
// `spec/ui/v1/tokens.json`; the search field's floor reuses the composer's
// minimum height and is marked `unverified geometry` at its one use site. No
// value is re-typed here.
package com.phonedsh.ui.page

import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.defaultMinSize
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicText
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.MenuDefaults
import androidx.compose.material3.TextButton
import androidx.compose.material3.pulltorefresh.PullToRefreshBox
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.style.TextOverflow
import com.phonedsh.ui.UiStrings
import com.phonedsh.ui.theme.LocalUiTokens
import com.phonedsh.ui.theme.LocalUiType
import com.phonedsh.ui.theme.generated.UiTokenNames
import java.time.Instant
import java.time.ZoneId

// ---------------------------------------------------------------------------
// Host facts
// ---------------------------------------------------------------------------

/** The run status a session row reports. It is host data, not a derived guess. */
public enum class SessionRunStatus {
    RUNNING,
    IDLE,
    FAILED,

    /** The host listed the session but did not report a status yet. */
    WAITING,
}

/** Whether the list has been read, is still waiting, or the last read failed. */
public enum class SessionListStatus { WAITING, READY, FAILED }

/**
 * Why the list has no visible row.
 *
 * `NO_SESSIONS` is the baseline's completely-empty drawer (no folder, no
 * ungrouped session and no archived session). The page renders that as its
 * Section 2 block. `NO_MATCHES` is only an observation for callers; the
 * baseline has no [global] no-match screen, so the page does not render one.
 */
public enum class SessionsEmpty {
    NONE,

    /** Nothing exists: no folder, no ungrouped session, no archived session. */
    NO_SESSIONS,

    /** Data exists but the search query kept none of it. */
    NO_MATCHES,
}

/**
 * One session exactly as the host lists it.
 *
 * @param id the host session id (used for every action).
 * @param title the host title; a default/empty title is reworded by the title
 *   policy instead of being shown raw (`new conversation` is not a user-facing
 *   name).
 * @param updatedAtMs last activity in epoch milliseconds; `null` when the host
 *   did not report it (the row then shows no time, never "刚刚").
 * @param status the run status; only [SessionRunStatus.RUNNING] renders an
 *   indicator, because that is the only status the baseline's row shows.
 */
public data class SessionListing(
    public val id: String,
    /**
     * The host title, or `null` when the host has no title store.
     *
     * `null` and `""` are different facts: `null` means the host did not report
     * a title, so the row falls back to its untitled label (新会话 / 新会话 N);
     * `""` means the host *did* report one and it is empty. Passing `""` for a
     * host that has no titles would assert a fact the host does not have. This
     * is the same rule as "an unknown value never renders as 0".
     */
    public val title: String?,
    public val updatedAtMs: Long? = null,
    public val status: SessionRunStatus = SessionRunStatus.IDLE,
)

/**
 * One workspace folder exactly as the host lists it.
 *
 * Membership decides grouping, the same way the baseline's `sessions(in:)`
 * does: a session that no workspace lists is ungrouped, and `sessionIDs` also
 * fixes the order of that folder's rows.
 *
 * @param id the host workspace id.
 * @param title the host title; a default or path-like name is reworded for
 *   display.
 * @param sessionIDs the host's membership list, in the folder's own order.
 */
public data class SessionWorkspace(
    public val id: String,
    public val title: String,
    public val sessionIDs: List<String> = emptyList(),
)

/**
 * Why the 新建会话 row cannot be pressed; `null` means it can.
 *
 * The baseline derives this from the chat model (engine started, turn running,
 * keep-alive); the host adapter reports the verdict instead of this page
 * reading the engine.
 */
public enum class NewSessionBlock {
    /** 先启动本地引擎,才能新建会话。 */
    ENGINE_NOT_STARTED,

    /** 这一轮跑完就能新建 */
    TURN_RUNNING,
}

/** The sentence the blocked 新建会话 row shows below itself. */
internal val NewSessionBlock.reason: String
    get() = when (this) {
        NewSessionBlock.ENGINE_NOT_STARTED -> UiStrings.SESSIONS_NEW_BLOCKED_ENGINE
        NewSessionBlock.TURN_RUNNING -> UiStrings.SESSIONS_NEW_BLOCKED_TURN
    }

/**
 * The local UI events of the drawer.
 *
 * Everything here is a view-local decision (§3.1): a fold, an open menu, an
 * editor dialog or the search query. It is never an event-anchored UiState
 * node, so it cannot live in the UiState sequence.
 */
public data class SessionsLocalState(
    public val query: String = "",
    /** Locally selected session; the host's `currentSessionID` wins when given. */
    public val selectedID: String? = null,
    /** The session whose rename dialog is open, if any. */
    public val renameTargetID: String? = null,
    /** The rename editor's draft; only meaningful together with `renameTargetID`. */
    public val renameDraft: String = "",
    /** Legacy session-delete target; the baseline archives instead of deleting. */
    public val deleteTargetID: String? = null,
    /** The workspaces the user collapsed; every folder starts expanded. */
    public val collapsedWorkspaceIDs: Set<String> = emptySet(),
    /** Whether 已归档 is expanded; it starts collapsed. */
    public val showArchived: Boolean = false,
    /** The session whose long-press action row is open. */
    public val sessionMenuID: String? = null,
    /** The workspace whose overflow menu is open. */
    public val workspaceMenuID: String? = null,
    /** The workspace whose rename editor is open. */
    public val renameWorkspaceTargetID: String? = null,
    public val renameWorkspaceDraft: String = "",
    /** The workspace whose delete confirmation is open. */
    public val deleteWorkspaceTargetID: String? = null,
    /** Whether the 新建工作文件夹 dialog is open. */
    public val creatingWorkspace: Boolean = false,
    public val newWorkspaceDraft: String = "",
)

// ---------------------------------------------------------------------------
// ScreenState
// ---------------------------------------------------------------------------

/** One visible session row. */
public data class SessionRowView(
    public val id: String,
    public val title: String,
    /** Relative-time label from [SessionListing.updatedAtMs]; `null` when unmeasured. */
    public val timeLabel: String?,
    public val status: SessionRunStatus,
    /** True for the host's current session (the baseline's check mark). */
    public val selected: Boolean,
    public val renaming: Boolean,
    /** Legacy session-delete flag; the page never renders it (baseline archives). */
    public val deleting: Boolean,
    /** True while this row's long-press action row is open. */
    public val menuOpen: Boolean = false,
)

/** One visible workspace section. */
public data class SessionWorkspaceView(
    public val id: String,
    public val title: String,
    /** The baseline shows the count after the query filter, not the host total. */
    public val sessionCount: Long,
    public val expanded: Boolean,
    public val menuOpen: Boolean,
    public val sessions: List<SessionRowView>,
    /** True when expanded and no row survived the query: the section's empty copy. */
    public val empty: Boolean,
)

/** One archived session row. */
public data class ArchivedRowView(
    public val id: String,
    public val title: String,
    public val timeLabel: String?,
)

/** What the 已归档 section currently shows. */
public enum class ArchivedStatus {
    /** Folded: only the header (with the host's count) is visible. */
    COLLAPSED,

    /** The host reported no archived session. */
    EMPTY,

    /** The host reported an archived list; [ArchivedSection.rows] carries the query filter. */
    READY,

    /** The host did not report archived sessions: the page says 未知. */
    UNKNOWN,
}

/**
 * The 已归档 section.
 *
 * @param count the host's archived count, unfiltered; `null` when it did not
 *   report the list (the header then shows 未知).
 * @param rows the archived rows the query kept.
 */
public data class ArchivedSection(
    public val status: ArchivedStatus,
    public val count: Long?,
    public val rows: List<ArchivedRowView>,
)

/** The rename dialog state, already resolved against the listing. */
public data class RenameEditor(
    public val sessionID: String,
    public val draft: String,
)

/** The workspace rename dialog state, already resolved against the folder. */
public data class WorkspaceRenameEditor(
    public val workspaceID: String,
    public val draft: String,
)

/** The overall state of the workspace region. */
public enum class SessionWorkspaceStatus {
    /** The host reported at least one folder. */
    READY,

    /** The host reported a list and it is empty. */
    EMPTY,

    /** The host did not report the list: the page says 未知, not "none". */
    UNKNOWN,
}

/**
 * The drawer's state.
 *
 * @param status read state; [SessionsEmpty] is only ever reported in `READY` so
 *   a failure or a wait never looks like "no sessions".
 * @param rows the ungrouped session rows, in the baseline's pinned-first order.
 * @param failure the fail-loud message for the last read failure; rows from the
 *   previous successful read stay visible (nothing is cleared on a failed read).
 * @param rename the open session rename editor; `null` when none.
 * @param deleteTargetID legacy session-delete target; never rendered.
 * @param workspaces the folder sections, in host `workspaceOrder` order.
 * @param archived the 已归档 section.
 * @param newSessionBlock why 新建会话 is disabled; `null` when it is enabled.
 * @param completelyEmpty the baseline's `isCompletelyEmpty`: the only condition
 *   under which Section 2 (and only it) replaces Sections 4 and 5.
 * @param renameWorkspace the open workspace rename editor.
 * @param deleteWorkspaceTargetID the workspace awaiting delete confirmation.
 * @param creatingWorkspace whether the 新建工作文件夹 dialog is open.
 */
public data class SessionsScreenState(
    public val status: SessionListStatus,
    public val rows: List<SessionRowView>,
    public val empty: SessionsEmpty,
    public val failure: String?,
    public val rename: RenameEditor?,
    public val deleteTargetID: String?,
    public val selectedID: String?,
    /** The search query the rows were filtered with; the field is a pure view of it. */
    public val query: String = "",
    public val workspaces: List<SessionWorkspaceView> = emptyList(),
    public val workspaceStatus: SessionWorkspaceStatus = SessionWorkspaceStatus.UNKNOWN,
    public val archived: ArchivedSection =
        ArchivedSection(ArchivedStatus.COLLAPSED, count = null, rows = emptyList()),
    public val newSessionBlock: NewSessionBlock? = null,
    public val completelyEmpty: Boolean = false,
    public val renameWorkspace: WorkspaceRenameEditor? = null,
    public val deleteWorkspaceTargetID: String? = null,
    public val creatingWorkspace: Boolean = false,
    public val newWorkspaceDraft: String = "",
    /** True while a host refresh is in flight (the pull-to-refresh indicator). */
    public val refreshInFlight: Boolean = false,
) {
    /** True while the host has not delivered a list yet. */
    public val waiting: Boolean get() = status == SessionListStatus.WAITING

    /** True while 已归档 is expanded. */
    public val archivedExpanded: Boolean get() = archived.status != ArchivedStatus.COLLAPSED

    public companion object {
        /**
         * Projects the host facts into the page state.
         *
         * Pure: the same arguments always yield the same rows, time labels,
         * folds and empty reasons, so a JVM test replays a script instead of
         * asserting pixels.
         *
         * @param sessions the host list, in host order.
         * @param local local UI events (query, selection, folds, editors).
         * @param nowMs the instant the labels are relative to (caller-supplied:
         *   the state machine never reads the clock).
         * @param zone the zone the date fallback (`M月d日`) is rendered in.
         * @param waiting true before the first successful read.
         * @param failure non-null when the last read failed.
         * @param workspaces the host's folders; `null` means "not reported".
         * @param archivedSessions the host's archived sessions; `null` means
         *   "not reported" (the count renders 未知).
         * @param currentSessionID the session the chat page has open; the
         *   check mark follows it, falling back to the local selection.
         * @param newSessionBlock why 新建会话 is disabled, or `null`.
         * @param pinnedSessionIDs the host's pinned order, applied inside each
         *   group (the baseline's `pinnedFirst`).
         * @param workspaceOrder the host's display order; unlisted folders keep
         *   their position after the listed ones (the baseline's
         *   `orderedWorkspaces`).
         */
        public fun from(
            sessions: List<SessionListing>,
            local: SessionsLocalState = SessionsLocalState(),
            nowMs: Long,
            zone: ZoneId,
            waiting: Boolean = false,
            failure: String? = null,
            workspaces: List<SessionWorkspace>? = null,
            archivedSessions: List<SessionListing>? = null,
            currentSessionID: String? = null,
            newSessionBlock: NewSessionBlock? = null,
            pinnedSessionIDs: List<String>? = null,
            workspaceOrder: List<String>? = null,
            refreshing: Boolean = false,
        ): SessionsScreenState {
            val status = when {
                failure != null -> SessionListStatus.FAILED
                waiting -> SessionListStatus.WAITING
                else -> SessionListStatus.READY
            }
            val ordered = workspaces?.let { orderWorkspaces(it, workspaceOrder.orEmpty()) }.orEmpty()
            val archivedIDs = archivedSessions.orEmpty().map { it.id }.toSet()
            val active = sessions.filterNot { it.id in archivedIDs }
            val activeByID = active.associateBy { it.id }
            // A folder's rows follow its own membership order, like the baseline's
            // `workspace.sessionIDs.compactMap`.
            val groups = ordered.map { workspace ->
                workspace to workspace.sessionIDs.mapNotNull { activeByID[it] }
            }
            val memberIDs = groups.flatMap { it.second }.map { it.id }.toSet()
            val ungrouped = active.filterNot { it.id in memberIDs }
            // Titles are numbered over the whole (unfiltered) list, so a search
            // never renumbers rows and a pin never changes a name.
            val titleOrder = groups.flatMap { it.second } + ungrouped
            val titles = displayTitles(titleOrder)
            val query = local.query.trim()
            val currentID = currentSessionID ?: local.selectedID

            fun titleOf(session: SessionListing): String =
                titles[session.id] ?: archivedTitle(session, titleOrder)

            fun matches(session: SessionListing): Boolean =
                query.isEmpty() || titleOf(session).contains(query, ignoreCase = true)

            fun rowOf(session: SessionListing): SessionRowView = SessionRowView(
                id = session.id,
                title = titleOf(session),
                timeLabel = session.updatedAtMs?.let { relativeTime(it, nowMs, zone) },
                status = session.status,
                selected = session.id == currentID,
                renaming = session.id == local.renameTargetID,
                deleting = session.id == local.deleteTargetID,
                menuOpen = session.id == local.sessionMenuID,
            )

            val ungroupedRows = pinnedFirst(ungrouped, pinnedSessionIDs.orEmpty())
                .filter { matches(it) }
                .map { rowOf(it) }
            val workspaceViews = groups.mapIndexed { index, pair ->
                val (workspace, members) = pair
                val rows = pinnedFirst(members, pinnedSessionIDs.orEmpty())
                    .filter { matches(it) }
                    .map { rowOf(it) }
                val expanded = workspace.id !in local.collapsedWorkspaceIDs
                SessionWorkspaceView(
                    id = workspace.id,
                    title = workspaceTitle(workspace.title, index + 1),
                    sessionCount = rows.size.toLong(),
                    expanded = expanded,
                    menuOpen = workspace.id == local.workspaceMenuID,
                    sessions = rows,
                    empty = expanded && rows.isEmpty(),
                )
            }
            val archivedStatus = when {
                !local.showArchived -> ArchivedStatus.COLLAPSED
                archivedSessions == null -> ArchivedStatus.UNKNOWN
                archivedSessions.isEmpty() -> ArchivedStatus.EMPTY
                else -> ArchivedStatus.READY
            }
            val archived = ArchivedSection(
                status = archivedStatus,
                count = archivedSessions?.size?.toLong(),
                rows = archivedSessions.orEmpty().filter { matches(it) }.map { session ->
                    ArchivedRowView(
                        id = session.id,
                        title = titleOf(session),
                        timeLabel = session.updatedAtMs?.let { relativeTime(it, nowMs, zone) },
                    )
                },
            )
            // The baseline's `isCompletelyEmpty`: every input must be known, and
            // all three must be empty. An unreported list can never prove it.
            val completelyEmpty = status == SessionListStatus.READY &&
                workspaces != null && workspaces.isEmpty() &&
                ungroupedRows.isEmpty() &&
                archivedSessions != null && archivedSessions.isEmpty()
            val hasAnyRow = ungroupedRows.isNotEmpty() ||
                workspaceViews.any { it.sessions.isNotEmpty() } ||
                archived.rows.isNotEmpty()
            val empty = when {
                status != SessionListStatus.READY -> SessionsEmpty.NONE
                completelyEmpty -> SessionsEmpty.NO_SESSIONS
                query.isNotEmpty() && !hasAnyRow -> SessionsEmpty.NO_MATCHES
                else -> SessionsEmpty.NONE
            }
            val workspaceStatus = when {
                workspaces == null -> SessionWorkspaceStatus.UNKNOWN
                workspaces.isEmpty() -> SessionWorkspaceStatus.EMPTY
                else -> SessionWorkspaceStatus.READY
            }
            // A stale local target (the row disappeared) must not leave an editor
            // open on something the host no longer lists.
            val rename = local.renameTargetID
                ?.takeIf { id -> sessions.any { it.id == id } }
                ?.let { RenameEditor(sessionID = it, draft = local.renameDraft) }
            val deleteTarget = local.deleteTargetID?.takeIf { id -> sessions.any { it.id == id } }
            val renameWorkspace = local.renameWorkspaceTargetID
                ?.takeIf { id -> workspaces?.any { it.id == id } == true }
                ?.let { WorkspaceRenameEditor(workspaceID = it, draft = local.renameWorkspaceDraft) }
            val deleteWorkspaceTarget = local.deleteWorkspaceTargetID
                ?.takeIf { id -> workspaces?.any { it.id == id } == true }
            return SessionsScreenState(
                status = status,
                rows = ungroupedRows,
                empty = empty,
                failure = failure,
                rename = rename,
                deleteTargetID = deleteTarget,
                selectedID = currentID,
                query = local.query,
                workspaces = workspaceViews,
                workspaceStatus = workspaceStatus,
                archived = archived,
                newSessionBlock = newSessionBlock,
                completelyEmpty = completelyEmpty,
                renameWorkspace = renameWorkspace,
                deleteWorkspaceTargetID = deleteWorkspaceTarget,
                creatingWorkspace = local.creatingWorkspace,
                newWorkspaceDraft = local.newWorkspaceDraft,
                refreshInFlight = refreshing,
            )
        }
    }
}

// ---------------------------------------------------------------------------
// Page
// ---------------------------------------------------------------------------

/**
 * The sessions page (the drawer's body).
 *
 * @param state the pure screen state ([SessionsScreenState.from]).
 * @param onSelect switch to a session (the drawer closes upstream).
 * @param onQueryChange the search field changed.
 * @param onRenameStart open the rename dialog for a session.
 * @param onRenameDraftChange edit the rename draft.
 * @param onRenameCommit save the draft (an empty draft is not committed upstream).
 * @param onRenameCancel close the editor.
 * @param onDeleteRequest legacy session delete: never called by this page
 *   (the baseline archives instead; the parameter keeps older hosts linking).
 * @param onDeleteConfirm legacy session delete: never called by this page.
 * @param onDeleteCancel legacy session delete: never called by this page.
 * @param onNewSession create a session in the current folder (or ungrouped).
 * @param onRetry retry a failed list read.
 * @param onDismissFailure dismiss the failure line.
 * @param onBack leave the page (absent on a root drawer body).
 * @param onToggleWorkspace expand or collapse one folder section.
 * @param onWorkspaceMenuToggle open or close one folder's overflow menu.
 * @param onNewSessionInWorkspace create a session inside that folder.
 * @param onRenameWorkspaceStart open the folder rename editor.
 * @param onRenameWorkspaceDraftChange edit the folder rename draft.
 * @param onRenameWorkspaceCommit save the folder name.
 * @param onRenameWorkspaceCancel close the folder editor.
 * @param onDeleteWorkspaceRequest ask for the folder delete confirmation.
 * @param onDeleteWorkspaceConfirm delete the confirmed folder.
 * @param onDeleteWorkspaceCancel cancel the folder delete confirmation.
 * @param onAddWorkspace open the 新建工作文件夹 editor.
 * @param onWorkspaceDraftChange edit the new folder's name.
 * @param onCreateWorkspace create the folder from the draft.
 * @param onCancelCreateWorkspace close the editor without creating.
 * @param onToggleArchived expand or collapse 已归档.
 * @param onRestoreArchived restore one archived session.
 * @param onSessionMenuToggle open or close one session's long-press actions.
 * @param onArchiveSession archive one session (the baseline's alternative to delete).
 * @param onRefresh pull-to-refresh; `null` leaves the gesture inert.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
public fun SessionsPage(
    state: SessionsScreenState,
    onSelect: (SessionRowView) -> Unit,
    onQueryChange: (String) -> Unit,
    onRenameStart: (SessionRowView) -> Unit,
    onRenameDraftChange: (String) -> Unit,
    onRenameCommit: (SessionRowView) -> Unit,
    onRenameCancel: () -> Unit,
    onDeleteRequest: (SessionRowView) -> Unit = {},
    onDeleteConfirm: (SessionRowView) -> Unit = {},
    onDeleteCancel: () -> Unit = {},
    onNewSession: () -> Unit,
    modifier: Modifier = Modifier,
    onRetry: (() -> Unit)? = null,
    onDismissFailure: (() -> Unit)? = null,
    onBack: (() -> Unit)? = null,
    onToggleWorkspace: (SessionWorkspaceView) -> Unit = {},
    onWorkspaceMenuToggle: (SessionWorkspaceView) -> Unit = {},
    onNewSessionInWorkspace: (SessionWorkspaceView) -> Unit = {},
    onRenameWorkspaceStart: (SessionWorkspaceView) -> Unit = {},
    onRenameWorkspaceDraftChange: (String) -> Unit = {},
    onRenameWorkspaceCommit: (SessionWorkspaceView) -> Unit = {},
    onRenameWorkspaceCancel: () -> Unit = {},
    onDeleteWorkspaceRequest: (SessionWorkspaceView) -> Unit = {},
    onDeleteWorkspaceConfirm: (SessionWorkspaceView) -> Unit = {},
    onDeleteWorkspaceCancel: () -> Unit = {},
    onAddWorkspace: () -> Unit = {},
    onWorkspaceDraftChange: (String) -> Unit = {},
    onCreateWorkspace: () -> Unit = {},
    onCancelCreateWorkspace: () -> Unit = {},
    onToggleArchived: () -> Unit = {},
    onRestoreArchived: (ArchivedRowView) -> Unit = {},
    onSessionMenuToggle: (SessionRowView) -> Unit = {},
    onArchiveSession: (SessionRowView) -> Unit = {},
    /** Pull-to-refresh (`null` leaves the gesture a no-op). */
    onRefresh: (() -> Unit)? = null,
) {
    PageFrame(
        title = UiStrings.SESSIONS,
        onBack = onBack,
        rootTag = UiPageTags.SESSIONS_ROOT,
        modifier = modifier,
    ) {
        // The search field is a text input: the IME must lift the list, not cover
        // it (spec §5 row `ime`).
        Column(modifier = Modifier.fillMaxSize().imePadding()) {
            if (state.waiting) {
                EmptyHint(
                    title = UiStrings.WAITING_ENGINE,
                    hint = UiStrings.SESSIONS_EMPTY_HINT,
                    tag = UiPageTags.SESSIONS_EMPTY,
                )
                return@Column
            }
            SearchField(query = state.query, onQueryChange = onQueryChange)
            PullToRefreshBox(
                isRefreshing = state.refreshInFlight,
                onRefresh = onRefresh ?: {},
                modifier = Modifier.fillMaxSize().testTag(UiPageTags.SESSIONS_REFRESH),
            ) {
                SessionsList(
                    state = state,
                    onSelect = onSelect,
                    onNewSession = onNewSession,
                    onRenameStart = onRenameStart,
                    onRetry = onRetry,
                    onDismissFailure = onDismissFailure,
                    onToggleWorkspace = onToggleWorkspace,
                    onWorkspaceMenuToggle = onWorkspaceMenuToggle,
                    onNewSessionInWorkspace = onNewSessionInWorkspace,
                    onRenameWorkspaceStart = onRenameWorkspaceStart,
                    onDeleteWorkspaceRequest = onDeleteWorkspaceRequest,
                    onAddWorkspace = onAddWorkspace,
                    onToggleArchived = onToggleArchived,
                    onRestoreArchived = onRestoreArchived,
                    onSessionMenuToggle = onSessionMenuToggle,
                    onArchiveSession = onArchiveSession,
                )
            }
            // The baseline's alerts are real modal dialogs; using the standard
            // control keeps the interaction one design across pages.
            state.rename?.let { editor ->
                val row = state.rows.firstOrNull { it.id == editor.sessionID }
                    ?: state.workspaces.asSequence()
                        .flatMap { it.sessions.asSequence() }
                        .firstOrNull { it.id == editor.sessionID }
                if (row != null) {
                    RenameSessionDialog(
                        editor = editor,
                        onDraftChange = onRenameDraftChange,
                        onSave = { onRenameCommit(row) },
                        onCancel = onRenameCancel,
                    )
                }
            }
            state.renameWorkspace?.let { editor ->
                val workspace = state.workspaces.firstOrNull { it.id == editor.workspaceID }
                if (workspace != null) {
                    RenameWorkspaceDialog(
                        editor = editor,
                        onDraftChange = onRenameWorkspaceDraftChange,
                        onSave = { onRenameWorkspaceCommit(workspace) },
                        onCancel = onRenameWorkspaceCancel,
                    )
                }
            }
            if (state.creatingWorkspace) {
                NewWorkspaceDialog(
                    draft = state.newWorkspaceDraft,
                    onDraftChange = onWorkspaceDraftChange,
                    onCreate = onCreateWorkspace,
                    onCancel = onCancelCreateWorkspace,
                )
            }
            state.workspaces.firstOrNull { it.id == state.deleteWorkspaceTargetID }?.let { workspace ->
                DeleteWorkspaceDialog(
                    workspaceTitle = workspace.title,
                    onDelete = { onDeleteWorkspaceConfirm(workspace) },
                    onCancel = onDeleteWorkspaceCancel,
                )
            }
        }
    }
}


/** The drawer's scrollable body: Sections 1-5, in the baseline's order. */
@Composable
private fun SessionsList(
    state: SessionsScreenState,
    onSelect: (SessionRowView) -> Unit,
    onNewSession: () -> Unit,
    onRenameStart: (SessionRowView) -> Unit,
    onRetry: (() -> Unit)?,
    onDismissFailure: (() -> Unit)?,
    onToggleWorkspace: (SessionWorkspaceView) -> Unit,
    onWorkspaceMenuToggle: (SessionWorkspaceView) -> Unit,
    onNewSessionInWorkspace: (SessionWorkspaceView) -> Unit,
    onRenameWorkspaceStart: (SessionWorkspaceView) -> Unit,
    onDeleteWorkspaceRequest: (SessionWorkspaceView) -> Unit,
    onAddWorkspace: () -> Unit,
    onToggleArchived: () -> Unit,
    onRestoreArchived: (ArchivedRowView) -> Unit,
    onSessionMenuToggle: (SessionRowView) -> Unit,
    onArchiveSession: (SessionRowView) -> Unit,
) {
    LazyColumn(
        modifier = Modifier.fillMaxSize().testTag(UiPageTags.SESSIONS_LIST),
    ) {
        // Section 1: new session, its blocked reason, the failure line and
        // the sessions that belong to no folder.
        item(key = "new-session") {
            Column {
                NewSessionRow(
                    block = state.newSessionBlock,
                    onNewSession = onNewSession,
                )
                SessionHairline()
                if (state.newSessionBlock != null) {
                    BasicText(
                        text = state.newSessionBlock.reason,
                        style = LocalUiType.current.caption.copy(
                            color = LocalUiTokens.current.colors.secondary,
                        ),
                        modifier = Modifier
                            .fillMaxWidth()
                            .testTag(UiPageTags.SESSIONS_NEW_SESSION_BLOCKED)
                            .padding(
                                horizontal = LocalUiTokens.current.geometry.pageOuterMarginH,
                                vertical = LocalUiTokens.current.spacing.badgeInsetV,
                            ),
                    )
                }
                if (state.failure != null) {
                    SessionFailureLine(
                        message = state.failure,
                        tag = UiPageTags.SESSIONS_FAILURE,
                        retryLabel = UiStrings.RETRY,
                        onRetry = onRetry,
                        onDismiss = onDismissFailure,
                    )
                }
            }
        }
        items(items = state.rows, key = { "ungrouped-${it.id}" }) { row ->
            SessionItem(
                row = row,
                onSelect = onSelect,
                onRenameStart = onRenameStart,
                onSessionMenuToggle = onSessionMenuToggle,
                onArchiveSession = onArchiveSession,
            )
        }

        // Section 2: the completely-empty drawer. It replaces Sections 4
        // and 5 only when the host reported all three lists and all are
        // empty; a filter that hides every ungrouped row also counts.
        if (state.completelyEmpty) {
            item(key = "empty-drawer") {
                CompletelyEmptyBlock(onCreateWorkspace = onAddWorkspace)
            }
        }

        // Section 3 can only be drawn from a reported folder list. When
        // the host did not report one, the region says 未知 instead of
        // pretending there are no folders.
        if (state.workspaceStatus == SessionWorkspaceStatus.UNKNOWN) {
            item(key = "workspaces-unknown") {
                UnknownWorkspacesBlock()
            }
        }

        // Section 3: one section per workspace folder.
        state.workspaces.forEach { workspace ->
            item(key = "workspace-${workspace.id}") {
                WorkspaceRow(
                    workspace = workspace,
                    onToggle = onToggleWorkspace,
                    onMenuToggle = onWorkspaceMenuToggle,
                    onNewSession = onNewSessionInWorkspace,
                    onRename = onRenameWorkspaceStart,
                    onDelete = onDeleteWorkspaceRequest,
                )
            }
            if (workspace.expanded) {
                if (workspace.empty) {
                    item(key = "workspace-empty-${workspace.id}") {
                        WorkspaceSessionsEmpty()
                    }
                } else {
                    items(
                        items = workspace.sessions,
                        key = { "workspace-${workspace.id}-session-${it.id}" },
                    ) { row ->
                        SessionItem(
                            row = row,
                            onSelect = onSelect,
                            onRenameStart = onRenameStart,
                            onSessionMenuToggle = onSessionMenuToggle,
                            onArchiveSession = onArchiveSession,
                        )
                    }
                }
            }
        }

        // Section 4: add a workspace. The completely-empty block already
        // owns the entry point, so the row is hidden in that state.
        if (!state.completelyEmpty) {
            item(key = "add-workspace") {
                AddWorkspaceRow(onAddWorkspace = onAddWorkspace)
            }
        }

        // Section 5: archived sessions. Hidden together with Section 4
        // while the drawer is completely empty.
        if (!state.completelyEmpty) {
            item(key = "archived-header") {
                ArchivedHeader(
                    state = state,
                    onToggle = onToggleArchived,
                )
            }
            when (state.archived.status) {
                ArchivedStatus.UNKNOWN -> item(key = "archived-unknown") {
                    UnknownArchivedBlock()
                }

                ArchivedStatus.EMPTY -> item(key = "archived-empty") {
                    ArchivedEmptyBlock()
                }

                ArchivedStatus.READY -> items(
                    items = state.archived.rows,
                    key = { "archived-${it.id}" },
                ) { row ->
                    ArchivedRow(row = row, onRestore = onRestoreArchived)
                }

                ArchivedStatus.COLLAPSED -> Unit
            }
        }
    }
}

// ---------------------------------------------------------------------------
// Drawer pieces
// ---------------------------------------------------------------------------

/**
 * The search box; the query lives in the caller's state.
 *
 * iOS renders this as `.searchable` inside the navigation bar; Android pins it
 * above the list. The presentation differs, the query and the title filter do not.
 */
@Composable
private fun SearchField(query: String, onQueryChange: (String) -> Unit) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    BasicTextField(
        value = query,
        onValueChange = onQueryChange,
        singleLine = true,
        textStyle = type.body.copy(color = tokens.colors.primary),
        cursorBrush = SolidColor(tokens.colors.accent),
        keyboardOptions = KeyboardOptions(imeAction = ImeAction.Search),
        modifier = Modifier
            .fillMaxWidth()
            // Page-level geometry: the field aligns to the page margin.
            .padding(
                horizontal = tokens.geometry.pageOuterMarginH,
                vertical = tokens.spacing.badgeInsetV,
            )
            // unverified geometry: the composer's minimum height reused as the
            // search field's floor; only this page has a search field, so the spec
            // declares no page-level token for it.
            .heightIn(min = tokens.geometry.composerMinHeight)
            .testTag(UiPageTags.SESSIONS_SEARCH)
            .semantics { contentDescription = UiStrings.SESSION_SEARCH },
        decorationBox = { inner ->
            if (query.isEmpty()) {
                BasicText(
                    text = UiStrings.SESSION_SEARCH,
                    style = type.body.copy(color = tokens.colors.tertiary),
                )
            }
            inner()
        },
    )
}

/** The 新建会话 row: accent when enabled, the disabled ink plus a reason when not. */
@Composable
private fun NewSessionRow(block: NewSessionBlock?, onNewSession: () -> Unit) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    val ink = if (block == null) tokens.colors.accent else tokens.colors.tertiary
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .testTag(UiPageTags.SESSIONS_NEW_SESSION_ROW)
            .clickable(enabled = block == null, role = Role.Button, onClick = onNewSession)
            // Page-level geometry: this is the page's first action row.
            .defaultMinSize(minHeight = tokens.geometry.pageRowMinHeight)
            .padding(
                horizontal = tokens.geometry.pageOuterMarginH,
                vertical = tokens.spacing.badgeInsetV,
            ),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(tokens.spacing.iconText),
    ) {
        BasicText(text = PLUS_GLYPH, style = type.headline.copy(color = ink))
        BasicText(
            text = UiStrings.SESSION_NEW,
            style = type.body.copy(color = ink),
            modifier = Modifier.weight(1f),
        )
    }
}

/** One session row, its long-press `DropdownMenu` and the current check mark. */
@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun SessionItem(
    row: SessionRowView,
    onSelect: (SessionRowView) -> Unit,
    onRenameStart: (SessionRowView) -> Unit,
    onSessionMenuToggle: (SessionRowView) -> Unit,
    onArchiveSession: (SessionRowView) -> Unit,
) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    Column(modifier = Modifier.fillMaxWidth()) {
        Box(modifier = Modifier.fillMaxWidth()) {
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .testTag(UiPageTags.SESSION_ROW)
                    .combinedClickable(
                        role = Role.Button,
                        onClick = { onSelect(row) },
                        onLongClick = { onSessionMenuToggle(row) },
                    )
                    // Page-level geometry: a session row is a compact list row.
                    .defaultMinSize(minHeight = tokens.geometry.pageListRowMinHeight)
                    .padding(
                        horizontal = tokens.geometry.pageOuterMarginH,
                        vertical = tokens.spacing.iconText,
                    ),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(tokens.spacing.iconText),
            ) {
                Column(
                    modifier = Modifier.weight(1f),
                    verticalArrangement = Arrangement.spacedBy(tokens.spacing.badgeInsetV),
                ) {
                    BasicText(
                        text = row.title,
                        style = type.body.copy(color = tokens.colors.primary),
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                    Row(
                        horizontalArrangement = Arrangement.spacedBy(tokens.spacing.iconText),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        if (row.timeLabel != null) {
                            BasicText(
                                text = row.timeLabel,
                                style = type.caption.copy(color = tokens.colors.secondary),
                            )
                        }
                        // The baseline shows one run indicator only: a grey dot and
                        // 运行中. A failure is not a row state there, so it is not
                        // invented here.
                        if (row.status == SessionRunStatus.RUNNING) {
                            BasicText(
                                text = SEPARATOR_GLYPH,
                                style = type.caption.copy(color = tokens.colors.secondary),
                            )
                            Box(
                                modifier = Modifier
                                    // Page-level geometry: the run-status dot.
                                    .size(tokens.geometry.statusDotDiameter)
                                    .clip(CircleShape)
                                    .background(tokens.colors.secondary),
                            )
                            BasicText(
                                text = UiStrings.RUNNING,
                                style = type.caption.copy(color = tokens.colors.secondary),
                            )
                        }
                    }
                }
                if (row.selected) {
                    BasicText(
                        text = CHECK_GLYPH,
                        style = type.headline.copy(color = tokens.colors.primary),
                        modifier = Modifier
                            .testTag(UiPageTags.SESSIONS_SESSION_CURRENT)
                            .semantics { contentDescription = UiStrings.SESSIONS_CURRENT },
                    )
                }
            }
            // The baseline's `contextMenu`: a standard DropdownMenu, not an inline row.
            DropdownMenu(
                expanded = row.menuOpen,
                onDismissRequest = { onSessionMenuToggle(row) },
                modifier = Modifier.testTag(UiPageTags.SESSIONS_SESSION_MENU),
            ) {
                DropdownMenuItem(
                    text = {
                        BasicText(
                            text = UiStrings.SESSION_RENAME_TITLE,
                            style = type.body.copy(color = tokens.colors.primary),
                        )
                    },
                    onClick = { onRenameStart(row) },
                    colors = MenuDefaults.itemColors(textColor = tokens.colors.primary),
                    modifier = Modifier.testTag(UiPageTags.SESSIONS_SESSION_RENAME),
                )
                DropdownMenuItem(
                    // Archiving is recoverable, so it is not inked as destructive
                    // and it gets no confirmation (the baseline's rule).
                    text = {
                        BasicText(
                            text = UiStrings.SESSIONS_ARCHIVE,
                            style = type.body.copy(color = tokens.colors.primary),
                        )
                    },
                    onClick = { onArchiveSession(row) },
                    colors = MenuDefaults.itemColors(textColor = tokens.colors.primary),
                    modifier = Modifier.testTag(UiPageTags.SESSIONS_SESSION_ARCHIVE),
                )
            }
        }
        SessionHairline()
    }
}

/** The completely-empty drawer: title, one sentence and the full-width CTA. */
@Composable
private fun CompletelyEmptyBlock(onCreateWorkspace: () -> Unit) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .testTag(UiPageTags.SESSIONS_SECTION_EMPTY)
            .padding(
                horizontal = tokens.geometry.pageOuterMarginH,
                vertical = tokens.spacing.iconText,
            )
            .semantics(mergeDescendants = true) {},
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(tokens.spacing.iconText),
    ) {
        BasicText(
            text = UiStrings.WORKSPACE_EMPTY,
            style = type.headline.copy(color = tokens.colors.primary),
        )
        BasicText(
            text = UiStrings.SESSIONS_EMPTY_WORKSPACE_HINT,
            style = type.secondary.copy(color = tokens.colors.secondary),
        )
        Box(
            modifier = Modifier
                .fillMaxWidth()
                .padding(top = tokens.spacing.iconText)
                .clip(RoundedCornerShape(tokens.radius.card))
                .background(tokens.colors.accent)
                // Page-level geometry: the CTA is a page row, not a surface button.
                .defaultMinSize(minHeight = tokens.geometry.pageRowMinHeight)
                .clickable(role = Role.Button, onClick = onCreateWorkspace)
                .padding(
                    horizontal = tokens.spacing.iconText,
                    vertical = tokens.spacing.badgeInsetV,
                )
                .testTag(UiPageTags.SESSIONS_NEW_WORKSPACE)
                .semantics { contentDescription = UiStrings.SESSIONS_NEW_WORKSPACE },
            contentAlignment = Alignment.Center,
        ) {
            BasicText(
                text = UiStrings.SESSIONS_NEW_WORKSPACE,
                style = type.body.copy(color = tokens.colors.onAccent),
            )
        }
    }
}

/** One folder row: chevron, name, the filtered count and its `DropdownMenu`. */
@Composable
private fun WorkspaceRow(
    workspace: SessionWorkspaceView,
    onToggle: (SessionWorkspaceView) -> Unit,
    onMenuToggle: (SessionWorkspaceView) -> Unit,
    onNewSession: (SessionWorkspaceView) -> Unit,
    onRename: (SessionWorkspaceView) -> Unit,
    onDelete: (SessionWorkspaceView) -> Unit,
) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    Row(
        modifier = Modifier
            .fillMaxWidth()
            // Page-level geometry: a folder row is a 44-high list row.
            .defaultMinSize(minHeight = tokens.geometry.pageRowMinHeight)
            .padding(
                horizontal = tokens.geometry.pageOuterMarginH,
                vertical = tokens.spacing.badgeInsetV,
            ),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Row(
            modifier = Modifier
                .weight(1f)
                .testTag(UiPageTags.SESSIONS_WORKSPACE_ROW)
                .clickable(
                    role = Role.Button,
                    onClickLabel = if (workspace.expanded) {
                        UiStrings.SESSIONS_WORKSPACE_COLLAPSE
                    } else {
                        UiStrings.SESSIONS_WORKSPACE_EXPAND
                    },
                    onClick = { onToggle(workspace) },
                )
                .padding(vertical = tokens.spacing.badgeInsetV)
                .semantics {
                    contentDescription = UiStrings.SESSIONS_WORKSPACE_A11Y
                        .format(workspace.title, workspace.sessionCount)
                },
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(tokens.spacing.iconText),
        ) {
            BasicText(
                text = CHEVRON_GLYPH,
                style = type.caption.copy(color = tokens.colors.secondary),
                modifier = Modifier.rotate(if (workspace.expanded) EXPANDED_ROTATION else 0f),
            )
            BasicText(
                text = workspace.title,
                style = type.headline.copy(color = tokens.colors.primary),
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            if (workspace.sessionCount > 0) {
                BasicText(
                    text = UiStrings.SESSIONS_WORKSPACE_COUNT.format(workspace.sessionCount),
                    style = type.caption.copy(color = tokens.colors.secondary),
                )
            }
        }
        Box {
            BasicText(
                text = MORE_GLYPH,
                style = type.headline.copy(color = tokens.colors.secondary),
                modifier = Modifier
                    .testTag(UiPageTags.SESSIONS_WORKSPACE_MENU)
                    .clickable(role = Role.Button, onClick = { onMenuToggle(workspace) })
                    .padding(tokens.spacing.iconText)
                    .semantics {
                        contentDescription =
                            UiStrings.SESSIONS_WORKSPACE_OPTIONS.format(workspace.title)
                    },
            )
            // The baseline's `Menu`: a standard DropdownMenu in the baseline's order.
            DropdownMenu(
                expanded = workspace.menuOpen,
                onDismissRequest = { onMenuToggle(workspace) },
                modifier = Modifier.testTag(UiPageTags.SESSIONS_WORKSPACE_MENU_ACTIONS),
            ) {
                DropdownMenuItem(
                    text = {
                        BasicText(
                            text = UiStrings.SESSIONS_WORKSPACE_NEW_SESSION,
                            style = type.body.copy(color = tokens.colors.accent),
                        )
                    },
                    onClick = { onNewSession(workspace) },
                    colors = MenuDefaults.itemColors(textColor = tokens.colors.accent),
                    modifier = Modifier.testTag(UiPageTags.SESSIONS_WORKSPACE_NEW_SESSION),
                )
                DropdownMenuItem(
                    text = {
                        BasicText(
                            text = UiStrings.SESSION_RENAME,
                            style = type.body.copy(color = tokens.colors.primary),
                        )
                    },
                    onClick = { onRename(workspace) },
                    colors = MenuDefaults.itemColors(textColor = tokens.colors.primary),
                    modifier = Modifier.testTag(UiPageTags.SESSIONS_WORKSPACE_RENAME),
                )
                DropdownMenuItem(
                    text = {
                        BasicText(
                            text = UiStrings.SESSIONS_WORKSPACE_DELETE,
                            style = type.body.copy(color = tokens.colors.danger),
                        )
                    },
                    onClick = { onDelete(workspace) },
                    colors = MenuDefaults.itemColors(textColor = tokens.colors.danger),
                    modifier = Modifier.testTag(UiPageTags.SESSIONS_WORKSPACE_DELETE),
                )
            }
        }
    }
}

/** The expanded folder's empty copy; the query can empty a folder too. */
@Composable
private fun WorkspaceSessionsEmpty() {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .testTag(UiPageTags.SESSIONS_WORKSPACE_SESSIONS_EMPTY)
            .padding(
                horizontal = tokens.geometry.pageOuterMarginH,
                vertical = tokens.spacing.iconText,
            )
            .semantics(mergeDescendants = true) {},
        verticalArrangement = Arrangement.spacedBy(tokens.spacing.badgeInsetV),
    ) {
        BasicText(
            text = UiStrings.SESSIONS_WORKSPACE_SESSIONS_EMPTY,
            style = type.headline.copy(color = tokens.colors.primary),
        )
        BasicText(
            text = UiStrings.SESSIONS_WORKSPACE_SESSIONS_EMPTY_HINT,
            style = type.secondary.copy(color = tokens.colors.secondary),
        )
    }
}

/** The 添加工作文件夹 row (Section 4). */
@Composable
private fun AddWorkspaceRow(onAddWorkspace: () -> Unit) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .testTag(UiPageTags.SESSIONS_ADD_WORKSPACE)
            .clickable(role = Role.Button, onClick = onAddWorkspace)
            // Page-level geometry: a list action row.
            .defaultMinSize(minHeight = tokens.geometry.pageRowMinHeight)
            .padding(
                horizontal = tokens.geometry.pageOuterMarginH,
                vertical = tokens.spacing.badgeInsetV,
            ),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(tokens.spacing.iconText),
    ) {
        BasicText(
            text = PLUS_GLYPH,
            style = type.body.copy(color = tokens.colors.accent),
        )
        BasicText(
            text = UiStrings.SESSIONS_ADD_WORKSPACE,
            style = type.body.copy(color = tokens.colors.accent),
            modifier = Modifier.weight(1f),
        )
    }
}

/** The 已归档 header: a fold with the host's count (未知 when unreported). */
@Composable
private fun ArchivedHeader(state: SessionsScreenState, onToggle: () -> Unit) {
    SectionHeader(
        title = UiStrings.SESSIONS_ARCHIVED,
        expanded = state.archivedExpanded,
        onToggle = onToggle,
        trailing = state.archived.count?.toString() ?: UiStrings.UNKNOWN,
        tag = UiPageTags.SESSIONS_ARCHIVED_SECTION,
    )
}

/** The expanded 已归档 section with nothing in it. */
@Composable
private fun ArchivedEmptyBlock() {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .testTag(UiPageTags.SESSIONS_ARCHIVED_EMPTY)
            .padding(
                horizontal = tokens.geometry.pageOuterMarginH,
                vertical = tokens.spacing.iconText,
            )
            .semantics(mergeDescendants = true) {},
        verticalArrangement = Arrangement.spacedBy(tokens.spacing.badgeInsetV),
    ) {
        BasicText(
            text = UiStrings.SESSIONS_ARCHIVED_EMPTY,
            style = type.body.copy(color = tokens.colors.primary),
        )
        BasicText(
            text = UiStrings.SESSIONS_ARCHIVED_EMPTY_HINT,
            style = type.caption.copy(color = tokens.colors.secondary),
        )
    }
}

/** The unknown workspace region: no folder list was reported. */
@Composable
private fun UnknownWorkspacesBlock() {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .testTag(UiPageTags.SESSIONS_WORKSPACE_UNKNOWN)
            .padding(
                horizontal = tokens.geometry.pageOuterMarginH,
                vertical = tokens.spacing.iconText,
            )
            .semantics(mergeDescendants = true) {
                contentDescription = "${UiStrings.SESSIONS_WORKSPACE_UNKNOWN}. " +
                    UiStrings.SESSIONS_WORKSPACE_UNKNOWN_HINT
            },
        verticalArrangement = Arrangement.spacedBy(tokens.spacing.badgeInsetV),
    ) {
        BasicText(
            text = UiStrings.UNKNOWN,
            style = type.body.copy(color = tokens.colors.tertiary),
        )
        BasicText(
            text = UiStrings.SESSIONS_WORKSPACE_UNKNOWN_HINT,
            style = type.caption.copy(color = tokens.colors.tertiary),
        )
    }
}

/** The expanded 已归档 section when the host did not report the list. */
@Composable
private fun UnknownArchivedBlock() {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .testTag(UiPageTags.SESSIONS_ARCHIVED_UNKNOWN)
            .padding(
                horizontal = tokens.geometry.pageOuterMarginH,
                vertical = tokens.spacing.iconText,
            )
            .semantics(mergeDescendants = true) {
                contentDescription = "${UiStrings.SESSIONS_ARCHIVED_UNKNOWN}. " +
                    UiStrings.SESSIONS_ARCHIVED_UNKNOWN_HINT
            },
        verticalArrangement = Arrangement.spacedBy(tokens.spacing.badgeInsetV),
    ) {
        BasicText(
            text = UiStrings.UNKNOWN,
            style = type.body.copy(color = tokens.colors.tertiary),
        )
        BasicText(
            text = UiStrings.SESSIONS_ARCHIVED_UNKNOWN_HINT,
            style = type.caption.copy(color = tokens.colors.tertiary),
        )
    }
}

/** One archived session: name, time and 恢复. */
@Composable
private fun ArchivedRow(row: ArchivedRowView, onRestore: (ArchivedRowView) -> Unit) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .testTag(UiPageTags.SESSIONS_ARCHIVED_ROW)
            .padding(
                horizontal = tokens.geometry.pageOuterMarginH,
                vertical = tokens.spacing.badgeInsetV,
            ),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(tokens.spacing.iconText),
    ) {
        Column(
            modifier = Modifier.weight(1f),
            verticalArrangement = Arrangement.spacedBy(tokens.spacing.badgeInsetV),
        ) {
            BasicText(
                text = row.title,
                style = type.body.copy(color = tokens.colors.primary),
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            if (row.timeLabel != null) {
                BasicText(
                    text = row.timeLabel,
                    style = type.caption.copy(color = tokens.colors.secondary),
                )
            }
        }
        SessionTextAction(
            label = UiStrings.SESSIONS_RESTORE,
            onClick = { onRestore(row) },
            tone = SessionActionTone.ACCENT,
            modifier = Modifier.testTag(UiPageTags.SESSIONS_ARCHIVED_RESTORE),
        )
    }
}

/**
 * The modal frame every baseline alert uses; the buttons stay at the call site.
 *
 * The input dialogs are modal on purpose and Robolectric drives them (the field
 * accepts text and the buttons fire), so no inline fallback was needed.
 */
@Composable
private fun DialogFrame(
    title: String,
    onDismissRequest: () -> Unit,
    text: @Composable () -> Unit,
    confirmButton: @Composable () -> Unit,
    dismissButton: @Composable () -> Unit,
) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    AlertDialog(
        onDismissRequest = onDismissRequest,
        title = {
            BasicText(
                text = title,
                style = type.headline.copy(color = tokens.colors.primary),
            )
        },
        text = { text() },
        confirmButton = confirmButton,
        dismissButton = dismissButton,
    )
}

/** The shared 取消 button; the label is visible here, not a call-site parameter. */
@Composable
private fun DialogDismissButton(onClick: () -> Unit, tag: String) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    TextButton(
        onClick = onClick,
        colors = ButtonDefaults.textButtonColors(contentColor = tokens.colors.secondary),
        modifier = Modifier.testTag(tag),
    ) {
        BasicText(
            text = UiStrings.CANCEL,
            style = type.body.copy(color = tokens.colors.secondary),
        )
    }
}

/** The shared single-line field of the rename/create dialogs. */
@Composable
private fun DraftField(
    draft: String,
    onDraftChange: (String) -> Unit,
    placeholder: String,
    fieldTag: String,
    detail: String? = null,
) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    Column(verticalArrangement = Arrangement.spacedBy(tokens.spacing.iconText)) {
        if (detail != null) {
            BasicText(
                text = detail,
                style = type.caption.copy(color = tokens.colors.secondary),
            )
        }
        BasicTextField(
            value = draft,
            onValueChange = onDraftChange,
            singleLine = true,
            textStyle = type.body.copy(color = tokens.colors.primary),
            cursorBrush = SolidColor(tokens.colors.accent),
            keyboardOptions = KeyboardOptions(imeAction = ImeAction.Done),
            modifier = Modifier
                .fillMaxWidth()
                // Page-level geometry: an editor field is a page row.
                .heightIn(min = tokens.geometry.pageRowMinHeight)
                .testTag(fieldTag)
                .semantics { contentDescription = placeholder },
            decorationBox = { inner ->
                if (draft.isEmpty()) {
                    BasicText(
                        text = placeholder,
                        style = type.body.copy(color = tokens.colors.tertiary),
                    )
                }
                inner()
            },
        )
    }
}

/** 重命名会话: the baseline's modal alert with one field. */
@Composable
private fun RenameSessionDialog(
    editor: RenameEditor,
    onDraftChange: (String) -> Unit,
    onSave: () -> Unit,
    onCancel: () -> Unit,
) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    DialogFrame(
        title = UiStrings.SESSION_RENAME_TITLE,
        onDismissRequest = onCancel,
        text = {
            DraftField(
                draft = editor.draft,
                onDraftChange = onDraftChange,
                placeholder = UiStrings.SESSIONS_SESSION_TITLE,
                fieldTag = UiPageTags.SESSION_RENAME_FIELD,
            )
        },
        confirmButton = {
            TextButton(
                onClick = onSave,
                colors = ButtonDefaults.textButtonColors(contentColor = tokens.colors.accent),
                modifier = Modifier.testTag(UiPageTags.SESSION_RENAME_SAVE),
            ) {
                BasicText(
                    text = UiStrings.SAVE,
                    style = type.body.copy(color = tokens.colors.accent),
                )
            }
        },
        dismissButton = {
            DialogDismissButton(onCancel, UiPageTags.SESSION_RENAME_CANCEL)
        },
    )
}

/** 重命名工作文件夹: the baseline's modal alert with one field. */
@Composable
private fun RenameWorkspaceDialog(
    editor: WorkspaceRenameEditor,
    onDraftChange: (String) -> Unit,
    onSave: () -> Unit,
    onCancel: () -> Unit,
) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    DialogFrame(
        title = UiStrings.SESSIONS_WORKSPACE_RENAME,
        onDismissRequest = onCancel,
        text = {
            DraftField(
                draft = editor.draft,
                onDraftChange = onDraftChange,
                placeholder = UiStrings.SESSIONS_WORKSPACE_NAME,
                fieldTag = UiPageTags.SESSIONS_WORKSPACE_RENAME_FIELD,
            )
        },
        confirmButton = {
            TextButton(
                onClick = onSave,
                colors = ButtonDefaults.textButtonColors(contentColor = tokens.colors.accent),
                modifier = Modifier.testTag(UiPageTags.SESSIONS_WORKSPACE_RENAME_SAVE),
            ) {
                BasicText(
                    text = UiStrings.SAVE,
                    style = type.body.copy(color = tokens.colors.accent),
                )
            }
        },
        dismissButton = {
            DialogDismissButton(onCancel, UiPageTags.SESSIONS_WORKSPACE_RENAME_CANCEL)
        },
    )
}

/** 新建工作文件夹: name plus the baseline's explanation of what it creates. */
@Composable
private fun NewWorkspaceDialog(
    draft: String,
    onDraftChange: (String) -> Unit,
    onCreate: () -> Unit,
    onCancel: () -> Unit,
) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    DialogFrame(
        title = UiStrings.SESSIONS_NEW_WORKSPACE,
        onDismissRequest = onCancel,
        text = {
            DraftField(
                draft = draft,
                onDraftChange = onDraftChange,
                placeholder = UiStrings.SESSIONS_WORKSPACE_NAME_FIELD,
                fieldTag = UiPageTags.SESSIONS_NEW_WORKSPACE_FIELD,
                detail = UiStrings.SESSIONS_WORKSPACE_CREATE_DETAIL,
            )
        },
        confirmButton = {
            TextButton(
                onClick = onCreate,
                colors = ButtonDefaults.textButtonColors(contentColor = tokens.colors.accent),
                modifier = Modifier.testTag(UiPageTags.SESSIONS_NEW_WORKSPACE_CREATE),
            ) {
                BasicText(
                    text = UiStrings.WORKSPACE_CREATE,
                    style = type.body.copy(color = tokens.colors.accent),
                )
            }
        },
        dismissButton = {
            DialogDismissButton(onCancel, UiPageTags.SESSIONS_NEW_WORKSPACE_CANCEL)
        },
    )
}

/** 删除工作文件夹: a pure confirmation; the folder's sessions survive it. */
@Composable
private fun DeleteWorkspaceDialog(
    workspaceTitle: String,
    onDelete: () -> Unit,
    onCancel: () -> Unit,
) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    DialogFrame(
        title = UiStrings.SESSIONS_WORKSPACE_DELETE_CONFIRM.format(workspaceTitle),
        onDismissRequest = onCancel,
        text = {
            BasicText(
                text = UiStrings.SESSIONS_WORKSPACE_DELETE_DETAIL,
                style = type.secondary.copy(color = tokens.colors.secondary),
            )
        },
        confirmButton = {
            TextButton(
                onClick = onDelete,
                colors = ButtonDefaults.textButtonColors(contentColor = tokens.colors.danger),
                modifier = Modifier.testTag(UiPageTags.SESSIONS_WORKSPACE_DELETE_YES),
            ) {
                BasicText(
                    text = UiStrings.SESSION_DELETE,
                    style = type.body.copy(color = tokens.colors.danger),
                )
            }
        },
        dismissButton = {
            DialogDismissButton(onCancel, UiPageTags.SESSIONS_WORKSPACE_DELETE_NO)
        },
    )
}

/** Which lane a queued message waits in. */
public enum class QueueLane { NEXT_TURN, CURRENT_STEP }

/** Maps the host's lane string; anything that is not `next-turn` is the current step. */
public fun queueLaneOf(raw: String): QueueLane =
    if (raw == NEXT_TURN_LANE) QueueLane.NEXT_TURN else QueueLane.CURRENT_STEP

/** One queued message exactly as the host lists it. */
public data class SessionQueueItem(
    public val id: String,
    public val lane: QueueLane,
    public val text: String = "",
)

/** The queue page's local events: only the edit draft is local. */
public data class SessionQueueLocalState(
    public val editingID: String? = null,
    public val editDraft: String = "",
)

/** What the queue page currently knows. */
public enum class QueueStatus {
    /** The host has not read this session's queue yet (the baseline's progress view). */
    LOADING,

    /** The host read the queue and it is empty. */
    EMPTY,

    /** The host read at least one queued message. */
    READY,
}

/** One visible queued message. */
public data class SessionQueueRowView(
    public val id: String,
    public val lane: QueueLane,
    /** 下一轮 or 当前步骤. */
    public val laneLabel: String,
    public val text: String,
    public val editing: Boolean,
)

/**
 * The queue page's state.
 *
 * @param status loading until the host reports this session's queue.
 * @param rows the queued messages, in the host's order: the baseline lists
 *   `next-turn` before `next-step`.
 * @param failure the host's read failure; the page shows it as its own 错误
 *   section (the baseline's Section 8).
 */
public data class SessionQueueScreenState(
    public val status: QueueStatus,
    public val rows: List<SessionQueueRowView>,
    public val failure: String?,
    public val editDraft: String = "",
    /** True while a host refresh is in flight (the pull-to-refresh indicator). */
    public val refreshInFlight: Boolean = false,
) {
    public companion object {
        /**
         * Projects the queue read into the page state.
         *
         * Pure: the same items and the same edit script always yield the same
         * lanes, labels and editor, so the sequence replays on the JVM.
         *
         * @param sessionID the session whose queue this page shows.
         * @param items the host's queue; `null` means it has not been read yet.
         * @param queueSessionID the session the host's last queue read belongs
         *   to; when it differs from [sessionID] the page is still loading (the
         *   baseline's `queueSessionID != session.id` check).
         * @param failure the host's read failure, if any.
         * @param local the local edit editor.
         */
        public fun from(
            sessionID: String,
            items: List<SessionQueueItem>? = null,
            queueSessionID: String? = null,
            failure: String? = null,
            local: SessionQueueLocalState = SessionQueueLocalState(),
            refreshing: Boolean = false,
        ): SessionQueueScreenState {
            val status = when {
                queueSessionID != sessionID || items == null -> QueueStatus.LOADING
                items.isEmpty() -> QueueStatus.EMPTY
                else -> QueueStatus.READY
            }
            val editingID = local.editingID?.takeIf { id -> items.orEmpty().any { it.id == id } }
            val rows = if (status == QueueStatus.READY) {
                items.orEmpty().map { item ->
                    SessionQueueRowView(
                        id = item.id,
                        lane = item.lane,
                        laneLabel = when (item.lane) {
                            QueueLane.NEXT_TURN -> UiStrings.SESSIONS_QUEUE_NEXT_TURN
                            QueueLane.CURRENT_STEP -> UiStrings.SESSIONS_QUEUE_CURRENT_STEP
                        },
                        text = item.text,
                        editing = item.id == editingID,
                    )
                }
            } else {
                emptyList()
            }
            return SessionQueueScreenState(
                status = status,
                rows = rows,
                failure = failure,
                editDraft = local.editDraft,
                refreshInFlight = refreshing,
            )
        }
    }
}

/**
 * The queue page (the baseline's `SessionQueuePage`, Sections 6-8).
 *
 * The baseline wires a navigation destination for it but never sets the
 * selection, so no drawer row opens it there; this port mirrors that and does
 * not invent an entry point. The page is public so the host can present it when
 * it grows one.
 *
 * @param state the pure screen state ([SessionQueueScreenState.from]).
 * @param onBack leave the page.
 * @param onEdit open the editor dialog for one message.
 * @param onEditDraftChange edit the replacement text.
 * @param onEditSave commit the replacement (`action: edit` upstream).
 * @param onEditCancel close the editor.
 * @param onSteer make one message the current steer (`action: steer`).
 * @param onRemove remove one message (`action: remove`).
 * @param onRetry retry a failed queue read.
 * @param onRefresh pull-to-refresh (the baseline's `.refreshable`).
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
public fun SessionQueuePage(
    state: SessionQueueScreenState,
    modifier: Modifier = Modifier,
    onBack: (() -> Unit)? = null,
    onEdit: (SessionQueueRowView) -> Unit = {},
    onEditDraftChange: (String) -> Unit = {},
    onEditSave: (SessionQueueRowView) -> Unit = {},
    onEditCancel: () -> Unit = {},
    onSteer: (SessionQueueRowView) -> Unit = {},
    onRemove: (SessionQueueRowView) -> Unit = {},
    onRetry: (() -> Unit)? = null,
    onRefresh: (() -> Unit)? = null,
) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    PageFrame(
        title = UiStrings.SESSIONS_QUEUE_TITLE,
        onBack = onBack,
        rootTag = UiPageTags.SESSION_QUEUE_ROOT,
        modifier = modifier,
    ) {
        PullToRefreshBox(
            isRefreshing = state.refreshInFlight,
            onRefresh = onRefresh ?: {},
            modifier = Modifier.fillMaxSize().testTag(UiPageTags.SESSION_QUEUE_REFRESH),
        ) {
            LazyColumn(
                modifier = Modifier.fillMaxSize().testTag(UiPageTags.SESSION_QUEUE_LIST),
            ) {
                when (state.status) {
                    QueueStatus.LOADING -> item(key = "queue-loading") {
                        BasicText(
                            text = UiStrings.SESSIONS_QUEUE_LOADING,
                            style = type.secondary.copy(color = tokens.colors.secondary),
                            modifier = Modifier
                                .fillMaxWidth()
                                .testTag(UiPageTags.SESSION_QUEUE_LOADING)
                                .padding(
                                    horizontal = tokens.geometry.pageOuterMarginH,
                                    vertical = tokens.spacing.iconText,
                                ),
                        )
                    }

                    QueueStatus.EMPTY -> item(key = "queue-empty") {
                        EmptyHint(
                            title = UiStrings.SESSIONS_QUEUE_EMPTY,
                            hint = UiStrings.SESSIONS_QUEUE_EMPTY_HINT,
                            tag = UiPageTags.SESSION_QUEUE_EMPTY,
                            modifier = Modifier.fillParentMaxSize(),
                        )
                    }

                    QueueStatus.READY -> items(
                        items = state.rows,
                        key = { "queue-${it.id}" },
                    ) { row ->
                        SessionSectionLabel(
                            text = row.laneLabel,
                            modifier = Modifier.testTag(UiPageTags.SESSION_QUEUE_SECTION),
                        )
                        Column(
                            modifier = Modifier
                                .fillMaxWidth()
                                .testTag(UiPageTags.SESSION_QUEUE_ROW)
                                .padding(
                                    horizontal = tokens.geometry.pageOuterMarginH,
                                    vertical = tokens.spacing.badgeInsetV,
                                ),
                            verticalArrangement = Arrangement.spacedBy(tokens.spacing.badgeInsetV),
                        ) {
                            BasicText(
                                text = if (row.text.isEmpty()) {
                                    UiStrings.SESSIONS_QUEUE_NO_TEXT
                                } else {
                                    row.text
                                },
                                style = type.body.copy(color = tokens.colors.primary),
                            )
                            Row(
                                modifier = Modifier.fillMaxWidth(),
                                verticalAlignment = Alignment.CenterVertically,
                                horizontalArrangement = Arrangement.spacedBy(tokens.spacing.iconText),
                            ) {
                                SessionTextAction(
                                    label = UiStrings.SESSIONS_QUEUE_EDIT,
                                    onClick = { onEdit(row) },
                                    tone = SessionActionTone.ACCENT,
                                    modifier = Modifier.testTag(UiPageTags.SESSION_QUEUE_EDIT),
                                )
                                SessionTextAction(
                                    label = UiStrings.SESSIONS_QUEUE_STEER,
                                    onClick = { onSteer(row) },
                                    tone = SessionActionTone.SECONDARY,
                                    modifier = Modifier.testTag(UiPageTags.SESSION_QUEUE_STEER),
                                )
                                SessionTextAction(
                                    label = UiStrings.SESSIONS_QUEUE_REMOVE,
                                    onClick = { onRemove(row) },
                                    tone = SessionActionTone.DANGER,
                                    modifier = Modifier.testTag(UiPageTags.SESSION_QUEUE_REMOVE),
                                )
                            }
                        }
                    }
                }
                if (state.failure != null) {
                    item(key = "queue-error") {
                        Column(modifier = Modifier.fillMaxWidth()) {
                            SessionSectionLabel(
                                text = UiStrings.SESSIONS_QUEUE_ERROR,
                                modifier = Modifier.testTag(UiPageTags.SESSION_QUEUE_ERROR),
                            )
                            BasicText(
                                text = state.failure,
                                style = type.caption.copy(color = tokens.colors.danger),
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .padding(
                                        horizontal = tokens.geometry.pageOuterMarginH,
                                        vertical = tokens.spacing.badgeInsetV,
                                    ),
                            )
                            if (onRetry != null) {
                                SessionTextAction(
                                    label = UiStrings.RETRY,
                                    onClick = onRetry,
                                    tone = SessionActionTone.ACCENT,
                                    modifier = Modifier.padding(
                                        horizontal = tokens.geometry.pageOuterMarginH,
                                    ),
                                )
                            }
                        }
                    }
                }
            }
        }
        state.rows.firstOrNull { it.editing }?.let { row ->
            EditQueueDialog(
                text = state.editDraft,
                onTextChange = onEditDraftChange,
                onSave = { onEditSave(row) },
                onCancel = onEditCancel,
            )
        }
    }
}

/**
 * The queue message editor: the baseline's `.sheet` with a TextEditor.
 *
 * Modal on purpose, like the other editors; the standard dialog keeps the
 * interaction one design instead of an inline field that only this page has.
 */
@Composable
private fun EditQueueDialog(
    text: String,
    onTextChange: (String) -> Unit,
    onSave: () -> Unit,
    onCancel: () -> Unit,
) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    DialogFrame(
        title = UiStrings.SESSIONS_QUEUE_EDIT_TITLE,
        onDismissRequest = onCancel,
        text = {
            BasicTextField(
                value = text,
                onValueChange = onTextChange,
                textStyle = type.body.copy(color = tokens.colors.primary),
                cursorBrush = SolidColor(tokens.colors.accent),
                modifier = Modifier
                    .fillMaxWidth()
                    .heightIn(min = tokens.geometry.pageRowMinHeight)
                    .testTag(UiPageTags.SESSION_QUEUE_EDIT_FIELD)
                    .semantics { contentDescription = UiStrings.SESSIONS_QUEUE_EDIT_TITLE },
            )
        },
        confirmButton = {
            TextButton(
                onClick = onSave,
                colors = ButtonDefaults.textButtonColors(contentColor = tokens.colors.accent),
                modifier = Modifier.testTag(UiPageTags.SESSION_QUEUE_SAVE),
            ) {
                BasicText(
                    text = UiStrings.SAVE,
                    style = type.body.copy(color = tokens.colors.accent),
                )
            }
        },
        dismissButton = {
            DialogDismissButton(onCancel, UiPageTags.SESSION_QUEUE_CANCEL)
        },
    )
}

// ---------------------------------------------------------------------------
// Copy policy and pure helpers
// ---------------------------------------------------------------------------

/**
 * The token inventory of this page; `PageTokenReferenceTest` fails when a use
 * site reads a token that is not listed here, and fails the other way around
 * when a listed token is no longer read.
 */
internal object SessionsPageTokens {
    val refs: List<String> = listOf(
        UiTokenNames.COLORS_PRIMARY,
        UiTokenNames.COLORS_SECONDARY,
        UiTokenNames.COLORS_TERTIARY,
        UiTokenNames.COLORS_ACCENT,
        UiTokenNames.COLORS_ON_ACCENT,
        UiTokenNames.COLORS_DANGER,
        UiTokenNames.TYPOGRAPHY_BODY,
        UiTokenNames.TYPOGRAPHY_SECONDARY,
        UiTokenNames.TYPOGRAPHY_CAPTION,
        UiTokenNames.TYPOGRAPHY_HEADLINE,
        UiTokenNames.SPACING_ICON_TEXT,
        UiTokenNames.SPACING_BADGE_INSET_V,
        UiTokenNames.RADIUS_CARD,
        UiTokenNames.GEOMETRY_PAGE_LIST_ROW_MIN_HEIGHT,
        UiTokenNames.GEOMETRY_STATUS_DOT_DIAMETER,
        UiTokenNames.GEOMETRY_PAGE_OUTER_MARGIN_H,
        UiTokenNames.GEOMETRY_COMPOSER_MIN_HEIGHT,
        UiTokenNames.GEOMETRY_PAGE_ROW_MIN_HEIGHT,
    )
}

/** The visible title for a host title: a default/blank name is reworded, never shown raw. */
internal fun sessionTitle(raw: String?, index: Int): String {
    val trimmed = raw.orEmpty().trim()
    return if (trimmed.isEmpty() || trimmed.lowercase() in DEFAULT_SESSION_TITLES) {
        if (index > 1) UiStrings.NEW_SESSION_INDEXED.format(index) else UiStrings.NEW_SESSION
    } else {
        trimmed
    }
}

/** Kept for callers of the previous page: same policy, same arguments. */
internal fun displayTitle(raw: String, index: Int): String = sessionTitle(raw, index)

/**
 * The visible workspace name, the baseline's `DrawerTitles.workspaceTitle`:
 * a default/blank name becomes 工作文件夹 (numbered from the second folder), a
 * path-like name keeps only its last segment, and an empty segment falls back
 * to 未命名文件夹.
 */
internal fun workspaceTitle(raw: String, index: Int): String {
    val trimmed = raw.trim()
    if (trimmed.isEmpty() || trimmed.lowercase() in DEFAULT_WORKSPACE_TITLES) {
        return if (index > 1) {
            UiStrings.SESSIONS_WORKSPACE_INDEXED.format(index)
        } else {
            UiStrings.SESSIONS_WORKSPACE_DEFAULT
        }
    }
    return lastSegmentName(trimmed, UiStrings.SESSIONS_WORKSPACE_UNNAMED)
}

/** The last path segment as a name, with the baseline's fallbacks. */
internal fun lastSegmentName(raw: String, fallback: String): String {
    val parts = raw.trim().split('/').filter { it.isNotEmpty() }
    val name = parts.lastOrNull()?.trim().orEmpty()
    if (name.isEmpty() || name == "." || name == ".." || name == "~") return fallback
    return middleTruncate(name, WORKSPACE_NAME_LIMIT)
}

/** Middle-truncates at [limit] characters, with the baseline's ellipsis. */
internal fun middleTruncate(text: String, limit: Int): String {
    if (text.length <= limit || limit <= 1) return text
    val head = (limit - 1) / 2
    val tail = limit - 1 - head
    return text.take(head) + ELLIPSIS + text.takeLast(tail)
}

/** The visible names for one ordering, numbered by occurrence (the baseline's rule). */
internal fun displayTitles(ordered: List<SessionListing>): Map<String, String> {
    val counts = mutableMapOf<String, Int>()
    val titles = mutableMapOf<String, String>()
    ordered.forEach { session ->
        val base = sessionTitle(session.title, index = 1)
        val occurrence = (counts[base] ?: 0) + 1
        counts[base] = occurrence
        titles[session.id] = sessionTitle(session.title, occurrence)
    }
    return titles
}

/**
 * The title of an archived session. The baseline numbers it against the active
 * ordering (which never contains it), so the count of active sessions sharing
 * its base name is the index it would have had.
 */
internal fun archivedTitle(session: SessionListing, activeOrder: List<SessionListing>): String {
    val base = sessionTitle(session.title, index = 1)
    val index = activeOrder.count { sessionTitle(it.title, index = 1) == base }
    return sessionTitle(session.title, maxOf(index, 1))
}

/** Orders the host's folders: the explicit order first, then the rest in host order. */
internal fun orderWorkspaces(
    workspaces: List<SessionWorkspace>,
    order: List<String>,
): List<SessionWorkspace> {
    val byID = workspaces.associateBy { it.id }
    val listed = order.mapNotNull { byID[it] }
    val listedIDs = listed.map { it.id }.toSet()
    return listed + workspaces.filterNot { it.id in listedIDs }
}

/** Pins first inside one group; ties keep the host order (the baseline's `pinnedFirst`). */
internal fun pinnedFirst(
    sessions: List<SessionListing>,
    pinnedSessionIDs: List<String>,
): List<SessionListing> {
    val rank = pinnedSessionIDs.withIndex().associate { (index, id) -> id to index }
    // Kotlin's sortedWith is stable, so equal ranks keep the host order.
    return sessions.sortedBy { rank[it.id] ?: Int.MAX_VALUE }
}

/** One Chinese relative time, the same thresholds as the iOS baseline. */
internal fun relativeTime(updatedAtMs: Long, nowMs: Long, zone: ZoneId): String {
    val delta = nowMs - updatedAtMs
    return when {
        delta < MINUTE_MS -> UiStrings.JUST_NOW
        delta < HOUR_MS -> UiStrings.MINUTES_AGO.format(delta / MINUTE_MS)
        delta < DAY_MS -> UiStrings.HOURS_AGO.format(delta / HOUR_MS)
        else -> {
            val date = Instant.ofEpochMilli(updatedAtMs).atZone(zone)
            UiStrings.MONTH_DAY.format(date.monthValue, date.dayOfMonth)
        }
    }
}

/** The row label for a run status; the baseline only renders RUNNING. */
internal val SessionRunStatus.label: String
    get() = when (this) {
        SessionRunStatus.RUNNING -> UiStrings.RUNNING
        SessionRunStatus.IDLE -> UiStrings.IDLE
        SessionRunStatus.FAILED -> UiStrings.FAILED_STATUS
        SessionRunStatus.WAITING -> UiStrings.WAITING
    }

/**
 * The host's own placeholders for "unnamed". These are compared, never shown: the
 * visible wording comes from [UiStrings.NEW_SESSION] / [UiStrings.NEW_SESSION_INDEXED].
 * Keeping the two apart is why the literals live here instead of in `UiStrings`.
 */
private val DEFAULT_SESSION_TITLES: Set<String> =
    setOf("new conversation", "新会话", "conversation", "untitled")

/** The baseline's default folder names, compared lowercase and never shown raw. */
private val DEFAULT_WORKSPACE_TITLES: Set<String> =
    setOf("workspace", "工作区", "工作文件夹", "default")

private const val WORKSPACE_NAME_LIMIT: Int = 12
private const val NEXT_TURN_LANE: String = "next-turn"
private const val EXPANDED_ROTATION: Float = 90f
private const val MINUTE_MS: Long = 60_000
private const val HOUR_MS: Long = 3_600_000
private const val DAY_MS: Long = 86_400_000

/** The glyphs the drawer draws; the baseline's SF Symbols have no Compose peer. */
private const val PLUS_GLYPH: String = "+"
private const val MORE_GLYPH: String = "…"
private const val CHEVRON_GLYPH: String = "›"
private const val CHECK_GLYPH: String = "✓"
private const val SEPARATOR_GLYPH: String = "·"
private const val ELLIPSIS: String = "…"
