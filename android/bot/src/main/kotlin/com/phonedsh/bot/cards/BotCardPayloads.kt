// SPDX-License-Identifier: MIT
package com.phonedsh.bot.cards

import com.phonedsh.agentcore.JsonArray
import com.phonedsh.agentcore.JsonBool
import com.phonedsh.agentcore.JsonNumber
import com.phonedsh.agentcore.JsonObject
import com.phonedsh.agentcore.JsonString
import com.phonedsh.agentcore.JsonValue
import com.phonedsh.bot.BotJson
import com.phonedsh.bot.optionalString
import com.phonedsh.bot.requiredArray
import java.net.URI
import java.security.MessageDigest
import kotlin.math.roundToInt

/** A card argument failed the frozen builder rules. */
public class BotCardPayloadException(message: String) : Exception(message)

/**
 * Port of Swift `BotCardPayloads` for the P0 card tools in
 * `card-payload.json` + `card-payload.phone.json`.
 *
 * The host owns option identity: `optionID` values are `o0…oN` assigned after
 * recommendation normalization, the single recommended choice is moved to the
 * front, a `danger` choice is never recommended, and the content-card `final`
 * control flag is validated then stripped from the payload.
 */
public object BotCardPayloads {
    /** The five content cards that accept the optional `final` control flag. */
    public val CONTENT_CARD_NAMES: Set<String> = setOf(
        "show_attachment", "show_document", "show_progress", "show_checklist", "show_link",
    )

    public val P0_CARD_TOOLS: Set<String> = setOf(
        "ask_user", "show_next_steps", "show_attachment", "show_document",
        "show_progress", "show_checklist", "show_link",
    )

    public fun build(tool: String, arguments: JsonValue): JsonValue {
        val args = (arguments as? JsonObject)?.members
            ?: invalid("arguments must be an object")
        contentCardFinal(tool, arguments)
        val card: JsonObject = when (tool) {
            "ask_user" -> question(args)
            "show_next_steps" -> steps(args)
            "show_attachment" -> attachment(args)
            "show_document" -> document(args)
            "show_progress" -> progress(args)
            "show_checklist" -> checklist(args)
            "show_link" -> links(args)
            else -> invalid("unknown or non-P0 card tool: $tool")
        }
        return BotJson.objectOf("ok" to JsonBool(true), "card" to card)
    }

    /**
     * `final` is input-only control metadata. It is validated as a JSON boolean
     * and intentionally stripped from the card payload. Tools without the flag
     * (including `ask_user`/`show_next_steps`) always return false.
     */
    public fun contentCardFinal(tool: String, arguments: JsonValue): Boolean {
        if (tool !in CONTENT_CARD_NAMES) return false
        val args = (arguments as? JsonObject)?.members
            ?: invalid("arguments must be an object")
        val raw = args["final"] ?: return false
        return (raw as? JsonBool)?.value ?: invalid("final 必须是 boolean。")
    }

    private fun question(args: Map<String, JsonValue>): JsonObject {
        val question = requiredString(args, "question")
        val rawOptions = requiredArray(args, "options")
        if (rawOptions.size !in 2..4) invalid("ask_user 需要 2–4 个 options。")
        val options = rawOptions.mapIndexedNotNull { index, value ->
            val option = normalizedChoice(value, "options[$index]")
            if (isSyntheticOther(option)) null else option
        }
        if (options.size !in 2..4) invalid("ask_user 需要 2–4 个有效 options。")
        val card = LinkedHashMap<String, JsonValue>()
        card["cardType"] = JsonString("question")
        card["question"] = JsonString(question)
        card["options"] = JsonArray(assignOptionIDs(normalizeRecommendations(options)))
        optionalString(args, "helpText")?.let { card["helpText"] = JsonString(it) }
        return JsonObject(card)
    }

    private fun steps(args: Map<String, JsonValue>): JsonObject {
        val rawSteps = requiredArray(args, "steps")
        if (rawSteps.size !in 2..4) invalid("show_next_steps 需要 2–4 个 steps。")
        val steps = rawSteps.mapIndexedNotNull { index, value ->
            if (value is JsonString) {
                val label = value.value.trim()
                if (label.isEmpty()) invalid("steps[$index] 不能为空。")
                val step = linkedMapOf<String, JsonValue>("label" to JsonString(label))
                if (isSyntheticOther(step)) null else step
            } else {
                val step = normalizedChoice(value, "steps[$index]")
                if (isSyntheticOther(step)) null else step
            }
        }
        if (steps.size !in 2..4) invalid("show_next_steps 需要 2–4 个有效 steps。")
        val card = LinkedHashMap<String, JsonValue>()
        card["cardType"] = JsonString("steps")
        card["steps"] = JsonArray(assignOptionIDs(normalizeRecommendations(steps)))
        return JsonObject(card)
    }

