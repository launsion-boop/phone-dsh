// The chat rows: message bubbles, tool runs, injected context and system events.
// SPDX-License-Identifier: MIT
//
// Spec: `spec/ui/v1/README.md` §2 (component semantics), §3.1 (ScreenState) and
// §4 (the six signature surfaces). A row is one `ScreenState` row; the fold over
// UiState happens in `ChatScreenState`, never here.
//
// Mirror: `examples/probe-app/PhoneDSHProbe/NativeMessageRows.swift` (the
// disclosure row, the thinking row, the system-event row), `ChatPage.swift`
// `ChatMessageRow` / `ToolRunRow` / `ContextInjectionCard` and
// `NativeChatTimelineChrome.swift` `NativeContextSourceGroup`. The per-row gap
// is `ChatPage.spacing(before:in:)`: 6 after a status row, 8 for a tool run or a
// context group, 12 between two rows of the same kind and 20 when the kind
// changes.
//
// Geometry: the row's horizontal inset is the page-level `geometry.pageOuterMarginH`.
// The gaps reuse signature-surface lengths that have no page-level token, and
// each such reuse is marked `unverified geometry` where it is used; no value is
// invented here.
package com.phonedsh.ui.page

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.defaultMinSize
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicText
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import com.phonedsh.ui.UiStrings
import com.phonedsh.ui.UiTags
import com.phonedsh.ui.state.ChatRow
import com.phonedsh.ui.state.ContextEntry
import com.phonedsh.ui.state.ToolEntry
import com.phonedsh.ui.state.contextSourceName
import com.phonedsh.ui.surface.BubbleBadge
import com.phonedsh.ui.surface.BubbleRole
import com.phonedsh.ui.surface.ChatBubble
import com.phonedsh.ui.surface.ThinkingPill
import com.phonedsh.ui.surface.ToolDetailCard
import com.phonedsh.ui.surface.ToolRow
import com.phonedsh.ui.theme.LocalUiTokens
import com.phonedsh.ui.theme.LocalUiType
import com.phonedsh.ui.theme.generated.UiTokenNames

/**
 * The token inventory of the row renderer; `PageTokenReferenceTest` fails if a
 * use site reads a token that is not listed here.
 */
