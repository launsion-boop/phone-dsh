// A small Markdown reader for the preview face.
// SPDX-License-Identifier: MIT
//
// Android had no Markdown renderer at all: `FileKind.MARKDOWN` in `FilesPage.kt`
// fell through to the monospaced text body, so a `.md` file showed its asterisks.
// The baseline renders it (`PreviewSurface.swift:415` `NativeMarkdownBody`), and
// this is the smallest honest stand-in for that body:
//
//   blocks    ATX headings (`#`…`######`), paragraphs, fenced code, bullet lists
//             (`-`/`*`/`+`), ordered lists (`1.`), block quotes, horizontal rules
//   inlines   `**bold**`, `*italic*`, `` `code` ``, `[text](url)` (drawn as a
//             link, not followed: the preview face owns no browser)
//   <code>    a fenced block is drawn by the shared `CodeBlock` surface, so the
//             language strip and 复制 behave exactly as they do in an answer
//
// What it deliberately does **not** do: HTML passthrough (a page source needs a
// WebView, which this host has exactly one of), tables, images, footnotes. Those
// stay literal text — the paragraph is rendered verbatim — which is the honest
// failure mode: the file's own characters, not a half-rendered table.
//
// The splitter is pure (`parseMarkdown`), so `PreviewMarkdownTest` pins the block
// grammar on the JVM without a device; only the drawing needs Compose.
package com.phonedsh.ui.surface.preview

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.text.BasicText
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.withStyle
import com.phonedsh.ui.HomeMetrics
import com.phonedsh.ui.theme.LocalUiTokens
import com.phonedsh.ui.theme.LocalUiType
import com.phonedsh.ui.theme.UiColors

/**
 * One block of a Markdown document.
 *
 * The model is deliberately flat: nesting is what a real Markdown engine is for,
 * and every block below is drawn exactly as the file wrote it.
 */
public sealed interface MarkdownBlock {
    /** `# Title` … `###### Title`; [level] is 1–6. */
    public data class Heading(public val level: Int, public val text: String) : MarkdownBlock

    /** A run of consecutive non-blank lines, joined with `\n` exactly as written. */
    public data class Paragraph(public val text: String) : MarkdownBlock

    /** A triple-backtick fence; [info] is the language word (may be empty). */
    public data class Code(public val info: String, public val body: String) : MarkdownBlock

    /** A bullet list: one entry per line, markers stripped. */
    public data class Bullets(public val items: List<String>) : MarkdownBlock

    /** An ordered list: the numbers as written, with the rendered text. */
    public data class Numbers(public val items: List<NumberedItem>) : MarkdownBlock

    /** `> quoted` lines, joined with `\n`. */
    public data class Quote(public val text: String) : MarkdownBlock

    /** `---`, `***` or `___`: a horizontal rule. */
    public data object Rule : MarkdownBlock
}

/** One ordered-list entry: the number as written plus its text. */
public data class NumberedItem(public val marker: String, public val text: String)

/** The fence marker (`\u0060\u0060\u0060`), spelled once. */
private const val FENCE: String = "```"

/**
 * Splits a Markdown document into blocks.
 *
 * An unterminated fence is the rest of the document as a code block, which is what
 * a reader expects of a file whose author forgot the closing marker (and unlike the
 * chat streamer's `MarkdownParser`, there is no "more text is coming" here: the
 * file is on disk).
 */
