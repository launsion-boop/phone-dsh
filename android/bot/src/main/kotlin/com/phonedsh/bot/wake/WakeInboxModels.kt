// SPDX-License-Identifier: MIT
package com.phonedsh.bot.wake

import com.phonedsh.agentcore.JsonArray
import com.phonedsh.agentcore.JsonObject
import com.phonedsh.agentcore.JsonString
import com.phonedsh.agentcore.JsonValue
import com.phonedsh.bot.routines.RoutineDecodeException
import com.phonedsh.bot.routines.RoutineError
import com.phonedsh.bot.routines.RoutineJson
import com.phonedsh.bot.routines.RoutineJson.objectOf
import com.phonedsh.bot.routines.RoutineJson.optionalInt
import com.phonedsh.bot.routines.RoutineJson.optionalLong
import com.phonedsh.bot.routines.RoutineJson.optionalString
import com.phonedsh.bot.routines.RoutineJson.requiredArray
import com.phonedsh.bot.routines.RoutineJson.requiredInt
import com.phonedsh.bot.routines.RoutineJson.requiredLong
import com.phonedsh.bot.routines.RoutineJson.requiredString

enum class WakeInboxState(val rawValue: String) {
    PENDING("pending"),
    STAGED("staged"),
    ;

    companion object {
        fun from(value: String?): WakeInboxState = when (value) {
            "pending", null -> PENDING
            "staged" -> STAGED
            else -> throw RoutineDecodeException("unknown held inbox item state: $value")
        }
    }
}

/**
 * One `WakeInbox` item (`held-inbox-item.schema.json`; Swift `WakeInboxItem`).
 *
 * `text` is capped at 1,200 scalars. `state == staged` requires both
 * `stagedAt` and a non-empty `stagedKey`; the durable inbox never stores a
 * partially staged item. Unknown members are ignored on decode (additive).
 */
data class WakeInboxItem(
    val id: String,
    val kind: String,
    val fromAgentId: String? = null,
    val fromAgentName: String = "",
    val title: String? = null,
    val text: String,
    val requestId: String? = null,
    val threadId: String? = null,
    val createdAt: Long,
    val state: WakeInboxState = WakeInboxState.PENDING,
    val stagedAt: Long? = null,
    val stagedKey: String? = null,
    val taskId: String? = null,
    val status: String? = null,
    val ranAt: Long? = null,
    val routineId: String? = null,
    val attempt: Int? = null,
    val runId: String? = null,
    val deliveryKey: String? = null,
) {
    init {
        validate()
    }

    fun validate(): WakeInboxItem {
        if (id.isEmpty()) throw RoutineError.InvalidHeldItem("held inbox item id is required")
        if (kind.isEmpty()) throw RoutineError.InvalidHeldItem("held inbox item kind is required")
        if (RoutineJson.codePointLength(text) > 1200) {
            throw RoutineError.InvalidHeldItem("held inbox item text exceeds 1200 characters")
        }
        if (state == WakeInboxState.STAGED) {
            if (stagedAt == null || stagedKey.isNullOrEmpty()) {
                throw RoutineError.InvalidHeldItem(
                    "staged inbox items require stagedAt and a non-empty stagedKey",
                )
            }
        }
        // `held-inbox-item.schema.json` gives `device-task-result` its own
        // required members; enforce them here too so a malformed notice cannot
        // be stored and later rendered as if it were an agent message.
        if (kind == DEVICE_TASK_RESULT) {
            if (requestId.isNullOrEmpty()) {
                throw RoutineError.InvalidHeldItem("device task result requestId is required")
            }
            if (taskId.isNullOrEmpty()) {
                throw RoutineError.InvalidHeldItem("device task result taskId is required")
            }
            val value = status ?: throw RoutineError.InvalidHeldItem("device task result status is required")
            if (value !in DEVICE_TASK_RESULT_STATUSES) {
                throw RoutineError.InvalidHeldItem("invalid device task result status: $value")
            }
        }
        return this
    }

    fun toJson(): JsonObject = objectOf(
        listOf(
            "id" to JsonString(id),
            "kind" to JsonString(kind),
            "fromAgentId" to fromAgentId?.let(RoutineJson::string),
            "fromAgentName" to JsonString(fromAgentName),
            "title" to title?.let(RoutineJson::string),
            "text" to JsonString(text),
            "requestId" to requestId?.let(RoutineJson::string),
            "threadId" to threadId?.let(RoutineJson::string),
            "createdAt" to RoutineJson.number(createdAt),
            "state" to JsonString(state.rawValue),
            "stagedAt" to stagedAt?.let(RoutineJson::number),
            "stagedKey" to stagedKey?.let(RoutineJson::string),
            "taskId" to taskId?.let(RoutineJson::string),
            "status" to status?.let(RoutineJson::string),
            "ranAt" to ranAt?.let(RoutineJson::number),
            "routineId" to routineId?.let(RoutineJson::string),
            "attempt" to attempt?.let { RoutineJson.number(it.toLong()) },
            "runId" to runId?.let(RoutineJson::string),
            "deliveryKey" to deliveryKey?.let(RoutineJson::string),
        ),
    )

    companion object {
        fun fromJson(value: JsonValue?): WakeInboxItem {
            val members = (value as? JsonObject)?.members
                ?: throw RoutineDecodeException("held inbox item must be an object")
            return WakeInboxItem(
                id = members.requiredString("id"),
                kind = members.requiredString("kind"),
                fromAgentId = members.optionalString("fromAgentId"),
                fromAgentName = members.optionalString("fromAgentName") ?: "",
                title = members.optionalString("title"),
                text = members.optionalString("text") ?: "",
                requestId = members.optionalString("requestId"),
                threadId = members.optionalString("threadId"),
                createdAt = members.requiredLong("createdAt"),
                state = WakeInboxState.from(members.optionalString("state")),
                stagedAt = members.optionalLong("stagedAt"),
                stagedKey = members.optionalString("stagedKey"),
                taskId = members.optionalString("taskId"),
                status = members.optionalString("status"),
                ranAt = members.optionalLong("ranAt"),
                routineId = members.optionalString("routineId"),
                attempt = members.optionalInt("attempt"),
                runId = members.optionalString("runId"),
                deliveryKey = members.optionalString("deliveryKey"),
            )
        }
    }
}

