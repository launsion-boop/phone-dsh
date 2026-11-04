// The answer body's block and inline model, and the parser that builds it.
// SPDX-License-Identifier: MIT
//
// Mirror: `examples/probe-app/PhoneDSHProbe/NativeMarkdownModel.swift`. The iOS
// page parses an answer with swift-markdown (CommonMark + GFM) and pre-processes
// three DSH extensions before the parse:
//
//   * `$$…$$` / `\[…\]` become a fenced ```math block (`:101-106`);
//   * `\(…\)` / `$…$` become a code span the AST parser turns into `.math`
//     (`:108-118`, `:205-208`);
//   * `[^id]: …` definitions are lifted out of the body and `[^id]` references
//     become an inline `.footnote` (`:85-99`, `:221-235`).
//
// This file is deliberately **not** a CommonMark engine. It recognises the block
// kinds the iOS renderer draws (heading, paragraph, list, quote, rule, fenced
// code, table, display math) and the inline kinds it styles (strong, emphasis,
// delete, code, link, inline math, footnote). Raw HTML is *text*: iOS renders
// `.html` with `Text(value)` (`NativeMarkdownBody.swift:293`) and never parses
// it, so leaving `<b>` in the paragraph is the faithful behaviour, not a gap.
package com.phonedsh.ui.surface

import java.net.URI

/**
 * Maximum recursive block nesting (quotes and list-item children) the parser
 * descends before it degrades the remaining source to a plain-text paragraph.
 */
internal const val MAX_MARKDOWN_BLOCK_DEPTH: Int = 32

/** Native markdown presentation variant; compact is used for expanded thinking. */
public enum class MarkdownVariant {
    /** Full transcript typography and spacing. */
    NORMAL,

    /** Compact disclosure-body typography and spacing. */
    COMPACT,
}

/** A GFM table column alignment (`NativeMarkdownTableAlignment`). */
public enum class MarkdownTableAlign {
    /** `:--` — leading. */
    LEFT,

    /** `:-:` — centred. */
    CENTER,

    /** `--:` — trailing. */
    RIGHT,
}

/** One inline run of a paragraph, a heading or a table cell. */
public sealed interface MarkdownInline {
    /** Literal text, including raw HTML tags: iOS draws them verbatim. */
    public data class Text(public val text: String) : MarkdownInline

    /** `**strong**` / `__strong__`. */
    public data class Strong(public val children: List<MarkdownInline>) : MarkdownInline

    /** `*emphasis*` / `_emphasis_`. */
    public data class Emphasis(public val children: List<MarkdownInline>) : MarkdownInline

    /** `~~deleted~~`. */
    public data class Delete(public val children: List<MarkdownInline>) : MarkdownInline

    /** `` `code` `` — a monospaced span, not a block. */
    public data class Code(public val code: String) : MarkdownInline

    /** `[label](destination)`. */
    public data class Link(
        public val destination: String,
        public val children: List<MarkdownInline>,
    ) : MarkdownInline

    /** Image content is not downloaded; iOS displays its alt text in italics. */
    public data class Image(public val alt: String) : MarkdownInline

    /** `$…$` / `\(…\)` — the TeX source, typeset by the renderer. */
    public data class Math(public val latex: String) : MarkdownInline

    /** `[^id]` — a superscript reference (iOS `.footnote`). */
    public data class Footnote(public val id: String) : MarkdownInline
}

/**
 * One list item: the GFM task marker (when present) and its inline content.
 *
 * @param checked `true` for `[x]`, `false` for `[ ]`, `null` for a plain item.
 */
public data class MarkdownListItem(
    public val checked: Boolean?,
    public val inlines: List<MarkdownInline>,
    /** Nested blocks under this item, preserving the CommonMark/GFM hierarchy. */
    public val children: List<MarkdownBlock> = emptyList(),
    /** A direct image-only paragraph in the list item, if present. */
    public val imageBlock: MarkdownBlock.Image? = null,
)

