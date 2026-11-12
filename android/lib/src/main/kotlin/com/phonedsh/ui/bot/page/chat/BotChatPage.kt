// SPDX-License-Identifier: MIT
package com.phonedsh.ui.bot.page.chat

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutVertically
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.defaultMinSize
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicText
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.phonedsh.bot.attachments.BotAttachment
import com.phonedsh.bot.rows.BotApprovalDecision
import com.phonedsh.bot.rows.BotRow
import com.phonedsh.bot.rows.BotRowBodyType
import com.phonedsh.ui.HomeMetrics
import com.phonedsh.ui.bot.driver.BotChatSnapshot
import com.phonedsh.ui.bot.driver.BotDraftAttachment
import com.phonedsh.ui.bot.page.BotFishSlot
import com.phonedsh.ui.bot.state.BotUICardContent
import com.phonedsh.ui.bot.state.BotUIRendering
import com.phonedsh.ui.bot.state.BotUiStrings
import com.phonedsh.ui.icon.PdshIcon
import com.phonedsh.ui.icon.PdshIconView
import com.phonedsh.ui.menu.ContextMenuRowState
import com.phonedsh.ui.menu.PdshContextMenu
import com.phonedsh.ui.theme.LocalUiTokens
import com.phonedsh.ui.theme.LocalUiType
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/**
 * The Bot chat page, ported from `BotChatPage.swift:9-1096`.
 *
 * A stateless composable: every value is in [state], every gesture is a
 * callback. The model owns history, actions, settlement, counts, header
 * presence and the activity clock; this file draws them.
 *
 * @param fish the BotFish renderer slot (`BotFishSlot`); the page never imports
 *   the renderer directly.
 * @param onOpenDrawer opens the Bot drawer (lane K5b); `null` draws no leading
 *   control, matching the reference's optional `openDrawer`.
 * @param onOpenInfo opens the Bot info page (lane K5b). The header menu's four
 *   rows all route to it: K5a freezes only the two documented callbacks.
 */
