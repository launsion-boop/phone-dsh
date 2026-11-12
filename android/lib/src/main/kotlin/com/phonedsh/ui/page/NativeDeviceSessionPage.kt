// 设备会话: a fixed session watched read-only, with history paging and a live tail.
// SPDX-License-Identifier: MIT
//
// The Android page of `NativeDeviceSessionPage.swift` (442 lines). The two pieces of
// logic that page exists for are both here, and neither is decorative:
//
//  1. **History paging** — `session/page` is a window. The page offers 读取更早消息
//     while the device says `hasMore`, asks with `beforeSeq`, and stops with the
//     reason on screen when the answer does not move the cursor
//     (`UiStrings.DEVICE_SESSION_NO_PROGRESS`). The window arithmetic is
//     `DeviceSessionHistory` in `:domain`; the button only forwards the gesture.
//  2. **live/durable merge** — `state.rows` is `durable + live`, exactly the iOS
//     model's `items`. The durable half is re-read only when a page arrives; the
//     live half grows delta by delta and never migrates into the durable half.
//     Both are computed by `DeviceSessionSource`, so this file renders and decides
//     nothing about ordering.
//
// **Read-only is structural.** The page takes no composer, no send and no approve
// callback, because the transport it was built from (`ReadOnlyDeviceSessionTransport`)
// has no write to call. The bottom bar says so in the baseline's own words:
// 「只读监视，请在设备上处理输入与确认」.
//
// Geometry: page margin, row floors, bubble padding/radius and the terminal card's
// ceiling all come from `spec/ui/v1/tokens.json`. The fold markers reuse the shared
// disclosure gap, which is declared for a signature surface, so the two reuses carry
// an `unverified geometry` note. No value is invented.
package com.phonedsh.ui.page

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.defaultMinSize
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicText
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.rememberScrollState
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.phonedsh.domain.connector.DeviceAttachment
import com.phonedsh.domain.connector.DeviceItemKind
import com.phonedsh.domain.connector.DeviceSessionFailure
import com.phonedsh.domain.connector.DeviceSessionSnapshot
import com.phonedsh.domain.connector.DeviceToolState
import com.phonedsh.domain.connector.DeviceTranscriptItem
import com.phonedsh.domain.connector.DeviceTranscriptProjector
import com.phonedsh.ui.ChatMetrics
import com.phonedsh.ui.HomeMetrics
import com.phonedsh.ui.UiMetrics
import com.phonedsh.ui.UiStrings
import com.phonedsh.ui.disclosure.PdshChevron
import com.phonedsh.ui.disclosure.PdshDisclosure
import com.phonedsh.ui.theme.LocalUiTokens
import com.phonedsh.ui.theme.LocalUiType
import com.phonedsh.ui.surface.MarkdownBody

/** The session page's local UI state: which foldable rows the user opened. */
public data class DeviceSessionLocalState(
    public val expandedRowIds: Set<String> = emptySet(),
) {
    /** Flips one foldable row; the only local event this page owns. */
    public fun toggle(rowId: String): DeviceSessionLocalState = copy(
        expandedRowIds = if (rowId in expandedRowIds) expandedRowIds - rowId else expandedRowIds + rowId,
    )
}

/**
 * The session page state.
 *
 * @param title the device's display name (the baseline's navigation title).
 * @param sessionBadge the first eight characters of the session id, as the baseline
 *   prints them in the top strip.
 * @param rows the transcript: durable rows, then live rows.
 * @param loading the first read has not answered yet.
 * @param empty the read succeeded and the session has no row at all.
 */
