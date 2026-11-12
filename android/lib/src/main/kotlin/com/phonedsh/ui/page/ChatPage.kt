// Chat page: page head, failure banners, pending cards, transcript, composer dock.
// SPDX-License-Identifier: MIT
@file:OptIn(androidx.compose.foundation.ExperimentalFoundationApi::class)
//
// Mirror: `examples/probe-app/PhoneDSHProbe/ChatPage.swift` (the page body, the
// transcript chrome, the composer dock), `NativeShell.swift` (`NativeHeaderStyle`
// and `RunStatusDot`) and `NativeMessageRows.swift` (the rows, via `ChatRows.kt`).
// The clause order is the iOS `body`'s: head, then the three failure banners,
// then the pending-card region, then the transcript; the composer is the bottom
// inset, not a stack item (spec §5 row `ime`).
//
// The page owns no screen state. Everything it shows comes from
// [ChatScreenState] (`ChatScreenState.from` is a pure function of the UiState
// sequence, the local UI events and the read-only host facts), including the
// composer lock reason, the pending-answer fold and the banners. The two platform
// observations it does make — IME visibility and the screen height — are reported
// upward (`onImeVisibleChange`) and read for a max-height clamp; neither is stored
// here, so a JVM replay of the state reaches the same screen. The only local
// `remember`s are the ones iOS also keeps as `@State` and that are not engine
// facts: an open menu, the rename dialog's text and one pending access-mode
// confirmation.
//
// Insets (§5 row `insets`): targetSdk 35 forces edge-to-edge, so the page consumes
// the insets explicitly — status bar above the header, navigation bar and IME
// below the composer, horizontal insets on the root. Nothing is drawn under a
// system bar.
//
// Geometry: the page-level tokens (`pageOuterMarginH`, `pageHeaderMinHeight`,
// `pageRowMinHeight`, `pageListRowMinHeight`, `statusDotDiameter`) are read where
// the iOS page reads its literal. Several lengths iOS types have no page-level
// token, so the closest token a signature surface declares is borrowed and marked
// `unverified geometry` at the use site (banner/card/composer geometry, the
// primary-button height reused as the tail padding and the 88 pt empty-state
// offset, the bubble max width reused as the empty-state column width).
//
// The 402 pt parity yardstick (official header 50 / composer 370x98 / content
// column 338 / tool row 24 / flow gaps 6-12) is owned by
// `com.phonedsh.ui.UiMetrics`, not by this page: it describes what the official UI
// shows, while this page draws the iOS app's lengths. Read it when measuring a
// capture, not when changing a layout.
package com.phonedsh.ui.page

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.WindowInsetsSides
import androidx.compose.foundation.layout.defaultMinSize
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.ime
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.only
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawing
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.gestures.animateScrollBy
import androidx.compose.foundation.gestures.scrollBy
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyListState
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicText
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.derivedStateOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.snapshotFlow
import androidx.compose.runtime.withFrameNanos
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.input.key.Key
import androidx.compose.ui.input.key.KeyEvent
import androidx.compose.ui.input.key.KeyEventType
import androidx.compose.ui.input.key.key
import androidx.compose.ui.input.key.onPreviewKeyEvent
import androidx.compose.ui.input.key.type
import androidx.compose.ui.graphics.isSpecified
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.platform.LocalSoftwareKeyboardController
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.phonedsh.agentcore.JsonArray
import com.phonedsh.agentcore.JsonObject
import com.phonedsh.agentcore.JsonString
import com.phonedsh.agentcore.JsonValue
import com.phonedsh.ui.ChatMetrics
import com.phonedsh.ui.HomeMetrics
import com.phonedsh.ui.UiMetrics
import com.phonedsh.ui.UiStrings
import com.phonedsh.ui.UiTags
import com.phonedsh.ui.icon.PdshIcon
import com.phonedsh.ui.icon.PdshIconView
import com.phonedsh.ui.nav.PdshActionAvailability
import com.phonedsh.ui.nav.PdshUnavailableReason
import com.phonedsh.ui.projection.CanonicalJson
import com.phonedsh.ui.state.AccessModeOption
import com.phonedsh.ui.state.ChatEmpty
import com.phonedsh.ui.state.ChatPhase
import com.phonedsh.ui.state.ChatRow
import com.phonedsh.ui.state.ChatScreenState
import com.phonedsh.ui.state.ComposerCommand
import com.phonedsh.ui.state.GoalBarState
import com.phonedsh.ui.state.ManagedQueueItemState
import com.phonedsh.ui.state.QueueItemId
import com.phonedsh.ui.state.QueueItemStatus
import com.phonedsh.ui.state.StateRequestId
import com.phonedsh.ui.state.PendingAnswer
import com.phonedsh.ui.state.PendingQuestionItem
import com.phonedsh.ui.state.PendingQuestionOption
import com.phonedsh.ui.state.PendingFold
import com.phonedsh.ui.state.PendingSlot
import com.phonedsh.ui.state.ReferenceMenu
import com.phonedsh.ui.state.RunStatus
import com.phonedsh.ui.state.SlashMenu
import com.phonedsh.ui.state.TodoDockItem
import com.phonedsh.ui.state.reconcileQueueRows
import com.phonedsh.ui.surface.Composer
import com.phonedsh.ui.composer.ComposerSendRule
import com.phonedsh.ui.disclosure.PdshChevron
import com.phonedsh.ui.disclosure.PdshDisclosure
import com.phonedsh.ui.surface.composer.ComposerToolbar
import com.phonedsh.ui.surface.composer.ComposerAvailability
import com.phonedsh.ui.surface.FoldedPendingRow
import com.phonedsh.ui.surface.MarkdownBody
import com.phonedsh.ui.theme.LocalUiTokens
import com.phonedsh.ui.theme.materialDialogColors
import com.phonedsh.ui.theme.LocalUiType
import com.phonedsh.ui.theme.generated.UiTokenNames
import kotlinx.coroutines.flow.first
import kotlin.math.abs
import kotlinx.coroutines.launch

/**
 * The chat screen.
 *
 * @param state the pure screen state (`ChatScreenState.from`).
 * @param onDraftChange draft edits.
 * @param onSend send the draft.
 * @param onStop stop the running turn.
 * @param onToggleRow expand/collapse a tool entry or a thinking pill.
 * @param onApprove answer a pending permission ask (allow once).
 * @param onDeny decline a pending ask.
 * @param onDismissBanner dismiss the top failure banner.
 * @param onRetry retry the failed turn.
 * @param onOpenSessions open the sessions drawer.
 * @param title the session title; empty falls back to the product name.
 * @param onGoalPause pause the visible goal; `null` hides the action.
 * @param onGoalResume resume a paused/blocked goal; `null` hides the action.
 * @param onGoalClear clear the goal; `null` hides the action.
 * @param onOpenGoalDetail open the goal detail sheet; `null` hides the affordance.
 * @param onImeVisibleChange reports IME visibility so the host can feed it into
 *   `ChatLocalState.imeVisible`; the page never stores it (spec §3.1 rule 3).
 * @param onExpandPendingSlot the user tapped the folded slot while the keyboard is
 *   up; the host records `pendingSlotExpanded = true`.
 * @param onRenameSession the title was edited; the dialog passes the trimmed name
 *   and an empty string means "cancelled edit" (iOS keeps the old title).
 * @param onExportTranscript the page-head menu's 导出对话记录 (a share-sheet
 *   action, spec §5 `share-sheet`; the host owns the platform panel).
 * @param onOpenArtifacts the page-head menu's 产物 (`ChatPage.swift:256`); `null`
 *   hides the row, because the artifacts sheet is scoped to one session and this
 *   page never learns a session id from its state.
 * @param onOpenWorkbench the page-head menu's 右侧边栏 (`ChatPage.swift:260`, the
 *   baseline's `showWorkbench`); `null` hides the row for the same reason.
 * @param onOpenRunStatus the run-status dot and the menu's 运行状态 were tapped
 *   (iOS `RuntimeDetailsPage`, `ChatPage.swift:270`).
 * @param onOpenSessionSettings the page-head menu's 本会话设置.
 * @param onStartEngine the empty state's 启动本地引擎.
 * @param onConfigureProvider the empty state's 去配置模型服务.
 * @param onLoadEarlier the transcript's 加载更早消息.
 * @param onSubmitAnswer submit a question card's answer as the JSON the iOS
 *   question composer builds (`{"<item>": ["a","b"]}`; skipped items use `[]`).
 * @param onDismissQuestion discard/close the active question through its owning
 *   host channel; the page does not infer a denial from this action.
 * @param onRemoveAttachment remove one pending attachment by index.
 * @param onAddImages the composer's 添加图片.
 * @param onAddFiles the composer's 添加文件（写入工作区）.
 * @param onSelectAccessMode pick an access mode by id.
 * @param onSelectModel pick a model and an optional reasoning effort.
 * @param onPickCommand write a `/command` into the draft (iOS `pickCommand`).
 * @param onPickReference write an `@path` or `@session` into the draft.
 * @param onDismissComposerNotice close the attachment or import notice.
 * @param onRetryAccessModes retry the permissions read.
 * @param onReloadCommands retry the command-catalog read.
 * @param onOpenFile a workspace-relative path a row wants to open (the tool row's
 *   file chip and an attachment's file chip). The page never navigates itself: the
 *   host routes it (workbench preview, file list) exactly like `onPickCommand`.
 * @param jobs the session's background jobs, or `null` when the host made no read.
 *   The page-head menu's 后台任务（N） row (`ChatPage.swift:247`) exists only while
 *   this list has rows, so a facts-only host renders no row instead of a sheet that
 *   could only say 读取不到.
 * @param schedules the session's scheduled tasks, same contract (`:252`).
 * @param onOpenJobs opens the 后台任务 sheet (its route); `null` hides the row.
 * @param onOpenSchedules opens the 定时任务 sheet; `null` hides the row.
 * @param subagents the current Worker's measured `subagentCatalog`; `null` means it was not reported.
 * @param onOpenSubagentSession opens one verified Worker subagent session; `null` hides the catalog row.
 */
@Composable
public fun ChatPage(
    state: ChatScreenState,
    onDraftChange: (String) -> Unit,
    onSend: () -> Unit,
    onStop: () -> Unit,
    onToggleRow: (String) -> Unit,
    onApprove: (PendingAnswer) -> Unit,
    onDeny: (PendingAnswer) -> Unit,
    onDismissBanner: (String) -> Unit,
    onRetry: () -> Unit,
    onOpenSessions: () -> Unit,
    modifier: Modifier = Modifier,
    title: String = "",
    onGoalPause: (() -> Unit)? = null,
    onGoalResume: (() -> Unit)? = null,
    onGoalClear: (() -> Unit)? = null,
    onOpenGoalDetail: (() -> Unit)? = null,
    onImeVisibleChange: ((Boolean) -> Unit)? = null,
    onExpandPendingSlot: () -> Unit = {},
    onRenameSession: (String) -> Unit = {},
    onExportTranscript: () -> Unit = {},
    onOpenArtifacts: (() -> Unit)? = null,
    onOpenWorkbench: (() -> Unit)? = null,
    onOpenRunStatus: () -> Unit = {},
    onOpenDeviceConnections: () -> Unit = {},
    onOpenSessionSettings: () -> Unit = {},
    onStartEngine: () -> Unit = {},
    onRestartEngine: () -> Unit = {},
    onConfigureProvider: (() -> Unit)? = null,
    onLoadEarlier: (() -> Unit)? = null,
    onSubmitAnswer: (PendingAnswer, String) -> Unit = { _, _ -> },
    onDismissQuestion: (PendingAnswer) -> Unit = {},
    onRemoveAttachment: (Int) -> Unit = {},
    onAddImages: () -> Unit = {},
    onAddFiles: () -> Unit = {},
    onSelectAccessMode: (String) -> Unit = {},
    onSelectModel: (String, String?) -> Unit = { _, _ -> },
    onPickCommand: (String) -> Unit = {},
    onExecuteCommand: ((String) -> Unit)? = null,
    onPickReference: (String) -> Unit = {},
    onDismissComposerNotice: () -> Unit = {},
    onRetryAccessModes: () -> Unit = {},
    onReloadCommands: () -> Unit = {},
    onOpenFile: ((String) -> Unit)? = null,
    /** Opens a host-resolved resource URI exactly as received from markdown. */
    onOpenResource: ((String) -> Unit)? = null,
    /** Safe current-workspace and session-scoped Markdown image sources. */
    imageSource: com.phonedsh.ui.surface.MarkdownImageSource? = null,
    /** A real host callback is required before the stopped-engine CTA is enabled. */
    startEngineAvailability: PdshActionAvailability<() -> Unit> = PdshActionAvailability.Unavailable(PdshUnavailableReason.NOT_IMPLEMENTED),
    /** Request-bound permission decision capabilities; absent receipts stay disabled. */
    permissionApproveAvailability: PdshActionAvailability<(PendingAnswer) -> Unit> = PdshActionAvailability.Unavailable(PdshUnavailableReason.NOT_IMPLEMENTED),
    permissionDenyAvailability: PdshActionAvailability<(PendingAnswer) -> Unit> = PdshActionAvailability.Unavailable(PdshUnavailableReason.NOT_IMPLEMENTED),
    /** Request-bound approval of a question's explicit plan-review action. */
    planApproveAvailability: PdshActionAvailability<(PendingAnswer, String) -> Unit> = PdshActionAvailability.Unavailable(PdshUnavailableReason.NOT_IMPLEMENTED),
    /** Request-bound request-changes action for plan review. */
    planRequestChangesAvailability: PdshActionAvailability<(PendingAnswer) -> Unit> = PdshActionAvailability.Unavailable(PdshUnavailableReason.NOT_IMPLEMENTED),
    jobs: List<ChatJobRow>? = null,
    schedules: List<ChatScheduleRow>? = null,
    onOpenJobs: (() -> Unit)? = null,
    onOpenSchedules: (() -> Unit)? = null,
    /** Host-reported workspace collapse timing; null stays unknown. */
    collapseTiming: CollapseTiming? = null,
    /** Writes the selection; null keeps both choices disabled. */
    onSetCollapseTiming: ((CollapseTiming) -> Unit)? = null,
    /** Explicit host routes; missing capability remains unavailable. */
    composerAvailability: ComposerAvailability = ComposerAvailability(),
    /** Reads the most recent assistant reply aloud when the host supplies a route. */
    onSpeakRecentReply: (() -> Unit)? = null,
    /** RETRY is available only when the host can retry the failed request itself. */
    timelineRetryAvailability: PdshActionAvailability<() -> Unit> = PdshActionAvailability.Unavailable(PdshUnavailableReason.NOT_IMPLEMENTED),
    /** Request-bound queue edits; durable ids and receipts remain host-owned. */
    queueEditAvailability: PdshActionAvailability<(ManagedQueueItemState, String, StateRequestId) -> Unit> = PdshActionAvailability.Unavailable(PdshUnavailableReason.NOT_IMPLEMENTED),
    queueRemoveAvailability: PdshActionAvailability<(ManagedQueueItemState, StateRequestId) -> Unit> = PdshActionAvailability.Unavailable(PdshUnavailableReason.NOT_IMPLEMENTED),
    queueSteerAvailability: PdshActionAvailability<(ManagedQueueItemState, StateRequestId) -> Unit> = PdshActionAvailability.Unavailable(PdshUnavailableReason.NOT_IMPLEMENTED),
    /** Request-bound QUEUE action used when a running turn receives a queued prompt. */
    queueSubmissionAvailability: PdshActionAvailability<(String, StateRequestId) -> Unit> = PdshActionAvailability.Unavailable(PdshUnavailableReason.NOT_IMPLEMENTED),
    /** Request-bound STEER action used when the active turn accepts follow-up text. */
    steerSubmissionAvailability: PdshActionAvailability<(String, StateRequestId) -> Unit> = PdshActionAvailability.Unavailable(PdshUnavailableReason.NOT_IMPLEMENTED),
    /** Request-bound STOP action; unavailable stop controls are not clickable. */
    stopAvailability: PdshActionAvailability<(StateRequestId) -> Unit> = PdshActionAvailability.Unavailable(PdshUnavailableReason.NOT_IMPLEMENTED),
    /** Current Worker subagent projection; null means it was not reported. */
    subagents: List<ChatSubagentEntry>? = null,
    /** Opens a subagent only after the host confirms its Worker identity/history. */
    onOpenSubagentSession: (suspend (ChatSubagentEntry) -> String?)? = null,
) {
    val tokens = LocalUiTokens.current
    val boundTimelineRetry = (timelineRetryAvailability as? PdshActionAvailability.Available)?.callback
    // `colors.background` is tier: unmeasured (a dynamic system colour), so an
    // unspecified value leaves the platform surface in place instead of an
    // invented sRGB fill.
    val surface = if (tokens.colors.background.isSpecified) {
        Modifier.background(tokens.colors.background)
    } else {
        Modifier
    }
    // A platform observation, reported upward and never stored in the page: the
    // fold itself is ScreenState (`ChatScreenState.pendingFold`).
    val imeVisible = WindowInsets.ime.getBottom(LocalDensity.current) > 0
    val reportIme = onImeVisibleChange
    LaunchedEffect(imeVisible) { reportIme?.invoke(imeVisible) }

    // The rename alert is drawn in the page, NOT because a system dialog would be
    // wrong: a Compose `AlertDialog` + text field never settles under Robolectric
    // (its cursor frame loop keeps the test harness from going idle, measured as a
    // 60 s AppNotIdleException), so this alert is the same content in an in-page
    // scrim. That is a *test-harness* limitation, not an interaction choice — on a
    // device a platform dialog would be fine. The content, the two verbs and the
    // trimming are the iOS alert's (`ChatPage.swift` `.alert("重命名会话")`).
    var renaming by remember { mutableStateOf(false) }
    var subagentCatalogOpen by remember { mutableStateOf(false) }
    var queueEditItem by remember { mutableStateOf<ManagedQueueItemState?>(null) }
    var queueEditDraft by remember { mutableStateOf("") }
    var queueEditNotice by remember { mutableStateOf<String?>(null) }
    // The row can be claimed by the running turn while its editor is open. DSH
    // closes that editor instead of letting a save silently hit no row.
    LaunchedEffect(queueEditItem?.id, state.queueItems) {
        val editing = queueEditItem ?: return@LaunchedEffect
        if (state.queueItems.orEmpty().none { it.id == editing.id }) {
            queueEditItem = null
            queueEditNotice = UiStrings.CHAT_QUEUE_EDIT_ITEM_GONE
        }
    }
    // iOS `ChatPage.swift:145-154 sessionTitle`: a real session name wins; a
    // conversation that already has a user turn reads 当前会话; only a fresh one
    // reads 新会话. The page used to fall back to the *product name* ("PDSH"), so
    // every real conversation was headed with the app's own name — a word the
    // baseline never paints there. A title that is the store's generic default is
    // not a name (iOS checks the same two strings).
    val headerTitle = remember(title, state.rows) {
        val generic = title.isEmpty() ||
            title == UiStrings.NEW_SESSION ||
            title == UiStrings.SESSION_TITLE_NEW ||
            title.equals("new conversation", ignoreCase = true) ||
            title.equals("conversation", ignoreCase = true)
        if (!generic) {
            title
        } else if (state.rows.any { it is ChatRow.User }) {
            UiStrings.SESSIONS_CURRENT
        } else {
            UiStrings.NEW_SESSION
        }
    }
    Box(modifier = modifier.fillMaxSize().then(surface).testTag(UiTags.CHAT_ROOT)) {
    Column(
        modifier = Modifier
            .fillMaxSize()
            // Edge-to-edge: the vertical bars are consumed by the header and the
            // dock; the horizontal ones are page-wide (landscape nav bar).
            .windowInsetsPadding(WindowInsets.safeDrawing.only(WindowInsetsSides.Horizontal)),
    ) {
        ChatHeader(
            title = headerTitle,
            onOpenSessions = onOpenSessions,
            onStartRename = { renaming = true },
            onOpenRunStatus = onOpenRunStatus,
            onOpenDeviceConnections = onOpenDeviceConnections,
            hasOnlineDevices = state.hasOnlineDevices,
            onExportTranscript = onExportTranscript,
            onOpenArtifacts = onOpenArtifacts,
            onOpenWorkbench = onOpenWorkbench,
            onOpenSessionSettings = onOpenSessionSettings,
            jobs = jobs,
            schedules = schedules,
            onOpenJobs = onOpenJobs,
            onOpenSchedules = onOpenSchedules,
            subagents = subagents,
            onOpenSubagentCatalog = if (!subagents.isNullOrEmpty() && onOpenSubagentSession != null) {
                { subagentCatalogOpen = true }
            } else null,
            collapseTiming = collapseTiming,
            onSetCollapseTiming = onSetCollapseTiming,
        )
        if (subagentCatalogOpen && !subagents.isNullOrEmpty()) {
            onOpenSubagentSession?.let { openSession ->
                SubagentCatalogDialog(
                    entries = subagents,
                    currentWorkerSessionId = state.workerSessionID,
                    onDismiss = { subagentCatalogOpen = false },
                    onOpen = openSession,
                )
            }
        }
        // A failure that belongs to one row is rendered under it; every other
        // failure owns the top banner (iOS body: `failedItemID == nil` first).
        // The engine-stopped line is suppressed while the no-engine empty state
        // is already on screen (the empty card says the same thing).
        if (shouldShowChatFailureBanner(state)) {
            val retryable = state.banners.firstOrNull()?.retryable == true
            TopFailureBanner(
                message = state.userFacingError.orEmpty(),
                onRetry = if (retryable) boundTimelineRetry else null,
                onRestart = if (state.lifecycle?.needsReset == true) onRestartEngine else null,
                onDismiss = { state.banners.firstOrNull()?.let { onDismissBanner(it.id) } },
            )
        }
        // The access-mode read retries itself (ProbeEngineViewModel); its state
        // lives on the composer control and in its menu, never as a page banner.
        if (state.commandsError != null) {
            NoticeBanner(
                glyph = COMMAND_GLYPH,
                message = state.commandsError,
                retryLabel = UiStrings.RETRY,
                onRetry = onReloadCommands,
                tag = UiPageTags.CHAT_BANNER_COMMANDS,
            )
        }
        // The card region sits between the banners and the transcript, and never
        // takes more than 40% of the screen (iOS `cardsRegion`).
        // unverified geometry: the approval card's own `cardAreaMaxHeightRatio`
        // borrowed by the page to clamp the region that holds it.
        val screenHeight = LocalConfiguration.current.screenHeightDp.dp
        PendingCardsRegion(
            slot = state.pending,
            fold = state.pendingFold,
            onExpand = onExpandPendingSlot,
            approveAvailability = permissionApproveAvailability,
            denyAvailability = permissionDenyAvailability,
            maxHeight = screenHeight * tokens.geometry.cardAreaMaxHeightRatio,
        )
        Box(modifier = Modifier.weight(1f).fillMaxWidth()) {
            ChatTranscript(
                state = state,
                onToggleRow = onToggleRow,
                onLoadEarlier = onLoadEarlier,
                startEngineAvailability = startEngineAvailability,
                onConfigureProvider = onConfigureProvider,
                onRetry = onRetry,
                onOpenFile = onOpenFile,
                onOpenResource = onOpenResource,
                imageSource = imageSource,
                retryAvailability = timelineRetryAvailability,
            )
        }
        Box(
            modifier = Modifier
                .fillMaxWidth()
                // IME + navigation bar: the dock is always above the keyboard.
                .navigationBarsPadding()
                .imePadding(),
        ) {
            ComposerDock(
                state = state,
                imageSource = imageSource,
                onDraftChange = onDraftChange,
                onSend = onSend,
                onGoalPause = onGoalPause,
                onGoalResume = onGoalResume,
                onGoalClear = onGoalClear,
                onOpenGoalDetail = onOpenGoalDetail,
                onSubmitAnswer = onSubmitAnswer,
                onDismissQuestion = onDismissQuestion,
                onRemoveAttachment = onRemoveAttachment,
                onAddImages = onAddImages,
                onAddFiles = onAddFiles,
                onSelectAccessMode = onSelectAccessMode,
                onRetryAccessModes = onRetryAccessModes,
                onSelectModel = onSelectModel,
                onPickCommand = onPickCommand,
                onExecuteCommand = onExecuteCommand,
                onPickReference = onPickReference,
                onDismissNotice = onDismissComposerNotice,
                onReloadCommands = onReloadCommands,
                availability = composerAvailability,
                onSpeakRecentReply = onSpeakRecentReply,
                planApproveAvailability = planApproveAvailability,
                planRequestChangesAvailability = planRequestChangesAvailability,
                queueEditAvailability = queueEditAvailability,
                queueRemoveAvailability = queueRemoveAvailability,
                queueSteerAvailability = queueSteerAvailability,
                queueSubmissionAvailability = queueSubmissionAvailability,
                steerSubmissionAvailability = steerSubmissionAvailability,
                stopAvailability = stopAvailability,
                onEditQueueItem = { item ->
                    queueEditNotice = null
                    queueEditItem = item
                    queueEditDraft = item.text
                },
                queueEditNotice = queueEditNotice,
                onDismissQueueEditNotice = { queueEditNotice = null },
            )
        }
    }
    }
    if (renaming) {
        RenameSessionOverlay(
            title = headerTitle,
            onCancel = { renaming = false },
            onSave = { name ->
                renaming = false
                onRenameSession(name)
            },
        )
    }
    queueEditItem?.let { item ->
        QueueEditOverlay(
            item = item,
            value = queueEditDraft,
            onValueChange = { queueEditDraft = it },
            onCancel = { queueEditItem = null },
            onSave = {
                val text = queueEditDraft.trim()
                val callback = (queueEditAvailability as? PdshActionAvailability.Available)?.callback
                val stillQueued = state.queueItems.orEmpty().any { it.id == item.id }
                when {
                    !stillQueued -> {
                        queueEditItem = null
                        queueEditNotice = UiStrings.CHAT_QUEUE_EDIT_ITEM_GONE
                    }
                    text.isNotEmpty() && item.canEdit == true && !queueActionPending(item) && callback != null -> {
                        callback(item, text, nextQueueActionRequestId())
                        queueEditItem = null
                    }
                }
            },
            canSave = queueEditDraft.trim().isNotEmpty() && item.canEdit == true && !queueActionPending(item) &&
                queueEditAvailability is PdshActionAvailability.Available,
        )
    }
}

