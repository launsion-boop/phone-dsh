// The host's screen around the sessions page: the drawer's 会话 body.
// SPDX-License-Identifier: MIT
//
// The page itself is a pure function of (host facts, local UI events). This file
// owns only the second half: the search query, the folds, the open menus and the
// inline editors, exactly the view-local decisions `spec/ui/v1/README.md` §3.1
// leaves to the caller. The facts come from `buildSessionsFacts`; nothing here
// reads the engine's session state, the clock or the filesystem.
//
// Session rows come from the journal and the App's durable chat store. The typed
// helpers in this file and HostWorkspaces.kt let the composition root issue
// archive/restore/rename and workspace mutations against that store; compatibility
// UI callbacks remain in the ViewModel until the root routes commands through the
// new contract.
// The session refresh itself remains [ProbeEngineViewModel.refreshSessions].
package com.phonedsh.probe

import android.util.Log
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.statusBars
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicText
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.TextStyle
import com.phonedsh.engine.EngineState
import com.phonedsh.ui.UiStrings
import com.phonedsh.ui.page.ArchivedRowView
import com.phonedsh.ui.page.SessionRowView
import com.phonedsh.ui.page.SessionWorkspaceView
import com.phonedsh.ui.page.SessionsLocalState
import com.phonedsh.ui.page.SessionsPage
import com.phonedsh.ui.theme.PdshThemeValues
import com.phonedsh.ui.nav.PdshActionOutcome
import com.phonedsh.ui.nav.PdshActionReceipt
import com.phonedsh.ui.nav.PdshUiHostCommand
import com.phonedsh.ui.state.StateRequestId
import com.phonedsh.ui.state.StateRevision
import java.time.ZoneId

/**
 * Runs a session metadata command against the same durable store used by the
 * session list. A receipt is successful only when ChatSessionStore has committed
 * the change and read it back; the legacy ViewModel Boolean reports enqueue/guard
 * acceptance and is not a persistence receipt.
 */
internal fun applyHostSessionCommand(
    store: ChatSessionStore,
    command: PdshUiHostCommand,
): PdshActionReceipt? {
    val receipt = when (command) {
        is PdshUiHostCommand.SessionRename -> {
            if (command.title.isBlank()) return PdshActionReceipt(
                command.requestId, command.sessionId, null, PdshActionOutcome.FAILED,
            )
            store.rename(command.sessionId, command.title, command.requestId)
        }
        is PdshUiHostCommand.SessionArchive -> store.setArchived(command.sessionId, true, command.requestId)
        is PdshUiHostCommand.SessionRestore -> store.setArchived(command.sessionId, false, command.requestId)
        else -> return null
    }
    return PdshActionReceipt(
        requestId = receipt.requestId,
        sessionId = receipt.sessionId,
        revision = receipt.revision,
        outcome = if (receipt.outcome is ChatWriteOutcome.Persisted) {
            PdshActionOutcome.SUCCEEDED
        } else {
            PdshActionOutcome.FAILED
        },
    )
}

/** Persists one new session into the requested real folder group and reads it back. */
internal fun createHostChatSession(
    store: ChatSessionStore,
    sessionId: String,
    updatedAtMs: Long,
    workspaceGroupId: String?,
    requestId: StateRequestId,
): PdshActionReceipt {
    return try {
        val expectedCurrentId = store.currentSessionId()
        if (workspaceGroupId == ChatSessionStore.DEFAULT_WORKSPACE_GROUP_ID) {
            val seeded = store.ensureDefaultWorkspaceGroup(StateRequestId("default-folder:$sessionId"))
            check(seeded.outcome is ChatWriteOutcome.Persisted)
        } else if (workspaceGroupId != null) {
            check(store.loadWorkspaceGroups().any { it.id == workspaceGroupId }) {
                "workspace folder no longer exists"
            }
        }
        val record = ChatRecord(
            id = sessionId,
            title = "",
            updatedAtMs = updatedAtMs,
            workerSessionIds = emptyList(),
            nodes = emptyList(),
            workspaceGroupId = workspaceGroupId,
        )
        store.save(record)
        val stored = store.load(sessionId)
        check(stored == record.copy(revision = stored?.revision ?: 0L)) { "new session readback mismatch" }
        val selected = store.selectCurrentSession(
            sessionId,
            StateRequestId("current-session:${requestId.value}"),
            expectedCurrentId = expectedCurrentId,
        )
        check(selected.outcome is ChatWriteOutcome.Persisted) { "current session selection was not confirmed" }
        PdshActionReceipt(requestId, sessionId, StateRevision(stored!!.revision), PdshActionOutcome.SUCCEEDED)
    } catch (_: Exception) {
        PdshActionReceipt(requestId, sessionId, null, PdshActionOutcome.FAILED)
    }
}

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
 * @param onBack leave the page; `null` on the home face, which is the root of
 *   the stack and therefore has nothing behind it (the page then draws no back
 *   glyph at all — a back arrow on the first screen would promise a level that
 *   does not exist).
 * @param onHostNotice show one host line for a handed-off write gesture; the
 *   shell owns the four-second fallback and the bar itself.
 * @param refreshOnEnter ask for a journal scan when this page enters the
 *   composition. The home face owns that first read itself (it decides between
 *   the list and its empty state from the same snapshot), so it passes `false`
 *   and the scan happens once, not twice.
 * @param modifier the space the shell gives this page (the note bar takes the
 *   top when a line is showing).
 */