public data class DeviceSessionScreenState(
    public val title: String,
    public val sessionBadge: String,
    public val failure: String?,
    public val rows: List<DeviceTranscriptItem>,
    public val loading: Boolean,
    public val empty: Boolean,
    public val hasMore: Boolean,
    public val loadingEarlier: Boolean,
    public val expandedRowIds: Set<String>,
) {
    public companion object {
        /**
         * Projects the monitor's snapshot into the page state.
         *
         * Pure: the same snapshot and fold script always render the same rows in the
         * same order, so a JVM replay asserts the paging and the merge without a
         * device or a coroutine.
         */
        public fun from(
            snapshot: DeviceSessionSnapshot,
            local: DeviceSessionLocalState = DeviceSessionLocalState(),
        ): DeviceSessionScreenState = DeviceSessionScreenState(
            title = snapshot.displayName,
            sessionBadge = snapshot.sessionId.take(SESSION_BADGE_LENGTH),
            failure = failureLine(snapshot.failure),
            rows = snapshot.items,
            loading = snapshot.waiting,
            empty = snapshot.empty,
            hasMore = snapshot.hasMore,
            loadingEarlier = snapshot.loadingEarlier,
            expandedRowIds = local.expandedRowIds,
        )

        private fun failureLine(failure: DeviceSessionFailure?): String? = when (failure) {
            is DeviceSessionFailure.Read -> UiStrings.DEVICE_SESSION_READ_FAILED.format(failure.detail)
            is DeviceSessionFailure.Stalled ->
                UiStrings.DEVICE_SESSION_NO_PROGRESS.format(failure.beforeSeq)

            null -> null
        }

        /** The baseline prints `sessionID.prefix(8)`; the strip is not a full id. */
        public const val SESSION_BADGE_LENGTH: Int = 8
    }
}

/**
 * The device session page.
 *
 * @param state the pure screen state ([DeviceSessionScreenState.from]).
 * @param onLoadEarlier read one older history window.
 * @param onToggleRow open/close one foldable transcript row.
 * @param onBack leave the page (stops monitoring in the route).
 */
@Composable
public fun NativeDeviceSessionPage(
    state: DeviceSessionScreenState,
    onLoadEarlier: () -> Unit,
    onToggleRow: (String) -> Unit,
    onBack: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    PageFrame(
        title = state.title,
        onBack = onBack,
        rootTag = UiPageTags.DEVICE_SESSION_ROOT,
        modifier = modifier,
    ) {
        Column(modifier = Modifier.fillMaxSize()) {
            // The baseline's 36pt strip: the read-only banner above the transcript.
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .testTag(UiPageTags.DEVICE_SESSION_STRIP)
                    .height(DEVICE_SESSION_STRIP_HEIGHT_DP.dp)
                    .padding(horizontal = HomeMetrics.contentInset)
                    .semantics(mergeDescendants = true) {},
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(DEVICE_SESSION_LABEL_GAP_DP.dp),
            ) {
                BasicText(
                    text = UiStrings.DEVICE_SESSION_TITLE,
                    style = type.listItem.copy(color = tokens.colors.textSecondary),
                    modifier = Modifier.weight(1f),
                )
                BasicText(
                    text = state.sessionBadge,
                    style = type.codeLabel.copy(color = tokens.colors.textTertiary),
                )
            }

            if (state.failure != null) {
                DeviceSessionFailureLine(state.failure)
            }

            Box(modifier = Modifier.weight(1f).fillMaxWidth()) {
                DeviceTranscript(state = state, onLoadEarlier = onLoadEarlier, onToggleRow = onToggleRow)
            }

            SessionHairline()
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .testTag(UiPageTags.DEVICE_SESSION_READ_ONLY)
                    .padding(horizontal = HomeMetrics.contentInset, vertical = READ_ONLY_BAR_INSET_DP.dp)
                    .semantics(mergeDescendants = true) {},
                verticalAlignment = Alignment.CenterVertically,
            ) {
                BasicText(
                    text = UiStrings.DEVICE_SESSION_READ_ONLY,
                    style = type.listItem.copy(color = tokens.colors.textSecondary),
                )
            }
        }
    }
}

