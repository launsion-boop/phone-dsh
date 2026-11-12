// The chat rows: message bubbles, tool runs, injected context and system events.
// SPDX-License-Identifier: MIT
@file:OptIn(androidx.compose.foundation.ExperimentalFoundationApi::class)
//
// Spec: `spec/ui/v1/README.md` §2 (component semantics), §3.1 (ScreenState) and
// §4 (the six signature surfaces). A row is one `ScreenState` row; the fold over
// UiState happens in `ChatScreenState`, never here.
//
// Mirror: `examples/probe-app/PhoneDSHProbe/NativeMessageRows.swift` (the
// disclosure row, the thinking row, the system-event row), `ChatPage.swift`
// `ChatMessageRow` / `ToolRunRow` / `ContextInjectionCard` and
// `NativeChatTimelineChrome.swift` `NativeContextSourceGroup`. The per-row gap
// is 16 after a user bubble and 20 between every other transcript block.
//
// Geometry comes from the shared source-derived HomeMetrics.
package com.phonedsh.ui.page

import android.content.Context
import android.content.Intent
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.defaultMinSize
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicText
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import com.phonedsh.ui.ChatMetrics
import com.phonedsh.ui.HomeMetrics
import com.phonedsh.ui.UiStrings
import com.phonedsh.ui.UiTags
import com.phonedsh.ui.disclosure.PdshChevron
import com.phonedsh.ui.disclosure.PdshDisclosure
import com.phonedsh.ui.icon.PdshIcon
import com.phonedsh.ui.menu.ContextMenuItem
import com.phonedsh.ui.menu.ContextMenuRowState
import com.phonedsh.ui.menu.PdshContextMenu
import com.phonedsh.ui.state.ChatRow
import com.phonedsh.ui.state.ChatTurnState
import com.phonedsh.ui.state.ChatProcessCategory
import com.phonedsh.ui.state.ContextEntry
import com.phonedsh.ui.state.ToolEntry
import com.phonedsh.ui.state.contextSourceName
import com.phonedsh.ui.surface.BubbleBadge
import com.phonedsh.ui.surface.BubbleRole
import com.phonedsh.ui.surface.ChangedFilesCard
import com.phonedsh.ui.surface.ChatBubble
import com.phonedsh.ui.surface.MarkdownBody
import com.phonedsh.ui.surface.ThinkingPill
import com.phonedsh.ui.surface.ToolDetailCard
import com.phonedsh.ui.surface.ToolRow
import com.phonedsh.ui.theme.LocalUiTokens
import com.phonedsh.ui.theme.LocalUiType
import com.phonedsh.ui.theme.generated.TokenContextMenuWhen
import com.phonedsh.ui.theme.generated.UiTokenNames

/**
 * The token inventory of the row renderer; `PageTokenReferenceTest` fails if a
 * use site reads a token that is not listed here.
 */
internal object ChatRowsTokens {
    val refs: List<String> = listOf(
        UiTokenNames.COLORS_ACCENT,
        UiTokenNames.COLORS_BORDER,
        UiTokenNames.COLORS_BORDER_LIST,
        UiTokenNames.COLORS_DANGER,
        UiTokenNames.COLORS_PRIMARY,
        UiTokenNames.COLORS_SECONDARY,
        UiTokenNames.COLORS_SELECTOR,
        UiTokenNames.COLORS_SURFACE,
        UiTokenNames.COLORS_TERTIARY,
        UiTokenNames.COLORS_WARNING,
        UiTokenNames.GEOMETRY_COMPOSER_CONTROL_SIZE,
        UiTokenNames.GEOMETRY_PAGE_ROW_MIN_HEIGHT,
        UiTokenNames.GEOMETRY_SUMMARY_DOT_DIAMETER,
        UiTokenNames.GEOMETRY_THINKING_CONTENT_INDENT,
        UiTokenNames.GEOMETRY_TOOL_DETAIL_INDENT,
        UiTokenNames.GEOMETRY_TOOL_DETAIL_VERTICAL,
        UiTokenNames.RADIUS_CARD,
        UiTokenNames.SPACING_BADGE_INSET_H,
        UiTokenNames.SPACING_CARD_INSET,
        UiTokenNames.SPACING_CODE_TOOLBAR,
        UiTokenNames.SPACING_COPY_GAP,
        UiTokenNames.SPACING_ICON_TEXT,
        UiTokenNames.STROKE_HAIRLINE,
        UiTokenNames.TYPOGRAPHY_CAPTION,
        UiTokenNames.TYPOGRAPHY_SECONDARY,
    )
}

/**
 * The visible chat rows in order.
 *
 * @param rows the projected rows (never re-ordered here).
 * @param expandedRowIds the rows the user expanded (tool entries and thinking
 *   pills; a tool run expands one call at a time, like the iOS per-row state).
 * @param onToggleRow expand/collapse one row.
 * @param tag the list's stable test tag.
 * @param onShareText the host's system-share-sheet route for a bubble's share
 *   item; `null` keeps the page's own chooser (see [ChatRowItem]).
 */
