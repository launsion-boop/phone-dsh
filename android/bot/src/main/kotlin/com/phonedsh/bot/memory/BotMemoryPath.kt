// SPDX-License-Identifier: MIT
package com.phonedsh.bot.memory

import java.text.BreakIterator

/**
 * Unicode scalar and grapheme helpers shared by the memory limits. The v2
 * contract counts Unicode scalars everywhere (paths, INDEX.md, snippets,
 * migration budgets), never UTF-16 units, so astral characters count as one.
 */
public object BotMemoryText {
    /** Number of Unicode code points, matching Swift `unicodeScalars.count`. */
    public fun scalarCount(text: String): Int = text.codePointCount(0, text.length)

    public fun utf16Count(text: String): Int = text.length

    public fun prefixScalars(text: String, count: Int): String {
        if (count <= 0) return ""
        val target = minOf(count, scalarCount(text))
        var cpCount = 0
        var index = 0
        while (index < text.length && cpCount < target) {
            index += Character.charCount(text.codePointAt(index))
            cpCount += 1
        }
        return text.substring(0, index)
    }

    public fun isWhitespace(codePoint: Int): Boolean =
        Character.isWhitespace(codePoint) || Character.isSpaceChar(codePoint) || codePoint == 0x85

    public fun trimWhitespace(text: String): String {
        var start = 0
        while (start < text.length) {
            val cp = text.codePointAt(start)
            if (!isWhitespace(cp)) break
            start += Character.charCount(cp)
        }
        var end = text.length
        while (end > start) {
            val cp = text.codePointBefore(end)
            if (!isWhitespace(cp)) break
            end -= Character.charCount(cp)
        }
        return text.substring(start, end)
    }

    public fun trimEnd(text: String): String {
        var end = text.length
        while (end > 0) {
            val cp = text.codePointBefore(end)
            if (!isWhitespace(cp)) break
            end -= Character.charCount(cp)
        }
        return text.substring(0, end)
    }

    /**
     * Code-point substring `[start, end)`; callers pass scalar offsets, so a
     * surrogate pair is never split.
     */
    public fun scalarSlice(text: String, start: Int, end: Int): String {
        val total = scalarCount(text)
        val from = start.coerceIn(0, total)
        val to = end.coerceIn(from, total)
        var cpIndex = 0
        var startIndex = text.length
        var endIndex = text.length
        var utf16 = 0
        while (utf16 < text.length) {
            if (cpIndex == from) startIndex = utf16
            if (cpIndex == to) {
                endIndex = utf16
                break
            }
            val cp = text.codePointAt(utf16)
            utf16 += Character.charCount(cp)
            cpIndex += 1
        }
        if (cpIndex == from) startIndex = minOf(startIndex, text.length)
        if (cpIndex == to) endIndex = minOf(endIndex, text.length)
        return text.substring(startIndex.coerceAtMost(endIndex), endIndex)
    }

    private const val ZERO_WIDTH_JOINER = 0x200D

    private fun isGraphemeExtend(codePoint: Int): Boolean {
        if (codePoint == ZERO_WIDTH_JOINER) return true
        if (codePoint == 0xFE0E || codePoint == 0xFE0F) return true
        if (codePoint in 0x1F3FB..0x1F3FF) return true // emoji skin-tone modifiers
        val type = Character.getType(codePoint)
        return type == Character.NON_SPACING_MARK.toInt() ||
            type == Character.COMBINING_SPACING_MARK.toInt() ||
            type == Character.ENCLOSING_MARK.toInt()
    }

    private fun isRegionalIndicator(codePoint: Int): Boolean = codePoint in 0x1F1E6..0x1F1FF

    /**
     * UTF-16 boundaries of extended grapheme clusters. BreakIterator supplies
     * the legacy cluster boundaries; this closes the emoji ZWJ, variation
     * selector, skin-tone and flag pairs that the legacy iterator splits.
     */
    fun graphemeBoundaries(text: String): List<Int> {
        if (text.isEmpty()) return listOf(0)
        val iterator = BreakIterator.getCharacterInstance()
        iterator.setText(text)
        val raw = ArrayList<Int>()
        var position = iterator.first()
        while (position != BreakIterator.DONE) {
            raw += position
            position = iterator.next()
        }
        val boundaries = ArrayList<Int>(raw.size)
        boundaries += 0
        for (index in 1 until raw.size) {
            val boundary = raw[index]
            val previous = boundaries.last()
            val previousCodePoint = if (previous > 0) text.codePointBefore(previous) else -1
            val currentCodePoint = if (boundary < text.length) text.codePointAt(boundary) else -1
            if (previousCodePoint == ZERO_WIDTH_JOINER ||
                currentCodePoint == ZERO_WIDTH_JOINER ||
                (currentCodePoint >= 0 && isGraphemeExtend(currentCodePoint)) ||
                (isRegionalIndicator(previousCodePoint) && isRegionalIndicator(currentCodePoint))
            ) {
                continue
            }
            boundaries += boundary
        }
        if (boundaries.last() != text.length) boundaries += text.length
        return boundaries
    }

