// The answer body's renderer: paragraphs, headings, lists, quotes, fenced code,
// GFM tables and DSH's TeX extensions.
// SPDX-License-Identifier: MIT
//
// Mirror: `examples/probe-app/PhoneDSHProbe/NativeMarkdownBody.swift`.
//
// What iOS actually draws, and what this file therefore draws:
//
//   * blocks are a `VStack(spacing: 20)` (`NativeMarkdownBody.swift:27` +
//     `NativeChatTheme.messageParagraphSpacing`, `NativeChatTheme.swift:49`), so the
//     gap between two blocks is 20 pt, not the 5 pt a prose/code split used to leave;
//   * the PR22 message body is 16/24 from `HomeSpec.swift:47-48`;
//   * a table is a real table (`NativeMarkdownTable`, `:132-199`): header row in the
//     selector fill, one hairline under every cell, GFM column alignment;
//   * math is rendered by the native RaTeX span (`:108-111` display, `:285-290` inline); the
//     TeX source remains in the TextView backing text for selection and copying;
//   * raw HTML is literal text (`:293` `Text(value)`), never parsed and never a
//     WebView: `<b>` on screen is exactly the iOS output;
//   * a footnote reference is a small superscript (`:291-292`, 9 pt raised 6 pt).
package com.phonedsh.ui.surface

import android.content.ActivityNotFoundException
import androidx.compose.foundation.background
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.layout.wrapContentWidth
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicText
import androidx.compose.runtime.Composable
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.platform.LocalUriHandler
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.LinkAnnotation
import androidx.compose.ui.text.LinkInteractionListener
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.TextLinkStyles
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.BaselineShift
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.unit.TextUnit
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.phonedsh.ui.ChatMetrics
import com.phonedsh.ui.UiStrings
import com.phonedsh.ui.theme.LocalUiTokens
import com.phonedsh.ui.theme.LocalUiType
import com.phonedsh.ui.theme.UiTokens

/** Test tag of the transcript's markdown body (one node per answer). */
internal const val MARKDOWN_BODY_TAG: String = "pdsh.surface.markdown.body"

/** Test tag of a GFM table inside an answer. */
internal const val MARKDOWN_TABLE_TAG: String = "pdsh.surface.markdown.table"

/** Test tag of a display-math block. */
internal const val MARKDOWN_MATH_TAG: String = "pdsh.surface.markdown.math"

/** Test tag of the visible notice shown when an external link cannot be opened. */
internal const val MARKDOWN_LINK_FAILURE_TAG: String = "pdsh.surface.markdown.link.failure"

/**
 * Opens [value] through the platform [uriHandler]. A missing handler activity or
 * a security refusal becomes a visible notice through [onFailure] instead of an
 * exception escaping the link tap.
 *
 * @return `true` when the platform accepted the URI.
 */
internal fun openMarkdownExternalUri(
    uriHandler: androidx.compose.ui.platform.UriHandler,
    value: String,
    onFailure: () -> Unit,
): Boolean = try {
    uriHandler.openUri(value)
    true
} catch (_: ActivityNotFoundException) {
    onFailure()
    false
} catch (_: SecurityException) {
    onFailure()
    false
}

/** The short notice under a block whose external link could not be opened. */
@Composable
internal fun MarkdownLinkFailureNotice(modifier: Modifier = Modifier) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    Row(
        modifier = modifier
            .fillMaxWidth()
            .testTag(MARKDOWN_LINK_FAILURE_TAG)
            .padding(top = tokens.geometry.bannerGap),
    ) {
        BasicText(
            text = UiStrings.MARKDOWN_LINK_OPEN_FAILED,
            style = type.caption.copy(color = tokens.colors.danger),
        )
    }
}

/**
 * Renders one answer body.
 *
 * @param markdown the projected answer text, parsed once per value.
 * @param modifier the row's placement.
 */