@Composable
internal fun ChatRowList(
    rows: List<ChatRow>,
    expandedRowIds: Set<String>,
    onToggleRow: (String) -> Unit,
    tag: String = UiTags.CHAT_LIST,
    modifier: Modifier = Modifier,
    onOpenFile: ((String) -> Unit)? = null,
    onOpenResource: ((String) -> Unit)? = null,
    imageSource: com.phonedsh.ui.surface.MarkdownImageSource? = null,
    onShareText: ((String) -> Unit)? = null,
) {
    LazyColumn(
        modifier = modifier
            .fillMaxSize()
            .testTag(tag),
    ) {
        itemsIndexed(items = rows, key = { _, row -> row.id }) { index, row ->
            val gap = rowGap(previous = rows.getOrNull(index - 1), current = row)
            Box(modifier = if (gap == null) Modifier else Modifier.padding(top = gap)) {
                ChatRowItem(
                    row = row,
                    expandedRowIds = expandedRowIds,
                    onToggleRow = onToggleRow,
                    onOpenFile = onOpenFile,
                    onOpenResource = onOpenResource,
                    imageSource = imageSource,
                    onShareText = onShareText,
                )
            }
        }
    }
}

/**
 * The gap the iOS `spacing(before:in:)` puts above a row.
 *
 * @param previous the row above; `null` for the first row.
 * @param current the row being measured.
 * @return the gap, or `null` above the first row (no padding at all).
 */
@Composable
internal fun rowGap(previous: ChatRow?, current: ChatRow): Dp? {
    if (previous == null) return null
    return if (previous is ChatRow.User) HomeMetrics.paragraphGap else HomeMetrics.blockGap
}

/**
 * One row, rendered by the surface that owns it (§4).
 *
 * @param row the projected row.
 * @param expandedRowIds the open tool entries and thinking pills.
 * @param onToggleRow the fold action.
 * @param onShareText the host's system-share-sheet route for a user bubble's
 *   share item (`interaction.md` §3 rule 4). When `null`, the row starts the
 *   platform chooser itself so the menu item is never dead; the host callback
 *   lets the app own the sheet instead.
 */