    /**
     * Truncates to at most [limit] scalars but only at an extended
     * grapheme-cluster boundary, mirroring the `BotNameValidation.capped`
     * loop while keeping ZWJ emoji whole.
     */
    public fun cappedAtGrapheme(text: String, limit: Int): String {
        if (limit <= 0) return ""
        if (scalarCount(text) <= limit) return text
        val boundaries = graphemeBoundaries(text)
        val out = StringBuilder()
        var used = 0
        var lastEnd = 0
        for (index in 0 until boundaries.size - 1) {
            val start = boundaries[index]
            val end = boundaries[index + 1]
            val clusterScalars = scalarCount(text.substring(start, end))
            if (used + clusterScalars > limit) break
            out.append(text, start, end)
            used += clusterScalars
            lastEnd = end
        }
        return if (lastEnd == 0) "" else out.toString()
    }

    /** First grapheme boundary at or after [scalarOffset], in scalars. */
    public fun graphemeBoundaryAtOrAfter(text: String, scalarOffset: Int): Int {
        if (scalarOffset <= 0) return 0
        val total = scalarCount(text)
        if (scalarOffset >= total) return total
        var scalars = 0
        for (boundary in graphemeBoundaries(text)) {
            if (boundary == 0) continue
            scalars = scalarCount(text.substring(0, boundary))
            if (scalars >= scalarOffset) return scalars
        }
        return total
    }

}

/**
 * Path rules from v2 §1.1: rooted at `user/` or `agent/`, case sensitive,
 * at most 200 scalars total and 64 per segment, no empty/`.`/`..` segments,
 * no backslash or control characters, and no leading/trailing whitespace in
 * a segment. No Unicode normalization is applied.
 */
public object BotMemoryPath {
    public const val MAX_PATH_SCALARS: Int = 200
    public const val MAX_SEGMENT_SCALARS: Int = 64

    public fun scopeOf(path: String): BotMemoryScope? {
        val parts = parse(path, allowRoot = true) ?: return null
        return BotMemoryScope.parse(parts.firstOrNull())
    }

    public fun parse(path: String, allowRoot: Boolean = false): List<String>? {
        if (path.isEmpty() || path.length > MAX_PATH_SCALARS * 2) return null
        if (BotMemoryText.scalarCount(path) > MAX_PATH_SCALARS) return null
        if (path.startsWith("/") || path.endsWith("/")) return null
        val parts = path.split("/")
        if (BotMemoryScope.parse(parts.firstOrNull()) == null) return null
        if (parts.size == 1) return if (allowRoot) parts else null
        for (segment in parts) {
            if (segment.isEmpty() || segment == "." || segment == "..") return null
            if (BotMemoryText.scalarCount(segment) > MAX_SEGMENT_SCALARS) return null
            if (BotMemoryText.trimWhitespace(segment) != segment) return null
            if (segment.contains("\\")) return null
            var offset = 0
            while (offset < segment.length) {
                val cp = segment.codePointAt(offset)
                if (cp < 0x20 || cp == 0x7F) return null
                offset += Character.charCount(cp)
            }
        }
        return parts
    }

    public fun isIndex(path: String): Boolean = path == "user/INDEX.md" || path == "agent/INDEX.md"

    public fun indexOverflow(path: String, content: String): Int? {
        if (!isIndex(path)) return null
        val count = BotMemoryText.scalarCount(content)
        return if (count > BotMemoryLimits.INDEX) count else null
    }

    /** Inbox-only author kinds must write under `agent/inbox/<sessionId>/`. */
    public fun scopeDenial(author: BotMemoryAuthor, path: String): String? {
        if (!author.kind.isInboxOnly) return null
        val session = author.sessionId
        if (session.isNullOrEmpty()) return "memory-scope-denied"
        val prefix = "agent/inbox/$session/"
        if (!path.startsWith(prefix) || path.length <= prefix.length) return "memory-scope-denied"
        return null
    }

    /**
     * `user/` writes need a real user turn and at least one `user` trust
     * reference. A maintainer has no user turn; its boundary is the evidence
     * (`source.kind == "maintenance"`), and only the maintainer principal takes
     * that branch. Host rollback restores an already accepted version.
     */
    public fun userBoundaryError(
        sourceKind: BotMemorySourceKind,
        trust: BotMemoryTrust?,
        path: String,
        authorKind: BotMemoryAuthorKind = BotMemoryAuthorKind.CHAT,
        hostRollback: Boolean = false,
    ): String? {
        if (scopeOf(path) != BotMemoryScope.USER) return null
        if (hostRollback) return null
        if (authorKind == BotMemoryAuthorKind.MAINTAINER || sourceKind == BotMemorySourceKind.MAINTENANCE) {
            if (authorKind != BotMemoryAuthorKind.MAINTAINER ||
                sourceKind != BotMemorySourceKind.MAINTENANCE
            ) {
                return "memory-source-boundary"
            }
            return if (trust == BotMemoryTrust.USER) null else "memory-evidence-required"
        }
        if (sourceKind != BotMemorySourceKind.USER_TURN) return "memory-source-boundary"
        if (trust != null && trust != BotMemoryTrust.USER) return "memory-evidence-required"
        if (trust == null) return "memory-evidence-required"
        return null
    }

    /** The shared `user/` root has one maintainer: the main Bot's. */
    public fun maintenanceScopeDenial(
        author: BotMemoryAuthor,
        path: String,
        isMainBot: Boolean,
    ): String? {
        if (author.kind != BotMemoryAuthorKind.MAINTAINER) return null
        if (isMainBot) return null
        if (scopeOf(path) != BotMemoryScope.USER) return null
        return "memory-scope-denied"
    }
}