@Composable
public fun BotChatPage(
    state: BotChatSnapshot,
    fish: BotFishSlot,
    onDraftChange: (String) -> Unit,
    onSend: () -> Unit,
    onStop: () -> Unit,
    onAnswer: (rowID: String, optionID: String) -> Unit,
    onDismiss: (rowID: String) -> Unit,
    onApproval: (rowID: String, decision: BotApprovalDecision) -> Unit,
    onChecklistProgress: (rowID: String, done: Int, total: Int) -> Unit,
    onChecklistSend: (rowID: String, done: Int, total: Int, message: String) -> Unit,
    onLoadHistory: () -> Unit,
    onTick: () -> Unit,
    onInteraction: () -> Unit,
    onOpenInfo: () -> Unit,
    onConnectDevice: () -> Unit,
    onAttach: () -> Unit,
    onRemoveAttachment: (Int) -> Unit,
    onDismissAttachmentNotice: () -> Unit,
    onOpenDrawer: (() -> Unit)? = null,
    onOpenDocument: ((BotRow) -> Unit)? = null,
    onOpenPath: (String) -> Unit = {},
    onOpenUrl: (String) -> Unit = {},
    onSelectBot: (String) -> Unit = {},
    peerAppearance: (String) -> com.phonedsh.bot.profile.BotFishAppearance? = { null },
    peerIsMainBot: (String) -> Boolean = { false },
    peerReaction: (String) -> com.phonedsh.ui.bot.state.BotFishReaction? = { null },
    hasOnlineDevices: Boolean = false,
    modifier: Modifier = Modifier,
) {
    val pageActive = LocalBotPageActive.current
    val tokens = LocalUiTokens.current
    var sourceRow by remember { mutableStateOf<BotRow?>(null) }
    var documentRow by remember { mutableStateOf<BotRow?>(null) }
    val transcriptState = rememberLazyListState()
    val scope = rememberCoroutineScope()

    // The activity-line clock parks at the model's next deadline instead of
    // polling: one wake per rotation, pending swap or minute boundary.
    LaunchedEffect(state.activityLine.nextDeadline) {
        val deadline = state.activityLine.nextDeadline ?: return@LaunchedEffect
        val wait = (deadline - System.currentTimeMillis()).coerceAtLeast(0L)
        delay(wait)
        onTick()
    }
    LaunchedEffect(
        state.rows.size,
        state.rows.lastOrNull()?.id,
        state.live?.segments?.size,
        state.live?.buffer,
        state.streamingText,
        state.settlements.keys,
    ) {
        if (state.rows.isNotEmpty()) {
            scope.launch { transcriptState.scrollToItem(state.rows.lastIndex) }
        }
    }

    Column(
        modifier = modifier
            .fillMaxSize()
            .background(tokens.colors.page),
    ) {
        BotHeader(
            state = state,
            fish = fish,
            pageActive = pageActive,
            hasOnlineDevices = hasOnlineDevices,
            onOpenDrawer = onOpenDrawer,
            onOpenInfo = onOpenInfo,
            onConnectDevice = onConnectDevice,
            onInteraction = onInteraction,
        )
        Box(Modifier.weight(1f)) {
            LazyColumn(
                state = transcriptState,
                modifier = Modifier.fillMaxSize().testTag(BotChatTags.TRANSCRIPT),
                contentPadding = androidx.compose.foundation.layout.PaddingValues(
                    top = HomeMetrics.BLOCK_GAP_PT.dp + BotChatMetrics.TRANSCRIPT_TOP_EXTRA_PT.dp,
                    bottom = BotChatMetrics.TRANSCRIPT_BOTTOM_PAD_PT.dp,
                ),
            ) {
                if (state.hasMoreHistory) {
                    item(key = "history-loader") {
                        Row(
                            modifier = Modifier
                                .fillMaxWidth()
                                .heightIn(min = BotChatMetrics.ROW_MIN_HEIGHT_PT.dp)
                                .clickable(
                                    enabled = !state.loadingHistory,
                                    role = Role.Button,
                                    onClick = onLoadHistory,
                                )
                                .testTag(BotChatTags.HISTORY_LOADER),
                            horizontalArrangement = Arrangement.Center,
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            BasicText(
                                text = if (state.loadingHistory) "正在加载历史" else "向上加载历史",
                                style = LocalUiType.current.caption.copy(
                                    color = tokens.colors.textTertiary),
                            )
                        }
                    }
                }
                if (state.isEmpty) {
                    item(key = "empty") {
                        Box(
                            modifier = Modifier
                                .fillParentMaxHeight(0.90f)
                                .fillMaxWidth(),
                            contentAlignment = Alignment.Center,
                        ) {
                            BotEmptyState(state, fish, pageActive)
                        }
                    }
                }
                items(state.rows, key = { it.id }) { row ->
                    BotTranscriptRow(
                        row = row,
                        state = state,
                        fish = fish,
                        pageActive = pageActive,
                        onAnswer = onAnswer,
                        onDismiss = onDismiss,
                        onApproval = onApproval,
                        onChecklistProgress = onChecklistProgress,
                        onChecklistSend = onChecklistSend,
                        onOpenDocument = { target ->
                            if (onOpenDocument != null) onOpenDocument(target) else documentRow = target
                        },
                        onOpenPath = onOpenPath,
                        onOpenUrl = onOpenUrl,
                        onSelectBot = onSelectBot,
                        peerAppearance = peerAppearance,
                        peerIsMainBot = peerIsMainBot,
                        peerReaction = peerReaction,
                        onInteraction = onInteraction,
                        onViewSource = { sourceRow = it },
                    )
                }
                state.live?.let { live ->
                    item(key = "live-turn") {
                        BotLiveTurnView(live)
                    }
                }
                state.streamingText?.takeIf { botAnswerHasContent(it) }?.let { streaming ->
                    item(key = "live-stream") {
                        BotAnswerBubble(
                            text = streaming,
                            streaming = true,
                            modifier = Modifier
                                .padding(horizontal = HomeMetrics.contentInset)
                                .padding(vertical = HomeMetrics.BLOCK_GAP_PT.dp / 2)
                                .testTag(BotChatTags.STREAMING_TEXT),
                        )
                    }
                }
                item(key = "transcript-bottom") { Spacer(Modifier.height(BotChatMetrics.GAP_1_PT.dp)) }
            }
            if (state.presence.line != null && state.activityLine.text.isNotEmpty()) {
                Box(
                    modifier = Modifier
                        .align(Alignment.TopCenter)
                        .fillMaxWidth()
                        .background(
                            Brush.verticalGradient(
                                0f to tokens.colors.page,
                                BotChatMetrics.ACTIVITY_FADE_SHARE to tokens.colors.page,
                                1f to tokens.colors.page.copy(alpha = 0f),
                            ),
                        )
                        .padding(
                            top = BotChatMetrics.ACTIVITY_TOP_PAD_PT.dp,
                            bottom = BotChatMetrics.ACTIVITY_BOTTOM_PAD_PT.dp,
                        ),
                ) {
                    BotActivityLine(
                        text = state.activityLine.text,
                        quiet = state.presence.lineIsQuiet,
                        problem = state.presence.lineIsProblem,
                        pageActive = pageActive,
                    )
                }
            }
        }
        BotComposer(
            state = state,
            onDraftChange = onDraftChange,
            onSend = onSend,
            onStop = onStop,
            onAttach = onAttach,
            onRemoveAttachment = onRemoveAttachment,
            onDismissAttachmentNotice = onDismissAttachmentNotice,
            onInteraction = onInteraction,
        )
    }

    sourceRow?.let { row ->
        BotSourceDialog(row = row, onDismiss = { sourceRow = null })
    }
    documentRow?.let { row ->
        BotDocumentPreview(row = row, onDismiss = { documentRow = null })
    }
}

// --------------------------------------------------------------------- header