    private fun normalizedChoice(value: JsonValue, path: String): MutableMap<String, JsonValue> {
        val raw = requireObject(value, path)
        val normalized = LinkedHashMap<String, JsonValue>()
        normalized["label"] = JsonString(requiredString(raw, "label"))
        optionalString(raw, "value")?.let { normalized["value"] = JsonString(it) }
        optionalString(raw, "description")?.let { normalized["description"] = JsonString(it) }
        raw["style"]?.let { styleValue ->
            val style = (styleValue as? JsonString)?.value ?: invalid("$path.style 不合法。")
            val lowered = style.lowercase()
            normalized["style"] = JsonString(
                if (lowered in setOf("primary", "default", "danger")) lowered else "default")
        }
        if ((raw["recommended"] as? JsonBool)?.value == true) {
            normalized["recommended"] = JsonBool(true)
        }
        return normalized
    }

    private fun normalizeRecommendations(
        values: List<MutableMap<String, JsonValue>>,
    ): List<Map<String, JsonValue>> {
        val first = values.indexOfFirst { choice ->
            val style = (choice["style"] as? JsonString)?.value
            style != "danger" && ((choice["recommended"] as? JsonBool)?.value == true || style == "primary")
        }
        val ordered = values.toMutableList()
        if (first >= 0) {
            val recommended = ordered.removeAt(first)
            ordered.add(0, recommended)
        }
        return ordered.mapIndexed { index, value ->
            val choice = LinkedHashMap(value)
            if (index == 0 && first >= 0) {
                choice["recommended"] = JsonBool(true)
            } else {
                choice.remove("recommended")
                if ((choice["style"] as? JsonString)?.value == "primary") {
                    choice["style"] = JsonString("default")
                }
            }
            choice
        }
    }

    /** The host owns option identity; numbering happens after normalization so the first is `o0`. */
    private fun assignOptionIDs(values: List<Map<String, JsonValue>>): List<JsonValue> =
        values.mapIndexed { index, value ->
            val choice = LinkedHashMap(value)
            choice["id"] = JsonString("o$index")
            JsonObject(choice)
        }

    private fun isSyntheticOther(choice: Map<String, JsonValue>): Boolean {
        val label = (choice["label"] as? JsonString)?.value?.trim()?.lowercase() ?: return false
        return label in setOf("其他", "其它", "other")
    }

    private fun attachment(args: Map<String, JsonValue>): JsonObject {
        val path = requiredString(args, "path")
        val card = LinkedHashMap<String, JsonValue>()
        card["cardType"] = JsonString("attachment")
        card["path"] = JsonString(path)
        optionalString(args, "caption")?.let { card["caption"] = JsonString(it) }
        return JsonObject(card)
    }

    private fun document(args: Map<String, JsonValue>): JsonObject {
        val path = optionalString(args, "path")
        val content = optionalString(args, "content")
        if (path == null && content == null) invalid("show_document 需要 path 或 content。")
        val title = optionalString(args, "title")
            ?: path?.let(::lastPathComponent)
            ?: firstHeading(content ?: "")
            ?: "Document"
        val kind = optionalString(args, "kind")
            ?: if (path?.lowercase()?.endsWith(".pdf") == true) "pdf" else "markdown"
        val labels = mapOf(
            "document" to "Document", "markdown" to "Markdown", "table" to "Table",
            "pdf" to "PDF", "code" to "Code", "library" to "文件庫",
        )
        val card = LinkedHashMap<String, JsonValue>()
        card["cardType"] = JsonString("document")
        card["title"] = JsonString(title)
        card["docKind"] = JsonString(kind)
        card["docTypeLabel"] = JsonString(optionalString(args, "kindLabel") ?: labels[kind] ?: kind)
        optionalString(args, "summary")?.let { card["summary"] = JsonString(it) }
        path?.let { card["path"] = JsonString(it) }
        content?.let { card["content"] = JsonString(it) }
        val fileName = optionalString(args, "fileName") ?: path?.let(::lastPathComponent)
        if (fileName != null) card["fileName"] = JsonString(fileName)
        optionalString(args, "size")?.let { card["size"] = JsonString(it) }
        val rawToc = args["toc"]
        if (rawToc != null) {
            val values = (rawToc as? JsonArray)?.values ?: invalid("toc 必须是字符串数组。")
            val toc = values.map { value ->
                val heading = (value as? JsonString)?.value
                if (heading.isNullOrEmpty()) invalid("toc 必须是字符串数组。")
                heading
            }
            card["toc"] = JsonArray(toc.take(6).map(::JsonString))
        } else {
            markdownHeadings(content ?: "")?.let { headings ->
                card["toc"] = JsonArray(headings.take(6).map(::JsonString))
            }
        }
        args["parseHeadings"]?.let { card["parseHeadings"] = JsonBool(boolean(it, "parseHeadings")) }
        return JsonObject(card)
    }