/** One block of an answer (`NativeMarkdownBlock`). */
public sealed interface MarkdownBlock {
    /** A paragraph; soft line breaks inside it become spaces, like CommonMark. */
    public data class Paragraph(public val inlines: List<MarkdownInline>) : MarkdownBlock

    /** `#` … `######`. */
    public data class Heading(
        public val level: Int,
        public val inlines: List<MarkdownInline>,
    ) : MarkdownBlock

    /** A fenced code block; `language` may be empty. */
    public data class Code(public val language: String, public val body: String) : MarkdownBlock

    /** A GFM table (iOS `.table`). */
    public data class Table(
        public val header: List<List<MarkdownInline>>,
        public val rows: List<List<List<MarkdownInline>>>,
        public val alignments: List<MarkdownTableAlign?>,
    ) : MarkdownBlock

    /** Display math: the TeX source between `$$…$$` or `\[…\]`. */
    public data class Math(public val latex: String) : MarkdownBlock

    /** A paragraph whose only child is a Markdown image, preserving its complete source metadata. */
    public data class Image(
        public val source: String,
        public val alt: String,
        public val title: String,
    ) : MarkdownBlock

    /** A bullet or ordered list. */
    public data class ListBlock(
        public val ordered: Boolean,
        public val start: Int,
        public val items: List<MarkdownListItem>,
    ) : MarkdownBlock

    /** A `>` quote: one level, recursively parsed. */
    public data class Quote(public val blocks: List<MarkdownBlock>) : MarkdownBlock

    /** `---` / `***` / `___` (iOS `.thematicBreak`). */
    public data object Rule : MarkdownBlock
}

/**
 * Parses an answer body into [MarkdownBlock]s.
 *
 * Pure: the same string always yields the same blocks, so a replay and a unit
 * test see one answer.
 */
public object MarkdownParser {
    /**
     * @param source the projected answer body.
     * @return the blocks in source order, plus the footnote section iOS appends.
     */
    public fun parse(source: String): List<MarkdownBlock> {
        val lines = source.replace("\r\n", "\n").replace('\r', '\n').split("\n")
        val footnotes = LinkedHashMap<String, String>()
        val body = ArrayList<String>(lines.size)
        lines.forEach { line ->
            val match = FOOTNOTE_DEFINITION.matchEntire(line)
            if (match == null) {
                body.add(line)
            } else {
                footnotes[match.groupValues[1]] = match.groupValues[2]
            }
        }
        val bodyWithReferences = body.map { line ->
            footnotes.keys.fold(line) { current, id ->
                current.replace("[^$id]", "DSHFOOTNOTE${id}END")
            }
        }
        val blocks = parseBlocks(bodyWithReferences).toMutableList()
        if (footnotes.isNotEmpty()) {
            // iOS appends the section after the body (`NativeMarkdownModel.swift:51-59`):
            // a bold 脚注 line, then each identifier and its parsed definition.
            blocks.add(MarkdownBlock.Paragraph(listOf(MarkdownInline.Strong(listOf(
                MarkdownInline.Text(FOOTNOTE_HEADING),
            )))))
            footnotes.toSortedMap().forEach { (id, definition) ->
                blocks.add(MarkdownBlock.Paragraph(
                    listOf(MarkdownInline.Text("[$id] ")) + inlines(definition),
                ))
            }
        }
        return blocks
    }

