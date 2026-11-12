// SPDX-License-Identifier: MIT
package com.phonedsh.bot.rows

import com.phonedsh.agentcore.JsonArray
import com.phonedsh.agentcore.JsonObject
import com.phonedsh.agentcore.JsonString
import com.phonedsh.agentcore.JsonValue
import com.phonedsh.bot.BotJson
import com.phonedsh.bot.BotJsonException
import com.phonedsh.bot.optionalString
import com.phonedsh.bot.requiredArray
import com.phonedsh.bot.requiredBool
import com.phonedsh.bot.requiredLong
import com.phonedsh.bot.requiredString

/** `BotRow.kind` (`row.schema.json`). */
public enum class BotRowKind(public val wire: String) {
    MESSAGE("message"),
    SEND_MESSAGE("sendMessage"),
    EVENT("event"),
    ;

    public companion object {
        public fun fromWire(value: String): BotRowKind =
            entries.firstOrNull { it.wire == value }
                ?: throw BotJsonException("unknown row kind: $value")
    }
}

/** `BotRow.body.type` (`row.schema.json`). */
public enum class BotRowBodyType(public val wire: String) {
    TEXT("text"),
    WIDGET("widget"),
    ATTACHMENT("attachment"),
    APPROVAL("approval"),
    AUTOMATION("automation"),
    NOTICE("notice"),
    DELETED("deleted"),
    ;

    public companion object {
        public fun fromWire(value: String): BotRowBodyType =
            entries.firstOrNull { it.wire == value }
                ?: throw BotJsonException("unknown row body type: $value")
    }
}

/** `body.cardType` (`row.schema.json`). */
public enum class BotWidgetCardType(public val wire: String) {
    QUESTION("question"),
    STEPS("steps"),
    TASK("task"),
    DOCUMENT("document"),
    PROGRESS("progress"),
    CHECKLIST("checklist"),
    LINK("link"),
    TABLE("table"),
    CALLOUT("callout"),
    INFO("info"),
    PAYLOAD("payload"),
    LIBRARY("library"),
    ;

    /** The five card types frozen as `p1` (protocol-visible, not phone P0 renderable). */
    public val isPhoneP0: Boolean
        get() = this !in P1_CARD_TYPES

    public companion object {
        public val P1_CARD_TYPES: Set<BotWidgetCardType> =
            setOf(TABLE, CALLOUT, INFO, PAYLOAD, LIBRARY)

        public fun fromWire(value: String): BotWidgetCardType =
            entries.firstOrNull { it.wire == value }
                ?: throw BotJsonException("unknown widget card type: $value")
    }
}

/**
 * A row body: the frozen `type`/`cardType`/`cardKey` triple plus the
 * body-type-specific members (`text`, `title`, `options`, …). The additional
 * members are preserved verbatim so a decoded row re-encodes byte-identically.
 */
public data class BotRowBody(
    public val type: BotRowBodyType,
    public val cardType: BotWidgetCardType? = null,
    public val cardKey: String? = null,
    public val additionalProperties: Map<String, JsonValue> = emptyMap(),
) {
    public operator fun get(key: String): JsonValue? = additionalProperties[key]

    public fun with(key: String, value: JsonValue): BotRowBody =
        copy(additionalProperties = additionalProperties + (key to value))

    public fun toJson(): JsonObject {
        val members = LinkedHashMap<String, JsonValue>()
        members["type"] = JsonString(type.wire)
        cardType?.let { members["cardType"] = JsonString(it.wire) }
        cardKey?.let { members["cardKey"] = JsonString(it) }
        for ((key, value) in additionalProperties) {
            if (key == "type" || key == "cardType" || key == "cardKey") continue
            members[key] = value
        }
        return JsonObject(members)
    }

    public companion object {
        public fun fromJson(value: JsonValue): BotRowBody {
            val members = (value as? JsonObject)?.members
                ?: throw BotJsonException("row body must be an object")
            val type = BotRowBodyType.fromWire(members.requiredString("type", "body.type"))
            val cardType = members.optionalString("cardType")?.let { BotWidgetCardType.fromWire(it) }
            val cardKey = members.optionalString("cardKey")
            val additional = LinkedHashMap<String, JsonValue>()
            for ((key, item) in members) {
                if (key == "type" || key == "cardType" || key == "cardKey") continue
                additional[key] = item
            }
            return BotRowBody(type = type, cardType = cardType, cardKey = cardKey,
                additionalProperties = additional)
        }
    }
}