@Composable
private fun BotHeader(
    state: BotChatSnapshot,
    fish: BotFishSlot,
    pageActive: Boolean,
    hasOnlineDevices: Boolean,
    onOpenDrawer: (() -> Unit)?,
    onOpenInfo: () -> Unit,
    onConnectDevice: () -> Unit,
    onInteraction: () -> Unit,
) {
    val tokens = LocalUiTokens.current
    var menuOpen by remember { mutableStateOf(false) }
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .statusBarsPadding()
            .padding(
                top = HomeMetrics.navTop,
                start = HomeMetrics.chromeInset,
                end = HomeMetrics.chromeInset,
            )
            .height(HomeMetrics.navButton),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        if (onOpenDrawer != null) {
            Box(
                modifier = Modifier
                    .size(HomeMetrics.navButton)
                    .shadow(
                        elevation = tokens.shadow.floatingRadius,
                        shape = CircleShape,
                        ambientColor = Color.Black.copy(alpha = tokens.shadow.floatingOpacity),
                        spotColor = Color.Black.copy(alpha = tokens.shadow.floatingOpacity),
                    )
                    .clip(CircleShape)
                    .background(tokens.colors.surface)
                    .clickable(role = Role.Button) {
                        onInteraction()
                        onOpenDrawer()
                    }
                    .semantics { contentDescription = BotChatCopy.DRAWER_OPEN }
                    .testTag(BotChatTags.DRAWER_OPEN),
                contentAlignment = Alignment.Center,
            ) {
                Column(
                    verticalArrangement = Arrangement.spacedBy(
                        BotChatMetrics.DRAWER_STROKE_GAP_PT.dp,
                    ),
                    horizontalAlignment = Alignment.Start,
                ) {
                    Box(
                        Modifier
                            .width(BotChatMetrics.DRAWER_STROKE_LONG_PT.dp)
                            .height(BotChatMetrics.DRAWER_STROKE_HEIGHT_PT.dp)
                            .clip(RoundedCornerShape(percent = 50))
                            .background(tokens.colors.primaryButton),
                    )
                    Box(
                        Modifier
                            .width(BotChatMetrics.DRAWER_STROKE_SHORT_PT.dp)
                            .height(BotChatMetrics.DRAWER_STROKE_HEIGHT_PT.dp)
                            .clip(RoundedCornerShape(percent = 50))
                            .background(tokens.colors.primaryButton),
                    )
                }
            }
            Spacer(
                Modifier.width(
                    HomeMetrics.navPillWidth - HomeMetrics.navButton,
                ),
            )
        } else {
            Spacer(Modifier.width(HomeMetrics.navPillWidth))
        }
        Box(Modifier.weight(1f), contentAlignment = Alignment.Center) {
            Row(
                modifier = Modifier
                    .height(HomeMetrics.navButton)
                    .shadow(
                        elevation = tokens.shadow.floatingRadius,
                        shape = RoundedCornerShape(percent = 50),
                        ambientColor = Color.Black.copy(alpha = tokens.shadow.floatingOpacity),
                        spotColor = Color.Black.copy(alpha = tokens.shadow.floatingOpacity),
                    )
                    .clip(RoundedCornerShape(percent = 50))
                    .background(tokens.colors.surface)
                    .clickable(role = Role.Button) {
                        onInteraction()
                        onOpenInfo()
                    }
                    .semantics { contentDescription = BotChatCopy.INFO_OPEN }
                    .testTag(BotChatTags.INFO_OPEN)
                    .padding(
                        start = BotChatMetrics.HEADER_NAME_PAD_LEADING_PT.dp,
                        end = BotChatMetrics.HEADER_NAME_PAD_TRAILING_PT.dp,
                    ),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(BotChatMetrics.GAP_8_PT.dp),
            ) {
                fish(
                    state.presence.fishState,
                    state.appearance,
                    state.isMainBot,
                    BotChatMetrics.HEADER_AVATAR_PT.dp,
                    !pageActive,
                    Modifier.size(BotChatMetrics.HEADER_AVATAR_PT.dp),
                )
                BasicText(
                    text = state.botName,
                    style = LocalUiType.current.body.copy(
                        fontSize = BotChatMetrics.HEADER_NAME_SIZE_PT.sp,
                        fontWeight = FontWeight.SemiBold,
                        color = tokens.colors.textPrimary,
                    ),
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
            }
        }
        Row(
            modifier = Modifier
                .size(width = HomeMetrics.navPillWidth, height = HomeMetrics.navButton)
                .shadow(
                    elevation = tokens.shadow.floatingRadius,
                    shape = RoundedCornerShape(percent = 50),
                    ambientColor = Color.Black.copy(alpha = tokens.shadow.floatingOpacity),
                    spotColor = Color.Black.copy(alpha = tokens.shadow.floatingOpacity),
                )
                .clip(RoundedCornerShape(percent = 50))
                .background(tokens.colors.surface),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Box(Modifier.weight(1f)) {
                Box(
                    modifier = Modifier
                        .fillMaxSize()
                        .clickable(role = Role.Button) {
                            onInteraction()
                            onConnectDevice()
                        }
                        .semantics {
                            contentDescription = if (hasOnlineDevices) {
                                "连接设备，有在线设备"
                            } else {
                                "连接设备"
                            }
                        }
                        .testTag(BotChatTags.CONNECT_DEVICE),
                    contentAlignment = Alignment.Center,
                ) {
                    PdshIconView(
                        PdshIcon.DEVICE_RADIO,
                        BotChatMetrics.HEADER_PILL_ICON_PT.dp,
                        tokens.colors.primaryButton,
                        null,
                    )
                    if (hasOnlineDevices) {
                        Box(
                            modifier = Modifier
                                .align(Alignment.TopEnd)
                                .padding(BotChatMetrics.HEADER_DEVICE_DOT_INSET_PT.dp)
                                .size(BotChatMetrics.HEADER_DEVICE_DOT_PT.dp)
                                .clip(CircleShape)
                                .background(tokens.colors.homeSuccess)
                                .border(
                                    BotChatMetrics.HEADER_DEVICE_DOT_BORDER_PT.dp,
                                    tokens.colors.page,
                                    CircleShape,
                                ),
                        )
                    }
                }
            }
            Box(Modifier.weight(1f)) {
                Box(
                    modifier = Modifier
                        .fillMaxSize()
                        .clickable(role = Role.Button) { menuOpen = true }
                        .semantics { contentDescription = "更多" }
                        .testTag(BotChatTags.HEADER_MENU),
                    contentAlignment = Alignment.Center,
                ) {
                    PdshIconView(
                        PdshIcon.CHAT_MORE,
                        BotChatMetrics.HEADER_MENU_ICON_PT.dp,
                        tokens.colors.primaryButton,
                        null,
                    )
                    DropdownMenu(expanded = menuOpen, onDismissRequest = { menuOpen = false }) {
                        DropdownMenuItem(
                            text = {
                                Text(
                                    BotUiStrings.format(
                                        "chat.menu.summary",
                                        "following" to state.followingCount,
                                        "attention" to state.needsAttentionCount,
                                    ),
                                )
                            },
                            onClick = {},
                            enabled = false,
                        )
                        HorizontalDivider()
                        listOf(
                            BotChatCopy.MENU_INFO,
                            BotChatCopy.MENU_MEMORY,
                            BotChatCopy.MENU_ROUTINES,
                            BotChatCopy.MENU_APPROVALS,
                        ).forEach { label ->
                            DropdownMenuItem(
                                text = { Text(label) },
                                onClick = {
                                    menuOpen = false
                                    onInteraction()
                                    onOpenInfo()
                                },
                            )
                        }
                    }
                }
            }
        }
    }
}