/** The transcript body: the paging action, the empty/loading states and the rows. */
@Composable
private fun DeviceTranscript(
    state: DeviceSessionScreenState,
    onLoadEarlier: () -> Unit,
    onToggleRow: (String) -> Unit,
) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    // The shared 402 pt metric: the transcript is the official 338 pt content
    // column, centred in the frame, and its rows are spaced at the official 6/12
    // flow gaps. The column width comes from `UiMetrics` and the flow gap from
    // `ChatMetrics` (their single definitions), not from this file; a narrower
    // display shrinks the column instead of clipping it.
    Box(modifier = Modifier.fillMaxSize(), contentAlignment = Alignment.TopCenter) {
        LazyColumn(
            modifier = Modifier
                .widthIn(max = UiMetrics.contentColumnWidth)
                .fillMaxSize()
                .testTag(UiPageTags.DEVICE_SESSION_LIST),
            verticalArrangement = Arrangement.spacedBy(ChatMetrics.flowGap),
            // The baseline anchors this scroll view to its bottom
            // (`.defaultScrollAnchor(.bottom)`): a monitor should open on what the
            // device just did, not on the oldest window it happens to hold. A
            // reversed layout puts the newest row at the bottom of the frame with no
            // scroll effect, so a capture and a first frame agree.
            reverseLayout = true,
            contentPadding = PaddingValues(
                top = UiMetrics.flowGapResponse,
                bottom = tokens.spacing.iconText,
            ),
        ) {
        if (state.loading) {
            item(key = "loading") {
                Row(
                    modifier = Modifier.fillMaxWidth().testTag(UiPageTags.DEVICE_SESSION_EMPTY)
                        .padding(top = DEVICE_SESSION_EMPTY_TOP_DP.dp),
                    horizontalArrangement = Arrangement.Center,
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    CircularProgressIndicator(
                        modifier = Modifier.size(DEVICE_SESSION_LOADING_MARK_SIZE_DP.dp),
                        strokeWidth = DEVICE_SESSION_LOADING_MARK_STROKE_DP.dp,
                    )
                    BasicText(
                        text = UiStrings.DEVICE_SESSION_LOADING,
                        style = type.listItem.copy(color = tokens.colors.textSecondary),
                        modifier = Modifier.padding(start = tokens.spacing.iconText),
                    )
                }
            }
        } else if (state.empty && state.failure == null) {
            item(key = "empty") {
                DeviceSessionHint(
                    title = UiStrings.DEVICE_SESSION_EMPTY,
                    hint = UiStrings.DEVICE_SESSION_EMPTY_HINT,
                    tag = UiPageTags.DEVICE_SESSION_EMPTY,
                    modifier = Modifier.padding(top = DEVICE_SESSION_EMPTY_TOP_DP.dp),
                )
            }
        }

        items(items = state.rows.asReversed(), key = { it.id }) { item ->
            Column(modifier = Modifier.fillMaxWidth().testTag(UiPageTags.DEVICE_SESSION_ROW)) {
                DeviceReadOnlyRow(
                    item = item,
                    expanded = item.id in state.expandedRowIds,
                    onToggle = { onToggleRow(item.id) },
                )
            }
        }
        // In a reversed layout the last index is the top of the frame, which is where
        // the paging action belongs: above the oldest row on screen.
        if (state.hasMore) {
            item(key = "earlier") {
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .testTag(UiPageTags.DEVICE_SESSION_READ_EARLIER)
                        .clickable(
                            enabled = !state.loadingEarlier,
                            role = Role.Button,
                            onClick = onLoadEarlier,
                        )
                        .defaultMinSize(minHeight = HomeMetrics.defaultMinListRowHeight)
                            .clip(RoundedCornerShape(tokens.radius.card))
                            .background(tokens.colors.surface)
                            .border(tokens.stroke.hairline, tokens.colors.borderList, RoundedCornerShape(tokens.radius.card))
                            .padding(horizontal = tokens.spacing.cardInset, vertical = tokens.spacing.iconText),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(tokens.spacing.iconText),
                ) {
                    // The house shape for a two-state action label is ChatPage's
                    // load-earlier row: one `BasicText` per state, each written out,
                    // never a ternary over `text`. The in-flight placeholder is its
                    // own label (`NativeDeviceSessionPage.swift:400`), and keeping it
                    // a literal `UiStrings` constant is also what lets the structure
                    // checker see this control at all — a ternary resolved to nothing,
                    // so the row read as absent.
                    if (state.loadingEarlier) {
                        BasicText(
                            text = UiStrings.DEVICE_SESSION_READING_EARLIER,
                            style = type.listItem.copy(color = tokens.colors.textTertiary),
                        )
                    } else {
                        BasicText(
                            text = UiStrings.DEVICE_SESSION_READ_EARLIER,
                            style = type.listItem.copy(color = tokens.colors.pageAccent),
                        )
                    }
                }
                SessionHairline()
            }
        }

        }
    }
}