@Composable
internal fun ChatRowItem(
    row: ChatRow,
    expandedRowIds: Set<String>,
    onToggleRow: (String) -> Unit,
    modifier: Modifier = Modifier,
    onOpenFile: ((String) -> Unit)? = null,
    onOpenResource: ((String) -> Unit)? = null,
    inListCard: Boolean = false,
    imageSource: com.phonedsh.ui.surface.MarkdownImageSource? = null,
    onShareText: ((String) -> Unit)? = null,
) {
    val tokens = LocalUiTokens.current
    // PR22 reading content uses the source HomeSpec's 20pt inset.
    val horizontal = if (inListCard) Dp(0f) else HomeMetrics.contentInset
    when (row) {
        is ChatRow.User -> BoxWithConstraints(modifier = modifier.fillMaxWidth()) {
            // Capture the row's real container before this row applies its reading
            // inset. ChatBubble's shared rule already subtracts `contentInset`
            // (`ChatMetrics.userBubbleMaxWidth`), so passing the inset content column
            // would deduct it twice (360 -> 320 -> 224 instead of the shared 256).
            val rowContainerWidth = maxWidth
            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(horizontal = horizontal),
                verticalArrangement = Arrangement.spacedBy(HomeMetrics.paragraphGap),
            ) {
                // Two row elements, two edges: the bubble hugs the trailing edge,
                // the queue label hugs the leading edge (iOS `queueLine` sits in a
                // leading VStack under a trailing `userBubble`). The bubble surface
                // never learns that a label exists.
                Box(modifier = Modifier.fillMaxWidth()) {
                    // Rule 1: long press opens the frozen `userBubble` surface on
                    // this bubble. A tap has no row action to preserve, so it stays
                    // the bubble's own gesture (none). The bubble sees text only.
                    val hasText = row.text.isNotEmpty()
                    val clipboard = LocalClipboardManager.current
                    val context = LocalContext.current
                    val shareBubble: (ContextMenuItem) -> Unit = { _ ->
                        val share = onShareText
                        if (share != null) {
                            share(row.text)
                        } else {
                            startTextShare(context = context, text = row.text)
                        }
                    }
                    PdshContextMenu(
                        surfaceId = USER_BUBBLE_SURFACE,
                        state = ContextMenuRowState.of(TokenContextMenuWhen.HAS_TEXT to hasText),
                        onAction = { clipboard.setText(AnnotatedString(row.text)) },
                        onShare = shareBubble,
                        modifier = Modifier.align(Alignment.CenterEnd),
                    ) {
                        ChatBubble(
                            role = BubbleRole.USER,
                            text = row.text,
                            containerWidth = rowContainerWidth,
                        )
                    }
                }
                if (row.attachments.isNotEmpty()) {
                    AttachmentList(attachments = row.attachments, onOpenFile = onOpenFile)
                }
                if (row.badge != null) {
                    BubbleBadge(text = row.badge, modifier = Modifier.align(Alignment.Start))
                }
            }
        }

        is ChatRow.Assistant -> Column(
            modifier = modifier
                .fillMaxWidth()
                .padding(horizontal = horizontal),
            verticalArrangement = Arrangement.spacedBy(HomeMetrics.paragraphGap),
        ) {
            // iOS renders an answer as markdown (`NativeMarkdownBody`): prose,
            // headings, lists, quotes, fenced code, GFM tables, typeset math, raw
            // HTML kept literal and footnote references. `MarkdownBody` owns that
            // grammar; this row only places it. Rule 1: the long-press menu is
            // `assistantBody`; nested markdown links keep their own taps because
            // the menu wrapper only claims an unconsumed press.
            val clipboard = LocalClipboardManager.current
            PdshContextMenu(
                surfaceId = ASSISTANT_BODY_SURFACE,
                state = ContextMenuRowState.of(
                    TokenContextMenuWhen.HAS_TEXT to row.text.isNotEmpty(),
                ),
                onAction = { clipboard.setText(AnnotatedString(row.text)) },
            ) {
                MarkdownBody(
                    markdown = if (row.text.isEmpty()) EMPTY_ANSWER else row.text,
                    modifier = Modifier.testTag(UiTags.BUBBLE),
                    onOpenFile = onOpenFile,
                    onOpenResource = onOpenResource,
                    imageSource = imageSource,
                )
            }
            if (row.changes.isNotEmpty()) {
                // iOS `assistantBody` is a 6 pt VStack and the card adds 4 pt of its
                // own top padding (`NativeChangedFilesCard.swift:97`): 10 pt in total,
                // which the column's 5 pt gap plus this 5 pt pad reproduces.
                if (onOpenFile != null) ChangedFilesCard(
                    changes = row.changes,
                    modifier = Modifier.padding(top = HomeMetrics.paragraphGap),
                    onOpenFile = onOpenFile,
                )
            }
            // iOS attaches visible message actions to *user* rows only; the
            // assistant body carries a context menu instead (`ChatPage.swift`
            // `case .assistant: assistantBody.contextMenu`), so no action row is
            // drawn here. The old row was 28 pt of content iOS never renders.
        }

        is ChatRow.Thinking -> Box(
            modifier = modifier
                .fillMaxWidth()
                .padding(horizontal = horizontal),
        ) {
            ThinkingPill(
                summary = row.summary,
                streaming = row.streaming,
                expanded = row.id in expandedRowIds,
                onToggle = { onToggleRow(row.id) },
                detail = row.fullReasoning,
                detailTruncated = row.fullReasoningTruncated,
                onOpenFile = onOpenFile,
                onOpenResource = onOpenResource,
                imageSource = imageSource,
            )
        }

        is ChatRow.ToolRun -> Column(
            modifier = modifier
                .fillMaxWidth()
                .padding(horizontal = horizontal),
            // iOS `ToolRunRow`: a VStack of one disclosure line per call/result.
            verticalArrangement = Arrangement.spacedBy(HomeMetrics.disclosureGap),
        ) {
            row.entries.forEach { entry ->
                ToolEntryRow(
                    entry = entry,
                    expanded = entry.id in expandedRowIds,
                    onToggle = { onToggleRow(entry.id) },
                    onOpenFile = onOpenFile,
                    onOpenResource = onOpenResource,
                    inListCard = inListCard,
                )
            }
        }

        is ChatRow.ProcessGroup -> ProcessGroupRow(
            row = row,
            // iOS NativeToolCallRow/ToolRunRow starts expanded; the shared local
            // id is therefore a user-collapsed marker for this group.
            expanded = row.id !in expandedRowIds || !row.showsHeader,
            expandedRowIds = expandedRowIds,
            onToggle = { onToggleRow(row.id) },
            onToggleRow = onToggleRow,
            onOpenFile = onOpenFile,
            onOpenResource = onOpenResource,
            modifier = modifier,
            imageSource = imageSource,
            onShareText = onShareText,
        )

        is ChatRow.TurnProcess -> TurnProcessRow(
            row = row,
            expandedRowIds = expandedRowIds,
            onToggle = { onToggleRow(row.id) },
            onToggleRow = onToggleRow,
            onOpenFile = onOpenFile,
            onOpenResource = onOpenResource,
            modifier = modifier,
            imageSource = imageSource,
            onShareText = onShareText,
        )

        is ChatRow.TurnTail -> TurnTailRow(row = row, modifier = modifier)

        is ChatRow.Context -> ContextGroupRow(
            entries = row.entries,
            expanded = row.id in expandedRowIds,
            onToggle = { onToggleRow(row.id) },
            modifier = modifier
                .fillMaxWidth()
                .padding(horizontal = horizontal),
        )

        is ChatRow.QuestionReply -> Column(
            modifier = modifier
                .fillMaxWidth()
                .padding(horizontal = horizontal),
            verticalArrangement = Arrangement.spacedBy(HomeMetrics.paragraphGap),
            horizontalAlignment = Alignment.End,
        ) {
            ChatBubble(role = BubbleRole.USER, text = row.text)
        }

        is ChatRow.SystemEvent -> SystemEventRow(
            row = row,
            modifier = modifier
                .fillMaxWidth()
                .padding(horizontal = horizontal),
        )
    }
}