// --------------------------------------------------------------- empty state

@Composable
private fun BotEmptyState(
    state: BotChatSnapshot,
    fish: BotFishSlot,
    pageActive: Boolean,
) {
    val tokens = LocalUiTokens.current
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = HomeMetrics.contentInset)
            .padding(vertical = BotChatMetrics.EMPTY_VERTICAL_PAD_PT.dp)
            .testTag(BotChatTags.EMPTY),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center,
    ) {
        fish(
            state.fishState,
            state.appearance,
            state.isMainBot,
            BotChatMetrics.EMPTY_AVATAR_PT.dp,
            !pageActive,
            Modifier.size(BotChatMetrics.EMPTY_AVATAR_PT.dp),
        )
        Spacer(Modifier.height(BotChatMetrics.EMPTY_GAP_PT.dp))
        BasicText(
            text = BotChatCopy.EMPTY_TITLE.replace("{name}", state.botName),
            style = LocalUiType.current.body.copy(
                fontSize = BotChatMetrics.EMPTY_TITLE_SIZE_PT.sp,
                lineHeight = BotChatMetrics.EMPTY_TITLE_LINE_PT.sp,
                fontWeight = FontWeight.SemiBold,
                color = tokens.colors.textPrimary,
                textAlign = TextAlign.Center,
            ),
        )
        Spacer(Modifier.height(BotChatMetrics.EMPTY_GAP_PT.dp))
        BasicText(
            text = BotChatCopy.EMPTY_BODY,
            style = LocalUiType.current.body.copy(
                fontSize = BotChatMetrics.EMPTY_BODY_SIZE_PT.sp,
                lineHeight = BotChatMetrics.EMPTY_BODY_LINE_PT.sp,
                color = tokens.colors.textSecondary,
                textAlign = TextAlign.Center,
            ),
            modifier = Modifier.widthIn(max = BotChatMetrics.EMPTY_TEXT_MAX_WIDTH_PT.dp),
        )
    }
}

// ---------------------------------------------------------------- transcript

@Composable
private fun BotTranscriptRow(
    row: BotRow,
    state: BotChatSnapshot,
    fish: BotFishSlot,
    pageActive: Boolean,
    onAnswer: (String, String) -> Unit,
    onDismiss: (String) -> Unit,
    onChecklistProgress: (String, Int, Int) -> Unit,
    onChecklistSend: (String, Int, Int, String) -> Unit,
    onApproval: (String, BotApprovalDecision) -> Unit,
    onOpenDocument: (BotRow) -> Unit,
    onOpenPath: (String) -> Unit,
    onOpenUrl: (String) -> Unit,
    onSelectBot: (String) -> Unit,
    peerAppearance: (String) -> com.phonedsh.bot.profile.BotFishAppearance?,
    peerIsMainBot: (String) -> Boolean,
    peerReaction: (String) -> com.phonedsh.ui.bot.state.BotFishReaction?,
    onInteraction: () -> Unit,
    onViewSource: (BotRow) -> Unit,
) {
    val comm = BotAgentCommRendering.presentation(row)
    when {
        comm != null -> {
            BotAgentCommRow(
                presentation = comm,
                appearance = comm.peerID?.let(peerAppearance),
                crowned = comm.peerID?.let(peerIsMainBot) == true,
                reaction = comm.peerID?.let(peerReaction),
                fish = fish,
                onSelectBot = onSelectBot,
                modifier = Modifier
                    .padding(horizontal = HomeMetrics.contentInset)
                    .padding(vertical = HomeMetrics.BLOCK_GAP_PT.dp / 2),
            )
        }
        row.body.type == BotRowBodyType.TEXT -> {
            BotMessageContextMenu(row = row, onViewSource = onViewSource) {
                BotTextRow(row)
            }
        }
        else -> {
            val card = BotUICardContent.parse(row) ?: return
            BotCardView(
                row = row,
                card = card,
                state = state,
                onAnswer = onAnswer,
                onDismiss = onDismiss,
                onChecklistProgress = onChecklistProgress,
                onChecklistSend = onChecklistSend,
                onApproval = onApproval,
                onOpenDocument = onOpenDocument,
                onOpenPath = onOpenPath,
                onOpenUrl = onOpenUrl,
                onInteraction = onInteraction,
            )
        }
    }
}