public fun parseMarkdown(text: String): List<MarkdownBlock> {
    val blocks = mutableListOf<MarkdownBlock>()
    val lines = text.split('\n')
    var index = 0
    val paragraph = StringBuilder()

    fun flushParagraph() {
        if (paragraph.isEmpty()) return
        blocks.add(MarkdownBlock.Paragraph(paragraph.toString().trimEnd('\n')))
        paragraph.setLength(0)
    }

    while (index < lines.size) {
        val line = lines[index]
        val trimmed = line.trim()
        when {
            trimmed.startsWith(FENCE) -> {
                flushParagraph()
                val info = trimmed.removePrefix(FENCE).trim()
                index += 1
                val body = StringBuilder()
                while (index < lines.size && !lines[index].trim().startsWith(FENCE)) {
                    body.append(lines[index]).append('\n')
                    index += 1
                }
                if (index < lines.size) index += 1 // consume the closing fence
                blocks.add(MarkdownBlock.Code(info = info, body = body.toString().trimEnd('\n')))
                continue
            }

            trimmed.isEmpty() -> {
                flushParagraph()
                index += 1
                continue
            }

            headingLevel(trimmed) > 0 -> {
                flushParagraph()
                val level = headingLevel(trimmed)
                blocks.add(MarkdownBlock.Heading(level, trimmed.drop(level).trim()))
                index += 1
                continue
            }

            isRule(trimmed) -> {
                flushParagraph()
                blocks.add(MarkdownBlock.Rule)
                index += 1
                continue
            }

            trimmed.startsWith(">") -> {
                flushParagraph()
                val quote = mutableListOf<String>()
                while (index < lines.size && lines[index].trim().startsWith(">")) {
                    quote.add(lines[index].trim().removePrefix(">").trim())
                    index += 1
                }
                blocks.add(MarkdownBlock.Quote(quote.joinToString("\n")))
                continue
            }

            isBullet(trimmed) -> {
                flushParagraph()
                val items = mutableListOf<String>()
                while (index < lines.size && isBullet(lines[index].trim())) {
                    items.add(lines[index].trim().substring(1).trim())
                    index += 1
                }
                blocks.add(MarkdownBlock.Bullets(items))
                continue
            }

            orderedMarker(trimmed) != null -> {
                flushParagraph()
                val items = mutableListOf<NumberedItem>()
                while (index < lines.size) {
                    val marker = orderedMarker(lines[index].trim()) ?: break
                    items.add(NumberedItem(marker, lines[index].trim().drop(marker.length).trim()))
                    index += 1
                }
                blocks.add(MarkdownBlock.Numbers(items))
                continue
            }

            else -> {
                paragraph.append(line).append('\n')
                index += 1
            }
        }
    }
    flushParagraph()
    return blocks
}

/** The next `*` that is not half of a `**`, i.e. the closing marker of `*em*`. */
private fun closingSingleStar(text: String, from: Int): Int {
    var index = text.indexOf('*', from)
    while (index >= 0) {
        val beforeIsStar = index > 0 && text[index - 1] == '*'
        val afterIsStar = index + 1 < text.length && text[index + 1] == '*'
        if (!beforeIsStar && !afterIsStar) return index
        index = text.indexOf('*', index + 1)
    }
    return -1
}

/** `#`…`######` followed by a space, or 0 for "not a heading". */
private fun headingLevel(trimmed: String): Int {
    if (!trimmed.startsWith("#")) return 0
    val hashes = trimmed.takeWhile { it == '#' }.length
    if (hashes > MAX_HEADING_LEVEL) return 0
    if (trimmed.length <= hashes || trimmed[hashes] != ' ') return 0
    return hashes
}

private const val MAX_HEADING_LEVEL: Int = 6

/** `---`, `***`, `___` (three or more), optionally spaced. */
private fun isRule(trimmed: String): Boolean {
    if (trimmed.length < MIN_RULE_LENGTH) return false
    val marker = trimmed.first()
    if (marker != '-' && marker != '*' && marker != '_') return false
    return trimmed.all { it == marker }
}

private const val MIN_RULE_LENGTH: Int = 3

/** `-`, `*` or `+` followed by a space. */
private fun isBullet(trimmed: String): Boolean {
    if (trimmed.length < 2) return false
    val marker = trimmed.first()
    if (marker != '-' && marker != '*' && marker != '+') return false
    return trimmed[1] == ' '
}