@Composable
internal fun HostSessionsScreen(
    engine: ProbeEngineViewModel,
    state: EngineState,
    turn: AppTurnState,
    onBack: (() -> Unit)? = null,
    onOpenDrawer: (() -> Unit)? = null,
    onHostNotice: (String) -> Unit,
    onOpenChat: () -> Unit = {},
    refreshOnEnter: Boolean = true,
    modifier: Modifier = Modifier,
) {
    // The gestures this host does not own (workspaces, archiving) are handed off;
    // the three that make up the main flow — new, select, rename — are performed
    // by the view model's session store and then land on the conversation.
    val handOff: (String) -> Unit = sessionHandOff(onHostNotice)
    val sessionSnapshot by engine.sessions.collectAsState()
    // The first visit asks for a read; a later one is already fresh from the
    // last scan and a completed turn.
    LaunchedEffect(refreshOnEnter) {
        if (refreshOnEnter) engine.refreshSessions()
    }
    var local by remember { mutableStateOf(SessionsLocalState()) }
    val (workspacePresent, workspacePath) = engine.chatWorkspaceSnapshot()
    val facts = remember(state, turn, sessionSnapshot, workspacePresent, workspacePath) {
        buildSessionsFacts(
            state = state,
            turn = turn,
            snapshot = sessionSnapshot,
            workspacePresent = workspacePresent,
            workspacePath = workspacePath,
        )
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
            // L69: switching opens that conversation. The view model paints the
            // stored transcript; the page's own selection is only the row highlight.
            local = local.copy(selectedID = row.id)
            engine.openChatSession(row.id)
            onOpenChat()
        },
        onQueryChange = { query -> local = local.copy(query = query) },
        onRenameStart = { row ->
            local = local.copy(renameTargetID = row.id, renameDraft = row.title)
        },
        onRenameDraftChange = { draft -> local = local.copy(renameDraft = draft) },
        onRenameCommit = { row ->
            // The typed name goes to the chat record; the row below re-reads it from
            // the same snapshot, so the page can only show a title that landed.
            val title = local.renameDraft
            local = local.copy(renameTargetID = null, renameDraft = "")
            if (!engine.renameChatSession(row.id, title)) {
                onHostNotice("会话名不能为空，本次未保存")
            }
        },
        onRenameCancel = { local = local.copy(renameTargetID = null, renameDraft = "") },
        onNewSession = {
            engine.newChatSession()
            onOpenChat()
        },
        onRetry = { engine.refreshSessions() },
        onDismissFailure = { engine.clearSessionsFailure() },
        onBack = onBack,
        onOpenDrawer = onOpenDrawer,
        // This build owns one fixed `/dsh/workspace` root. It cannot create,
        // rename, delete or switch a second root without changing worker cwd.
        workspaceActionsAvailable = false,
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
        onRestoreArchived = { row: ArchivedRowView ->
            local = local.copy(showArchived = true)
            if (!engine.restoreChatSession(row.id)) {
                onHostNotice("无法恢复此会话，列表已保留原状态")
            }
        },
        onArchiveSession = { row: SessionRowView ->
            if (!engine.archiveChatSession(row.id)) {
                onHostNotice("无法归档此会话，列表已保留原状态")
            }
        },
    )
}

// ---------------------------------------------------------------------------
// L62: the product home face
// ---------------------------------------------------------------------------