@Composable
private fun BotMessageContextMenu(
    row: BotRow,
    onViewSource: (BotRow) -> Unit,
    content: @Composable () -> Unit,
) {
    val clipboard = LocalClipboardManager.current
    PdshContextMenu(
        surfaceId = "botMessageRow",
        state = ContextMenuRowState.unconditional,
        onAction = { item ->
            when (item.label) {
                "复制" -> clipboard.setText(AnnotatedString(BotUIRendering.copyText(row)))
                "查看来源" -> onViewSource(row)
            }
        },
        modifier = Modifier.testTag(BotChatTags.row(row.id)),
        content = content,
    )
}

@Composable
private fun BotTextRow(row: BotRow) {
    val tokens = LocalUiTokens.current
    val isUser = row.role == "user"
    val text = (row.body["text"] as? com.phonedsh.agentcore.JsonString)?.value ?: ""
    val attachments = if (isUser) {
        com.phonedsh.ui.bot.state.BotUIAttachmentParser.parseList(row.body["attachments"])
    } else {
        emptyList()
    }
    if (isUser) {
        BotContentWidth(ratio = BotChatMetrics.USER_BUBBLE_RATIO, trailing = true) {
            Column(
                modifier = Modifier
                    .background(
                        tokens.colors.userBubble,
                        RoundedCornerShape(
                            topStart = HomeMetrics.bubbleRadius,
                            topEnd = 0.dp,
                            bottomEnd = HomeMetrics.bubbleRadius,
                            bottomStart = HomeMetrics.bubbleRadius,
                        ),
                    )
                    .padding(
                        horizontal = BotChatMetrics.BUBBLE_PAD_H_PT.dp,
                        vertical = BotChatMetrics.BUBBLE_PAD_V_PT.dp,
                    ),
                verticalArrangement = Arrangement.spacedBy(BotChatMetrics.GAP_8_PT.dp),
            ) {
                if (text.isNotEmpty()) {
                    BasicText(
                        text = text,
                        style = LocalUiType.current.body.copy(
                            fontSize = HomeMetrics.BODY_SIZE_PT.sp,
                            lineHeight = HomeMetrics.BODY_LINE_PT.sp,
                            color = tokens.colors.textPrimary,
                        ),
                    )
                }
                attachments.forEach { attachment ->
                    BotUserAttachmentCard(attachment)
                }
            }
        }
    } else {
        BotAnswerBubble(text = text, streaming = false)
    }
}

/** The user row's attached-file card (`BotChatPage.swift:917-947`). */
@Composable
private fun BotUserAttachmentCard(attachment: BotAttachment) {
    val tokens = LocalUiTokens.current
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .background(tokens.colors.surface, RoundedCornerShape(BotChatMetrics.GAP_10_PT.dp))
            .border(BotChatMetrics.HAIRLINE_PT.dp, tokens.colors.borderList, RoundedCornerShape(BotChatMetrics.GAP_10_PT.dp))
            .padding(BotChatMetrics.ATTACHMENT_CARD_PAD_PT.dp)
            .testTag(BotChatTags.MESSAGE_ATTACHMENT),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(BotChatMetrics.GAP_8_PT.dp),
    ) {
        Box(
            modifier = Modifier
                .size(BotChatMetrics.ATTACHMENT_ICON_BOX_PT.dp)
                .background(
                    tokens.colors.surface,
                    RoundedCornerShape(BotChatMetrics.ATTACHMENT_ICON_RADIUS_PT.dp),
                ),
            contentAlignment = Alignment.Center,
        ) {
            PdshIconView(
                BotCardFileIcon.icon(attachment.name, attachment.mimeType),
                BotChatMetrics.ICON_15_PT.dp,
                tokens.colors.textPrimary,
                null,
            )
        }
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(BotChatMetrics.GAP_1_PT.dp)) {
            BasicText(
                text = attachment.name,
                style = LocalUiType.current.body.copy(
                    fontSize = BotChatMetrics.ATTACHMENT_NAME_SIZE_PT.sp,
                    fontWeight = FontWeight.Medium,
                    color = tokens.colors.textPrimary,
                ),
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            BasicText(
                text = "${sizeLabel(attachment.size)} · ${kindLabel(attachment.kind)}",
                style = LocalUiType.current.caption.copy(
                    fontSize = BotChatMetrics.ATTACHMENT_META_SIZE_PT.sp,
                    color = tokens.colors.textSecondary,
                ),
            )
        }
    }
}