    private fun progress(args: Map<String, JsonValue>): JsonObject {
        val title = optionalString(args, "title") ?: invalid("show_progress 需要 title。")
        if (title.length > 80) invalid("show_progress title 最多 80 字。")
        val state = optionalString(args, "state") ?: "running"
        if (state !in setOf("running", "done", "paused", "failed", "cancelled")) {
            invalid("show_progress state 不合法。")
        }
        val steps = ArrayList<MutableMap<String, JsonValue>>()
        args["steps"]?.let { raw ->
            val values = (raw as? JsonArray)?.values
            if (values == null || values.size > 8) invalid("show_progress steps 最多 8 项。")
            for ((index, value) in values.withIndex()) {
                val step = requireObject(value, "steps[$index]")
                val label = requiredString(step, "label")
                val stepState = (step["state"] as? JsonString)?.value ?: "pending"
                if (stepState !in setOf("pending", "active", "done", "failed", "skipped")) {
                    invalid("steps[$index].state 不合法。")
                }
                val normalized = LinkedHashMap<String, JsonValue>()
                normalized["id"] = JsonString("step-$index")
                normalized["label"] = JsonString(label)
                normalized["state"] = JsonString(stepState)
                optionalString(step, "detail")?.let { normalized["detail"] = JsonString(it) }
                steps += normalized
            }
        }
        if (steps.none { (it["state"] as? JsonString)?.value == "active" }) {
            val firstPending = steps.indexOfFirst { (it["state"] as? JsonString)?.value == "pending" }
            if (firstPending >= 0) steps[firstPending]["state"] = JsonString("active")
        }
        val percent: Int = if (args["percent"] != null) {
            val value = integer(args["percent"]!!, "percent")
            if (value !in 0..100) invalid("percent 必须在 0…100。")
            value
        } else if (state == "done") {
            100
        } else if (steps.isNotEmpty()) {
            val complete = steps.count {
                (it["state"] as? JsonString)?.value in setOf("done", "skipped")
            }
            (complete.toDouble() / steps.size * 100.0).roundToInt()
        } else {
            0
        }
        val cardKey = optionalString(args, "cardKey") ?: "progress:" + digest(title)
        if (cardKey.length > 64 || cardKey.isEmpty()) invalid("cardKey 最多 64 字且不能为空。")
        val card = LinkedHashMap<String, JsonValue>()
        card["cardType"] = JsonString("progress")
        card["title"] = JsonString(title)
        card["state"] = JsonString(state)
        card["cardKey"] = JsonString(cardKey)
        card["percent"] = JsonNumber((if (state == "done") 100 else percent).toString())
        if (steps.isNotEmpty()) card["steps"] = JsonArray(steps.map { JsonObject(it) })
        optionalString(args, "summary")?.let { card["summary"] = JsonString(it) }
        optionalString(args, "eta")?.let { card["eta"] = JsonString(it) }
        return JsonObject(card)
    }

    private fun checklist(args: Map<String, JsonValue>): JsonObject {
        val title = requiredString(args, "title")
        val values = requiredArray(args, "items")
        if (values.size !in 1..12) invalid("show_checklist 需要 1–12 个 items。")
        val items = values.mapIndexed { index, value ->
            val item = requireObject(value, "items[$index]")
            val text = requiredString(item, "text")
            val normalized = LinkedHashMap<String, JsonValue>()
            normalized["id"] = JsonString("item-$index")
            normalized["text"] = JsonString(text)
            normalized["done"] = JsonBool((item["done"] as? JsonBool)?.value ?: false)
            optionalString(item, "note")?.let { normalized["note"] = JsonString(it) }
            JsonObject(normalized)
        }
        val card = LinkedHashMap<String, JsonValue>()
        card["cardType"] = JsonString("checklist")
        card["title"] = JsonString(title)
        card["items"] = JsonArray(items)
        optionalString(args, "summary")?.let { card["summary"] = JsonString(it) }
        args["interactive"]?.let { card["interactive"] = JsonBool(boolean(it, "interactive")) }
        return JsonObject(card)
    }