/**
 * The rename alert's content: the old title pre-filled, 取消 and 保存, and an empty
 * name is not saved (iOS `guard !title.isEmpty`).
 */
@Composable
private fun RenameSessionOverlay(
    title: String,
    onCancel: () -> Unit,
    onSave: (String) -> Unit,
) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    var draft by remember(title) { mutableStateOf(title) }
    Box(
        modifier = Modifier
            .fillMaxSize()
            .testTag(UiPageTags.CHAT_RENAME_OVERLAY),
        contentAlignment = Alignment.Center,
    ) {
        // The dimmed area is the tap-outside-to-cancel target. It is a sibling of
        // the dialog, not its wrapper, so the dialog's title stays a title instead
        // of becoming the scrim's click label (iOS `.alert`).
        Box(
            modifier = Modifier
                .fillMaxSize()
                .background(tokens.colors.primary.copy(alpha = SCRIM_ALPHA))
                .clickable(role = Role.Button, onClick = onCancel),
        )
        Column(
            modifier = Modifier
                .padding(horizontal = tokens.geometry.pageOuterMarginH)
                .fillMaxWidth()
                .background(tokens.colors.input, RoundedCornerShape(tokens.radius.card))
                .semantics { contentDescription = UiStrings.RENAME_DIALOG_TITLE }
                .padding(tokens.geometry.cardPadding),
            verticalArrangement = Arrangement.spacedBy(tokens.geometry.bannerGap),
        ) {
            BasicText(
                text = UiStrings.RENAME_DIALOG_TITLE,
                style = type.headline.copy(color = tokens.colors.primary),
                modifier = Modifier.semantics { heading() },
            )
            BasicTextField(
                value = draft,
                onValueChange = { draft = it },
                textStyle = type.secondary.copy(color = tokens.colors.primary),
                cursorBrush = SolidColor(tokens.colors.accent),
                modifier = Modifier
                    .fillMaxWidth()
                    .testTag(UiPageTags.CHAT_RENAME_FIELD),
                decorationBox = { inner ->
                    Box {
                        if (draft.isEmpty()) {
                            BasicText(
                                text = UiStrings.RENAME_FIELD,
                                style = type.secondary.copy(color = tokens.colors.tertiary),
                            )
                        }
                        inner()
                    }
                },
            )
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(tokens.geometry.bannerGap, Alignment.End),
            ) {
                BasicText(
                    text = UiStrings.CANCEL,
                    style = type.secondary.copy(color = tokens.colors.secondary),
                    modifier = Modifier
                        .clickable(role = Role.Button, onClick = onCancel)
                        .testTag(UiPageTags.CHAT_RENAME_CANCEL)
                        .padding(tokens.spacing.iconText),
                )
                BasicText(
                    text = UiStrings.RENAME_SAVE,
                    style = type.secondary.copy(color = tokens.colors.accent),
                    modifier = Modifier
                        .clickable(role = Role.Button) {
                            val name = draft.trim()
                            if (name.isNotEmpty()) onSave(name)
                        }
                        .testTag(UiPageTags.CHAT_RENAME_SAVE)
                        .padding(tokens.spacing.iconText),
                )
            }
        }
    }
}

// ---------------------------------------------------------------------------
// Page head (ChatPage.swift `chatHeader`, NativeShell.swift `NativeHeaderStyle`)
// ---------------------------------------------------------------------------

/**
 * The iOS ChatPage header: drawer, centred title, device entry and menu.
 */
@Composable
private fun ChatHeader(
    title: String,
    onOpenSessions: () -> Unit,
    onStartRename: () -> Unit,
    onOpenRunStatus: () -> Unit,
    onOpenDeviceConnections: () -> Unit,
    hasOnlineDevices: Boolean?,
    onExportTranscript: () -> Unit,
    onOpenSessionSettings: () -> Unit,
    onOpenArtifacts: (() -> Unit)? = null,
    onOpenWorkbench: (() -> Unit)? = null,
    jobs: List<ChatJobRow>? = null,
    schedules: List<ChatScheduleRow>? = null,
    onOpenJobs: (() -> Unit)? = null,
    onOpenSchedules: (() -> Unit)? = null,
    subagents: List<ChatSubagentEntry>? = null,
    onOpenSubagentCatalog: (() -> Unit)? = null,
    collapseTiming: CollapseTiming?,
    onSetCollapseTiming: ((CollapseTiming) -> Unit)?,
) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    var menuOpen by remember { mutableStateOf(false) }
    val shape = RoundedCornerShape(50)

    Row(
        modifier = Modifier.fillMaxWidth().statusBarsPadding()
            .padding(top = HomeMetrics.navTop, start = HomeMetrics.chromeInset, end = HomeMetrics.chromeInset)
            .height(HomeMetrics.navButton),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        HeaderAction(
            description = UiStrings.HEADER_DRAWER,
            onClick = onOpenSessions,
            modifier = Modifier.size(HomeMetrics.navButton).shadow(
                    elevation = tokens.shadow.floatingRadius, shape = CircleShape,
                    ambientColor = Color.Black.copy(alpha = tokens.shadow.floatingOpacity),
                    spotColor = Color.Black.copy(alpha = tokens.shadow.floatingOpacity),
                )
                .clip(CircleShape).background(tokens.colors.surface)
                .testTag(UiPageTags.CHAT_HEADER_DRAWER),
        )
        Column(
            modifier = Modifier.weight(1f).fillMaxHeight().padding(horizontal = HomeMetrics.chromeInset)
                .clickable(enabled = title.isNotEmpty(), role = Role.Button) { onStartRename() }
                .semantics { contentDescription = title }
                .testTag(UiPageTags.CHAT_HEADER_TITLE),
            verticalArrangement = Arrangement.Center,
        ) {
            BasicText(
                text = title,
                style = type.navTitle.copy(color = tokens.colors.textPrimary),
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }
        Row(
            modifier = Modifier.size(width = HomeMetrics.navPillWidth, height = HomeMetrics.navButton)
                .shadow(
                    elevation = tokens.shadow.floatingRadius, shape = shape,
                    ambientColor = Color.Black.copy(alpha = tokens.shadow.floatingOpacity),
                    spotColor = Color.Black.copy(alpha = tokens.shadow.floatingOpacity),
                ).clip(shape).background(tokens.colors.surface),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Box(modifier = Modifier.weight(1f)) {
                DeviceHeaderAction(
                    hasOnlineDevices = hasOnlineDevices,
                    onClick = onOpenDeviceConnections,
                    modifier = Modifier.fillMaxSize().testTag(CHAT_HEADER_DEVICE_TAG),
                )
            }
            Box(modifier = Modifier.weight(1f)) {
                HeaderMenuAction(
                    onClick = { menuOpen = true },
                    modifier = Modifier.fillMaxSize().testTag(UiPageTags.CHAT_HEADER_MENU)
                        .semantics { contentDescription = "更多" },
                )
                DropdownMenu(expanded = menuOpen, onDismissRequest = { menuOpen = false }) {
                    val subagentRows = subagents
                    if (subagentRows != null && subagentRows.isNotEmpty() && onOpenSubagentCatalog != null) {
                        DropdownMenuItem(
                            text = { Text("子智能体（${subagentRows.size}）") },
                            onClick = { menuOpen = false; onOpenSubagentCatalog() },
                        )
                    }
                    val jobRows = jobs
                    if (jobRows != null && jobRows.isNotEmpty() && onOpenJobs != null) {
                        DropdownMenuItem(text = { Text("${UiStrings.CHAT_JOBS_TITLE}（${jobRows.size}）") }, onClick = { menuOpen = false; onOpenJobs() })
                    }
                    val scheduleRows = schedules
                    if (scheduleRows != null && scheduleRows.isNotEmpty() && onOpenSchedules != null) {
                        DropdownMenuItem(text = { Text("${UiStrings.CHAT_SCHEDULES_TITLE}（${scheduleRows.size}）") }, onClick = { menuOpen = false; onOpenSchedules() })
                    }
                    onOpenArtifacts?.let { action -> DropdownMenuItem(text = { Text(UiStrings.HEADER_ARTIFACTS) }, onClick = { menuOpen = false; action() }) }
                    onOpenWorkbench?.let { action -> DropdownMenuItem(text = { Text(UiStrings.HEADER_WORKBENCH) }, onClick = { menuOpen = false; action() }) }
                    DropdownMenuItem(text = { Text(UiStrings.HEADER_EXPORT) }, onClick = { menuOpen = false; onExportTranscript() })
                    DropdownMenuItem(text = { Text(UiStrings.HEADER_RUN_STATUS) }, onClick = { menuOpen = false; onOpenRunStatus() })
                    DropdownMenuItem(text = { Text(UiStrings.HEADER_SESSION_SETTINGS) }, onClick = { menuOpen = false; onOpenSessionSettings() })
                    androidx.compose.material3.HorizontalDivider()
                    DropdownMenuItem(text = { Text("折叠时机") }, onClick = {}, enabled = false)
                    CollapseTiming.entries.forEach { option ->
                        DropdownMenuItem(
                            text = { Text(option.chatMenuLabel()) },
                            onClick = {
                                onSetCollapseTiming?.invoke(option)
                                menuOpen = false
                            },
                            enabled = onSetCollapseTiming != null,
                            trailingIcon = if (collapseTiming == option) {
                                { PdshIconView(PdshIcon.CHECK, ChatMetrics.CHAT_HEADER_MORE_ICON_PT.dp, tokens.colors.textPrimary, "当前选择") }
                            } else null,
                            modifier = Modifier.testTag(collapseTimingTag(option)),
                        )
                    }
                }
            }
        }
    }
}

/**
 * One header control: its glyph, the header's 50 pt floor and its accessibility label.
 *
 * The drawer has no word on the baseline page (`accessibilityLabel` only), so the
 * control's name lives in `description`.
 */
@Composable
private fun HeaderAction(
    description: String,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val tokens = LocalUiTokens.current
    Box(
        modifier = modifier
            .defaultMinSize(minHeight = tokens.geometry.pageHeaderMinHeight)
            .clickable(role = Role.Button, onClick = onClick)
            .semantics { contentDescription = description }
            .padding(horizontal = tokens.spacing.iconText),
        contentAlignment = Alignment.Center,
    ) {
        DrawerGlyph(tokens.colors.primaryButton)
    }
}

/**
 * The page-head menu trigger: the bold ellipsis symbol in the primary ink.
 *
 * It draws a mark and nothing else. The baseline labels it `更多`
 * (`ChatPage.swift:340`).
 *
 * @param onClick opens the menu.
 * @param modifier the caller's tag, accessible name and placement.
 */
@Composable
private fun HeaderMenuAction(
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val tokens = LocalUiTokens.current
    Box(
        modifier = modifier
            .defaultMinSize(minHeight = tokens.geometry.pageHeaderMinHeight)
            .clickable(role = Role.Button, onClick = onClick)
            .padding(horizontal = tokens.spacing.iconText),
        contentAlignment = Alignment.Center,
    ) {
        PdshIconView(
            icon = PdshIcon.CHAT_MORE,
            size = ChatMetrics.CHAT_HEADER_MORE_ICON_PT.dp,
            tint = tokens.colors.primaryButton,
            contentDescription = null,
        )
    }
}

@Composable
private fun DeviceHeaderAction(
    hasOnlineDevices: Boolean?,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val tokens = LocalUiTokens.current
    Box(
        modifier = modifier.size(width = ChatMetrics.CHAT_DEVICE_ENTRY_WIDTH_PT.dp, height = tokens.geometry.pageHeaderMinHeight)
            .clickable(role = Role.Button, onClick = onClick)
            .semantics {
                contentDescription = if (hasOnlineDevices == true) "连接设备，有在线设备" else "连接设备"
            },
        contentAlignment = Alignment.Center,
    ) {
        PdshIconView(
            icon = PdshIcon.DEVICE_RADIO,
            size = ChatMetrics.CHAT_DEVICE_ICON_SIZE_PT.dp,
            tint = tokens.colors.primaryButton,
            contentDescription = null,
        )
        if (hasOnlineDevices == true) {
            Box(
                modifier = Modifier.align(Alignment.TopEnd).padding(
                    top = ChatMetrics.CHAT_DEVICE_STATUS_INSET_PT.dp,
                    end = ChatMetrics.CHAT_DEVICE_STATUS_INSET_PT.dp,
                ).size(ChatMetrics.CHAT_DEVICE_STATUS_DOT_PT.dp).clip(CircleShape)
                    .background(tokens.colors.success)
                    .border(ChatMetrics.CHAT_DEVICE_STATUS_BORDER_PT.dp, tokens.colors.page, CircleShape),
            )
        }
    }
}

@Composable
private fun DrawerGlyph(tint: Color) {
    PdshIconView(
        icon = PdshIcon.CHAT_DRAWER,
        size = ChatMetrics.CHAT_DRAWER_ICON_PT.dp,
        tint = tint,
        contentDescription = null,
    )
}

/**
 * The one run-status indicator (iOS `RunStatusDot`): an 8 pt dot plus its word.
 *
 * iOS maps parked to amber, started to green and stopped to the tertiary label;
 * those literals are `colors.warning`, `colors.success` and `colors.tertiary`.
 */
@Composable
private fun RunStatusDot(
    runStatus: RunStatus,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    val (ink, label) = when (runStatus) {
        RunStatus.STARTED -> tokens.colors.success to UiStrings.RUN_STATUS_STARTED
        RunStatus.PARKED -> tokens.colors.warning to UiStrings.RUN_STATUS_PARKED
        RunStatus.STOPPED -> tokens.colors.tertiary to UiStrings.RUN_STATUS_STOPPED
    }
    Row(
        modifier = modifier
            .clickable(role = Role.Button, onClick = onClick)
            .semantics(mergeDescendants = true) { contentDescription = label }
            .defaultMinSize(minHeight = ChatMetrics.headerHeight)
            .padding(horizontal = tokens.spacing.iconText),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(tokens.spacing.copyGap),
    ) {
        Box(
            modifier = Modifier
                .size(tokens.geometry.statusDotDiameter)
                .clip(CircleShape)
                .background(ink),
        )
        BasicText(
            text = label,
            style = type.caption.copy(color = tokens.colors.secondary),
        )
    }
}

// ---------------------------------------------------------------------------
// Failure banners (ChatPage.swift `errorBanner`, `accessModeErrorBanner`,
// `commandErrorBanner`)
// ---------------------------------------------------------------------------

/**
 * The top failure banner: the message in warning ink, an optional 重试 and the
 * xmark that dismisses it. A per-message failure never comes here; it is drawn
 * under its own row (iOS `failureLine`).
 */
@Composable
private fun TopFailureBanner(
    message: String,
    onRetry: (() -> Unit)?,
    onRestart: (() -> Unit)?,
    onDismiss: () -> Unit,
) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .testTag(UiTags.FAIL_LOUD_BANNER)
            .padding(
                horizontal = ChatMetrics.FAILURE_BANNER_INSET_H_PT.dp,
                vertical = ChatMetrics.FAILURE_BANNER_INSET_V_PT.dp,
            ),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(ChatMetrics.FAILURE_BANNER_GAP_PT.dp),
    ) {
        BasicText(
            text = message,
            style = type.caption.copy(fontSize = ChatMetrics.FAILURE_TEXT_SIZE_PT.sp, color = tokens.colors.warning),
            modifier = Modifier.weight(1f),
        )
        if (onRetry != null) {
            BasicText(
                text = UiStrings.RETRY,
                style = type.caption.copy(fontSize = ChatMetrics.FAILURE_TEXT_SIZE_PT.sp, fontWeight = androidx.compose.ui.text.font.FontWeight.SemiBold, color = tokens.colors.accent),
                modifier = Modifier
                    .clickable(role = Role.Button, onClick = onRetry)
                    .testTag(UiTags.BANNER_RETRY)
                    .padding(tokens.spacing.iconText),
            )
        }
        if (onRestart != null) {
            BasicText(
                text = UiStrings.ENGINE_RESTART,
                style = type.caption.copy(fontSize = ChatMetrics.FAILURE_TEXT_SIZE_PT.sp, fontWeight = androidx.compose.ui.text.font.FontWeight.SemiBold, color = tokens.colors.accent),
                modifier = Modifier
                    .clickable(role = Role.Button, onClick = onRestart)
                    .testTag(CHAT_RESTART_ENGINE_TAG)
                    .padding(tokens.spacing.iconText),
            )
        }
        BasicText(
            text = DISMISS_GLYPH,
            style = type.caption.copy(color = tokens.colors.secondary),
            modifier = Modifier
                .clickable(role = Role.Button, onClick = onDismiss)
                .semantics { contentDescription = UiStrings.CLOSE_HINT }
                .testTag(UiTags.BANNER_DISMISS)
                .padding(tokens.spacing.iconText),
        )
    }
}

/** The accessory-read banner: a glyph, the message and a retry verb. */
@Composable
private fun NoticeBanner(
    glyph: String,
    message: String,
    retryLabel: String,
    onRetry: () -> Unit,
    tag: String,
) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .testTag(tag)
            .padding(
                horizontal = tokens.geometry.pageOuterMarginH,
                vertical = tokens.geometry.toolDetailVertical,
            ),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(tokens.spacing.codeToolbar),
    ) {
        BasicText(text = glyph, style = type.caption.copy(color = tokens.colors.warning))
        BasicText(
            text = message,
            style = type.caption.copy(color = tokens.colors.secondary),
            modifier = Modifier.weight(1f),
        )
        BasicText(
            text = retryLabel,
            style = type.caption.copy(color = tokens.colors.accent),
            modifier = Modifier
                .clickable(role = Role.Button, onClick = onRetry)
                .padding(tokens.spacing.iconText),
        )
    }
}

// ---------------------------------------------------------------------------
// Pending cards (ChatPage.swift `cardsRegion` + `QuestionCard`)
// ---------------------------------------------------------------------------

/**
 * The pending-permission region. Questions are routed to the composer seat, as in
 * iOS `questionTakeover`; this region holds only permission approvals.
 *
 * The older "还有 1 个待确认" fold line is gone on purpose: the baseline's
 * `cardsRegion` now holds the cards themselves (`pendingCardCount` counts the one
 * permission ask, `ChatPage.swift:840-842`), so a line standing in for a card has
 * no counterpart to mirror — and the contract stopped listing it as an action.
 * The second ask is drawn instead of folded, so nothing is hidden behind a row the
 * baseline no longer has.
 */
@Composable
private fun PendingCardsRegion(
    slot: PendingSlot,
    fold: PendingFold,
    onExpand: () -> Unit,
    approveAvailability: PdshActionAvailability<(PendingAnswer) -> Unit>,
    denyAvailability: PdshActionAvailability<(PendingAnswer) -> Unit>,
    maxHeight: Dp,
) {
    // Questions own the composer seat (ChatPage.swift `questionTakeover`); only
    // permissions remain in the page card region.
    val approvals = (listOfNotNull(slot.primary) + slot.folded).filter { it.kind != QUESTION }
    if (approvals.isEmpty()) return
    val primary = approvals.firstOrNull()
    val count = approvals.size + slot.hidden
    Box(
        modifier = Modifier
            .fillMaxWidth()
            .testTag(UiTags.ANSWER_SLOT),
    ) {
        if (fold == PendingFold.FOLDED) {
            FoldedPendingRow(
                label = UiStrings.PENDING_SLOT.format(count),
                onExpand = onExpand,
                modifier = Modifier.testTag(UiPageTags.CHAT_PENDING_FOLD),
            )
        } else {
            // Swift `cardsRegion` clamps the whole scroll area to 40% of the
            // viewport; each card keeps its own scrolling body within that region.
            Column(
                modifier = Modifier.fillMaxWidth()
                    .heightIn(max = maxHeight)
                    .verticalScroll(rememberScrollState()),
            ) {
                Column(modifier = Modifier.fillMaxWidth()) {
                    if (primary != null) {
                        PermissionRequestCard(primary, approveAvailability, denyAvailability, maxHeight)
                    }
                    approvals.drop(1).forEach { ask ->
                        PermissionRequestCard(ask, approveAvailability, denyAvailability, maxHeight)
                    }
                }
            }
        }
    }
}

