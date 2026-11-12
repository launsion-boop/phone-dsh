// SPDX-License-Identifier: MIT
package com.phonedsh.bot.attachments

import com.phonedsh.agentcore.JsonValue

/**
 * The model-visible attachment block and its inverse. The markers and the
 * `- {json}` line shape are shared with dsh-bot; only the explanatory sentence
 * is phoneDSH-specific (the files live in the Bot workspace, not on a Mac).
 * Parsing depends on the markers and the JSON lines, not the prose.
 */
public object BotAttachmentPrompt {
    public const val EXPLANATION: String =
        "The user attached these files. They are saved in your workspace; " +
            "read them with your file tools when the task needs their contents."
    public const val OPEN_MARKER: String = "[dshbot-attachments]"
    public const val CLOSE_MARKER: String = "[/dshbot-attachments]"

    /** `""` for an empty list; otherwise the block starts with two newlines. */
    public fun block(items: List<BotAttachment>): String {
        if (items.isEmpty()) return ""
        val lines = items.joinToString("\n") { "- " + jsonLine(it) }
        return "\n\n$OPEN_MARKER\n$EXPLANATION\n$lines\n$CLOSE_MARKER"
    }

    /**
     * Removes the first attachment block from visible text and restores its
     * metadata. Text before the block is kept (trimmed); text after the
     * closing marker is dropped, matching dsh-bot. A missing marker leaves
     * the input untouched.
     */
    public fun parse(text: String): ParsedAttachmentPrompt {
        val start = text.indexOf(OPEN_MARKER)
        if (start < 0) return ParsedAttachmentPrompt(text, emptyList())
        val bodyStart = start + OPEN_MARKER.length
        val end = text.indexOf(CLOSE_MARKER, startIndex = bodyStart)
        if (end < 0) return ParsedAttachmentPrompt(text, emptyList())
        val visible = text.substring(0, start).trim()
        val body = text.substring(bodyStart, end)
        val attachments = ArrayList<BotAttachment>()
        for (rawLine in body.split("\n")) {
            val line = rawLine.trim()
            if (!line.startsWith("- ")) continue
            val json = line.substring(2)
            val item = try {
                BotAttachment.fromJson(JsonValue.parse(json))
            } catch (_: Exception) {
                continue
            }
            attachments += item
        }
        return ParsedAttachmentPrompt(visible, attachments)
    }

    private fun jsonLine(item: BotAttachment): String =
        "{\"name\":${quoted(item.name)},\"path\":${quoted(item.path)},\"size\":${item.size}," +
            "\"mimeType\":${quoted(item.mimeType)},\"kind\":${quoted(item.kind)}}"

    /**
     * Mirrors `JSON.stringify` for the fields the block carries: ordinary
     * UTF-8 stays literal, `/` is not escaped, and only the JSON control
     * escapes are emitted.
     */
    private fun quoted(value: String): String {
        val out = StringBuilder()
        out.append('"')
        for (scalar in value) {
            when (scalar) {
                '"' -> out.append("\\\"")
                '\\' -> out.append("\\\\")
                '\b' -> out.append("\\b")
                '\u000C' -> out.append("\\f")
                '\n' -> out.append("\\n")
                '\r' -> out.append("\\r")
                '\t' -> out.append("\\t")
                in '\u0000'..'\u001F' -> {
                    val hex = scalar.code.toString(16)
                    out.append("\\u")
                    out.append("0".repeat(4 - hex.length))
                    out.append(hex)
                }
                else -> out.append(scalar)
            }
        }
        out.append('"')
        return out.toString()
    }
}

/** Result of [BotAttachmentPrompt.parse]. */
public data class ParsedAttachmentPrompt(
    public val text: String,
    public val attachments: List<BotAttachment>,
)