@Composable
public fun MarkdownBody(
    markdown: String,
    modifier: Modifier = Modifier,
    onOpenFile: ((String) -> Unit)? = null,
    onOpenResource: ((String) -> Unit)? = null,
    variant: MarkdownVariant = MarkdownVariant.NORMAL,
    imageSource: MarkdownImageSource? = null,
) {
    val blocks = remember(markdown) { parseMarkdownOrPlain(markdown) }
    MarkdownBlocks(
        blocks = blocks,
        modifier = modifier,
        onOpenFile = onOpenFile,
        onOpenResource = onOpenResource,
        variant = variant,
        imageSource = imageSource,
    )
}

/**
 * Renders already-parsed [blocks]; the caller may reuse the parse across a
 * recomposition (the row remembers it).
 */
@Composable
internal fun MarkdownBlocks(
    blocks: List<MarkdownBlock>,
    modifier: Modifier = Modifier,
    onOpenFile: ((String) -> Unit)? = null,
    onOpenResource: ((String) -> Unit)? = null,
    variant: MarkdownVariant = MarkdownVariant.NORMAL,
    imageSource: MarkdownImageSource? = null,
) {
    Column(
        modifier = modifier.fillMaxWidth().testTag(MARKDOWN_BODY_TAG),
        verticalArrangement = Arrangement.spacedBy(
            if (variant == MarkdownVariant.COMPACT) ChatMetrics.MARKDOWN_COMPACT_BLOCK_SPACING_PT.dp
            else ChatMetrics.MARKDOWN_BLOCK_SPACING_PT.dp,
        ),
    ) {
        blocks.forEach { block -> MarkdownBlockView(block, onOpenFile, onOpenResource, variant, imageSource) }
    }
}

