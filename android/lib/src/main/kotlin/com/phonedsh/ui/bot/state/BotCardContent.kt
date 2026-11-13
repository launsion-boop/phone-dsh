// SPDX-License-Identifier: MIT
package com.phonedsh.ui.bot.state

import com.phonedsh.agentcore.JsonArray
import com.phonedsh.agentcore.JsonNull
import com.phonedsh.agentcore.JsonObject
import com.phonedsh.agentcore.JsonString
import com.phonedsh.agentcore.JsonValue
import com.phonedsh.bot.BotJson
import com.phonedsh.bot.BotJsonException
import com.phonedsh.bot.attachments.BotAttachment
import com.phonedsh.bot.attachments.BotAttachmentPolicy
import com.phonedsh.bot.rows.BotRow
import com.phonedsh.bot.rows.BotRowBody
import com.phonedsh.bot.rows.BotRowBodyType
import com.phonedsh.bot.rows.BotRowKind
import com.phonedsh.bot.rows.BotWidgetCardType
import java.net.URI

/** One card kind a Bot page can render (`ui-state.md` §2.2/§4.2). */
public enum class BotUICardKind(public val wire: String) {
    QUESTION("question"),
    STEPS("steps"),
    TASK("task"),
    ATTACHMENT("attachment"),
    DOCUMENT("document"),
    PROGRESS("progress"),
    CHECKLIST("checklist"),
    LINK("link"),
    APPROVAL("approval"),
    AUTOMATION("automation"),
    NOTICE("notice"),
    ;

    public companion object {
        public fun fromWire(value: String): BotUICardKind =
            entries.firstOrNull { it.wire == value }
                ?: throw BotJsonException("unknown card kind: $value")
    }
}

/** A parsed interactive choice (`BotUIChoice`). */
public data class BotUIChoice(
    public val id: String,
    public val label: String,
    public val value: String,
    public val description: String?,
    public val recommended: Boolean,
    public val danger: Boolean,
) {
    public fun toJson(): JsonObject = BotJson.objectOf(
        "id" to JsonString(id),
        "label" to JsonString(label),
        "value" to JsonString(value),
        "description" to (description?.let(::JsonString) ?: JsonNull),
        "recommended" to com.phonedsh.agentcore.JsonBool(recommended),
        "danger" to com.phonedsh.agentcore.JsonBool(danger),
    )

    public companion object {
        /** Parses one list entry; [index] is the entry's index in the source array. */
        public fun parse(value: JsonValue, index: Int): BotUIChoice? {
            val raw = (value as? JsonString)?.value
            if (raw != null) {
                val label = raw.trim()
                if (label.isEmpty()) return null
                return BotUIChoice(
                    id = "$index:$label",
                    label = label,
                    value = label,
                    description = null,
                    recommended = false,
                    danger = false,
                )
            }
            val members = (value as? JsonObject)?.members ?: return null
            val rawLabel = JsonSupport.firstString(members, "label", "text", "title", "value")
                ?: return null
            val label = rawLabel.trim()
            if (label.isEmpty()) return null
            val explicitID = JsonSupport.firstString(members, "id", "optionID") ?: ""
            val style = (JsonSupport.string(members["style"]) ?: "default").lowercase()
            return BotUIChoice(
                id = if (explicitID.isEmpty()) "$index:$rawLabel" else explicitID,
                label = label,
                value = JsonSupport.string(members["value"]) ?: label,
                description = JsonSupport.firstString(members, "description", "detail"),
                recommended = (JsonSupport.bool(members["recommended"]) == true ||
                    style == "primary") && style != "danger",
                danger = style == "danger",
            )
        }

        /** `parseList` stops at [limit] and keeps only the first recommended non-danger entry. */
        public fun parseList(value: JsonValue?, limit: Int = 4): List<BotUIChoice> {
            val values = (value as? JsonArray)?.values ?: return emptyList()
            val choices = values.take(limit).mapIndexedNotNull { index, item ->
                parse(item, index)
            }.toMutableList()
            val recommendedIndex = choices.indexOfFirst { it.recommended && !it.danger }
            for (index in choices.indices) {
                choices[index] = choices[index].copy(recommended = index == recommendedIndex)
            }
            return choices
        }
    }
}