@Composable
private fun ProcessGroupRow(
    row: ChatRow.ProcessGroup,
    expanded: Boolean,
    expandedRowIds: Set<String>,
    onToggle: () -> Unit,
    onToggleRow: (String) -> Unit,
    onOpenFile: ((String) -> Unit)?,
    onOpenResource: ((String) -> Unit)?,
    modifier: Modifier = Modifier,
    imageSource: com.phonedsh.ui.surface.MarkdownImageSource? = null,
    onShareText: ((String) -> Unit)? = null,
) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    Column(modifier = modifier.fillMaxWidth()) {
        if (row.showsHeader) {
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(horizontal = HomeMetrics.contentInset)
                    .clickable(role = Role.Button, onClick = onToggle)
                    .semantics(mergeDescendants = true) {
                        contentDescription = row.title
                        stateDescription = if (expanded) UiStrings.EXPANDED else UiStrings.COLLAPSED
                    }
                    .testTag(PROCESS_GROUP_TAG)
                    .padding(bottom = if (expanded) tokens.spacing.codeToolbar else ChatMetrics.NO_GAP_PT.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(ChatMetrics.DISCLOSURE_ICON_GAP_PT.dp),
            ) {
                BasicText(
                    text = if (expanded) "⌃" else processCategoryGlyph(row.categories.firstOrNull()),
                    style = type.secondary.copy(color = tokens.colors.tertiary),
                    modifier = Modifier.width(ChatMetrics.DISCLOSURE_ICON_PT.dp),
                )
                BasicText(
                    text = row.title,
                    style = type.secondary.copy(color = tokens.colors.tertiary),
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
            }
        }
        if (!row.showsHeader || expanded) {
            Column(
                modifier = if (row.showsHeader) Modifier
                    .fillMaxWidth()
                    .padding(horizontal = HomeMetrics.contentInset)
                    .clip(RoundedCornerShape(HomeMetrics.listCardRadius))
                    .background(tokens.colors.surface)
                    .border(tokens.stroke.hairline, tokens.colors.borderList, RoundedCornerShape(HomeMetrics.listCardRadius))
                    .padding(horizontal = tokens.spacing.cardInset, vertical = HomeMetrics.disclosureGap)
                else Modifier.fillMaxWidth(),
                verticalArrangement = Arrangement.spacedBy(HomeMetrics.disclosureGap),
            ) {
                row.entries.forEach { entry ->
                    ChatRowItem(
                        row = entry,
                        expandedRowIds = expandedRowIds,
                        onToggleRow = onToggleRow,
                        onOpenFile = onOpenFile,
                        onOpenResource = onOpenResource,
                        imageSource = imageSource,
                        inListCard = row.showsHeader,
                        onShareText = onShareText,
                    )
                }
            }
        }
    }
}

private fun processCategoryGlyph(category: ChatProcessCategory?): String = when (category) {
    ChatProcessCategory.THINKING -> "◌"
    ChatProcessCategory.READ, ChatProcessCategory.READ_IMAGE, ChatProcessCategory.WEB_FETCH -> "▤"
    ChatProcessCategory.SEARCH, ChatProcessCategory.WEB_SEARCH -> "⌕"
    ChatProcessCategory.EDIT, ChatProcessCategory.WRITE -> "✎"
    ChatProcessCategory.COMMANDS, ChatProcessCategory.CODE -> "›_"
    ChatProcessCategory.SUBAGENTS -> "⋯"
    ChatProcessCategory.PLAN -> "☷"
    ChatProcessCategory.QUESTIONS -> "?"
    ChatProcessCategory.TOOLS, null -> "◦"
}

/**
 * One closed turn's control row (iOS `NativeTurnProcessRow` over the turn's
 * process rows).
 *
 * Rule 1 of `interaction.md` §7: the process body is a disclosure driven by
 * `motion.disclosure`; the header is outside the animated region so the row the
 * person tapped never moves. The final answer is *not* part of the folded body
 * (iOS keeps it on screen when the turn is folded), so it is rendered once,
 * below the disclosure, and stays visible in both states.
 *
 * @param onShareText forwarded to a nested user bubble's share item.
 */
@Composable
private fun TurnProcessRow(
    row: ChatRow.TurnProcess,
    expandedRowIds: Set<String>,
    onToggle: () -> Unit,
    onToggleRow: (String) -> Unit,
    onOpenFile: ((String) -> Unit)?,
    onOpenResource: ((String) -> Unit)?,
    modifier: Modifier = Modifier,
    imageSource: com.phonedsh.ui.surface.MarkdownImageSource? = null,
    onShareText: ((String) -> Unit)? = null,
) {
    val expanded = row.expanded || !row.foldable
    val closingId = row.closingAssistant?.id
    val processEntries = row.entries.filter { entry -> entry.id != closingId }
    val header: @Composable () -> Unit = {
        TurnProcessHeader(row = row, expanded = expanded, foldable = row.foldable, onToggle = onToggle)
    }
    Column(modifier = modifier.fillMaxWidth()) {
        if (row.foldable) {
            PdshDisclosure(
                expanded = row.expanded,
                onToggle = { onToggle() },
                modifier = Modifier.fillMaxWidth(),
                tag = TURN_PROCESS_DISCLOSURE_TAG,
                anchorKey = row.id,
                header = header,
                body = {
                    TurnProcessEntries(
                        entries = processEntries,
                        expandedRowIds = expandedRowIds,
                        onToggleRow = onToggleRow,
                        onOpenFile = onOpenFile,
                        onOpenResource = onOpenResource,
                        imageSource = imageSource,
                        onShareText = onShareText,
                    )
                },
            )
            row.closingAssistant?.let { closing ->
                ChatRowItem(
                    row = closing,
                    expandedRowIds = expandedRowIds,
                    onToggleRow = onToggleRow,
                    onOpenFile = onOpenFile,
                    onOpenResource = onOpenResource,
                    imageSource = imageSource,
                    onShareText = onShareText,
                    modifier = Modifier.padding(top = IOS_TURN_CONTROL_GAP),
                )
            }
        } else {
            header()
            TurnProcessEntries(
                entries = row.entries,
                expandedRowIds = expandedRowIds,
                onToggleRow = onToggleRow,
                onOpenFile = onOpenFile,
                onOpenResource = onOpenResource,
                imageSource = imageSource,
                onShareText = onShareText,
            )
        }
    }
}