/** One block, dispatched exactly as `NativeMarkdownBlockView` dispatches (`:51-118`). */
@Composable
private fun MarkdownBlockView(
    block: MarkdownBlock,
    onOpenFile: ((String) -> Unit)?,
    onOpenResource: ((String) -> Unit)?,
    variant: MarkdownVariant,
    imageSource: MarkdownImageSource?,
) {
    val tokens = LocalUiTokens.current
    when (block) {
        is MarkdownBlock.Paragraph -> MarkdownInlineText(
            inlines = block.inlines,
            style = markdownBodyStyle(variant),
            onOpenFile = onOpenFile,
            onOpenResource = onOpenResource,
            variant = variant,
        )

        is MarkdownBlock.Heading -> MarkdownInlineText(
            inlines = block.inlines,
            style = headingStyle(block.level, variant),
            onOpenFile = onOpenFile,
            onOpenResource = onOpenResource,
            variant = variant,
        )

        is MarkdownBlock.Code -> CodeBlock(language = block.language, body = block.body)

        is MarkdownBlock.Math -> DisplayMath(latex = block.latex, variant = variant)

        is MarkdownBlock.Image -> MarkdownImageBlock(
            source = block.source,
            alt = block.alt,
            title = block.title,
            imageSource = imageSource,
            variant = variant,
        )

        is MarkdownBlock.Table -> MarkdownTable(
            header = block.header,
            rows = block.rows,
            alignments = block.alignments,
            onOpenFile = onOpenFile,
            onOpenResource = onOpenResource,
            variant = variant,
        )

        is MarkdownBlock.ListBlock -> Column(
            modifier = Modifier.fillMaxWidth().padding(start = listIndent(variant)),
            verticalArrangement = Arrangement.spacedBy(listSpacing(variant)),
        ) {
            block.items.forEachIndexed { index, item ->
                Column(verticalArrangement = Arrangement.spacedBy(listSpacing(variant))) {
                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        horizontalArrangement = Arrangement.spacedBy(
                            if (variant == MarkdownVariant.COMPACT) ChatMetrics.MARKDOWN_COMPACT_LIST_ITEM_GAP_PT.dp
                            else ChatMetrics.MESSAGE_LIST_SPACING_PT.dp,
                        ),
                    ) {
                        val marker = when {
                            item.checked == true -> MARKER_CHECKED
                            item.checked == false -> MARKER_UNCHECKED
                            block.ordered -> "${block.start + index}."
                            else -> MARKER_BULLET
                        }
                        BasicText(
                            text = marker,
                            style = markdownBodyStyle(variant).copy(color = tokens.colors.secondary),
                            modifier = Modifier
                                .widthIn(
                                    min = if (block.ordered) {
                                        ChatMetrics.MARKDOWN_ORDERED_MARKER_MIN_WIDTH_PT.dp
                                    } else {
                                        ChatMetrics.MARKDOWN_BULLET_MARKER_MIN_WIDTH_PT.dp
                                    },
                                )
                                .wrapContentWidth(androidx.compose.ui.Alignment.End)
                                .padding(top = ChatMetrics.MARKDOWN_MARKER_TOP_INSET_PT.dp),
                        )
                        val image = item.imageBlock
                        if (image != null) {
                            MarkdownImageBlock(
                                source = image.source,
                                alt = image.alt,
                                title = image.title,
                                imageSource = imageSource,
                                variant = variant,
                            )
                        } else {
                            MarkdownInlineText(
                                inlines = item.inlines,
                                style = markdownBodyStyle(variant),
                                onOpenFile = onOpenFile,
                                onOpenResource = onOpenResource,
                                variant = variant,
                            )
                        }
                    }
                    item.children.forEach { child ->
                        MarkdownBlockView(child, onOpenFile, onOpenResource, variant, imageSource)
                    }
                }
            }
        }

        // iOS draws a 2 pt rule at the leading edge and insets the children by 14
        // (`NativeMarkdownBody.swift:96-99`). unverified geometry: the 2 pt summary
        // dot is the only 2 pt token; the 14 pt inset has no token either.
        is MarkdownBlock.Quote -> Column(
            modifier = Modifier
                .fillMaxWidth()
                .drawBehind {
                    val width = ChatMetrics.MARKDOWN_QUOTE_BAR_WIDTH_PT.dp.toPx()
                    drawRect(
                        color = tokens.colors.caption,
                        size = Size(width, size.height),
                        topLeft = Offset.Zero,
                    )
                }
                .padding(
                    start = if (variant == MarkdownVariant.COMPACT) {
                        ChatMetrics.MARKDOWN_QUOTE_COMPACT_INSET_PT.dp
                    } else {
                        ChatMetrics.MARKDOWN_QUOTE_INSET_PT.dp
                    },
                ),
            verticalArrangement = Arrangement.spacedBy(
                if (variant == MarkdownVariant.COMPACT) ChatMetrics.MARKDOWN_QUOTE_COMPACT_CHILD_GAP_PT.dp
                else ChatMetrics.MARKDOWN_QUOTE_CHILD_GAP_PT.dp,
            ),
        ) {
            block.blocks.forEach { child ->
                MarkdownBlockView(child, onOpenFile, onOpenResource, variant, imageSource)
            }
        }

        MarkdownBlock.Rule -> Box(
            modifier = Modifier
                .fillMaxWidth()
                .padding(
                    vertical = if (variant == MarkdownVariant.COMPACT) {
                        ChatMetrics.MARKDOWN_RULE_COMPACT_INSET_V_PT.dp
                    } else {
                        ChatMetrics.MARKDOWN_RULE_INSET_V_PT.dp
                    },
                )
                .height(ChatMetrics.MARKDOWN_RULE_HEIGHT_PT.dp)
                .background(tokens.colors.border),
        )
    }
}

/** Normal messages use the provider body role; compact thinking uses native 13pt leading. */
@Composable
internal fun markdownBodyStyle(variant: MarkdownVariant = MarkdownVariant.NORMAL): TextStyle {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    return when (variant) {
        MarkdownVariant.NORMAL -> type.homeBody.copy(color = tokens.colors.primary)
        MarkdownVariant.COMPACT -> type.secondary.copy(
            color = tokens.colors.tertiary,
            lineHeight = TextUnit.Unspecified,
        )
    }
}

/**
 * Heading roles. iOS uses 24/22/20/17/body-bold (`NativeMarkdownBody.swift:120-129`).
 * The available JSON-backed roles are used until the remaining owner-specific
 * heading metrics are added to ChatMetrics.
 */