/**
 * The app's home: the session list, with the drawer that reaches everything else.
 *
 * Before L62 the home slot rendered `ProbeScreen` — the D3 diagnostic console
 * with 跑一轮, the HELLO summary and the D14/channel cards. That is a debugging
 * panel, not a product page: a person who installs the APK landed on a screen
 * addressed to whoever wrote it. This composable is the product face instead,
 * and the probe moved to the drawer (see `HostShell`'s `ENGINE_PROBE_LABEL` row).
 *
 * The body is the same [HostSessionsScreen] the 会话 route renders, so there is
 * one session list in the app rather than two. What this file adds around it is
 * exactly what a home needs and the list page cannot own:
 *
 *   * the drawer entry in the sessions page's existing empty navigation band,
 *     so it does not add a second header above the iOS list structure;
 *   * the 模型服务 onboarding card. A fresh install has no key, and the product
 *     answer is to say so and open the settings page that can fix it — not to
 *     leave a probe full of D14 state as the first screen. This card is the one
 *     thing on the face the baseline does not have (iOS keeps its key in the
 *     system store, so it has nothing to ask); it stays because the Android
 *     host really does need a key before the first turn, and it now sits on the
 *     baseline's page instead of replacing it.
 *
 * An empty read renders the same list page the 会话 route renders — the
 * baseline's root screen is the list, and its empty state is that list with
 * nothing in it (search, 新建会话, the workspace section, 添加工作文件夹,
 * 已归档). The host-owned identity card that used to replace it here was
 * Android-only, and it cost the home screen the whole of that structure.
 *
 * @param engine the composition root (its session read and its clock).
 * @param state the engine lifecycle state (the 新建会话 blocked reason).
 * @param turn the one turn's state (the other blocked reason).
 * @param providerConfigured whether the device holds a model key the last use
 *   accepted. `false` also covers a key that exists but is unusable, because the
 *   card's sentence ("还差一步:配好模型服务") is true for both, while the model
 *   page names the exact state per service.
 * @param onHostNotice show one host line for a handed-off write gesture.
 * @param onOpenDrawer open the drawer (the home's only route to the other pages).
 * @param onOpenModelProvider open 模型服务 in the settings family.
 */
@Composable
internal fun HostHomeScreen(
    engine: ProbeEngineViewModel,
    state: EngineState,
    turn: AppTurnState,
    providerConfigured: Boolean,
    onHostNotice: (String) -> Unit,
    onOpenDrawer: () -> Unit,
    onOpenModelProvider: () -> Unit,
    onOpenChat: () -> Unit = {},
) {
    val tokens = PdshThemeValues.tokens
    // The home is where the app opens, so the first journal read belongs here:
    // no row can be drawn before it is taken.
    LaunchedEffect(Unit) { engine.refreshSessions() }
    Column(
        Modifier
            .fillMaxSize()
            // The home's own chrome is the page's paper, not a second grey: the
            // sessions page below paints `colors.input`, and a `selector` column
            // behind the header left a full-width seam where the two met on a
            // phone (measured 2026-11-02). iOS's root screen is one white page.
            .background(tokens.colors.input)
            // One status-bar reading for the whole face. The strip is consumed
            // here so the sessions page below it does not add the same inset a
            // second time (the rule the shell's note bar already follows), and
            // the header is not pushed under the system bar.
            .windowInsetsPadding(WindowInsets.statusBars),
    ) {
        if (!providerConfigured) {
            ProviderSetupCard(onOpenModelProvider = onOpenModelProvider)
        }
        Box(Modifier.weight(1f)) {
            // The list page is the home, empty or not. It used to be replaced by
            // `HomeEmptyState` (a centered "Phone DSH / 运行在手机端的 DeepSeek
            // Harness / 还没有会话" card) whenever the read found nothing, and that
            // card is a screen the iOS baseline does not have: on a fresh install
            // the Android home was missing the search field, the 新建会话 row, the
            // workspace section and the 已归档 row, i.e. 79-80 % of the frame
            // (measured on a device against both the iOS baseline and this PR's own
            // parity sample — `docs/receipts/ui-parity-sheet/real-device/REPORT.md`).
            // The baseline's root screen is the sessions list, and its empty state
            // is the list with nothing in it, so the same page now draws both.
            HostSessionsScreen(
                engine = engine,
                state = state,
                turn = turn,
                onBack = null,
                onOpenDrawer = onOpenDrawer,
                onHostNotice = onHostNotice,
                onOpenChat = onOpenChat,
                refreshOnEnter = false,
                modifier = Modifier.fillMaxSize(),
            )
        }
    }
}

