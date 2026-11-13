// SPDX-License-Identifier: MIT
package com.phonedsh.bot.rows

import com.phonedsh.agentcore.JsonObject
import com.phonedsh.agentcore.JsonValue
import com.phonedsh.bot.BotJson

/** Which display profile a projection is evaluated for. */
public enum class BotDisplayProfile {
    UPSTREAM_REFERENCE,
    PHONE_P0,
}

/** The wire record a projected row maps to (`wire.kind` + `wire.type` + role). */
public data class BotWireRecord(
    public val kind: String,
    public val type: String,
    public val role: String? = null,
)

/** A projected display surface. */
public data class BotDisplayProjection(
    public val surface: String,
    public val renderable: Boolean,
    public val wire: BotWireRecord,
)

/**
 * The frozen display projection (`row-projection.json`).
 *
 * Port of Swift `BotDisplayContract.project(surface/renderable)`. The input is
 * the row-shaped JSON object the goldens carry, so the projector is a pure
 * function of those bytes.
 */
public object BotDisplayContract {
    public const val HIDDEN: String = "hidden"

    public val P1_CARD_TYPES: Set<BotWidgetCardType> = BotWidgetCardType.P1_CARD_TYPES

    /**
     * Cosmetic tool invocations never enter the transcript's tool list.
     * `FishAction` is the only advertisement-only tool today; prefixed names
     * (`mcp__phone__FishAction`) are hidden by the last `__` segment.
     */
    public val HIDDEN_TOOL_NAMES: Set<String> = setOf("FishAction")

    public fun isToolCallVisible(named: String): Boolean =
        named.substringAfterLast("__") !in HIDDEN_TOOL_NAMES

    public fun visibleToolCallNames(names: List<String>): List<String> =
        names.filter { isToolCallVisible(it) }

    public fun project(
        input: Map<String, JsonValue>,
        profile: BotDisplayProfile = BotDisplayProfile.PHONE_P0,
    ): BotDisplayProjection {
        val kind = BotJson.string(input["kind"]) ?: "message"
        return when (kind) {
            "message" -> projectMessage(input)
            "card", "attachment", "file", "info-row", "payload-row", "task-thread", "team-bot" ->
                cardProjection(input, kind, profile)
            "approval" -> {
                val status = BotJson.string(input["status"]) ?: "pending"
                val hasData = input["ask"] != null ||
                    BotJson.nonEmptyString(input, listOf("action", "text", "status")) != null
                projection(
                    "approval-card",
                    status != "pending" && hasData,
                    BotWireRecord("send-message", "local-tool-permission"),
                )
            }
            "routine-run", "automation", "automation-run" -> {
                val automation = (input["automation"] as? JsonObject)?.members ?: emptyMap()
                val hasData = BotJson.nonEmptyString(automation, listOf("name", "automationId")) != null ||
                    BotJson.nonEmptyString(input, listOf("title", "name", "automationId")) != null
                projection("automation-row", hasData, BotWireRecord("message", "text"))
            }
            "system-event" -> {
                val event = BotJson.string(input["event"]) ?: ""
                val visible = event in setOf("outbound", "inbound", "summary", "renamed")
                val hasData = if (event == "renamed") {
                    BotJson.nonEmptyString(input, listOf("botName")) != null
                } else {
                    BotJson.nonEmptyString(input, listOf("botName", "text")) != null
                }
                projection(
                    if (visible) "system-event" else HIDDEN,
                    visible && hasData,
                    BotWireRecord("event", if (event.isEmpty()) "unknown" else event),
                )
            }
            "notice" -> {
                val tone = BotJson.string(input["tone"]) ?: ""
                val visible = tone in setOf("error", "denied", "denial") &&
                    BotJson.bool(input["contextOnly"]) != true
                projection(
                    if (visible) "notice" else HIDDEN,
                    visible && hasText(input, listOf("text")),
                    BotWireRecord("event", "notice"),
                )
            }
            "tool-call" -> projection(HIDDEN, false, BotWireRecord("event", "tool-call"))
            "deleted" -> projection(HIDDEN, false, BotWireRecord("event", "deleted"))
            "separator" -> projection(
                "separator",
                profile == BotDisplayProfile.UPSTREAM_REFERENCE,
                BotWireRecord("event", "separator"),
            )
            else -> projection(HIDDEN, false, BotWireRecord("event", kind))
        }
    }