/**
 * One transcript row, rendered by kind.
 *
 * The renderer split is the baseline's: a bubble for the two participants, plain
 * prose for the assistant, a fold for reasoning and tools, an information line for
 * a system or failed turn.
 */
@Composable
private fun DeviceReadOnlyRow(
    item: DeviceTranscriptItem,
    expanded: Boolean,
    onToggle: () -> Unit,
) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    when (item.kind) {
        DeviceItemKind.USER, DeviceItemKind.DEVICE -> ParticipantBubble(item)

        DeviceItemKind.ASSISTANT -> MarkdownBody(
            markdown = if (item.text.isEmpty() && item.streaming) {
                DeviceTranscriptProjector.PLACEHOLDER
            } else {
                item.text
            },
            modifier = Modifier.fillMaxWidth().padding(vertical = tokens.spacing.badgeInsetV),
        )

        DeviceItemKind.REASONING -> FoldableRow(
            title = item.title.ifEmpty { UiStrings.DEVICE_REASONING_LABEL },
            trailing = if (item.streaming) STREAMING_GLYPH else null,
            expanded = expanded,
            onToggle = onToggle,
            tag = foldTag(item.id),
            body = {
                BasicText(
                    text = item.text.ifEmpty { DeviceTranscriptProjector.PLACEHOLDER },
                    style = type.listItem.copy(color = tokens.colors.textSecondary),
                )
            },
        )

        DeviceItemKind.TOOL_CALL, DeviceItemKind.TOOL_RESULT -> ToolRow(
            item = item,
            expanded = expanded,
            onToggle = onToggle,
        )

        DeviceItemKind.IMAGE -> AttachmentLabels(item.attachments)

        DeviceItemKind.SYSTEM_EVENT, DeviceItemKind.MAX_TOKENS, DeviceItemKind.UNKNOWN ->
            InformationRow(
                text = if (item.title.isEmpty() || item.text.isEmpty()) {
                    item.text.ifEmpty { item.title }
                } else {
                    "${item.title}：${item.text}"
                },
                tone = InformationTone.SECONDARY,
            )

        DeviceItemKind.TURN_ERROR -> InformationRow(
            text = if (item.text.isEmpty()) item.title else item.text,
            tone = InformationTone.DANGER,
        )

        DeviceItemKind.CONTEXT -> Column(
            modifier = Modifier.fillMaxWidth().padding(vertical = tokens.spacing.badgeInsetV),
            verticalArrangement = Arrangement.spacedBy(tokens.spacing.badgeInsetV),
        ) {
            BasicText(
                text = item.title.ifEmpty { UiStrings.DEVICE_CONTEXT_LABEL },
                style = type.listItem.copy(color = tokens.colors.textTertiary),
            )
            BasicText(text = item.text, style = type.listItem.copy(color = tokens.colors.textSecondary))
        }
    }
}