    /** Parses a line range; used for the body and recursively for a quote. */
    private fun parseBlocks(lines: List<String>, depth: Int = 0): List<MarkdownBlock> {
        if (depth >= MAX_MARKDOWN_BLOCK_DEPTH) {
            // Hostile input must stay on screen instead of exhausting the stack.
            // The remaining source is kept verbatim as one plain paragraph.
            return if (lines.isEmpty()) {
                emptyList()
            } else {
                listOf(MarkdownBlock.Paragraph(listOf(MarkdownInline.Text(lines.joinToString("\n")))))
            }
        }
        val out = mutableListOf<MarkdownBlock>()
        val paragraph = mutableListOf<String>()
        fun flushParagraph() {
            if (paragraph.isEmpty()) return
            val text = buildString {
                paragraph.forEachIndexed { index, line ->
                    val trailing = line.length - line.trimEnd(' ', '\t').length
                    val explicitBreak = line.trimEnd().endsWith('\\')
                    append(line.trim().trimEnd(' ', '\t').let { if (explicitBreak) it.removeSuffix("\\") else it })
                    if (index < paragraph.lastIndex) append(if (trailing >= 2 || explicitBreak) '\n' else ' ')
                }
            }
            out.add(MarkdownBlock.Paragraph(inlines(text)))
            paragraph.clear()
        }

        var i = 0
        while (i < lines.size) {
            val line = lines[i]
            val trimmed = line.trim()
            when {
                trimmed.isEmpty() -> {
                    flushParagraph()
                    i++
                }

                trimmed.startsWith("![") -> {
                    val image = if (paragraph.isEmpty()) standaloneImage(trimmed) else null
                    if (image != null && endsStandaloneImageParagraph(lines, i)) {
                        out.add(image)
                    } else {
                        // Image labels inside a prose paragraph keep the existing inline-alt path.
                        paragraph.add(line)
                    }
                    i++
                }

                trimmed.startsWith(FENCE) -> {
                    val language = trimmed.removePrefix(FENCE).trim()
                    val body = StringBuilder()
                    var j = i + 1
                    while (j < lines.size && lines[j].trim() != FENCE) {
                        body.append(lines[j]).append('\n')
                        j++
                    }
                    if (j >= lines.size) {
                        // Unterminated fence: the stream has not finished arriving.
                        // The old splitter kept it prose so a half answer never
                        // flashed an empty card; the same rule holds here, and the
                        // opening line stays in the surrounding paragraph.
                        paragraph.add(trimmed)
                        i++
                    } else {
                        flushParagraph()
                        out.add(MarkdownBlock.Code(language, body.toString().trimEnd('\n')))
                        i = j + 1
                    }
                }

                trimmed.startsWith("$$") -> {
                    flushParagraph()
                    val close = trimmed.indexOf("$$", 2)
                    if (close > 0) {
                        out.add(MarkdownBlock.Math(trimmed.substring(2, close).trim()))
                        i++
                    } else {
                        val latex = StringBuilder(trimmed.removePrefix("$$"))
                        var j = i + 1
                        while (j < lines.size && lines[j].trim() != "$$") {
                            latex.append('\n').append(lines[j])
                            j++
                        }
                        out.add(MarkdownBlock.Math(latex.toString().trim()))
                        i = if (j >= lines.size) lines.size else j + 1
                    }
                }

                trimmed.startsWith("\\[") -> {
                    flushParagraph()
                    val latex = StringBuilder(trimmed.removePrefix("\\["))
                    var j = i
                    if (trimmed.length > 4 && trimmed.endsWith("\\]")) {
                        out.add(MarkdownBlock.Math(trimmed.substring(2, trimmed.length - 2)))
                        i++
                    } else {
                        j += 1
                        while (j < lines.size && !lines[j].trim().endsWith("\\]")) {
                            latex.append('\n').append(lines[j])
                            j++
                        }
                        if (j < lines.size) latex.append('\n').append(lines[j].trim().removeSuffix("\\]"))
                        out.add(MarkdownBlock.Math(latex.toString().trim()))
                        i = if (j >= lines.size) lines.size else j + 1
                    }
                }

                isTableHeader(lines, i) -> {
                    flushParagraph()
                    val header = cells(lines[i]).map { inlines(it) }
                    val alignments = cells(lines[i + 1]).map(::alignment)
                    val rows = mutableListOf<List<List<MarkdownInline>>>()
                    var j = i + 2
                    while (j < lines.size && lines[j].contains('|') && lines[j].isNotBlank()) {
                        rows.add(cells(lines[j]).map { inlines(it) })
                        j++
                    }
                    out.add(MarkdownBlock.Table(header, rows, alignments))
                    i = j
                }

                HEADING.matches(trimmed) -> {
                    flushParagraph()
                    val match = HEADING.matchEntire(trimmed)!!
                    out.add(
                        MarkdownBlock.Heading(
                            level = match.groupValues[1].length,
                            inlines = inlines(match.groupValues[2].trim()),
                        ),
                    )
                    i++
                }

                RULE.matches(trimmed) -> {
                    flushParagraph()
                    out.add(MarkdownBlock.Rule)
                    i++
                }

                trimmed.startsWith(">") -> {
                    flushParagraph()
                    val quoted = mutableListOf<String>()
                    var j = i
                    while (j < lines.size && lines[j].trim().startsWith(">")) {
                        quoted.add(lines[j].trim().removePrefix(">").removePrefix(" "))
                        j++
                    }
                    out.add(MarkdownBlock.Quote(parseBlocks(quoted, depth + 1)))
                    i = j
                }

                BULLET.matches(line) || ORDERED.matches(line) -> {
                    flushParagraph()
                    val listIndent = leadingIndent(line)
                    val ordered = ORDERED.matches(line)
                    val start = if (ordered) {
                        ORDERED.matchEntire(line)!!.groupValues[1].toIntOrNull() ?: 1
                    } else {
                        1
                    }
                    val pending = mutableListOf<Pair<MarkdownListItem, MutableList<String>>>()
                    var j = i
                    while (j < lines.size) {
                        val candidate = lines[j]
                        val candidateIndent = leadingIndent(candidate)
                        val hasMarker = BULLET.matches(candidate) || ORDERED.matches(candidate)
                        if (hasMarker && candidateIndent == listIndent) {
                            val rawItem = if (ordered) {
                                ORDERED.matchEntire(candidate)?.groupValues?.get(2)
                            } else {
                                BULLET.matchEntire(candidate)?.groupValues?.get(1)
                            } ?: break
                            var text = rawItem
                            var checked: Boolean? = null
                            val task = TASK.matchEntire(rawItem)
                            if (task != null) {
                                checked = task.groupValues[1].equals("x", ignoreCase = true)
                                text = task.groupValues[2]
                            }
                            pending.add(
                                MarkdownListItem(checked, inlines(text), imageBlock = standaloneImage(text)) to mutableListOf(),
                            )
                            j++
                        } else if (pending.isNotEmpty() && candidateIndent > listIndent) {
                            // Strip the parent marker's continuation indent so the
                            // recursive parser sees the nested list at its own root.
                            pending.last().second.add(
                                if (candidate.isBlank()) "" else candidate.drop(minOf(listIndent + 2, candidate.length)),
                            )
                            j++
                        } else if (candidate.isBlank() && pending.isNotEmpty() && j + 1 < lines.size &&
                            leadingIndent(lines[j + 1]) > listIndent
                        ) {
                            pending.last().second.add("")
                            j++
                        } else {
                            break
                        }
                    }
                    val items = pending.map { (item, childLines) ->
                        val standalone = item.imageBlock.takeIf { childLines.isEmpty() }
                        item.copy(
                            inlines = if (standalone == null) item.inlines else emptyList(),
                            imageBlock = standalone,
                            children = parseBlocks(childLines, depth + 1),
                        )
                    }
                    out.add(MarkdownBlock.ListBlock(ordered, start, items))
                    i = j
                }

                else -> {
                    paragraph.add(line)
                    i++
                }
            }
        }
        flushParagraph()
        return out
    }