/** Permission decision card with the source's geometry and request-scoped status. */
@Composable
private fun PermissionRequestCard(
    request: PendingAnswer,
    approveAvailability: PdshActionAvailability<(PendingAnswer) -> Unit>,
    denyAvailability: PdshActionAvailability<(PendingAnswer) -> Unit>,
    maxHeight: Dp,
) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    val busy = request.actionState?.status == com.phonedsh.ui.state.PendingAnswerActionStatus.PENDING || request.submitting == true
    val approve = (approveAvailability as? PdshActionAvailability.Available)?.callback
    val deny = (denyAvailability as? PdshActionAvailability.Available)?.callback
    val receipt = request.actionState?.error ?: request.submissionError
    Column(
        modifier = Modifier.fillMaxWidth()
            .padding(horizontal = ChatMetrics.PERMISSION_CARD_OUTER_MARGIN_H_PT.dp, vertical = ChatMetrics.PERMISSION_CARD_OUTER_MARGIN_V_PT.dp)
            .testTag(UiTags.APPROVAL_CARD)
            .background(tokens.colors.selector, RoundedCornerShape(ChatMetrics.PERMISSION_CARD_RADIUS_PT.dp))
            .padding(ChatMetrics.PERMISSION_CARD_PADDING_PT.dp),
        verticalArrangement = Arrangement.spacedBy(ChatMetrics.PERMISSION_CARD_SPACING_PT.dp),
    ) {
        Column(modifier = Modifier.heightIn(max = maxHeight).verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(ChatMetrics.PERMISSION_CARD_SPACING_PT.dp)) {
        BasicText(UiStrings.WAITING_AUTHORIZATION, style = type.pageTitle.copy(color = tokens.colors.primary), modifier = Modifier.semantics { heading() })
            if (request.subtitle.isNotEmpty()) BasicText(request.subtitle, style = type.subheadline.copy(fontWeight = androidx.compose.ui.text.font.FontWeight.SemiBold, color = tokens.colors.secondary))
            if (busy) BasicText("正在处理…", style = type.caption.copy(color = tokens.colors.secondary))
            if (receipt != null) BasicText(receipt, style = type.caption.copy(color = tokens.colors.danger), modifier = Modifier.testTag("pdsh.chat.pending-action-error"))
        }
        Box(
            modifier = Modifier.fillMaxWidth().height(ChatMetrics.PERMISSION_PRIMARY_HEIGHT_PT.dp)
                .background(if (approve != null && !busy) tokens.colors.accent else tokens.colors.selector, RoundedCornerShape(ChatMetrics.PERMISSION_PRIMARY_RADIUS_PT.dp))
                .clickable(enabled = approve != null && !busy, role = Role.Button) { approve?.invoke(request) }
                .testTag(UiTags.APPROVAL_PRIMARY)
                .semantics { contentDescription = UiStrings.ALLOW_ONCE },
            contentAlignment = Alignment.Center,
        ) {
            BasicText(UiStrings.ALLOW_ONCE, style = type.pageTitle.copy(color = if (approve != null && !busy) tokens.colors.onAccent else tokens.colors.tertiary))
        }
        Box(
            modifier = Modifier.fillMaxWidth().height(ChatMetrics.PERMISSION_DENY_HEIGHT_PT.dp)
                .clickable(enabled = deny != null && !busy, role = Role.Button) { deny?.invoke(request) }
                .testTag(UiTags.APPROVAL_SECONDARY)
                .semantics { contentDescription = UiStrings.DENY },
            contentAlignment = Alignment.Center,
        ) {
            BasicText(UiStrings.DENY, style = type.subheadline.copy(fontWeight = androidx.compose.ui.text.font.FontWeight.Normal, color = if (deny != null && !busy) tokens.colors.secondary else tokens.colors.tertiary))
        }
    }
}

/**
 * The question card (iOS `QuestionCard`): one option row per choice, a free-text
 * field, an optional "可多选" hint and the submit key, which stays disabled until
 * every question has an answer.
 *
 * The selections are widget-local, exactly like the iOS `@State` fields: they are
 * not engine facts and they leave with the card.
 */
@Composable
private fun QuestionCard(
    question: PendingAnswer,
    maxHeight: Dp,
    onSubmit: (String) -> Unit,
) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    var single by remember { mutableStateOf<String?>(null) }
    var multiple by remember { mutableStateOf(setOf<String>()) }
    var custom by remember { mutableStateOf("") }
    val chosen = if (question.multiple) multiple.isNotEmpty() else single != null
    val canSubmit = chosen || custom.trim().isNotEmpty()

    Column(
        modifier = Modifier
            .fillMaxWidth()
            .padding(
                horizontal = tokens.geometry.cardOuterMarginH,
                vertical = tokens.geometry.cardOuterMarginV,
            )
            .testTag(UiTags.APPROVAL_CARD)
            .background(tokens.colors.selector, RoundedCornerShape(tokens.radius.card))
            .padding(tokens.geometry.cardPadding),
        verticalArrangement = Arrangement.spacedBy(tokens.geometry.cardPadding),
    ) {
        Box(
            modifier = Modifier
                .fillMaxWidth()
                .heightIn(max = maxHeight)
                .verticalScroll(rememberScrollState()),
        ) {
            Column(verticalArrangement = Arrangement.spacedBy(tokens.geometry.bannerGap)) {
                BasicText(
                    text = UiStrings.QUESTION_CARD_TITLE,
                    style = type.subheadline.copy(fontWeight = androidx.compose.ui.text.font.FontWeight.SemiBold, color = tokens.colors.primary),
                    modifier = Modifier.semantics { heading() },
                )
                if (question.subtitle.isNotEmpty()) {
                    BasicText(
                        text = question.subtitle,
                        style = type.secondary.copy(color = tokens.colors.secondary),
                    )
                }
                question.options.forEach { option ->
                    val selected = if (question.multiple) option in multiple else single == option
                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .defaultMinSize(minHeight = tokens.geometry.pageRowMinHeight)
                            .clickable(role = Role.Button) {
                                if (question.multiple) {
                                    multiple = if (selected) multiple - option else multiple + option
                                } else {
                                    single = option
                                    custom = ""
                                }
                            }
                            .semantics(mergeDescendants = true) {
                                contentDescription = option
                            },
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(tokens.spacing.iconText),
                    ) {
                        Box(
                            modifier = Modifier.size(ChatMetrics.QUESTION_RADIO_OUTLINE_PT.dp).border(tokens.stroke.hairline, tokens.colors.borderLight, CircleShape),
                            contentAlignment = Alignment.Center,
                        ) {
                            if (selected) Box(Modifier.size(ChatMetrics.QUESTION_RADIO_DOT_PT.dp).background(tokens.colors.accent, CircleShape))
                        }
                        BasicText(
                            text = option,
                            style = type.secondary.copy(
                                color = if (selected) tokens.colors.accent else tokens.colors.primary,
                            ),
                        )
                    }
                }
                BasicTextField(
                    value = custom,
                    onValueChange = { value ->
                        custom = value
                        if (value.isNotEmpty() && !question.multiple) single = null
                    },
                    textStyle = type.secondary.copy(color = tokens.colors.primary),
                    cursorBrush = SolidColor(tokens.colors.accent),
                    modifier = Modifier
                        .fillMaxWidth()
                        .testTag(UiPageTags.CHAT_QUESTION_ANSWER),
                    decorationBox = { inner ->
                        Box {
                            if (custom.isEmpty()) {
                                BasicText(
                                    text = if (question.options.isEmpty()) {
                                        UiStrings.QUESTION_INPUT_ANSWER
                                    } else {
                                        UiStrings.QUESTION_CUSTOM_ANSWER
                                    },
                                    style = type.secondary.copy(color = tokens.colors.tertiary),
                                )
                            }
                            inner()
                        }
                    },
                )
                if (question.multiple) {
                    BasicText(
                        text = UiStrings.QUESTION_MULTIPLE_HINT,
                        style = type.caption.copy(color = tokens.colors.secondary),
                    )
                }
            }
        }
        Box(
            modifier = Modifier
                .fillMaxWidth()
                .defaultMinSize(minHeight = tokens.geometry.primaryButtonHeight)
                .background(
                    color = if (canSubmit) tokens.colors.ctaOverride else tokens.colors.border,
                    shape = RoundedCornerShape(tokens.radius.card),
                )
                .clickable(enabled = canSubmit, role = Role.Button) {
                    onSubmit(answerJson(question, single, multiple, custom))
                }
                .testTag(UiPageTags.CHAT_QUESTION_SUBMIT),
            contentAlignment = Alignment.Center,
        ) {
            BasicText(
                text = UiStrings.QUESTION_SUBMIT,
                style = type.headline.copy(
                    color = if (canSubmit) tokens.colors.onAccent else tokens.colors.tertiary,
                ),
            )
        }
    }
}

/**
 * The question composer takes the bottom seat while a real question is pending,
 * matching ChatPage.swift `questionTakeover`. It only renders fields present in
 * the host projection; absent progress/availability facts remain unknown.
 */
@Composable
private fun QuestionTakeover(
    question: PendingAnswer,
    onSubmit: (String) -> Unit,
    onDismiss: () -> Unit,
    maxHeight: Dp,
    canSubmit: Boolean,
    canDismiss: Boolean,
    imageSource: com.phonedsh.ui.surface.MarkdownImageSource? = null,
) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    val items = remember(question.requestId, question.questionItems, question.options, question.subtitle) {
        question.questionItems.ifEmpty {
            listOf(
                PendingQuestionItem(
                    id = ANSWER_KEY,
                    prompt = question.subtitle,
                    options = question.options.map { PendingQuestionOption(it) },
                    multiple = question.multiple,
                ),
            )
        }
    }
    val recommendedDrafts = remember(items) {
        items.mapNotNull { q ->
            val first = q.options.firstOrNull()?.label
            val recommendation = q.recommendedWireLabel ?: first?.takeIf(::hasRecommendedSuffix)
            recommendation?.let { q.id to QuestionDraft(selected = listOf(it)) }
        }.toMap()
    }
    var index by remember(question.requestId) {
        mutableStateOf(question.initialProgress?.index?.coerceIn(0, (items.size - 1).coerceAtLeast(0)) ?: 0)
    }
    var drafts by remember(question.requestId) {
        mutableStateOf(
            question.initialProgress?.drafts?.mapValues { (_, selected) -> QuestionDraft(selected = selected) }
                ?: recommendedDrafts,
        )
    }
    var minimized by remember(question.requestId) { mutableStateOf(false) }
    var validationError by remember(question.requestId) { mutableStateOf<String?>(null) }
    val item = items.getOrNull(index) ?: return
    val draft = drafts[item.id] ?: QuestionDraft()
    val busy = question.submitting == true
    val last = index == items.lastIndex
    val answered = draft.selected.isNotEmpty() || draft.custom.trim().isNotEmpty()
    val canRespond = canSubmit && question.channelAvailable == true

    fun update(next: QuestionDraft) {
        drafts = drafts + (item.id to next)
        validationError = null
    }
    fun submit(sourceDrafts: Map<String, QuestionDraft> = drafts) {
        if (busy) return
        val missing = items.indexOfFirst { q ->
            val answer = sourceDrafts[q.id] ?: QuestionDraft()
            !answer.skipped && answer.selected.isEmpty() && answer.custom.trim().isEmpty()
        }
        if (missing >= 0) {
            index = missing
            validationError = "请先完成这道问题。"
            return
        }
        val values = items.associate { q ->
            val answer = sourceDrafts[q.id] ?: QuestionDraft()
            val selected = if (answer.skipped) emptyList() else {
                val custom = answer.custom.trim()
                val choices = if (custom.isNotEmpty() && !q.multiple) emptyList() else answer.selected
                choices + listOfNotNull(custom.takeIf(String::isNotEmpty))
            }
            q.id to JsonArray(selected.map(::JsonString))
        }
        onSubmit(CanonicalJson.write(JsonObject(values)))
    }
    fun skip() {
        if (busy) return
        val skippedDrafts = drafts + (item.id to QuestionDraft(skipped = true))
        drafts = skippedDrafts
        validationError = null
        if (!last) index += 1 else submit(skippedDrafts)
    }

    Column(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = tokens.geometry.composerOuterMarginH)
            .padding(bottom = ChatMetrics.COMPOSER_CONTROL_BOTTOM_PT.dp)
            .testTag(QUESTION_TAKEOVER_TAG)
            .shadow(ChatMetrics.QUESTION_CARD_SHADOW_PT.dp, RoundedCornerShape(ChatMetrics.QUESTION_CARD_RADIUS_PT.dp))
            .background(tokens.colors.selector, RoundedCornerShape(ChatMetrics.QUESTION_CARD_RADIUS_PT.dp))
            .border(tokens.stroke.hairline, tokens.colors.borderLight, RoundedCornerShape(ChatMetrics.QUESTION_CARD_RADIUS_PT.dp)),
    ) {
        Row(
            modifier = Modifier.fillMaxWidth().padding(
                start = ChatMetrics.QUESTION_HEADER_LEADING_PT.dp,
                top = ChatMetrics.QUESTION_HEADER_TOP_PT.dp,
                end = ChatMetrics.QUESTION_HEADER_TRAILING_PT.dp,
                bottom = if (minimized) ChatMetrics.QUESTION_HEADER_MINIMIZED_BOTTOM_PT.dp
                else ChatMetrics.QUESTION_HEADER_EXPANDED_BOTTOM_PT.dp,
            ),
            verticalAlignment = Alignment.Top,
            horizontalArrangement = Arrangement.spacedBy(ChatMetrics.QUESTION_HEADER_COPY_ACTION_GAP_PT.dp),
        ) {
            Column(
                modifier = Modifier.weight(1f),
                verticalArrangement = Arrangement.spacedBy(ChatMetrics.QUESTION_HEADER_STACK_GAP_PT.dp),
            ) {
                item.header?.takeIf(String::isNotBlank)?.let {
                    BasicText(text = it, style = type.caption.copy(fontSize = ChatMetrics.QUESTION_EYEBROW_SIZE_PT.sp, color = tokens.colors.tertiary))
                }
                BasicText(
                    text = item.prompt,
                    style = type.secondary.copy(fontSize = ChatMetrics.QUESTION_PROMPT_SIZE_PT.sp, color = tokens.colors.primary),
                    modifier = Modifier.semantics { heading() },
                )
            }
            Row(horizontalArrangement = Arrangement.spacedBy(ChatMetrics.CHAT_HEADER_GROUP_GAP_PT.dp)) {
                ComposerIconAction(
                    icon = if (minimized) PdshIcon.CHEVRON_DOWN else PdshIcon.CHEVRON_UP,
                    label = if (minimized) "展开问题卡片" else "收起问题卡片",
                    enabled = !busy,
                    onClick = { minimized = !minimized },
                )
                ComposerIconAction(
                    icon = PdshIcon.CLOSE,
                    label = "放弃整组问题",
                    enabled = !busy && canDismiss,
                    onClick = { onDismiss() },
                )
            }
        }
        if (!minimized) {
            Column(
                modifier = Modifier.fillMaxWidth().heightIn(max = maxHeight).verticalScroll(rememberScrollState())
                    .padding(horizontal = ChatMetrics.QUESTION_BODY_INSET_H_PT.dp),
                verticalArrangement = Arrangement.spacedBy(tokens.geometry.bannerGap),
            ) {
                item.detail?.takeIf(String::isNotBlank)?.let {
                    MarkdownBody(markdown = it, imageSource = imageSource, modifier = Modifier
                        .padding(horizontal = ChatMetrics.QUESTION_DETAIL_INSET_H_PT.dp)
                        .padding(vertical = ChatMetrics.QUESTION_DETAIL_INSET_V_PT.dp))
                }
                if (item.options.isNotEmpty()) {
                    Spacer(Modifier.height(ChatMetrics.QUESTION_OPTIONS_TOP_PT.dp))
                }
                item.options.forEachIndexed { optionIndex, option ->
                val selected = option.label in draft.selected
                val displayLabel = option.label.replace(
                    Regex("""\s*(?:\((?:recommended|推荐)\)|（(?:recommended|推荐)）)\s*$""", RegexOption.IGNORE_CASE),
                    "",
                )
                val recommended = option.label == item.recommendedWireLabel || displayLabel != option.label
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .defaultMinSize(minHeight = ChatMetrics.QUESTION_OPTION_ROW_HEIGHT_PT.dp)
                        .background(
                            if (selected && !item.multiple) tokens.colors.selector else Color.Transparent,
                            RoundedCornerShape(ChatMetrics.QUESTION_OPTION_RADIUS_PT.dp),
                        )
                        .clickable(enabled = !busy, role = Role.Button) {
                            val next = if (item.multiple) {
                                if (selected) draft.selected - option.label else draft.selected + option.label
                            } else listOf(option.label)
                            update(draft.copy(selected = next, custom = "", skipped = false))
                        }
                        .padding(
                            horizontal = ChatMetrics.QUESTION_OPTION_PADDING_H_PT.dp,
                            vertical = ChatMetrics.QUESTION_OPTION_PADDING_V_PT.dp,
                        )
                        .semantics(mergeDescendants = true) {
                            contentDescription = if (recommended) "$displayLabel，推荐" else displayLabel
                            this.selected = selected
                        },
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(tokens.spacing.iconText),
                ) {
                    if (item.multiple) {
                        Box(
                            modifier = Modifier.size(ChatMetrics.QUESTION_CHECKBOX_FRAME_PT.dp)
                                .border(tokens.stroke.hairline, tokens.colors.borderLight, RoundedCornerShape(ChatMetrics.QUESTION_CHECKBOX_RADIUS_PT.dp)),
                            contentAlignment = Alignment.Center,
                        ) {
                            if (selected) PdshIconView(PdshIcon.CHECK, ChatMetrics.QUESTION_CHECKBOX_GLYPH_PT.dp, tokens.colors.accent, null)
                        }
                    } else {
                        Box(Modifier.size(ChatMetrics.QUESTION_OPTION_MARK_SIZE_PT.dp).background(tokens.colors.selector, CircleShape), contentAlignment = Alignment.Center) {
                            BasicText(text = (optionIndex + 1).toString(), style = type.caption.copy(color = tokens.colors.secondary))
                        }
                    }
                    Column {
                        BasicText(
                            text = displayLabel,
                            style = type.secondary.copy(fontSize = ChatMetrics.QUESTION_OPTION_TEXT_SIZE_PT.sp, color = tokens.colors.primary),
                        )
                        option.description?.takeIf(String::isNotBlank)?.let {
                            BasicText(text = it, style = type.secondary.copy(fontSize = ChatMetrics.QUESTION_OPTION_TEXT_SIZE_PT.sp, color = tokens.colors.tertiary))
                        }
                        if (recommended) {
                            BasicText("推荐", style = type.caption.copy(color = tokens.colors.accent))
                        }
                    }
                }
            }
            Row(
                modifier = Modifier.fillMaxWidth().defaultMinSize(minHeight = if (item.options.isEmpty()) ChatMetrics.QUESTION_FREE_ANSWER_HEIGHT_PT.dp else ChatMetrics.QUESTION_OPTION_ROW_HEIGHT_PT.dp)
                    .padding(
                        horizontal = ChatMetrics.QUESTION_ANSWER_INSET_H_PT.dp,
                        vertical = ChatMetrics.QUESTION_ANSWER_INSET_V_PT.dp,
                    ),
                verticalAlignment = Alignment.Top,
                horizontalArrangement = Arrangement.spacedBy(ChatMetrics.QUESTION_HEADER_STACK_GAP_PT.dp),
            ) {
                if (item.options.isNotEmpty()) {
                    PdshIconView(PdshIcon.PLUS, ChatMetrics.QUESTION_ANSWER_ADD_ICON_PT.dp, tokens.colors.secondary, null)
                }
                Box(Modifier.weight(1f)) {
                    BasicTextField(
                        value = draft.custom,
                        onValueChange = { value ->
                            update(draft.copy(custom = value, selected = if (item.multiple) draft.selected else emptyList(), skipped = false))
                        },
                        textStyle = type.secondary.copy(color = tokens.colors.primary),
                        cursorBrush = SolidColor(tokens.colors.accent),
                        modifier = Modifier.fillMaxWidth().testTag(UiPageTags.CHAT_QUESTION_ANSWER),
                        decorationBox = { inner ->
                            if (draft.custom.isEmpty()) BasicText(
                                text = if (item.options.isEmpty()) "输入你的答案" else UiStrings.QUESTION_CUSTOM_ANSWER,
                                style = type.secondary.copy(color = tokens.colors.tertiary),
                            )
                            inner()
                        },
                    )
                }
            }
            if (item.options.isNotEmpty()) {
                Spacer(Modifier.height(ChatMetrics.QUESTION_OPTIONS_BOTTOM_PT.dp))
            }
            }
            (question.submissionError ?: validationError)?.let { error ->
                BasicText(text = error, style = type.caption.copy(color = tokens.colors.warning))
            }
            if (!canRespond && question.submissionError == null && validationError == null) {
                BasicText(UiStrings.QUESTION_UNAVAILABLE, style = type.caption.copy(color = tokens.colors.tertiary))
            }
            Column(modifier = Modifier.padding(
                top = ChatMetrics.QUESTION_FOOTER_TOP_PT.dp,
                start = ChatMetrics.QUESTION_FOOTER_INSET_H_PT.dp,
                end = ChatMetrics.QUESTION_FOOTER_INSET_H_PT.dp,
                bottom = ChatMetrics.QUESTION_PANEL_BOTTOM_PT.dp,
            )) {
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(ChatMetrics.QUESTION_PAGER_GAP_PT.dp)) {
                    QuestionPagerButton(PdshIcon.CHEVRON_LEFT, "上一题", enabled = index > 0 && !busy) { index -= 1 }
                    BasicText(
                        text = "${index + 1} / ${items.size}",
                        style = type.secondary.copy(fontSize = ChatMetrics.QUESTION_OPTION_TEXT_SIZE_PT.sp, color = tokens.colors.secondary),
                        modifier = Modifier.semantics { contentDescription = "第 ${index + 1} 题，共 ${items.size} 题" },
                    )
                    QuestionPagerButton(PdshIcon.CHEVRON_RIGHT, "下一题", enabled = !last && !busy) { index += 1 }
                    Spacer(Modifier.weight(1f))
                }
                Row(
                    modifier = Modifier.fillMaxWidth().padding(top = ChatMetrics.QUESTION_FOOTER_GAP_PT.dp),
                    verticalAlignment = Alignment.Bottom,
                    horizontalArrangement = Arrangement.spacedBy(ChatMetrics.QUESTION_FOOTER_GAP_PT.dp),
                ) {
                    QuestionActionText("跳过", enabled = !busy && canRespond) { skip() }
                    Spacer(Modifier.weight(1f))
                    Box(
                        modifier = Modifier.defaultMinSize(minHeight = ChatMetrics.QUESTION_ACTION_HEIGHT_PT.dp)
                            .background(if (!busy && canRespond && answered) tokens.colors.ctaOverride else tokens.colors.border, RoundedCornerShape(ChatMetrics.QUESTION_ACTION_RADIUS_PT.dp))
                            .clickable(enabled = !busy && canRespond && answered, role = Role.Button) {
                                if (!last) index += 1 else submit()
                            }
                            .testTag(UiPageTags.CHAT_QUESTION_SUBMIT)
                            .padding(horizontal = ChatMetrics.QUESTION_ACTION_PADDING_H_PT.dp),
                        contentAlignment = Alignment.Center,
                    ) {
                        BasicText(
                            text = if (busy) "正在提交…" else if (last) "提交" else "下一题",
                            style = type.secondary.copy(fontSize = ChatMetrics.QUESTION_OPTION_TEXT_SIZE_PT.sp, color = if (!busy && canRespond && answered) tokens.colors.onAccent else tokens.colors.tertiary),
                        )
                    }
                }
            }
        }
        Spacer(Modifier.height(ChatMetrics.QUESTION_CARD_BOTTOM_PT.dp))
    }
}

private fun hasRecommendedSuffix(label: String): Boolean = Regex(
    """\s*(?:\((?:recommended|推荐)\)|（(?:recommended|推荐)）)\s*$""",
    RegexOption.IGNORE_CASE,
).containsMatchIn(label)