/** The phone user's and the device's bubble: the two participants never collapse. */
@Composable
private fun ParticipantBubble(item: DeviceTranscriptItem) {
    val tokens = LocalUiTokens.current
    val fromDevice = item.kind == DeviceItemKind.DEVICE
    Row(
        modifier = Modifier.fillMaxWidth().padding(vertical = tokens.spacing.badgeInsetV),
        horizontalArrangement = Arrangement.Start,
    ) {
        // The baseline's `Spacer(minLength: 24)`: the other side of the row is empty,
        // so the two participants are told apart by side as well as by label.
        if (!fromDevice) Box(modifier = Modifier.weight(1f))
        Bubble(item = item, fromDevice = fromDevice)
        if (fromDevice) Box(modifier = Modifier.weight(1f))
    }
}

/** The bubble's own body; a device bubble carries its label above the text. */
@Composable
private fun Bubble(item: DeviceTranscriptItem, fromDevice: Boolean) {
    val tokens = LocalUiTokens.current
    val style = LocalUiType.current
    Column(
        modifier = Modifier
            .clip(RoundedCornerShape(tokens.radius.bubble))
            .background(tokens.colors.textSecondary.copy(alpha = BUBBLE_TINT_ALPHA))
            .padding(
                horizontal = tokens.geometry.bubblePaddingH,
                vertical = tokens.geometry.bubblePaddingV,
            )
            .semantics(mergeDescendants = true) {},
        verticalArrangement = Arrangement.spacedBy(tokens.spacing.badgeInsetV),
    ) {
        if (fromDevice) {
            BasicText(
                text = item.title.ifEmpty { UiStrings.DEVICE_DEVICE_LABEL },
                style = style.caption.copy(color = tokens.colors.textTertiary),
                modifier = Modifier.semantics { heading() },
            )
        }
        if (item.text.isNotEmpty()) {
            SelectionContainer {
                BasicText(text = item.text, style = style.body.copy(color = tokens.colors.textPrimary))
            }
        }
        AttachmentLabels(item.attachments)
    }
}

/** Attachment labels: a name and whether it is a picture. */
@Composable
private fun AttachmentLabels(attachments: List<DeviceAttachment>) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    attachments.forEach { attachment ->
        BasicText(
            text = (if (attachment.isImage) UiStrings.DEVICE_IMAGE else UiStrings.DEVICE_FILE) +
                "：" + attachment.name,
            style = type.listItem.copy(color = tokens.colors.textTertiary),
        )
    }
}

/**
 * A foldable row: 思考 and the tool rows both use it.
 *
 * The iOS source is a SwiftUI `DisclosureGroup` for both row kinds
 * (`NativeDeviceSessionRows.swift:38` for 思考, `:104` for a tool call/result), so
 * it is a real disclosure. `interaction.md` §7 rule 1 assigns its body
 * `motion.disclosure` and rule 3 assigns its chevron `motion.chevron`; the
 * shared [PdshDisclosure] / [PdshChevron] own both, including the reduced-motion
 * snap. iOS names no duration of its own, so the contract token is the value.
 */
@Composable
private fun FoldableRow(
    title: String,
    trailing: String?,
    expanded: Boolean,
    onToggle: () -> Unit,
    modifier: Modifier = Modifier,
    tag: String? = null,
    tone: InformationTone = InformationTone.SECONDARY,
    body: @Composable () -> Unit,
) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    PdshDisclosure(
        expanded = expanded,
        onToggle = { onToggle() },
        modifier = modifier.fillMaxWidth().padding(vertical = tokens.spacing.badgeInsetV),
        tag = tag,
        header = {
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .defaultMinSize(minHeight = HomeMetrics.defaultMinListRowHeight)
                    .semantics(mergeDescendants = true) { contentDescription = title },
                verticalAlignment = Alignment.CenterVertically,
                // unverified geometry: the disclosure icon gap is declared for a
                // signature surface and reused here as the fold marker's gap.
                horizontalArrangement = Arrangement.spacedBy(tokens.geometry.disclosureIconGap),
            ) {
                PdshChevron(
                    expanded = expanded,
                    tint = tokens.colors.textTertiary,
                )
                BasicText(
                    text = title,
                    style = type.listItem.copy(color = tone.ink(tokens)),
                    modifier = Modifier.weight(1f),
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
                if (trailing != null) {
                    BasicText(
                        text = trailing,
                        style = type.listItem.copy(color = tone.ink(tokens)),
                    )
                }
            }
        },
        body = {
            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    // unverified geometry: the thinking block's content indent is a
                    // signature-surface token; it is the declared indent for prose
                    // below a disclosure and the page level has none.
                    .padding(start = tokens.geometry.thinkingContentIndent, top = tokens.spacing.iconText),
            ) {
                body()
            }
        },
    )
}

