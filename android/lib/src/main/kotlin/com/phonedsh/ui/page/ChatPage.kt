// Chat page: page head, failure banners, pending cards, transcript, composer dock.
// SPDX-License-Identifier: MIT
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
package com.phonedsh.ui.page

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.WindowInsetsSides
import androidx.compose.foundation.layout.defaultMinSize
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
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
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.snapshotFlow
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.isSpecified
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import com.phonedsh.agentcore.JsonArray
import com.phonedsh.agentcore.JsonObject
import com.phonedsh.agentcore.JsonString
import com.phonedsh.agentcore.JsonValue
import com.phonedsh.ui.UiStrings
import com.phonedsh.ui.UiTags
import com.phonedsh.ui.projection.CanonicalJson
import com.phonedsh.ui.state.AccessModeOption
import com.phonedsh.ui.state.ChatEmpty
import com.phonedsh.ui.state.ChatPhase
import com.phonedsh.ui.state.ChatScreenState
import com.phonedsh.ui.state.ComposerCommand
import com.phonedsh.ui.state.GoalBarState
import com.phonedsh.ui.state.PendingAnswer
import com.phonedsh.ui.state.PendingFold
import com.phonedsh.ui.state.PendingSlot
import com.phonedsh.ui.state.ReferenceMenu
import com.phonedsh.ui.state.RunStatus
import com.phonedsh.ui.state.SlashMenu
import com.phonedsh.ui.surface.ApprovalCard
import com.phonedsh.ui.surface.Composer
import com.phonedsh.ui.surface.ComposerMode
import com.phonedsh.ui.surface.FoldedPendingRow
import com.phonedsh.ui.theme.LocalUiTokens
import com.phonedsh.ui.theme.LocalUiType
import com.phonedsh.ui.theme.generated.UiTokenNames
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
 * @param onCollapsePendingSlot the user tapped the "还有 1 个待确认" line while the
 *   second card was open; the host records `pendingSlotExpanded = false`.
 * @param onRenameSession the title was edited; the dialog passes the trimmed name
 *   and an empty string means "cancelled edit" (iOS keeps the old title).
 * @param onExportTranscript the page-head menu's 导出对话记录 (a share-sheet
 *   action, spec §5 `share-sheet`; the host owns the platform panel).
 * @param onOpenSessionSettings the page-head menu's 本会话设置.
 * @param onOpenRunStatus the run-status dot was tapped (iOS `RuntimeDetailsPage`).
 * @param onStartEngine the empty state's 启动本地引擎.
 * @param onConfigureProvider the empty state's 去配置模型服务.
 * @param onLoadEarlier the transcript's 加载更早消息.
 * @param onSubmitAnswer submit a question card's answer as the JSON the iOS
 *   `QuestionCard` builds (`{"<item>": "value"}` or `{"<item>": ["a","b"]}`).
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
    onCollapsePendingSlot: () -> Unit = {},
    onRenameSession: (String) -> Unit = {},
    onExportTranscript: () -> Unit = {},
    onOpenSessionSettings: () -> Unit = {},
    onOpenRunStatus: () -> Unit = {},
    onStartEngine: () -> Unit = {},
    onConfigureProvider: () -> Unit = {},
    onLoadEarlier: () -> Unit = {},
    onSubmitAnswer: (PendingAnswer, String) -> Unit = { _, _ -> },
    onRemoveAttachment: (Int) -> Unit = {},
    onAddImages: () -> Unit = {},
    onAddFiles: () -> Unit = {},
    onSelectAccessMode: (String) -> Unit = {},
    onSelectModel: (String, String?) -> Unit = { _, _ -> },
    onPickCommand: (String) -> Unit = {},
    onPickReference: (String) -> Unit = {},
    onDismissComposerNotice: () -> Unit = {},
    onRetryAccessModes: () -> Unit = {},
    onReloadCommands: () -> Unit = {},
    onOpenFile: (String) -> Unit = {},
) {
    val tokens = LocalUiTokens.current
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
    Box(modifier = modifier.fillMaxSize().then(surface).testTag(UiTags.CHAT_ROOT)) {
    Column(
        modifier = Modifier
            .fillMaxSize()
            // Edge-to-edge: the vertical bars are consumed by the header and the
            // dock; the horizontal ones are page-wide (landscape nav bar).
            .windowInsetsPadding(WindowInsets.safeDrawing.only(WindowInsetsSides.Horizontal)),
    ) {
        ChatHeader(
            title = title,
            runStatus = state.runStatus,
            onOpenSessions = onOpenSessions,
            onStartRename = { renaming = true },
            onOpenRunStatus = onOpenRunStatus,
            onExportTranscript = onExportTranscript,
            onOpenSessionSettings = onOpenSessionSettings,
        )
        // A failure that belongs to one row is rendered under it; every other
        // failure owns the top banner (iOS body: `failedItemID == nil` first).
        if (state.failedItemID == null && state.userFacingError != null) {
            val retryable = state.banners.firstOrNull()?.retryable == true
            TopFailureBanner(
                message = state.userFacingError,
                onRetry = if (retryable) onRetry else null,
                onDismiss = { state.banners.firstOrNull()?.let { onDismissBanner(it.id) } },
            )
        }
        if (state.accessModeError != null) {
            NoticeBanner(
                glyph = LOCK_GLYPH,
                message = state.accessModeError,
                retryLabel = UiStrings.RETRY,
                onRetry = onRetryAccessModes,
                tag = UiPageTags.CHAT_BANNER_ACCESS_MODE,
            )
        }
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
            expanded = state.pendingExpanded,
            onExpand = onExpandPendingSlot,
            onCollapse = onCollapsePendingSlot,
            onApprove = onApprove,
            onDeny = onDeny,
            onSubmitAnswer = onSubmitAnswer,
            maxHeight = screenHeight * tokens.geometry.cardAreaMaxHeightRatio,
        )
        Box(modifier = Modifier.weight(1f).fillMaxWidth()) {
            ChatTranscript(
                state = state,
                onToggleRow = onToggleRow,
                onLoadEarlier = onLoadEarlier,
                onStartEngine = onStartEngine,
                onConfigureProvider = onConfigureProvider,
                onRetry = onRetry,
                onOpenFile = onOpenFile,
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
                onDraftChange = onDraftChange,
                onSend = onSend,
                onStop = onStop,
                onGoalPause = onGoalPause,
                onGoalResume = onGoalResume,
                onGoalClear = onGoalClear,
                onOpenGoalDetail = onOpenGoalDetail,
                onRemoveAttachment = onRemoveAttachment,
                onAddImages = onAddImages,
                onAddFiles = onAddFiles,
                onSelectAccessMode = onSelectAccessMode,
                onSelectModel = onSelectModel,
                onPickCommand = onPickCommand,
                onPickReference = onPickReference,
                onDismissNotice = onDismissComposerNotice,
                onReloadCommands = onReloadCommands,
            )
        }
    }
    }
    if (renaming) {
        RenameSessionOverlay(
            title = title,
            onCancel = { renaming = false },
            onSave = { name ->
                renaming = false
                onRenameSession(name)
            },
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
 * The self-drawn page head: drawer on the left, the session title centred (a tap
 * renames it), then the run-status dot and the `⋯` menu on the right. 44 pt tall,
 * 16 pt side inset — the same numbers as every other native header.
 */
@Composable
private fun ChatHeader(
    title: String,
    runStatus: RunStatus,
    onOpenSessions: () -> Unit,
    onStartRename: () -> Unit,
    onOpenRunStatus: () -> Unit,
    onExportTranscript: () -> Unit,
    onOpenSessionSettings: () -> Unit,
) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    var menuOpen by remember { mutableStateOf(false) }

    // iOS centres the title in a ZStack and reserves 104 pt on each side so the
    // buttons cannot push it off centre. Those 104 pt are the *result* of the two
    // button groups' widths on the baseline device, not a design value, so the
    // layout derives them here: one Row, the title takes the remaining weight and
    // centres itself inside it. No literal is repeated.
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .statusBarsPadding()
            .defaultMinSize(minHeight = tokens.geometry.pageHeaderMinHeight)
            .padding(horizontal = tokens.geometry.pageOuterMarginH),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        // Left slot: the drawer button.
        HeaderAction(
            glyph = MENU_GLYPH,
            description = UiStrings.HEADER_DRAWER,
            onClick = onOpenSessions,
            modifier = Modifier.testTag(UiPageTags.CHAT_HEADER_DRAWER),
        )
        Box(
            modifier = Modifier
                .weight(1f)
                .defaultMinSize(minHeight = tokens.geometry.pageHeaderMinHeight)
                // The tap target is the title's slot, not the drawn word: the title is
                // data (a session's name), so the control around it takes the click and
                // the text only draws it — iOS
                // `Button { beginRename() } label: { Text(sessionTitle) }`.
                .clickable(role = Role.Button) {
                    // iOS disables the rename for a session that is not open.
                    if (title.isNotEmpty()) onStartRename()
                }
                .semantics { contentDescription = title.ifEmpty { PRODUCT_NAME } }
                .testTag(UiPageTags.CHAT_HEADER_TITLE),
            contentAlignment = Alignment.Center,
        ) {
            BasicText(
                text = title.ifEmpty { PRODUCT_NAME },
                style = type.headline.copy(color = tokens.colors.primary),
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }
        // Right slot: iOS `RunStatusDot` + the ⋯ menu, one 4 pt-spaced group.
        RunStatusDot(
            runStatus = runStatus,
            onClick = onOpenRunStatus,
            modifier = Modifier.testTag(UiPageTags.CHAT_HEADER_RUN_STATUS),
        )
        Box {
            HeaderMenuAction(
                label = UiStrings.HEADER_MORE,
                glyph = MORE_GLYPH,
                onClick = { menuOpen = true },
                modifier = Modifier.testTag(UiPageTags.CHAT_HEADER_MENU),
            )
            DropdownMenu(expanded = menuOpen, onDismissRequest = { menuOpen = false }) {
                DropdownMenuItem(
                    text = { Text(UiStrings.HEADER_EXPORT) },
                    onClick = {
                        menuOpen = false
                        onExportTranscript()
                    },
                )
                DropdownMenuItem(
                    text = { Text(UiStrings.HEADER_SESSION_SETTINGS) },
                    onClick = {
                        menuOpen = false
                        onOpenSessionSettings()
                    },
                )
            }
        }
    }
}

/**
 * One header control: its glyph, a 44 pt floor and its accessibility label.
 *
 * The drawer has no word on the baseline page (`accessibilityLabel` only), so the
 * control's name lives in `description`. The `⋯` menu *is* a named action on the
 * baseline (`.accessibilityLabel("更多操作")`), so it uses [HeaderMenuAction],
 * whose first parameter is that word.
 */
@Composable
private fun HeaderAction(
    glyph: String,
    description: String,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    Box(
        modifier = modifier
            .defaultMinSize(minHeight = tokens.geometry.pageHeaderMinHeight)
            .clickable(role = Role.Button, onClick = onClick)
            .semantics { contentDescription = description }
            .padding(horizontal = tokens.spacing.iconText),
        contentAlignment = Alignment.Center,
    ) {
        BasicText(
            text = glyph,
            style = type.secondary.copy(color = tokens.colors.secondary),
        )
    }
}

/**
 * The page-head menu trigger.
 *
 * @param label the control's accessible name; iOS puts exactly this word on the
 *   menu (`.accessibilityLabel("更多操作")`), and the header draws a mark, so the
 *   name and the mark are two different strings.
 * @param glyph what is drawn.
 * @param onClick opens the menu.
 * @param modifier the caller's tag and placement.
 */
@Composable
private fun HeaderMenuAction(
    label: String,
    glyph: String,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    Box(
        modifier = modifier
            .defaultMinSize(minHeight = tokens.geometry.pageHeaderMinHeight)
            .clickable(role = Role.Button, onClick = onClick)
            .semantics { contentDescription = label }
            .padding(horizontal = tokens.spacing.iconText),
        contentAlignment = Alignment.Center,
    ) {
        BasicText(
            text = glyph,
            style = type.secondary.copy(color = tokens.colors.secondary),
        )
    }
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
            .defaultMinSize(minHeight = tokens.geometry.pageHeaderMinHeight)
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
    onDismiss: () -> Unit,
) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .testTag(UiTags.FAIL_LOUD_BANNER)
            .padding(
                horizontal = tokens.geometry.bannerInsetH,
                vertical = tokens.geometry.bannerInsetV,
            ),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(tokens.geometry.bannerGap),
    ) {
        BasicText(
            text = message,
            style = type.secondary.copy(color = tokens.colors.warning),
            modifier = Modifier.weight(1f),
        )
        if (onRetry != null) {
            BasicText(
                text = UiStrings.RETRY,
                style = type.secondary.copy(color = tokens.colors.accent),
                modifier = Modifier
                    .clickable(role = Role.Button, onClick = onRetry)
                    .testTag(UiTags.BANNER_RETRY)
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
 * The pending-answer region.
 *
 * Three states, exactly as iOS: the keyboard up folds the whole region into one
 * "N 项需要处理" line; otherwise a permission card and a question card share the
 * region, with the second one folded into "还有 1 个待确认" until the user opens
 * it. The region never takes more than 40% of the screen and scrolls inside
 * itself when it has more.
 */
@Composable
private fun PendingCardsRegion(
    slot: PendingSlot,
    fold: PendingFold,
    expanded: Boolean,
    onExpand: () -> Unit,
    onCollapse: () -> Unit,
    onApprove: (PendingAnswer) -> Unit,
    onDeny: (PendingAnswer) -> Unit,
    onSubmitAnswer: (PendingAnswer, String) -> Unit,
    maxHeight: Dp,
) {
    if (slot.isEmpty) return
    val primary = slot.primary
    Box(
        modifier = Modifier
            .fillMaxWidth()
            .testTag(UiTags.ANSWER_SLOT),
    ) {
        if (fold == PendingFold.FOLDED) {
            FoldedPendingRow(
                label = UiStrings.PENDING_SLOT.format(slot.count),
                onExpand = onExpand,
                modifier = Modifier.testTag(UiPageTags.CHAT_PENDING_FOLD),
            )
        } else {
            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .heightIn(max = maxHeight)
                    .verticalScroll(rememberScrollState()),
            ) {
                // One card at a time: the permission card wins, and the other one
                // folds into a line above it.
                if (slot.bothKinds) {
                    FoldedPendingRow(
                        // The slot shows at most two cards, so exactly one is folded
                        // and the line is the singular wording iOS types at
                        // ChatPage.swift:517.
                        label = UiStrings.MORE_PENDING,
                        // iOS toggles `cardsExpanded` from this line.
                        onExpand = if (expanded) onCollapse else onExpand,
                        modifier = Modifier.testTag(UiPageTags.CHAT_PENDING_MORE),
                    )
                }
                if (primary != null) {
                    if (primary.kind == QUESTION) {
                        QuestionCard(
                            question = primary,
                            maxHeight = maxHeight,
                            onSubmit = { answer -> onSubmitAnswer(primary, answer) },
                        )
                    } else {
                        ApprovalCard(
                            title = primary.title,
                            subtitle = primary.subtitle,
                            primaryLabel = UiStrings.ALLOW_ONCE,
                            onPrimary = { onApprove(primary) },
                            secondaryLabel = UiStrings.DENY,
                            onSecondary = { onDeny(primary) },
                            maxHeight = maxHeight,
                        )
                    }
                }
                // The second ask is a card only while the user opened it; until then
                // the line above is its whole representation (iOS `cardsExpanded`).
                slot.folded.filter { expanded }.forEach { ask ->
                    if (ask.kind == QUESTION) {
                        QuestionCard(
                            question = ask,
                            maxHeight = maxHeight,
                            onSubmit = { answer -> onSubmitAnswer(ask, answer) },
                        )
                    } else {
                        ApprovalCard(
                            title = ask.title,
                            subtitle = ask.subtitle,
                            primaryLabel = UiStrings.ALLOW_ONCE,
                            onPrimary = { onApprove(ask) },
                            secondaryLabel = UiStrings.DENY,
                            onSecondary = { onDeny(ask) },
                            maxHeight = maxHeight,
                        )
                    }
                }
            }
        }
    }
    // The slot never hides the composer: `state.composer.enabled` is already false
    // while an ask is pending (spec §2).
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
                    style = type.headline.copy(color = tokens.colors.primary),
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
                        BasicText(
                            text = if (selected) SELECTED_GLYPH else EMPTY_GLYPH,
                            style = type.secondary.copy(color = tokens.colors.accent),
                        )
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
    onLoadEarlier: () -> Unit,
    onStartEngine: () -> Unit,
    onConfigureProvider: () -> Unit,
    onRetry: () -> Unit,
    onOpenFile: (String) -> Unit,
) {
    val tokens = LocalUiTokens.current
    val listState = rememberLazyListState()
    // True while the last row is on screen: the only condition that lets a new row
    // pull the viewport (iOS `nearBottom`).
    val nearBottom by remember(listState) {
        derivedStateOf {
            val info = listState.layoutInfo
            val last = info.visibleItemsInfo.lastOrNull() ?: return@derivedStateOf true
            last.index >= info.totalItemsCount - 1
        }
    }
    // "The reader scrolled away" is a user gesture, not a measurement: only a
    // user drag can set it, and being near the tail again clears it (iOS
    // `userScrolledAway` + `nearBottom`).
    var scrolledAway by remember { mutableStateOf(false) }
    val scope = rememberCoroutineScope()
    LaunchedEffect(listState) {
        snapshotFlow { listState.isScrollInProgress to nearBottom }.collect { (scrolling, near) ->
            if (scrolling && !near) scrolledAway = true
            if (near) scrolledAway = false
        }
    }
    LaunchedEffect(state.rows.size) {
        if (scrolledAway || state.rows.isEmpty()) return@LaunchedEffect
        val total = listState.layoutInfo.totalItemsCount
        if (total > 0) listState.scrollToItem(total - 1)
    }

    Box(modifier = Modifier.fillMaxSize()) {
        if (state.rows.isEmpty()) {
            Column(modifier = Modifier.fillMaxSize()) {
                TranscriptChrome(state = state, onLoadEarlier = onLoadEarlier)
                EmptyTimeline(
                    state = state,
                    onStartEngine = onStartEngine,
                    onConfigureProvider = onConfigureProvider,
                )
            }
        } else {
            LazyColumn(
                state = listState,
                modifier = Modifier
                    .fillMaxSize()
                    .testTag(UiTags.CHAT_LIST),
                // iOS: top 22, bottom 48 (room for the 28 pt "回到最新" pill).
                // unverified geometry: the compact list-row floor borrowed as the
                // 22 pt top inset and the primary-button height as the 48 pt tail
                // inset; tokens.json has neither page token.
                contentPadding = PaddingValues(
                    top = tokens.geometry.pageListRowMinHeight,
                    bottom = tokens.geometry.primaryButtonHeight,
                ),
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
                            )
                            if (row.id == state.failedItemID && state.userFacingError != null) {
                                FailureLine(
                                    reason = state.userFacingError,
                                    retry = if (state.banners.firstOrNull()?.retryable == true) {
                                        onRetry
                                    } else {
                                        null
                                    },
                                )
                            }
                        }
                    }
                }
            }
            if (scrolledAway && !nearBottom) {
                Box(
                    modifier = Modifier
                        .align(Alignment.BottomCenter)
                        .padding(bottom = tokens.spacing.cardInset)
                        .testTag(UiPageTags.CHAT_BACK_TO_LATEST)
                        .clip(RoundedCornerShape(tokens.radius.card))
                        .background(tokens.colors.selector)
                        .border(
                            width = tokens.stroke.hairline,
                            color = tokens.colors.border,
                            shape = RoundedCornerShape(tokens.radius.card),
                        )
                        .clickable(role = Role.Button) {
                            scrolledAway = false
                            scope.launch {
                                listState.animateScrollToItem(
                                    (listState.layoutInfo.totalItemsCount - 1).coerceAtLeast(0),
                                )
                            }
                        }
                        .padding(
                            horizontal = tokens.spacing.cardInset,
                            vertical = tokens.spacing.codeToolbar,
                        ),
                ) {
                    BasicText(
                        text = UiStrings.BACK_TO_LATEST,
                        style = LocalUiType.current.caption.copy(color = tokens.colors.accent),
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
    onLoadEarlier: () -> Unit,
) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    Column(modifier = Modifier.fillMaxWidth()) {
        if (state.transcript.hasMore) {
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .defaultMinSize(minHeight = tokens.geometry.pageRowMinHeight)
                    .clickable(
                        enabled = !state.transcript.loadingEarlier,
                        role = Role.Button,
                        onClick = onLoadEarlier,
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
            .padding(top = tokens.spacing.iconText),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(tokens.spacing.iconText, Alignment.End),
    ) {
        BasicText(
            text = UiStrings.SEND_FAILED_LINE,
            style = type.secondary.copy(color = tokens.colors.danger),
        )
        if (reason.isNotEmpty()) {
            BasicText(
                text = UiStrings.DOT_SEPARATOR,
                style = type.secondary.copy(color = tokens.colors.secondary),
            )
            BasicText(
                text = reason,
                style = type.secondary.copy(color = tokens.colors.secondary),
            )
        }
        if (retry != null) {
            BasicText(
                text = UiStrings.DOT_SEPARATOR,
                style = type.secondary.copy(color = tokens.colors.secondary),
            )
            BasicText(
                text = UiStrings.RETRY,
                style = type.secondary.copy(color = tokens.colors.accent),
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
    onStartEngine: () -> Unit,
    onConfigureProvider: () -> Unit,
) {
    val tokens = LocalUiTokens.current
    when (state.empty) {
        // iOS pads the first two states 88 pt from the top instead of centring.
        // unverified geometry: 88 pt is expressed as two declared lengths
        // (primaryButtonHeight + composerTrailingReserve); no single token is 88.
        ChatEmpty.ENGINE_NOT_STARTED -> EngineNotStartedState(
            busy = state.starting,
            onStartEngine = onStartEngine,
            modifier = Modifier.padding(top = tokens.geometry.primaryButtonHeight + tokens.geometry.composerTrailingReserve),
        )

        ChatEmpty.PROVIDER_SETUP -> ProviderSetupState(
            onConfigureProvider = onConfigureProvider,
            modifier = Modifier.padding(top = tokens.geometry.primaryButtonHeight + tokens.geometry.composerTrailingReserve),
        )

        ChatEmpty.READY -> ReadyState()
    }
}

/** A: the engine is not started yet — a 338 pt column, text left-aligned. */
@Composable
private fun EngineNotStartedState(
    busy: Boolean,
    onStartEngine: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    Column(
        // iOS pins the column to 338 pt on the baseline device, which is simply
        // "screen width minus both page margins". That is a device result, not a
        // design value, so the column fills the width and takes the page margin;
        // it stays correct at every width.
        modifier = modifier
            .fillMaxWidth()
            .padding(horizontal = tokens.geometry.pageOuterMarginH)
            .testTag(UiPageTags.CHAT_EMPTY_ENGINE),
        verticalArrangement = Arrangement.spacedBy(tokens.spacing.codeToolbar),
    ) {
        BasicText(
            text = UiStrings.ENGINE_NOT_STARTED,
            style = type.headline.copy(color = tokens.colors.primary),
        )
        BasicText(
            text = UiStrings.ENGINE_NOT_STARTED_HINT,
            style = type.secondary.copy(color = tokens.colors.secondary),
        )
        Box(
            modifier = Modifier
                .fillMaxWidth()
                .padding(top = tokens.geometry.composerOuterMarginTop)
                .defaultMinSize(minHeight = tokens.geometry.primaryButtonHeight)
                .background(tokens.colors.accent, RoundedCornerShape(tokens.radius.card))
                .clickable(enabled = !busy, role = Role.Button, onClick = onStartEngine)
                .testTag(UiPageTags.CHAT_START_ENGINE),
            contentAlignment = Alignment.Center,
        ) {
            // iOS `model.busy ? "正在启动…" : "启动本地引擎"`: one word per state.
            if (busy) {
                BasicText(
                    text = UiStrings.STARTING_ENGINE,
                    style = type.headline.copy(color = tokens.colors.onAccent),
                )
            } else {
                BasicText(
                    text = UiStrings.START_ENGINE,
                    style = type.headline.copy(color = tokens.colors.onAccent),
                )
            }
        }
    }
}

/** B: the engine is up, only the model service is missing. */
@Composable
private fun ProviderSetupState(
    onConfigureProvider: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    Column(
        modifier = modifier
            .fillMaxWidth()
            .padding(horizontal = tokens.geometry.pageOuterMarginH)
            .testTag(UiPageTags.CHAT_EMPTY_PROVIDER),
        verticalArrangement = Arrangement.spacedBy(tokens.geometry.bannerGap),
    ) {
        BasicText(
            text = UiStrings.PROVIDER_SETUP_TITLE,
            style = type.headline.copy(color = tokens.colors.primary),
        )
        BasicText(
            text = UiStrings.PROVIDER_SETUP_HINT,
            style = type.secondary.copy(color = tokens.colors.secondary),
        )
        Box(
            modifier = Modifier
                .fillMaxWidth()
                .padding(top = tokens.spacing.codeToolbar)
                .defaultMinSize(minHeight = tokens.geometry.primaryButtonHeight)
                .background(tokens.colors.accent, RoundedCornerShape(tokens.radius.card))
                .clickable(role = Role.Button, onClick = onConfigureProvider)
                .testTag(UiPageTags.CHAT_PROVIDER_SETUP),
            contentAlignment = Alignment.Center,
        ) {
            BasicText(
                text = UiStrings.PROVIDER_SETUP_ACTION,
                style = type.headline.copy(color = tokens.colors.onAccent),
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
    onDraftChange: (String) -> Unit,
    onSend: () -> Unit,
    onStop: () -> Unit,
    onGoalPause: (() -> Unit)?,
    onGoalResume: (() -> Unit)?,
    onGoalClear: (() -> Unit)?,
    onOpenGoalDetail: (() -> Unit)?,
    onRemoveAttachment: (Int) -> Unit,
    onAddImages: () -> Unit,
    onAddFiles: () -> Unit,
    onSelectAccessMode: (String) -> Unit,
    onSelectModel: (String, String?) -> Unit,
    onPickCommand: (String) -> Unit,
    onPickReference: (String) -> Unit,
    onDismissNotice: () -> Unit,
    onReloadCommands: () -> Unit,
) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    val composer = state.composer
    // iOS keeps the truncation notice in the same slot as the attachment error.
    var truncated by remember { mutableStateOf(false) }
    Column(modifier = Modifier.fillMaxWidth()) {
        // iOS puts the 16 pt horizontal inset on the dock's VStack; the input card
        // is that same surface and applies it itself (`Composer`), so the inset is
        // applied here only to the pieces around the card.
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = tokens.geometry.composerOuterMarginH)
                .padding(top = tokens.geometry.composerOuterMarginTop),
            verticalArrangement = Arrangement.spacedBy(tokens.geometry.composerTrailingReserve),
        ) {
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
            if (composer.queued.isNotEmpty()) {
                QueuedStrip(messages = composer.queued)
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
            if (truncated) {
                NoticeLine(text = UiStrings.COMPOSER_TRUNCATED, onClose = { truncated = false })
            }
            composer.slash?.let { menu ->
                SlashMenuView(
                    menu = menu,
                    onPick = onPickCommand,
                    onRetry = onReloadCommands,
                )
            }
            composer.reference?.let { menu ->
                ReferenceMenuView(menu = menu, onPick = onPickReference)
            }
        }
        Composer(
                text = composer.draft,
                onTextChange = onDraftChange,
                placeholder = composer.placeholder,
                mode = composer.mode,
                enabled = composer.enabled,
                canSubmit = composer.canSubmit,
                running = composer.running,
                onSend = onSend,
                onStop = onStop,
                stat = state.stats,
                contextPercent = state.contextPercent,
                sendLabel = composer.sendLabel,
                onTruncated = { truncated = true },
                controls = {
                    ComposerControls(
                        state = state,
                        onDraftChange = onDraftChange,
                        onAddImages = onAddImages,
                        onAddFiles = onAddFiles,
                        onSelectAccessMode = onSelectAccessMode,
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
            .testTag(UiTags.GOAL_BAR)
            .defaultMinSize(minHeight = tokens.geometry.composerTrailingReserve)
            .background(tokens.colors.code, RoundedCornerShape(tokens.radius.card))
            .then(
                if (onOpenDetail != null) {
                    Modifier.clickable(role = Role.Button, onClick = onOpenDetail)
                } else {
                    Modifier
                },
            )
            .padding(horizontal = tokens.spacing.badgeInsetH),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(tokens.spacing.codeToolbar),
    ) {
        Column(modifier = Modifier.weight(1f)) {
            BasicText(
                text = goalBarPhaseLabel(goal.phase),
                style = type.caption.copy(color = tokens.colors.secondary),
                maxLines = 1,
            )
            BasicText(
                text = goal.objective,
                style = type.secondary.copy(color = tokens.colors.secondary),
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }
        if (goal.phase == PHASE_ACTIVE && onPause != null) {
            BasicText(
                text = UiStrings.GOAL_PAUSE,
                style = type.caption.copy(color = tokens.colors.secondary),
                modifier = Modifier
                    .clickable(role = Role.Button, onClick = onPause)
                    .testTag(UiPageTags.GOAL_PAUSE)
                    .padding(tokens.spacing.iconText),
            )
        } else if ((goal.phase == PHASE_PAUSED || goal.phase == PHASE_BLOCKED) && onResume != null) {
            BasicText(
                text = UiStrings.GOAL_RESUME,
                style = type.caption.copy(color = tokens.colors.secondary),
                modifier = Modifier
                    .clickable(role = Role.Button, onClick = onResume)
                    .testTag(UiPageTags.GOAL_RESUME)
                    .padding(tokens.spacing.iconText),
            )
        }
        if (onClear != null) {
            BasicText(
                text = DISMISS_GLYPH,
                style = type.caption.copy(color = tokens.colors.secondary),
                modifier = Modifier
                    .clickable(role = Role.Button, onClick = onClear)
                    .semantics { contentDescription = UiStrings.GOAL_CLEAR_TARGET }
                    .testTag(UiPageTags.GOAL_CLEAR)
                    .padding(tokens.spacing.iconText),
            )
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

/** The queued strip: "排队中 N 条" and one 28 pt line per queued message. */
@Composable
private fun QueuedStrip(messages: List<String>) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .testTag(UiTags.COMPOSER_QUEUE),
        verticalArrangement = Arrangement.spacedBy(tokens.geometry.toolDetailVertical),
    ) {
        BasicText(
            text = UiStrings.QUEUED_COUNT.format(messages.size),
            style = type.caption.copy(color = tokens.colors.secondary),
        )
        messages.forEach { message ->
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .defaultMinSize(minHeight = tokens.geometry.composerControlSize)
                    .background(tokens.colors.code, RoundedCornerShape(tokens.radius.codeBlock))
                    .padding(horizontal = tokens.spacing.badgeInsetH),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                BasicText(
                    text = message,
                    style = type.secondary.copy(color = tokens.colors.secondary),
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
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
                BasicText(
                    text = IMAGE_GLYPH,
                    style = type.caption.copy(color = tokens.colors.secondary),
                )
                BasicText(
                    text = attachment.name,
                    style = type.caption.copy(color = tokens.colors.primary),
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
                BasicText(
                    text = DISMISS_GLYPH,
                    style = type.caption.copy(color = tokens.colors.secondary),
                    modifier = Modifier
                        .clickable(role = Role.Button) { onRemove(index) }
                        .semantics {
                            contentDescription = UiStrings.COMPOSER_REMOVE_IMAGE.format(attachment.name)
                        }
                        .padding(tokens.spacing.iconText),
                )
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

            is SlashMenu.Matches -> menu.commands.forEach { command ->
                SlashCommandRow(command = command, onPick = onPick)
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
    onPick: (String) -> Unit,
) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .clickable(role = Role.Button) { onPick(command.name) }
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
 * The tool row docked inside the card (iOS `composerControls`): the plus menu, the
 * permissions menu, the model menu and the running spinner.
 */
@Composable
private fun ComposerControls(
    state: ChatScreenState,
    onDraftChange: (String) -> Unit,
    onAddImages: () -> Unit,
    onAddFiles: () -> Unit,
    onSelectAccessMode: (String) -> Unit,
    onSelectModel: (String, String?) -> Unit,
) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    val composer = state.composer
    var addOpen by remember { mutableStateOf(false) }
    Row(
        modifier = Modifier.fillMaxWidth(),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(tokens.spacing.codeToolbar),
    ) {
        Box {
            BasicText(
                text = PLUS_GLYPH,
                style = type.secondary.copy(color = tokens.colors.primary),
                modifier = Modifier
                    .size(tokens.geometry.composerControlSize)
                    .clip(CircleShape)
                    .background(tokens.colors.selector)
                    .clickable(enabled = composer.enabled, role = Role.Button) { addOpen = true }
                    .semantics { contentDescription = UiStrings.COMPOSER_ADD_MENU }
                    .testTag(UiPageTags.COMPOSER_ADD)
                    .padding(tokens.spacing.iconText),
            )
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
                DropdownMenuItem(
                    text = { Text(UiStrings.COMPOSER_ADD_IMAGE) },
                    onClick = {
                        addOpen = false
                        onAddImages()
                    },
                )
                DropdownMenuItem(
                    text = { Text(UiStrings.COMPOSER_ADD_FILE) },
                    onClick = {
                        addOpen = false
                        onAddFiles()
                    },
                )
            }
        }
        AccessModeMenuButton(state = state, onSelect = onSelectAccessMode)
        Box(modifier = Modifier.weight(1f))
        ModelMenuButton(state = state, onSelect = onSelectModel)
        if (composer.running) {
            CircularProgressIndicator(
                color = tokens.colors.tertiary,
                strokeWidth = tokens.stroke.hairline,
                modifier = Modifier
                    .size(tokens.geometry.composerControlSize)
                    .semantics { contentDescription = UiStrings.COMPOSER_RUNNING },
            )
        }
    }
}

/** The permissions menu: the translated modes, the current one checked. */
@Composable
private fun AccessModeMenuButton(
    state: ChatScreenState,
    onSelect: (String) -> Unit,
) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    val menu = state.accessModeMenu
    var confirmation by remember { mutableStateOf<AccessModeOption?>(null) }
    var open by remember { mutableStateOf(false) }
    Box {
        BasicText(
            text = SHIELD_GLYPH,
            style = type.secondary.copy(color = tokens.colors.secondary),
            modifier = Modifier
                .defaultMinSize(minHeight = tokens.geometry.composerControlSize)
                .clickable(enabled = menu.enabled, role = Role.Button) { open = true }
                .semantics { contentDescription = UiStrings.ACCESS_MODE_LABEL.format(menu.label) }
                .testTag(UiPageTags.COMPOSER_ACCESS_MODE)
                .padding(tokens.spacing.iconText),
        )
        DropdownMenu(expanded = open, onDismissRequest = { open = false }) {
            val error = menu.error
            if (error != null) {
                // iOS `Section("暂不可用") { Text(error) }`: a group title and the
                // read failure's own words. The retry is the page banner's
                // (`accessModeErrorBanner`), so the menu does not repeat it.
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
        )
    }
}

/** The model menu: the model list and the effort list, one check each. */
@Composable
private fun ModelMenuButton(
    state: ChatScreenState,
    onSelect: (String, String?) -> Unit,
) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    val menu = state.modelMenu
    var open by remember { mutableStateOf(false) }
    Box {
        Row(
            modifier = Modifier
                .defaultMinSize(minHeight = tokens.geometry.composerControlSize)
                .clickable(enabled = menu.enabled, role = Role.Button) { open = true }
                .semantics { contentDescription = UiStrings.MODEL_LABEL }
                .testTag(UiPageTags.COMPOSER_MODEL_MENU)
                .padding(tokens.spacing.iconText),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(tokens.spacing.copyGap),
        ) {
            BasicText(
                text = menu.label,
                style = type.secondary.copy(color = tokens.colors.primary),
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            if (menu.effortTitle != null) {
                BasicText(
                    text = menu.effortTitle,
                    style = type.secondary.copy(color = tokens.colors.secondary),
                    maxLines = 1,
                )
            }
            BasicText(
                text = CHEVRON,
                style = type.caption.copy(color = tokens.colors.secondary),
            )
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
            BasicText(
                text = CHECK_GLYPH,
                style = type.secondary.copy(color = tokens.colors.accent),
            )
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
        UiTokenNames.COLORS_CODE,
        UiTokenNames.COLORS_CTA_OVERRIDE,
        UiTokenNames.COLORS_DANGER,
        UiTokenNames.COLORS_INPUT,
        UiTokenNames.COLORS_ON_ACCENT,
        UiTokenNames.COLORS_PRIMARY,
        UiTokenNames.COLORS_SECONDARY,
        UiTokenNames.COLORS_SELECTOR,
        UiTokenNames.COLORS_SUCCESS,
        UiTokenNames.COLORS_TERTIARY,
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
        UiTokenNames.GEOMETRY_COMPOSER_TRAILING_RESERVE,
        UiTokenNames.GEOMETRY_DISCLOSURE_ROW_HEIGHT,
        UiTokenNames.GEOMETRY_PAGE_HEADER_MIN_HEIGHT,
        UiTokenNames.GEOMETRY_PAGE_LIST_ROW_MIN_HEIGHT,
        UiTokenNames.GEOMETRY_PAGE_OUTER_MARGIN_H,
        UiTokenNames.GEOMETRY_PAGE_ROW_MIN_HEIGHT,
        UiTokenNames.GEOMETRY_PRIMARY_BUTTON_HEIGHT,
        UiTokenNames.GEOMETRY_STATUS_DOT_DIAMETER,
        UiTokenNames.GEOMETRY_TOOL_DETAIL_VERTICAL,
        UiTokenNames.RADIUS_CARD,
        UiTokenNames.RADIUS_CODE_BLOCK,
        UiTokenNames.SPACING_BADGE_INSET_H,
        UiTokenNames.SPACING_CARD_INSET,
        UiTokenNames.SPACING_CODE_TOOLBAR,
        UiTokenNames.SPACING_COPY_GAP,
        UiTokenNames.SPACING_ICON_TEXT,
        UiTokenNames.STROKE_HAIRLINE,
        UiTokenNames.TYPOGRAPHY_CAPTION,
        UiTokenNames.TYPOGRAPHY_HEADLINE,
        UiTokenNames.TYPOGRAPHY_SECONDARY,
        UiTokenNames.TYPOGRAPHY_SUBHEADLINE,
    )

    /** No reviewed deviations: every token this page uses is declared by the spec. */
    val gaps: List<String> = emptyList()
}

/** The `kind` of ask that submits an answer instead of allowing an action. */
private const val QUESTION: String = "question"
private const val PRODUCT_NAME: String = "PDSH"
private const val MENU_GLYPH: String = "☰"
private const val MORE_GLYPH: String = "⋯"
private const val LOCK_GLYPH: String = "⛨"
private const val COMMAND_GLYPH: String = "⌘"
private const val SHIELD_GLYPH: String = "🛡"
private const val PLUS_GLYPH: String = "+"
private const val CHEVRON: String = "▾"
private const val IMAGE_GLYPH: String = "▣"
private const val EMPTY_GLYPH: String = "○"
private const val SELECTED_GLYPH: String = "◉"

/** The menu's "this one is in force" mark (iOS `Label(title, systemImage: "checkmark")`). */
private const val CHECK_GLYPH: String = "✓"

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