@Composable
private fun QuestionPagerButton(icon: PdshIcon, label: String, enabled: Boolean, onClick: () -> Unit) {
    val tokens = LocalUiTokens.current
    Box(
        modifier = Modifier.size(ChatMetrics.QUESTION_PAGER_TARGET_PT.dp)
            .clickable(enabled = enabled, role = Role.Button, onClick = onClick)
            .semantics { contentDescription = label },
        contentAlignment = Alignment.Center,
    ) {
        PdshIconView(icon, ChatMetrics.QUESTION_PAGER_ICON_PT.dp, if (enabled) tokens.colors.secondary else tokens.colors.tertiary, null)
    }
}

@Composable
private fun ComposerIconAction(icon: PdshIcon, label: String, enabled: Boolean, onClick: () -> Unit) {
    val tokens = LocalUiTokens.current
    Box(
        modifier = Modifier.size(ChatMetrics.QUESTION_HEADER_ACTION_SIZE_PT.dp)
            .clickable(enabled = enabled, role = Role.Button, onClick = onClick)
            .semantics { contentDescription = label },
        contentAlignment = Alignment.Center,
    ) {
        PdshIconView(icon, ChatMetrics.QUESTION_HEADER_ACTION_GLYPH_PT.dp, if (enabled) tokens.colors.secondary else tokens.colors.tertiary, null)
    }
}

@Composable
private fun QuestionActionText(label: String, enabled: Boolean, onClick: () -> Unit) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    BasicText(
        text = label,
        style = type.secondary.copy(color = if (enabled) tokens.colors.secondary else tokens.colors.tertiary),
        modifier = Modifier.clickable(enabled = enabled, role = Role.Button, onClick = onClick)
            .padding(
                horizontal = ChatMetrics.QUESTION_ACTION_TEXT_INSET_H_PT.dp,
                vertical = ChatMetrics.QUESTION_ACTION_TEXT_INSET_V_PT.dp,
            ),
    )
}

private data class QuestionDraft(
    val selected: List<String> = emptyList(),
    val custom: String = "",
    val skipped: Boolean = false,
)

/** Plan-review variant is selected only from the explicit source intent. */
@Composable
private fun PlanReviewTakeover(
    question: PendingAnswer,
    item: PendingQuestionItem,
    onApprove: (String) -> Unit,
    onRequestChanges: () -> Unit,
    canApprove: Boolean,
    canRequestChanges: Boolean,
) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    val markdown = item.detail.orEmpty().trim()
    val firstLine = markdown.lineSequence().firstOrNull().orEmpty().trimStart('#').trim()
    val body = markdown.lineSequence().drop(1).dropWhile { it.isBlank() }.takeWhile { it.isNotBlank() }
        .joinToString(" ").trim()
    val title = firstLine.ifEmpty { item.prompt }
    val summary = body.takeIf { it.isNotEmpty() && it != title }
    val busy = question.submitting == true
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = tokens.geometry.composerOuterMarginH)
            .testTag(PLAN_REVIEW_TAKEOVER_TAG)
            .background(tokens.colors.input, RoundedCornerShape(tokens.radius.card))
            .border(tokens.stroke.hairline, tokens.colors.borderLight, RoundedCornerShape(tokens.radius.card)),
    ) {
        Row(
            modifier = Modifier.fillMaxWidth()
                .background(tokens.colors.warning.copy(alpha = 0.12f))
                .padding(horizontal = tokens.spacing.cardInset, vertical = tokens.spacing.iconText),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(tokens.spacing.iconText),
        ) {
            Box(Modifier.size(tokens.geometry.statusDotDiameter).clip(CircleShape).background(tokens.colors.warning))
            BasicText("计划待审", style = type.secondary.copy(color = tokens.colors.warning))
            Spacer(Modifier.weight(1f))
            if (busy) BasicText("正在提交…", style = type.caption.copy(color = tokens.colors.secondary))
        }
        Column(
            modifier = Modifier.fillMaxWidth().padding(tokens.spacing.cardInset),
            verticalArrangement = Arrangement.spacedBy(tokens.spacing.iconText),
        ) {
            BasicText(title, style = type.subheadline.copy(color = tokens.colors.primary), maxLines = 1, overflow = TextOverflow.Ellipsis)
            if (summary != null) {
                BasicText(summary, style = type.secondary.copy(color = tokens.colors.secondary), maxLines = 2, overflow = TextOverflow.Ellipsis)
            }
            if (question.submissionError != null) {
                BasicText(question.submissionError, style = type.caption.copy(color = tokens.colors.warning))
            }
            if (!canApprove && question.submissionError == null) {
                BasicText(UiStrings.QUESTION_UNAVAILABLE, style = type.caption.copy(color = tokens.colors.tertiary))
            }
            Row(horizontalArrangement = Arrangement.spacedBy(tokens.spacing.iconText), verticalAlignment = Alignment.CenterVertically) {
                Row(
                    modifier = Modifier.clickable(enabled = !busy && canRequestChanges, role = Role.Button, onClick = onRequestChanges)
                        .border(tokens.stroke.hairline, tokens.colors.borderLight, RoundedCornerShape(ChatMetrics.PLAN_REVIEW_BUTTON_RADIUS_PT.dp))
                        .padding(horizontal = tokens.spacing.cardInset, vertical = tokens.spacing.iconText)
                        .testTag(PLAN_REVIEW_CHANGE_TAG),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(ChatMetrics.PLAN_REVIEW_BUTTON_GAP_PT.dp),
                ) {
                    PdshIconView(PdshIcon.EDIT, ChatMetrics.PLAN_REVIEW_CHANGE_GLYPH_PT.dp, tokens.colors.secondary, null)
                    BasicText("要求修改", style = type.secondary.copy(color = tokens.colors.primary))
                }
                Box(
                    modifier = Modifier.weight(1f).defaultMinSize(minHeight = ChatMetrics.PLAN_REVIEW_BUTTON_HEIGHT_PT.dp)
                        .background(if (!busy && canApprove) tokens.colors.ctaOverride else tokens.colors.border, RoundedCornerShape(ChatMetrics.PLAN_REVIEW_BUTTON_RADIUS_PT.dp))
                        .clickable(enabled = !busy && canApprove, role = Role.Button) {
                            val value = JsonArray(listOf(JsonString(item.approveWireLabel.orEmpty())))
                            onApprove(CanonicalJson.write(JsonObject(mapOf(item.id to value))))
                        }
                        .testTag(PLAN_REVIEW_APPROVE_TAG),
                    contentAlignment = Alignment.Center,
                ) {
                    BasicText("同意执行", style = type.secondary.copy(color = if (!busy && canApprove) tokens.colors.onAccent else tokens.colors.tertiary))
                }
            }
        }
    }
}

/** Builds the JSON the iOS card submits: one key, a string or a list of strings. */
private fun answerJson(
    question: PendingAnswer,
    single: String?,
    multiple: Set<String>,
    custom: String,
): String {
    val trimmed = custom.trim()
    val value: JsonValue = if (question.multiple) {
        val answers = question.options.filter { it in multiple } + listOfNotNull(trimmed.takeIf { it.isNotEmpty() })
        JsonArray(answers.map { JsonString(it) })
    } else {
        JsonString(single ?: trimmed)
    }
    return CanonicalJson.write(JsonObject(mapOf(ANSWER_KEY to value)))
}

// ---------------------------------------------------------------------------
// Transcript (ChatPage.swift `transcript` + `emptyTimeline`)
// ---------------------------------------------------------------------------

/**
 * The transcript.
 *
 * The list follows the tail while the reader is at the bottom, refuses to jump
 * when they scrolled away, and offers "回到最新" in that case (spec §5 row
 * `scroll-refresh`: the follow-the-tail condition is the same on both platforms).
 * Above the rows sit the history controls: 加载更早消息, the history read failure
 * and the "显示上次对话" cache notice.
 */
@Composable
private fun ChatTranscript(
    state: ChatScreenState,
    onToggleRow: (String) -> Unit,
    onLoadEarlier: (() -> Unit)?,
    startEngineAvailability: PdshActionAvailability<() -> Unit>,
    onConfigureProvider: (() -> Unit)?,
    onRetry: () -> Unit,
    onOpenFile: ((String) -> Unit)?,
    onOpenResource: ((String) -> Unit)?,
    imageSource: com.phonedsh.ui.surface.MarkdownImageSource?,
    retryAvailability: PdshActionAvailability<() -> Unit>,
) {
    val tokens = LocalUiTokens.current
    val focusManager = LocalFocusManager.current
    val keyboard = LocalSoftwareKeyboardController.current
    val listState = rememberLazyListState()
    val nearBottomTolerancePx = with(LocalDensity.current) { HomeMetrics.navButton.toPx() }
    // Seeing the last index is not enough: a very tall last row can remain visible
    // while the reader is still far from its tail. Compare its measured bottom to
    // the actual viewport edge, including LazyColumn's bottom content padding.
    val nearBottom by remember(listState, nearBottomTolerancePx) {
        derivedStateOf {
            val info = listState.layoutInfo
            if (info.totalItemsCount == 0) return@derivedStateOf true
            val tail = info.visibleItemsInfo.firstOrNull { it.index == info.totalItemsCount - 1 }
                ?: return@derivedStateOf false
            val viewportBottom = info.viewportEndOffset - info.afterContentPadding
            abs(tail.offset + tail.size - viewportBottom) <= nearBottomTolerancePx
        }
    }
    // "The reader scrolled away" is a user gesture, not a measurement: only a
    // user drag can set it, and being near the tail again clears it (iOS
    // `userScrolledAway` + `nearBottom`).
    var scrolledAway by remember(state.sessionID) { mutableStateOf(false) }
    // True while this composable itself is placing the viewport. A programmatic
    // scroll is not a reader gesture: without this flag the open-at-tail scroll
    // counts as "the reader scrolled away", the pill appears over a transcript
    // nobody touched, and the next rows update refuses to follow the tail.
    var autoScrolling by remember(state.sessionID) { mutableStateOf(false) }
    val scope = rememberCoroutineScope()
    val rowsIdentityKey = remember(state.rows) {
        state.rows.joinToString(separator = "\u0000") { it.id }
    }
    var scrollSessionID by remember { mutableStateOf(state.sessionID) }

    suspend fun scrollToTail(animate: Boolean) {
        val itemCount = listState.layoutInfo.totalItemsCount
        if (itemCount <= 1) return
        autoScrolling = true
        try {
            val tailIndex = itemCount - 1
            if (animate) listState.animateScrollToItem(tailIndex) else listState.scrollToItem(tailIndex)
            withFrameNanos { }
            val info = listState.layoutInfo
            val tail = info.visibleItemsInfo.firstOrNull { it.index == tailIndex } ?: return
            val viewportBottom = info.viewportEndOffset - info.afterContentPadding
            val remaining = (tail.offset + tail.size - viewportBottom).coerceAtLeast(0)
            if (remaining > 0) {
                if (animate) listState.animateScrollBy(remaining.toFloat())
                else listState.scrollBy(remaining.toFloat())
            }
        } finally {
            autoScrolling = false
        }
    }

    LaunchedEffect(listState) {
        snapshotFlow { listState.isScrollInProgress to nearBottom }.collect { (scrolling, near) ->
            if (autoScrolling) return@collect
            if (scrolling && !near) scrolledAway = true
            if (!scrolling && near) scrolledAway = false
        }
    }
    // The tail is keyed on the rows' *identity*, not only their count: a restored
    // session can replace its history with re-derived row ids of the same length,
    // and a LazyColumn that cannot match a previous key starts again at the top.
    // Keyed on `size` that replacement was invisible, so the transcript stayed on
    // its first message (measured on the phone, 2026-11-02).
    // Row identities handle append/history replacement. The session key is
    // separate so switching after reading away opens the new conversation at its
    // tail, even if its row ids match the previous session's ids.
    LaunchedEffect(state.sessionID, rowsIdentityKey) {
        val switchedSession = scrollSessionID != state.sessionID
        if (switchedSession) {
            scrollSessionID = state.sessionID
            scrolledAway = false
        }
        if (state.rows.isEmpty()) return@LaunchedEffect
        if (!switchedSession && listState.isScrollInProgress) {
            snapshotFlow { listState.isScrollInProgress }.first { !it }
            withFrameNanos { }
        }
        if (!switchedSession && scrolledAway) return@LaunchedEffect
        snapshotFlow { listState.layoutInfo.totalItemsCount }.first { it > 1 }
        withFrameNanos { }
        if (!switchedSession && (scrolledAway || listState.isScrollInProgress)) return@LaunchedEffect
        scrollToTail(animate = false)
    }

    // Streaming text can grow under the same row id. Images/math can change row
    // height asynchronously, and the IME changes viewport height; none changes
    // the identity key above. Follow those layout changes only while the reader
    // is at the tail and no touch/fling is active.
    LaunchedEffect(listState, state.sessionID, rowsIdentityKey) {
        var previousSizes: Map<Int, Int>? = null
        var previousViewportHeight: Int? = null
        snapshotFlow {
            val info = listState.layoutInfo
            info.visibleItemsInfo.associate { it.index to it.size } to
                (info.viewportEndOffset - info.viewportStartOffset)
        }.collect { (currentSizes, viewportHeight) ->
            val previous = previousSizes
            val previousViewport = previousViewportHeight
            previousSizes = currentSizes
            previousViewportHeight = viewportHeight
            val rowHeightChanged = previous != null && currentSizes.any { (index, size) ->
                previous[index]?.let { it != size } == true
            }
            val viewportChanged = previousViewport != null && previousViewport != viewportHeight
            if (!(rowHeightChanged || viewportChanged) || state.rows.isEmpty() || scrolledAway ||
                autoScrolling || listState.isScrollInProgress
            ) return@collect
            withFrameNanos { }
            if (!scrolledAway && !autoScrolling && !listState.isScrollInProgress) {
                scrollToTail(animate = false)
            }
        }
    }

    Box(
        modifier = Modifier.fillMaxSize().pointerInput(focusManager, keyboard) {
            detectTapGestures(onTap = {
                focusManager.clearFocus()
                keyboard?.hide()
            })
        },
    ) {
        if (state.rows.isEmpty()) {
            Column(modifier = Modifier.fillMaxSize()) {
                TranscriptChrome(state = state, onLoadEarlier = onLoadEarlier)
                EmptyTimeline(
                    state = state,
                    startEngineAvailability = startEngineAvailability,
                    onConfigureProvider = onConfigureProvider,
                )
            }
        } else {
            LazyColumn(
                state = listState,
                modifier = Modifier
                    .fillMaxSize()
                    .testTag(UiTags.CHAT_LIST),
                // HomeSpec: 20pt top rhythm and 48pt room for the floating latest pill.
                contentPadding = PaddingValues(
                    top = HomeMetrics.blockGap,
                    bottom = ChatMetrics.TRANSCRIPT_LATEST_CLEARANCE_PT.dp,
                ),
                // ios-chat-assistant.png / -failed.png / -queued.png: a short
                // conversation sits at the *bottom* of the transcript, against the
                // dock, leaving the space under the header empty. A top-anchored list
                // put the first row directly under the header.
                verticalArrangement = Arrangement.Bottom,
            ) {
                item(key = CHROME_ITEM) { TranscriptChrome(state = state, onLoadEarlier = onLoadEarlier) }
                itemsIndexed(items = state.rows, key = { _, row -> row.id }) { index, row ->
                    val gap = rowGap(previous = state.rows.getOrNull(index - 1), current = row)
                    Box(modifier = if (gap == null) Modifier else Modifier.padding(top = gap)) {
                        Column {
                            ChatRowItem(
                                row = row,
                                expandedRowIds = state.expandedRowIds,
                                onToggleRow = onToggleRow,
                                onOpenFile = onOpenFile,
                                onOpenResource = onOpenResource,
                                imageSource = imageSource,
                                            )
                            if (row.id == state.failedItemID && state.userFacingError != null) {
                                FailureLine(
                                    reason = state.userFacingError,
                                    retry = (retryAvailability as? PdshActionAvailability.Available)?.callback
                                        ?.takeIf { state.banners.firstOrNull()?.retryable == true },
                                )
                            }
                        }
                    }
                }
            }
            if (scrolledAway && !nearBottom) {
                val latestShape = RoundedCornerShape(ChatMetrics.BACK_TO_LATEST_RADIUS_PT.dp)
                val latestLabelStyle = LocalUiType.current.caption.copy(
                    fontSize = ChatMetrics.BACK_TO_LATEST_LABEL_PT.sp,
                    lineHeight = ChatMetrics.BACK_TO_LATEST_LABEL_LINE_HEIGHT_PT.sp,
                    fontWeight = FontWeight.SemiBold,
                    color = tokens.colors.accent,
                )
                Row(
                    modifier = Modifier
                        .align(Alignment.BottomCenter)
                        .padding(bottom = ChatMetrics.BACK_TO_LATEST_BOTTOM_PT.dp)
                        .testTag(UiPageTags.CHAT_BACK_TO_LATEST)
                        // ChatPage.swift:1333-1345 uses an opaque surface rectangle;
                        // this pill may cover transcript content while the reader is away.
                        .clip(latestShape)
                        .background(tokens.colors.surface, latestShape)
                        .border(
                            width = ChatMetrics.BACK_TO_LATEST_BORDER_PT.dp,
                            color = tokens.colors.separator,
                            shape = latestShape,
                        )
                        .clickable(role = Role.Button) {
                            scrolledAway = false
                            scope.launch {
                                scrollToTail(animate = true)
                            }
                        }
                        .padding(
                            horizontal = ChatMetrics.BACK_TO_LATEST_PADDING_H_PT.dp,
                            vertical = ChatMetrics.BACK_TO_LATEST_PADDING_V_PT.dp,
                        ),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(tokens.spacing.iconText),
                ) {
                    // iOS is `Label("回到最新", systemImage: "arrow.down")`: the glyph
                    // is part of the control, and without it the pill reads as a
                    // stray link rather than a "jump to the tail" action.
                    BasicText(
                        text = BACK_TO_LATEST_GLYPH,
                        style = latestLabelStyle,
                    )
                    BasicText(
                        text = UiStrings.BACK_TO_LATEST,
                        style = latestLabelStyle,
                    )
                }
            }
        }
    }
}

/**
 * The history controls above the rows. Rendered inside the list so they scroll
 * with it, exactly like the iOS `LazyVStack` header block.
 */
@Composable
private fun TranscriptChrome(
    state: ChatScreenState,
    onLoadEarlier: (() -> Unit)?,
) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    Column(modifier = Modifier.fillMaxWidth().padding(horizontal = HomeMetrics.contentInset)) {
        if (state.transcript.hasMore) {
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .defaultMinSize(minHeight = tokens.geometry.pageRowMinHeight)
                    .clickable(
                        enabled = !state.transcript.loadingEarlier && onLoadEarlier != null,
                        role = Role.Button,
                        onClick = { onLoadEarlier?.invoke() },
                    )
                    .testTag(UiPageTags.CHAT_LOAD_EARLIER),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(tokens.spacing.iconText, Alignment.CenterHorizontally),
            ) {
                if (state.transcript.loadingEarlier) {
                    CircularProgressIndicator(
                        color = tokens.colors.tertiary,
                        strokeWidth = tokens.stroke.hairline,
                        modifier = Modifier.size(tokens.geometry.composerControlSize),
                    )
                    // iOS `loadingEarlierTranscript ? "正在加载…" : "加载更早消息"`:
                    // one word per state, each written out here.
                    BasicText(
                        text = UiStrings.LOADING_EARLIER,
                        style = type.secondary.copy(color = tokens.colors.secondary),
                    )
                } else {
                    BasicText(
                        text = UiStrings.LOAD_EARLIER,
                        style = type.secondary.copy(color = tokens.colors.secondary),
                    )
                }
            }
        }
        val transcriptError = state.transcript.error
        if (transcriptError != null) {
            // iOS paints this line with the warning ink over a 8% warning wash.
            BasicText(
                text = transcriptError,
                style = type.caption.copy(color = tokens.colors.warning),
                modifier = Modifier
                    .fillMaxWidth()
                    .testTag(UiPageTags.CHAT_TRANSCRIPT_ERROR)
                    .padding(tokens.geometry.bannerInsetH)
                    .background(
                        tokens.colors.warning.copy(alpha = WARNING_WASH_ALPHA),
                        RoundedCornerShape(tokens.radius.card),
                    )
                    .padding(tokens.geometry.bannerInsetH),
            )
        }
        if (state.transcript.showingCached) {
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .testTag(UiPageTags.CHAT_CACHED_NOTICE)
                    .padding(vertical = tokens.geometry.toolDetailVertical),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(tokens.spacing.iconText, Alignment.CenterHorizontally),
            ) {
                CircularProgressIndicator(
                    color = tokens.colors.tertiary,
                    strokeWidth = tokens.stroke.hairline,
                    modifier = Modifier.size(tokens.geometry.disclosureRowHeight),
                )
                BasicText(
                    text = UiStrings.TRANSCRIPT_CACHED,
                    style = type.caption.copy(color = tokens.colors.secondary),
                )
            }
        }
    }
}

/** The per-row failure line: 没发出去 · reason · 重试, aligned to the trailing edge. */
@Composable
private fun FailureLine(
    reason: String,
    retry: (() -> Unit)?,
) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .testTag(UiPageTags.CHAT_FAILURE_LINE)
            .padding(top = ChatMetrics.FAILURE_LINE_TOP_PT.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(ChatMetrics.FAILURE_LINE_GAP_PT.dp, Alignment.End),
    ) {
        BasicText(
            text = UiStrings.SEND_FAILED_LINE,
            style = type.caption.copy(fontSize = ChatMetrics.FAILURE_TEXT_SIZE_PT.sp, fontWeight = androidx.compose.ui.text.font.FontWeight.SemiBold, color = tokens.colors.danger),
        )
        if (reason.isNotEmpty()) {
            BasicText(
                text = UiStrings.DOT_SEPARATOR,
                style = type.caption.copy(fontSize = ChatMetrics.FAILURE_TEXT_SIZE_PT.sp, color = tokens.colors.secondary),
            )
            BasicText(
                text = reason,
                style = type.caption.copy(fontSize = ChatMetrics.FAILURE_TEXT_SIZE_PT.sp, color = tokens.colors.secondary),
            )
        }
        if (retry != null) {
            BasicText(
                text = UiStrings.DOT_SEPARATOR,
                style = type.caption.copy(fontSize = ChatMetrics.FAILURE_TEXT_SIZE_PT.sp, color = tokens.colors.secondary),
            )
            BasicText(
                text = UiStrings.RETRY,
                style = type.caption.copy(fontSize = ChatMetrics.FAILURE_TEXT_SIZE_PT.sp, fontWeight = androidx.compose.ui.text.font.FontWeight.SemiBold, color = tokens.colors.accent),
                modifier = Modifier
                    .clickable(role = Role.Button, onClick = retry)
                    .padding(tokens.spacing.iconText),
            )
        }
    }
}

