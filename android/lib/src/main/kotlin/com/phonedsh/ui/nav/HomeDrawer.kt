// PR22 home drawer overlay. The host mounts this over ChatPage and owns all writes.
// SPDX-License-Identifier: MIT
package com.phonedsh.ui.nav

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.animate
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.ScrollState
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.focusGroup
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
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
import androidx.compose.material3.ButtonDefaults
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Paint
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.graphics.addOutline
import androidx.compose.ui.graphics.drawscope.drawIntoCanvas
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.input.pointer.PointerInputScope
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.input.pointer.positionChange
import androidx.compose.ui.input.pointer.util.VelocityTracker
import androidx.compose.ui.platform.LocalSoftwareKeyboardController
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.window.DialogWindowProvider
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.isTraversalGroup
import androidx.compose.ui.semantics.onClick
import androidx.compose.ui.semantics.paneTitle
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.phonedsh.ui.HomeMetrics
import com.phonedsh.ui.SessionsMetrics
import com.phonedsh.ui.UiStrings
import com.phonedsh.ui.page.workspaceTitle
import com.phonedsh.ui.icon.PdshIcon
import com.phonedsh.ui.icon.PdshIconView
import com.phonedsh.ui.theme.LocalUiDarkTheme
import com.phonedsh.ui.theme.LocalUiTokens
import com.phonedsh.ui.theme.LocalUiType
import com.phonedsh.ui.theme.UiShadow
import com.phonedsh.ui.theme.UiTokens
import com.phonedsh.ui.theme.applySystemBarAppearance
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import com.phonedsh.ui.state.StateRequestId
import java.util.UUID
import kotlin.math.abs
import kotlin.math.roundToInt

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
    val drawer = tokens.drawer
    val drawerShape = RoundedCornerShape(
        topEnd = drawer.panelTrailingRadius,
        bottomEnd = drawer.panelTrailingRadius,
    )
    val closedPanelOffset = -drawer.width.value - drawer.closedOverhang.value
    var panelOffset by remember { mutableFloatStateOf(closedPanelOffset) }
    val keyboardController = LocalSoftwareKeyboardController.current
    val latestOnClose by rememberUpdatedState(onClose)
    var dialogVisible by remember { mutableStateOf(isOpen) }
    var closing by remember { mutableStateOf(false) }
    var motionJob by remember { mutableStateOf<Job?>(null) }
    var dialog by rememberSaveable { mutableStateOf<String?>(null) }

    suspend fun animatePanel(target: Float, durationMs: Int, easing: androidx.compose.animation.core.Easing) {
        animate(
            initialValue = panelOffset,
            targetValue = target,
            animationSpec = tween(durationMillis = durationMs, easing = easing),
        ) { value, _ -> panelOffset = value }
    }
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

    // A switch may make the host reorder its refreshed session list (for
    // example by touching the opened session's timestamp). Hold the order the
    // drawer first showed so the row under the finger cannot move; ids that
    // appear later are appended. The state dies with the drawer, so the next
    // open adopts the host's fresh order.
    var heldSessionOrder by remember { mutableStateOf(emptyList<String>()) }
    val currentSessionIds = remember(facts.folders, facts.unassignedSessions) {
        (facts.folders.orEmpty().flatMap { folder -> folder.sessions.map { it.id } } +
            facts.unassignedSessions.orEmpty().map { it.id }).distinct()
    }
    val (stableSessionIds, nextHeldSessionOrder) = remember(heldSessionOrder, currentSessionIds) {
        homeDrawerStableSessionOrder(heldSessionOrder, currentSessionIds)
    }
    SideEffect {
        if (nextHeldSessionOrder != heldSessionOrder) heldSessionOrder = nextHeldSessionOrder
    }
    val sessionRank = remember(stableSessionIds) {
        stableSessionIds.withIndex().associate { (index, id) -> id to index }
    }
    val stableFolders = facts.folders?.map { folder ->
        folder.copy(sessions = homeDrawerSessionsInHeldOrder(folder.sessions, sessionRank))
    }
    val stableLoose = facts.unassignedSessions?.let {
        homeDrawerSessionsInHeldOrder(it, sessionRank)
    }

    fun finishClose() {
        dialogVisible = false
        closing = false
        dismissedLocally = true
        latestOnClose()
    }

    fun requestClose() {
        if (!dialogVisible || closing) return
        closing = true
        dismissedLocally = true
        operationEpoch++
        pendingArchiveIds = emptySet()
        toast = false
        motionJob?.cancel()
        motionJob = coroutineScope.launch {
            try {
                animatePanel(closedPanelOffset, tokens.motion.drawerCloseMs, tokens.motion.drawerCloseEasing)
                finishClose()
            } finally {
                closing = false
            }
        }
    }

    fun settleBack() {
        motionJob?.cancel()
        motionJob = coroutineScope.launch {
            animatePanel(0f, tokens.motion.drawerSettleMs, tokens.motion.drawerSettleEasing)
        }
    }

    fun dismissDrawer() {
        requestClose()
    }

    // Open from the closed overhang and close with the contract's own motion.
    // The dialog stays composed until the close animation ends (rule 8); only
    // then does the host remove it and learn about the dismissal.
    LaunchedEffect(isOpen) {
        operationEpoch++
        if (isOpen) {
            dismissedLocally = false
            if (closing) {
                motionJob?.cancel()
                closing = false
            }
            if (!dialogVisible) {
                dialogVisible = true
                panelOffset = closedPanelOffset
            }
            if (panelOffset < 0f) {
                keyboardController?.hide()
                motionJob?.cancel()
                motionJob = coroutineScope.launch {
                    animatePanel(0f, tokens.motion.drawerOpenMs, tokens.motion.drawerOpenEasing)
                }
            }
        } else if (dialogVisible && !closing && !dismissedLocally) {
            closing = true
            dismissedLocally = true
            pendingArchiveIds = emptySet()
            toast = false
            motionJob?.cancel()
            try {
                animatePanel(closedPanelOffset, tokens.motion.drawerCloseMs, tokens.motion.drawerCloseEasing)
                dialogVisible = false
                closing = false
                latestOnClose()
            } finally {
                closing = false
            }
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

    if (dialogVisible) Dialog(onDismissRequest = ::dismissDrawer, properties = DialogProperties(
        usePlatformDefaultWidth = false,
        dismissOnBackPress = true,
        dismissOnClickOutside = true,
        decorFitsSystemWindows = false,
    )) {
      val dialogView = LocalView.current
      SideEffect {
          (dialogView.parent as? DialogWindowProvider)?.window?.let { window ->
              // Only the composable's own scrim may animate: the platform window
              // enter/exit animation would add a second, unmeasured effect.
              window.setWindowAnimations(0)
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
        val panelWidth = minOf(drawer.width, maxWidth - HomeMetrics.NAV_BUTTON_PT.dp)
        Box(Modifier.fillMaxSize()) {
        Box(Modifier.fillMaxSize()
            .background(Color.Black.copy(alpha = DrawerGesture.scrimAlpha(panelOffset)))
            .pointerInput(drawer) {
                drawerDrag(
                    dragMinimumDistance = drawer.dragMinimumDistance,
                    initialOffset = { panelOffset },
                    onOffset = { if (!closing && !dismissedLocally) { motionJob?.cancel(); panelOffset = it } },
                    onRelease = { dx, velocity ->
                        if (!closing && !dismissedLocally) {
                            when (DrawerGesture.release(dx, velocity)) {
                                DrawerRelease.Close -> requestClose()
                                DrawerRelease.Settle -> settleBack()
                            }
                        }
                    },
                    onTap = ::dismissDrawer,
                )
            }
            .semantics {
                contentDescription = "关闭抽屉"
                role = Role.Button
                onClick(label = "关闭抽屉") { dismissDrawer(); true }
            }
            .testTag(HomeDrawerTags.SCRIM))
        Column(
            Modifier.width(panelWidth).fillMaxHeight()
                .offset { IntOffset(panelOffset.dp.roundToPx(), 0) }
                .drawerShadow(tokens.shadow, drawerShape)
                .clip(drawerShape)
                .background(tokens.colors.page)
                .pointerInput(drawer) {
                    drawerDrag(
                        dragMinimumDistance = drawer.dragMinimumDistance,
                        initialOffset = { panelOffset },
                        onOffset = { if (!closing && !dismissedLocally) { motionJob?.cancel(); panelOffset = it } },
                        onRelease = { dx, velocity ->
                            if (!closing && !dismissedLocally) {
                                when (DrawerGesture.release(dx, velocity)) {
                                    DrawerRelease.Close -> requestClose()
                                    DrawerRelease.Settle -> settleBack()
                                }
                            }
                        },
                    )
                }
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
                Column(Modifier.padding(horizontal = 16.dp)) {
                    val blockedReason = drawerNewSessionBlockedReason(facts.languageId, facts.newSessionBlockedReason)
                    val enabled = onCreateSession != null && facts.newSessionBlockedReason == null
                    val newSessionLabel = drawerNativeText(facts.languageId, UiStrings.NEW_SESSION, UiStrings.DRAWER_NEW_SESSION_EN)
                    Button(
                        onClick = {
                            val create = onCreateSession
                            if (create != null) {
                                coroutineScope.launch {
                                    if (isOpen && !dismissedLocally && create()) dismissDrawer()
                                }
                            }
                        },
                        enabled = enabled,
                        modifier = Modifier.fillMaxWidth().height(52.dp)
                            .focusRequester(initialFocus)
                            .testTag(HomeDrawerTags.NEW_SESSION)
                            .semantics { contentDescription = newSessionLabel },
                        shape = RoundedCornerShape(26.dp),
                        colors = ButtonDefaults.buttonColors(
                            containerColor = tokens.colors.surface,
                            contentColor = tokens.colors.textPrimary,
                            disabledContainerColor = tokens.colors.surface.copy(alpha = 0.55f),
                            disabledContentColor = tokens.colors.textPlaceholder,
                        ),
                        border = BorderStroke(0.5.dp, tokens.colors.borderList),
                        contentPadding = PaddingValues(horizontal = 12.dp, vertical = 0.dp),
                    ) {
                        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.Center) {
                            PdshIconView(PdshIcon.NEW_CHAT_PLUS, 20.dp,
                                if (enabled) tokens.colors.textPrimary else tokens.colors.textPlaceholder, null)
                            Spacer(Modifier.width(10.dp))
                            Text(newSessionLabel, style = type.body.copy(fontSize = 17.sp, fontWeight = FontWeight.Medium))
                        }
                    }
                    Box(
                        Modifier.fillMaxWidth().padding(top = 6.dp).height(DRAWER_NEW_SESSION_REASON_HEIGHT),
                        contentAlignment = Alignment.Center,
                    ) {
                        NewSessionReasonLine(
                            reason = blockedReason,
                            style = type.caption.copy(fontSize = 13.sp, color = tokens.colors.textSecondary),
                        )
                    }
                }
                Spacer(Modifier.height(16.dp))
                if (DRAWER_FOLDERS_ENABLED) Row(Modifier.fillMaxWidth().height(36.dp).padding(start = HomeMetrics.CONTENT_INSET_PT.dp, end = 12.dp), verticalAlignment = Alignment.CenterVertically) {
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
                    val folders = stableFolders
                    if (folders == null) {
                        Text("文件夹列表未知", Modifier.padding(horizontal = HomeMetrics.CONTENT_INSET_PT.dp, vertical = 8.dp), style = type.secondary.copy(color = tokens.colors.textSecondary))
                    } else if (DRAWER_FOLDERS_ENABLED && folders.isEmpty() && stableLoose.isNullOrEmpty()) {
                        Text("还没有文件夹。点右上角的 + 新建一个，文件夹用于整理会话；文件仍使用工作区。", Modifier.padding(horizontal = HomeMetrics.CONTENT_INSET_PT.dp, vertical = 8.dp), style = type.secondary.copy(color = tokens.colors.textSubtle))
                    }
                    val defaultFolder = folders?.firstOrNull { it.isDefault }
                    val loose = stableLoose
                    val looseTitle = drawerDefaultFolderTitle(facts.languageId)
                    if (folders == null && loose != null && loose.isNotEmpty()) {
                        FolderGroup("__unknown_folder__", looseTitle, loose, state,
                            onOpenSession, canRenameSession = onMutation != null, onArchiveSession, pendingArchiveIds,
                            archiveFailureById, ::archiveSession, canRenameFolder = false, canDeleteFolder = false,
                            onNewSessionInFolder = null,
                            emptyMessage = "还没有会话",
                            onRequestRename = { _, _ -> }, onRequestDelete = { _ -> },
                            onRequestRenameSession = { id, name -> targetId = id; draft = name; dialog = "rename-session" },
                            activeSessionId = facts.activeSessionId)
                    }
                    if (folders != null && defaultFolder == null && loose != null && loose.isNotEmpty()) {
                        FolderGroup("__unassigned__", looseTitle, loose, state,
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
                        val sessions = homeDrawerSessionsInHeldOrder(
                            if (folder === defaultFolder || folder.id == defaultFolder?.id) {
                                folder.sessions + (loose ?: emptyList())
                            } else folder.sessions,
                            sessionRank,
                        )
                        val folderIndex = (folders.orEmpty().indexOfFirst { it.id == folder.id } + 1).coerceAtLeast(1)
                        val folderTitle = if (folder.isDefault) {
                            workspaceTitle(folder.title, folderIndex, facts.languageId)
                        } else {
                            folder.title.ifBlank { "文件夹" }
                        }
                        FolderGroup(folder.id, folderTitle, sessions, state,
                            onOpenSession, canRenameSession = onMutation != null, onArchiveSession, pendingArchiveIds,
                            archiveFailureById, ::archiveSession,
                            canRenameFolder = DRAWER_FOLDERS_ENABLED && onMutation != null,
                            canDeleteFolder = DRAWER_FOLDERS_ENABLED && onMutation != null && !folder.isDefault,
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

/**
 * Folder management (the 文件夹 title, 新建文件夹, the empty-folder hint, folder
 * rename/delete) is not offered yet, matching iOS `HomeDrawer.foldersEnabled`.
 * Session groups such as 手机工作区 still show.
 */
internal const val DRAWER_FOLDERS_ENABLED: Boolean = false

/** One 13sp reason line, laid out even when there is no reason to show. */
private val DRAWER_NEW_SESSION_REASON_HEIGHT = 20.dp
private const val DRAWER_NEW_SESSION_REASON_FADE_MS = 150

/**
 * The contract's drawer shadow: black at the token opacity, SwiftUI blur radius
 * and x/y offset. Compose's `shadow()` has no offset, so the drawing site maps
 * the token's four values directly instead of pretending they equal an elevation.
 */
private fun Modifier.drawerShadow(shadow: UiShadow, shape: Shape): Modifier = drawBehind {
    val drawScope = this
    val path = Path().apply { addOutline(shape.createOutline(size, layoutDirection, drawScope)) }
    val paint = Paint().apply {
        color = Color.Black
        isAntiAlias = true
    }
    paint.asFrameworkPaint().setShadowLayer(
        shadow.drawerRadius.toPx(),
        shadow.drawerX.toPx(),
        shadow.drawerY.toPx(),
        Color.Black.copy(alpha = shadow.drawerOpacity).toArgb(),
    )
    drawIntoCanvas { canvas -> canvas.drawPath(path, paint) }
}

/**
 * Drag rule 3/4/6: start only after the contract's 12 dp Euclidean distance,
 * follow horizontally dominant movement, and release through the shared rule.
 * Vertical-dominant movement stays unconsumed so the inner list keeps scrolling.
 */
private suspend fun PointerInputScope.drawerDrag(
    dragMinimumDistance: Dp,
    initialOffset: () -> Float,
    onOffset: (Float) -> Unit,
    onRelease: (dx: Float, velocity: Float) -> Unit,
    onTap: (() -> Unit)? = null,
) {
    awaitEachGesture {
        val down = awaitFirstDown(requireUnconsumed = false)
        val tracker = VelocityTracker()
        tracker.addPosition(down.uptimeMillis, down.position)
        var total = Offset.Zero
        var started = false
        var followed = false
        var lastOffset = 0f
        while (true) {
            val event = awaitPointerEvent()
            val change = event.changes.firstOrNull { it.id == down.id } ?: break
            tracker.addPosition(change.uptimeMillis, change.position)
            if (!change.pressed) {
                if (followed) {
                    onRelease(total.x / density, tracker.calculateVelocity().x / density)
                } else if (!started && onTap != null) {
                    onTap()
                }
                break
            }
            total += change.positionChange()
            if (!started && total.getDistance() >= dragMinimumDistance.toPx()) {
                started = true
                lastOffset = initialOffset()
            }
            if (!started) continue
            if (abs(total.x) <= abs(total.y)) continue
            followed = true
            lastOffset = DrawerGesture.followOffset(total.x / density, total.y / density, lastOffset)
            onOffset(lastOffset)
            change.consume()
        }
    }
}

public object HomeDrawerTags {
    public const val PANEL = "home.drawer.panel"
    public const val SCRIM = "home.drawer.scrim"
    public const val NEW_SESSION = "home.drawer.new-session"
    public const val NEW_SESSION_REASON = "home.drawer.new-session.reason"
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
            if (DRAWER_FOLDERS_ENABLED) {
                DropdownMenuItem(text = { Text("重命名") }, enabled = canRenameFolder,
                    onClick = { folderMenu = false; onRequestRename(id, title) })
                DropdownMenuItem(text = { Text("删除文件夹") }, enabled = canDeleteFolder,
                    onClick = { folderMenu = false; onRequestDelete(id) })
            }
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
                // A running spinner and a relative time have different widths;
                // reserving one trailing slot keeps the title from reflowing
                // when a row starts or finishes a turn.
                Box(Modifier.width(64.dp), contentAlignment = Alignment.CenterEnd) {
                    if (pendingArchive) CircularProgressIndicator(Modifier.size(14.dp).testTag(HomeDrawerTags.ARCHIVE_PENDING_PREFIX + session.id), strokeWidth = 1.5.dp)
                    else if (session.running) CircularProgressIndicator(Modifier.size(14.dp), strokeWidth = 1.5.dp)
                    else session.relativeTime?.let { Text(it, style = type.caption.copy(color = tokens.colors.textPlaceholder), maxLines = 1) }
                }
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

/** The reason line fades in and out inside a fixed-height slot; no reason = no node. */
@Composable
private fun NewSessionReasonLine(reason: String?, style: TextStyle) {
    AnimatedVisibility(
        visible = reason != null,
        enter = fadeIn(animationSpec = tween(durationMillis = DRAWER_NEW_SESSION_REASON_FADE_MS)),
        exit = fadeOut(animationSpec = tween(durationMillis = DRAWER_NEW_SESSION_REASON_FADE_MS)),
    ) {
        Text(
            reason.orEmpty(),
            modifier = Modifier.fillMaxWidth().testTag(HomeDrawerTags.NEW_SESSION_REASON),
            style = style,
            textAlign = TextAlign.Center,
            maxLines = 1,
        )
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