/** `WakeInboxDocument {version:1, items}` stored as `{botId, document}`. */
data class WakeInboxDocument(
    val version: Int = 1,
    val items: List<WakeInboxItem> = emptyList(),
) {
    fun toJson(): JsonObject = objectOf(
        listOf(
            "version" to RoutineJson.number(version.toLong()),
            "items" to JsonArray(items.map { it.toJson() }),
        ),
    )

    companion object {
        const val SUPPORTED_VERSION: Int = 1

        fun fromJson(value: JsonValue?): WakeInboxDocument {
            val members = (value as? JsonObject)?.members
                ?: throw RoutineDecodeException("wake inbox document must be an object")
            val version = members.requiredInt("version", "document.version")
            if (version != SUPPORTED_VERSION) {
                throw RoutineDecodeException(
                    "unsupported wake inbox snapshot version: $version",
                )
            }
            return WakeInboxDocument(
                version = version,
                items = members.requiredArray("items", "document.items").map(WakeInboxItem::fromJson),
            )
        }
    }
}

const val DEVICE_TASK_RESULT: String = "device-task-result"

val DEVICE_TASK_RESULT_STATUSES: Set<String> = setOf(
    "completed", "denied", "unavailable", "expired", "failed", "unknown_outcome",
)

/** One atomic inbox mutation; `persistSnapshot=false` writes nothing. */
data class WakeInboxMutation<V>(
    val value: V,
    val document: WakeInboxDocument,
    val persistSnapshot: Boolean = true,
    val eventType: String = "comm.inbound",
    val eventId: String? = null,
)

/** The durable inbox seam (Swift `WakeInboxStore`). */
interface WakeInboxStore {
    fun read(botId: String): WakeInboxDocument

    fun <V> mutate(botId: String, body: (WakeInboxDocument) -> WakeInboxMutation<V>): V
}

data class WakeInboxEnqueue(val ok: Boolean, val item: WakeInboxItem, val duplicate: Boolean)

data class WakeInboxStage(val items: List<WakeInboxItem>, val key: String?)

/** One wake signal from the host (D8 §10 interface; no push relay this round). */
data class WakeSignal(val botId: String, val reason: String, val at: Long)

interface WakeSignalSource {
    fun start(onSignal: (WakeSignal) -> Unit)

    fun stop()
}