/** The `1.` / `12)` marker of an ordered item, or `null`. */
private fun orderedMarker(trimmed: String): String? {
    val digits = trimmed.takeWhile { it.isDigit() }
    if (digits.isEmpty() || digits.length > MAX_ORDER_DIGITS) return null
    val rest = trimmed.drop(digits.length)
    if (rest.length < 2) return null
    if (rest[0] != '.' && rest[0] != ')') return null
    if (rest[1] != ' ') return null
    return digits + rest[0]
}

private const val MAX_ORDER_DIGITS: Int = 9

/**
 * One inline run, with the four markers the renderer styles.
 *
 * Parsed without a regex engine: a marker that has no partner stays literal text,
 * which is what a file's own characters are.
 */
public sealed interface InlineSegment {
    public data class Plain(public val text: String) : InlineSegment
    public data class Bold(public val text: String) : InlineSegment
    public data class Italic(public val text: String) : InlineSegment
    public data class Code(public val text: String) : InlineSegment

    /** `[label](target)`: [label] is drawn as a link, [target] is not followed. */
    public data class Link(public val label: String, public val target: String) : InlineSegment
}

/**
 * Splits a paragraph into styled segments.
 *
 * Precedence is code span first (its contents are literal), then `**`, then `*`,
 * then links — the order that keeps `` `**not bold**` `` a code span.
 */
public fun parseInline(text: String): List<InlineSegment> {
    val segments = mutableListOf<InlineSegment>()
    val plain = StringBuilder()
    var index = 0

    fun flush() {
        if (plain.isEmpty()) return
        segments.add(InlineSegment.Plain(plain.toString()))
        plain.setLength(0)
    }

    while (index < text.length) {
        val char = text[index]
        when {
            char == '`' -> {
                val close = text.indexOf('`', index + 1)
                if (close < 0) {
                    plain.append(char)
                    index += 1
                } else {
                    flush()
                    segments.add(InlineSegment.Code(text.substring(index + 1, close)))
                    index = close + 1
                }
            }

            text.startsWith("**", index) -> {
                val close = text.indexOf("**", index + 2)
                if (close < 0) {
                    plain.append("**")
                    index += 2
                } else {
                    flush()
                    segments.add(InlineSegment.Bold(text.substring(index + 2, close)))
                    index = close + 2
                }
            }

            char == '*' -> {
                val close = closingSingleStar(text, index + 1)
                if (close < 0) {
                    plain.append(char)
                    index += 1
                } else {
                    flush()
                    segments.add(InlineSegment.Italic(text.substring(index + 1, close)))
                    index = close + 1
                }
            }

            char == '[' -> {
                val labelEnd = text.indexOf(']', index + 1)
                val targetEnd = if (labelEnd < 0 || labelEnd + 1 >= text.length) -1 else {
                    if (text[labelEnd + 1] != '(') -1 else text.indexOf(')', labelEnd + 2)
                }
                if (labelEnd < 0 || targetEnd < 0) {
                    plain.append(char)
                    index += 1
                } else {
                    flush()
                    segments.add(
                        InlineSegment.Link(
                            label = text.substring(index + 1, labelEnd),
                            target = text.substring(labelEnd + 2, targetEnd),
                        ),
                    )
                    index = targetEnd + 1
                }
            }

            else -> {
                plain.append(char)
                index += 1
            }
        }
    }
    flush()
    return segments
}

/**
 * Draws a Markdown document.
 *
 * The outer reading margin comes from HomeSpec; block spacing comes from the
 * current UI theme. No page-only token is assumed.
 */