@Composable
private fun headingStyle(level: Int, variant: MarkdownVariant): TextStyle {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    if (variant == MarkdownVariant.COMPACT) {
        return type.secondary.copy(
            color = tokens.colors.primary,
            fontWeight = FontWeight.SemiBold,
            lineHeight = TextUnit.Unspecified,
        )
    }
    return when (level) {
        1 -> type.homeBody.copy(
            color = tokens.colors.primary,
            fontSize = ChatMetrics.MARKDOWN_H1_SIZE_PT.sp,
            fontWeight = FontWeight.Bold,
        )
        2 -> type.homeBody.copy(
            color = tokens.colors.primary,
            fontSize = ChatMetrics.MARKDOWN_H2_SIZE_PT.sp,
            fontWeight = FontWeight.Bold,
        )
        3 -> type.homeBody.copy(
            color = tokens.colors.primary,
            fontSize = ChatMetrics.MARKDOWN_H3_SIZE_PT.sp,
            fontWeight = FontWeight.SemiBold,
        )
        4 -> type.homeBody.copy(
            color = tokens.colors.primary,
            fontSize = ChatMetrics.MARKDOWN_H4_SIZE_PT.sp,
            fontWeight = FontWeight.SemiBold,
        )
        else -> type.homeBody.copy(color = tokens.colors.primary, fontWeight = FontWeight.SemiBold)
    }
}

/** One table cell's text, with the GFM column alignment (`:227-241`). */
@Composable
private fun cellStyle(align: MarkdownTableAlign?, header: Boolean, variant: MarkdownVariant): TextStyle {
    val tokens = LocalUiTokens.current
    return markdownBodyStyle(variant).copy(
        fontWeight = if (header) FontWeight.SemiBold else FontWeight.Normal,
        color = tokens.colors.primary,
        textAlign = when (align) {
            MarkdownTableAlign.CENTER -> TextAlign.Center
            MarkdownTableAlign.RIGHT -> TextAlign.End
            else -> TextAlign.Start
        },
    )
}

/**
 * A GFM table (`NativeMarkdownTable`): header row on the selector fill, one
 * hairline under every cell, every column the same weight.
 *
 * iOS picks between a grid and per-row cards with `ViewThatFits` (`:145-149`).
 * Android uses the minimum grid width to choose the matching representation.
 */
@Composable
internal fun MarkdownTable(
    header: List<List<MarkdownInline>>,
    rows: List<List<List<MarkdownInline>>>,
    alignments: List<MarkdownTableAlign?>,
    onOpenFile: ((String) -> Unit)? = null,
    onOpenResource: ((String) -> Unit)? = null,
    variant: MarkdownVariant = MarkdownVariant.NORMAL,
) {
    val tokens = LocalUiTokens.current
    val columns = maxOf(header.size, rows.maxOfOrNull { it.size } ?: 0)
    BoxWithConstraints(modifier = Modifier.fillMaxWidth().testTag(MARKDOWN_TABLE_TAG)) {
        val minimumGridWidth = ChatMetrics.MARKDOWN_TABLE_COLUMN_MIN_WIDTH_PT.dp * columns.toFloat()
        if (minimumGridWidth > maxWidth) {
            MarkdownTableCards(header, rows, columns, onOpenFile, onOpenResource, variant)
        } else {
            @Composable
            fun row(cells: List<List<MarkdownInline>>, isHeader: Boolean) {
                Row(
                    modifier = Modifier.fillMaxWidth().background(
                        // NativeChatTheme.selector (`NativeMarkdownBody.swift:224`).
                        if (isHeader) tokens.colors.approvalCard else Color.Transparent,
                    ),
                ) {
                    for (index in 0 until columns) {
                        Box(
                            modifier = Modifier
                                .weight(1f)
                                .widthIn(
                                    min = ChatMetrics.MARKDOWN_TABLE_COLUMN_MIN_WIDTH_PT.dp,
                                    max = ChatMetrics.MARKDOWN_TABLE_COLUMN_MAX_WIDTH_PT.dp,
                                )
                                // Native grid cells use 16/10 in body mode and 8/4 in compact.
                                .padding(
                                    horizontal = if (variant == MarkdownVariant.COMPACT) {
                                        ChatMetrics.MARKDOWN_TABLE_COMPACT_CELL_INSET_H_PT.dp
                                    } else {
                                        ChatMetrics.MARKDOWN_TABLE_CELL_INSET_H_PT.dp
                                    },
                                    vertical = if (variant == MarkdownVariant.COMPACT) {
                                        ChatMetrics.MARKDOWN_TABLE_COMPACT_CELL_INSET_V_PT.dp
                                    } else {
                                        ChatMetrics.MARKDOWN_TABLE_CELL_INSET_V_PT.dp
                                    },
                                )
                                .drawBehind {
                                    val stroke = tokens.stroke.hairline.toPx()
                                    drawLine(
                                        color = tokens.colors.border,
                                        start = Offset(0f, size.height - stroke / 2),
                                        end = Offset(size.width, size.height - stroke / 2),
                                        strokeWidth = stroke,
                                    )
                                },
                        ) {
                            MarkdownInlineText(
                                inlines = cells.getOrNull(index).orEmpty(),
                                style = cellStyle(alignments.getOrNull(index), isHeader, variant),
                                onOpenFile = onOpenFile,
                                onOpenResource = onOpenResource,
                                variant = variant,
                            )
                        }
                    }
                }
            }
            Column(modifier = Modifier.fillMaxWidth()) {
                row(header, isHeader = true)
                rows.forEach { row(it, isHeader = false) }
            }
        }
    }
}