/** The three mutually exclusive empty states (iOS `emptyTimeline`). */
@Composable
private fun EmptyTimeline(
    state: ChatScreenState,
    startEngineAvailability: PdshActionAvailability<() -> Unit>,
    onConfigureProvider: (() -> Unit)?,
) {
    when (state.empty) {
        // PR22's scroll content puts this block 88 pt below the transcript's
        // content origin (`ChatPage.swift:1402-1408`); the ScrollView itself
        // retains `.defaultScrollAnchor(.bottom)` (`:1241`) for short content.
        ChatEmpty.ENGINE_NOT_STARTED -> Box(
            modifier = Modifier.fillMaxSize(),
            contentAlignment = Alignment.BottomStart,
        ) {
            EngineNotStartedState(
                busy = state.starting,
                startEngineAvailability = startEngineAvailability,
                modifier = Modifier.padding(
                    top = ChatMetrics.EMPTY_STATE_TOP_PT.dp,
                    bottom = ChatMetrics.TRANSCRIPT_LATEST_CLEARANCE_PT.dp,
                ),
            )
        }

        ChatEmpty.PROVIDER_SETUP -> Box(
            modifier = Modifier.fillMaxSize(),
            contentAlignment = Alignment.BottomStart,
        ) {
            ProviderSetupState(
                onConfigureProvider = onConfigureProvider,
                modifier = Modifier.padding(
                    top = ChatMetrics.EMPTY_STATE_TOP_PT.dp,
                    bottom = ChatMetrics.TRANSCRIPT_LATEST_CLEARANCE_PT.dp,
                ),
            )
        }

        ChatEmpty.READY -> ReadyState()
    }
}

/**
 * A: the engine is not started yet — the official 338 pt column
 * ([com.phonedsh.ui.UiMetrics.CONTENT_COLUMN_WIDTH_PT]), text left-aligned.
 */
@Composable
private fun EngineNotStartedState(
    busy: Boolean,
    startEngineAvailability: PdshActionAvailability<() -> Unit>,
    modifier: Modifier = Modifier,
) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    val startEngine = (startEngineAvailability as? PdshActionAvailability.Available)?.callback
    val startEnabled = !busy && startEngine != null
    Column(
        // iOS pins the column to the official 338 pt
        // (com.phonedsh.ui.UiMetrics.CONTENT_COLUMN_WIDTH_PT) on the baseline
        // device, which is simply "screen width minus both page margins". That is
        // a device result, not a design value, so the column fills the width and
        // takes the page margin; it stays correct at every width.
        modifier = modifier
            .fillMaxWidth()
            // ios-chat-draft.png: the title ink starts at x 33 and the CTA spans
            // x 32–370 — the shared 338 pt content column (`UiMetrics`), not the
            // transcript's 16 pt page margin. Read from the metric owner, not
            // re-typed.
            .padding(horizontal = HomeMetrics.contentInset)
            .testTag(UiPageTags.CHAT_EMPTY_ENGINE),
    ) {
        BasicText(
            text = UiStrings.ENGINE_NOT_STARTED,
            style = type.headline.copy(
                fontSize = ChatMetrics.EMPTY_STATE_TITLE_SIZE_PT.sp,
                fontWeight = androidx.compose.ui.text.font.FontWeight.SemiBold,
                color = tokens.colors.textPrimary,
            ),
        )
        BasicText(
            text = UiStrings.ENGINE_NOT_STARTED_HINT,
            style = type.secondary.copy(
                fontSize = ChatMetrics.EMPTY_STATE_HINT_SIZE_PT.sp,
                color = tokens.colors.inputPlaceholder,
            ),
            modifier = Modifier.padding(top = ChatMetrics.EMPTY_STATE_HINT_TOP_PT.dp),
        )
        Box(
            modifier = Modifier
                .fillMaxWidth()
                .padding(top = ChatMetrics.EMPTY_STATE_ACTION_TOP_PT.dp)
                .height(ChatMetrics.EMPTY_STATE_ACTION_HEIGHT_PT.dp)
                .background(tokens.colors.primaryButton.copy(alpha = if (startEnabled) 1f else 0.25f), CircleShape)
                .clickable(enabled = startEnabled, role = Role.Button) { startEngine?.invoke() }
                .testTag(UiPageTags.CHAT_START_ENGINE),
            contentAlignment = Alignment.Center,
        ) {
            // iOS `model.busy ? "正在启动…" : "启动本地引擎"`: one word per state.
            if (busy) {
                BasicText(
                    text = UiStrings.STARTING_ENGINE,
                    style = type.headline.copy(
                        fontSize = ChatMetrics.EMPTY_STATE_ACTION_LABEL_SIZE_PT.sp,
                        fontWeight = androidx.compose.ui.text.font.FontWeight.SemiBold,
                        color = tokens.colors.primaryButtonInk,
                    ),
                )
            } else {
                BasicText(
                    text = UiStrings.START_ENGINE,
                    style = type.headline.copy(
                        fontSize = ChatMetrics.EMPTY_STATE_ACTION_LABEL_SIZE_PT.sp,
                        fontWeight = androidx.compose.ui.text.font.FontWeight.SemiBold,
                        color = tokens.colors.primaryButtonInk,
                    ),
                )
            }
        }
    }
}

/** B: the engine is up, only the model service is missing. */
@Composable
private fun ProviderSetupState(
    onConfigureProvider: (() -> Unit)?,
    modifier: Modifier = Modifier,
) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    val actionEnabled = onConfigureProvider != null
    Column(
        modifier = modifier
            .fillMaxWidth()
            .padding(horizontal = HomeMetrics.contentInset)
            .testTag(UiPageTags.CHAT_EMPTY_PROVIDER),
    ) {
        BasicText(
            text = UiStrings.PROVIDER_SETUP_TITLE,
            style = type.headline.copy(
                fontSize = ChatMetrics.EMPTY_STATE_TITLE_SIZE_PT.sp,
                fontWeight = androidx.compose.ui.text.font.FontWeight.SemiBold,
                color = tokens.colors.textPrimary,
            ),
        )
        BasicText(
            text = UiStrings.PROVIDER_SETUP_HINT,
            style = type.secondary.copy(
                fontSize = ChatMetrics.EMPTY_STATE_HINT_SIZE_PT.sp,
                color = tokens.colors.inputPlaceholder,
            ),
            modifier = Modifier.padding(top = ChatMetrics.EMPTY_STATE_HINT_TOP_PT.dp),
        )
        Box(
            modifier = Modifier
                .fillMaxWidth()
                .padding(top = ChatMetrics.EMPTY_STATE_ACTION_TOP_PT.dp)
                .height(ChatMetrics.EMPTY_STATE_ACTION_HEIGHT_PT.dp)
                .background(tokens.colors.primaryButton.copy(alpha = if (actionEnabled) 1f else 0.25f), CircleShape)
                .clickable(enabled = actionEnabled, role = Role.Button) { onConfigureProvider?.invoke() }
                .testTag(UiPageTags.CHAT_PROVIDER_SETUP),
            contentAlignment = Alignment.Center,
        ) {
            BasicText(
                text = UiStrings.PROVIDER_SETUP_ACTION,
                style = type.headline.copy(
                    fontSize = ChatMetrics.EMPTY_STATE_ACTION_LABEL_SIZE_PT.sp,
                    fontWeight = androidx.compose.ui.text.font.FontWeight.SemiBold,
                    color = tokens.colors.primaryButtonInk,
                ),
            )
        }
    }
}

/**
 * C: both ready. The iOS state centres the product mark over the tagline; the
 * mark is a bundled image (`LogoBackground`) with no Android asset, so only the
 * two lines are drawn, centred in the content area.
 */
@Composable
private fun ReadyState() {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    Box(
        modifier = Modifier
            .fillMaxSize()
            .testTag(UiPageTags.CHAT_EMPTY_READY),
        contentAlignment = Alignment.Center,
    ) {
        Column(horizontalAlignment = Alignment.CenterHorizontally) {
            BasicText(
                text = UiStrings.READY_TITLE,
                style = type.headline.copy(color = tokens.colors.secondary),
                maxLines = 1,
            )
            BasicText(
                text = UiStrings.READY_SUBTITLE,
                style = type.secondary.copy(color = tokens.colors.tertiary),
                maxLines = 1,
            )
        }
    }
}

// ---------------------------------------------------------------------------
// Composer dock (ChatPage.swift `composer` + `goalBar` + `queuedStrip` + menus)
// ---------------------------------------------------------------------------

/**
 * The bottom dock: the goal bar, the queued strip, the pending attachments, the
 * two notice lines, the in-place `/` and `@` menus, the input card and the stat
 * pills — the iOS `composer` VStack in the same order.
 */
@Composable
private fun ComposerDock(
    state: ChatScreenState,
    imageSource: com.phonedsh.ui.surface.MarkdownImageSource?,
    onDraftChange: (String) -> Unit,
    onSend: () -> Unit,
    onGoalPause: (() -> Unit)?,
    onGoalResume: (() -> Unit)?,
    onGoalClear: (() -> Unit)?,
    onOpenGoalDetail: (() -> Unit)?,
    onSubmitAnswer: (PendingAnswer, String) -> Unit,
    onDismissQuestion: (PendingAnswer) -> Unit,
    onRemoveAttachment: (Int) -> Unit,
    onAddImages: () -> Unit,
    onAddFiles: () -> Unit,
    onSelectAccessMode: (String) -> Unit,
    onRetryAccessModes: () -> Unit = {},
    onSelectModel: (String, String?) -> Unit,
    onPickCommand: (String) -> Unit,
    onExecuteCommand: ((String) -> Unit)?,
    onPickReference: (String) -> Unit,
    onDismissNotice: () -> Unit,
    onReloadCommands: () -> Unit,
    availability: ComposerAvailability,
    onSpeakRecentReply: (() -> Unit)?,
    planApproveAvailability: PdshActionAvailability<(PendingAnswer, String) -> Unit>,
    planRequestChangesAvailability: PdshActionAvailability<(PendingAnswer) -> Unit>,
    queueEditAvailability: PdshActionAvailability<(ManagedQueueItemState, String, StateRequestId) -> Unit>,
    queueRemoveAvailability: PdshActionAvailability<(ManagedQueueItemState, StateRequestId) -> Unit>,
    queueSteerAvailability: PdshActionAvailability<(ManagedQueueItemState, StateRequestId) -> Unit>,
    queueSubmissionAvailability: PdshActionAvailability<(String, StateRequestId) -> Unit>,
    steerSubmissionAvailability: PdshActionAvailability<(String, StateRequestId) -> Unit>,
    stopAvailability: PdshActionAvailability<(StateRequestId) -> Unit>,
    onEditQueueItem: (ManagedQueueItemState) -> Unit,
    queueEditNotice: String? = null,
    onDismissQueueEditNotice: () -> Unit = {},
) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    val composer = state.composer
    val queueSubmission = (queueSubmissionAvailability as? PdshActionAvailability.Available)?.callback
    val steerSubmission = (steerSubmissionAvailability as? PdshActionAvailability.Available)?.callback
    val stopRequest = (stopAvailability as? PdshActionAvailability.Available)?.callback
    val runningSubmissionAvailable = if (composer.steering) steerSubmission != null else queueSubmission != null
    // interaction.md §5 rule 2 has one implementation: the page contributes the
    // typed queue/steer route to `composerEnabled`, then calls the same rule the
    // screen state used. There is no second truth table here.
    val canSubmit = ComposerSendRule.canSubmit(
        composerEnabled = composer.enabled && (!composer.running || runningSubmissionAvailable),
        steer = composer.steering,
        hasText = composer.draft.trim().isNotEmpty(),
        hasAttachments = composer.attachments.isNotEmpty(),
        turnRunning = composer.running,
    )
    // No host stop route means no stop key; the key's visibility is the §5 turn
    // branch, but the page never draws an action the host cannot receive.
    val showRunningStop = composer.running && stopRequest != null

    fun submitComposer() {
        if (!composer.running) {
            onSend()
            return
        }
        val requestID = nextQueueActionRequestId()
        val text = composer.draft.trim()
        if (composer.steering) steerSubmission?.invoke(text, requestID)
        else queueSubmission?.invoke(text, requestID)
    }
    val queueRows = remember(state.queueItems, composer.queued) {
        buildChatQueueRows(state.queueItems, composer.queued)
    }
    val pendingQueueRows = state.queueItems.orEmpty().filter { it.state == QueueItemStatus.SENDING }
    var queueExpanded by remember(queueRows.map { it.id }) { mutableStateOf(queueRows.size < 2) }
    val pendingQuestion = (listOfNotNull(state.pending.primary) + state.pending.folded)
        .firstOrNull { it.kind == QUESTION }
    // iOS keeps the truncation notice in the same slot as the attachment error.
    var truncated by remember { mutableStateOf(false) }
    var slashMenuDismissed by remember { mutableStateOf(false) }
    var slashHighlight by remember { mutableIntStateOf(0) }
    val slashMenu = state.composer.slash.takeUnless { slashMenuDismissed }
    val slashCommands = (slashMenu as? SlashMenu.Matches)?.commands.orEmpty()
    // The source `composer` has one 8 pt outer top inset above `composerDocks`
    // and one 6 pt VStack gap above the card, including when the docks are empty.
    // This page owns the dock rows, so only the first visible surface carries
    // the inset; the surface always supplies the 6 pt gap.
    val hasDockRows = state.todoItems.isNotEmpty() ||
        state.goal is GoalBarState.Visible ||
        pendingQueueRows.isNotEmpty() ||
        queueRows.isNotEmpty() ||
        composer.attachments.isNotEmpty() ||
        composer.attachmentError != null ||
        composer.fileImportNotice != null ||
        queueEditNotice != null ||
        truncated ||
        slashMenu != null ||
        composer.reference != null

    fun chooseCommand(name: String) {
        val command = slashCommands.firstOrNull { it.name == name }
        if (command?.hasInput == false && onExecuteCommand != null) {
            onDraftChange("")
            onExecuteCommand(name)
        } else {
            // This local update is essential for screen hosts that only supply a
            // catalog: selecting a menu row must never be a no-op.
            onDraftChange("/$name ")
        }
        onPickCommand(name)
        slashMenuDismissed = true
    }

    fun handleSlashKey(event: KeyEvent): Boolean {
        if (slashMenu == null || event.type != KeyEventType.KeyDown) return false
        if (slashCommands.isEmpty()) {
            if (event.key == Key.Escape) {
                slashMenuDismissed = true
                return true
            }
            if (event.key == Key.Enter) return true
            return false
        }
        return when (event.key) {
            Key.DirectionDown -> {
                slashHighlight = (slashHighlight + 1).coerceAtMost(slashCommands.lastIndex)
                true
            }
            Key.DirectionUp -> {
                slashHighlight = (slashHighlight - 1).coerceAtLeast(0)
                true
            }
            Key.Tab, Key.Enter -> {
                slashCommands.getOrNull(slashHighlight)?.let { chooseCommand(it.name) }
                true
            }
            Key.Escape -> {
                slashMenuDismissed = true
                true
            }
            else -> false
        }
    }

    LaunchedEffect(composer.draft) {
        slashMenuDismissed = false
        slashHighlight = 0
    }
    Column(modifier = Modifier.fillMaxWidth().onPreviewKeyEvent(::handleSlashKey)) {
        // iOS puts the 16 pt horizontal inset on the dock's VStack; the input card
        // is that same surface and applies it itself (`Composer`), so the inset is
        // applied here only to the pieces around the card.
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = tokens.geometry.composerOuterMarginH)
                .padding(top = if (hasDockRows) tokens.geometry.composerOuterMarginTop else Dp(0f)),
            // iOS stacks the dock's rows with `NativeParityTokens.flowGap` = 6 pt
            // (`ChatPage.swift:1795`); the old 40 pt was the trailing *reserve*
            // for the send key, which pushed the queue strip 28 pt too high.
            verticalArrangement = Arrangement.spacedBy(ChatMetrics.flowGap),
        ) {
            if (state.todoItems.isNotEmpty()) {
                TodoDock(
                    items = state.todoItems,
                    modifier = Modifier.widthIn(max = ChatMetrics.CONTENT_COLUMN_WIDTH_PT.dp)
                        .fillMaxWidth().align(Alignment.CenterHorizontally),
                )
            }
            val goal = state.goal
            if (goal is GoalBarState.Visible) {
                GoalBarView(
                    goal = goal,
                    onPause = onGoalPause,
                    onResume = onGoalResume,
                    onClear = onGoalClear,
                    onOpenDetail = onOpenGoalDetail,
                )
            }
            if (pendingQueueRows.isNotEmpty()) PendingQueueSubmissionRows(pendingQueueRows)
            if (queueRows.isNotEmpty()) {
                QueueDock(
                    rows = queueRows,
                    running = composer.running,
                    expanded = queueExpanded,
                    onToggleExpanded = { queueExpanded = !queueExpanded },
                    editAvailability = queueEditAvailability,
                    removeAvailability = queueRemoveAvailability,
                    steerAvailability = queueSteerAvailability,
                    onEdit = onEditQueueItem,
                )
            }
            if (composer.attachments.isNotEmpty()) {
                AttachmentStrip(
                    attachments = composer.attachments,
                    onRemove = onRemoveAttachment,
                )
            }
            if (composer.attachmentError != null) {
                NoticeLine(text = composer.attachmentError, onClose = onDismissNotice)
            }
            if (composer.running && composer.steering && composer.attachments.isNotEmpty()) {
                BasicText(
                    text = UiStrings.COMPOSER_STEER_ATTACHMENT,
                    style = type.caption.copy(color = tokens.colors.warning),
                    modifier = Modifier.fillMaxWidth(),
                )
            }
            if (composer.fileImportNotice != null) {
                NoticeLine(text = composer.fileImportNotice, onClose = onDismissNotice)
            }
            queueEditNotice?.let { notice ->
                NoticeLine(text = notice, onClose = onDismissQueueEditNotice)
            }
            if (truncated) {
                NoticeLine(text = UiStrings.COMPOSER_TRUNCATED, onClose = { truncated = false })
            }
            slashMenu?.let { menu ->
                SlashMenuView(
                    menu = menu,
                    highlightedIndex = slashHighlight,
                    onHighlight = { slashHighlight = it },
                    onPick = ::chooseCommand,
                    onRetry = onReloadCommands,
                )
            }
            composer.reference?.let { menu ->
                ReferenceMenuView(menu = menu, onPick = { value ->
                    val selected = if (value in menu.sessions) "@$value " else "$value "
                    onDraftChange(selected)
                    onPickReference(value)
                })
            }
        }
        if (pendingQuestion != null) {
            val plan = pendingQuestion.questionItems.singleOrNull()?.takeIf {
                it.intentKind == PLAN_REVIEW_INTENT && !it.detail.isNullOrBlank() &&
                    !it.approveWireLabel.isNullOrBlank()
            }
            if (plan != null) {
                PlanReviewTakeover(
                    question = pendingQuestion,
                    item = plan,
                    onApprove = { json ->
                        (planApproveAvailability as? PdshActionAvailability.Available)?.callback?.invoke(pendingQuestion, json)
                    },
                    onRequestChanges = {
                        (planRequestChangesAvailability as? PdshActionAvailability.Available)?.callback?.invoke(pendingQuestion)
                    },
                    canApprove = planApproveAvailability is PdshActionAvailability.Available && pendingQuestion.channelAvailable == true,
                    canRequestChanges = planRequestChangesAvailability is PdshActionAvailability.Available,
                )
            } else {
                QuestionTakeover(
                    question = pendingQuestion,
                    onSubmit = { json -> onSubmitAnswer(pendingQuestion, json) },
                    onDismiss = { onDismissQuestion(pendingQuestion) },
                    canSubmit = availability.answerQuestions && pendingQuestion.channelAvailable == true,
                    canDismiss = availability.dismissQuestions,
                    imageSource = imageSource,
                    maxHeight = minOf(
                        LocalConfiguration.current.screenHeightDp.dp * 0.6f,
                        ChatMetrics.QUESTION_MAX_HEIGHT_PT.dp,
                    ),
                )
            }
        } else Composer(
                // The dock is floored at the iOS-measured collapsed composer height
                // (94 pt since commit `86a39aac`; `ChatMetrics.COMPOSER_HEIGHT_PT`
                // carries the commit reference, not a guess). The card's own padding
                // stack already draws more than this, so the floor pins the page's
                // number against a collapse rather than adding space today. The outer
                // *bottom* margin the same commit took from 8 to 0 is applied by the
                // Composer surface itself (the source-owned zero bottom margin), not
                // by this page, so it stays a separate follow-up.
                modifier = Modifier.heightIn(min = ChatMetrics.composerHeight),
                text = composer.draft,
                onTextChange = onDraftChange,
                placeholder = composer.placeholder,
                enabled = composer.enabled,
                canSubmit = canSubmit,
                running = showRunningStop,
                steer = composer.steering,
                onSend = ::submitComposer,
                onStop = { stopRequest?.invoke(nextQueueActionRequestId()) },
                stat = state.stats,
                contextPercent = state.contextPercent,
                sessionStats = state.sessionStats,
                tokenUsage = state.tokenUsage,
                contextPressure = state.contextPressure,
                contextBreakdown = state.contextBreakdown,
                statsMode = state.composerStatsMode,
                outerTopInset = if (hasDockRows) Dp(0f) else null,
                onTruncated = { truncated = true },
                onMenuKey = ::handleSlashKey,
                onMenuSubmit = {
                    if (slashMenu == null) {
                        false
                    } else {
                        slashCommands.getOrNull(slashHighlight)?.let { chooseCommand(it.name) }
                        true
                    }
                },
                controls = {
                    ComposerControls(
                        state = state,
                        availability = availability,
                        onSpeakRecentReply = onSpeakRecentReply,
                        onDraftChange = onDraftChange,
                        onAddImages = onAddImages,
                        onAddFiles = onAddFiles,
                        onSelectAccessMode = onSelectAccessMode,
                        onRetryAccessModes = onRetryAccessModes,
                        onSelectModel = onSelectModel,
                    )
                },
        )
    }
}

/**
 * The goal bar (iOS `goalBar`): the phase label, the one-line objective and the
 * pause/resume/clear actions.
 */
@Composable
private fun GoalBarView(
    goal: GoalBarState.Visible,
    onPause: (() -> Unit)?,
    onResume: (() -> Unit)?,
    onClear: (() -> Unit)?,
    onOpenDetail: (() -> Unit)?,
) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .height(ChatMetrics.GOAL_BAR_HEIGHT_PT.dp)
            .testTag(UiTags.GOAL_BAR)
            .background(tokens.colors.selector, RoundedCornerShape(ChatMetrics.GOAL_BAR_RADIUS_PT.dp))
            .then(
                if (onOpenDetail != null) {
                    Modifier.clickable(role = Role.Button, onClick = onOpenDetail)
                } else {
                    Modifier
                },
            )
            .padding(horizontal = ChatMetrics.GOAL_BAR_INSET_H_PT.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(ChatMetrics.GOAL_BAR_GAP_PT.dp),
    ) {
            PdshIconView(
                icon = PdshIcon.GAUGE,
                size = ChatMetrics.GOAL_BAR_ICON_SIZE_PT.dp,
                tint = tokens.colors.secondary,
                contentDescription = null,
            )
        Column(modifier = Modifier.weight(1f)) {
            BasicText(
                text = goalBarPhaseLabel(goal.phase),
                style = type.caption.copy(fontSize = ChatMetrics.GOAL_BAR_PHASE_SIZE_PT.sp, color = tokens.colors.secondary),
                maxLines = 1,
            )
            BasicText(
                text = goal.objective,
                style = type.secondary.copy(fontSize = ChatMetrics.GOAL_BAR_OBJECTIVE_SIZE_PT.sp, color = tokens.colors.secondary),
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }
        if (goal.phase == PHASE_ACTIVE && onPause != null) {
            BasicText(
                text = UiStrings.GOAL_PAUSE,
                style = type.caption.copy(fontSize = ChatMetrics.GOAL_BAR_ACTION_SIZE_PT.sp, color = tokens.colors.secondary),
                modifier = Modifier
                    .clickable(role = Role.Button, onClick = onPause)
                    .testTag(UiPageTags.GOAL_PAUSE)
                    .padding(tokens.spacing.iconText),
            )
        } else if ((goal.phase == PHASE_PAUSED || goal.phase == PHASE_BLOCKED) && onResume != null) {
            BasicText(
                text = UiStrings.GOAL_RESUME,
                style = type.caption.copy(fontSize = ChatMetrics.GOAL_BAR_ACTION_SIZE_PT.sp, color = tokens.colors.secondary),
                modifier = Modifier
                    .clickable(role = Role.Button, onClick = onResume)
                    .testTag(UiPageTags.GOAL_RESUME)
                    .padding(tokens.spacing.iconText),
            )
        }
        Box(
            modifier = Modifier
                .clickable(enabled = onClear != null, role = Role.Button, onClick = { onClear?.invoke() })
                .semantics { contentDescription = UiStrings.GOAL_CLEAR_TARGET }
                .testTag(UiPageTags.GOAL_CLEAR)
                .padding(tokens.spacing.iconText),
        ) {
            PdshIconView(PdshIcon.CLOSE, ChatMetrics.GOAL_CLEAR_GLYPH_PT.dp, tokens.colors.secondary, null)
        }
    }
}