/** The fixed disclosure header; the divider belongs to it, not to the body. */
@Composable
private fun TurnProcessHeader(
    row: ChatRow.TurnProcess,
    expanded: Boolean,
    foldable: Boolean,
    onToggle: () -> Unit,
) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    Column(modifier = Modifier.fillMaxWidth()) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = HomeMetrics.contentInset)
                .height(ChatMetrics.TURN_PROCESS_HEIGHT_PT.dp)
                .then(
                    if (foldable) {
                        Modifier
                    } else {
                        Modifier.clickable(enabled = false, role = Role.Button, onClick = onToggle)
                    },
                )
                .semantics(mergeDescendants = true) {
                    contentDescription = turnProcessLabel(row.outcome, row.elapsedMillis)
                    stateDescription = if (expanded) UiStrings.EXPANDED else UiStrings.COLLAPSED
                }
                .testTag(TURN_PROCESS_TAG),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            BasicText(
                text = turnProcessLabel(row.outcome, row.elapsedMillis),
                style = type.secondary.copy(color = if (row.outcome == ChatTurnState.FAILED) tokens.colors.danger else tokens.colors.tertiary),
                modifier = Modifier.weight(1f),
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            if (row.foldable) {
                PdshChevron(
                    expanded = expanded,
                    size = ChatMetrics.DISCLOSURE_CHEVRON_ICON_PT.dp,
                    tint = tokens.colors.tertiary,
                    tag = TURN_PROCESS_CHEVRON_TAG,
                )
            }
        }
        Box(
            Modifier.fillMaxWidth().padding(horizontal = HomeMetrics.contentInset)
                .height(tokens.stroke.hairline).background(tokens.colors.border),
        )
    }
}

/** The disclosure body: one column, one motion, no per-row stagger. */
@Composable
private fun TurnProcessEntries(
    entries: List<ChatRow>,
    expandedRowIds: Set<String>,
    onToggleRow: (String) -> Unit,
    onOpenFile: ((String) -> Unit)?,
    onOpenResource: ((String) -> Unit)?,
    imageSource: com.phonedsh.ui.surface.MarkdownImageSource?,
    onShareText: ((String) -> Unit)?,
) {
    if (entries.isEmpty()) return
    Column(verticalArrangement = Arrangement.spacedBy(HomeMetrics.blockGap)) {
        entries.forEachIndexed { index, entry ->
            val top = if (index == 0) IOS_TURN_CONTROL_GAP else rowGap(entries[index - 1], entry) ?: HomeMetrics.blockGap
            ChatRowItem(
                row = entry,
                expandedRowIds = expandedRowIds,
                onToggleRow = onToggleRow,
                onOpenFile = onOpenFile,
                onOpenResource = onOpenResource,
                imageSource = imageSource,
                onShareText = onShareText,
                modifier = Modifier.padding(top = top),
            )
        }
    }
}

private fun turnProcessLabel(outcome: ChatTurnState, elapsedMillis: Long?): String = when (outcome) {
    ChatTurnState.RUNNING -> "正在处理"
    ChatTurnState.STOPPED -> "已停止"
    ChatTurnState.FAILED -> "处理失败"
    ChatTurnState.COMPLETED -> elapsedMillis?.let { "已完成，用时 ${runDuration(it)}" } ?: "已完成"
}

private fun runDuration(elapsedMillis: Long): String {
    val total = (elapsedMillis.coerceAtLeast(1_000L) / 1_000L).toInt()
    val hours = total / 3600
    val minutes = (total / 60) % 60
    val seconds = total % 60
    return buildString {
        if (hours > 0) append("${hours}小时")
        if (total >= 60) append("${minutes}分")
        append("${seconds}秒")
    }
}

