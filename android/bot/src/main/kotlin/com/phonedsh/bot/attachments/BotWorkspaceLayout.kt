// SPDX-License-Identifier: MIT
package com.phonedsh.bot.attachments

/**
 * The VFS layout the Bot runtime owns.
 *
 * Bot sessions run under a private directory tree below the durable
 * `/dsh/workspace` mount. `botRoot` is `<botDataDirectory>/agents/<botID>`,
 * matching the upstream dsh-bot `<dataRoot>/agents/<botID>/` convention.
 * Attachments stay under the session cwd, in the relative
 * `imports/attachments-<messageID>/` layout the directory-import service has
 * always produced.
 */
public object BotWorkspaceLayout {
    /** Default root used by tests and callers that do not supply the app's data directory. */
    public const val DEFAULT_BOT_DATA_DIRECTORY: String = "/dsh/workspace/.dshbot"

    /** `<botDataDirectory>/agents/<safe botID>`. */
    public fun botRoot(
        botId: String,
        dataDirectory: String = DEFAULT_BOT_DATA_DIRECTORY,
    ): String = "${normalizedDataDirectory(dataDirectory)}/agents/${safePathComponent(botId)}"

    /**
     * A single safe path component for an id that becomes a VFS directory.
     * Keeps the value deterministic so the same Bot always maps to one root.
     *
     * `session-lifecycle.md` §2.1: keep Unicode general categories `L*`, `M*`
     * and `N*` plus `.`, `_` and `-`; replace every other scalar with `_`; fall
     * back to `bot` for `""`, `"."` and `".."`; then truncate to 64 extended
     * grapheme clusters. One output scalar per input scalar.
     */
    public fun safePathComponent(raw: String): String {
        val output = StringBuilder()
        var index = 0
        while (index < raw.length) {
            val codePoint = raw.codePointAt(index)
            if (isKeptScalar(codePoint)) output.appendCodePoint(codePoint) else output.append('_')
            index += Character.charCount(codePoint)
        }
        var value = output.toString()
        if (value.isEmpty() || value == "." || value == "..") value = "bot"
        return truncateGraphemeClusters(value, 64)
    }

    /**
     * The one grapheme truncation/count implementation the Bot uses.
     *
     * `java.text.BreakIterator.getCharacterInstance()` on the JDK 17 toolchain
     * splits emoji ZWJ sequences, flags and emoji modifiers into several
     * clusters, so it cannot implement §2.1 step 5. This is the UAX #29 subset
     * the contract needs: GB3–GB5 controls, GB6–GB8 Hangul, GB9/GB9a
     * Extend/SpacingMark, GB9b Prepend, GB11 emoji ZWJ and GB12/GB13 regional
     * indicator pairs. It is shared by the session lane through
     * `BotSessionWorkspace.safePathComponent`.
     */
    internal fun truncateGraphemeClusters(value: String, maximum: Int): String {
        if (maximum <= 0) return ""
        var index = 0
        var clusters = 0
        while (index < value.length) {
            if (clusters == maximum) return value.substring(0, index)
            index = nextGraphemeBoundary(value, index)
            clusters++
        }
        return value
    }

    /** Extended grapheme cluster count, matching Swift's `String.count`. */
    internal fun graphemeClusterCount(value: String): Int {
        var index = 0
        var clusters = 0
        while (index < value.length) {
            index = nextGraphemeBoundary(value, index)
            clusters++
        }
        return clusters
    }

    private fun normalizedDataDirectory(raw: String): String {
        var value = raw
        while (value.length > 1 && value.endsWith("/")) value = value.dropLast(1)
        return value
    }

    private fun isKeptScalar(codePoint: Int): Boolean {
        val type = Character.getType(codePoint)
        return type == Character.UPPERCASE_LETTER.toInt() ||
            type == Character.LOWERCASE_LETTER.toInt() ||
            type == Character.TITLECASE_LETTER.toInt() ||
            type == Character.MODIFIER_LETTER.toInt() ||
            type == Character.OTHER_LETTER.toInt() ||
            type == Character.NON_SPACING_MARK.toInt() ||
            type == Character.ENCLOSING_MARK.toInt() ||
            type == Character.COMBINING_SPACING_MARK.toInt() ||
            type == Character.DECIMAL_DIGIT_NUMBER.toInt() ||
            type == Character.LETTER_NUMBER.toInt() ||
            type == Character.OTHER_NUMBER.toInt() ||
            codePoint == '.'.code || codePoint == '_'.code || codePoint == '-'.code
    }

    private fun nextGraphemeBoundary(value: String, start: Int): Int {
        var index = start
        var previous = OTHER
        var regionalIndicators = 0
        var baseBeforeExtend = OTHER
        var zwjAfterPictographic = false
        while (index < value.length) {
            val codePoint = value.codePointAt(index)
            val current = propertyOf(codePoint)
            if (index > start &&
                breaksBefore(previous, current, regionalIndicators, zwjAfterPictographic)
            ) {
                return index
            }
            when {
                current == ZWJ -> zwjAfterPictographic = baseBeforeExtend == EXTENDED_PICTOGRAPHIC
                current == EXTEND -> zwjAfterPictographic = false
                else -> {
                    baseBeforeExtend = current
                    zwjAfterPictographic = false
                }
            }
            regionalIndicators = if (current == REGIONAL_INDICATOR) {
                if (previous == REGIONAL_INDICATOR) regionalIndicators + 1 else 1
            } else {
                0
            }
            previous = current
            index += Character.charCount(codePoint)
        }
        return value.length
    }