/** A parsed progress step (`BotUIProgressStep`). */
public data class BotUIProgressStep(
    public val id: String,
    public val label: String,
    public val state: String,
    public val detail: String?,
) {
    public fun toJson(): JsonObject = BotJson.objectOf(
        "id" to JsonString(id),
        "label" to JsonString(label),
        "state" to JsonString(state),
        "detail" to (detail?.let(::JsonString) ?: JsonNull),
    )

    public companion object {
        private val ALIASES: Map<String, String> = mapOf(
            "in_progress" to "active", "running" to "active", "working" to "active",
            "complete" to "done", "completed" to "done", "success" to "done",
            "ok" to "done", "sent" to "done",
            "error" to "failed", "failure" to "failed", "blocked" to "failed",
        )
        private val ALLOWED: Set<String> = setOf("pending", "active", "done", "failed", "skipped")

        public fun parseList(value: JsonValue?, limit: Int = 8): List<BotUIProgressStep> {
            val values = (value as? JsonArray)?.values ?: return emptyList()
            return values.take(limit).mapIndexedNotNull { index, item ->
                val raw = (item as? JsonString)?.value
                if (raw != null) {
                    if (raw.isEmpty()) return@mapIndexedNotNull null
                    return@mapIndexedNotNull BotUIProgressStep(
                        id = "step-$index", label = raw, state = "pending", detail = null)
                }
                val members = (item as? JsonObject)?.members ?: return@mapIndexedNotNull null
                val label = JsonSupport.firstString(members, "label", "title", "text")
                    ?: return@mapIndexedNotNull null
                val rawState = JsonSupport.string(members["state"])
                    ?: JsonSupport.string(members["status"])
                    ?: "pending"
                val state = ALIASES[rawState] ?: rawState
                BotUIProgressStep(
                    id = JsonSupport.firstString(members, "id") ?: "step-$index",
                    label = label,
                    state = if (state in ALLOWED) state else "pending",
                    detail = JsonSupport.firstString(members, "detail", "meta", "note"),
                )
            }
        }
    }
}

/** A parsed checklist item (`BotUIChecklistItem`). */
public data class BotUIChecklistItem(
    public val id: String,
    public val text: String,
    public val done: Boolean,
    public val note: String?,
    public val synthetic: Boolean,
) {
    public fun toJson(): JsonObject = BotJson.objectOf(
        "id" to JsonString(id),
        "text" to JsonString(text),
        "done" to com.phonedsh.agentcore.JsonBool(done),
        "note" to (note?.let(::JsonString) ?: JsonNull),
        "synthetic" to com.phonedsh.agentcore.JsonBool(synthetic),
    )

    public companion object {
        public fun parseList(value: JsonValue?, limit: Int = 12): List<BotUIChecklistItem> {
            val values = (value as? JsonArray)?.values ?: return emptyList()
            return values.take(limit).mapIndexedNotNull { index, item ->
                val raw = (item as? JsonString)?.value
                if (raw != null) {
                    if (raw.isEmpty()) return@mapIndexedNotNull null
                    return@mapIndexedNotNull BotUIChecklistItem(
                        id = "item-$index", text = raw, done = false, note = null, synthetic = false)
                }
                val members = (item as? JsonObject)?.members ?: return@mapIndexedNotNull null
                val text = JsonSupport.firstString(members, "text", "content", "label", "title")
                    ?: return@mapIndexedNotNull null
                BotUIChecklistItem(
                    id = JsonSupport.firstString(members, "id") ?: "item-$index",
                    text = text,
                    done = JsonSupport.bool(members["done"]) == true,
                    note = JsonSupport.firstString(members, "note", "meta", "due"),
                    synthetic = JsonSupport.bool(members["synthetic"]) == true,
                )
            }
        }
    }
}