/**
 * 还差一步:配好模型服务 — the one onboarding the product home owes a new install.
 *
 * Every word is the baseline's (`ChatPage.swift:1355`–`:1364`, the chat page's
 * provider-setup empty state): the title, the sentence and the button. Nothing
 * here claims a model service exists; the card is drawn only while the host's
 * key read says none is usable, and the page it opens is the one that writes.
 *
 * @param onOpenModelProvider push 模型服务 (a sheet; L56 made it writable).
 */
@Composable
private fun ProviderSetupCard(onOpenModelProvider: () -> Unit) {
    val tokens = PdshThemeValues.tokens
    val type = PdshThemeValues.type
    val shape = RoundedCornerShape(tokens.radius.card)
    Box(
        Modifier
            .fillMaxWidth()
            .padding(
                horizontal = tokens.geometry.cardOuterMarginH,
                vertical = tokens.geometry.cardOuterMarginV,
            ),
    ) {
        Column(
            Modifier
                .fillMaxWidth()
                .clip(shape)
                .background(tokens.colors.input)
                .border(tokens.stroke.hairline, tokens.colors.border, shape)
                .padding(tokens.geometry.cardPadding),
        ) {
            BasicText(
                text = UiStrings.PROVIDER_SETUP_TITLE,
                style = type.secondary.copy(color = tokens.colors.primary),
            )
            Spacer(Modifier.height(tokens.spacing.jsonStack))
            BasicText(
                text = UiStrings.PROVIDER_SETUP_HINT,
                style = type.caption.copy(color = tokens.colors.secondary),
            )
            Spacer(Modifier.height(tokens.spacing.cardInset))
            HomeButton(label = UiStrings.PROVIDER_SETUP_ACTION, primary = true, onClick = onOpenModelProvider)
        }
    }
}

/**
 * One home-face button: the probe's `ActionButton` shape, from tokens only.
 *
 * A host-owned face has no page frame to borrow a control from, so the button is
 * drawn here rather than from `:lib`'s page layer — the same reason the note bar
 * and the engine-unavailable notice are drawn by the shell.
 */
@Composable
private fun HomeButton(label: String, primary: Boolean, onClick: () -> Unit) {
    val tokens = PdshThemeValues.tokens
    val shape = RoundedCornerShape(tokens.radius.card)
    Box(
        modifier = Modifier
            .fillMaxWidth()
            .height(
                if (primary) tokens.geometry.primaryButtonHeight else tokens.geometry.secondaryButtonHeight,
            )
            .clip(shape)
            .background(if (primary) tokens.colors.accent else tokens.colors.input)
            .then(
                if (primary) {
                    Modifier
                } else {
                    Modifier.border(tokens.stroke.hairline, tokens.colors.border, shape)
                },
            )
            .clickable(role = Role.Button, onClick = onClick)
            .padding(horizontal = tokens.spacing.cardInset),
        contentAlignment = Alignment.Center,
    ) {
        BasicText(
            text = label,
            style = homeButtonStyle(primary),
        )
    }
}

/** The ink of one home button; a pure function so the modifier chain stays readable. */
@Composable
private fun homeButtonStyle(primary: Boolean): TextStyle {
    val tokens = PdshThemeValues.tokens
    val type = PdshThemeValues.type
    return if (primary) {
        type.body.copy(color = tokens.colors.onAccent)
    } else {
        type.secondary.copy(color = tokens.colors.primary)
    }
}

/**
 * One handed-off session gesture, with the app's one wording for it.
 *
 * Shared by the list page and the home's empty state so a 新建会话 tap says the
 * same sentence wherever it is made.
 */
private fun sessionHandOff(onHostNotice: (String) -> Unit): (String) -> Unit = { gesture ->
    Log.i(TAG_SESSIONS, "host session gesture handed off: $gesture")
    // L81: the sentence names the command the gesture needed instead of a generic
    // refusal template. The list itself is a real host read, so nothing here is
    // implied to have changed: the page keeps its rows and says why the gesture
    // could not move one.
    onHostNotice("本宿主没有「${sessionGestureLabel(gesture)}」的命令，页面保持只读，本次没有改动")
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