/** Structured task projection at the top of the iOS composer dock. */
@Composable
private fun TodoDock(items: List<TodoDockItem>, modifier: Modifier = Modifier) {
    val todos = items.filter { it.status in setOf(TODO_COMPLETED, TODO_IN_PROGRESS, TODO_PENDING) }
    if (todos.isEmpty()) return
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    var collapsed by remember(items) { mutableStateOf(true) }
    val completed = todos.count { it.status == TODO_COMPLETED }
    val active = todos.count { it.status == TODO_IN_PROGRESS }
    val pending = todos.count { it.status == TODO_PENDING }
    val progress = buildList {
        if (completed > 0) add("$completed 已完成")
        if (active > 0) add("$active 进行中")
        if (pending > 0) add("$pending 待处理")
    }.joinToString("\u2002·\u2002")
    Column(
        modifier = modifier
            .fillMaxWidth()
            .shadow(ChatMetrics.TODO_DOCK_SHADOW_PT.dp, RoundedCornerShape(ChatMetrics.TODO_DOCK_RADIUS_PT.dp))
            .background(tokens.colors.selector, RoundedCornerShape(ChatMetrics.TODO_DOCK_RADIUS_PT.dp))
            .border(tokens.stroke.hairline, tokens.colors.borderLight, RoundedCornerShape(ChatMetrics.TODO_DOCK_RADIUS_PT.dp))
            .padding(
                horizontal = ChatMetrics.TODO_DOCK_INSET_H_PT.dp,
                vertical = ChatMetrics.TODO_DOCK_INSET_V_PT.dp,
            ),
        verticalArrangement = Arrangement.spacedBy(ChatMetrics.TODO_DOCK_GAP_PT.dp),
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .defaultMinSize(minHeight = ChatMetrics.TODO_DOCK_HEADER_LINE_PT.dp)
                .clickable(role = Role.Button) { collapsed = !collapsed }
                .semantics {
                    contentDescription = "任务 $progress"
                    stateDescription = if (collapsed) "已折叠" else "已展开"
                }
                .testTag(TODO_DOCK_TAG),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(tokens.spacing.iconText),
        ) {
            PdshIconView(PdshIcon.LIST, ChatMetrics.TODO_DOCK_GLYPH_PT.dp, tokens.colors.secondary, null)
            BasicText("任务", style = type.secondary.copy(fontSize = ChatMetrics.TODO_TEXT_SIZE_PT.sp, color = tokens.colors.primary))
            BasicText(
                progress,
                style = type.secondary.copy(fontSize = ChatMetrics.TODO_TEXT_SIZE_PT.sp, color = tokens.colors.tertiary),
                modifier = Modifier.weight(1f),
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            PdshIconView(
                icon = if (collapsed) PdshIcon.CHEVRON_DOWN else PdshIcon.CHEVRON_UP,
                size = ChatMetrics.TODO_DOCK_CHEVRON_PT.dp,
                tint = tokens.colors.tertiary,
                contentDescription = null,
            )
        }
        if (!collapsed) {
            Column(
                modifier = Modifier.heightIn(max = ChatMetrics.TODO_LIST_MAX_HEIGHT_PT.dp).verticalScroll(rememberScrollState()),
                verticalArrangement = Arrangement.spacedBy(ChatMetrics.TODO_DOCK_GAP_PT.dp),
            ) {
                todos.forEach { item ->
                    val status = when (item.status) {
                        TODO_COMPLETED -> "已完成" to tokens.colors.success
                        TODO_IN_PROGRESS -> "进行中" to tokens.colors.accent
                        else -> "待处理" to tokens.colors.tertiary
                    }
                    Row(
                        modifier = Modifier.fillMaxWidth().defaultMinSize(minHeight = ChatMetrics.TODO_ROW_HEIGHT_PT.dp)
                            .testTag(TODO_DOCK_ROW_TAG + item.id)
                            .semantics(mergeDescendants = true) {
                                contentDescription = "${status.first}，${item.content}"
                            },
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(ChatMetrics.TODO_STATUS_GAP_PT.dp),
                    ) {
                        Box(Modifier.size(ChatMetrics.TODO_STATUS_DOT_PT.dp).clip(CircleShape).background(status.second))
                        BasicText(item.content, style = type.secondary.copy(fontSize = ChatMetrics.TODO_TEXT_SIZE_PT.sp, color = tokens.colors.secondary), maxLines = 1, overflow = TextOverflow.Ellipsis)
                    }
                }
            }
        }
    }
}

/** The phase label: the exact iOS table, never the host's wire word. */
private fun goalBarPhaseLabel(phase: String): String = when (phase) {
    PHASE_ACTIVE -> UiStrings.GOAL_PHASE_ACTIVE
    PHASE_PAUSED -> UiStrings.GOAL_PHASE_PAUSED
    PHASE_BLOCKED -> UiStrings.GOAL_PHASE_BLOCKED
    else -> UiStrings.GOAL_PHASE_COMPLETE
}

/** The source QueueDock combines host durable rows with display-only local drafts. */
private fun buildChatQueueRows(
    managedRows: List<ManagedQueueItemState>?,
    composerQueued: List<String>,
): List<ManagedQueueItemState> {
    val managed = managedRows.orEmpty()
    val durable = managed.filter { it.id is QueueItemId.Durable && it.state != QueueItemStatus.SENDING }
    val local = managed.filter { it.id is QueueItemId.Local && it.state != QueueItemStatus.SENDING }.toMutableList()
    val fallback = composerQueued.toMutableList()
    local.forEach { row ->
        val key = queueTextKey(row.text)
        val index = fallback.indexOfFirst { queueTextKey(it) == key }
        if (index >= 0) fallback.removeAt(index)
    }
    local += fallback.mapIndexed { index, text ->
        ManagedQueueItemState(
            id = QueueItemId.Local("composer-$index"),
            text = text,
            state = QueueItemStatus.QUEUED,
        )
    }
    return reconcileQueueRows(durable, local)
}

private fun queueTextKey(text: String): String =
    text.trim().split(Regex("\\s+")).filter(String::isNotEmpty).joinToString(" ")

private fun queueItemKey(id: QueueItemId): String = when (id) {
    is QueueItemId.Durable -> "durable:${id.value}"
    is QueueItemId.Local -> "local:${id.value}"
}

/** Independent pending submissions stay visible above the composer while the host dispatches them. */
@Composable
private fun PendingQueueSubmissionRows(rows: List<ManagedQueueItemState>) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    Column(
        modifier = Modifier.fillMaxWidth().testTag("pdsh.chat.queue-pending"),
        verticalArrangement = Arrangement.spacedBy(ChatMetrics.CHAT_QUEUE_PENDING_STACK_GAP_PT.dp),
    ) {
        rows.forEach { row ->
            val key = queueItemKey(row.id)
            Row(
                modifier = Modifier.fillMaxWidth()
                    .padding(horizontal = ChatMetrics.CHAT_QUEUE_PENDING_INSET_H_PT.dp)
                    .height(ChatMetrics.CHAT_QUEUE_PENDING_HEIGHT_PT.dp)
                    .background(tokens.colors.surface, RoundedCornerShape(ChatMetrics.QUEUE_ROW_RADIUS_PT.dp))
                    .semantics(mergeDescendants = true) {
                        contentDescription = "${UiStrings.CHAT_QUEUE_SENDING}：${row.text.lineSequence().firstOrNull().orEmpty()}"
                    }
                    .testTag("pdsh.chat.queue-pending.$key")
                    .padding(horizontal = tokens.spacing.iconText),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(ChatMetrics.CHAT_QUEUE_PENDING_CONTENT_GAP_PT.dp),
            ) {
                CircularProgressIndicator(
                    color = tokens.colors.tertiary,
                    strokeWidth = tokens.stroke.hairline,
                    modifier = Modifier.size(ChatMetrics.CHAT_QUEUE_PENDING_SPINNER_PT.dp),
                )
                BasicText(
                    text = UiStrings.CHAT_QUEUE_SENDING,
                    style = type.secondary.copy(fontSize = ChatMetrics.CHAT_QUEUE_PENDING_TEXT_PT.sp, color = tokens.colors.secondary),
                )
                BasicText(
                    text = row.text.lineSequence().firstOrNull().orEmpty(),
                    style = type.secondary.copy(fontSize = ChatMetrics.CHAT_QUEUE_PENDING_TEXT_PT.sp, color = tokens.colors.tertiary),
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.weight(1f),
                )
            }
        }
    }
}

private fun queueActionPending(item: ManagedQueueItemState): Boolean =
    item.busy == true || item.actionRequestId != null && item.receipt?.requestId != item.actionRequestId

private fun queueActionStatus(item: ManagedQueueItemState): String? {
    if (item.busy == true) return UiStrings.CHAT_QUEUE_ACTION_BUSY
    val actionID = item.actionRequestId
    val receipt = item.receipt
    if (actionID != null && receipt?.requestId != actionID) {
        return if (receipt == null) UiStrings.CHAT_QUEUE_ACTION_PENDING else UiStrings.CHAT_QUEUE_ACTION_STALE
    }
    return when (receipt?.outcome) {
        com.phonedsh.ui.state.CommandOutcome.FAILED -> receipt.message ?: UiStrings.CHAT_QUEUE_ACTION_FAILED
        com.phonedsh.ui.state.CommandOutcome.SUCCEEDED -> receipt.message
        null -> null
    }
}

/** The source QueueDock: one row has no header, multiple rows fold by default. */
@Composable
private fun QueueDock(
    rows: List<ManagedQueueItemState>,
    running: Boolean,
    expanded: Boolean,
    onToggleExpanded: () -> Unit,
    editAvailability: PdshActionAvailability<(ManagedQueueItemState, String, StateRequestId) -> Unit>,
    removeAvailability: PdshActionAvailability<(ManagedQueueItemState, StateRequestId) -> Unit>,
    steerAvailability: PdshActionAvailability<(ManagedQueueItemState, StateRequestId) -> Unit>,
    onEdit: (ManagedQueueItemState) -> Unit,
) {
    if (rows.isEmpty()) return
    val tokens = LocalUiTokens.current
    val edit = (editAvailability as? PdshActionAvailability.Available)?.callback
    val remove = (removeAvailability as? PdshActionAvailability.Available)?.callback
    val steer = (steerAvailability as? PdshActionAvailability.Available)?.callback
    val busy = rows.any(::queueActionPending)
    val showRows = rows.size == 1 || expanded || busy
    val shape = RoundedCornerShape(tokens.radius.card)
    Column(
        modifier = Modifier.fillMaxWidth().testTag(UiTags.COMPOSER_QUEUE)
            .clip(shape).background(tokens.colors.surface)
            .border(tokens.stroke.hairline, tokens.colors.border, shape)
            .padding(vertical = ChatMetrics.CHAT_QUEUE_CARD_INSET_V_PT.dp),
        verticalArrangement = Arrangement.spacedBy(ChatMetrics.CHAT_QUEUE_STACK_GAP_PT.dp),
    ) {
        if (rows.size > 1) {
            // interaction.md §7 rule 1/4: the queue's whole row list is one
            // `motion.disclosure` unit; the header stays outside the animated
            // body (rule 6) and its chevron rotates in place (rule 3).
            PdshDisclosure(
                expanded = showRows,
                onToggle = { if (!busy) onToggleExpanded() },
                tag = QUEUE_DISCLOSURE_TAG,
                anchorKey = rows.size,
                header = {
                    QueueDockHeader(rows = rows, showRows = showRows)
                },
                body = {
                    QueueDockBody(
                        rows = rows,
                        running = running,
                        edit = edit,
                        remove = remove,
                        steer = steer,
                        onEdit = onEdit,
                    )
                },
            )
        } else if (showRows) {
            QueueDockBody(
                rows = rows,
                running = running,
                edit = edit,
                remove = remove,
                steer = steer,
                onEdit = onEdit,
            )
        }
    }
}

/** The disclosure header: count, glyph and rotating chevron (interaction §7 rule 3). */
@Composable
private fun QueueDockHeader(
    rows: List<ManagedQueueItemState>,
    showRows: Boolean,
) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    Row(
        modifier = Modifier.fillMaxWidth()
            // The card's 4 pt row rhythm used to come from its Column spacing;
            // inside the disclosure the header owns the gap before the body.
            .padding(bottom = ChatMetrics.CHAT_QUEUE_STACK_GAP_PT.dp)
            .height(ChatMetrics.CHAT_QUEUE_HEADER_HEIGHT_PT.dp)
            .padding(horizontal = ChatMetrics.CHAT_QUEUE_ROW_INSET_H_PT.dp)
            .semantics(mergeDescendants = true) {
                contentDescription = UiStrings.CHAT_QUEUE_HEADER_COUNT.format(rows.size)
                stateDescription = if (showRows) UiStrings.EXPANDED else UiStrings.COLLAPSED
            },
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(ChatMetrics.CHAT_QUEUE_HEADER_GAP_PT.dp),
    ) {
        PdshIconView(PdshIcon.LIST, ChatMetrics.CHAT_QUEUE_HEADER_ICON_PT.dp, tokens.colors.secondary, null)
        BasicText(
            text = UiStrings.CHAT_QUEUE_HEADER_COUNT.format(rows.size),
            style = type.secondary.copy(
                fontSize = ChatMetrics.CHAT_QUEUE_HEADER_FONT_PT.sp,
                fontWeight = androidx.compose.ui.text.font.FontWeight.Medium,
                color = tokens.colors.secondary,
            ),
        )
        Spacer(Modifier.weight(1f))
        PdshChevron(
            expanded = showRows,
            size = ChatMetrics.CHAT_QUEUE_HEADER_CHEVRON_PT.dp,
            tint = tokens.colors.secondary,
        )
    }
}

/** The animated body: all rows and their dividers, one disclosure unit (rule 4). */
@Composable
private fun QueueDockBody(
    rows: List<ManagedQueueItemState>,
    running: Boolean,
    edit: ((ManagedQueueItemState, String, StateRequestId) -> Unit)?,
    remove: ((ManagedQueueItemState, StateRequestId) -> Unit)?,
    steer: ((ManagedQueueItemState, StateRequestId) -> Unit)?,
    onEdit: (ManagedQueueItemState) -> Unit,
) {
    val tokens = LocalUiTokens.current
    Column(verticalArrangement = Arrangement.spacedBy(ChatMetrics.CHAT_QUEUE_STACK_GAP_PT.dp)) {
        rows.forEachIndexed { index, item ->
            QueueDockRow(
                item = item,
                showsLeadingGlyph = rows.size == 1,
                running = running,
                edit = edit,
                remove = remove,
                steer = steer,
                onEdit = onEdit,
            )
            if (index < rows.lastIndex) {
                Box(
                    Modifier.fillMaxWidth()
                        .padding(start = if (rows.size == 1) ChatMetrics.CHAT_QUEUE_DIVIDER_INSET_PT.dp else ChatMetrics.CHAT_QUEUE_ROW_INSET_H_PT.dp)
                        .height(tokens.stroke.hairline).background(tokens.colors.border),
                )
            }
        }
    }
}

@Composable
private fun QueueDockRow(
    item: ManagedQueueItemState,
    showsLeadingGlyph: Boolean,
    running: Boolean,
    edit: ((ManagedQueueItemState, String, StateRequestId) -> Unit)?,
    remove: ((ManagedQueueItemState, StateRequestId) -> Unit)?,
    steer: ((ManagedQueueItemState, StateRequestId) -> Unit)?,
    onEdit: (ManagedQueueItemState) -> Unit,
) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    val durable = item.id is QueueItemId.Durable
    val pending = queueActionPending(item)
    val receiptText = queueActionStatus(item)
    val key = queueItemKey(item.id)
    val localReason = UiStrings.CHAT_QUEUE_LOCAL_ACTION_UNAVAILABLE
    val editReason = when {
        !durable -> localReason
        pending -> receiptText ?: UiStrings.CHAT_QUEUE_ACTION_PENDING
        item.text.isBlank() -> UiStrings.CHAT_QUEUE_EDIT_NOT_TEXT
        item.canEdit != true -> UiStrings.UNAVAILABLE
        edit == null -> UiStrings.UNAVAILABLE
        else -> null
    }
    val removeReason = when {
        !durable -> localReason
        pending -> receiptText ?: UiStrings.CHAT_QUEUE_ACTION_PENDING
        item.canRemove != true -> UiStrings.UNAVAILABLE
        remove == null -> UiStrings.UNAVAILABLE
        else -> null
    }
    val steerReason = when {
        !durable -> localReason
        pending -> receiptText ?: UiStrings.CHAT_QUEUE_ACTION_PENDING
        !running -> UiStrings.CHAT_QUEUE_STEER_UNAVAILABLE
        item.canSteer != true -> UiStrings.UNAVAILABLE
        steer == null -> UiStrings.UNAVAILABLE
        else -> null
    }
    Column(
        modifier = Modifier.fillMaxWidth().testTag("${UiTags.COMPOSER_QUEUE}.row.$key"),
        verticalArrangement = Arrangement.spacedBy(ChatMetrics.CHAT_QUEUE_STACK_GAP_PT.dp),
    ) {
        Row(
            modifier = Modifier.fillMaxWidth()
                .padding(horizontal = ChatMetrics.CHAT_QUEUE_ROW_INSET_H_PT.dp)
                .defaultMinSize(minHeight = ChatMetrics.CHAT_QUEUE_ROW_MIN_HEIGHT_PT.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(ChatMetrics.CHAT_QUEUE_ROW_GAP_PT.dp),
        ) {
            if (showsLeadingGlyph) {
                PdshIconView(PdshIcon.LIST, ChatMetrics.CHAT_QUEUE_ROW_GLYPH_PT.dp, tokens.colors.tertiary, null)
            }
            BasicText(
                text = item.text.lineSequence().firstOrNull().orEmpty(),
                style = type.caption.copy(fontSize = ChatMetrics.CHAT_QUEUE_ROW_FONT_PT.sp, color = tokens.colors.secondary),
                modifier = Modifier.weight(1f),
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            if (item.state == QueueItemStatus.SENDING) {
                BasicText(UiStrings.CHAT_QUEUE_SENDING, style = type.caption.copy(color = tokens.colors.tertiary))
                QueueActionIcon(PdshIcon.PENCIL, UiStrings.CHAT_QUEUE_EDIT_TITLE, UiStrings.CHAT_QUEUE_ACTION_BUSY, false)
                QueueActionIcon(PdshIcon.TRASH, UiStrings.CHAT_QUEUE_DELETE, UiStrings.CHAT_QUEUE_ACTION_BUSY, false)
                QueueActionIcon(PdshIcon.SEND, UiStrings.CHAT_QUEUE_STEER_SEND, UiStrings.CHAT_QUEUE_ACTION_BUSY, false)
            } else {
                QueueActionIcon(PdshIcon.PENCIL, UiStrings.CHAT_QUEUE_EDIT_TITLE, editReason, editReason == null) {
                    onEdit(item)
                }
                QueueActionIcon(PdshIcon.TRASH, UiStrings.CHAT_QUEUE_DELETE, removeReason, removeReason == null) {
                    remove?.invoke(item, nextQueueActionRequestId())
                }
                QueueActionIcon(PdshIcon.SEND, UiStrings.CHAT_QUEUE_STEER_SEND, steerReason, steerReason == null) {
                    steer?.invoke(item, nextQueueActionRequestId())
                }
            }
        }
        receiptText?.let { status ->
            BasicText(
                text = status,
                style = type.caption.copy(color = if (item.receipt?.outcome == com.phonedsh.ui.state.CommandOutcome.FAILED) tokens.colors.danger else tokens.colors.tertiary),
                modifier = Modifier.fillMaxWidth().padding(horizontal = ChatMetrics.CHAT_QUEUE_ROW_INSET_H_PT.dp)
                    .testTag("${UiTags.COMPOSER_QUEUE}.receipt.$key"),
            )
        }
    }
}

@Composable
private fun QueueActionIcon(
    icon: PdshIcon,
    label: String,
    unavailableReason: String?,
    enabled: Boolean,
    onClick: (() -> Unit)? = null,
) {
    val tokens = LocalUiTokens.current
    Box(
        modifier = Modifier.size(width = ChatMetrics.CHAT_QUEUE_ACTION_TARGET_WIDTH_PT.dp, height = ChatMetrics.CHAT_QUEUE_ACTION_TARGET_HEIGHT_PT.dp)
            .clickable(enabled = enabled && onClick != null, role = Role.Button) { onClick?.invoke() }
            .semantics { contentDescription = if (unavailableReason == null) label else "$label，$unavailableReason" },
        contentAlignment = Alignment.Center,
    ) {
        PdshIconView(
            icon,
            ChatMetrics.CHAT_QUEUE_ACTION_GLYPH_PT.dp,
            if (enabled) tokens.colors.secondary else tokens.colors.tertiary,
            contentDescription = null,
            modifier = Modifier.size(ChatMetrics.CHAT_QUEUE_ACTION_ICON_BOX_PT.dp),
        )
    }
}

private fun nextQueueActionRequestId(): StateRequestId =
    StateRequestId("ui.queue.${java.util.UUID.randomUUID()}")

@Composable
private fun QueueEditOverlay(
    item: ManagedQueueItemState,
    value: String,
    onValueChange: (String) -> Unit,
    canSave: Boolean,
    onCancel: () -> Unit,
    onSave: () -> Unit,
) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    Box(
        modifier = Modifier.fillMaxSize().background(tokens.colors.primary.copy(alpha = 0.32f))
            .testTag("pdsh.chat.queue-edit-dialog"),
        contentAlignment = Alignment.Center,
    ) {
        Column(
            modifier = Modifier.fillMaxWidth().padding(horizontal = HomeMetrics.chromeInset)
                .clip(RoundedCornerShape(tokens.radius.card)).background(tokens.colors.surface)
                .padding(tokens.spacing.cardInset),
            verticalArrangement = Arrangement.spacedBy(tokens.spacing.iconText),
        ) {
            BasicText(UiStrings.CHAT_QUEUE_EDIT_TITLE, style = type.headline.copy(color = tokens.colors.primary))
            BasicText(item.text, style = type.caption.copy(color = tokens.colors.tertiary), maxLines = 2, overflow = TextOverflow.Ellipsis)
            BasicTextField(
                value = value,
                onValueChange = onValueChange,
                textStyle = type.secondary.copy(color = tokens.colors.primary),
                cursorBrush = SolidColor(tokens.colors.accent),
                modifier = Modifier.fillMaxWidth().testTag("pdsh.chat.queue-edit-field"),
                decorationBox = { inner ->
                    Box(
                        Modifier.fillMaxWidth().background(tokens.colors.input, RoundedCornerShape(tokens.radius.card))
                            .padding(tokens.spacing.cardInset),
                    ) {
                        if (value.isEmpty()) BasicText(UiStrings.CHAT_QUEUE_EDIT_CONTENT, style = type.secondary.copy(color = tokens.colors.tertiary))
                        inner()
                    }
                },
            )
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(tokens.spacing.iconText, Alignment.End),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                BasicText(UiStrings.CANCEL, style = type.secondary.copy(color = tokens.colors.secondary),
                    modifier = Modifier.clickable(role = Role.Button, onClick = onCancel).testTag("pdsh.chat.queue-edit-cancel").padding(tokens.spacing.iconText))
                BasicText(UiStrings.SAVE, style = type.secondary.copy(color = if (canSave) tokens.colors.accent else tokens.colors.tertiary),
                    modifier = Modifier.clickable(enabled = canSave, role = Role.Button, onClick = onSave).testTag("pdsh.chat.queue-edit-save").padding(tokens.spacing.iconText))
            }
        }
    }
}