@Composable
private fun TurnTailRow(row: ChatRow.TurnTail, modifier: Modifier = Modifier) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    val clipboard = LocalClipboardManager.current
    val context = LocalContext.current
    var copied by remember(row.turnID) { mutableStateOf(false) }
    LaunchedEffect(copied) {
        if (copied) {
            kotlinx.coroutines.delay(1_000)
            copied = false
        }
    }
    Row(
        modifier = modifier.fillMaxWidth()
            .padding(horizontal = HomeMetrics.contentInset)
            .padding(top = tokens.geometry.toolDetailVertical)
            .offset(x = -ChatMetrics.FLOW_GAP_PT.dp)
            .height(tokens.geometry.composerControlSize)
            .testTag(TURN_TAIL_TAG),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(tokens.spacing.copyGap),
    ) {
        TurnTailAction(glyph = if (copied) "✓" else COPY_GLYPH, label = if (copied) "复制成功" else "复制") {
            clipboard.setText(AnnotatedString(row.assistantText))
            copied = true
        }
        TurnTailAction(glyph = "↗", label = "分享") {
            val intent = Intent(Intent.ACTION_SEND).apply {
                this.type = "text/plain"
                putExtra(Intent.EXTRA_TEXT, row.assistantText)
            }
            context.startActivity(Intent.createChooser(intent, "分享回答"))
        }
        Spacer(Modifier.weight(1f))
        row.timeMillis?.let { millis ->
            BasicText(
                text = chatClock(millis),
                style = type.caption.copy(color = tokens.colors.tertiary),
                maxLines = 1,
            )
        }
    }
}

@Composable
private fun TurnTailAction(glyph: String, label: String, onClick: () -> Unit) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    Box(
        modifier = Modifier.size(tokens.geometry.composerControlSize).clickable(role = Role.Button, onClick = onClick)
            .semantics { contentDescription = label },
        contentAlignment = Alignment.Center,
    ) {
        BasicText(glyph, style = type.secondary.copy(color = tokens.colors.tertiary))
    }
}

private fun chatClock(timeMillis: Long): String {
    val now = java.util.Calendar.getInstance()
    val then = java.util.Calendar.getInstance().apply { timeInMillis = timeMillis }
    val time = java.text.SimpleDateFormat("HH:mm", java.util.Locale.getDefault()).format(java.util.Date(timeMillis))
    return when {
        now.get(java.util.Calendar.YEAR) != then.get(java.util.Calendar.YEAR) ->
            java.text.SimpleDateFormat("yyyy年M月d日 HH:mm", java.util.Locale.getDefault()).format(java.util.Date(timeMillis))
        now.get(java.util.Calendar.DAY_OF_YEAR) != then.get(java.util.Calendar.DAY_OF_YEAR) ->
            java.text.SimpleDateFormat("M月d日 HH:mm", java.util.Locale.getDefault()).format(java.util.Date(timeMillis))
        else -> time
    }
}

/**
 * One tool call/result line (iOS `NativeToolCallRow` over `NativeDisclosureRow`):
 * the tool name, a 2 pt separator dot, the summary, and the detail card when
 * expanded. A row without detail cannot be expanded.
 */
@Composable
private fun ToolEntryRow(
    entry: ToolEntry,
    expanded: Boolean,
    onToggle: () -> Unit,
    onOpenFile: ((String) -> Unit)? = null,
    onOpenResource: ((String) -> Unit)? = null,
    inListCard: Boolean = false,
) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    val canExpand = entry.body.isNotEmpty() || entry.filePath != null || entry.arguments != null
    ToolRow(
        title = entry.displayTitle,
        summary = entry.summary,
        state = entry.state,
        expanded = expanded,
        onToggle = onToggle,
        showsSummaryWhenExpanded = true,
        detail = if (canExpand) {
            {
                ToolDetail(
                    entry = entry,
                    canExpand = canExpand,
                    onOpenFile = onOpenFile,
                    onOpenResource = onOpenResource,
                )
            }
        } else {
            null
        },
        inListCard = inListCard,
        categoryIcon = when (entry.variant) {
            com.phonedsh.ui.state.ToolVariant.BASH -> PdshIcon.TERMINAL
            com.phonedsh.ui.state.ToolVariant.READ -> PdshIcon.DOCUMENT
            com.phonedsh.ui.state.ToolVariant.WRITE, com.phonedsh.ui.state.ToolVariant.EDIT -> PdshIcon.PENCIL
            com.phonedsh.ui.state.ToolVariant.SEARCH -> PdshIcon.SEARCH
            com.phonedsh.ui.state.ToolVariant.WEB_SEARCH, com.phonedsh.ui.state.ToolVariant.WEB_FETCH -> PdshIcon.GLOBE
            com.phonedsh.ui.state.ToolVariant.QUESTION -> PdshIcon.INFO
            com.phonedsh.ui.state.ToolVariant.PLAN -> PdshIcon.LIST
            com.phonedsh.ui.state.ToolVariant.TODO -> PdshIcon.LIST
            com.phonedsh.ui.state.ToolVariant.GENERIC -> PdshIcon.SPARKLE
        },
        modifier = Modifier.testTag(UiPageTags.CHAT_ROW_TOOL),
    )
}

/**
 * The expanded body of a tool entry: the file chip iOS shows for a tool that
 * touched a workspace path (a tappable `Label(path, systemImage:)`), then the
 * banner + monospaced output card.
 *
 * @param entry the tool entry.
 * @param canExpand false when the entry has a path but no output to show.
 * @param onOpenFile the host's router for that path; the page never navigates.
 */