/** A parsed http/https link (`BotUILink`). */
public data class BotUILink(
    public val id: String,
    public val url: String,
    public val title: String,
    public val site: String,
    public val description: String?,
    public val kind: String,
) {
    public fun toJson(): JsonObject = BotJson.objectOf(
        "id" to JsonString(id),
        "url" to JsonString(url),
        "title" to JsonString(title),
        "site" to JsonString(site),
        "description" to (description?.let(::JsonString) ?: JsonNull),
        "kind" to JsonString(kind),
    )

    public companion object {
        public fun parseList(value: JsonValue?, limit: Int = 4): List<BotUILink> {
            val values = (value as? JsonArray)?.values ?: return emptyList()
            return values.take(limit).mapIndexedNotNull { index, item ->
                val members = (item as? JsonObject)?.members ?: return@mapIndexedNotNull null
                val rawURL = JsonSupport.string(members["url"]) ?: return@mapIndexedNotNull null
                if (rawURL.length > 2_048) return@mapIndexedNotNull null
                val uri = try {
                    URI(rawURL)
                } catch (_: Exception) {
                    return@mapIndexedNotNull null
                }
                val scheme = uri.scheme?.lowercase() ?: return@mapIndexedNotNull null
                if (scheme != "http" && scheme != "https") return@mapIndexedNotNull null
                val host = uri.host
                if (host.isNullOrEmpty()) return@mapIndexedNotNull null
                val site = JsonSupport.firstString(members, "site")
                    ?: (if (host.startsWith("www.")) host.substring(4) else host)
                BotUILink(
                    id = JsonSupport.firstString(members, "id") ?: "link-$index",
                    url = rawURL,
                    title = JsonSupport.firstString(members, "title", "name", "label") ?: site,
                    site = site,
                    description = JsonSupport.firstString(members, "description", "summary", "note"),
                    kind = JsonSupport.string(members["kind"]) ?: "other",
                )
            }
        }
    }
}

/**
 * `BotUIAttachment.parseList`: name/fileName is required, size is clamped to
 * >= 0, and an absent kind is derived by [BotAttachmentPolicy.kind].
 */
public object BotUIAttachmentParser {
    public fun parseList(value: JsonValue?, limit: Int = BotAttachmentPolicy.MAX_COUNT): List<BotAttachment> {
        val values = (value as? JsonArray)?.values ?: return emptyList()
        return values.take(limit).mapNotNull { item ->
            val members = (item as? JsonObject)?.members ?: return@mapNotNull null
            val name = JsonSupport.firstString(members, "name", "fileName") ?: return@mapNotNull null
            val size = JsonSupport.long(members["size"])?.coerceAtLeast(0) ?: 0
            val mimeType = JsonSupport.string(members["mimeType"]) ?: ""
            BotAttachment(
                name = name,
                path = JsonSupport.string(members["path"]) ?: "",
                size = size,
                mimeType = mimeType,
                kind = JsonSupport.string(members["kind"])
                    ?: BotAttachmentPolicy.kind(name, mimeType),
            )
        }
    }
}

