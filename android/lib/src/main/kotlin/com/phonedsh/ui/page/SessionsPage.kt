// The drawer (sessions, workspaces, archive).
// SPDX-License-Identifier: MIT
//
// Spec: `spec/ui/v1/README.md` §1 (SessionsPage: 会话列表、重命名、删除、开关) and
// §3.1 (the two layers). The baseline is
// `examples/probe-app/PhoneDSHProbe/SessionsPage.swift`, which draws the drawer
// as five `Section` blocks in the page body.
//
// The drawer's sections, in the baseline's order:
//   1. 新建会话, its blocked reason, the failure line and the ungrouped sessions;
//   2. the completely-empty block (no folder, no session, no archive);
//   3. one section per workspace: the folder row, its menu, then its sessions;
//   4. 添加工作文件夹 (hidden while the drawer is completely empty);
//   5. 已归档: a header with the count, then the archived rows and 恢复.
//
// L55 removed the `SessionQueuePage` that used to live in this file. The baseline
// keeps that screen as a **private** sub-view of `SessionsPage.swift:656`, opened
// by `navigationDestination(item: $selectedQueueSession)` — and `selectedQueueSession`
// is declared at `:101` and never assigned anywhere in the probe app, so the
// screen has no entry on iOS either. The queue a person actually sees is Chat's
// own `queueDock` (`ChatPage.swift`). A page with no entry on either platform, no
// own contract and no route was the zero-call debt this lane was asked to close.
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
// Width (L73): the page fills the container it is given. The 320 pt drawer is the
// *container's* constant (`NativeShell.swift:97`, and the preview drawer at
// `:875`), never this page's: iOS captures the same page at 402 in the `.sessions`
// route and at 320 inside `DrawerPreview`, and the two PNGs differ by the container
// alone. A page that pinned its own list to 320 could not reproduce that pair.
//
// Geometry: the page margin and the three row floors are page-level tokens from
// `spec/ui/v1/tokens.json`; the search field's floor reuses the composer's
// minimum height and is marked `unverified geometry` at its one use site. The
// values the baseline hard-codes as literals (288 pt separators, 50 pt CTA, the
// 16.3 x 15.3 balloon ink, 18.3 x 4 ellipsis) live in the private constants at the
// bottom of the file, each with the source line it was measured from. No value is
// re-typed here.
package com.phonedsh.ui.page

import androidx.compose.animation.core.CubicBezierEasing
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.gestures.waitForUpOrCancellation
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.WindowInsetsSides
import androidx.compose.foundation.layout.defaultMinSize
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.only
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawing
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.windowInsetsPadding
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
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.input.pointer.PointerEventPass
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.PlatformTextStyle
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.phonedsh.ui.SessionsMetrics
import com.phonedsh.ui.UiStrings
import com.phonedsh.ui.disclosure.PdshChevron
import com.phonedsh.ui.disclosure.PdshFolderGroup
import com.phonedsh.ui.icon.PdshIcon
import com.phonedsh.ui.icon.PdshIconView
import com.phonedsh.ui.menu.ContextMenuRowState
import com.phonedsh.ui.menu.PdshContextMenu
import com.phonedsh.ui.theme.LocalUiTokens
import com.phonedsh.ui.theme.materialDialogColors
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

/** A host-confirmed mutation result. Pages never infer success from a callback returning. */
public data class PageMutationReceipt(
    public val operation: PageMutationOperation,
    public val outcome: PageMutationOutcome,
    /** The host-reported object name, when it is safe and useful to show. */
    public val subject: String? = null,
    /** The host's failure reason; shown only when [outcome] is [PageMutationOutcome.FAILED]. */
    public val failureReason: String? = null,
    /** True only when the host confirms that archiving removed the active conversation context. */
    public val contextLost: Boolean = false,
) {
    /** Human-readable copy derived from the typed result, never from an action callback. */
    public val message: String
        get() {
            if (outcome == PageMutationOutcome.FAILED) {
                return failureReason?.takeIf(String::isNotBlank) ?: "操作未完成，原有内容已保留"
            }
            val name = subject?.takeIf(String::isNotBlank)
            if (operation == PageMutationOperation.SESSION_ARCHIVE && contextLost) {
                return "${name ?: "会话"}已归档；当前上下文已离开。"
            }
            return when (operation) {
                PageMutationOperation.SESSION_RENAME -> "${name ?: "会话"}已重命名"
                PageMutationOperation.SESSION_ARCHIVE -> "${name ?: "会话"}已归档，可在已归档会话中恢复"
                PageMutationOperation.SESSION_RESTORE -> "${name ?: "会话"}已恢复"
                PageMutationOperation.WORKSPACE_CREATE -> "${name ?: "工作文件夹"}已创建"
                PageMutationOperation.WORKSPACE_RENAME -> "${name ?: "工作文件夹"}已重命名"
                PageMutationOperation.WORKSPACE_DELETE -> "${name ?: "工作文件夹"}已删除；其中的会话已保留"
            }
        }
}

/** Operations for which a page can present a host-confirmed receipt. */
public enum class PageMutationOperation {
    SESSION_RENAME,
    SESSION_ARCHIVE,
    SESSION_RESTORE,
    WORKSPACE_CREATE,
    WORKSPACE_RENAME,
    WORKSPACE_DELETE,
}

/** A success is shown only when the host supplies [SUCCEEDED]. */
public enum class PageMutationOutcome { SUCCEEDED, FAILED }

/**
 * Why the list has no visible row.
 *
 * `NO_SESSIONS` is a host-confirmed completely-empty drawer (no folder, active
 * session or archived session). `NO_MATCHES` means real host data exists but
 * the query filtered every session out.
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
 * @param isDefault the host says this is its built-in phone workspace. The
 *   title fallback also covers older hosts that only send `default-workspace`.
 */