@Composable
private fun ToolDetail(
    entry: ToolEntry,
    canExpand: Boolean,
    onOpenFile: ((String) -> Unit)?,
    onOpenResource: ((String) -> Unit)?,
) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    Column(verticalArrangement = Arrangement.spacedBy(tokens.spacing.iconText)) {
        val path = entry.filePath
        if (path != null) {
            BasicText(
                text = path,
                style = type.caption.copy(color = tokens.colors.accent),
                maxLines = 1,
                // iOS truncates the middle of a path; Compose has no middle mode in
                // this version, so the tail is cut and the leading directories stay.
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier
                    .clickable(enabled = onOpenFile != null, role = Role.Button) { onOpenFile?.invoke(path) }
                    .testTag(UiPageTags.CHAT_ROW_TOOL_FILE)
                    .padding(vertical = tokens.geometry.toolDetailVertical),
            )
        }
        if (canExpand) {
            ToolDetailCard(
                banner = entry.title,
                body = entry.body,
                variant = entry.variant,
                arguments = entry.arguments,
                metadata = entry.metadata,
                isError = entry.state == com.phonedsh.ui.surface.ToolRowState.ERROR,
            )
        }
    }
}

/**
 * A group of injected context blocks (iOS `NativeContextSourceGroup`): one
 * disclosure line with the iOS chevron, then each block with its translated
 * source and a copy action.
 *
 * Rule 1/6 of `interaction.md` §7: the header is outside the animated body, so
 * the tapped line stays put while the blocks expand or collapse with
 * `motion.disclosure`.
 */
@Composable
private fun ContextGroupRow(
    entries: List<ContextEntry>,
    expanded: Boolean,
    onToggle: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    val clipboard = LocalClipboardManager.current
    PdshDisclosure(
        expanded = expanded,
        onToggle = { onToggle() },
        modifier = modifier.padding(start = tokens.geometry.toolDetailIndent),
        tag = CONTEXT_GROUP_DISCLOSURE_TAG,
        anchorKey = entries.firstOrNull()?.text ?: entries.size,
        header = {
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .defaultMinSize(minHeight = tokens.geometry.pageRowMinHeight)
                    .semantics(mergeDescendants = true) {
                        contentDescription = UiStrings.CONTEXT_GROUP
                        stateDescription = if (expanded) UiStrings.EXPANDED else UiStrings.COLLAPSED
                    }
                    .testTag(UiPageTags.CHAT_ROW_CONTEXT),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(tokens.spacing.iconText),
            ) {
                BasicText(
                    text = UiStrings.CONTEXT_GROUP,
                    style = type.secondary.copy(color = tokens.colors.secondary),
                    maxLines = 1,
                )
                BasicText(
                    text = UiStrings.CONTEXT_GROUP_COUNT.format(entries.size),
                    style = type.secondary.copy(color = tokens.colors.secondary),
                    maxLines = 1,
                )
                // iOS prints the source name only for a single block whose name it can
                // translate; anything else stays hidden.
                val single = contextSourceName(entries.singleOrNull()?.source)
                if (single != null) {
                    BasicText(
                        text = single,
                        style = type.secondary.copy(color = tokens.colors.secondary),
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                        // Keep the chevron on screen: the name is the only text
                        // allowed to shrink (iOS puts the spacer after it).
                        modifier = Modifier.weight(1f, fill = false),
                    )
                }
                PdshChevron(
                    expanded = expanded,
                    size = ChatMetrics.CHAT_QUEUE_HEADER_CHEVRON_PT.dp,
                    tint = tokens.colors.secondary,
                    tag = CONTEXT_GROUP_CHEVRON_TAG,
                )
            }
        },
        body = {
            Column(
                modifier = Modifier.padding(start = tokens.geometry.thinkingContentIndent),
                verticalArrangement = Arrangement.spacedBy(tokens.spacing.copyGap),
            ) {
                entries.forEach { entry ->
                    val name = contextSourceName(entry.source)
                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(tokens.spacing.iconText),
                    ) {
                        if (name != null) {
                            BasicText(
                                text = name,
                                style = type.caption.copy(color = tokens.colors.secondary),
                                maxLines = 1,
                            )
                        }
                        Box(modifier = Modifier.weight(1f))
                        BasicText(
                            text = COPY_GLYPH,
                            style = type.caption.copy(color = tokens.colors.secondary),
                            modifier = Modifier
                                .defaultMinSize(
                                    minWidth = tokens.geometry.pageRowMinHeight,
                                    minHeight = tokens.geometry.pageRowMinHeight,
                                )
                                .clickable(
                                    role = Role.Button,
                                    onClick = { clipboard.setText(AnnotatedString(entry.text)) },
                                )
                                .semantics {
                                    contentDescription = name
                                        ?.let { UiStrings.CONTEXT_COPY_NAMED.format(it) }
                                        ?: UiStrings.CONTEXT_COPY
                                }
                                .padding(tokens.spacing.iconText),
                        )
                    }
                    BasicText(
                        text = entry.text,
                        style = type.secondary.copy(color = tokens.colors.secondary),
                    )
                }
            }
        },
    )
}

/**
 * A system event (iOS `NativeSystemEventRow`): a 6 pt dot in the danger or
 * warning ink, a medium title and an optional caption line.
 */