internal object ChatRowsTokens {
    val refs: List<String> = listOf(
        UiTokenNames.COLORS_ACCENT,
        UiTokenNames.COLORS_DANGER,
        UiTokenNames.COLORS_PRIMARY,
        UiTokenNames.COLORS_SECONDARY,
        UiTokenNames.COLORS_SELECTOR,
        UiTokenNames.COLORS_TERTIARY,
        UiTokenNames.COLORS_WARNING,
        UiTokenNames.GEOMETRY_BANNER_GAP,
        UiTokenNames.GEOMETRY_COMPOSER_CONTROL_SIZE,
        UiTokenNames.GEOMETRY_PAGE_OUTER_MARGIN_H,
        UiTokenNames.GEOMETRY_PAGE_ROW_MIN_HEIGHT,
        UiTokenNames.GEOMETRY_STAT_PILL_MIN_HEIGHT,
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
 */
@Composable
internal fun ChatRowList(
    rows: List<ChatRow>,
    expandedRowIds: Set<String>,
    onToggleRow: (String) -> Unit,
    tag: String = UiTags.CHAT_LIST,
    modifier: Modifier = Modifier,
    onOpenFile: (String) -> Unit = {},
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
    val tokens = LocalUiTokens.current
    if (previous == null) return null
    return when {
        // iOS `.toolCall` / `.toolResult`.
        current is ChatRow.ToolRun -> tokens.spacing.codeToolbar
        // iOS `.context`.
        current is ChatRow.Context -> tokens.spacing.codeToolbar
        // iOS' `.systemEvent` / `.turnError` / `.maxTokens` rows take the generic
        // same-kind/other-kind rule below; its own `.status` branch (6 pt) is
        // unreachable there because `.status` rows are never drawn.
        kindOf(previous) == kindOf(current) -> tokens.spacing.cardInset
        // unverified geometry: the composer's 20 pt stat-pill floor reused as the
        // 20 pt gap between two rows of different kinds; tokens.json has no
        // page-level 20 pt spacing token.
        else -> tokens.geometry.statPillMinHeight
    }
}

/** The row kind, as the iOS spacing function compares them. */
private fun kindOf(row: ChatRow): String = when (row) {
    is ChatRow.User -> KIND_USER
    is ChatRow.Assistant -> KIND_ASSISTANT
    is ChatRow.Thinking -> KIND_THINKING
    is ChatRow.ToolRun -> KIND_TOOL
    is ChatRow.Context -> KIND_CONTEXT
    is ChatRow.SystemEvent -> KIND_SYSTEM
}

/**
 * One row, rendered by the surface that owns it (§4).
 *
 * @param row the projected row.
 * @param expandedRowIds the open tool entries and thinking pills.
 * @param onToggleRow the fold action.
 */
@Composable
internal fun ChatRowItem(
    row: ChatRow,
    expandedRowIds: Set<String>,
    onToggleRow: (String) -> Unit,
    modifier: Modifier = Modifier,
    onOpenFile: (String) -> Unit = {},
) {
    val tokens = LocalUiTokens.current
    // Page-level geometry: the chat list uses the page margin, not the composer's.
    val horizontal = tokens.geometry.pageOuterMarginH
    when (row) {
        is ChatRow.User -> Column(
            modifier = modifier
                .fillMaxWidth()
                .padding(horizontal = horizontal),
            verticalArrangement = Arrangement.spacedBy(tokens.spacing.copyGap),
        ) {
            // Two row elements, two edges: the bubble hugs the trailing edge,
            // the queue label hugs the leading edge (iOS `queueLine` sits in a
            // leading VStack under a trailing `userBubble`). The bubble surface
            // never learns that a label exists.
            ChatBubble(
                role = BubbleRole.USER,
                text = row.text,
                modifier = Modifier.align(Alignment.End),
            )
            if (row.attachments.isNotEmpty()) {
                AttachmentList(attachments = row.attachments, onOpenFile = onOpenFile)
            }
            // iOS `userVStack` aligns the action row to the trailing edge.
            MessageActions(text = row.text, modifier = Modifier.align(Alignment.End))
            if (row.badge != null) {
                BubbleBadge(text = row.badge, modifier = Modifier.align(Alignment.Start))
            }
        }

        is ChatRow.Assistant -> Column(
            modifier = modifier
                .fillMaxWidth()
                .padding(horizontal = horizontal),
            verticalArrangement = Arrangement.spacedBy(tokens.spacing.copyGap),
        ) {
            ChatBubble(role = BubbleRole.ASSISTANT, text = row.text)
            // iOS attaches the turn-wide actions to the closing assistant row only.
            if (row.closing) MessageActions(text = row.text)
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
                detail = if (row.summary.isEmpty()) null else row.summary,
            )
        }

        is ChatRow.ToolRun -> Column(
            modifier = modifier
                .fillMaxWidth()
                .padding(horizontal = horizontal),
            // iOS `ToolRunRow`: a VStack of one disclosure line per call/result.
            verticalArrangement = Arrangement.spacedBy(tokens.spacing.iconText),
        ) {
            row.entries.forEach { entry ->
                ToolEntryRow(
                    entry = entry,
                    expanded = entry.id in expandedRowIds,
                    onToggle = { onToggleRow(entry.id) },
                    onOpenFile = onOpenFile,
                )
            }
        }

        is ChatRow.Context -> ContextGroupRow(
            entries = row.entries,
            expanded = row.id in expandedRowIds,
            onToggle = { onToggleRow(row.id) },
            modifier = modifier
                .fillMaxWidth()
                .padding(horizontal = horizontal),
        )

        is ChatRow.SystemEvent -> SystemEventRow(
            row = row,
            modifier = modifier
                .fillMaxWidth()
                .padding(horizontal = horizontal),
        )
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
    onOpenFile: (String) -> Unit = {},
) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    val canExpand = entry.body.isNotEmpty() || entry.banner.isNotEmpty()
    ToolRow(
        title = entry.title,
        summary = entry.summary,
        state = entry.state,
        expanded = expanded,
        onToggle = onToggle,
        detail = if (canExpand || entry.filePath != null) {
            {
                ToolDetail(
                    entry = entry,
                    canExpand = canExpand,
                    onOpenFile = onOpenFile,
                )
            }
        } else {
            null
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
    onOpenFile: (String) -> Unit,
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
                    .clickable(role = Role.Button, onClick = { onOpenFile(path) })
                    .testTag(UiPageTags.CHAT_ROW_TOOL_FILE)
                    .padding(vertical = tokens.geometry.toolDetailVertical),
            )
        }
        if (canExpand) {
            ToolDetailCard(banner = entry.banner.ifEmpty { entry.title }, body = entry.body)
        }
    }
}

/**
 * A group of injected context blocks (iOS `NativeContextSourceGroup`): one
 * disclosure line, then each block with its translated source and a copy action.
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
    Column(modifier = modifier.padding(start = tokens.geometry.toolDetailIndent)) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .defaultMinSize(minHeight = tokens.geometry.pageRowMinHeight)
                .clickable(role = Role.Button, onClick = onToggle)
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
                )
            }
        }
        if (expanded) {
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
        }
    }
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
            verticalArrangement = Arrangement.spacedBy(tokens.geometry.bannerGap),
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
    onOpenFile: (String) -> Unit = {},
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
                    .clickable(enabled = path != null, role = Role.Button) {
                        if (path != null) onOpenFile(path)
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
 * The row's copy action (iOS `NativeMessageActions`). Sharing, feedback and the
 * usage sheet need host services this page does not own, so the copy action is
 * the one the row can perform by itself.
 */
@Composable
private fun MessageActions(
    text: String,
    modifier: Modifier = Modifier,
) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    val clipboard = LocalClipboardManager.current
    if (text.isEmpty()) return
    Row(
        modifier = modifier
            .defaultMinSize(minHeight = tokens.geometry.composerControlSize)
            .testTag(UiPageTags.CHAT_MESSAGE_COPY)
            .clickable(role = Role.Button, onClick = { clipboard.setText(AnnotatedString(text)) })
            .semantics { contentDescription = UiStrings.MESSAGE_COPY }
            .padding(horizontal = tokens.spacing.copyGap),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        BasicText(
            text = COPY_GLYPH,
            style = type.secondary.copy(color = tokens.colors.tertiary),
        )
    }
}

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