private fun sizeLabel(bytes: Long): String {
    val units = listOf("B", "KB", "MB", "GB")
    var value = bytes.toDouble()
    var unit = 0
    while (value >= 1024 && unit < units.lastIndex) {
        value /= 1024
        unit++
    }
    return if (unit == 0) "${value.toInt()} ${units[unit]}"
    else String.format("%.1f %s", value, units[unit])
}

private fun kindLabel(kind: String): String = when (kind) {
    "image" -> "图片"
    "audio" -> "音频"
    "video" -> "视频"
    "pdf" -> "PDF"
    "markdown" -> "Markdown"
    "table" -> "表格"
    "json" -> "JSON"
    "document" -> "文档"
    "archive" -> "压缩包"
    else -> "文件"
}

/** The Bot's own words (`BotChatPage.swift:952-975`). */
@Composable
internal fun BotAnswerBubble(
    text: String,
    streaming: Boolean,
    modifier: Modifier = Modifier,
) {
    val tokens = LocalUiTokens.current
    BotContentWidth {
        Box(
            modifier = modifier
                .background(
                    tokens.colors.surface,
                    RoundedCornerShape(
                        topStart = HomeMetrics.bubbleRadius,
                        topEnd = HomeMetrics.bubbleRadius,
                        bottomEnd = HomeMetrics.bubbleRadius,
                        bottomStart = 0.dp,
                    ),
                )
                .border(
                    BotChatMetrics.HAIRLINE_PT.dp,
                    tokens.colors.borderList,
                    RoundedCornerShape(
                        topStart = HomeMetrics.bubbleRadius,
                        topEnd = HomeMetrics.bubbleRadius,
                        bottomEnd = HomeMetrics.bubbleRadius,
                        bottomStart = 0.dp,
                    ),
                )
                .padding(
                    horizontal = BotChatMetrics.BUBBLE_PAD_H_PT.dp,
                    vertical = BotChatMetrics.BUBBLE_PAD_V_PT.dp,
                ),
        ) {
            BasicText(
                text = text,
                style = LocalUiType.current.body.copy(
                    fontSize = HomeMetrics.BODY_SIZE_PT.sp,
                    lineHeight = HomeMetrics.BODY_LINE_PT.sp,
                    color = tokens.colors.textPrimary,
                ),
            )
        }
    }
}

/** True for a non-blank answer chunk (`BotChatPage.swift:958-960`). */
internal fun botAnswerHasContent(text: String): Boolean = text.trim().isNotEmpty()

// ------------------------------------------------------------------ composer

