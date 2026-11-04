// The markdown code card of an answer: language strip, wrap/copy actions, monospaced body.
// SPDX-License-Identifier: MIT
//
// Mirror: `ios-code-block.png` (the component swatch) and the code card inside
// `ios-chat-assistant.png`. The iOS page renders an answer's fenced blocks with
// `DSSCodeBlock` (`NativeMarkdownBody.swift:100-102`); this card is its Android
// counterpart and is reached from `MarkdownBody`'s `.code` block.
//
// Measured baseline (`Components.swift:151-225`, `ios-code-block.png`):
//
//   chrome        one card, radius 12, 0.5 pt border, 2 pt vertical outer inset
//   header strip  34 pt tall, fill `#F5F6F7`, language + wrap toggle + copy
//   copy          min 44 x 28, 13 pt glyph, 11 pt text, `已复制` for 1 s
//   body          fill `#F9FAFB`, mono 13 pt, 5 pt line spacing (20.7 pt pitch)
//   long block    > 24 lines or > 2400 chars: max 300 pt, `展开全部 N 行` tail
//
// Theme values come from `spec/ui/v1/tokens.json`; the source font and collapse cap
// remain owner-specific ChatMetrics with Components/NativeCodeHighlighter provenance.
package com.phonedsh.ui.surface

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.defaultMinSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicText
import androidx.compose.foundation.verticalScroll
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.phonedsh.ui.UiStrings
import com.phonedsh.ui.ChatMetrics
import com.phonedsh.ui.icon.PdshIcon
import com.phonedsh.ui.icon.PdshIconView
import com.phonedsh.ui.theme.LocalUiTokens
import com.phonedsh.ui.theme.LocalUiType
import kotlinx.coroutines.delay

/**
 * One fenced code block of an assistant answer.
 *
 * @param language the fence's info string (`swift`); empty hides the label.
 * @param body the block's text, drawn verbatim (never re-wrapped by this card).
 * @param modifier the row's placement.
 */