/** A parseable card: the kind plus the body it came from. */
public data class BotUICardContent(
    public val kind: BotUICardKind,
    public val body: BotRowBody,
) {
    public val choices: List<BotUIChoice>
        get() = BotUIChoice.parseList(body[if (kind == BotUICardKind.STEPS) "steps" else "options"])

    /** The steps card's display rows (state/detail), not its answer choices. */
    public val steps: List<BotUIProgressStep>
        get() = BotUIProgressStep.parseList(body["steps"])

    public val progressSteps: List<BotUIProgressStep> get() = steps

    public val checklist: List<BotUIChecklistItem>
        get() = BotUIChecklistItem.parseList(body["items"])

    public val links: List<BotUILink>
        get() = BotUILink.parseList(body["links"])

    public companion object {
        /** `BotUICardContent.parse`: the single fail-closed card parser. */
        public fun parse(row: BotRow): BotUICardContent? {
            val body = row.body
            val kind: BotUICardKind
            when (body.type) {
                BotRowBodyType.WIDGET -> {
                    val cardType = body.cardType ?: return null
                    kind = when (cardType) {
                        BotWidgetCardType.QUESTION -> BotUICardKind.QUESTION
                        BotWidgetCardType.STEPS -> BotUICardKind.STEPS
                        BotWidgetCardType.TASK -> BotUICardKind.TASK
                        BotWidgetCardType.DOCUMENT -> BotUICardKind.DOCUMENT
                        BotWidgetCardType.PROGRESS -> BotUICardKind.PROGRESS
                        BotWidgetCardType.CHECKLIST -> BotUICardKind.CHECKLIST
                        BotWidgetCardType.LINK -> BotUICardKind.LINK
                        else -> return null
                    }
                }
                BotRowBodyType.ATTACHMENT -> {
                    // BotUIRowCodec normalises the schema's UI-only
                    // cardType:"attachment" to absent; any remaining declared
                    // type is something other than attachment and fails closed.
                    if (body.cardType != null) return null
                    kind = BotUICardKind.ATTACHMENT
                }
                BotRowBodyType.APPROVAL -> kind = BotUICardKind.APPROVAL
                BotRowBodyType.AUTOMATION -> kind = BotUICardKind.AUTOMATION
                BotRowBodyType.NOTICE -> kind = BotUICardKind.NOTICE
                BotRowBodyType.TEXT, BotRowBodyType.DELETED -> return null
            }
            return if (valid(kind, body)) BotUICardContent(kind, body) else null
        }

        private fun valid(kind: BotUICardKind, body: BotRowBody): Boolean {
            val ask = (body["ask"] as? JsonObject)?.members ?: emptyMap()
            return when (kind) {
                BotUICardKind.QUESTION, BotUICardKind.STEPS -> {
                    val choices = BotUIChoice.parseList(
                        body[if (kind == BotUICardKind.QUESTION) "options" else "steps"])
                    val prompt = JsonSupport.firstString(
                        body.additionalProperties, "question", "prompt", "helpText", "help") ?: ""
                    choices.isNotEmpty() || prompt.trim().isNotEmpty()
                }
                BotUICardKind.TASK -> {
                    val title = JsonSupport.firstString(
                        body.additionalProperties, "title", "text", "question") ?: ""
                    val steps = when (val value = body["tasks"]) {
                        is JsonArray -> value.values
                        else -> (body["steps"] as? JsonArray)?.values ?: emptyList()
                    }
                    title.isNotEmpty() || steps.isNotEmpty()
                }
                BotUICardKind.ATTACHMENT ->
                    JsonSupport.firstString(
                        body.additionalProperties, "fileName", "name", "path") != null
                BotUICardKind.DOCUMENT ->
                    JsonSupport.firstString(
                        body.additionalProperties,
                        "title", "name", "fileName", "path", "url", "summary", "content") != null
                BotUICardKind.PROGRESS ->
                    JsonSupport.firstString(body.additionalProperties, "title", "name") != null
                BotUICardKind.CHECKLIST ->
                    JsonSupport.firstString(body.additionalProperties, "title") != null &&
                        BotUIChecklistItem.parseList(body["items"]).isNotEmpty()
                BotUICardKind.LINK -> BotUILink.parseList(body["links"]).isNotEmpty()
                BotUICardKind.APPROVAL -> {
                    val status = JsonSupport.string(body["status"])
                        ?: JsonSupport.string(ask["status"])
                        ?: "pending"
                    val action = JsonSupport.firstString(
                        body.additionalProperties, "action", "title", "text")
                        ?: JsonSupport.string(ask["action"])
                        ?: ""
                    if (status == "pending") {
                        val id = JsonSupport.firstString(
                            body.additionalProperties, "approvalID", "requestId", "id")
                            ?: JsonSupport.string(ask["requestId"])
                        val digest = JsonSupport.string(body["digest"])
                        id?.isNotEmpty() == true && digest?.isNotEmpty() == true && action.isNotEmpty()
                    } else {
                        action.isNotEmpty()
                    }
                }
                BotUICardKind.AUTOMATION -> {
                    val name = JsonSupport.firstString(
                        body.additionalProperties, "title", "name", "automationId")
                        ?: (body["automation"] as? JsonObject)?.members?.let { automation ->
                            JsonSupport.firstString(automation, "name", "automationId")
                        }
                    name != null
                }
                BotUICardKind.NOTICE -> {
                    val tone = JsonSupport.string(body["tone"]) ?: "error"
                    val text = JsonSupport.string(body["text"]) ?: ""
                    tone in setOf("error", "denied", "denial") && text.trim().isNotEmpty()
                }
            }
        }
    }
}