@Composable
private fun MarkdownTableCards(
    header: List<List<MarkdownInline>>,
    rows: List<List<List<MarkdownInline>>>,
    columns: Int,
    onOpenFile: ((String) -> Unit)?,
    onOpenResource: ((String) -> Unit)?,
    variant: MarkdownVariant,
) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    Column(
        modifier = Modifier.fillMaxWidth(),
        verticalArrangement = Arrangement.spacedBy(ChatMetrics.MARKDOWN_TABLE_CARD_GAP_PT.dp),
    ) {
        rows.forEach { cells ->
            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .background(
                        tokens.colors.approvalCard,
                        RoundedCornerShape(ChatMetrics.MARKDOWN_TABLE_CARD_RADIUS_PT.dp),
                    )
                    .padding(ChatMetrics.MARKDOWN_TABLE_CARD_INSET_PT.dp),
                verticalArrangement = Arrangement.spacedBy(ChatMetrics.MARKDOWN_TABLE_FIELD_GAP_PT.dp),
            ) {
                for (index in 0 until columns) {
                    Column(verticalArrangement = Arrangement.spacedBy(ChatMetrics.MARKDOWN_TABLE_LABEL_VALUE_GAP_PT.dp)) {
                        MarkdownInlineText(
                            inlines = header.getOrNull(index).orEmpty(),
                            style = type.caption.copy(
                                color = tokens.colors.secondary,
                                fontWeight = FontWeight.Medium,
                            ),
                            onOpenFile = onOpenFile,
                            onOpenResource = onOpenResource,
                            variant = variant,
                        )
                        MarkdownInlineText(
                            inlines = cells.getOrNull(index).orEmpty(),
                            style = markdownBodyStyle(variant).copy(color = tokens.colors.primary),
                            onOpenFile = onOpenFile,
                            onOpenResource = onOpenResource,
                            variant = variant,
                        )
                    }
                }
            }
        }
    }
}

/**
 * Display math: the iOS block is a horizontal `ScrollView` around the typeset
 * label (`NativeMarkdownBody.swift:109-111`), so a long formula scrolls instead of
 * wrapping.
 */
@Composable
private fun DisplayMath(latex: String, variant: MarkdownVariant) {
    val style = markdownBodyStyle(variant)
    val type = LocalUiType.current
    val codeFontFamily = if (variant == MarkdownVariant.COMPACT) FontFamily.Monospace else type.code.fontFamily
    val codeFontSize = if (variant == MarkdownVariant.COMPACT) {
        ChatMetrics.MARKDOWN_COMPACT_INLINE_CODE_SIZE_PT.sp
    } else {
        (type.code.fontSize.value + ChatMetrics.MARKDOWN_INLINE_CODE_SIZE_OFFSET_PT).sp
    }
    MarkdownMathTextView(
        inlines = listOf(MarkdownInline.Math(latex)),
        style = style,
        codeFontFamily = codeFontFamily,
        codeFontSize = codeFontSize,
        displayMode = true,
        testTag = MARKDOWN_MATH_TAG,
    )
}