    private fun breaksBefore(
        previous: Int,
        current: Int,
        regionalIndicators: Int,
        zwjAfterPictographic: Boolean,
    ): Boolean {
        if (previous == CR && current == LF) return false
        if (previous == CONTROL || previous == CR || previous == LF) return true
        if (current == CONTROL || current == CR || current == LF) return true
        if (previous == HANGUL_L &&
            (current == HANGUL_L || current == HANGUL_V ||
                current == HANGUL_LV || current == HANGUL_LVT)
        ) {
            return false
        }
        if ((previous == HANGUL_LV || previous == HANGUL_V) &&
            (current == HANGUL_V || current == HANGUL_T)
        ) {
            return false
        }
        if ((previous == HANGUL_LVT || previous == HANGUL_T) && current == HANGUL_T) return false
        if (current == EXTEND || current == ZWJ) return false
        if (current == SPACING_MARK) return false
        if (previous == PREPEND) return false
        if (previous == ZWJ && current == EXTENDED_PICTOGRAPHIC && zwjAfterPictographic) return false
        if (previous == REGIONAL_INDICATOR && current == REGIONAL_INDICATOR &&
            regionalIndicators % 2 == 1
        ) {
            return false
        }
        return true
    }

    private fun propertyOf(codePoint: Int): Int {
        when {
            codePoint == 0x0D -> return CR
            codePoint == 0x0A -> return LF
            codePoint == 0x200D -> return ZWJ
            codePoint == 0x200C -> return EXTEND
            codePoint in 0x1F3FB..0x1F3FF -> return EXTEND
            codePoint in 0xFE00..0xFE0F -> return EXTEND
            codePoint in 0xE0100..0xE01EF -> return EXTEND
            codePoint in 0xE0020..0xE007F -> return EXTEND
            codePoint in 0x1F1E6..0x1F1FF -> return REGIONAL_INDICATOR
            isPrepend(codePoint) -> return PREPEND
            isHangulL(codePoint) -> return HANGUL_L
            isHangulV(codePoint) -> return HANGUL_V
            isHangulT(codePoint) -> return HANGUL_T
            codePoint in 0xAC00..0xD7A3 ->
                return if ((codePoint - 0xAC00) % 28 == 0) HANGUL_LV else HANGUL_LVT
            isExtendedPictographic(codePoint) -> return EXTENDED_PICTOGRAPHIC
        }
        return when (Character.getType(codePoint)) {
            Character.NON_SPACING_MARK.toInt(),
            Character.ENCLOSING_MARK.toInt() -> EXTEND
            Character.COMBINING_SPACING_MARK.toInt() -> SPACING_MARK
            Character.CONTROL.toInt(),
            Character.FORMAT.toInt(),
            Character.LINE_SEPARATOR.toInt(),
            Character.PARAGRAPH_SEPARATOR.toInt() -> CONTROL
            else -> OTHER
        }
    }

    private fun isPrepend(codePoint: Int): Boolean = when (codePoint) {
        0x0600, 0x0601, 0x0602, 0x0603, 0x0604, 0x0605, 0x06DD, 0x070F,
        0x0890, 0x0891, 0x08E2, 0x0D4E, 0x110BD, 0x110CD, 0x1193F, 0x11941,
        0x11A3A, 0x11D46, 0x11F02 -> true
        in 0x111C2..0x111C3, in 0x11A84..0x11A89 -> true
        else -> false
    }

    private fun isHangulL(codePoint: Int): Boolean =
        codePoint in 0x1100..0x115F || codePoint in 0xA960..0xA97C

    private fun isHangulV(codePoint: Int): Boolean =
        codePoint in 0x1160..0x11A7 || codePoint in 0xD7B0..0xD7C6

    private fun isHangulT(codePoint: Int): Boolean =
        codePoint in 0x11A8..0x11FF || codePoint in 0xD7CB..0xD7FB

    private fun isExtendedPictographic(codePoint: Int): Boolean {
        if (codePoint in 0x1F1E6..0x1F1FF) return false
        return codePoint == 0x00A9 || codePoint == 0x00AE ||
            codePoint == 0x203C || codePoint == 0x2049 ||
            codePoint == 0x2122 || codePoint == 0x2139 ||
            codePoint in 0x2194..0x2199 || codePoint in 0x21A9..0x21AA ||
            codePoint in 0x231A..0x231B || codePoint == 0x2328 ||
            codePoint == 0x23CF || codePoint in 0x23E9..0x23F3 ||
            codePoint in 0x23F8..0x23FA || codePoint == 0x24C2 ||
            codePoint in 0x25AA..0x25AB || codePoint == 0x25B6 ||
            codePoint == 0x25C0 || codePoint in 0x25FB..0x25FE ||
            codePoint in 0x2600..0x27BF ||
            codePoint in 0x2934..0x2935 || codePoint in 0x2B05..0x2B07 ||
            codePoint in 0x2B1B..0x2B1C || codePoint == 0x2B50 ||
            codePoint == 0x2B55 || codePoint == 0x3030 || codePoint == 0x303D ||
            codePoint == 0x3297 || codePoint == 0x3299 ||
            codePoint in 0x1F000..0x1F1E5 ||
            codePoint in 0x1F200..0x1FAFF ||
            codePoint in 0x1FC00..0x1FFFD
    }

    // Grapheme_Cluster_Break classes used by the UAX #29 loop above.
    private const val OTHER = 0
    private const val CR = 1
    private const val LF = 2
    private const val CONTROL = 3
    private const val EXTEND = 4
    private const val ZWJ = 5
    private const val REGIONAL_INDICATOR = 6
    private const val PREPEND = 7
    private const val SPACING_MARK = 8
    private const val HANGUL_L = 9
    private const val HANGUL_V = 10
    private const val HANGUL_T = 11
    private const val HANGUL_LV = 12
    private const val HANGUL_LVT = 13
    private const val EXTENDED_PICTOGRAPHIC = 14
}