    /** Splits a table line into trimmed cells. */
    private fun cells(line: String): List<String> {
        var text = line.trim()
        if (text.startsWith("|")) text = text.substring(1)
        if (text.endsWith("|")) text = text.dropLast(1)
        return text.split("|").map { it.trim() }
    }

    /** True when line `index` opens a table: a pipe row followed by a delimiter row. */
    private fun isTableHeader(lines: List<String>, index: Int): Boolean {
        if (index + 1 >= lines.size) return false
        val header = lines[index]
        if (!header.contains('|')) return false
        val delimiter = lines[index + 1].trim()
        if (delimiter.isEmpty() || delimiter.any { it !in "-:| \t" }) return false
        if (!delimiter.contains('-')) return false
        val columns = cells(header).size
        val markers = cells(delimiter)
        return markers.size == columns && markers.all { DELIMITER_CELL.matches(it) }
    }

    /** iOS promotes an image only when its entire Markdown paragraph is one image child. */
    private fun endsStandaloneImageParagraph(lines: List<String>, index: Int): Boolean {
        if (index + 1 >= lines.size || lines[index + 1].isBlank()) return true
        val next = lines[index + 1].trim()
        return next.startsWith(FENCE) || next.startsWith("$$") || next.startsWith("\\[") ||
            HEADING.matches(next) || RULE.matches(next) || next.startsWith(">") ||
            isTableHeader(lines, index + 1) || BULLET.matches(lines[index + 1]) || ORDERED.matches(lines[index + 1])
    }

