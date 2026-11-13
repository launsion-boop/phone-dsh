// SPDX-License-Identifier: MIT
package com.phonedsh.bot.mcp

import com.phonedsh.agentcore.JsonArray
import com.phonedsh.agentcore.JsonNumber
import com.phonedsh.agentcore.JsonObject
import com.phonedsh.agentcore.JsonString
import com.phonedsh.agentcore.JsonValue
import com.phonedsh.bot.cards.BotCardPayloadException
import com.phonedsh.bot.cards.BotCardPayloads

/**
 * The MCP-facing facade over the frozen Kotlin `BotCardPayloads` builder.
 *
 * `cards/BotCardPayloads.kt` is the shared card authority for the upstream
 * golden. The phone contract (`cards.md` §4) additionally fixes the Chinese
 * default document title/labels and the `percent` failure sentence; those
 * defaults are supplied here, before the builder runs, so the two ends do not
 * drift and no string is duplicated from a golden.
 */
public object BotMCPCards {
    public val TOOL_NAMES: Set<String> = BotToolCatalog.CARD_TOOL_NAMES

    public const val ASK_USER_TEXT: String = "已显示提问卡；回合应在此结束，等待用户选择。"
    public const val SHOW_NEXT_STEPS_TEXT: String = "已显示建议下一步卡片；回合应在此结束，等待用户选择。"

    private val DOCUMENT_LABELS: Map<String, String> = mapOf(
        "document" to "文档",
        "markdown" to "Markdown",
        "table" to "表格",
        "pdf" to "PDF",
        "code" to "代码",
        "library" to "文件库",
    )

    public fun build(tool: String, arguments: JsonValue): JsonValue {
        // Match the frozen builder's validation order: `final` is checked
        // before any tool-specific field.
        BotCardPayloads.contentCardFinal(tool, arguments)
        return BotCardPayloads.build(tool, normalize(tool, arguments))
    }

    public fun contentCardFinal(tool: String, arguments: JsonValue): Boolean =
        BotCardPayloads.contentCardFinal(tool, arguments)

    public fun fixedText(tool: String): String? = when (tool) {
        "ask_user" -> ASK_USER_TEXT
        "show_next_steps" -> SHOW_NEXT_STEPS_TEXT
        else -> null
    }

    /**
     * The builder's own validation is authoritative; this only adds the phone
     * defaults it predates. A malformed member is still rejected by the
     * builder with its frozen sentence (or the exact sentence checked here).
     */
    private fun normalize(tool: String, arguments: JsonValue): JsonValue {
        val args = arguments as? JsonObject ?: return arguments
        return when (tool) {
            "show_document" -> normalizeDocument(args)
            "show_progress" -> normalizeProgress(args)
            "show_link" -> normalizeLinks(args)
            else -> args
        }
    }

    private fun normalizeDocument(args: JsonObject): JsonValue {
        val fields = LinkedHashMap(args.members)
        val path = (fields["path"] as? JsonString)?.value
        val content = (fields["content"] as? JsonString)?.value
        val suppliedTitle = (fields["title"] as? JsonString)?.value
        if (!fields.containsKey("title") && suppliedTitle == null && path.isNullOrBlank() && !hasMarkdownHeading(content)) {
            fields["title"] = JsonString("文档")
        }
        if (!fields.containsKey("kindLabel")) {
            val kind = (fields["kind"] as? JsonString)?.value
                ?: if (path?.trim()?.lowercase()?.endsWith(".pdf") == true) "pdf" else "markdown"
            DOCUMENT_LABELS[kind]?.let { fields["kindLabel"] = JsonString(it) }
        }
        // `toc` is an array of non-empty strings; the builder already rejects
        // non-arrays and empty strings, so only whitespace-only entries are
        // normalized to the same frozen failure here.
        (fields["toc"] as? JsonArray)?.values?.forEach { value ->
            val heading = (value as? JsonString)?.value
            if (heading != null && heading.trim().isEmpty()) {
                throw BotCardPayloadException("toc 必须是字符串数组。")
            }
        }
        return JsonObject(fields)
    }

    private fun normalizeProgress(args: JsonObject): JsonValue {
        val fields = LinkedHashMap(args.members)
        val rawPercent = fields["percent"] ?: return JsonObject(fields)
        val number = (rawPercent as? JsonNumber)?.asLongOrNull()
        if (number == null || number !in 0..100) {
            throw BotCardPayloadException("percent 必须在 0…100。")
        }
        return JsonObject(fields)
    }

    private fun normalizeLinks(args: JsonObject): JsonValue {
        val fields = LinkedHashMap(args.members)
        val raw = fields["links"] ?: return JsonObject(fields)
        val values = raw as? JsonArray
            ?: throw BotCardPayloadException("show_link 最多 4 个 links。")
        if (values.values.size > 4) {
            throw BotCardPayloadException("show_link 最多 4 个 links。")
        }
        return JsonObject(fields)
    }

    private fun hasMarkdownHeading(content: String?): Boolean {
        if (content == null) return false
        return content.lineSequence().any { line ->
            val text = line.trim()
            text.startsWith("#") && text.dropWhile { it == '#' }.trim().isNotEmpty()
        }
    }
}