@Composable
public fun CodeBlock(
    language: String,
    body: String,
    modifier: Modifier = Modifier,
) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    val clipboard = LocalClipboardManager.current
    val shape = RoundedCornerShape(tokens.radius.codeBlock)
    // The header sits flush on the card: only its top corners are rounded.
    val headerShape = RoundedCornerShape(
        topStart = tokens.radius.codeBlock,
        topEnd = tokens.radius.codeBlock,
    )
    var wrapped by remember { mutableStateOf(true) }
    var copied by remember { mutableStateOf(false) }
    var expanded by remember { mutableStateOf(false) }
    val lineCount = remember(body) { body.split("\n").size }
    val isLong = lineCount > LONG_LINE_COUNT || body.length > LONG_CHAR_COUNT

    // `Components.swift:180-183`: 已复制 holds for one second, then reverts.
    LaunchedEffect(copied) {
        if (copied) {
            delay(tokens.motion.copyConfirmHoldMs.toLong())
            copied = false
        }
    }

    Column(
        modifier = modifier
            .fillMaxWidth()
            // `Components.swift:224`: the card is inset 2 pt above/below its row.
            .padding(vertical = tokens.spacing.codeBlockOuterInsetV)
            .testTag(CODE_BLOCK_TAG)
            .background(tokens.colors.code, shape)
            .border(width = tokens.stroke.hairline, color = tokens.colors.border, shape = shape),
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .height(tokens.spacing.codeHeaderHeight)
                .background(tokens.colors.codeBanner, headerShape)
                .padding(horizontal = ChatMetrics.CODE_BLOCK_HEADER_INSET_H_PT.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(ChatMetrics.CODE_BLOCK_HEADER_GAP_PT.dp),
        ) {
            BasicText(
                text = language,
                style = type.codeAction.copy(color = tokens.colors.secondary),
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier.weight(1f, fill = false),
            )
            Box(modifier = Modifier.weight(1f))
            // `Components.swift:171-176`: text.alignleft / arrow.left.and.right,
            // 28 x 28, plain style.
            Box(
                modifier = Modifier
                    .size(ChatMetrics.CODE_BLOCK_CONTROL_SIZE_PT.dp)
                    .clickable(role = Role.Button) { wrapped = !wrapped }
                    .semantics {
                        contentDescription = if (wrapped) {
                            UiStrings.CODE_WRAP_OFF
                        } else {
                            UiStrings.CODE_WRAP_ON
                        }
                    }
                    .testTag(CODE_WRAP_TAG),
                contentAlignment = Alignment.Center,
            ) {
                PdshIconView(
                    icon = if (wrapped) PdshIcon.TEXT_ALIGN_LEFT else PdshIcon.ARROW_LEFT_RIGHT,
                    size = ChatMetrics.CODE_BLOCK_WRAP_ICON_SIZE_PT.dp,
                    tint = tokens.colors.secondary,
                    contentDescription = null,
                    modifier = Modifier.testTag(CODE_WRAP_ICON_TAG),
                )
            }
            // `Components.swift:177-192`: icon 13 + 11 pt label, min 44 x 28.
            Row(
                modifier = Modifier
                    .defaultMinSize(
                        minWidth = tokens.spacing.codeCopyMinWidth,
                        minHeight = tokens.spacing.codeWrapButton,
                    )
                    .clickable(role = Role.Button) {
                        clipboard.setText(AnnotatedString(body))
                        copied = true
                    }
                    .semantics {
                        contentDescription = if (copied) {
                            UiStrings.MESSAGE_COPIED
                        } else {
                            UiStrings.CODE_COPY_ACTION
                        }
                    }
                    .testTag(CODE_COPY_TAG),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(
                    tokens.spacing.copyGap,
                    Alignment.CenterHorizontally,
                ),
            ) {
                PdshIconView(
                    icon = if (copied) PdshIcon.CHECK else PdshIcon.COPY,
                    size = ChatMetrics.CODE_BLOCK_COPY_ICON_SIZE_PT.dp,
                    tint = tokens.colors.secondary,
                    contentDescription = null,
                )
                BasicText(
                    text = if (copied) UiStrings.MESSAGE_COPIED else UiStrings.MESSAGE_COPY,
                    style = type.codeAction.copy(color = tokens.colors.secondary),
                )
            }
        }
        // iOS paints the block with `NativeCodeHighlighter` and a
        // `.secondary` base ink (NativeCodeHighlighter.swift:19-27); the four
        // token classes are the theme's success / caption / warning / accent.
        // A block with no recognised token therefore changes ink from primary
        // to secondary, which is what the baseline shows.
        val highlighted = remember(body, tokens.dark) {
            highlightCode(
                body,
                CodeInks(
                    string = tokens.colors.success,
                    comment = tokens.colors.caption,
                    number = tokens.colors.warning,
                    keyword = tokens.colors.accent,
                ),
            )
        }
        // `NativeCodeHighlighter.swift:18` sets this surface to 13pt mono even
        // though the user code-preference role defaults to 14pt. Components.swift:201
        // adds 5pt; the iOS capture measures a 20-21pt pitch.
        val codeStyle = type.code.copy(
            fontSize = ChatMetrics.CODE_BLOCK_SOURCE_FONT_SIZE_PT.sp,
            lineHeight = (type.subheadline.fontSize.value + tokens.spacing.codeLineSpacing.value).sp,
            color = tokens.colors.secondary,
        )
        val verticalScroll = rememberScrollState()
        val horizontalScroll = rememberScrollState()
        val collapsible = isLong && !expanded
        Box(
            modifier = Modifier
                .fillMaxWidth()
                // `Components.swift:207`: the code block owns a separate 300 pt cap;
                // it is not the 224 pt cap on a terminal output card.
                .then(
                    if (collapsible) {
                        Modifier.heightIn(max = ChatMetrics.CODE_BLOCK_COLLAPSED_MAX_HEIGHT_PT.dp)
                    } else {
                        Modifier
                    },
                )
                // The transcript LazyColumn owns vertical movement for short and
                // expanded blocks. A nested vertical scroller in an unbounded list
                // item asks for infinite height and crashes during measure. Only the
                // collapsed 300 pt preview needs its own vertical viewport.
                .then(if (collapsible) Modifier.verticalScroll(verticalScroll) else Modifier)
                .then(
                    if (!wrapped) Modifier.horizontalScroll(horizontalScroll) else Modifier,
                ),
        ) {
            BasicText(
                text = highlighted,
                style = codeStyle,
                softWrap = wrapped,
                modifier = Modifier.padding(ChatMetrics.CODE_BLOCK_PADDING_PT.dp),
            )
        }
        if (isLong) {
            // `Components.swift:209-218`: full-width 32 pt tail, 12 pt label.
            val expandLabel = if (expanded) {
                UiStrings.CODE_COLLAPSE
            } else {
                UiStrings.CODE_EXPAND_ALL.format(lineCount)
            }
            Box(
                modifier = Modifier
                    .fillMaxWidth()
                    .height(tokens.spacing.codeExpandHeight)
                    .background(tokens.colors.code)
                    .clickable(role = Role.Button) { expanded = !expanded }
                    .semantics { contentDescription = expandLabel }
                    .testTag(CODE_EXPAND_TAG),
                contentAlignment = Alignment.Center,
            ) {
                BasicText(
                    text = expandLabel,
                    style = type.codeExpand.copy(color = tokens.colors.secondary),
                )
            }
        }
    }
}

/** The card's stable tag (a component swatch capture addresses it). */
public const val CODE_BLOCK_TAG: String = "pdsh.surface.code-block"

/** The 复制 key's stable tag. */
public const val CODE_COPY_TAG: String = "pdsh.surface.code-block.copy"

/** The wrap toggle's stable tag. */
public const val CODE_WRAP_TAG: String = "pdsh.surface.code-block.wrap"

/** The expand/collapse tail's stable tag. */
public const val CODE_EXPAND_TAG: String = "pdsh.surface.code-block.expand"
/** Artwork size inside the separate 28 pt wrap control. */
internal const val CODE_WRAP_ICON_TAG: String = "pdsh.surface.code-block.wrap-icon"

/** `Components.swift:156-158`: long is > 24 lines or > 2400 characters. */
private const val LONG_LINE_COUNT: Int = 24
private const val LONG_CHAR_COUNT: Int = 2400