@Composable
private fun SystemEventRow(
    row: ChatRow.SystemEvent,
    modifier: Modifier = Modifier,
) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    val ink = if (row.isError) tokens.colors.danger else tokens.colors.secondary
    Row(
        modifier = modifier
            .semantics(mergeDescendants = true) {}
            .testTag(UiPageTags.CHAT_ROW_SYSTEM),
        verticalAlignment = Alignment.Top,
        horizontalArrangement = Arrangement.spacedBy(tokens.spacing.iconText),
    ) {
        Box(
            modifier = Modifier
                .padding(top = tokens.geometry.toolDetailIndent)
                .size(tokens.geometry.summaryDotDiameter)
                .clip(CircleShape)
                .background(if (row.isError) tokens.colors.danger else tokens.colors.warning),
        )
        Column(
            verticalArrangement = Arrangement.spacedBy(ChatMetrics.SYSTEM_EVENT_TEXT_GAP_PT.dp),
        ) {
            BasicText(
                text = row.title,
                style = type.secondary.copy(color = ink),
                maxLines = 2,
                overflow = TextOverflow.Ellipsis,
            )
            if (row.text.isNotEmpty()) {
                BasicText(
                    text = row.text,
                    style = type.caption.copy(color = ink),
                )
            }
        }
    }
}

/**
 * The message's attachment list (iOS `NativeAttachmentList`): one chip per
 * attachment with its file-type glyph, name and MIME type.
 */
@Composable
private fun AttachmentList(
    attachments: List<com.phonedsh.ui.state.ChatAttachment>,
    modifier: Modifier = Modifier,
    onOpenFile: ((String) -> Unit)? = null,
) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    Column(
        modifier = modifier.fillMaxWidth(),
        verticalArrangement = Arrangement.spacedBy(tokens.spacing.codeToolbar),
    ) {
        attachments.forEach { attachment ->
            val path = attachment.path
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .background(tokens.colors.selector, RoundedCornerShape(tokens.radius.card))
                    // iOS `NativeAttachmentList` disables the row when it has no path.
                    .clickable(enabled = path != null && onOpenFile != null, role = Role.Button) {
                        if (path != null) onOpenFile?.invoke(path)
                    }
                    .padding(tokens.spacing.cardInset),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(tokens.spacing.badgeInsetH),
            ) {
                BasicText(
                    text = if (attachment.image) IMAGE_GLYPH else FILE_GLYPH,
                    style = type.secondary.copy(color = tokens.colors.secondary),
                )
                Column(modifier = Modifier.weight(1f)) {
                    BasicText(
                        text = attachment.name,
                        style = type.secondary.copy(color = tokens.colors.primary),
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                    val mime = attachment.mimeType
                        ?: if (attachment.image) IMAGE_WORD else FILE_WORD
                    BasicText(text = mime, style = type.caption.copy(color = tokens.colors.tertiary))
                }
            }
        }
    }
}

/**
 * Rule 4 of `interaction.md` §3: the page's own chooser, used only while the
 * host supplies no share route ([onShareText] on [ChatRowItem]). A host route
 * must win, so the app owns the system share sheet when it has one.
 */
private fun startTextShare(context: Context, text: String) {
    val intent = Intent(Intent.ACTION_SEND).apply {
        type = "text/plain"
        putExtra(Intent.EXTRA_TEXT, text)
    }
    context.startActivity(Intent.createChooser(intent, SHARE_CHOOSER_TITLE))
}

/** The answer placeholder iOS draws while an answer has no text yet. */
private const val EMPTY_ANSWER: String = "\u2026"
private const val PROCESS_GROUP_TAG: String = "pdsh.chat.process-group"
internal const val TURN_PROCESS_TAG: String = "pdsh.chat.turn-process"

/** `PdshDisclosure`'s header/body tags for the turn-process disclosure. */
internal const val TURN_PROCESS_DISCLOSURE_TAG: String = "pdsh.chat.turn-process.disclosure"
internal const val TURN_PROCESS_CHEVRON_TAG: String = "pdsh.chat.turn-process.chevron"
internal const val CONTEXT_GROUP_DISCLOSURE_TAG: String = "pdsh.chat.row.context.disclosure"
internal const val CONTEXT_GROUP_CHEVRON_TAG: String = "pdsh.chat.row.context.chevron"

/** `interaction.contextMenu.surfaces` ids this page owns (rule 2). */
internal const val USER_BUBBLE_SURFACE: String = "userBubble"
internal const val ASSISTANT_BODY_SURFACE: String = "assistantBody"

private const val TURN_TAIL_TAG: String = "pdsh.chat.turn-tail"

/** The platform chooser's title; only used when the host passes no share route. */
private const val SHARE_CHOOSER_TITLE: String = "分享对话"

private val IOS_PROCESS_GAP: Dp = HomeMetrics.blockGap
private val IOS_RESPONSE_GAP: Dp = HomeMetrics.paragraphGap
private val IOS_TURN_CONTROL_GAP: Dp = HomeMetrics.blockGap

private const val KIND_USER: String = "user"
private const val KIND_ASSISTANT: String = "assistant"
private const val KIND_THINKING: String = "thinking"
private const val KIND_TOOL: String = "tool"
private const val KIND_CONTEXT: String = "context"
private const val KIND_SYSTEM: String = "system"

/** Glyphs: the iOS icon set is an asset catalog, so Android draws text glyphs. */
private const val COPY_GLYPH: String = "⧉"
private const val IMAGE_GLYPH: String = "▣"
private const val FILE_GLYPH: String = "▤"
private const val IMAGE_WORD: String = "图片"
private const val FILE_WORD: String = "文件"