/** The stable tag of one fold row's header/body pair; the row keeps its page tag. */
private fun foldTag(rowId: String): String = "${UiPageTags.DEVICE_SESSION_ROW}.$rowId"

/** A tool call or tool result: its name, its state, and its input/output on demand. */
@Composable
private fun ToolRow(
    item: DeviceTranscriptItem,
    expanded: Boolean,
    onToggle: () -> Unit,
) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    val state = item.toolState ?: DeviceToolState.RUNNING
    val status = when (state) {
        DeviceToolState.RUNNING -> UiStrings.DEVICE_TOOL_RUNNING
        DeviceToolState.OK -> UiStrings.DEVICE_TOOL_DONE
        DeviceToolState.ERROR -> UiStrings.DEVICE_TOOL_FAILED
        DeviceToolState.STOPPED -> UiStrings.DEVICE_TOOL_STOPPED
    }
    FoldableRow(
        title = item.toolName ?: item.title,
        trailing = status,
        expanded = expanded,
        onToggle = onToggle,
        tag = foldTag(item.id),
        tone = if (state == DeviceToolState.ERROR) InformationTone.DANGER else InformationTone.SECONDARY,
    ) {
        val arguments = item.argumentsJson
        if (!arguments.isNullOrEmpty()) {
            DeviceMonospaceCard(
                title = UiStrings.DEVICE_TOOL_INPUT,
                text = arguments,
                isError = false,
            )
        }
        val output = item.outputText
        if (!output.isNullOrEmpty()) {
            DeviceMonospaceCard(
                title = UiStrings.DEVICE_TOOL_OUTPUT,
                text = output,
                isError = state == DeviceToolState.ERROR,
            )
        } else if (state == DeviceToolState.RUNNING) {
            BasicText(
                text = UiStrings.DEVICE_TOOL_WAITING,
                style = type.listItem.copy(color = tokens.colors.textTertiary),
            )
        }
    }
}

/** One monospaced block (a tool's input or output) under a caption. */
@Composable
private fun DeviceMonospaceCard(title: String, text: String, isError: Boolean) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(tokens.radius.card))
            .background(tokens.colors.textSecondary.copy(alpha = CARD_TINT_ALPHA))
            .padding(tokens.spacing.badgeInsetH)
            .semantics(mergeDescendants = true) {},
        verticalArrangement = Arrangement.spacedBy(tokens.spacing.copyGap),
    ) {
        BasicText(
            text = title,
            style = type.listItem.copy(color = tokens.colors.textSecondary),
            modifier = Modifier.semantics { heading() },
        )
            SelectionContainer {
                Box(
                    modifier = Modifier
                        .fillMaxWidth()
                        .heightIn(max = tokens.geometry.terminalCardMaxHeight)
                        .verticalScroll(rememberScrollState()),
                ) {
                    BasicText(
                        text = text,
                        style = type.code.copy(
                            color = if (isError) tokens.colors.pageDanger else tokens.colors.textPrimary,
                        ),
                    )
                }
            }
    }
}

/** One information line: a system event, a truncated turn or a model failure. */
@Composable
private fun InformationRow(text: String, tone: InformationTone) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    BasicText(
        text = text,
        style = type.listItem.copy(color = tone.ink(tokens)),
        modifier = Modifier.fillMaxWidth().padding(vertical = tokens.spacing.iconText),
    )
}