public data class SessionWorkspace(
    public val id: String,
    public val title: String,
    public val sessionIDs: List<String> = emptyList(),
    public val isDefault: Boolean = false,
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
 * @param completelyEmpty true only when all required host lists were reported
 *   and the unfiltered host data has no workspace, active session or archive.
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
    /** A receipt from the host after it confirms a mutation; `null` means no result was reported. */
    public val mutationReceipt: PageMutationReceipt? = null,
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
            /** Explicit app language id; `null` keeps the established Chinese copy. */
            languageId: String? = null,
            pinnedSessionIDs: List<String>? = null,
            workspaceOrder: List<String>? = null,
            refreshing: Boolean = false,
            mutationReceipt: PageMutationReceipt? = null,
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
            // Loose sessions belong to the built-in phone workspace, not to a
            // separate synthetic 日常 group. A host that has not registered a
            // default folder yet keeps the temporary group (the baseline's
            // `looseHeader`), so the rows are still reachable.
            val defaultGroup = groups.firstOrNull { (workspace, _) ->
                workspace.isDefault || isDefaultWorkspaceTitle(workspace.title)
            }
            val grouped = groups.map { (workspace, members) ->
                workspace to (if (defaultGroup?.first?.id == workspace.id) members + ungrouped else members)
            }
            // Titles are numbered over the whole (unfiltered) list, so a search
            // never renumbers rows and a pin never changes a name.
            val titleOrder = grouped.flatMap { it.second } + (if (defaultGroup == null) ungrouped else emptyList())
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
            )

            val ungroupedRows = if (defaultGroup == null) {
                pinnedFirst(ungrouped, pinnedSessionIDs.orEmpty())
                    .filter { matches(it) }
                    .map { rowOf(it) }
            } else emptyList()
            val workspaceViews = grouped.mapIndexed { index, pair ->
                val (workspace, members) = pair
                val rows = pinnedFirst(members, pinnedSessionIDs.orEmpty())
                    .filter { matches(it) }
                    .map { rowOf(it) }
                val expanded = workspace.id !in local.collapsedWorkspaceIDs
                SessionWorkspaceView(
                    id = workspace.id,
                    title = workspaceTitle(workspace.title, index + 1, languageId),
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
            // Every input must be known, and the host facts (before search
            // filtering) must be empty. An unreported list can never prove it;
            // a query that hides real rows is a no-match state, not an empty app.
            val completelyEmpty = status == SessionListStatus.READY &&
                workspaces != null && workspaces.isEmpty() &&
                active.isEmpty() &&
                archivedSessions != null && archivedSessions.isEmpty()
            val hasAnyRow = ungroupedRows.isNotEmpty() ||
                workspaceViews.any { it.sessions.isNotEmpty() } ||
                archived.rows.isNotEmpty()
            val empty = when {
                status != SessionListStatus.READY -> SessionsEmpty.NONE
                query.isNotEmpty() && !completelyEmpty && !hasAnyRow -> SessionsEmpty.NO_MATCHES
                completelyEmpty -> SessionsEmpty.NO_SESSIONS
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
                mutationReceipt = mutationReceipt,
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
 * Layout follows `ios-sessions-{default,empty,error,many,nothing,ungrouped}.png`
 * top to bottom: an empty 44-high bar, the white search capsule, the 会话 section
 * label, the 新建会话 row with its hairline, the blocked reason, the failure line,
 * the ungrouped rows, the big empty block, one section per folder, 添加工作文件夹
 * and 已归档. Row rhythm is the baseline's: 44 for the action / folder / header
 * rows, 56 for a session row, 0.5 hairline inset by the page margin.
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
 * @param onDismissFailure legacy Android-only control: the baseline's failure row
 *   is `Text(errorText)` + 重试 and has **no** dismiss glyph
 *   (`SessionsPage.swift:176-197`), so the page no longer draws one. The
 *   parameter is kept so a host compiled against the previous page still links
 *   (its one caller is the app's `HostSessionsScreen`); the row disappears when
 *   the failed read is cleared, which is what 重试 does.
 * @param onBack leave the page. The baseline's bar is empty
 *   (`SessionsPage.swift:137`), so the band is drawn either way and only the
 *   glyph is Android's: `null` (the drawer/home presentation) leaves the band
 *   empty exactly as iOS draws it.
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
    onOpenDrawer: (() -> Unit)? = null,
    /** Whether this host can really create or mutate a workspace root. */
    workspaceActionsAvailable: Boolean = true,
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
    onArchiveSession: (SessionRowView) -> Unit = {},
    /** Pull-to-refresh (`null` leaves the gesture a no-op). */
    onRefresh: (() -> Unit)? = null,
) {
    val tokens = LocalUiTokens.current
    Box(modifier = modifier.fillMaxSize()) {
        Column(
            modifier = Modifier
                .fillMaxSize()
                // PR22 pages sit on HomeSpec's #F7F7F7 fill; row and search
                // surfaces stay white inside that page layer.
                .background(tokens.colors.page)
                .testTag(UiPageTags.SESSIONS_ROOT)
                .statusBarsPadding()
                .windowInsetsPadding(WindowInsets.safeDrawing.only(WindowInsetsSides.Horizontal)),
        ) {
            // `SessionsPage.swift:137`–`:324`: the baseline's `NavigationStack` declares
            // no title and no toolbar item, so its bar is an empty 44 pt band and the
            // search field hangs directly below it. The band is part of the page on
            // both platforms; only the back control inside it is Android's own (a
            // drawer has nothing behind it, a route does), so it is drawn only when
            // the host routes this page.
            SessionsNavBar(onBack = onBack, onOpenDrawer = onOpenDrawer)
            if (state.waiting) {
                EmptyHint(
                    title = UiStrings.WAITING_ENGINE,
                    hint = UiStrings.SESSIONS_EMPTY_HINT,
                    tag = UiPageTags.SESSIONS_EMPTY,
                )
                return@Column
            }
            // The baseline's `.searchable(navigationBarDrawer)`: a white capsule
            // pinned under the bar, above the scrolling list.
            SessionsSearchField(query = state.query, onQueryChange = onQueryChange)
            state.mutationReceipt?.let { PageMutationReceiptLine(it) }
            // The page fills the width it is given; the 320 pt drawer is the
            // *container's* number, not this page's (`NativeShell.swift:97` frames the
            // drawer at 320, and the baseline's own `sessions` state is captured in the
            // full 402 pt window). That is the one difference between the two iOS
            // empty captures: `ios-sessions-default` is the page at 402 and
            // `ios-sessions-nothing` the same page inside the 320 drawer, which is why
            // its CTA is 288 wide there and 370 wide here.
            //
            // The search capsule stays pinned; the list under it consumes the IME
            // inset so its last row can still be scrolled above the keyboard
            // (spec §5 row `insets`). The page's own `navigationBarsPadding` below
            // is the existing bottom inset; the IME inset is only added while the
            // keyboard is up, so the resting frame is unchanged.
            Box(modifier = Modifier.fillMaxWidth().weight(1f).imePadding()) {
                PullToRefreshBox(
                    isRefreshing = state.refreshInFlight,
                    onRefresh = onRefresh ?: {},
                    modifier = Modifier
                        .fillMaxSize()
                        .navigationBarsPadding()
                        .testTag(UiPageTags.SESSIONS_REFRESH),
                ) {
                    SessionsList(
                        state = state,
                        onSelect = onSelect,
                        onNewSession = onNewSession,
                        onRenameStart = onRenameStart,
                        onRetry = onRetry,
                        onToggleWorkspace = onToggleWorkspace,
                        onWorkspaceMenuToggle = onWorkspaceMenuToggle,
                        onNewSessionInWorkspace = onNewSessionInWorkspace,
                        onRenameWorkspaceStart = onRenameWorkspaceStart,
                        onDeleteWorkspaceRequest = onDeleteWorkspaceRequest,
                        onAddWorkspace = onAddWorkspace,
                        onToggleArchived = onToggleArchived,
                        onRestoreArchived = onRestoreArchived,
                        onArchiveSession = onArchiveSession,
                        workspaceActionsAvailable = workspaceActionsAvailable,
                    )
                }
            }
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

/**
 * The 44 pt band above the search field.
 *
 * The baseline's bar is empty: `NavigationStack { List { … } }` declares no
 * `navigationTitle` and no toolbar item (`SessionsPage.swift:137`, `:322`), so the
 * band is there and holds nothing. Android keeps the same band and puts the one
 * control iOS gets from the system there: the back control, drawn only when the
 * host routes the page (`onBack != null`). A drawer — the baseline's own
 * presentation — passes `null` and gets the empty band the baseline draws.
 */
@Composable
private fun SessionsNavBar(onBack: (() -> Unit)?, onOpenDrawer: (() -> Unit)?) {
    val tokens = LocalUiTokens.current
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .defaultMinSize(minHeight = tokens.geometry.pageHeaderMinHeight)
            .padding(horizontal = tokens.geometry.pageOuterMarginH),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        if (onBack != null) {
            BasicText(
                text = PAGE_BACK_GLYPH,
                style = LocalUiType.current.secondary.copy(color = tokens.colors.secondary),
                modifier = Modifier
                    .clickable(role = Role.Button, onClick = onBack)
                    .semantics { contentDescription = UiStrings.BACK }
                    .padding(tokens.spacing.iconText),
            )
        } else if (onOpenDrawer != null) {
            Box(
                modifier = Modifier
                    .size(tokens.geometry.pageHeaderMinHeight)
                    .clickable(role = Role.Button, onClick = onOpenDrawer)
                    .semantics { contentDescription = UiStrings.HEADER_DRAWER }
                    .testTag("sessions.drawer"),
                contentAlignment = Alignment.CenterStart,
            ) {
                PdshIconView(
                    icon = PdshIcon.MENU,
                    size = DRAWER_GLYPH_WIDTH_PT.dp,
                    tint = tokens.colors.secondary,
                    contentDescription = null,
                )
            }
        }
    }
}

/**
 * The search capsule: white fill, a hairline edge and the capsule radius.
 *
 * The baseline's field is 369.7 x 40 with a `magnifyingglass` at x 33.3 and the
 * placeholder at x 56.7. Android has no icon set and the spec declares no
 * magnifier, so the field carries the placeholder only, starting at the capsule's
 * own inset; the geometry of the capsule itself (full page width minus the page
 * margin, capsule radius, 17 pt placeholder) is the baseline's.
 */
@Composable
private fun SessionsSearchField(query: String, onQueryChange: (String) -> Unit) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    // Capsule: L6 fitted the baseline's top corner to r = 22 pt = height / 2.
    val shape = RoundedCornerShape(SessionsMetrics.searchRadius)
    Box(
        modifier = Modifier
            .fillMaxWidth()
            .padding(
                horizontal = tokens.geometry.pageOuterMarginH,
                vertical = tokens.geometry.cardOuterMarginV,
            )
            .defaultMinSize(minHeight = SessionsMetrics.searchHeight)
            .clip(shape)
            .background(tokens.colors.input)
            // The baseline draws a soft shadow instead of a border; the lightest
            // declared stroke is the only border the token table can express.
            .border(tokens.stroke.hairline, tokens.colors.borderLight, shape)
            .padding(horizontal = tokens.spacing.cardInset)
            .testTag(UiPageTags.SESSIONS_SEARCH),
        contentAlignment = Alignment.CenterStart,
    ) {
        Row(
            modifier = Modifier.fillMaxWidth(),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(SESSIONS_SEARCH_GLYPH_GAP_PT.dp),
        ) {
            SessionsSearchGlyph(ink = tokens.colors.secondary)
        BasicTextField(
            value = query,
            onValueChange = onQueryChange,
            singleLine = true,
            textStyle = type.headline.copy(
                fontWeight = FontWeight.Normal,
                color = tokens.colors.primary,
            ),
            cursorBrush = SolidColor(tokens.colors.accent),
            keyboardOptions = KeyboardOptions(imeAction = ImeAction.Search),
            modifier = Modifier.weight(1f).semantics {
                contentDescription = UiStrings.SESSION_SEARCH
            },
            decorationBox = { inner ->
                if (query.isEmpty()) {
                    BasicText(
                        text = UiStrings.SESSION_SEARCH,
                        style = type.headline.copy(
                            fontWeight = FontWeight.Normal,
                            color = tokens.colors.secondary,
                        ),
                    )
                }
                inner()
            },
        )
        }
    }
}

/** A visible search result state; the typed query remains in the field for correction. */
@Composable
private fun NoSessionMatchesBlock(query: String) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .testTag(SESSION_SEARCH_NO_RESULTS_TAG)
            .padding(
                horizontal = tokens.geometry.pageOuterMarginH,
                vertical = tokens.spacing.cardInset,
            )
            .semantics { liveRegion = LiveRegionMode.Polite },
        verticalArrangement = Arrangement.spacedBy(tokens.spacing.badgeInsetV),
    ) {
        BasicText(
            text = "没有结果",
            style = type.body.copy(color = tokens.colors.textPrimary, fontWeight = FontWeight.SemiBold),
        )
        BasicText(
            text = "没有找到与“${query.trim()}”匹配的会话。",
            style = type.secondary.copy(color = tokens.colors.textSecondary),
        )
    }
}

/** Renders only a typed result supplied by the host; dispatching a write is not a receipt. */
@Composable
internal fun PageMutationReceiptLine(receipt: PageMutationReceipt) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    BasicText(
        text = receipt.message,
        style = type.secondary.copy(
            color = if (receipt.outcome == PageMutationOutcome.FAILED) {
                tokens.colors.danger
            } else {
                tokens.colors.textSecondary
            },
        ),
        modifier = Modifier
            .fillMaxWidth()
            .testTag(PAGE_MUTATION_RECEIPT_TAG)
            .padding(
                horizontal = tokens.geometry.pageOuterMarginH,
                vertical = tokens.spacing.badgeInsetV,
            )
            .semantics {
                liveRegion = if (receipt.outcome == PageMutationOutcome.FAILED) {
                    LiveRegionMode.Assertive
                } else {
                    LiveRegionMode.Polite
                }
            },
    )
}

/** The iOS search field's 16 pt `magnifyingglass` symbol. */
@Composable
private fun SessionsSearchGlyph(ink: Color) {
    PdshIconView(
        icon = PdshIcon.SEARCH,
        size = SESSIONS_SEARCH_GLYPH_SIZE_PT.dp,
        tint = ink,
        contentDescription = null,
    )
}

/** The drawer's scrollable body, in the baseline's order. */
@Composable
private fun SessionsList(
    state: SessionsScreenState,
    onSelect: (SessionRowView) -> Unit,
    onNewSession: () -> Unit,
    onRenameStart: (SessionRowView) -> Unit,
    onRetry: (() -> Unit)?,
    onToggleWorkspace: (SessionWorkspaceView) -> Unit,
    onWorkspaceMenuToggle: (SessionWorkspaceView) -> Unit,
    onNewSessionInWorkspace: (SessionWorkspaceView) -> Unit,
    onRenameWorkspaceStart: (SessionWorkspaceView) -> Unit,
    onDeleteWorkspaceRequest: (SessionWorkspaceView) -> Unit,
    onAddWorkspace: () -> Unit,
    onToggleArchived: () -> Unit,
    onRestoreArchived: (ArchivedRowView) -> Unit,
    onArchiveSession: (SessionRowView) -> Unit,
    workspaceActionsAvailable: Boolean,
) {
    val tokens = LocalUiTokens.current
    LazyColumn(
        modifier = Modifier.fillMaxSize().testTag(UiPageTags.SESSIONS_LIST),
    ) {
        // The baseline's plain list starts with the 新建会话 row and gives it a
        // row of air above; the group at `SessionsPage.swift:139` is untitled, so
        // the air stays and no header is invented for it.
        item(key = "section-air") {
            Box(modifier = Modifier.fillMaxWidth().height(SESSIONS_SEARCH_TO_NEW_AIR_PT.dp))
        }

        // Section 1: new session, its blocked reason, the failure line and
        // the sessions that belong to no folder.
        item(key = "new-session") {
            Column {
                Box {
                    NewSessionRow(
                        block = state.newSessionBlock,
                        onNewSession = onNewSession,
                    )
                    // `SessionsPage.swift:153-158`: an overlay, `.bottom`, 288 wide, so
                    // it is centred in the row's content box and costs no height.
                    SessionSeparator(Modifier.align(Alignment.BottomCenter))
                }
                if (state.newSessionBlock != null) {
                    BasicText(
                        text = state.newSessionBlock.reason,
                        style = LocalUiType.current.secondary.copy(
                            color = LocalUiTokens.current.colors.secondary,
                        ),
                        modifier = Modifier
                            .fillMaxWidth()
                            .testTag(UiPageTags.SESSIONS_NEW_SESSION_BLOCKED)
                            .padding(
                                start = LocalUiTokens.current.geometry.pageOuterMarginH,
                                // unverified geometry: the baseline leaves ~26 pt
                                // between the hairline and this sentence; the
                                // section gap token is the closest published inset.
                                top = SESSIONS_BLOCK_REASON_TOP_PT.dp,
                                end = LocalUiTokens.current.geometry.pageOuterMarginH,
                                bottom = LocalUiTokens.current.spacing.badgeInsetV,
                            ),
                    )
                }
                if (state.failure != null) {
                    SessionsFailureLine(message = state.failure, onRetry = onRetry)
                }
            }
        }
        items(items = state.rows, key = { "ungrouped-${it.id}" }) { row ->
            SessionItem(
                row = row,
                onSelect = onSelect,
                onRenameStart = onRenameStart,
                onArchiveSession = onArchiveSession,
            )
        }

        // Section 2: the completely-empty drawer. A query that hides real host
        // rows has its own explicit no-match item instead of claiming this app
        // has no sessions.
        if (state.completelyEmpty && state.empty != SessionsEmpty.NO_MATCHES) {
            item(key = "empty-drawer") {
                CompletelyEmptyBlock(
                    onCreateWorkspace = onAddWorkspace,
                    showCreateAction = workspaceActionsAvailable,
                )
            }
        }

        if (state.empty == SessionsEmpty.NO_MATCHES) {
            item(key = "search-no-matches") {
                NoSessionMatchesBlock(query = state.query)
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

        // Section 3: one section per workspace folder. `SessionsPage.swift:265-290`
        // is a folder-style Section: the header row folds the folder's sessions in
        // and out as one group, so the shared drawer folder disclosure owns the
        // body motion (§7 rule 2, `motion.folderCollapse`) and the chevron rotates
        // through [PdshChevron]. The ⋯ control remains a page `Menu`, not a §3
        // context-menu surface.
        state.workspaces.forEach { workspace ->
            item(key = "workspace-${workspace.id}") {
                PdshFolderGroup(
                    expanded = workspace.expanded,
                    onToggle = { onToggleWorkspace(workspace) },
                    tag = sessionsWorkspaceDisclosureTag(workspace.id),
                    anchorKey = workspace.id,
                    modifier = Modifier.padding(top = SESSIONS_WORKSPACE_SECTION_GAP_PT.dp),
                    header = {
                        WorkspaceRow(
                            workspace = workspace,
                            onMenuToggle = onWorkspaceMenuToggle,
                            onNewSession = onNewSessionInWorkspace,
                            onRename = onRenameWorkspaceStart,
                            onDelete = onDeleteWorkspaceRequest,
                            showMenu = workspaceActionsAvailable,
                        )
                    },
                    body = {
                        if (workspace.empty) {
                            Column {
                                WorkspaceSessionsEmpty()
                                // The baseline's empty copy carries no
                                // `.listRowSeparator(.hidden)` (`SessionsPage.swift:246-256`),
                                // so the platform draws that row's separator (16 → 304 in the
                                // drawer the state is captured in, `ios-sessions-empty.png`
                                // y 438). It stays an overlay, like every other line here.
                                Box {
                                    SessionSeparator(Modifier.align(Alignment.BottomStart).padding(start = SessionsMetrics.SEPARATOR_INSET_PT.dp))
                                }
                            }
                        } else {
                            Column {
                                workspace.sessions.forEach { row ->
                                    SessionItem(
                                        row = row,
                                        onSelect = onSelect,
                                        onRenameStart = onRenameStart,
                                        onArchiveSession = onArchiveSession,
                                    )
                                }
                            }
                        }
                    },
                )
            }
        }

        // Section 4: add a workspace. The completely-empty block already
        // owns the entry point, so the row is hidden in that state.
        if ((!state.completelyEmpty || state.empty == SessionsEmpty.NO_MATCHES) && workspaceActionsAvailable) {
            item(key = "add-workspace") {
                AddWorkspaceRow(onAddWorkspace = onAddWorkspace)
            }
        }

        // Section 5: archived sessions. Hidden together with Section 4
        // while the drawer is completely empty.
        if (!state.completelyEmpty || state.empty == SessionsEmpty.NO_MATCHES) {
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
 * One hand-drawn separator, the baseline's own shape.
 *
 * `SessionsPage.swift:157` and `:596` both hard-code `.frame(width: 288, height:
 * 0.5)`, so the line is *288 wide regardless of the page width* — it is not a
 * full-bleed rule with a 16 pt inset. The two call sites differ only in the
 * overlay's alignment: the new-session row centres it (`.bottom`) and a session
 * row pins it to the row's leading edge (`.bottomLeading`, i.e. x 16 after the
 * row inset). Both are overlays, so neither takes layout height.
 */
@Composable
private fun SessionSeparator(modifier: Modifier = Modifier) {
    val tokens = LocalUiTokens.current
    Box(
        modifier = modifier
            .width(SessionsMetrics.SEPARATOR_WIDTH_PT.dp)
            .height(tokens.stroke.hairline)
            .background(tokens.colors.border),
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
            .padding(horizontal = tokens.geometry.pageOuterMarginH),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(tokens.spacing.badgeInsetH),
    ) {
        BasicText(
            text = PLUS_GLYPH,
            style = type.headline.copy(fontWeight = FontWeight.Normal, color = ink),
        )
        BasicText(
            text = UiStrings.SESSION_NEW,
            style = type.headline.copy(fontWeight = FontWeight.Normal, color = ink),
            modifier = Modifier.weight(1f),
        )
    }
}

/**
 * The fail-loud line of a failed list read: the host's own message in the
 * danger ink, with 重试 at the trailing edge (the baseline's 44 pt row).
 */
@Composable
private fun SessionsFailureLine(
    message: String,
    onRetry: (() -> Unit)?,
) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .testTag(UiPageTags.SESSIONS_FAILURE)
            // Fail-loud is audible too: an assertive live region interrupts.
            .semantics { liveRegion = LiveRegionMode.Assertive }
            .defaultMinSize(minHeight = tokens.geometry.pageRowMinHeight)
            .padding(
                horizontal = tokens.geometry.pageOuterMarginH,
                vertical = tokens.spacing.badgeInsetV,
            ),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(tokens.spacing.cardInset),
    ) {
        BasicText(
            text = message,
            style = type.secondary.copy(color = tokens.colors.danger),
            maxLines = 2,
            overflow = TextOverflow.Ellipsis,
            modifier = Modifier.weight(1f),
        )
        if (onRetry != null) {
            BasicText(
                text = UiStrings.RETRY,
                style = type.headline.copy(
                    fontWeight = FontWeight.Normal,
                    color = tokens.colors.accent,
                ),
                modifier = Modifier
                    .clickable(role = Role.Button, onClick = onRetry)
                    .padding(tokens.spacing.iconText),
            )
        }
    }
}

/**
 * One session row, its long-press menu and the current check mark.
 *
 * The standalone baseline's row: `bubble.left` 15pt ink in a 17pt box, a 16pt
 * title, 13pt relative-time metadata, a 56pt row floor, and a 288pt hairline
 * pinned to the row's leading edge as an *overlay*.
 *
 * Two things the overlay placement changes, both measured on `ios-sessions-many`:
 * the row stays exactly 56pt tall, and the line sits on the boundary.
 *
 * The long-press surface is [PdshContextMenu] with the frozen `sessionsRow`
 * table (`SessionsPage.swift:612-616`): 重命名会话 then 归档会话, both `always`.
 * The row's normal tap still selects it. The 0.15 s press fill is the page's own
 * source-owned feedback (`SessionsPage.swift:641-654`), not the shared §6
 * pressed-state recipe, so it stays page-local and is driven from a non-consuming
 * Initial-pass pointer observer while the shared wrapper owns the click gesture.
 */
@Composable
private fun SessionItem(
    row: SessionRowView,
    onSelect: (SessionRowView) -> Unit,
    onRenameStart: (SessionRowView) -> Unit,
    onArchiveSession: (SessionRowView) -> Unit,
) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    var pressed by remember { mutableStateOf(false) }
    val onPressChange = rememberUpdatedState<(Boolean) -> Unit> { pressed = it }
    val pressFill by animateFloatAsState(
        targetValue = if (pressed) 1f else 0f,
        animationSpec = tween(durationMillis = ROW_PRESS_MS, easing = ROW_PRESS_EASING),
        label = "session-row-press",
    )
    Box(modifier = Modifier.fillMaxWidth()) {
        val rowShape = RoundedCornerShape(SessionsMetrics.SESSION_ROW_PRESS_RADIUS_PT.dp)
        PdshContextMenu(
            surfaceId = SESSIONS_ROW_SURFACE,
            state = ContextMenuRowState.unconditional,
            onAction = { item ->
                // Token order in `interaction.contextMenu.surfaces[sessionsRow]`.
                when (item.order) {
                    0 -> onRenameStart(row)
                    1 -> onArchiveSession(row)
                }
            },
            onClick = { onSelect(row) },
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = tokens.geometry.pageOuterMarginH)
                .clip(rowShape)
                .testTag(UiPageTags.SESSION_ROW)
                .background(
                    color = tokens.colors.selector.copy(alpha = pressFill),
                    shape = rowShape,
                )
                // The shared wrapper owns click/long-press. Observe the down/up
                // on the Initial pass without consuming so the 0.15 s fill still
                // tracks the finger exactly as the baseline's ButtonStyle did.
                .pointerInput(Unit) {
                    awaitEachGesture {
                        awaitFirstDown(
                            requireUnconsumed = false,
                            pass = PointerEventPass.Initial,
                        )
                        onPressChange.value(true)
                        try {
                            waitForUpOrCancellation(pass = PointerEventPass.Initial)
                        } finally {
                            onPressChange.value(false)
                        }
                    }
                },
        ) {
            Row(
                modifier = Modifier
                    // Source floor is 56 pt; the 16 pt card inset plus 8 pt content
                    // inset puts the glyph at the same 24 pt baseline position.
                    .heightIn(min = SessionsMetrics.standaloneSessionRowHeight)
                    .padding(horizontal = SessionsMetrics.SESSION_ROW_INNER_INSET_PT.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(SessionsMetrics.SESSION_GLYPH_GAP_PT.dp),
            ) {
                SessionRowGlyph(ink = tokens.colors.secondary)
                Column(
                    modifier = Modifier.weight(1f),
                    verticalArrangement = Arrangement.spacedBy(SessionsMetrics.SESSION_TEXT_GAP_PT.dp),
                ) {
                    BasicText(
                        text = row.title,
                        style = type.body.copy(
                            fontWeight = FontWeight.Normal,
                            color = tokens.colors.textPrimary,
                            platformStyle = PlatformTextStyle(includeFontPadding = false),
                        ),
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                    Row(
                        horizontalArrangement = Arrangement.spacedBy(SessionsMetrics.SESSION_METADATA_GAP_PT.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        if (row.timeLabel != null) {
                            BasicText(
                                text = row.timeLabel,
                                style = type.caption.copy(
                                    color = tokens.colors.textSecondary,
                                    fontSize = SessionsMetrics.SESSION_METADATA_SIZE_PT.sp,
                                    platformStyle = PlatformTextStyle(includeFontPadding = false),
                                ),
                            )
                        }
                        // The baseline shows one run indicator only: a grey dot and
                        // 运行中. A failure is not a row state there, so it is not
                        // invented here.
                        if (row.status == SessionRunStatus.RUNNING) {
                            BasicText(
                                text = SEPARATOR_GLYPH,
                                style = type.caption.copy(color = tokens.colors.textSecondary, fontSize = SessionsMetrics.SESSION_METADATA_SIZE_PT.sp),
                            )
                            Row(
                                verticalAlignment = Alignment.CenterVertically,
                                horizontalArrangement = Arrangement.spacedBy(SessionsMetrics.SESSION_STATUS_DOT_GAP_PT.dp),
                            ) {
                                Box(
                                    modifier = Modifier
                                        .size(SessionsMetrics.SESSION_RUNNING_DOT_PT.dp)
                                        .clip(CircleShape)
                                        .background(tokens.colors.textSecondary),
                                )
                                BasicText(
                                    text = UiStrings.RUNNING,
                                    style = type.caption.copy(color = tokens.colors.textSecondary, fontSize = SessionsMetrics.SESSION_METADATA_SIZE_PT.sp),
                                )
                            }
                        }
                    }
                }
                if (row.selected) {
                    // `SessionsPage.swift:572`: `Spacer(minLength: 4)` between the
                    // title block and the check, on top of the 10 pt row gap.
                    Box(modifier = Modifier.width(SessionsMetrics.SESSION_SELECTED_CHECK_GAP_PT.dp))
                    BasicText(
                        text = CHECK_GLYPH,
                        style = type.body.copy(
                            fontSize = SessionsMetrics.SESSION_SELECTED_CHECK_SIZE_PT.sp,
                            fontWeight = FontWeight.Normal,
                            color = tokens.colors.primary,
                        ),
                        modifier = Modifier
                            .testTag(UiPageTags.SESSIONS_SESSION_CURRENT)
                            .semantics { contentDescription = UiStrings.SESSIONS_CURRENT },
                    )
                }
            }
        }
        // `SessionsPage.swift:592-597`: `.overlay(alignment: .bottomLeading)`.
        SessionSeparator(
            Modifier
                .align(Alignment.BottomStart)
                .padding(start = SessionsMetrics.SEPARATOR_INSET_PT.dp),
        )
    }
}

/** The completely-empty drawer: title, one sentence and the full-width CTA. */
@Composable
private fun CompletelyEmptyBlock(onCreateWorkspace: () -> Unit, showCreateAction: Boolean) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .testTag(UiPageTags.SESSIONS_SECTION_EMPTY)
            // `SessionsPage.swift:207-232`: the block itself adds only 8 pt below
            // (`.padding(.bottom, 8)`); the air above it belongs to the list.
            .padding(
                start = tokens.geometry.pageOuterMarginH,
                end = tokens.geometry.pageOuterMarginH,
                top = SESSIONS_EMPTY_TOP_PT.dp,
                bottom = SessionsMetrics.EMPTY_STATE_BOTTOM_PT.dp,
            )
            .semantics(mergeDescendants = true) {},
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(SESSIONS_EMPTY_STACK_GAP_PT.dp),
    ) {
        BasicText(
            text = UiStrings.WORKSPACE_EMPTY,
            // `.font(.system(size: 17, weight: .semibold))` + `.multilineTextAlignment(.center)`
            style = type.headline.copy(color = tokens.colors.primary, textAlign = TextAlign.Center),
        )
        BasicText(
            text = UiStrings.SESSIONS_EMPTY_WORKSPACE_HINT,
            style = type.secondary.copy(color = tokens.colors.secondary, textAlign = TextAlign.Center),
            modifier = Modifier.fillMaxWidth(),
        )
        if (showCreateAction) Box(
            modifier = Modifier
                .fillMaxWidth()
                .padding(top = SESSIONS_EMPTY_CTA_TOP_PT.dp)
                .clip(RoundedCornerShape(SessionsMetrics.ctaRadius))
                // The baseline's CTA fill is the page-layer blue
                // (`NativePagePalette.accentFill` #2F5BFF), not the theme accent
                // and not the approval card's ctaOverride: measured
                // ios-sessions-nothing.png CTA = #2F5BFF.
                .background(tokens.colors.pageAccent)
                .defaultMinSize(minHeight = SessionsMetrics.ctaHeight)
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
                style = type.headline.copy(color = tokens.colors.onAccent),
            )
        }
    }
}

/** One folder row: chevron, name, the filtered count and its page `Menu`. */
@Composable
private fun WorkspaceRow(
    workspace: SessionWorkspaceView,
    onMenuToggle: (SessionWorkspaceView) -> Unit,
    onNewSession: (SessionWorkspaceView) -> Unit,
    onRename: (SessionWorkspaceView) -> Unit,
    onDelete: (SessionWorkspaceView) -> Unit,
    showMenu: Boolean = true,
) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .defaultMinSize(minHeight = SessionsMetrics.workspaceRowHeight)
            .padding(horizontal = tokens.geometry.pageOuterMarginH),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        // `SessionsPage.swift:449-462`: the folder is one row; the disclosure
        // header owns the whole row's tap, and this child only carries the label.
        Row(
            modifier = Modifier
                .weight(1f)
                .testTag(UiPageTags.SESSIONS_WORKSPACE_ROW)
                .semantics {
                    contentDescription = UiStrings.SESSIONS_WORKSPACE_A11Y
                        .format(workspace.title, workspace.sessionCount)
                },
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.Start,
        ) {
            // `SessionsPage.swift:453`: 12 pt `chevron.right`; §7 rule 3's shared
            // chevron owns the 0→90° rotation and keeps the slot's size.
            PdshChevron(
                expanded = workspace.expanded,
                modifier = Modifier.width(SessionsMetrics.WORKSPACE_CHEVRON_SLOT_PT.dp),
                size = SessionsMetrics.WORKSPACE_CHEVRON_SLOT_PT.dp,
                tint = tokens.colors.textSecondary,
                tag = sessionsWorkspaceChevronTag(workspace.id),
            )
            BasicText(
                text = workspace.title,
                style = type.headline.copy(color = tokens.colors.primary),
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier.padding(start = SessionsMetrics.WORKSPACE_TITLE_GAP_PT.dp),
            )
            if (workspace.sessionCount > 0) {
                BasicText(
                    text = UiStrings.SESSIONS_WORKSPACE_COUNT.format(workspace.sessionCount),
                    style = type.secondary.copy(color = tokens.colors.secondary),
                    modifier = Modifier.padding(start = SessionsMetrics.WORKSPACE_COUNT_GAP_PT.dp),
                )
            }
        }
        if (showMenu) Box {
            // The baseline's hit box is 32 x 44 with the mark centred in it
            // (`SessionsPage.swift:451-457`). This is the page's own overflow
            // `Menu`, not one of the eleven §3 `.contextMenu` surfaces.
            Box(
                modifier = Modifier
                    .testTag(UiPageTags.SESSIONS_WORKSPACE_MENU)
                    .clickable(role = Role.Button, onClick = { onMenuToggle(workspace) })
                    .width(SessionsMetrics.WORKSPACE_MENU_WIDTH_PT.dp)
                    .defaultMinSize(minHeight = SessionsMetrics.workspaceRowHeight)
                    .semantics {
                        contentDescription =
                            UiStrings.SESSIONS_WORKSPACE_OPTIONS.format(workspace.title)
                    },
                contentAlignment = Alignment.Center,
            ) {
                WorkspaceMenuGlyph(ink = tokens.colors.secondary)
            }
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

/**
 * The folder row's overflow mark: the baseline's `Image(systemName: "ellipsis")`
 * at 20 pt (`SessionsPage.swift:452-453`).
 *
 * SF's ellipsis draws three round dots 4 pt across, 18.3 pt end to end
 * (`ios-sessions-empty.png`: ink x 279.0-297.0, y 305.0-308.7). U+2026 "…" in the
 * system font measures 9.3 x 2.3 pt on the same row — half the width and half the
 * height — because it is a text ellipsis, not the symbol. `:lib` ships no icon
 * set, so the three dots are drawn here at the measured size; nothing outside
 * this composable depends on the drawing.
 */
@Composable
private fun WorkspaceMenuGlyph(ink: Color) {
    PdshIconView(
        icon = PdshIcon.MORE,
        size = WORKSPACE_MENU_GLYPH_W_PT.dp,
        tint = ink,
        contentDescription = null,
    )
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
                // unverified geometry: the baseline's 24 pt lead-in is the spec's
                // compact-list row floor; no gap token publishes 24.
                start = tokens.geometry.pageOuterMarginH,
                top = WORKSPACE_SESSIONS_EMPTY_TOP_PT.dp,
                end = tokens.geometry.pageOuterMarginH,
                bottom = tokens.geometry.cardOuterMarginV,
            )
            .semantics(mergeDescendants = true) {},
        verticalArrangement = Arrangement.spacedBy(tokens.spacing.codeToolbar),
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
            .padding(horizontal = SESSIONS_ADD_WORKSPACE_INSET_PT.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(tokens.spacing.badgeInsetH),
    ) {
        BasicText(
            text = PLUS_GLYPH,
            style = type.headline.copy(
                fontWeight = FontWeight.Normal,
                color = tokens.colors.accent,
            ),
        )
        BasicText(
            text = UiStrings.SESSIONS_ADD_WORKSPACE,
            style = type.headline.copy(
                fontWeight = FontWeight.Normal,
                color = tokens.colors.accent,
            ),
            modifier = Modifier.weight(1f),
        )
    }
}

/** The 已归档 header: the baseline's fold header with the host's count. */
@Composable
private fun ArchivedHeader(state: SessionsScreenState, onToggle: () -> Unit) {
    // `SessionsPage.swift:303`–`:317` is a `Section` whose header is a Button: the
    // chevron, the fixed 已归档 title and the count. The shared collapsible header
    // is that shape, and it keeps the title literal so the page contract can read
    // it (`SectionHeader(title = …)` also counts as the header's tap action).
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
                vertical = tokens.spacing.cardInset,
            )
            .semantics(mergeDescendants = true) {},
        verticalArrangement = Arrangement.spacedBy(tokens.spacing.codeToolbar),
    ) {
        BasicText(
            text = UiStrings.SESSIONS_ARCHIVED_EMPTY,
            style = type.headline.copy(
                fontWeight = FontWeight.Normal,
                color = tokens.colors.primary,
            ),
        )
        BasicText(
            text = UiStrings.SESSIONS_ARCHIVED_EMPTY_HINT,
            style = type.secondary.copy(color = tokens.colors.secondary),
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
                style = type.headline.copy(
                    fontWeight = FontWeight.Normal,
                    color = tokens.colors.primary,
                ),
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
    val palette = materialDialogColors(tokens)
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
        containerColor = palette.container,
        textContentColor = palette.content,
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
        UiTokenNames.COLORS_ACCENT,
        UiTokenNames.COLORS_BORDER,
        UiTokenNames.COLORS_BORDER_LIGHT,
        UiTokenNames.COLORS_PAGE_ACCENT,
        UiTokenNames.COLORS_DANGER,
        UiTokenNames.COLORS_INPUT,
        UiTokenNames.COLORS_ON_ACCENT,
        UiTokenNames.COLORS_PAGE,
        UiTokenNames.COLORS_PRIMARY,
        UiTokenNames.COLORS_SECONDARY,
        UiTokenNames.COLORS_SELECTOR,
        UiTokenNames.COLORS_TERTIARY,
        UiTokenNames.COLORS_TEXT_PRIMARY,
        UiTokenNames.COLORS_TEXT_SECONDARY,
        UiTokenNames.GEOMETRY_CARD_OUTER_MARGIN_V,
        UiTokenNames.GEOMETRY_PAGE_HEADER_MIN_HEIGHT,
        UiTokenNames.GEOMETRY_PAGE_OUTER_MARGIN_H,
        UiTokenNames.GEOMETRY_PAGE_ROW_MIN_HEIGHT,
        UiTokenNames.SPACING_BADGE_INSET_H,
        UiTokenNames.SPACING_BADGE_INSET_V,
        UiTokenNames.SPACING_CARD_INSET,
        UiTokenNames.SPACING_CODE_TOOLBAR,
        UiTokenNames.SPACING_ICON_TEXT,
        UiTokenNames.STROKE_HAIRLINE,
        UiTokenNames.TYPOGRAPHY_BODY,
        UiTokenNames.TYPOGRAPHY_CAPTION,
        UiTokenNames.TYPOGRAPHY_HEADLINE,
        UiTokenNames.TYPOGRAPHY_SECONDARY,
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
 * a default/blank name becomes 手机工作区 / Phone Workspace (numbered from the
 * second folder), a path-like name keeps only its last segment, and an empty
 * segment falls back to 未命名文件夹.
 */
internal fun isDefaultWorkspaceTitle(raw: String): Boolean {
    val trimmed = raw.trim()
    return trimmed.isEmpty() || trimmed.lowercase() in DEFAULT_WORKSPACE_TITLES
}

internal fun workspaceTitle(raw: String, index: Int, languageId: String? = null): String {
    val trimmed = raw.trim()
    if (isDefaultWorkspaceTitle(trimmed)) {
        val chinese = if (index > 1) {
            UiStrings.DRAWER_DEFAULT_FOLDER_INDEXED.format(index)
        } else {
            UiStrings.DRAWER_DEFAULT_FOLDER
        }
        val english = if (index > 1) {
            UiStrings.DRAWER_DEFAULT_FOLDER_INDEXED_EN.format(index)
        } else {
            UiStrings.DRAWER_DEFAULT_FOLDER_EN
        }
        return if (languageId == null) chinese else UiStrings.settingsNativeText(languageId, chinese, english)
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
    setOf("workspace", "工作区", "工作文件夹", "default", "default-workspace", "日常", "手机工作区", "phone workspace")

private const val WORKSPACE_NAME_LIMIT: Int = 12
private const val MINUTE_MS: Long = 60_000
private const val HOUR_MS: Long = 3_600_000
private const val DAY_MS: Long = 86_400_000

/** The glyphs the drawer draws; the baseline's SF Symbols have no Compose peer. */
private const val PLUS_GLYPH: String = "+"
private const val CHECK_GLYPH: String = "✓"
private const val SEPARATOR_GLYPH: String = "·"

private const val ELLIPSIS: String = "…"

/** The frozen §3 surface for a session row (`SessionsPage.swift:612`). */
private const val SESSIONS_ROW_SURFACE: String = "sessionsRow"

/** Stable disclosure/chevron tags for one workspace folder; new nodes only. */
internal fun sessionsWorkspaceDisclosureTag(workspaceId: String): String =
    "pdsh.sessions.workspace.$workspaceId"

internal fun sessionsWorkspaceChevronTag(workspaceId: String): String =
    "${sessionsWorkspaceDisclosureTag(workspaceId)}.chevron"

/**
 * The session row's registered `bubble.left` icon, secondary ink.
 */
@Composable
private fun SessionRowGlyph(ink: Color) {
    Box(
        modifier = Modifier.size(SessionsMetrics.SESSION_GLYPH_BOX_PT.dp),
        contentAlignment = Alignment.Center,
    ) {
        PdshIconView(
            icon = PdshIcon.CHAT_BUBBLE,
            size = SessionsMetrics.SESSION_GLYPH_SIZE_PT.dp,
            tint = ink,
            contentDescription = null,
        )
    }
}

/**
 * The ellipsis ink: three 4 pt dots 18.3 pt end to end
 * (`SessionsPage.swift:452-453`, measured on `ios-sessions-empty.png`).
 */
private const val WORKSPACE_MENU_GLYPH_W_PT: Float = 18.3f

/** The baseline's row gap before the check mark: `Spacer(minLength: 4)` (`:572`). */
/** 402 pt capture: the new-session title was 12.4 pt too low after the search field. */
private const val SESSIONS_SEARCH_TO_NEW_AIR_PT: Float = 31.6f
/** 402 pt capture: restore the measured ~26.7 pt separator-to-blocked-copy gap. */
private const val SESSIONS_BLOCK_REASON_TOP_PT: Float = 26.7f
/** SwiftUI List's measured section lead-in before each workspace row. */
private const val SESSIONS_WORKSPACE_SECTION_GAP_PT: Float = 13.4f
/** Title alignment after the upstream list-air correction. */
private const val SESSIONS_EMPTY_TOP_PT: Float = 24f
/** Compensates for Android's 3.3 pt taller title-to-hint ink gap. */
private const val SESSIONS_EMPTY_STACK_GAP_PT: Float = 4.7f
/** Measured CTA top offset after title/hint line-box differences. */
private const val SESSIONS_EMPTY_CTA_TOP_PT: Float = 13.4f
/** iOS's default section/list spacing before the expanded-folder empty copy. */
private const val WORKSPACE_SESSIONS_EMPTY_TOP_PT: Float = 61.3f
/** iOS inset for the add-workspace section row. */
private const val SESSIONS_ADD_WORKSPACE_INSET_PT: Float = 32.7f
private const val SESSIONS_SEARCH_GLYPH_SIZE_PT: Float = 16f
private const val SESSIONS_SEARCH_GLYPH_GAP_PT: Float = 6.4f
internal const val SESSION_SEARCH_NO_RESULTS_TAG: String = "pdsh.sessions.search.no-results"
internal const val PAGE_MUTATION_RECEIPT_TAG: String = "pdsh.page.mutation-receipt"
private const val DRAWER_GLYPH_WIDTH_PT: Int = 20

/** The row's pressed fill: `.easeIn(duration: 0.15)` (`SessionsPage.swift:652`). */
private const val ROW_PRESS_MS: Int = 150
private val ROW_PRESS_EASING: CubicBezierEasing = CubicBezierEasing(0.42f, 0f, 1f, 1f)