    /** Parses one standalone `![alt](destination "title")` line without changing source identity. */
    private fun standaloneImage(line: String): MarkdownBlock.Image? {
        if (!line.startsWith("![")) return null
        val labelEnd = line.indexOf(']', startIndex = 2)
        if (labelEnd < 2 || labelEnd + 2 >= line.length || line[labelEnd + 1] != '(' || !line.endsWith(')')) {
            return null
        }
        val label = line.substring(2, labelEnd)
        val contents = line.substring(labelEnd + 2, line.lastIndex).trim()
        if (contents.isEmpty()) return null

        val destinationEnd = when {
            contents.startsWith('<') -> contents.indexOf('>').takeIf { it > 0 }?.plus(1) ?: return null
            else -> {
                var depth = 0
                var index = 0
                while (index < contents.length) {
                    when (val char = contents[index]) {
                        '\\' -> index++
                        '(' -> depth++
                        ')' -> if (depth > 0) depth-- else break
                        else -> if (char.isWhitespace() && depth == 0) break
                    }
                    index++
                }
                index
            }
        }
        if (destinationEnd <= 0) return null
        val rawDestination = contents.substring(0, destinationEnd).removeSurrounding("<", ">").trim()
        if (rawDestination.isEmpty()) return null
        val rawTitle = contents.substring(destinationEnd).trim()
        val title = when {
            rawTitle.length >= 2 && rawTitle.first() == '"' && rawTitle.last() == '"' -> rawTitle.substring(1, rawTitle.lastIndex)
            rawTitle.length >= 2 && rawTitle.first() == '\'' && rawTitle.last() == '\'' -> rawTitle.substring(1, rawTitle.lastIndex)
            rawTitle.length >= 2 && rawTitle.first() == '(' && rawTitle.last() == ')' -> rawTitle.substring(1, rawTitle.lastIndex)
            rawTitle.isEmpty() -> ""
            else -> return null
        }
        return MarkdownBlock.Image(source = rawDestination, alt = label, title = title)
    }

    private fun alignment(cell: String): MarkdownTableAlign? = when {
        cell.startsWith(":") && cell.endsWith(":") -> MarkdownTableAlign.CENTER
        cell.endsWith(":") -> MarkdownTableAlign.RIGHT
        cell.startsWith(":") -> MarkdownTableAlign.LEFT
        else -> null
    }

    private fun leadingIndent(line: String): Int = line.takeWhile { it == ' ' || it == '\t' }.length

    // ------------------------------------------------------------------ inline