/** The failure line above the transcript; the baseline inks it with `danger`. */
@Composable
private fun DeviceSessionFailureLine(message: String) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    Box(
        modifier = Modifier
            .fillMaxWidth()
            .testTag(UiPageTags.DEVICE_SESSION_FAILURE)
            .background(tokens.colors.pageDanger.copy(alpha = FAILURE_TINT_ALPHA))
            .padding(tokens.spacing.cardInset)
            // Fail-loud is audible too: an assertive live region interrupts.
            .semantics { liveRegion = LiveRegionMode.Assertive },
    ) {
        BasicText(text = message, style = type.listItem.copy(color = tokens.colors.pageDanger))
    }
}

/** A centred waiting/empty hint inside the transcript. */
@Composable
private fun DeviceSessionHint(title: String, hint: String?, tag: String, modifier: Modifier = Modifier) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    Column(
        modifier = modifier
            .fillMaxWidth()
            .testTag(tag)
            .padding(vertical = tokens.geometry.cardOuterMarginV)
            .semantics(mergeDescendants = true) {
                contentDescription = listOfNotNull(title, hint).joinToString(". ")
            },
        verticalArrangement = Arrangement.spacedBy(tokens.spacing.iconText),
    ) {
        BasicText(text = title, style = type.body.copy(color = tokens.colors.textTertiary))
        if (hint != null) {
            BasicText(text = hint, style = type.listItem.copy(color = tokens.colors.textTertiary))
        }
    }
}

/** The two inks an information line can use; both are tokens. */
private enum class InformationTone {
    SECONDARY,
    DANGER,
    ;

    fun ink(tokens: com.phonedsh.ui.theme.UiTokens): androidx.compose.ui.graphics.Color = when (this) {
        SECONDARY -> tokens.colors.textSecondary
        DANGER -> tokens.colors.pageDanger
    }
}

/**
 * The token inventory of this page; `DeviceConnectorPagesTokenTest` fails when a use
 * site reads a token that is not listed here.
 */
internal object NativeDeviceSessionPageTokens {
    val refs: List<String> = listOf(
        "colors.textPrimary",
        "colors.textSecondary",
        "colors.textTertiary",
        "colors.borderList",
        "colors.pageAccent",
        "colors.pageDanger",
        "colors.surface",
        "typography.body",
        "typography.listItem",
        "typography.code",
        "typography.codeLabel",
        "radius.bubble",
        "radius.card",
        "spacing.iconText",
        "spacing.badgeInsetV",
        "spacing.badgeInsetH",
        "spacing.copyGap",
        "spacing.cardInset",
        "stroke.hairline",
        "geometry.bubblePaddingH",
        "geometry.bubblePaddingV",
        "geometry.cardOuterMarginV",
        "geometry.disclosureIconGap",
        "geometry.thinkingContentIndent",
        "geometry.terminalCardMaxHeight",
    )
}

/** The still-streaming marker. */
private const val STREAMING_GLYPH: String = "…"

/**
 * The two tints the baseline declares as an opacity over the secondary ink
 * (`0.09` for a bubble, `0.06` for a tool card) and `0.06` for the failure line.
 * They are opacities, not colours: the ink itself is still the token.
 */
private const val BUBBLE_TINT_ALPHA: Float = 0.09f
private const val CARD_TINT_ALPHA: Float = 0.06f
private const val FAILURE_TINT_ALPHA: Float = 0.06f
private const val DEVICE_SESSION_STRIP_HEIGHT_DP: Float = 36f
private const val DEVICE_SESSION_LABEL_GAP_DP: Float = 7f
private const val READ_ONLY_BAR_INSET_DP: Float = 10f
private const val DEVICE_SESSION_EMPTY_TOP_DP: Float = 60f
// The platform loading glyph is a compact implementation mark rather than an
// iOS parity measurement; keeping its dimensions named avoids inline geometry.
private const val DEVICE_SESSION_LOADING_MARK_SIZE_DP: Float = 16f
private const val DEVICE_SESSION_LOADING_MARK_STROKE_DP: Float = 2f