@Composable
private fun BotComposer(
    state: BotChatSnapshot,
    onDraftChange: (String) -> Unit,
    onSend: () -> Unit,
    onStop: () -> Unit,
    onAttach: () -> Unit,
    onRemoveAttachment: (Int) -> Unit,
    onDismissAttachmentNotice: () -> Unit,
    onInteraction: () -> Unit,
) {
    val tokens = LocalUiTokens.current
    val canSend = state.draft.trim().isNotEmpty() || state.draftAttachments.isNotEmpty()
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .background(tokens.colors.page)
            .padding(
                start = HomeMetrics.chromeInset,
                end = HomeMetrics.chromeInset,
                top = BotChatMetrics.COMPOSER_TOP_PAD_PT.dp,
                bottom = BotChatMetrics.COMPOSER_BOTTOM_PAD_PT.dp,
            )
            .navigationBarsPadding(),
        verticalArrangement = Arrangement.spacedBy(BotChatMetrics.GAP_8_PT.dp),
    ) {
        if (state.draftAttachments.isNotEmpty()) {
            LazyRow(
                modifier = Modifier.fillMaxWidth().height(BotChatMetrics.CHIP_TRAY_HEIGHT_PT.dp),
                horizontalArrangement = Arrangement.spacedBy(BotChatMetrics.GAP_8_PT.dp),
            ) {
                items(state.draftAttachments) { item ->
                    val index = state.draftAttachments.indexOf(item)
                    BotAttachmentChip(
                        item = item,
                        index = index,
                        onRemove = { onRemoveAttachment(index) },
                    )
                }
            }
        }
        if (state.attachmentNotice != null) {
            Row(
                modifier = Modifier.fillMaxWidth().testTag(BotChatTags.COMPOSER_ATTACHMENT_NOTICE),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(BotChatMetrics.GAP_6_PT.dp),
            ) {
                PdshIconView(PdshIcon.WARNING, BotChatMetrics.GAP_12_PT.dp, tokens.colors.pageDanger, null)
                BasicText(
                    text = state.attachmentNotice,
                    style = LocalUiType.current.caption.copy(color = tokens.colors.pageDanger),
                    modifier = Modifier.weight(1f),
                    maxLines = 2,
                )
                Box(
                    modifier = Modifier
                        .size(BotChatMetrics.SETTLEMENT_MIN_HEIGHT_PT.dp)
                        .clickable(role = Role.Button, onClick = onDismissAttachmentNotice)
                        .semantics {
                            contentDescription = BotChatCopy.DISMISS_ATTACHMENT_NOTICE
                        },
                    contentAlignment = Alignment.Center,
                ) {
                    PdshIconView(PdshIcon.CLOSE, BotChatMetrics.GAP_10_PT.dp, tokens.colors.pageDanger, null)
                }
            }
        }
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .heightIn(min = BotChatMetrics.COMPOSER_MIN_HEIGHT_PT.dp)
                .shadow(
                    elevation = tokens.shadow.floatingRadius,
                    shape = RoundedCornerShape(BotChatMetrics.COMPOSER_RADIUS_PT.dp),
                    ambientColor = Color.Black.copy(alpha = tokens.shadow.floatingOpacity),
                    spotColor = Color.Black.copy(alpha = tokens.shadow.floatingOpacity),
                )
                .clip(RoundedCornerShape(BotChatMetrics.COMPOSER_RADIUS_PT.dp))
                .background(tokens.colors.surface)
                .border(
                    BotChatMetrics.HAIRLINE_PT.dp,
                    tokens.colors.borderList,
                    RoundedCornerShape(BotChatMetrics.COMPOSER_RADIUS_PT.dp),
                )
                .padding(
                    horizontal = BotChatMetrics.COMPOSER_INSET_PT.dp,
                    vertical = BotChatMetrics.COMPOSER_INSET_PT.dp,
                ),
            verticalAlignment = Alignment.Bottom,
            horizontalArrangement = Arrangement.spacedBy(BotChatMetrics.COMPOSER_INPUT_GAP_PT.dp),
        ) {
            Box(
                modifier = Modifier
                    .size(BotChatMetrics.COMPOSER_CONTROL_PT.dp)
                    .clip(CircleShape)
                    .background(tokens.colors.userBubble)
                    .clickable(role = Role.Button) {
                        onInteraction()
                        onAttach()
                    }
                    .semantics { contentDescription = BotChatCopy.ATTACH }
                    .testTag(BotChatTags.COMPOSER_ATTACH),
                contentAlignment = Alignment.Center,
            ) {
                PdshIconView(
                    PdshIcon.PLUS,
                    BotChatMetrics.COMPOSER_ATTACH_GLYPH_PT.dp,
                    tokens.colors.textPrimary,
                    null,
                )
            }
            BasicTextField(
                value = state.draft,
                onValueChange = { value ->
                    onDraftChange(value)
                    onInteraction()
                },
                modifier = Modifier
                    .weight(1f)
                    .padding(vertical = BotChatMetrics.COMPOSER_INPUT_PAD_V_PT.dp)
                    .testTag(BotChatTags.COMPOSER_INPUT),
                textStyle = LocalUiType.current.body.copy(
                    fontSize = HomeMetrics.BODY_SIZE_PT.sp,
                    color = tokens.colors.textPrimary,
                ),
                maxLines = BotChatMetrics.COMPOSER_MAX_LINES,
                decorationBox = { inner ->
                    Box {
                        if (state.draft.isEmpty()) {
                            BasicText(
                                text = BotChatCopy.INPUT_PLACEHOLDER.replace(
                                    "{name}", state.botName),
                                style = LocalUiType.current.body.copy(
                                    fontSize = HomeMetrics.BODY_SIZE_PT.sp,
                                    color = tokens.colors.inputPlaceholder,
                                ),
                            )
                        }
                        inner()
                    }
                },
            )
            Box(
                modifier = Modifier
                    .size(BotChatMetrics.COMPOSER_CONTROL_PT.dp)
                    .clip(CircleShape)
                    .background(
                        if (canSend || state.runningTurnID != null) {
                            tokens.colors.primaryButton
                        } else {
                            tokens.colors.userBubble
                        },
                    )
                    .clickable(
                        enabled = if (state.runningTurnID != null && !canSend) true else canSend,
                        role = Role.Button,
                    ) {
                        if (state.runningTurnID != null && !canSend) onStop() else onSend()
                    }
                    .semantics {
                        contentDescription = when {
                            state.runningTurnID != null && !canSend -> BotChatCopy.STOP
                            state.runningTurnID != null -> BotChatCopy.STEER
                            else -> BotChatCopy.SEND
                        }
                    }
                    .testTag(
                        if (state.runningTurnID != null && !canSend) {
                            BotChatTags.COMPOSER_STOP
                        } else {
                            BotChatTags.COMPOSER_SEND
                        },
                    ),
                contentAlignment = Alignment.Center,
            ) {
                val ink = if (canSend || state.runningTurnID != null) {
                    tokens.colors.primaryButtonInk
                } else {
                    tokens.colors.iconMuted
                }
                if (state.runningTurnID != null && !canSend) {
                    Box(
                        Modifier
                            .size(BotChatMetrics.ICON_11_PT.dp)
                            .background(ink, RoundedCornerShape(BotChatMetrics.GAP_2_PT.dp)),
                    )
                } else {
                    PdshIconView(
                        PdshIcon.SEND,
                        BotChatMetrics.COMPOSER_SEND_GLYPH_PT.dp,
                        ink,
                        null,
                    )
                }
            }
        }
    }
}