/** One text run with inline spans; shared by paragraphs, headings, lists and cells. */
@Composable
internal fun MarkdownInlineText(
    inlines: List<MarkdownInline>,
    style: TextStyle,
    modifier: Modifier = Modifier,
    onOpenFile: ((String) -> Unit)? = null,
    onOpenResource: ((String) -> Unit)? = null,
    variant: MarkdownVariant = MarkdownVariant.NORMAL,
) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    val uriHandler = LocalUriHandler.current
    val codeFontFamily = if (variant == MarkdownVariant.COMPACT) {
        FontFamily.Monospace
    } else {
        type.code.fontFamily
    }
    val codeFontSize = if (variant == MarkdownVariant.COMPACT) {
        ChatMetrics.MARKDOWN_COMPACT_INLINE_CODE_SIZE_PT.sp
    } else {
        (type.code.fontSize.value + ChatMetrics.MARKDOWN_INLINE_CODE_SIZE_OFFSET_PT).sp
    }
    if (containsMarkdownMath(inlines)) {
        MarkdownMathTextView(
            inlines = inlines,
            style = style,
            codeFontFamily = codeFontFamily,
            codeFontSize = codeFontSize,
            modifier = modifier,
            onOpenFile = onOpenFile,
            onOpenResource = onOpenResource,
        )
        return
    }
    val linkFailure = remember(inlines) { mutableStateOf(false) }
    val openExternal: (String) -> Unit = { value ->
        openMarkdownExternalUri(uriHandler, value) { linkFailure.value = true }
    }
    val text = remember(
        inlines,
        style,
        codeFontSize,
        codeFontFamily,
        variant,
        tokens,
        uriHandler,
        onOpenFile,
        onOpenResource,
    ) {
        annotatedInlines(
            inlines,
            style,
            codeFontFamily,
            codeFontSize,
            tokens,
            openExternal,
            onOpenFile,
            onOpenResource,
        )
    }
    if (linkFailure.value) {
        Column(modifier = modifier) {
            BasicText(text = text, style = style)
            MarkdownLinkFailureNotice()
        }
    } else {
        BasicText(text = text, style = style, modifier = modifier)
    }
}

/** Builds the annotated string for a run of inline parts. */
private fun annotatedInlines(
    inlines: List<MarkdownInline>,
    style: TextStyle,
    codeFontFamily: FontFamily?,
    codeFontSize: TextUnit,
    tokens: UiTokens,
    openExternal: (String) -> Unit,
    onOpenFile: ((String) -> Unit)?,
    onOpenResource: ((String) -> Unit)?,
): AnnotatedString {
    val builder = AnnotatedString.Builder()
    // The spans must start from the block's own size: the math script and the
    // footnote reference are sized relative to it (an unspecified size would leave
    // both at 100 %).
    val base = SpanStyle(
        color = style.color,
        fontSize = style.fontSize,
        fontWeight = style.fontWeight,
        fontStyle = style.fontStyle,
    )
    builder.appendInlines(
        inlines,
        base,
        codeFontFamily,
        codeFontSize,
        tokens,
        openExternal,
        onOpenFile,
        onOpenResource,
    )
    return builder.toAnnotatedString()
}