/** The pending-attachment chips with their remove keys (iOS `attachmentStrip`). */
@Composable
private fun AttachmentStrip(
    attachments: List<com.phonedsh.ui.state.ChatAttachment>,
    onRemove: (Int) -> Unit,
) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .testTag(UiPageTags.COMPOSER_ATTACHMENTS),
        horizontalArrangement = Arrangement.spacedBy(tokens.spacing.iconText),
    ) {
        attachments.forEachIndexed { index, attachment ->
            Row(
                modifier = Modifier
                    .background(tokens.colors.selector, CircleShape)
                    .padding(start = tokens.spacing.badgeInsetH, end = tokens.spacing.iconText),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(tokens.spacing.copyGap),
            ) {
                PdshIconView(PdshIcon.DOCUMENT, ChatMetrics.ATTACHMENT_DOCUMENT_GLYPH_PT.dp, tokens.colors.secondary, null)
                BasicText(
                    text = attachment.name,
                    style = type.caption.copy(color = tokens.colors.primary),
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
                Box(
                    modifier = Modifier
                        .clickable(role = Role.Button) { onRemove(index) }
                        .semantics {
                            contentDescription = UiStrings.COMPOSER_REMOVE_IMAGE.format(attachment.name)
                        }
                        .padding(tokens.spacing.iconText),
                ) { PdshIconView(PdshIcon.CLOSE, ChatMetrics.ATTACHMENT_REMOVE_GLYPH_PT.dp, tokens.colors.secondary, null) }
            }
        }
    }
}

/** One notice line: the text and the 关闭 verb (iOS attachmentError / fileImportNotice). */
@Composable
private fun NoticeLine(
    text: String,
    onClose: () -> Unit,
) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .testTag(UiPageTags.CHAT_COMPOSER_NOTICE),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(tokens.spacing.codeToolbar),
    ) {
        BasicText(
            text = text,
            style = type.caption.copy(color = tokens.colors.secondary),
            modifier = Modifier.weight(1f),
        )
        BasicText(
            text = UiStrings.COMPOSER_NOTICE_CLOSE,
            style = type.caption.copy(color = tokens.colors.accent),
            modifier = Modifier
                .clickable(role = Role.Button, onClick = onClose)
                .padding(tokens.spacing.iconText),
        )
    }
}

/**
 * The in-place `/` menu (iOS `slashCommandMenu`): the live catalog's names and
 * hints, a loading line, the read failure with its retry, or "没有匹配的命令".
 */
@Composable
private fun SlashMenuView(
    menu: SlashMenu,
    highlightedIndex: Int,
    onHighlight: (Int) -> Unit,
    onPick: (String) -> Unit,
    onRetry: () -> Unit,
) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .testTag(UiPageTags.COMPOSER_SLASH_MENU)
            .background(tokens.colors.selector, RoundedCornerShape(tokens.radius.card)),
    ) {
        when (menu) {
            is SlashMenu.Loading -> Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(tokens.spacing.cardInset),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(tokens.spacing.codeToolbar),
            ) {
                CircularProgressIndicator(
                    color = tokens.colors.tertiary,
                    strokeWidth = tokens.stroke.hairline,
                    modifier = Modifier.size(tokens.geometry.composerControlSize),
                )
                BasicText(
                    text = UiStrings.COMPOSER_SLASH_LOADING,
                    style = type.secondary.copy(color = tokens.colors.secondary),
                )
            }

            is SlashMenu.Failed -> Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(tokens.spacing.cardInset),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(tokens.spacing.codeToolbar),
            ) {
                BasicText(
                    text = menu.message,
                    style = type.secondary.copy(color = tokens.colors.warning),
                    modifier = Modifier.weight(1f),
                )
                BasicText(
                    text = UiStrings.RETRY,
                    style = type.secondary.copy(color = tokens.colors.accent),
                    modifier = Modifier
                        .clickable(role = Role.Button, onClick = onRetry)
                        .padding(tokens.spacing.iconText),
                )
            }

            is SlashMenu.Matches -> menu.commands.forEachIndexed { index, command ->
                SlashCommandRow(
                    command = command,
                    highlighted = index == highlightedIndex,
                    onHighlight = { onHighlight(index) },
                    onPick = onPick,
                )
            }

            is SlashMenu.Empty -> BasicText(
                text = UiStrings.COMPOSER_SLASH_EMPTY,
                style = type.secondary.copy(color = tokens.colors.secondary),
                modifier = Modifier.padding(tokens.spacing.cardInset),
            )
        }
    }
}

/** One command line: `/name` in 15 pt semibold, its hint in 12 pt secondary. */
@Composable
private fun SlashCommandRow(
    command: ComposerCommand,
    highlighted: Boolean,
    onHighlight: () -> Unit,
    onPick: (String) -> Unit,
) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .background(if (highlighted) tokens.colors.selector else Color.Transparent, RoundedCornerShape(tokens.radius.card))
            .clickable(role = Role.Button) { onHighlight(); onPick(command.name) }
            .semantics { selected = highlighted }
            .testTag(SLASH_COMMAND_TAG_PREFIX + command.name)
            .padding(
                horizontal = tokens.spacing.cardInset,
                vertical = tokens.spacing.codeToolbar,
            ),
    ) {
        BasicText(
            text = "/${command.name}",
            style = type.subheadline.copy(color = tokens.colors.primary),
        )
        BasicText(
            text = command.description,
            style = type.caption.copy(color = tokens.colors.secondary),
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
    }
}

/** The in-place `@` menu (iOS `referenceMenu`): matching files, then sessions. */
@Composable
private fun ReferenceMenuView(
    menu: ReferenceMenu,
    onPick: (String) -> Unit,
) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .testTag(UiPageTags.COMPOSER_REFERENCE_MENU)
            .background(tokens.colors.selector, RoundedCornerShape(tokens.radius.card)),
    ) {
        if (menu.isEmpty) {
            BasicText(
                text = UiStrings.COMPOSER_REFERENCE_EMPTY,
                style = type.secondary.copy(color = tokens.colors.secondary),
                modifier = Modifier.padding(tokens.spacing.cardInset),
            )
        }
        menu.files.forEach { path ->
            // The row's name is data (a workspace path), so the container takes the
            // click and the text only draws the value.
            Box(
                modifier = Modifier
                    .fillMaxWidth()
                    .clickable(role = Role.Button) { onPick(path) }
                    .padding(
                        horizontal = tokens.spacing.cardInset,
                        vertical = tokens.spacing.codeToolbar,
                    ),
            ) {
                BasicText(
                    text = path,
                    style = type.secondary.copy(color = tokens.colors.primary),
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
            }
        }
        menu.sessions.forEach { session ->
            Box(
                modifier = Modifier
                    .fillMaxWidth()
                    .clickable(role = Role.Button) { onPick(session) }
                    .padding(
                        horizontal = tokens.spacing.cardInset,
                        vertical = tokens.spacing.codeToolbar,
                    ),
            ) {
                BasicText(
                    text = session,
                    style = type.secondary.copy(color = tokens.colors.primary),
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
            }
        }
    }
}

/**
 * The tool row docked inside the card (iOS `composerControls`): plus, permissions,
 * model, followed by the action cluster in the same constrained row.
 */
@Composable
private fun ComposerControls(
    state: ChatScreenState,
    availability: ComposerAvailability,
    onSpeakRecentReply: (() -> Unit)?,
    onDraftChange: (String) -> Unit,
    onAddImages: () -> Unit,
    onAddFiles: () -> Unit,
    onSelectAccessMode: (String) -> Unit,
    onRetryAccessModes: () -> Unit = {},
    onSelectModel: (String, String?) -> Unit,
) {
    val tokens = LocalUiTokens.current
    val composer = state.composer
    var addOpen by remember { mutableStateOf(false) }
    ComposerToolbar(
        add = {
        Box {
            Box(
                modifier = Modifier
                    .size(width = ChatMetrics.COMPOSER_CONTROL_MIN_WIDTH_PT.dp, height = ChatMetrics.COMPOSER_CONTROL_ROW_HEIGHT_PT.dp)
                    .clickable(enabled = composer.enabled, role = Role.Button) { addOpen = true }
                    .semantics { contentDescription = UiStrings.COMPOSER_ADD_MENU }
                    .testTag(UiPageTags.COMPOSER_ADD),
                contentAlignment = Alignment.Center,
            ) {
                PdshIconView(PdshIcon.PLUS, HomeMetrics.COMPOSER_ICON_PT.dp, tokens.colors.primaryButton, null)
            }
            DropdownMenu(expanded = addOpen, onDismissRequest = { addOpen = false }) {
                DropdownMenuItem(
                    text = { Text(UiStrings.COMPOSER_ADD_COMMAND) },
                    onClick = {
                        addOpen = false
                        // iOS: a leading `/` opens the command menu in place.
                        onPickSlashTrigger(onDraftChange)
                    },
                )
                DropdownMenuItem(
                    text = { Text(UiStrings.COMPOSER_ADD_REFERENCE) },
                    onClick = {
                        addOpen = false
                        onPickReferenceTrigger(onDraftChange)
                    },
                )
                if (availability.addImages) DropdownMenuItem(
                    text = { Text(UiStrings.COMPOSER_ADD_IMAGE) },
                    onClick = { addOpen = false; onAddImages() },
                )
                if (availability.addFiles) DropdownMenuItem(
                    text = { Text(UiStrings.COMPOSER_ADD_FILE) },
                    onClick = { addOpen = false; onAddFiles() },
                )
                if (availability.speakRecentReply && onSpeakRecentReply != null) DropdownMenuItem(
                    text = { Text("朗读最近回复") },
                    onClick = { addOpen = false; onSpeakRecentReply() },
                )
            }
        }
        },
        access = {
            AccessModeMenuButton(
                state = state, available = availability.selectAccessMode,
                onSelect = onSelectAccessMode, onRetry = onRetryAccessModes,
            )
        },
        model = { ModelMenuButton(state = state, available = availability.selectModel, onSelect = onSelectModel) },
    )
}

/** The permissions menu: the translated modes, the current one checked. */
@Composable
private fun AccessModeMenuButton(
    state: ChatScreenState,
    available: Boolean,
    onSelect: (String) -> Unit,
    onRetry: () -> Unit = {},
) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    val menu = state.accessModeMenu
    var confirmation by remember { mutableStateOf<AccessModeOption?>(null) }
    var open by remember { mutableStateOf(false) }
    Box {
        Row(
            modifier = Modifier
                .defaultMinSize(minWidth = ChatMetrics.COMPOSER_CONTROL_MIN_WIDTH_PT.dp)
                .height(ChatMetrics.COMPOSER_CONTROL_ROW_HEIGHT_PT.dp)
                .clickable(enabled = menu.enabled && available, role = Role.Button) {
                    // Opening the menu after a failed read starts the read again.
                    if (menu.error != null && !menu.loading) onRetry()
                    open = true
                }
                .semantics { contentDescription = UiStrings.ACCESS_MODE_LABEL.format(menu.label) }
                .testTag(UiPageTags.COMPOSER_ACCESS_MODE),
            verticalAlignment = Alignment.CenterVertically,
            // Native ChatPage.swift composerControls uses a 2pt shield/chevron gap.
            horizontalArrangement = Arrangement.spacedBy(ChatMetrics.ACCESS_MODE_ICON_GAP_PT.dp),
        ) {
            Box {
                PdshIconView(PdshIcon.LOCK_SHIELD, ChatMetrics.ACCESS_MODE_SHIELD_GLYPH_PT.dp, tokens.colors.iconMuted, null)
                if (menu.error != null && !menu.loading) {
                    // Reads failed even after the automatic retries: a quiet mark
                    // on the control (iOS orange dot), not a page banner.
                    Box(
                        modifier = Modifier
                            .align(Alignment.TopEnd)
                            .size(ChatMetrics.ACCESS_MODE_ALERT_DOT_PT.dp)
                            .background(tokens.colors.warning, androidx.compose.foundation.shape.CircleShape),
                    )
                }
            }
            if (menu.loading) {
                androidx.compose.material3.CircularProgressIndicator(
                    modifier = Modifier.size(ChatMetrics.ACCESS_MODE_CHEVRON_GLYPH_PT.dp),
                    color = tokens.colors.iconMuted,
                    strokeWidth = ChatMetrics.ACCESS_MODE_SPINNER_STROKE_PT.dp,
                )
            } else {
                PdshIconView(PdshIcon.CHEVRON_DOWN, ChatMetrics.ACCESS_MODE_CHEVRON_GLYPH_PT.dp, tokens.colors.iconMuted, null)
            }
        }
        DropdownMenu(expanded = open, onDismissRequest = { open = false }) {
            val error = menu.error
            if (error != null) {
                // iOS `Section("暂不可用") { Text(error) }`: a group title and the
                // read failure's own words. There is no page banner; opening this
                // menu already started another read.
                ChatMenuSectionLabel(text = UiStrings.ACCESS_MODE_UNAVAILABLE)
                BasicText(
                    text = error,
                    style = type.caption.copy(color = tokens.colors.warning),
                    modifier = Modifier.padding(
                        horizontal = tokens.spacing.cardInset,
                        vertical = tokens.spacing.codeToolbar,
                    ),
                )
            }
            if (menu.options.isEmpty()) {
                DropdownMenuItem(
                    text = { Text(UiStrings.ACCESS_MODE_NONE) },
                    onClick = {},
                    enabled = false,
                )
            } else {
                DropdownMenuItem(
                    text = {
                        Text(
                            if (menu.asksBeforeWrite) {
                                UiStrings.ACCESS_MODE_HEADER_ASK
                            } else {
                                UiStrings.ACCESS_MODE_HEADER_ALLOW
                            },
                        )
                    },
                    onClick = {},
                    enabled = false,
                )
                menu.options.forEach { option ->
                    ComposerMenuOption(
                        title = option.title,
                        selected = option.id == menu.currentID,
                        onClick = {
                            open = false
                            // The three most permissive ids ask for a confirmation
                            // first (iOS `confirmAccessMode`).
                            if (option.id in CONFIRM_IDS) confirmation = option else onSelect(option.id)
                        },
                    )
                }
            }
        }
    }
    val pending = confirmation
    if (pending != null) {
        val palette = materialDialogColors(tokens)
        AlertDialog(
            onDismissRequest = { confirmation = null },
            confirmButton = {
                Text(
                    text = UiStrings.ACCESS_MODE_CONFIRM_ACTION,
                    modifier = Modifier
                        .clickable(role = Role.Button) {
                            confirmation = null
                            onSelect(pending.id)
                        }
                        .padding(tokens.spacing.codeToolbar),
                )
            },
            dismissButton = {
                Text(
                    text = UiStrings.CANCEL,
                    modifier = Modifier
                        .clickable(role = Role.Button) { confirmation = null }
                        .padding(tokens.spacing.codeToolbar),
                )
            },
            title = { Text(UiStrings.ACCESS_MODE_CONFIRM_OPEN.format(pending.title)) },
            text = { Text(UiStrings.ACCESS_MODE_CONFIRM_MESSAGE) },
            containerColor = palette.container,
            textContentColor = palette.content,
        )
    }
}

/** The model menu: the model list and the effort list, one check each. */
@Composable
private fun ModelMenuButton(
    state: ChatScreenState,
    available: Boolean,
    onSelect: (String, String?) -> Unit,
) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    val menu = state.modelMenu
    val modelTint = if (menu.enabled) tokens.colors.textPrimary else tokens.colors.textPlaceholder
    val modelStyle = type.body.copy(
        color = modelTint,
    )
    var open by remember { mutableStateOf(false) }
    Box {
        Row(
            modifier = Modifier
                .height(ChatMetrics.COMPOSER_CONTROL_ROW_HEIGHT_PT.dp)
                .fillMaxWidth()
                .defaultMinSize(minHeight = tokens.geometry.composerControlSize)
                .clickable(enabled = menu.enabled && available, role = Role.Button) { open = true }
                .semantics { contentDescription = UiStrings.MODEL_LABEL }
                .testTag(UiPageTags.COMPOSER_MODEL_MENU),
            verticalAlignment = Alignment.CenterVertically,
            // HomeSpec.swift modelNameBlock uses six points between name and effort.
            horizontalArrangement = Arrangement.spacedBy(ChatMetrics.MODEL_EFFORT_GAP_PT.dp),
        ) {
            BasicText(
                text = menu.label,
                style = modelStyle,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier.weight(1f).testTag(COMPOSER_MODEL_LABEL_TAG),
            )
            if (menu.effortTitle != null) {
                BasicText(
                    text = menu.effortTitle,
                    style = modelStyle,
                    maxLines = 1,
                )
            }
            PdshIconView(PdshIcon.CHEVRON_DOWN, ChatMetrics.MODEL_MENU_CHEVRON_GLYPH_PT.dp, tokens.colors.textSecondary, null)
        }
        DropdownMenu(expanded = open, onDismissRequest = { open = false }) {
            if (menu.unavailable) {
                DropdownMenuItem(
                    text = { Text(UiStrings.MODEL_UNAVAILABLE) },
                    onClick = {},
                    enabled = false,
                )
            } else {
                if (menu.efforts.isNotEmpty()) {
                    ChatMenuSectionLabel(text = UiStrings.MODEL_SECTION_EFFORT)
                    menu.efforts.forEach { effort ->
                        ComposerMenuOption(
                            title = effort.title,
                            selected = effort.id == menu.currentEffort,
                            onClick = {
                                open = false
                                onSelect(menu.currentModel.orEmpty(), effort.id)
                            },
                        )
                    }
                    // 「默认强度」不是一档,是「按这个模型自己那档来」:
                    // 后面跟上它现在实际等于哪个档,点了才不会没底。
                    ComposerMenuOption(
                        title = menu.defaultEffortTitle,
                        selected = menu.currentEffort == null,
                        onClick = {
                            open = false
                            onSelect(menu.currentModel.orEmpty(), null)
                        },
                    )
                }
                ChatMenuSectionLabel(text = UiStrings.MODEL_SECTION_MODEL)
                menu.models.forEach { model ->
                    ComposerMenuOption(
                        title = model,
                        selected = model == menu.currentModel,
                        onClick = {
                            open = false
                            onSelect(model, menu.currentEffort)
                        },
                    )
                }
            }
        }
    }
}

/**
 * A titled group inside a composer menu (iOS `Section("强度")` / `Section("模型")`).
 *
 * The system menu draws no section chrome of its own, so the group gets a caption
 * line above its rows; the caption is a `UiStrings` word, never an assembled one.
 *
 * @param text the group's title.
 */
@Composable
private fun ChatMenuSectionLabel(text: String) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    BasicText(
        text = text,
        style = type.caption.copy(color = tokens.colors.tertiary),
        modifier = Modifier
            .fillMaxWidth()
            .padding(
                horizontal = tokens.spacing.cardInset,
                vertical = tokens.spacing.codeToolbar,
            )
            .semantics { heading() },
    )
}

/**
 * One option line of a composer menu (iOS `Label(title, systemImage: "checkmark")`).
 *
 * The offer is data (a mode title, a model name, an effort title), so the row draws
 * the title exactly as the host reports it and marks the choice with a separate
 * fixed glyph plus the `selected` semantics. Nothing here assembles a label from a
 * condition, so the drawn word and the chosen state stay two different things.
 *
 * @param title the option's visible name.
 * @param selected true for the option in force.
 * @param onClick picks it.
 */
@Composable
private fun ComposerMenuOption(
    title: String,
    selected: Boolean,
    onClick: () -> Unit,
) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .defaultMinSize(minHeight = tokens.geometry.pageRowMinHeight)
            .clickable(role = Role.Button, onClick = onClick)
            .semantics(mergeDescendants = true) { this.selected = selected }
            .padding(
                horizontal = tokens.spacing.cardInset,
                vertical = tokens.spacing.codeToolbar,
            ),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(tokens.spacing.iconText),
    ) {
        if (selected) {
            PdshIconView(PdshIcon.CHECK, ChatMetrics.COMPOSER_MENU_CHECK_GLYPH_PT.dp, tokens.colors.accent, null)
        }
        BasicText(
            text = title,
            style = type.secondary.copy(color = tokens.colors.primary),
        )
    }
}

/** The page's token inventory; `PageTokenReferenceTest` fails when a use site reads a token that is not listed here. */
internal object ChatPageTokens {
    val refs: List<String> = listOf(
        UiTokenNames.COLORS_ACCENT,
        UiTokenNames.COLORS_BACKGROUND,
        UiTokenNames.COLORS_BORDER,
        UiTokenNames.COLORS_BORDER_LIGHT,
        UiTokenNames.COLORS_CODE,
        UiTokenNames.COLORS_CTA_OVERRIDE,
        UiTokenNames.COLORS_DANGER,
        UiTokenNames.COLORS_ICON_MUTED,
        UiTokenNames.COLORS_INPUT,
        UiTokenNames.COLORS_ON_ACCENT,
        UiTokenNames.COLORS_PAGE,
        UiTokenNames.COLORS_PRIMARY,
        UiTokenNames.COLORS_INPUT_PLACEHOLDER,
        UiTokenNames.COLORS_PRIMARY_BUTTON_INK,
        UiTokenNames.COLORS_PRIMARY_BUTTON,
        UiTokenNames.COLORS_SECONDARY,
        UiTokenNames.COLORS_SELECTOR,
        UiTokenNames.COLORS_SURFACE,
        UiTokenNames.COLORS_SYSTEM_SEPARATOR,
        UiTokenNames.COLORS_SUCCESS,
        UiTokenNames.COLORS_TERTIARY,
        UiTokenNames.COLORS_TEXT_PLACEHOLDER,
        UiTokenNames.COLORS_TEXT_PRIMARY,
        UiTokenNames.COLORS_TEXT_SECONDARY,
        UiTokenNames.COLORS_WARNING,
        UiTokenNames.GEOMETRY_BANNER_GAP,
        UiTokenNames.GEOMETRY_BANNER_INSET_H,
        UiTokenNames.GEOMETRY_BANNER_INSET_V,
        UiTokenNames.GEOMETRY_CARD_AREA_MAX_HEIGHT_RATIO,
        UiTokenNames.GEOMETRY_CARD_OUTER_MARGIN_H,
        UiTokenNames.GEOMETRY_CARD_OUTER_MARGIN_V,
        UiTokenNames.GEOMETRY_CARD_PADDING,
        UiTokenNames.GEOMETRY_COMPOSER_CONTROL_SIZE,
        UiTokenNames.GEOMETRY_COMPOSER_OUTER_MARGIN_H,
        UiTokenNames.GEOMETRY_COMPOSER_OUTER_MARGIN_TOP,
        UiTokenNames.GEOMETRY_DISCLOSURE_ROW_HEIGHT,
        UiTokenNames.GEOMETRY_PAGE_HEADER_MIN_HEIGHT,
        UiTokenNames.GEOMETRY_NAV_BUTTON,
        UiTokenNames.GEOMETRY_PAGE_OUTER_MARGIN_H,
        UiTokenNames.GEOMETRY_PAGE_ROW_MIN_HEIGHT,
        UiTokenNames.GEOMETRY_PRIMARY_BUTTON_HEIGHT,
        UiTokenNames.GEOMETRY_STATUS_DOT_DIAMETER,
        UiTokenNames.GEOMETRY_TOOL_DETAIL_VERTICAL,
        UiTokenNames.RADIUS_CARD,
        UiTokenNames.RADIUS_CODE_BLOCK,
        UiTokenNames.SPACING_BADGE_INSET_H,
        UiTokenNames.SPACING_BADGE_INSET_V,
        UiTokenNames.SPACING_CARD_INSET,
        UiTokenNames.SPACING_CODE_TOOLBAR,
        UiTokenNames.SPACING_COPY_GAP,
        UiTokenNames.SPACING_ICON_TEXT,
        UiTokenNames.STROKE_HAIRLINE,
        // L24: the three embedded subpages' type roles — the iOS `.callout`-sized
        // row label and the `.monospaced` command line.
        UiTokenNames.TYPOGRAPHY_BODY,
        UiTokenNames.TYPOGRAPHY_CAPTION,
        UiTokenNames.TYPOGRAPHY_CODE,
        UiTokenNames.TYPOGRAPHY_HEADLINE,
        UiTokenNames.TYPOGRAPHY_NAV_SUBTITLE,
        UiTokenNames.TYPOGRAPHY_NAV_TITLE,
        UiTokenNames.TYPOGRAPHY_PAGE_TITLE,
        UiTokenNames.TYPOGRAPHY_SECONDARY,
        UiTokenNames.TYPOGRAPHY_SUBHEADLINE,
    )