@Composable
private fun BotAttachmentChip(
    item: BotDraftAttachment,
    index: Int,
    onRemove: () -> Unit,
) {
    val tokens = LocalUiTokens.current
    Row(
        modifier = Modifier
            .height(BotChatMetrics.CHIP_HEIGHT_PT.dp)
            .background(tokens.colors.surface, RoundedCornerShape(percent = 50))
            .border(BotChatMetrics.HAIRLINE_PT.dp, tokens.colors.borderList, RoundedCornerShape(percent = 50))
            .padding(start = BotChatMetrics.GAP_10_PT.dp, end = BotChatMetrics.GAP_2_PT.dp)
            .testTag(BotChatTags.attachmentChip(index)),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(BotChatMetrics.GAP_6_PT.dp),
    ) {
        PdshIconView(
            BotCardFileIcon.icon(item.attachment.name, item.attachment.mimeType),
            BotChatMetrics.ICON_13_PT.dp,
            tokens.colors.textSecondary,
            null,
        )
        Column(
            modifier = Modifier.widthIn(max = BotChatMetrics.CHIP_MAX_NAME_WIDTH_PT.dp),
            verticalArrangement = Arrangement.spacedBy(0.dp),
        ) {
            BasicText(
                text = item.attachment.name,
                style = LocalUiType.current.body.copy(
                    fontSize = BotChatMetrics.COMMAND_SIZE_PT.sp,
                    fontWeight = FontWeight.Medium,
                    color = tokens.colors.textPrimary,
                ),
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            BasicText(
                text = "${sizeLabel(item.attachment.size)} · ${kindLabel(item.attachment.kind)}",
                style = LocalUiType.current.caption.copy(
                    fontSize = BotChatMetrics.ATTACHMENT_META_SIZE_PT.sp,
                    color = tokens.colors.textTertiary,
                ),
            )
        }
        Box(
            modifier = Modifier
                .size(BotChatMetrics.CHIP_REMOVE_TARGET_PT.dp)
                .clickable(role = Role.Button, onClick = onRemove)
                .semantics {
                    contentDescription = BotChatCopy.REMOVE_ATTACHMENT.replace(
                        "{name}", item.attachment.name)
                },
            contentAlignment = Alignment.Center,
        ) {
            PdshIconView(PdshIcon.CLOSE, BotChatMetrics.GAP_10_PT.dp, tokens.colors.textSecondary, null)
        }
    }
}

// ------------------------------------------------------------------- dialogs

@Composable
private fun BotSourceDialog(row: BotRow, onDismiss: () -> Unit) {
    val tokens = LocalUiTokens.current
    AlertDialog(
        onDismissRequest = onDismiss,
        confirmButton = {
            TextButton(onClick = onDismiss) {
                Text("好", color = tokens.colors.textPrimary)
            }
        },
        title = { Text("消息来源", color = tokens.colors.textPrimary) },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(BotChatMetrics.GAP_4_PT.dp)) {
                SourceLine("rowID", row.id)
                SourceLine("botID", row.botID)
                SourceLine("表面", BotUIRendering.surface(row))
                SourceLine("序号", "${row.seq} / ${row.updatedSeq}")
                SourceLine("信任", row.provenance.trust)
                SourceLine("外部内容", if (row.provenance.tainted) "是" else "否")
                row.provenance.eventIDs.forEach { eventID ->
                    BasicText(
                        text = eventID,
                        style = LocalUiType.current.code.copy(color = tokens.colors.textSecondary),
                    )
                }
            }
        },
    )
}

@Composable
private fun SourceLine(label: String, value: String) {
    val tokens = LocalUiTokens.current
    Row(horizontalArrangement = Arrangement.spacedBy(BotChatMetrics.GAP_8_PT.dp)) {
        BasicText(
            text = label,
            style = LocalUiType.current.caption.copy(color = tokens.colors.textPlaceholder),
        )
        BasicText(
            text = value,
            style = LocalUiType.current.caption.copy(color = tokens.colors.textPrimary),
        )
    }
}

@Composable
private fun BotDocumentPreview(row: BotRow, onDismiss: () -> Unit) {
    val tokens = LocalUiTokens.current
    val title = firstString(row.body, "title", "name", "fileName") ?: BotChatCopy.DOCUMENT_TITLE_FALLBACK
    val content = firstString(row.body, "content", "markdown")
    val summary = firstString(row.body, "summary", "description")
    val path = firstString(row.body, "path", "url")
    AlertDialog(
        onDismissRequest = onDismiss,
        confirmButton = {
            TextButton(onClick = onDismiss) {
                Text("完成", color = tokens.colors.textPrimary)
            }
        },
        title = { Text(title, color = tokens.colors.textPrimary) },
        text = {
            Column(
                modifier = Modifier.heightIn(max = BotChatMetrics.DIALOG_MAX_HEIGHT_PT.dp),
                verticalArrangement = Arrangement.spacedBy(BotChatMetrics.GAP_12_PT.dp),
            ) {
                if (content != null) {
                    BasicText(
                        text = content,
                        style = LocalUiType.current.body.copy(color = tokens.colors.textPrimary),
                    )
                } else {
                    if (summary != null) {
                        BasicText(
                            text = summary,
                            style = LocalUiType.current.body.copy(
                                color = tokens.colors.textSecondary),
                        )
                    }
                    BotFailureRow(BotChatCopy.DOCUMENT_NO_BODY)
                }
                if (path != null) {
                    BasicText(
                        text = path,
                        style = LocalUiType.current.caption.copy(
                            color = tokens.colors.textTertiary),
                    )
                }
            }
        },
    )
}

/** Convenience for previews/tests: the page's page-active local provider. */
@Composable
internal fun WithBotPageActive(active: Boolean, content: @Composable () -> Unit) {
    CompositionLocalProvider(LocalBotPageActive provides active) { content() }
}