/** `row.provenance` (`row.schema.json`). */
public data class BotRowProvenance(
    public val eventIDs: List<String>,
    public val trust: String,
    public val tainted: Boolean,
) {
    public fun toJson(): JsonObject = BotJson.objectOf(
        "eventIDs" to JsonArray(eventIDs.map(::JsonString)),
        "trust" to JsonString(trust),
        "tainted" to com.phonedsh.agentcore.JsonBool(tainted),
    )

    public companion object {
        public const val OWNER_DIRECT: String = "owner_direct"
        public const val MODEL: String = "model"
        public const val PROJECTOR: String = "projector"

        public fun fromJson(value: JsonValue): BotRowProvenance {
            val members = (value as? JsonObject)?.members
                ?: throw BotJsonException("row provenance must be an object")
            val eventIDs = members.requiredArray("eventIDs", "provenance.eventIDs").map { item ->
                (item as? JsonString)?.value
                    ?: throw BotJsonException("provenance.eventIDs[] must be a string")
            }
            return BotRowProvenance(
                eventIDs = eventIDs,
                trust = members.requiredString("trust", "provenance.trust"),
                tainted = members.requiredBool("tainted", "provenance.tainted"),
            )
        }
    }
}

/** `row.schema.json` `BotRow v1`. */
public data class BotRow(
    public val id: String,
    public val botID: String,
    public val seq: Long,
    public val updatedSeq: Long,
    public val kind: BotRowKind,
    public val role: String? = null,
    public val body: BotRowBody,
    public val provenance: BotRowProvenance,
    public val streaming: Boolean,
    public val createdAt: Long,
) {
    public fun toJson(): JsonObject {
        val members = LinkedHashMap<String, JsonValue>()
        members["id"] = JsonString(id)
        members["botID"] = JsonString(botID)
        members["seq"] = BotJson.number(seq)
        members["updatedSeq"] = BotJson.number(updatedSeq)
        members["kind"] = JsonString(kind.wire)
        role?.let { members["role"] = JsonString(it) }
        members["body"] = body.toJson()
        members["provenance"] = provenance.toJson()
        members["streaming"] = com.phonedsh.agentcore.JsonBool(streaming)
        members["createdAt"] = BotJson.number(createdAt)
        return JsonObject(members)
    }

    public fun replacing(
        body: BotRowBody? = null,
        updatedSeq: Long? = null,
        provenance: BotRowProvenance? = null,
        streaming: Boolean? = null,
    ): BotRow = copy(
        body = body ?: this.body,
        updatedSeq = updatedSeq ?: this.updatedSeq,
        provenance = provenance ?: this.provenance,
        streaming = streaming ?: this.streaming,
    )

    public companion object {
        public fun fromJson(value: JsonValue): BotRow {
            val members = (value as? JsonObject)?.members
                ?: throw BotJsonException("row must be an object")
            val id = members.requiredString("id")
            if (id.isEmpty()) throw BotJsonException("id must not be empty")
            val botID = members.requiredString("botID")
            if (botID.isEmpty()) throw BotJsonException("botID must not be empty")
            val seq = members.requiredLong("seq")
            if (seq < 0) throw BotJsonException("seq must be >= 0")
            val updatedSeq = members.requiredLong("updatedSeq")
            if (updatedSeq < 0) throw BotJsonException("updatedSeq must be >= 0")
            val createdAt = members.requiredLong("createdAt")
            if (createdAt < 0) throw BotJsonException("createdAt must be >= 0")
            return BotRow(
                id = id,
                botID = botID,
                seq = seq,
                updatedSeq = updatedSeq,
                kind = BotRowKind.fromWire(members.requiredString("kind")),
                role = members.optionalString("role"),
                body = BotRowBody.fromJson(members["body"]
                    ?: throw BotJsonException("missing member body")),
                provenance = BotRowProvenance.fromJson(members["provenance"]
                    ?: throw BotJsonException("missing member provenance")),
                streaming = members.requiredBool("streaming"),
                createdAt = createdAt,
            )
        }
    }
}

/** `row-batch.schema.json` `BotRowBatch v1`. */
public data class BotRowBatch(
    public val rows: List<BotRow>,
    public val deletes: List<String>,
    public val cursor: Long,
    public val reset: Boolean,
) {
    public fun toJson(): JsonObject = BotJson.objectOf(
        "rows" to JsonArray(rows.map { it.toJson() }),
        "deletes" to JsonArray(deletes.map(::JsonString)),
        "cursor" to BotJson.number(cursor),
        "reset" to com.phonedsh.agentcore.JsonBool(reset),
    )

    public companion object {
        public fun fromJson(value: JsonValue): BotRowBatch {
            val members = (value as? JsonObject)?.members
                ?: throw BotJsonException("row batch must be an object")
            val rows = members.requiredArray("rows", "rows").map(BotRow::fromJson)
            val deletes = members.requiredArray("deletes", "deletes").map { item ->
                val id = (item as? JsonString)?.value
                    ?: throw BotJsonException("deletes[] must be a string")
                if (id.isEmpty()) throw BotJsonException("deletes[] must not be empty")
                id
            }
            val cursor = members.requiredLong("cursor")
            if (cursor < 0) throw BotJsonException("cursor must be >= 0")
            return BotRowBatch(
                rows = rows,
                deletes = deletes,
                cursor = cursor,
                reset = members.requiredBool("reset"),
            )
        }
    }
}