    /** Parses the inline runs of one text run. */
    internal fun inlines(text: String): List<MarkdownInline> {
        val out = mutableListOf<MarkdownInline>()
        val buffer = StringBuilder()
        fun flush() {
            if (buffer.isEmpty()) return
            out.add(MarkdownInline.Text(buffer.toString()))
            buffer.clear()
        }

        var i = 0
        while (i < text.length) {
            when {
                text.startsWith("**", i) -> {
                    val end = text.indexOf("**", i + 2)
                    if (end > i + 2) {
                        flush()
                        out.add(MarkdownInline.Strong(inlines(text.substring(i + 2, end))))
                        i = end + 2
                    } else {
                        buffer.append(text[i++])
                    }
                }

                text.startsWith("~~", i) -> {
                    val end = text.indexOf("~~", i + 2)
                    if (end > i + 2) {
                        flush()
                        out.add(MarkdownInline.Delete(inlines(text.substring(i + 2, end))))
                        i = end + 2
                    } else {
                        buffer.append(text[i++])
                    }
                }

                text[i] == '`' -> {
                    val end = text.indexOf('`', i + 1)
                    if (end > i + 1) {
                        flush()
                        out.add(MarkdownInline.Code(text.substring(i + 1, end)))
                        i = end + 1
                    } else {
                        buffer.append(text[i++])
                    }
                }

                text.startsWith(FOOTNOTE_SENTINEL, i) -> {
                    val end = text.indexOf(FOOTNOTE_SENTINEL_END, i + FOOTNOTE_SENTINEL.length)
                    if (end > i) {
                        flush()
                        out.add(
                            MarkdownInline.Footnote(
                                text.substring(i + FOOTNOTE_SENTINEL.length, end),
                            ),
                        )
                        i = end + FOOTNOTE_SENTINEL_END.length
                    } else {
                        buffer.append(text[i++])
                    }
                }

                text.startsWith("![", i) -> {
                    val label = text.indexOf(']', i + 2)
                    if (label > i && label + 1 < text.length && text[label + 1] == '(') {
                        val close = text.indexOf(')', label + 2)
                        if (close > label) {
                            flush()
                            out.add(MarkdownInline.Image(text.substring(i + 2, label)))
                            i = close + 1
                        } else {
                            buffer.append(text[i++])
                        }
                    } else {
                        buffer.append(text[i++])
                    }
                }

                text[i] == '[' -> {
                    val label = text.indexOf(']', i + 1)
                    if (label > i && label + 1 < text.length && text[label + 1] == '(') {
                        val close = text.indexOf(')', label + 2)
                        if (close > label) {
                            flush()
                            out.add(
                                MarkdownInline.Link(
                                    destination = text.substring(label + 2, close).trim(),
                                    children = inlines(text.substring(i + 1, label)),
                                ),
                            )
                            i = close + 1
                        } else {
                            buffer.append(text[i++])
                        }
                    } else {
                        buffer.append(text[i++])
                    }
                }

                text.startsWith("\\(", i) -> {
                    val end = text.indexOf("\\)", i + 2)
                    if (end > i + 2) {
                        flush()
                        out.add(MarkdownInline.Math(text.substring(i + 2, end)))
                        i = end + 2
                    } else {
                        buffer.append(text[i++])
                    }
                }

                // Inline `$…$`; a `$$` pair is display math and is handled by the
                // block parser, so it is left alone here.
                text[i] == '$' && !text.startsWith("$$", i) -> {
                    val end = text.indexOf('$', i + 1)
                    val content = if (end > i + 1) text.substring(i + 1, end) else ""
                    if (end > i + 1 && !content.contains('\n') && !content.startsWith("$")) {
                        flush()
                        out.add(MarkdownInline.Math(content))
                        i = end + 1
                    } else {
                        buffer.append(text[i++])
                    }
                }

                text[i] == '*' -> {
                    val end = text.indexOf('*', i + 1)
                    if (end > i + 1) {
                        flush()
                        out.add(MarkdownInline.Emphasis(inlines(text.substring(i + 1, end))))
                        i = end + 1
                    } else {
                        buffer.append(text[i++])
                    }
                }

                else -> buffer.append(text[i++])
            }
        }
        flush()
        return out
    }

    private const val FENCE: String = "```"
    private const val FOOTNOTE_HEADING: String = "脚注"
    private const val FOOTNOTE_SENTINEL: String = "DSHFOOTNOTE"
    private const val FOOTNOTE_SENTINEL_END: String = "END"