    public fun project(row: BotRow, profile: BotDisplayProfile = BotDisplayProfile.PHONE_P0): BotDisplayProjection {
        val input = LinkedHashMap<String, JsonValue>(row.body.additionalProperties)
        row.body.cardType?.let { input["cardType"] = com.phonedsh.agentcore.JsonString(it.wire) }
        row.body.cardKey?.let { input["cardKey"] = com.phonedsh.agentcore.JsonString(it) }
        row.role?.let { input["role"] = com.phonedsh.agentcore.JsonString(it) }
        when (row.body.type) {
            BotRowBodyType.TEXT -> {
                input["kind"] = com.phonedsh.agentcore.JsonString("message")
                if (row.kind == BotRowKind.MESSAGE && row.role == null) {
                    input["role"] = com.phonedsh.agentcore.JsonString("user")
                }
            }
            BotRowBodyType.WIDGET -> input["kind"] = com.phonedsh.agentcore.JsonString("card")
            BotRowBodyType.ATTACHMENT -> {
                input["kind"] = com.phonedsh.agentcore.JsonString("card")
                input["cardType"] = com.phonedsh.agentcore.JsonString("attachment")
            }
            BotRowBodyType.APPROVAL -> input["kind"] = com.phonedsh.agentcore.JsonString("approval")
            BotRowBodyType.AUTOMATION -> input["kind"] = com.phonedsh.agentcore.JsonString("routine-run")
            BotRowBodyType.NOTICE -> input["kind"] = com.phonedsh.agentcore.JsonString(
                if (input["event"] == null) "notice" else "system-event")
            BotRowBodyType.DELETED -> input["kind"] = com.phonedsh.agentcore.JsonString("deleted")
        }
        return project(input, profile)
    }

    private fun projectMessage(input: Map<String, JsonValue>): BotDisplayProjection {
        val direction = agentCommDirection(input)
        if (direction != null) {
            val role = BotJson.string(input["role"])
            if (direction != BotAgentCommDirection.OUTBOUND && direction != BotAgentCommDirection.INBOUND) {
                val hasBody = hasText(input, listOf("text", "content")) ||
                    hasText(input, listOf("replyText"))
                val isUser = role == "user"
                return projection(
                    "bubble",
                    hasBody,
                    BotWireRecord(if (isUser) "message" else "send-message", "text", role),
                )
            }
            val hasBody = hasText(input, listOf("text", "content", "replyText"))
            return projection("agent-comm", hasBody, BotWireRecord("message", "text", role))
        }
        if (input["toAgent"] != null || input["fromAgent"] != null ||
            BotJson.bool(input["agentComm"]) == true
        ) {
            return projection(
                "agent-comm",
                hasText(input, listOf("text", "content", "replyText")),
                BotWireRecord("message", "text", BotJson.string(input["role"])),
            )
        }
        val role = BotJson.string(input["role"])
        val isUser = role == "user"
        // Attachment-only user messages have an empty bubble text but must
        // still render the row (the attachments are shown as cards).
        val hasBody = hasText(input, listOf("text", "content")) ||
            BotJson.hasItems(input, listOf("attachments"))
        return projection(
            "bubble",
            hasBody,
            BotWireRecord(if (isUser) "message" else "send-message", "text", role),
        )
    }

