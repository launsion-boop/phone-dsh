// SPDX-License-Identifier: MIT
package com.phonedsh.bot.session

import java.text.BreakIterator

/**
 * The Bot VFS root (`session-lifecycle.md` §2.1/§2.2).
 *
 * This is the P27 implementation of the frozen rule. `:bot` already has
 * `com.phonedsh.bot.attachments.BotWorkspaceLayout`, but its truncation counts
 * UTF-16 code units; §2.1 step 5 counts extended grapheme clusters, and the
 * shared `grapheme-truncation` vector exercises 64 decomposed `e`+acute pairs
 * (128 UTF-16 units). Reusing that implementation would fail the frozen
 * vector, so the session lane implements the contract here. See the handoff's
 * "Needed outside my scope" for the follow-up on the attachments copy.
 */
public object BotSessionWorkspace {
    /** `BotWorkspaceLayout.defaultBotDataDirectory`. */
    public const val DEFAULT_BOT_DATA_DIRECTORY: String = "/dsh/workspace/.dshbot"

    /** `<dataDirectory>/agents/<safePathComponent(botId)>` (§2.2). */
    public fun botRoot(
        botId: String,
        dataDirectory: String = DEFAULT_BOT_DATA_DIRECTORY,
    ): String = "${normalizedDataDirectory(dataDirectory)}/agents/${safePathComponent(botId)}"

    /**
     * §2.1: keep Unicode general categories `L*`, `M*`, `N*` and `.`, `_`, `-`
     * unchanged; replace every other scalar with `_`; fall back to `bot` for
     * `""`, `"."` and `".."`; finally truncate to 64 extended grapheme
     * clusters. One output scalar per input scalar.
     */
    public fun safePathComponent(raw: String): String {
        val output = StringBuilder()
        var index = 0
        while (index < raw.length) {
            val codePoint = raw.codePointAt(index)
            val type = Character.getType(codePoint)
            val kept = type == Character.UPPERCASE_LETTER.toInt() ||
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
                codePoint == '.'.code ||
                codePoint == '_'.code ||
                codePoint == '-'.code
            if (kept) output.appendCodePoint(codePoint) else output.append('_')
            index += Character.charCount(codePoint)
        }
        var value = output.toString()
        if (value.isEmpty() || value == "." || value == "..") value = "bot"
        return prefixGraphemeClusters(value, 64)
    }

    private fun prefixGraphemeClusters(value: String, count: Int): String {
        val iterator = BreakIterator.getCharacterInstance()
        iterator.setText(value)
        var boundary = iterator.first()
        var remaining = count
        while (remaining > 0) {
            val next = iterator.next()
            if (next == BreakIterator.DONE) return value
            boundary = next
            remaining--
        }
        return value.substring(0, boundary)
    }

    private fun normalizedDataDirectory(raw: String): String {
        var value = raw
        while (value.length > 1 && value.endsWith("/")) value = value.dropLast(1)
        return value
    }
}