    private fun links(args: Map<String, JsonValue>): JsonObject {
        val values = requiredArray(args, "links")
        if (values.size > 4) invalid("show_link 最多 4 个 links。")
        val links = values.mapIndexedNotNull { index, value ->
            val link = requireObject(value, "links[$index]")
            val raw = (link["url"] as? JsonString)?.value
            val uri = raw?.let(::parseHttpUrl)
            if (raw == null || uri == null || raw.length > 2_048) return@mapIndexedNotNull null
            val host = uri.host ?: return@mapIndexedNotNull null
            val site = (link["site"] as? JsonString)?.value ?: host
            val normalized = LinkedHashMap<String, JsonValue>()
            normalized["url"] = JsonString(raw)
            normalized["title"] = JsonString((link["title"] as? JsonString)?.value ?: site)
            normalized["site"] = JsonString(site)
            normalized["kind"] = JsonString((link["kind"] as? JsonString)?.value ?: "other")
            optionalString(link, "description")?.let { normalized["description"] = JsonString(it) }
            JsonObject(normalized)
        }
        if (links.isEmpty()) invalid("show_link 需要至少一個合法的 http(s) links[] {url}。")
        val card = LinkedHashMap<String, JsonValue>()
        card["cardType"] = JsonString("link")
        card["links"] = JsonArray(links)
        optionalString(args, "title")?.let { card["title"] = JsonString(it) }
        return JsonObject(card)
    }

    private fun parseHttpUrl(raw: String): URI? {
        val uri = try {
            URI(raw)
        } catch (_: Exception) {
            return null
        }
        val scheme = uri.scheme?.lowercase() ?: return null
        if (scheme !in setOf("http", "https")) return null
        if (uri.host == null) return null
        return uri
    }

    private fun lastPathComponent(path: String): String {
        val trimmed = path.trimEnd('/')
        return if (trimmed.isEmpty()) "/" else trimmed.substringAfterLast('/')
    }

    private fun firstHeading(markdown: String): String? = markdownHeadings(markdown)?.firstOrNull()

    private fun markdownHeadings(markdown: String): List<String>? {
        val headings = markdown.split('\n').mapNotNull { rawLine ->
            val text = rawLine.trim()
            if (!text.startsWith("#")) return@mapNotNull null
            val value = text.dropWhile { it == '#' }.trim()
            value.ifEmpty { null }
        }
        return if (headings.isEmpty()) null else headings.take(6)
    }

    private fun digest(text: String): String {
        val bytes = MessageDigest.getInstance("SHA-256").digest(text.toByteArray(Charsets.UTF_8))
        return bytes.joinToString("") { byte ->
            (byte.toInt() and 0xFF).toString(16).padStart(2, '0')
        }.take(24)
    }

    private fun requireObject(value: JsonValue, path: String): Map<String, JsonValue> =
        (value as? JsonObject)?.members ?: invalid("$path 必须是对象。")

    private fun requiredString(members: Map<String, JsonValue>, key: String): String =
        optionalString(members, key) ?: invalid("$key 不能为空。")

    private fun optionalString(members: Map<String, JsonValue>, key: String): String? {
        val raw = members[key] ?: return null
        val value = (raw as? JsonString)?.value ?: invalid("$key 必须是字符串。")
        val text = value.trim()
        return text.ifEmpty { null }
    }

    private fun requiredArray(members: Map<String, JsonValue>, key: String): List<JsonValue> =
        (members[key] as? JsonArray)?.values ?: invalid("$key 必须是数组。")

    private fun boolean(value: JsonValue, path: String): Boolean =
        (value as? JsonBool)?.value ?: invalid("$path 必须是 boolean。")

    private fun integer(value: JsonValue, path: String): Int {
        val number = (value as? JsonNumber)?.asLongOrNull() ?: invalid("$path 必须是整数。")
        if (number < Int.MIN_VALUE || number > Int.MAX_VALUE) invalid("$path 必须是整数。")
        return number.toInt()
    }

    private fun invalid(message: String): Nothing = throw BotCardPayloadException(message)
}