    private fun cardProjection(
        input: Map<String, JsonValue>,
        kind: String,
        profile: BotDisplayProfile,
    ): BotDisplayProjection {
        val rawType = BotJson.string(input["cardType"]) ?: defaultCardType(kind) ?: ""
        val surface: String
        val wireType: String
        val hasData: Boolean
        when (rawType) {
            "question", "steps" -> {
                surface = "widget-card"
                wireType = "widget"
                hasData = BotJson.nonEmptyString(input, listOf("question", "prompt", "helpText", "help")) != null ||
                    BotJson.hasItems(input, listOf("options", "steps"))
            }
            "attachment", "file" -> {
                surface = "attachment-card"
                wireType = "attachment"
                hasData = BotJson.nonEmptyString(input, listOf("fileName", "name", "path")) != null
            }
            "document", "library" -> {
                surface = "document-card"
                wireType = "widget"
                hasData = BotJson.nonEmptyString(input, listOf("title", "name", "path", "url", "summary")) != null
            }
            "progress" -> {
                surface = "progress-card"
                wireType = "widget"
                hasData = BotJson.nonEmptyString(input, listOf("title", "name")) != null
            }
            "checklist" -> {
                surface = "checklist-card"
                wireType = "widget"
                hasData = BotJson.nonEmptyString(input, listOf("title")) != null &&
                    BotJson.hasItems(input, listOf("items"))
            }
            "link" -> {
                surface = "link-card"
                wireType = "widget"
                hasData = BotJson.hasItems(input, listOf("links"))
            }
            "task" -> {
                surface = "agent-thread-row"
                wireType = "widget"
                hasData = BotJson.nonEmptyString(input, listOf("title", "text")) != null ||
                    BotJson.hasItems(input, listOf("tasks", "steps"))
            }
            "table" -> {
                surface = "table-card"
                wireType = "widget"
                hasData = (BotJson.arraySize(input["columns"]) > 1) &&
                    BotJson.hasItems(input, listOf("rows"))
            }
            "callout" -> {
                surface = "callout"
                wireType = "widget"
                hasData = BotJson.nonEmptyString(input, listOf("body", "title")) != null
            }
            "info" -> {
                surface = "info-row"
                wireType = "connector"
                hasData = BotJson.nonEmptyString(input, listOf("label", "value", "title", "text")) != null ||
                    BotJson.hasItems(input, listOf("rows"))
            }
            "payload" -> {
                surface = "payload-row"
                wireType = "text"
                hasData = BotJson.hasItems(input, listOf("payloads", "items", "attachments"))
            }
            "team-bot" -> {
                surface = "team-bot-row"
                wireType = "widget"
                hasData = BotJson.nonEmptyString(
                    input, listOf("name", "title", "teamBotName", "description")) != null
            }
            else -> return projection(HIDDEN, false, BotWireRecord("send-message", "widget"))
        }
        if (profile == BotDisplayProfile.PHONE_P0 &&
            P1_CARD_TYPES.any { it.wire == rawType }
        ) {
            return projection(HIDDEN, false, BotWireRecord("send-message", wireType))
        }
        return projection(surface, hasData, BotWireRecord("send-message", wireType))
    }

    private fun defaultCardType(kind: String): String? = when (kind) {
        "attachment", "file" -> "attachment"
        "info-row" -> "info"
        "payload-row" -> "payload"
        "task-thread" -> "task"
        "team-bot" -> "team-bot"
        else -> null
    }

    /**
     * The upstream `agentComm.direction` object wins. Rows written before that
     * object existed derive the direction from `fromAgent`/`toAgent`.
     */
    private fun agentCommDirection(input: Map<String, JsonValue>): BotAgentCommDirection? {
        val objectValue = (input["agentComm"] as? JsonObject)?.members
        if (objectValue != null) {
            val raw = BotJson.string(objectValue["direction"])
            if (raw != null) {
                BotAgentCommDirection.entries.firstOrNull { it.wire == raw }?.let { return it }
            }
        }
        if (input["fromAgent"] != null) return BotAgentCommDirection.INBOUND
        if (input["toAgent"] != null) return BotAgentCommDirection.OUTBOUND
        return null
    }

    private fun hasText(input: Map<String, JsonValue>, keys: List<String>): Boolean =
        BotJson.nonEmptyString(input, keys) != null

    private fun projection(
        surface: String,
        renderable: Boolean,
        wire: BotWireRecord,
    ): BotDisplayProjection = BotDisplayProjection(
        surface = if (renderable || surface != HIDDEN) surface else HIDDEN,
        renderable = renderable,
        wire = wire,
    )
}