@Composable
public fun PreviewMarkdown(text: String, modifier: Modifier = Modifier) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    val blocks = parseMarkdown(text)
    Column(
        modifier = modifier
            .fillMaxWidth()
            .padding(
                horizontal = HomeMetrics.contentInset,
                vertical = tokens.spacing.cardInset,
            ),
        verticalArrangement = Arrangement.spacedBy(tokens.spacing.iconText),
    ) {
        blocks.forEach { block ->
            when (block) {
                is MarkdownBlock.Heading -> BasicText(
                    text = inline(block.text, tokens.colors.textPrimary),
                    style = when (block.level) {
                        1 -> type.largeTitle
                        2 -> type.pageTitle
                        else -> type.body
                    }.copy(color = tokens.colors.textPrimary),
                )

                is MarkdownBlock.Paragraph -> BasicText(
                    text = inline(block.text, tokens.colors.textPrimary),
                    style = type.body.copy(color = tokens.colors.textPrimary),
                )

                is MarkdownBlock.Code -> com.phonedsh.ui.surface.CodeBlock(
                    language = block.info,
                    body = block.body,
                )

                is MarkdownBlock.Bullets -> Column(
                    verticalArrangement = Arrangement.spacedBy(tokens.spacing.badgeInsetV),
                ) {
                    block.items.forEach { item ->
                        Row(horizontalArrangement = Arrangement.spacedBy(tokens.spacing.iconText)) {
                            BasicText(
                                text = BULLET,
                                style = type.body.copy(color = tokens.colors.textSecondary),
                            )
                            BasicText(
                                text = inline(item, tokens.colors.textPrimary),
                                style = type.body.copy(color = tokens.colors.textPrimary),
                            )
                        }
                    }
                }

                is MarkdownBlock.Numbers -> Column(
                    verticalArrangement = Arrangement.spacedBy(tokens.spacing.badgeInsetV),
                ) {
                    block.items.forEach { item ->
                        Row(horizontalArrangement = Arrangement.spacedBy(tokens.spacing.iconText)) {
                            BasicText(
                                text = item.marker,
                                style = type.body.copy(color = tokens.colors.textSecondary),
                            )
                            BasicText(
                                text = inline(item.text, tokens.colors.textPrimary),
                                style = type.body.copy(color = tokens.colors.textPrimary),
                            )
                        }
                    }
                }

                is MarkdownBlock.Quote -> BasicText(
                    text = inline(block.text, tokens.colors.textPrimary),
                    style = type.body.copy(color = tokens.colors.textSecondary),
                    modifier = Modifier.padding(start = tokens.spacing.cardInset),
                )

                MarkdownBlock.Rule -> BasicText(
                    text = RULE,
                    style = type.listItem.copy(color = tokens.colors.borderList),
                )
            }
        }
    }
}

/** The bullet glyph: the baseline's `•` list marker, drawn as text. */
private const val BULLET: String = "•"

/** The horizontal rule: an em-dash run on the page's own ink. */
private const val RULE: String = "──────────"

/**
 * Builds the styled run for one inline text.
 *
 * The styles are the theme's own: bold is [FontWeight.SemiBold] of the same face,
 * code is the `code` colour, a link is the accent ink. Nothing is underlined into a
 * tappable target, because the preview face has no browser to open it in.
 */
@Composable
private fun inline(text: String, accent: Color): AnnotatedString {
    val tokens = LocalUiTokens.current
    val segments = parseInline(text)
    return buildAnnotatedString {
        segments.forEach { segment ->
            when (segment) {
                is InlineSegment.Plain -> append(segment.text)
                is InlineSegment.Bold -> withStyle(SpanStyle(fontWeight = FontWeight.SemiBold)) {
                    append(segment.text)
                }
                is InlineSegment.Italic -> withStyle(SpanStyle(fontStyle = androidx.compose.ui.text.font.FontStyle.Italic)) {
                    append(segment.text)
                }
                is InlineSegment.Code -> withStyle(
                    SpanStyle(
                        color = tokens.colors.textPrimary,
                        background = tokens.colors.sessionCode,
                        fontFamily = FontFamily.Monospace,
                    ),
                ) { append(segment.text) }
                is InlineSegment.Link -> withStyle(SpanStyle(color = accent)) { append(segment.label) }
            }
        }
    }
}

/** Canonical spec name, backed by the existing resolved code colour role. */
private val UiColors.sessionCode: Color get() = code