    private val FOOTNOTE_DEFINITION = Regex("""^\[\^([^\]]+)\]:\s*(.*)$""")
    private val DELIMITER_CELL = Regex("""^:?-{1,}:?$""")
    private val HEADING = Regex("""^(#{1,6})\s+(.*)$""")
    private val RULE = Regex("""^(?:-{3,}|\*{3,}|_{3,})$""")
    private val BULLET = Regex("""^\s*[-*+]\s+(.*)$""")
    private val ORDERED = Regex("""^\s*(\d{1,9})[.)]\s+(.*)$""")
    private val TASK = Regex("""^\[([ xX])]\s+(.*)$""")
}

/**
 * Parses [markdown] and falls back to one plain-text paragraph if the parser
 * fails for any reason, including a [StackOverflowError] from hostile nesting.
 * The original source stays on screen instead of taking the app down.
 *
 * @param markdown the projected answer body.
 * @param parse the parser seam; production callers use [MarkdownParser.parse].
 */
internal fun parseMarkdownOrPlain(
    markdown: String,
    parse: (String) -> List<MarkdownBlock> = MarkdownParser::parse,
): List<MarkdownBlock> = runCatching { parse(markdown) }.getOrElse {
    listOf(MarkdownBlock.Paragraph(listOf(MarkdownInline.Text(markdown))))
}

/**
 * Routes external links, app-resolved resource URIs, and safe relative workspace
 * paths without converting native resource schemes into guessed local paths.
 */
internal fun markdownLinkTarget(destination: String): MarkdownLinkTarget? {
    val trimmed = destination.trim()
    if (trimmed.isEmpty() || trimmed.any(Char::isISOControl)) return null
    val uri = runCatching { URI(trimmed) }.getOrNull() ?: return null
    val scheme = uri.scheme?.lowercase()
    if (scheme != null) {
        if (scheme in EXTERNAL_MARKDOWN_SCHEMES) return MarkdownLinkTarget.Uri(trimmed)
        if (scheme !in WORKSPACE_MARKDOWN_SCHEMES) return null
        if (!isSafeWorkspaceUri(uri, scheme)) return null
        return MarkdownLinkTarget.ResourceUri(trimmed)
    }
    if (trimmed.startsWith('/') || trimmed.startsWith('\\') || ':' in trimmed) return null
    val path = trimmed.replace('\\', '/')
    if (path.split('/').any { it == ".." || it == "." || it.isEmpty() }) return null
    return MarkdownLinkTarget.WorkspacePath(path)
}

internal sealed interface MarkdownLinkTarget {
    public data class Uri(public val value: String) : MarkdownLinkTarget
    public data class WorkspacePath(public val value: String) : MarkdownLinkTarget
    /** A native resource address that only the host can resolve in the right scope. */
    public data class ResourceUri(public val value: String) : MarkdownLinkTarget
}

private val EXTERNAL_MARKDOWN_SCHEMES = setOf("http", "https", "mailto")
private val WORKSPACE_MARKDOWN_SCHEMES = setOf("file", "sandbox", "dsh-resource")

/** Validates native resource URI structure but preserves its complete identity. */
private fun isSafeWorkspaceUri(uri: URI, scheme: String): Boolean {
    if (uri.rawQuery != null || uri.rawFragment != null) return false
    val path = when (scheme) {
        "file", "sandbox" -> {
            if (!uri.rawAuthority.isNullOrEmpty()) return false
            if (scheme == "sandbox" && uri.isOpaque) uri.schemeSpecificPart else uri.path.orEmpty()
        }
        "dsh-resource" -> {
            if (uri.host?.lowercase() != "file") return false
            val segments = uri.path.orEmpty().split('/').filter(String::isNotEmpty)
            val tail = when (segments.firstOrNull()) {
                "session" -> if (segments.size >= 3) segments.drop(2) else return false
                "absolute" -> if (segments.size >= 2) segments.drop(1) else return false
                else -> return false
            }
            val joined = tail.joinToString("/")
            if (joined.isEmpty() || joined == "dsh/workspace") return false
            if (joined.startsWith("dsh/") && !joined.startsWith("dsh/workspace/")) return false
            uri.path.orEmpty()
        }
        else -> return false
    }
    val components = path.split('/').filter(String::isNotEmpty)
    return components.isNotEmpty() && components.none { it == "." || it == ".." }
}