    /** No reviewed deviations: every token this page uses is declared by the spec. */
    val gaps: List<String> = emptyList()
}

/** The `kind` of ask that submits an answer instead of allowing an action. */
private const val QUESTION: String = "question"
private const val LOCK_GLYPH: String = "⛨"
private const val COMMAND_GLYPH: String = "⌘"

/** The menu's "this one is in force" mark (iOS `Label(title, systemImage: "checkmark")`). */

/** iOS `arrow.down` on the 回到最新 capsule. */
private const val BACK_TO_LATEST_GLYPH: String = "↓"

/** The goal phases the bar translates (the host's wire words). */
private const val PHASE_ACTIVE: String = "active"
private const val PHASE_PAUSED: String = "paused"
private const val PHASE_BLOCKED: String = "blocked"

/** The modes whose switch needs a confirmation first (iOS `mode.id ==` table). */
private val CONFIRM_IDS: Set<String> = setOf("bypassPermissions", "danger-full-access", "phone")

/** The stable key of the transcript's chrome item. */
private const val CHROME_ITEM: String = "chat-transcript-chrome"

/** The rename alert's scrim opacity (the platform alert dims the page behind it). */
private const val SCRIM_ALPHA: Float = 0.25f

/** The question answer's single key (iOS `HarnessQuestionItem(id: "answer")`). */
private const val ANSWER_KEY: String = "answer"

/** iOS `errorBanner`'s wash behind a transcript failure (an 8% warning layer). */
private const val WARNING_WASH_ALPHA: Float = 0.08f

/** iOS `composerControls`' 调用指令: a bare `/` opens the command menu in place. */
private fun onPickSlashTrigger(onDraftChange: (String) -> Unit) {
    onDraftChange("/")
}

/** iOS `composerControls`' 引用文件或对话: a bare `@` opens the reference menu. */
private fun onPickReferenceTrigger(onDraftChange: (String) -> Unit) {
    onDraftChange("@")
}

// ---------------------------------------------------------------------------
// 内嵌子页 — the three surfaces the iOS page keeps beside itself
// ---------------------------------------------------------------------------
//
// README §1 line 86: 内嵌子页随父页实现、不单独排期 — CommandExecutionResultPage,
// SessionQueuePage, … are implemented with their parent page, not scheduled as
// pages of their own. The three surfaces below are the chat page's:
//
//   * `ChatPage.swift:3504` `NativeScheduleListSheet` (presented at `:445`),
//   * `ChatPage.swift:3554` `NativeJobListSheet` (presented at `:437`),
//   * `ChatPage.swift:4243` `CommandExecutionResultPage` (presented at `:407`).
//
// They live in this file because the baseline keeps them in `ChatPage.swift` as
// private structs of the same page; `PdshNavHost` additionally gives each a route
// so a screenshot test (and a host that owns the read) can open it directly.
//
// Data honesty, the rule the whole page follows:
//   * `jobs` / `schedules` are `null` when the host made no read. The baseline's
//     model arrays always exist, so it renders `没有后台任务` for an empty one; an
//     unread list must not wear that sentence, and renders the Android-only
//     `读取不到…` line instead (the same rule as `SessionActivityPage`'s 未知 rows).
//   * `刷新` is the host's read, not a local relabel: both baseline sheets call
//     the one `management.refreshActivity(sessionID:)` (`:441`, `:449`), so both
//     `刷新` actions hand off the same `PdshHostAction`. A `null` callback draws the
//     verb greyed-but-visible — an affordance the user has seen on the sheet is
//     never silently removed.

/**
 * One executed `/command` and its settlement (iOS `NativeCommandExecution`,
 * `ChatModel.swift:71`–`:77`).
 *
 * @param kind the host's own word; `success` is what makes the baseline open the
 *   result sheet (`ChatPage.swift:2516`). Kept raw so an unknown kind prints as
 *   itself instead of being coerced to a failure.
 * @param text the settlement body; `null` and `""` are the same branch (the
 *   baseline's `if let text, !text.isEmpty`).
 */
public data class ChatCommandExecution(
    public val id: String,
    public val name: String,
    public val line: String,
    public val kind: String,
    public val text: String? = null,
) {
    /** iOS `execution.kind == "success"` (`ChatPage.swift:4251`). */
    public val succeeded: Boolean get() = kind == KIND_SUCCESS
}

/** One background-job row (iOS `ActivityRow` as `NativeJobListSheet` draws it, `ChatPage.swift:3572`–`:3585`). */
public data class ChatJobRow(
    public val id: String,
    public val title: String,
    public val detail: String,
    /** The host's status word, or `null` at which the baseline draws nothing. */
    public val status: String? = null,
)

/** One scheduled-task row (iOS `ManagedSchedule` as `NativeScheduleListSheet` draws it, `ChatPage.swift:3521`–`:3540`). */
public data class ChatScheduleRow(
    public val id: String,
    public val title: String,
    public val detail: String,
    public val status: String? = null,
    /** The user's prompt; the baseline gives it two lines and only draws it when present. */
    public val prompt: String? = null,
)

/**
 * The three subpages' read-only input.
 *
 * A `null` list is "this host made no read" and a `null` execution is "no `/command`
 * ran on this host"; neither is ever `emptyList()`/a placeholder row. The host that
 * owns the read fills the field, and the sheet stops saying 读取不到 by itself —
 * nothing else changes.
 *
 * @param commandExecution the settlement the result page shows, if any ran.
 * @param jobs `management.jobs` (`ChatPage.swift:437`).
 * @param schedules `management.scheduleRecords` (`ChatPage.swift:445`).
 * @param subagents the current session's raw subagent catalog projection; null means unread.
 */
public data class ChatSubpageFacts(
    public val commandExecution: ChatCommandExecution? = null,
    public val jobs: List<ChatJobRow>? = null,
    public val schedules: List<ChatScheduleRow>? = null,
    public val subagents: List<ChatSubagentEntry>? = null,
)

/** Which body a list sheet draws; [UNREAD] is the Android-only "the host did not read" case. */
public enum class ChatSubpageBody {
    /** The host reported no read; the sheet says 读取不到 rather than "none". */
    UNREAD,

    /** The host read the list and it is empty (`ContentUnavailableView` in the baseline). */
    EMPTY,

    /** The host read the list and it has rows. */
    ROWS,
}

/** 后台任务 sheet's body (`ChatPage.swift:3554`-`:3601`). */
public data class ChatJobsSheetState(
    public val body: ChatSubpageBody,
    public val rows: List<ChatJobRow> = emptyList(),
) {
    public companion object {
        /** The baseline has no unread branch; the Android page does, and says so. */
        public fun from(jobs: List<ChatJobRow>?): ChatJobsSheetState = when {
            jobs == null -> ChatJobsSheetState(ChatSubpageBody.UNREAD)
            jobs.isEmpty() -> ChatJobsSheetState(ChatSubpageBody.EMPTY)
            else -> ChatJobsSheetState(ChatSubpageBody.ROWS, jobs)
        }
    }
}

/** 定时任务 sheet's body (`ChatPage.swift:3504`-`:3552`). */
public data class ChatSchedulesSheetState(
    public val body: ChatSubpageBody,
    public val rows: List<ChatScheduleRow> = emptyList(),
) {
    public companion object {
        public fun from(schedules: List<ChatScheduleRow>?): ChatSchedulesSheetState = when {
            schedules == null -> ChatSchedulesSheetState(ChatSubpageBody.UNREAD)
            schedules.isEmpty() -> ChatSchedulesSheetState(ChatSubpageBody.EMPTY)
            else -> ChatSchedulesSheetState(ChatSubpageBody.ROWS, schedules)
        }
    }
}

/** 命令结果 page's body (`ChatPage.swift:4243`-`:4299`); a `null` execution is the unread case. */
public data class ChatCommandResultState(
    public val execution: ChatCommandExecution? = null,
) {
    /** The output body, or `null` for the baseline's 这次没有更多输出。 branch. */
    public val output: String? get() = execution?.text?.takeIf { it.isNotEmpty() }

    /** Whether the settlement says success; only read when [execution] is present. */
    public val succeeded: Boolean get() = execution?.succeeded == true
}

/**
 * 命令结果: one `/command` execution's settlement.
 *
 * `完成` is the baseline's `dismiss()` (`.topBarTrailing`, `ChatPage.swift:4276`), so
 * it only closes this surface; nothing here writes to the host.
 *
 * @param state what the host reported (`UNREAD` by default: this host owns no
 *   `commands/execute`, so no execution reaches it).
 * @param onDone close the sheet (the shell pops the route).
 * @param modifier the caller's placement.
 */
@Composable
public fun CommandExecutionResultPage(
    state: ChatCommandResultState,
    onDone: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    val execution = state.execution
    ChatSubpageFrame(
        title = UiStrings.CHAT_COMMAND_RESULT_TITLE,
        rootTag = UiPageTags.CHAT_COMMAND_RESULT_ROOT,
        onClose = null,
        modifier = modifier,
        trailing = {
            SessionTextAction(
                label = UiStrings.CHAT_SUBPAGE_DONE,
                onClick = onDone,
                tone = SessionActionTone.ACCENT,
            )
        },
    ) {
        if (execution == null) {
            EmptyHint(
                title = UiStrings.CHAT_COMMAND_RESULT_UNREAD,
                hint = null,
                tag = UiPageTags.CHAT_COMMAND_RESULT_UNREAD,
            )
        } else {
            Column(
                modifier = Modifier
                    .fillMaxSize()
                    .verticalScroll(rememberScrollState())
                    // Page-level margin; the baseline padds this page by 18 pt.
                    .padding(tokens.geometry.pageOuterMarginH)
                    .testTag(UiPageTags.CHAT_COMMAND_RESULT_BODY),
                verticalArrangement = Arrangement.spacedBy(tokens.spacing.cardInset),
            ) {
                BasicText(
                    text = if (state.succeeded) {
                        UiStrings.CHAT_COMMAND_RESULT_SUCCESS
                    } else {
                        UiStrings.CHAT_COMMAND_RESULT_FAILED
                    },
                    style = type.headline.copy(
                        color = if (state.succeeded) tokens.colors.primary else tokens.colors.danger,
                    ),
                    modifier = Modifier
                        .testTag(UiPageTags.CHAT_COMMAND_RESULT_STATUS)
                        .semantics { heading() },
                )
                // The command line in its own box: iOS
                // `.system(.callout, design: .monospaced)` on
                // `secondarySystemBackground` with a 12 pt radius.
                BasicText(
                    text = execution.line,
                    style = type.code.copy(color = tokens.colors.primary),
                    modifier = Modifier
                        .fillMaxWidth()
                        .testTag(UiPageTags.CHAT_COMMAND_RESULT_LINE)
                        .clip(RoundedCornerShape(tokens.radius.codeBlock))
                        .background(tokens.colors.code)
                        .padding(tokens.spacing.cardInset),
                )
                val output = state.output
                if (output != null) {
                    BasicText(
                        text = output,
                        style = type.body.copy(color = tokens.colors.primary),
                        modifier = Modifier
                            .fillMaxWidth()
                            .testTag(UiPageTags.CHAT_COMMAND_RESULT_OUTPUT),
                    )
                } else {
                    BasicText(
                        text = UiStrings.CHAT_COMMAND_RESULT_EMPTY,
                        style = type.secondary.copy(color = tokens.colors.secondary),
                        modifier = Modifier
                            .fillMaxWidth()
                            .testTag(UiPageTags.CHAT_COMMAND_RESULT_OUTPUT),
                    )
                }
            }
        }
    }
}

/**
 * 后台任务: this session's background jobs (`ChatPage.swift:3554`-`:3601`).
 *
 * @param state the host's read, or `UNREAD`.
 * @param onRefresh re-read the session activity; `null` draws 刷新 greyed but
 *   visible (the sheet can never hide a verb it renders on the baseline).
 * @param onClose `关闭` (`.cancellationAction`, `:3596`).
 * @param modifier the caller's placement.
 */
@Composable
public fun NativeJobListSheet(
    state: ChatJobsSheetState,
    onRefresh: (() -> Unit)?,
    onClose: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val tokens = LocalUiTokens.current
    ChatSubpageFrame(
        title = UiStrings.CHAT_JOBS_TITLE,
        rootTag = UiPageTags.CHAT_JOBS_SHEET_ROOT,
        onClose = onClose,
        modifier = modifier,
        trailing = {
            SessionTextAction(
                label = UiStrings.CHAT_SUBPAGE_REFRESH,
                onClick = { onRefresh?.invoke() },
                tone = SessionActionTone.ACCENT,
                enabled = onRefresh != null,
            )
        },
    ) {
        when (state.body) {
            ChatSubpageBody.UNREAD -> EmptyHint(
                title = UiStrings.CHAT_JOBS_UNREAD,
                hint = null,
                tag = UiPageTags.CHAT_JOBS_SHEET_UNREAD,
            )

            ChatSubpageBody.EMPTY -> EmptyHint(
                title = UiStrings.CHAT_JOBS_EMPTY_TITLE,
                hint = UiStrings.CHAT_JOBS_EMPTY_DETAIL,
                tag = UiPageTags.CHAT_JOBS_SHEET_EMPTY,
            )

            ChatSubpageBody.ROWS -> LazyColumn(
                modifier = Modifier
                    .fillMaxSize()
                    .testTag(UiPageTags.CHAT_JOBS_SHEET_LIST),
                contentPadding = PaddingValues(vertical = tokens.geometry.cardOuterMarginV),
            ) {
                itemsIndexed(items = state.rows, key = { _, row -> row.id }) { index, row ->
                    if (index > 0) SessionHairline()
                    ChatJobRowView(row)
                }
            }
        }
    }
}

/**
 * 定时任务: this session's scheduled tasks (`ChatPage.swift:3504`-`:3552`).
 *
 * @param state the host's read, or `UNREAD`.
 * @param onRefresh re-read the session activity (the baseline's `onRefresh`, `:3549`).
 * @param onClose `关闭` (`.cancellationAction`, `:3547`).
 * @param modifier the caller's placement.
 */
@Composable
public fun NativeScheduleListSheet(
    state: ChatSchedulesSheetState,
    onRefresh: (() -> Unit)?,
    onClose: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val tokens = LocalUiTokens.current
    ChatSubpageFrame(
        title = UiStrings.CHAT_SCHEDULES_TITLE,
        rootTag = UiPageTags.CHAT_SCHEDULES_SHEET_ROOT,
        onClose = onClose,
        modifier = modifier,
        trailing = {
            SessionTextAction(
                label = UiStrings.CHAT_SUBPAGE_REFRESH,
                onClick = { onRefresh?.invoke() },
                tone = SessionActionTone.ACCENT,
                enabled = onRefresh != null,
            )
        },
    ) {
        when (state.body) {
            ChatSubpageBody.UNREAD -> EmptyHint(
                title = UiStrings.CHAT_SCHEDULES_UNREAD,
                hint = null,
                tag = UiPageTags.CHAT_SCHEDULES_SHEET_UNREAD,
            )

            ChatSubpageBody.EMPTY -> EmptyHint(
                title = UiStrings.CHAT_SCHEDULES_EMPTY_TITLE,
                hint = UiStrings.CHAT_SCHEDULES_EMPTY_DETAIL,
                tag = UiPageTags.CHAT_SCHEDULES_SHEET_EMPTY,
            )

            ChatSubpageBody.ROWS -> LazyColumn(
                modifier = Modifier
                    .fillMaxSize()
                    .testTag(UiPageTags.CHAT_SCHEDULES_SHEET_LIST),
                contentPadding = PaddingValues(vertical = tokens.geometry.cardOuterMarginV),
            ) {
                itemsIndexed(items = state.rows, key = { _, row -> row.id }) { index, row ->
                    if (index > 0) SessionHairline()
                    ChatScheduleRowView(row)
                }
            }
        }
    }
}

/**
 * The subpage frame: the baseline's inline navigation bar (title centred between
 * `关闭` and the sheet's one trailing verb) over a full-height body.
 *
 * The title is data-free — every caller passes a `UiStrings` constant — so this
 * helper never assembles a label at runtime.
 */
@Composable
private fun ChatSubpageFrame(
    title: String,
    rootTag: String,
    onClose: (() -> Unit)?,
    modifier: Modifier = Modifier,
    trailing: (@Composable () -> Unit)? = null,
    content: @Composable () -> Unit,
) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    // `colors.background` is tier: unmeasured, so an unspecified value leaves the
    // platform surface in place instead of an invented sRGB fill.
    val surface = if (tokens.colors.background.isSpecified) {
        Modifier.background(tokens.colors.background)
    } else {
        Modifier
    }
    Column(
        modifier = modifier
            .fillMaxSize()
            .then(surface)
            .testTag(rootTag)
            .windowInsetsPadding(WindowInsets.safeDrawing.only(WindowInsetsSides.Horizontal)),
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .statusBarsPadding()
                .defaultMinSize(minHeight = tokens.geometry.pageHeaderMinHeight)
                .padding(horizontal = tokens.geometry.pageOuterMarginH),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            // Equal weights keep the title centred whatever the two verbs measure,
            // the same reason the page header derives its 104 pt reserve.
            Box(modifier = Modifier.weight(1f), contentAlignment = Alignment.CenterStart) {
                if (onClose != null) {
                    SessionTextAction(
                        label = UiStrings.DISMISS,
                        onClick = onClose,
                        tone = SessionActionTone.SECONDARY,
                    )
                }
            }
            BasicText(
                text = title,
                style = type.headline.copy(color = tokens.colors.primary),
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier.semantics { heading() },
            )
            Box(modifier = Modifier.weight(1f), contentAlignment = Alignment.CenterEnd) {
                trailing?.invoke()
            }
        }
        Box(
            modifier = Modifier
                .weight(1f)
                .fillMaxWidth()
                .navigationBarsPadding(),
        ) {
            content()
        }
    }
}

/** One job row: title, one-line detail, and the status on the right when reported. */
@Composable
private fun ChatJobRowView(row: ChatJobRow) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(
                horizontal = tokens.geometry.pageOuterMarginH,
                vertical = tokens.geometry.bannerInsetV,
            )
            .testTag(UiPageTags.CHAT_JOBS_SHEET_ROW_PREFIX + row.id),
        verticalAlignment = Alignment.Top,
        horizontalArrangement = Arrangement.spacedBy(tokens.spacing.badgeInsetH),
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
            BasicText(
                text = row.detail,
                style = type.caption.copy(color = tokens.colors.tertiary),
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }
        if (row.status != null) {
            BasicText(
                text = row.status,
                style = type.caption.copy(color = tokens.colors.secondary),
                maxLines = 1,
            )
        }
    }
}

/** One schedule row: title + status, its detail line, then the prompt (two lines). */
@Composable
private fun ChatScheduleRowView(row: ChatScheduleRow) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .padding(
                horizontal = tokens.geometry.pageOuterMarginH,
                vertical = tokens.geometry.bannerInsetV,
            )
            .testTag(UiPageTags.CHAT_SCHEDULES_SHEET_ROW_PREFIX + row.id),
        verticalArrangement = Arrangement.spacedBy(tokens.spacing.badgeInsetV),
    ) {
        Row(
            modifier = Modifier.fillMaxWidth(),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(tokens.spacing.badgeInsetH),
        ) {
            BasicText(
                text = row.title,
                style = type.body.copy(color = tokens.colors.primary),
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier.weight(1f),
            )
            if (row.status != null) {
                BasicText(
                    text = row.status,
                    style = type.caption.copy(color = tokens.colors.secondary),
                    maxLines = 1,
                )
            }
        }
        BasicText(
            text = row.detail,
            style = type.caption.copy(color = tokens.colors.tertiary),
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
        if (row.prompt != null) {
            BasicText(
                text = row.prompt,
                style = type.secondary.copy(color = tokens.colors.secondary),
                maxLines = 2,
                overflow = TextOverflow.Ellipsis,
            )
        }
    }
}

/** The kind word that means "the command ran" (`ChatPage.swift:2516`). */
private const val KIND_SUCCESS: String = "success"
private const val TODO_COMPLETED: String = "completed"
private const val TODO_IN_PROGRESS: String = "in_progress"
private const val TODO_PENDING: String = "pending"
private const val TODO_DOCK_TAG: String = "pdsh.chat.todo-dock"
private const val TODO_DOCK_ROW_TAG: String = "pdsh.chat.todo-row."
private const val QUESTION_TAKEOVER_TAG: String = "pdsh.chat.question-takeover"
private const val COMPOSER_MODEL_LABEL_TAG: String = "pdsh.composer.model-label"

/** Stable tag for the queue disclosure; `PdshDisclosureTags` appends `.header` / `.body`. */
private const val QUEUE_DISCLOSURE_TAG: String = "pdsh.composer.queue.disclosure"
private const val PLAN_REVIEW_TAKEOVER_TAG: String = "pdsh.chat.plan-review-takeover"
private const val PLAN_REVIEW_APPROVE_TAG: String = "pdsh.chat.plan-review-approve"
private const val PLAN_REVIEW_CHANGE_TAG: String = "pdsh.chat.plan-review-change"
private const val PLAN_REVIEW_INTENT: String = "plan-review"
private const val SLASH_COMMAND_TAG_PREFIX: String = "pdsh.chat.slash-command."
private const val CHAT_HEADER_DEVICE_TAG: String = "pdsh.chat.header.device"
private const val CHAT_RESTART_ENGINE_TAG: String = "pdsh.chat.restart-engine"

private fun CollapseTiming.chatMenuLabel(): String = when (this) {
    CollapseTiming.COMPLETION -> "完成时"
    CollapseTiming.NEXT_INPUT -> "下一条消息"
}

private fun collapseTimingTag(value: CollapseTiming): String = "pdsh.chat.header.collapse-timing.${value.id}"