private fun AnnotatedString.Builder.appendInlines(
    inlines: List<MarkdownInline>,
    span: SpanStyle,
    codeFontFamily: FontFamily?,
    codeFontSize: TextUnit,
    tokens: UiTokens,
    openExternal: (String) -> Unit,
    onOpenFile: ((String) -> Unit)?,
    onOpenResource: ((String) -> Unit)?,
) {
    inlines.forEach { part ->
        when (part) {
            is MarkdownInline.Text -> withStyle(span) { append(part.text) }
            is MarkdownInline.Strong -> appendInlines(
                part.children,
                span.merge(SpanStyle(fontWeight = FontWeight.SemiBold)),
                codeFontFamily,
                codeFontSize,
                tokens,
                openExternal,
                onOpenFile,
                onOpenResource,
            )
            is MarkdownInline.Emphasis -> appendInlines(
                part.children,
                span.merge(SpanStyle(fontStyle = FontStyle.Italic)),
                codeFontFamily,
                codeFontSize,
                tokens,
                openExternal,
                onOpenFile,
                onOpenResource,
            )
            is MarkdownInline.Delete -> appendInlines(
                part.children,
                span.merge(SpanStyle(textDecoration = TextDecoration.LineThrough)),
                codeFontFamily,
                codeFontSize,
                tokens,
                openExternal,
                onOpenFile,
                onOpenResource,
            )
            is MarkdownInline.Code -> withStyle(
                span.merge(
                    SpanStyle(
                        fontFamily = codeFontFamily ?: FontFamily.Monospace,
                        fontSize = codeFontSize,
                        background = tokens.colors.inlineCode,
                    ),
                ),
            ) { append(part.code) }
            is MarkdownInline.Link -> {
                val target = markdownLinkTarget(part.destination)
                if (
                    target == null ||
                    (target is MarkdownLinkTarget.WorkspacePath && onOpenFile == null) ||
                    (target is MarkdownLinkTarget.ResourceUri && onOpenResource == null)
                ) {
                    appendInlines(
                        part.children,
                        span,
                        codeFontFamily,
                        codeFontSize,
                        tokens,
                        openExternal,
                        onOpenFile,
                        onOpenResource,
                    )
                } else {
                    val listener = LinkInteractionListener {
                        when (target) {
                            is MarkdownLinkTarget.Uri -> openExternal(target.value)
                            is MarkdownLinkTarget.WorkspacePath -> onOpenFile?.invoke(target.value)
                            is MarkdownLinkTarget.ResourceUri -> onOpenResource?.invoke(target.value)
                        }
                    }
                    pushLink(
                        LinkAnnotation.Url(
                            part.destination,
                            styles = TextLinkStyles(
                                style = SpanStyle(
                                    color = tokens.colors.accent,
                                    textDecoration = TextDecoration.Underline,
                                ),
                            ),
                            linkInteractionListener = listener,
                        ),
                    )
                    appendInlines(
                        part.children,
                        span,
                        codeFontFamily,
                        codeFontSize,
                        tokens,
                        openExternal,
                        onOpenFile,
                        onOpenResource,
                    )
                    pop()
                }
            }
            is MarkdownInline.Image -> withStyle(
                span.merge(SpanStyle(color = tokens.colors.tertiary, fontStyle = FontStyle.Italic)),
            ) { append(part.alt) }
            is MarkdownInline.Footnote -> withStyle(
                span.merge(
                    SpanStyle(
                        fontSize = ChatMetrics.MARKDOWN_FOOTNOTE_SIZE_PT.sp,
                        baselineShift = BaselineShift(
                            ChatMetrics.MARKDOWN_FOOTNOTE_BASELINE_OFFSET_PT / span.fontSize.value,
                        ),
                    ),
                ),
            ) { append("[${part.id}]") }
            // Math-containing paragraphs are dispatched to MarkdownMathTextView.
            // Keep TeX source as a literal fallback if this builder is reused directly.
            is MarkdownInline.Math -> withStyle(span) { append(part.latex) }
        }
    }
}

private const val MARKER_BULLET: String = "•"
private const val MARKER_CHECKED: String = "[x]"
private const val MARKER_UNCHECKED: String = "[ ]"

// NativeMarkdownBody.swift compact variant: VStack spacing 4, list spacing 2,
// list item HStack spacing 8, fixed inline-code font 13.

private fun listIndent(variant: MarkdownVariant) = if (variant == MarkdownVariant.COMPACT) {
    ChatMetrics.MARKDOWN_LIST_COMPACT_INDENT_PT.dp
} else {
    ChatMetrics.MARKDOWN_LIST_INDENT_PT.dp
}

private fun listSpacing(variant: MarkdownVariant) = if (variant == MarkdownVariant.COMPACT) {
    ChatMetrics.MARKDOWN_COMPACT_LIST_STACK_SPACING_PT.dp
} else {
    ChatMetrics.MESSAGE_LIST_SPACING_PT.dp
}
