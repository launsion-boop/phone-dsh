// PR22 home drawer overlay. The host mounts this over ChatPage and owns all writes.
// SPDX-License-Identifier: MIT
package com.phonedsh.ui.nav

import androidx.compose.foundation.ScrollState
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsPressedAsState
import androidx.compose.foundation.focusGroup
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import androidx.compose.ui.window.PopupProperties
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TextField
import androidx.compose.material3.Button
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.window.DialogWindowProvider
import androidx.compose.ui.draw.clip
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.TextUnit
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.isTraversalGroup
import androidx.compose.ui.semantics.paneTitle
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.phonedsh.ui.HomeMetrics
import com.phonedsh.ui.SessionsMetrics
import com.phonedsh.ui.icon.PdshIcon
import com.phonedsh.ui.icon.PdshIconView
import com.phonedsh.ui.theme.LocalUiDarkTheme
import com.phonedsh.ui.theme.LocalUiTokens
import com.phonedsh.ui.theme.LocalUiType
import com.phonedsh.ui.theme.UiTokens
import com.phonedsh.ui.theme.applySystemBarAppearance
import kotlinx.coroutines.delay
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.launch
import com.phonedsh.ui.state.StateRequestId
import java.util.UUID

/** Caller-owned view state survives closing/reopening while the host keeps it remembered. */
@Stable
public class HomeDrawerUiState internal constructor(
    public val scrollState: ScrollState,
    collapsed: Set<String>,
    private val onCollapsedFoldersChanged: suspend (Set<String>) -> Boolean,
) {
    internal var collapsedFolderIds by mutableStateOf(collapsed)
    internal suspend fun setCollapsedFolderIds(value: Set<String>) {
        val copy = value.toSet()
        if (copy == collapsedFolderIds) return
        if (onCollapsedFoldersChanged(copy)) collapsedFolderIds = copy
    }
}

/**
 * The drawer's token table is the app's own.
 *
 * This tiny projection is the regression seam for device issue "dark drawer":
 * the previous code resolved `UiTokens.resolve(false, width)` whenever the app
 * theme was dark, so the panel stayed light. Keeping the decision in one pure
 * function makes that inversion testable without a rendered drawer.
 */
internal fun homeDrawerTokens(inherited: UiTokens): UiTokens = inherited

@Composable
public fun rememberHomeDrawerUiState(
    collapsedFolderIds: Set<String> = emptySet(),
    onCollapsedFolderIdsChanged: suspend (Set<String>) -> Boolean = { true },
): HomeDrawerUiState {
    val scroll = rememberScrollState()
    val latestChange by rememberUpdatedState(onCollapsedFolderIdsChanged)
    return remember(scroll) { HomeDrawerUiState(scroll, collapsedFolderIds, { ids -> latestChange(ids) }) }
}

/**
 * Full-screen PR22 drawer overlay. All business actions are optional host callbacks;
 * absent capabilities are disabled and identified as unavailable.
 */