/** The frozen renderability/surface/copy rules (`ui-state.md` §4.1). */
public object BotUIRendering {
    public const val HIDDEN_SURFACE: String = "hidden"

    public fun isRenderable(row: BotRow): Boolean {
        if (row.body.type == BotRowBodyType.DELETED) return false
        if (row.body.type == BotRowBodyType.TEXT) {
            val text = JsonSupport.string(row.body["text"]) ?: ""
            val hasText = text.trim().isNotEmpty()
            val hasAttachments = row.role == "user" &&
                BotUIAttachmentParser.parseList(row.body["attachments"]).isNotEmpty()
            return row.kind in setOf(BotRowKind.MESSAGE, BotRowKind.SEND_MESSAGE) &&
                row.role in setOf("user", "assistant") &&
                (hasText || hasAttachments)
        }
        return BotUICardContent.parse(row) != null
    }

    public fun surface(row: BotRow): String {
        if (!isRenderable(row)) return HIDDEN_SURFACE
        if (row.body.type == BotRowBodyType.TEXT) return "bubble"
        val kind = BotUICardContent.parse(row)?.kind ?: return HIDDEN_SURFACE
        return when (kind) {
            BotUICardKind.QUESTION, BotUICardKind.STEPS -> "widget-card"
            BotUICardKind.TASK -> "agent-thread-row"
            BotUICardKind.ATTACHMENT -> "attachment-card"
            BotUICardKind.DOCUMENT -> "document-card"
            BotUICardKind.PROGRESS -> "progress-card"
            BotUICardKind.CHECKLIST -> "checklist-card"
            BotUICardKind.LINK -> "link-card"
            BotUICardKind.APPROVAL -> "approval-card"
            BotUICardKind.AUTOMATION -> "automation-row"
            BotUICardKind.NOTICE -> "notice"
        }
    }

    public fun copyText(row: BotRow): String {
        val text = JsonSupport.string(row.body["text"])
        if (text != null && text.isNotEmpty()) return text
        return JsonSupport.firstString(
            row.body.additionalProperties,
            "title", "question", "prompt", "name", "fileName", "path", "summary",
        ) ?: row.id
    }
}

/**
 * The P09 row decoder.
 *
 * `row.schema.json` accepts the UI-only `body.cardType: "attachment"` value,
 * but the P27 `BotWidgetCardType` enum in `:bot` does not (it lists only the
 * widget kinds P27 serializes). The P09 contract says `attachment` accepts an
 * absent or `attachment` cardType, so this decoder normalises that one value
 * to absent before delegating every other field to [BotRow.fromJson]. It is
 * not a second row type and does not add a field; it is the view-side reading
 * of a schema legal value. A widget body with an unknown cardType still fails
 * closed.
 */
public object BotUIRowCodec {
    public fun fromJson(value: JsonValue): BotRow {
        val members = (value as? JsonObject)?.members ?: return BotRow.fromJson(value)
        val body = members["body"] as? JsonObject ?: return BotRow.fromJson(value)
        val isAttachment = JsonSupport.string(body.members["type"]) == "attachment"
        if (isAttachment && JsonSupport.string(body.members["cardType"]) == "attachment") {
            val bodyMembers = LinkedHashMap(body.members)
            bodyMembers.remove("cardType")
            val rowMembers = LinkedHashMap(members)
            rowMembers["body"] = JsonObject(bodyMembers)
            return BotRow.fromJson(JsonObject(rowMembers))
        }
        return BotRow.fromJson(value)
    }

    public fun fromJsonList(values: List<JsonValue>): List<BotRow> = values.map(::fromJson)
}

/** The `approval` status member with the `ask.status` fallback. */
internal fun BotRow.approvalStatus(): String {
    val ask = (body["ask"] as? JsonObject)?.members ?: emptyMap()
    return JsonSupport.string(body["status"]) ?: JsonSupport.string(ask["status"]) ?: "pending"
}
