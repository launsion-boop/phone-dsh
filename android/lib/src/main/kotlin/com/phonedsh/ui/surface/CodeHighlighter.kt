// The code card's token highlighter, mirroring the iOS one.
// SPDX-License-Identifier: MIT
//
// Mirror: `NativeCodeHighlighter.swift` (iOS). That file is the *only* syntax
// highlighter the baseline has, and it does not define colours of its own: it
// names four theme tokens (`NativeChatTheme.success` for strings, `.caption` for
// comments, `.warning` for numbers, `.accent` for keywords) and paints the base
// source in `.secondary` (NativeCodeHighlighter.swift:19-27).
//
// So this port adds no new value source either: every ink is read from the
// matching `colors.*` token, and the keyword list and the four regular
// expressions are the baseline's own (NativeCodeHighlighter.swift:7-15, :22-26).
// The application order matches too (strings, comments, numbers, keywords), and
// later passes overwrite earlier ones exactly as `apply(...)` does on iOS — so a
// keyword inside a string ends up in the keyword ink on both platforms.
package com.phonedsh.ui.surface

import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString

/**
 * The iOS highlighter's keyword table, verbatim
 * (`NativeCodeHighlighter.swift:7-15`). Lower-cased on both sides; the lookup
 * lowercases the candidate word.
 */
private val KEYWORDS: Set<String> = setOf(
    "actor", "as", "async", "await", "break", "case", "catch", "class", "const", "continue",
    "def", "default", "defer", "do", "else", "enum", "export", "extends", "false", "final",
    "finally", "for", "from", "func", "function", "guard", "if", "implements", "import", "in",
    "init", "interface", "internal", "is", "let", "namespace", "new", "nil", "nonisolated",
    "null", "open", "operator", "override", "package", "private", "protocol", "public", "raise",
    "return", "self", "static", "struct", "super", "switch", "this", "throw", "throws", "true",
    "try", "typealias", "typeof", "using", "var", "void", "where", "while", "yield",
)

/** The string-literal pattern, verbatim from NativeCodeHighlighter.swift:22. */
private val STRING_PATTERN = Regex("\"(?:\\\\.|[^\"\\\\])*\"|'(?:\\\\.|[^'\\\\])*'")

/** The comment pattern (line, block and hash), verbatim from NativeCodeHighlighter.swift:23. */
private val COMMENT_PATTERN = Regex("//[^\\n]*|/\\*[\\s\\S]*?\\*/|#[^\\n]*")

/** The numeric-literal pattern, verbatim from NativeCodeHighlighter.swift:24. */
private val NUMBER_PATTERN = Regex("\\b(?:0x[0-9a-fA-F]+|\\d+(?:\\.\\d+)?)\\b")

/** The identifier pattern, verbatim from NativeCodeHighlighter.swift:25. */
private val WORD_PATTERN = Regex("\\b[A-Za-z_][A-Za-z0-9_]*\\b")

/**
 * The four inks the highlighter needs, passed in from the theme so this file
 * carries no value of its own.
 *
 * @param string the string-literal ink (iOS `NativeChatTheme.success`).
 * @param comment the comment ink (iOS `NativeChatTheme.caption`).
 * @param number the numeric-literal ink (iOS `NativeChatTheme.warning`).
 * @param keyword the keyword ink (iOS `NativeChatTheme.accent`).
 */
public data class CodeInks(
    public val string: Color,
    public val comment: Color,
    public val number: Color,
    public val keyword: Color,
)

/**
 * Paints [source] with the baseline's four token classes.
 *
 * The returned [AnnotatedString] always carries the full source: highlighting
 * only adds spans, so a token the patterns miss renders in whatever ink the
 * caller gives the text style.
 */
public fun highlightCode(source: String, inks: CodeInks): AnnotatedString {
    val spans = ArrayList<SpanStyle>()
    val starts = ArrayList<Int>()
    val ends = ArrayList<Int>()
    fun paint(pattern: Regex, color: Color) {
        for (match in pattern.findAll(source)) {
            starts.add(match.range.first)
            ends.add(match.range.last + 1)
            spans.add(SpanStyle(color = color))
        }
    }
    // iOS order: strings, comments, numbers, then the keyword table (which wins
    // because `apply` writes the attribute last). Mirrored exactly.
    paint(STRING_PATTERN, inks.string)
    paint(COMMENT_PATTERN, inks.comment)
    paint(NUMBER_PATTERN, inks.number)
    for (match in WORD_PATTERN.findAll(source)) {
        if (match.value.lowercase() in KEYWORDS) {
            starts.add(match.range.first)
            ends.add(match.range.last + 1)
            spans.add(SpanStyle(color = inks.keyword))
        }
    }
    return buildAnnotatedString {
        append(source)
        // Appending in application order keeps the "last write wins" rule.
        for (index in spans.indices) {
            addStyle(spans[index], starts[index], ends[index])
        }
    }
}