@Composable
public fun HomeDrawer(
    facts: HomeDrawerFacts,
    onClose: () -> Unit,
    isOpen: Boolean = true,
    onNavigate: ((PdshRoute) -> Unit)? = null,
    onCreateSession: (suspend () -> Boolean)? = null,
    onOpenSchedules: (() -> Unit)? = null,
    /** Confirmed host writes for folder and session metadata; missing capabilities stay disabled. */
    onMutation: HomeDrawerMutationAction? = null,
    onArchiveSession: HomeDrawerArchiveAction? = null,
    onCreateSessionInFolder: (suspend (String) -> Boolean)? = null,
    onRetry: (() -> Unit)? = null,
    onOpenSession: ((String) -> Unit)? = null,
    modifier: Modifier = Modifier,
    state: HomeDrawerUiState = rememberHomeDrawerUiState(),
) {
    // The drawer follows the app's theme. It used to resolve a light token
    // table for dark mode (the iOS shell's fixed light panel); that painted a
    // light drawer under the app's dark setting and diverged from every other
    // surface. The dialog's status-bar glyphs follow the app theme separately
    // through [LocalUiDarkTheme] below.
    val inheritedTokens = LocalUiTokens.current
    val darkTheme = LocalUiDarkTheme.current
    val tokens = homeDrawerTokens(inheritedTokens)
    val type = LocalUiType.current
    var dialog by rememberSaveable { mutableStateOf<String?>(null) }
    var draft by rememberSaveable { mutableStateOf("") }
    var targetId by rememberSaveable { mutableStateOf("") }
    var toast by rememberSaveable { mutableStateOf(false) }
    var dismissedLocally by remember { mutableStateOf(false) }
    var operationEpoch by remember { mutableIntStateOf(0) }
    var pendingArchiveIds by remember { mutableStateOf(emptySet<String>()) }
    var archiveFailureById by remember { mutableStateOf(emptyMap<String, String>()) }
    var operationFailure by rememberSaveable { mutableStateOf<String?>(null) }
    val coroutineScope = rememberCoroutineScope()
    val initialFocus = remember { FocusRequester() }
    LaunchedEffect(Unit) { runCatching { initialFocus.requestFocus() } }

    LaunchedEffect(isOpen) {
        operationEpoch++
        dismissedLocally = !isOpen
        if (!isOpen) {
            pendingArchiveIds = emptySet()
            toast = false
        }
    }

    fun dismissDrawer() {
        if (!dismissedLocally) {
            dismissedLocally = true
            operationEpoch++
            pendingArchiveIds = emptySet()
            toast = false
            onClose()
        }
    }

    fun archiveSession(sessionId: String) {
        val action = onArchiveSession ?: return
        if (!isOpen || dismissedLocally || sessionId in pendingArchiveIds) return
        val request = HomeDrawerArchiveRequest(UUID.randomUUID().toString(), sessionId)
        val epoch = operationEpoch
        pendingArchiveIds = pendingArchiveIds + sessionId
        archiveFailureById = archiveFailureById - sessionId
        coroutineScope.launch {
            try {
                val result = action(request)
                if (!isOpen || dismissedLocally || operationEpoch != epoch) return@launch
                if (result.requestId != request.requestId || result.sessionId != request.sessionId) {
                    val reason = "归档结果与此会话不匹配，归档状态未确认"
                    archiveFailureById = archiveFailureById + (sessionId to reason)
                    operationFailure = reason
                    return@launch
                }
                when (result) {
                    is HomeDrawerArchiveResult.Archived -> { toast = true; operationFailure = null }
                    is HomeDrawerArchiveResult.Failed -> {
                        val reason = result.reason.ifBlank { "归档未完成，会话仍保留，可重试" }
                        archiveFailureById = archiveFailureById + (sessionId to reason)
                        operationFailure = reason
                    }
                    is HomeDrawerArchiveResult.Unavailable -> {
                        val reason = result.reason?.takeIf(String::isNotBlank) ?: "此主机暂不支持归档，会话仍保留"
                        archiveFailureById = archiveFailureById + (sessionId to reason)
                        operationFailure = reason
                    }
                }
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (failure: Exception) {
                if (isOpen && !dismissedLocally && operationEpoch == epoch) {
                    val explanation = failure.message?.takeIf(String::isNotBlank)
                    val reason = explanation ?: "归档状态未确认，请刷新列表后再试"
                    archiveFailureById = archiveFailureById + (sessionId to reason)
                    operationFailure = reason
                }
            } finally {
                if (operationEpoch == epoch) pendingArchiveIds = pendingArchiveIds - sessionId
            }
        }
    }

    fun mutationRequestId(command: PdshUiHostCommand): StateRequestId? = when (command) {
        is PdshUiHostCommand.WorkspaceFolderCreate -> command.requestId
        is PdshUiHostCommand.WorkspaceFolderRename -> command.requestId
        is PdshUiHostCommand.WorkspaceFolderDelete -> command.requestId
        is PdshUiHostCommand.SessionRename -> command.requestId
        else -> null
    }

    fun submitMutation(command: PdshUiHostCommand) {
        val action = onMutation ?: return
        val requestId = mutationRequestId(command) ?: return
        val expectedSessionId = (command as? PdshUiHostCommand.SessionRename)?.sessionId
        coroutineScope.launch {
            val result = try {
                action(command)
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (failure: Exception) {
                operationFailure = failure.message?.takeIf(String::isNotBlank)
                    ?: "会话或文件夹修改失败，请刷新后重试"
                return@launch
            }
            if (result?.confirms(requestId, expectedSessionId, null) != true) {
                operationFailure = "会话或文件夹修改未确认，请刷新列表后重试"
            } else {
                operationFailure = null
            }
        }
    }

    fun createSessionInFolder(folderId: String) {
        val create = onCreateSessionInFolder ?: return
        if (folderId.isBlank() || folderId.startsWith("__")) return
        coroutineScope.launch {
            try {
                if (isOpen && !dismissedLocally && create(folderId)) dismissDrawer()
                else operationFailure = "未能在此文件夹中新建会话，请刷新后重试"
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (failure: Exception) {
                operationFailure = failure.message?.takeIf(String::isNotBlank)
                    ?: "未能在此文件夹中新建会话，请刷新后重试"
            }
        }
    }

    if (isOpen && !dismissedLocally) Dialog(onDismissRequest = ::dismissDrawer, properties = DialogProperties(
        usePlatformDefaultWidth = false,
        dismissOnBackPress = true,
        dismissOnClickOutside = true,
        decorFitsSystemWindows = false,
    )) {
      val dialogView = LocalView.current
      SideEffect {
          (dialogView.parent as? DialogWindowProvider)?.window?.let { window ->
              // The composable owns the source's single 28% scrim. A second
              // platform dim would darken both the page and the status bar twice.
              window.clearFlags(android.view.WindowManager.LayoutParams.FLAG_DIM_BEHIND)
              window.addFlags(android.view.WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN)
              if (android.os.Build.VERSION.SDK_INT >= 28) {
                  val attributes = window.attributes
                  attributes.layoutInDisplayCutoutMode = if (android.os.Build.VERSION.SDK_INT >= 30)
                      android.view.WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_ALWAYS
                  else android.view.WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_SHORT_EDGES
                  window.attributes = attributes
              }
              window.setGravity(android.view.Gravity.TOP or android.view.Gravity.START)
              window.statusBarColor = android.graphics.Color.TRANSPARENT
              window.navigationBarColor = android.graphics.Color.TRANSPARENT
              window.setLayout(android.view.WindowManager.LayoutParams.MATCH_PARENT, android.view.WindowManager.LayoutParams.MATCH_PARENT)
              applySystemBarAppearance(window, dialogView, darkTheme)
          }
      }
      CompositionLocalProvider(LocalUiTokens provides tokens) {
      BoxWithConstraints(modifier.fillMaxSize().semantics {
        paneTitle = "会话抽屉"
        isTraversalGroup = true
      }) {
        val panelWidth = minOf(SessionsMetrics.drawerWidth, maxWidth - HomeMetrics.NAV_BUTTON_PT.dp)
        Row(Modifier.fillMaxSize()) {
        Column(
            Modifier.width(panelWidth).fillMaxHeight()
                .clip(RoundedCornerShape(topEnd = SessionsMetrics.DRAWER_PANEL_RADIUS_PT.dp, bottomEnd = SessionsMetrics.DRAWER_PANEL_RADIUS_PT.dp))
                .background(tokens.colors.page)
                .windowInsetsPadding(WindowInsets.statusBars.only(WindowInsetsSides.Top))
                .focusGroup().testTag(HomeDrawerTags.PANEL),
        ) {
            Column(
                Modifier.weight(1f).fillMaxWidth()
                    .verticalScroll(state.scrollState)
                    .testTag(HomeDrawerTags.SCROLL)
                    // PR #60 removed the pinned 设置 bar (`HomeDrawer.swift:45`): settings
                    // is the 我的 tab now, so the list itself clears the home indicator.
                    .padding(top = HomeMetrics.NAV_TOP_PT.dp,
                        bottom = WindowInsets.navigationBars.asPaddingValues().calculateBottomPadding() + 24.dp),
            ) {
                Column(Modifier.padding(horizontal = SessionsMetrics.rowInset)) {
                    EntryRow("新会话", PdshIcon.NEW_CHAT,
                        detail = facts.newSessionBlockedReason ?: "",
                        enabled = onCreateSession != null && facts.newSessionBlockedReason == null,
                        unavailable = onCreateSession == null,
                        modifier = Modifier.focusRequester(initialFocus).testTag(HomeDrawerTags.NEW_SESSION),
                    ) {
                        val create = onCreateSession ?: return@EntryRow
                        coroutineScope.launch {
                            if (isOpen && !dismissedLocally && create()) dismissDrawer()
                        }
                    }
                    Spacer(Modifier.height(2.dp))
                    EntryRow("定时任务", PdshIcon.CLOCK,
                        detail = facts.scheduleCount?.takeIf { it > 0 }?.toString() ?: "",
                        enabled = onOpenSchedules != null || onNavigate != null,
                        unavailable = onOpenSchedules == null && onNavigate == null,
                        modifier = Modifier.testTag(HomeDrawerTags.SCHEDULES),
                    ) { if (onOpenSchedules != null) onOpenSchedules.invoke() else onNavigate?.invoke(PdshRoute.Automation) }
                }
                Spacer(Modifier.height(24.dp))
                Row(Modifier.fillMaxWidth().height(36.dp).padding(start = HomeMetrics.CONTENT_INSET_PT.dp, end = 12.dp), verticalAlignment = Alignment.CenterVertically) {
                    Text("文件夹", style = type.secondary.copy(color = tokens.colors.textSecondary))
                    Spacer(Modifier.weight(1f))
                    Box {
                        var addMenu by remember { mutableStateOf(false) }
                        IconAction("新建文件夹", PdshIcon.PLUS, enabled = onMutation != null,
                            modifier = Modifier.size(SessionsMetrics.WORKSPACE_MENU_WIDTH_PT.dp).testTag(HomeDrawerTags.CREATE_FOLDER)) { addMenu = true }
                        DropdownMenu(addMenu, { addMenu = false },
                            modifier = Modifier.widthIn(max = 240.dp), properties = PopupProperties(focusable = true, clippingEnabled = true)) {
                            DropdownMenuItem(text = { Text("新建文件夹") }, enabled = onMutation != null,
                                onClick = { addMenu = false; targetId = ""; draft = ""; dialog = "create-folder" })
                        }
                    }
                }
                val drawerFailure = operationFailure ?: facts.failure
                if (drawerFailure != null) {
                    Row(
                        Modifier.fillMaxWidth().padding(horizontal = SessionsMetrics.rowInset, vertical = 8.dp)
                            .testTag(HomeDrawerTags.FAILURE),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Text(drawerFailure, Modifier.weight(1f), style = type.caption.copy(color = tokens.colors.danger))
                        TextButton(
                            onClick = { operationFailure = null; archiveFailureById = emptyMap(); onRetry?.invoke() },
                            enabled = onRetry != null,
                            modifier = Modifier.testTag(HomeDrawerTags.RETRY),
                        ) { Text("重试") }
                    }
                }
                Column(Modifier.padding(horizontal = SessionsMetrics.rowInset), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                    val folders = facts.folders
                    if (folders == null) {
                        Text("文件夹列表未知", Modifier.padding(horizontal = HomeMetrics.CONTENT_INSET_PT.dp, vertical = 8.dp), style = type.secondary.copy(color = tokens.colors.textSecondary))
                    } else if (folders.isEmpty() && facts.unassignedSessions.isNullOrEmpty()) {
                        Text("还没有文件夹。点右上角的 + 新建一个，文件夹用于整理会话；文件仍使用工作区。", Modifier.padding(horizontal = HomeMetrics.CONTENT_INSET_PT.dp, vertical = 8.dp), style = type.secondary.copy(color = tokens.colors.textSubtle))
                    }
                    val defaultFolder = folders?.firstOrNull { it.isDefault }
                    val loose = facts.unassignedSessions
                    if (folders == null && loose != null && loose.isNotEmpty()) {
                        FolderGroup("__unknown_folder__", "未分配文件夹", loose, state,
                            onOpenSession, canRenameSession = onMutation != null, onArchiveSession, pendingArchiveIds,
                            archiveFailureById, ::archiveSession, canRenameFolder = false, canDeleteFolder = false,
                            onNewSessionInFolder = null,
                            emptyMessage = "还没有会话",
                            onRequestRename = { _, _ -> }, onRequestDelete = { _ -> },
                            onRequestRenameSession = { id, name -> targetId = id; draft = name; dialog = "rename-session" },
                            activeSessionId = facts.activeSessionId)
                    }
                    if (folders != null && defaultFolder == null && loose != null && loose.isNotEmpty()) {
                        FolderGroup("__unassigned__", "未分配", loose, state,
                            onOpenSession, canRenameSession = onMutation != null, onArchiveSession, pendingArchiveIds,
                            archiveFailureById, ::archiveSession, canRenameFolder = false, canDeleteFolder = false,
                            onNewSessionInFolder = null,
                            emptyMessage = "还没有会话",
                            onRequestRename = { _, _ -> }, onRequestDelete = { _ -> },
                            onRequestRenameSession = { id, name -> targetId = id; draft = name; dialog = "rename-session" },
                            activeSessionId = facts.activeSessionId)
                    }
                    folders.orEmpty().forEach { folder ->
                        // The iOS drawer renders unassigned rows inside a known
                        // default folder, but ownership remains unassigned in the
                        // host store and is not rewritten by this presentation.
                        val sessions = if (folder === defaultFolder || folder.id == defaultFolder?.id) {
                            folder.sessions + (loose ?: emptyList())
                        } else folder.sessions
                        FolderGroup(folder.id, folder.title.ifBlank { "文件夹" }, sessions, state,
                            onOpenSession, canRenameSession = onMutation != null, onArchiveSession, pendingArchiveIds,
                            archiveFailureById, ::archiveSession,
                            canRenameFolder = onMutation != null,
                            canDeleteFolder = onMutation != null && !folder.isDefault,
                            onNewSessionInFolder = onCreateSessionInFolder?.let { { folderId -> createSessionInFolder(folderId) } },
                            emptyMessage = "还没有会话",
                            onRequestRename = { id, name -> targetId = id; draft = name; dialog = "rename-folder" },
                            onRequestDelete = { id -> targetId = id; dialog = "delete-folder" },
                            onRequestRenameSession = { id, name -> targetId = id; draft = name; dialog = "rename-session" },
                            activeSessionId = facts.activeSessionId)
                    }
                }
            }
        }
        Box(Modifier.weight(1f).fillMaxHeight().background(Color.Black.copy(alpha = SessionsMetrics.DRAWER_SCRIM_ALPHA))
            .clickable(role = Role.Button, onClick = ::dismissDrawer)
            .semantics { contentDescription = "关闭抽屉" }
            .testTag(HomeDrawerTags.SCRIM))
        }
        if (toast) {
            LaunchedEffect(toast, operationEpoch) {
                val epoch = operationEpoch
                delay(2200)
                if (isOpen && !dismissedLocally && epoch == operationEpoch) toast = false
            }
            Text("已归档，可在 我的 › 已归档会话 里找回", Modifier.align(Alignment.TopCenter)
                .padding(top = 16.dp).background(tokens.colors.surface, CircleShape).padding(horizontal = 12.dp, vertical = 6.dp),
                style = type.caption.copy(color = tokens.colors.textSecondary))
        }
        if (dialog != null) {
            val editorTitle = when (dialog) {
                "create-folder" -> "新建文件夹"
                "rename-folder" -> "重命名文件夹"
                "delete-folder" -> "删除文件夹？"
                else -> "编辑名称"
            }
            Box(Modifier.fillMaxSize().background(Color.Black.copy(alpha = 0.28f))
                .clickable(role = Role.Button, onClick = { dialog = null }), contentAlignment = Alignment.Center) {
                Column(Modifier.widthIn(max = 360.dp).padding(24.dp)
                    .background(tokens.colors.surface, RoundedCornerShape(20.dp))
                    .clickable(role = Role.Button, onClick = {})
                    .padding(24.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
                    Text(editorTitle, style = type.headline.copy(color = tokens.colors.textPrimary))
                    if (dialog == "delete-folder") {
                        Text("里面的会话会留着，只是不再放在这个文件夹里。", style = type.secondary.copy(color = tokens.colors.textSecondary))
                    } else {
                        TextField(value = draft, onValueChange = { draft = it }, singleLine = true,
                            modifier = Modifier.fillMaxWidth().testTag(HomeDrawerTags.EDITOR),
                            label = { Text(if (dialog == "rename-session") "会话名称" else "文件夹名称") })
                    }
                    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.End, verticalAlignment = Alignment.CenterVertically) {
                        TextButton(onClick = { dialog = null }) { Text("取消") }
                        TextButton(onClick = {
                            val value = draft.trim()
                            val requestId = StateRequestId("ui.drawer.${UUID.randomUUID()}")
                            val command = when (dialog) {
                                "create-folder" -> value.takeIf(String::isNotEmpty)?.let { PdshUiHostCommand.WorkspaceFolderCreate(it, requestId) }
                                "rename-folder" -> value.takeIf(String::isNotEmpty)?.let { PdshUiHostCommand.WorkspaceFolderRename(targetId, it, requestId) }
                                "delete-folder" -> PdshUiHostCommand.WorkspaceFolderDelete(targetId, requestId)
                                else -> value.takeIf(String::isNotEmpty)?.let { PdshUiHostCommand.SessionRename(targetId, it, requestId) }
                            }
                            dialog = null
                            command?.let(::submitMutation)
                        }, enabled = onMutation != null && (dialog == "delete-folder" || draft.trim().isNotEmpty())) {
                            Text(when (dialog) { "create-folder" -> "创建"; "delete-folder" -> "删除"; else -> "保存" })
                        }
                    }
                }
            }
        }
      }
      }
    }
}

public object HomeDrawerTags {
    public const val PANEL = "home.drawer.panel"
    public const val SCRIM = "home.drawer.scrim"
    public const val NEW_SESSION = "home.drawer.new-session"
    public const val SCHEDULES = "home.drawer.schedules"
    public const val CREATE_FOLDER = "home.drawer.create-folder"
    public const val EDITOR = "home.drawer.editor"
    public const val SCROLL = "home.drawer.scroll"
    public const val ARCHIVE_PENDING_PREFIX = "home.drawer.archive.pending."
    public const val ARCHIVE_FAILURE_PREFIX = "home.drawer.archive.failure."
    public const val FAILURE = "home.drawer.failure"
    public const val RETRY = "home.drawer.retry"
    public const val FOLDER_PREFIX = "home.drawer.folder."
    public const val SESSION_PREFIX = "home.drawer.session."
}

@Composable
private fun EntryRow(label: String, icon: PdshIcon, detail: String, enabled: Boolean, unavailable: Boolean,
                     modifier: Modifier = Modifier, action: () -> Unit) {
    val colors = LocalUiTokens.current.colors
    val type = LocalUiType.current
    val interaction = remember { MutableInteractionSource() }
    val pressed by interaction.collectIsPressedAsState()
    Row(modifier.fillMaxWidth().height(SessionsMetrics.ACTION_ROW_HEIGHT_PT.dp)
        .background(if (pressed) colors.userBubble.copy(alpha = SessionsMetrics.DRAWER_PRESS_ALPHA) else Color.Transparent,
            RoundedCornerShape(SessionsMetrics.DRAWER_CARD_RADIUS_PT.dp))
        .clickable(interactionSource = interaction, indication = null, enabled = enabled, role = Role.Button, onClick = action)
        .semantics { if (!enabled) stateDescription = if (detail.isNotEmpty()) detail else if (unavailable) "不可用" else "不可用" }
        .padding(horizontal = 12.dp), verticalAlignment = Alignment.CenterVertically) {
        PdshIconView(icon, SessionsMetrics.DRAWER_ROW_GLYPH_REF_PT.dp, if (enabled) colors.textPrimary else colors.textPlaceholder, null, Modifier.size(24.dp))
        Spacer(Modifier.width(SessionsMetrics.DRAWER_ROW_SPACING_PT.dp))
        Text(label, style = type.body.copy(color = if (enabled) colors.textPrimary else colors.textPlaceholder))
        Spacer(Modifier.weight(1f))
        if (detail.isNotEmpty()) Text(detail, style = type.caption.copy(color = colors.textPlaceholder), maxLines = 1, overflow = TextOverflow.Ellipsis)
    }
}

@OptIn(androidx.compose.foundation.ExperimentalFoundationApi::class)
@Composable
private fun FolderGroup(id: String, title: String, sessions: List<HomeDrawerSession>, state: HomeDrawerUiState,
                       onOpen: ((String) -> Unit)?, canRenameSession: Boolean,
                       onArchive: HomeDrawerArchiveAction?, pendingArchiveIds: Set<String>,
                       archiveFailureById: Map<String, String>, onArchiveRequest: (String) -> Unit,
                       canRenameFolder: Boolean, canDeleteFolder: Boolean, emptyMessage: String,
                       onNewSessionInFolder: ((String) -> Unit)?,
                       onRequestRename: (String, String) -> Unit, onRequestDelete: (String) -> Unit,
                       onRequestRenameSession: (String, String) -> Unit, activeSessionId: String?) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    val expanded = id !in state.collapsedFolderIds
    val scope = rememberCoroutineScope()
    var changingFold by remember(id) { mutableStateOf(false) }
    var folderMenu by remember(id) { mutableStateOf(false) }
    Row(Modifier.fillMaxWidth().height(SessionsMetrics.WORKSPACE_ROW_HEIGHT_PT.dp)
        .combinedClickable(onClick = {
            if (!changingFold) scope.launch {
                changingFold = true
                state.setCollapsedFolderIds(if (expanded) state.collapsedFolderIds + id else state.collapsedFolderIds - id)
                changingFold = false
            }
        }, onLongClick = { folderMenu = true })
        .semantics { contentDescription = "$title，${sessions.size} 个会话"; stateDescription = if (expanded) "已展开" else "已收起" }
        .testTag(HomeDrawerTags.FOLDER_PREFIX + id).padding(horizontal = 12.dp), verticalAlignment = Alignment.CenterVertically) {
        PdshIconView(if (expanded) PdshIcon.CHEVRON_DOWN else PdshIcon.CHEVRON_RIGHT, 12.dp, tokens.colors.textPlaceholder, null)
        Spacer(Modifier.width(8.dp))
        PdshIconView(PdshIcon.FOLDER, 20.dp, tokens.colors.textSecondary, null)
        Spacer(Modifier.width(8.dp))
        Text(title, style = type.body.copy(color = tokens.colors.textPrimary), maxLines = 1, overflow = TextOverflow.Ellipsis)
        Spacer(Modifier.width(8.dp))
        if (sessions.isNotEmpty()) Text(sessions.size.toString(), style = type.caption.copy(color = tokens.colors.textPlaceholder))
        DropdownMenu(folderMenu, { folderMenu = false }, modifier = Modifier.widthIn(max = 240.dp),
            properties = PopupProperties(focusable = true, clippingEnabled = true)) {
            DropdownMenuItem(text = { Text("在这里新建会话") }, enabled = onNewSessionInFolder != null,
                onClick = { folderMenu = false; onNewSessionInFolder?.invoke(id) })
            DropdownMenuItem(text = { Text("重命名") }, enabled = canRenameFolder,
                onClick = { folderMenu = false; onRequestRename(id, title) })
            DropdownMenuItem(text = { Text("删除文件夹") }, enabled = canDeleteFolder,
                onClick = { folderMenu = false; onRequestDelete(id) })
        }
    }
    if (expanded) {
        if (sessions.isEmpty()) Text(emptyMessage, Modifier.padding(start = 50.dp).height(36.dp).wrapContentHeight(Alignment.CenterVertically), style = type.secondary.copy(color = tokens.colors.textSubtle))
        sessions.forEach { session ->
            var menu by remember(session.id) { mutableStateOf(false) }
            val pendingArchive = session.id in pendingArchiveIds
            Row(Modifier.fillMaxWidth().height(SessionsMetrics.SESSION_ROW_HEIGHT_PT.dp)
                .combinedClickable(onClick = { onOpen?.invoke(session.id) }, onLongClick = { if (canRenameSession || onArchive != null) menu = true })
                .background(if (session.id == activeSessionId) tokens.colors.sessionSurface else Color.Transparent, RoundedCornerShape(SessionsMetrics.DRAWER_CARD_RADIUS_PT.dp))
                .semantics {
                    contentDescription = session.title ?: "新会话"
                    stateDescription = when {
                        pendingArchive -> "正在归档"
                        onOpen == null -> "不可用"
                        else -> ""
                    }
                }
                .testTag(HomeDrawerTags.SESSION_PREFIX + session.id).padding(start = 42.dp, end = 12.dp), verticalAlignment = Alignment.CenterVertically) {
                Text(session.title?.takeIf { it.isNotBlank() } ?: "新会话", Modifier.weight(1f), style = type.body.copy(color = tokens.colors.textPrimary), maxLines = 1, overflow = TextOverflow.Ellipsis)
                if (pendingArchive) CircularProgressIndicator(Modifier.size(14.dp).testTag(HomeDrawerTags.ARCHIVE_PENDING_PREFIX + session.id), strokeWidth = 1.5.dp)
                else if (session.running) CircularProgressIndicator(Modifier.size(14.dp), strokeWidth = 1.5.dp)
                else session.relativeTime?.let { Text(it, style = type.caption.copy(color = tokens.colors.textPlaceholder), maxLines = 1) }
        // The 240dp popup cap is an approximate viewport guard, not a HomeSpec
        // token or pixel-parity claim; narrow split views and enlarged text may wrap.
        DropdownMenu(menu, { menu = false }, modifier = Modifier.widthIn(max = 240.dp),
                    properties = PopupProperties(focusable = true, clippingEnabled = true)) {
                    DropdownMenuItem(text = { Text("编辑名称") }, enabled = canRenameSession,
                        onClick = { menu = false; onRequestRenameSession(session.id, session.title.orEmpty()) })
                    DropdownMenuItem(text = { Text(if (onArchive == null) "归档不可用" else "归档") }, enabled = onArchive != null && !pendingArchive,
                        onClick = { menu = false; onArchiveRequest(session.id) })
                }
            }
            archiveFailureById[session.id]?.let { reason ->
                Text(reason, Modifier.padding(start = 42.dp, end = 12.dp, bottom = 4.dp)
                    .testTag(HomeDrawerTags.ARCHIVE_FAILURE_PREFIX + session.id),
                    style = type.caption.copy(color = tokens.colors.danger))
            }
        }
    }
}

@Composable
private fun IconAction(label: String, icon: PdshIcon, enabled: Boolean, modifier: Modifier, onClick: () -> Unit) {
    val color = LocalUiTokens.current.colors.textSecondary
    Box(modifier.clickable(enabled = enabled, role = Role.Button, onClick = onClick)
        .semantics { contentDescription = label; if (!enabled) stateDescription = "不可用" }, contentAlignment = Alignment.Center) {
        PdshIconView(icon, 18.dp, color, null)
    }
}
