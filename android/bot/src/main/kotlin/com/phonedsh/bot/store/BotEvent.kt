// SPDX-License-Identifier: MIT
package com.phonedsh.bot.store

import com.phonedsh.agentcore.JsonArray
import com.phonedsh.agentcore.JsonBool
import com.phonedsh.agentcore.JsonNull
import com.phonedsh.agentcore.JsonNumber
import com.phonedsh.agentcore.JsonObject
import com.phonedsh.agentcore.JsonString
import com.phonedsh.agentcore.JsonValue
import com.phonedsh.bot.BotJson

/** `origin` (`spec/bot/v1/README.md` §1.2; Swift `BotEventOrigin`). */
public sealed interface BotEventOrigin {
    public data class Dsh(public val sessionId: String, public val seq: Long) : BotEventOrigin

    public data class Local(public val source: String) : BotEventOrigin

    public fun toJson(): JsonObject = when (this) {
        is Dsh -> JsonObject(
            linkedMapOf(
                "kind" to JsonString("dsh"),
                "sessionId" to JsonString(sessionId),
                "seq" to number(seq),
            ),
        )
        is Local -> JsonObject(
            linkedMapOf(
                "kind" to JsonString("local"),
                "source" to JsonString(source),
            ),
        )
    }

    public companion object {
        public fun fromJson(value: JsonValue?): BotEventOrigin {
            val members = (value as? JsonObject)?.members
                ?: throw invalidEvent("origin", "origin must be an object")
            val kind = string(members["kind"]) ?: throw invalidEvent("origin.kind", "origin.kind is required")
            return when (kind) {
                "dsh" -> {
                    if (!members.keys.allMatch(setOf("kind", "sessionId", "seq"))) {
                        throw invalidEvent("origin", "unknown DSH origin member")
                    }
                    BotEventOrigin.Dsh(
                        sessionId = string(members["sessionId"])
                            ?: throw invalidEvent("origin.sessionId", "origin.sessionId is required"),
                        seq = long(members["seq"])
                            ?: throw invalidEvent("origin.seq", "origin.seq is required"),
                    )
                }
                "local" -> {
                    if (!members.keys.allMatch(setOf("kind", "source"))) {
                        throw invalidEvent("origin", "unknown local origin member")
                    }
                    BotEventOrigin.Local(
                        source = string(members["source"])
                            ?: throw invalidEvent("origin.source", "origin.source is required"),
                    )
                }
                else -> throw invalidEvent("origin.kind", "unknown origin kind: $kind")
            }
        }
    }
}

public data class BotPrincipal(
    public val botId: String?,
    public val sessionId: String?,
    public val kind: String,
    public val capabilities: List<String>,
) {
    public fun toJson(): JsonObject {
        val members = LinkedHashMap<String, JsonValue>()
        botId?.let { members["botId"] = JsonString(it) }
        sessionId?.let { members["sessionId"] = JsonString(it) }
        members["kind"] = JsonString(kind)
        members["capabilities"] = JsonArray(capabilities.map(::JsonString))
        return JsonObject(members)
    }

    public companion object {
        public fun fromJson(value: JsonValue?): BotPrincipal {
            val members = (value as? JsonObject)?.members
                ?: throw invalidEvent("principal", "principal must be an object")
            val capabilities = (members["capabilities"] as? JsonArray)?.values?.map {
                (it as? JsonString)?.value
                    ?: throw invalidEvent("principal.capabilities", "capabilities must be strings")
            } ?: throw invalidEvent("principal.capabilities", "principal.capabilities is required")
            return BotPrincipal(
                botId = optionalString(members["botId"]),
                sessionId = optionalString(members["sessionId"]),
                kind = string(members["kind"])
                    ?: throw invalidEvent("principal.kind", "principal.kind is required"),
                capabilities = capabilities,
            )
        }
    }
}

public data class BotEventBatch(
    public val id: String,
    public val index: Int,
    public val total: Int,
) {
    public fun toJson(): JsonObject = JsonObject(
        linkedMapOf(
            "id" to JsonString(id),
            "index" to number(index.toLong()),
            "total" to number(total.toLong()),
        ),
    )

    public companion object {
        public fun fromJson(value: JsonValue?): BotEventBatch {
            val members = (value as? JsonObject)?.members
                ?: throw invalidEvent("batch", "batch must be an object")
            return BotEventBatch(
                id = string(members["id"]) ?: throw invalidEvent("batch.id", "batch.id is required"),
                index = long(members["index"])?.toInt()
                    ?: throw invalidEvent("batch.index", "batch.index is required"),
                total = long(members["total"])?.toInt()
                    ?: throw invalidEvent("batch.total", "batch.total is required"),
            )
        }
    }
}

/**
 * The durable event envelope (`spec/bot/v1/store.md` §4.5, README §1.2).
 * Optional members are omitted when nil; readers accept absent and explicit
 * null as the same value.
 */
public data class BotEvent(
    public val schemaVersion: Int,
    public val type: String,
    public val eventId: String,
    public val commitSeq: Long?,
    public val time: Long,
    public val origin: BotEventOrigin,
    public val traceId: String,
    public val principal: BotPrincipal,
    public val causationId: String?,
    public val correlationId: String?,
    public val turnId: String? = null,
    public val runId: String? = null,
    public val attempt: Int? = null,
    public val batch: BotEventBatch? = null,
    public val ignorable: Boolean? = null,
    public val data: JsonValue,
) {
    public fun toJson(dataOverride: JsonValue? = null): JsonObject {
        val members = LinkedHashMap<String, JsonValue>()
        members["schemaVersion"] = number(schemaVersion.toLong())
        members["type"] = JsonString(type)
        members["eventId"] = JsonString(eventId)
        commitSeq?.let { members["commitSeq"] = number(it) }
        members["time"] = number(time)
        members["origin"] = origin.toJson()
        members["traceId"] = JsonString(traceId)
        members["principal"] = principal.toJson()
        causationId?.let { members["causationId"] = JsonString(it) }
        correlationId?.let { members["correlationId"] = JsonString(it) }
        turnId?.let { members["turnId"] = JsonString(it) }
        runId?.let { members["runId"] = JsonString(it) }
        attempt?.let { members["attempt"] = number(it.toLong()) }
        batch?.let { members["batch"] = it.toJson() }
        ignorable?.let { members["ignorable"] = JsonBool(it) }
        members["data"] = dataOverride ?: data
        return JsonObject(members)
    }

    public fun withCommitSeq(sequence: Long): BotEvent = copy(commitSeq = sequence)

    public fun withBatch(batch: BotEventBatch?): BotEvent = copy(batch = batch)

    public fun withData(data: JsonValue): BotEvent = copy(data = data)

    public companion object {
        public fun fromJson(value: JsonValue): BotEvent {
            val members = (value as? JsonObject)?.members
                ?: throw invalidEvent("event", "event must be an object")
            return BotEvent(
                schemaVersion = long(members["schemaVersion"])?.toInt()
                    ?: throw invalidEvent("schemaVersion", "schemaVersion is required"),
                type = string(members["type"]) ?: throw invalidEvent("type", "type is required"),
                eventId = string(members["eventId"])
                    ?: throw invalidEvent("eventId", "eventId is required"),
                commitSeq = optionalLong(members["commitSeq"]),
                time = long(members["time"]) ?: throw invalidEvent("time", "time is required"),
                origin = BotEventOrigin.fromJson(members["origin"]),
                traceId = string(members["traceId"])
                    ?: throw invalidEvent("traceId", "traceId is required"),
                principal = BotPrincipal.fromJson(members["principal"]),
                causationId = optionalString(members["causationId"]),
                correlationId = optionalString(members["correlationId"]),
                turnId = optionalString(members["turnId"]),
                runId = optionalString(members["runId"]),
                attempt = optionalLong(members["attempt"])?.toInt(),
                batch = members["batch"]?.let { if (it is JsonNull) null else BotEventBatch.fromJson(it) },
                ignorable = when (val flag = members["ignorable"]) {
                    null, is JsonNull -> null
                    is JsonBool -> flag.value
                    else -> throw invalidEvent("ignorable", "ignorable must be a boolean")
                },
                data = members["data"] ?: throw invalidEvent("data", "data is required"),
            )
        }
    }
}

/** Envelope validation and the three canonical byte surfaces (`store.md` §4–§5). */
public object BotEventCodec {
    public const val CURRENT_SCHEMA_VERSION: Int = 1

    public val durableEventTypes: Set<String> = setOf(
        "conversation.turn_started", "conversation.user_message", "conversation.assistant_message",
        "conversation.tool_call", "conversation.tool_result", "conversation.turn_ended",
        "conversation.automation_run", "approval.requested", "approval.decided", "authz.grant_snapshot",
        "grant.created", "grant.added", "grant.consumed", "grant.revoked", "grant.migrated", "card.presented",
        "card.answered", "card.dismissed",
        "ui.system_event", "ui.notice", "ui.send_to_user", "transcript.rollback",
        "transcript.row_deleted", "transcript.imported", "bot.greeting_seeded", "bot.created",
        "comm.outbound", "comm.inbound", "comm.reply", "comm.failed", "agent.comm",
        "task.created", "task.started",
        "task.updated", "task.stop_requested", "task.settled", "task.resumed", "background.started",
        "background.stop_requested", "background.settled", "routine.defined", "routine.updated",
        "routine.deleted", "routine.run_started", "routine.run_finished", "memory.written",
        "memory.forgotten", "memory.document_written", "memory.document_deleted",
        "memory.imported", "memory.review_requested", "memory.review_resolved",
        "memory.maintenance_started", "memory.maintenance_finished",
        "memory.maintenance_rolled_back",
        "effect.enqueued", "effect.attempted", "effect.acked", "effect.failed", "effect.dead_lettered",
        "effect.reconciliation_required", "effect.cancel_requested", "effect.canceled", "runtime.started",
        "runtime.exited", "proactive.considered", "ledger.usage_recorded", "watchdog.flagged",
        "verification.reported", "redaction.applied", "erasure",
    )

    public val ephemeralEventTypes: Set<String> = setOf(
        "model.delta", "model.started", "model.settled", "tool.progress", "agent.status", "fish.action",
        "runtime.stderr", "runtime.notification", "projection.invalidated", "journal.backpressure",
        "approval.card_available",
    )

    private val localOriginSources: Set<String> = setOf(
        "ipc", "card-bridge", "mcp", "scheduler", "task-manager", "memory-service", "comm-service",
        "projector", "effect-runner", "runtime", "user", "watchdog", "background-supervisor",
    )

    private val principalKinds: Set<String> = setOf(
        "chat", "task", "routine", "verifier", "team", "proactive", "watchdog", "maintainer", "ipc",
    )

    public enum class Mode { APPEND, STORED }

    public fun isEphemeral(type: String): Boolean = type in ephemeralEventTypes

    public fun isDurable(type: String): Boolean = type in durableEventTypes

    public fun validate(event: BotEvent, mode: Mode = Mode.STORED) {
        if (event.schemaVersion > CURRENT_SCHEMA_VERSION) {
            throw BotEventValidationException(
                "SCHEMA_TOO_NEW", "schemaVersion",
                "schemaVersion ${event.schemaVersion} is newer than $CURRENT_SCHEMA_VERSION; reader is read-only",
            )
        }
        if (event.schemaVersion != CURRENT_SCHEMA_VERSION) {
            throw invalidEvent("schemaVersion", "schemaVersion must be $CURRENT_SCHEMA_VERSION")
        }
        if (event.eventId.isEmpty()) throw invalidEvent("eventId", "eventId must not be empty")
        if (event.traceId.isEmpty()) throw invalidEvent("traceId", "traceId must not be empty")
        if (event.time < 0) throw invalidEvent("time", "time must not be negative")
        if (event.principal.kind !in principalKinds) {
            throw invalidEvent("principal.kind", "unknown principal kind")
        }
        when (val origin = event.origin) {
            is BotEventOrigin.Dsh -> {
                if (origin.sessionId.isEmpty() || origin.seq < 0) {
                    throw invalidEvent("origin", "DSH origin requires sessionId and non-negative seq")
                }
            }
            is BotEventOrigin.Local -> {
                if (origin.source !in localOriginSources) {
                    throw invalidEvent("origin.source", "unknown local origin source")
                }
            }
        }
        event.attempt?.let {
            if (it < 1) throw invalidEvent("attempt", "attempt must be a positive integer")
        }
        event.turnId?.let {
            if (it.isEmpty()) throw invalidEvent("turnId", "turnId must not be empty")
        }
        event.runId?.let {
            if (it.isEmpty()) throw invalidEvent("runId", "runId must not be empty")
        }
        event.batch?.let { batch ->
            if (batch.id.isEmpty() || batch.total < 1 || batch.index < 0 || batch.index >= batch.total) {
                throw invalidEvent("batch", "invalid batch reference")
            }
        }
        event.ignorable?.let {
            if (!it) throw invalidEvent("ignorable", "ignorable may only be true or omitted")
        }
        if (event.data !is JsonObject) {
            throw invalidEvent("data", "event data must be an object")
        }

        if (isEphemeral(event.type)) {
            if (event.commitSeq != null) {
                throw BotEventValidationException(
                    "EPHEMERAL_HAS_COMMIT_SEQ", "commitSeq",
                    "ephemeral events must not carry commitSeq",
                )
            }
            return
        }
        if (!isDurable(event.type) && event.ignorable != true) {
            throw BotEventValidationException(
                "UNKNOWN_REQUIRED_EVENT", "type",
                "unknown event type \"${event.type}\" is not ignorable; refusing to skip it",
            )
        }
        when (mode) {
            Mode.APPEND -> {
                if (event.commitSeq != null) {
                    throw BotEventValidationException(
                        "COMMIT_SEQ_ASSIGNED_BY_STORE", "commitSeq",
                        "commitSeq is assigned by SQLite and must not be provided",
                    )
                }
            }
            Mode.STORED -> {
                val sequence = event.commitSeq
                    ?: throw BotEventValidationException(
                        "MISSING_COMMIT_SEQ", "commitSeq", "durable events require a commitSeq",
                    )
                if (sequence < 1) throw invalidEvent("commitSeq", "commitSeq must be positive")
            }
        }
    }

    /** Canonical `header_meta`: the full envelope with `data` replaced by `{}`. */
    public fun encodeHeaderMeta(event: BotEvent): ByteArray {
        val stored = if (event.commitSeq != null) event else event.withCommitSeq(0)
        require(stored.commitSeq != null && stored.commitSeq!! >= 1) {
            "header_meta requires the store-assigned commitSeq"
        }
        return encodeCanonical(stored.toJson(JsonObject(emptyMap())))
    }

    /** Canonical bytes of `data` only; the payload digest covers exactly these. */
    public fun encodeData(data: JsonValue): ByteArray {
        if (data !is JsonObject) throw invalidEvent("data", "event data must be an object")
        return encodeCanonical(data)
    }

    public fun decodeData(bytes: ByteArray): JsonObject {
        val parsed = try {
            JsonValue.parse(bytes.toString(Charsets.UTF_8))
        } catch (error: Exception) {
            throw corrupted("payload is not valid JSON: ${error.message}")
        }
        return parsed as? JsonObject ?: throw corrupted("payload data is not an object")
    }

    public fun encodeCanonical(value: JsonValue): ByteArray =
        BotJson.canonical(normalizeNumbers(value)).toByteArray(Charsets.UTF_8)

    public fun decode(bytes: ByteArray, mode: Mode = Mode.STORED): BotEvent {
        val parsed = try {
            JsonValue.parse(bytes.toString(Charsets.UTF_8))
        } catch (error: Exception) {
            throw invalidEvent("event", "event is not valid JSON: ${error.message}")
        }
        val event = BotEvent.fromJson(parsed)
        validate(event, mode)
        return event
    }

    private fun normalizeNumbers(value: JsonValue): JsonValue = when (value) {
        is JsonNumber -> {
            val integral = value.asLongOrNull()
            if (integral != null) JsonNumber(integral.toString()) else value
        }
        is JsonArray -> JsonArray(value.values.map(::normalizeNumbers))
        is JsonObject -> JsonObject(value.members.mapValues { normalizeNumbers(it.value) })
        else -> value
    }
}

internal fun number(value: Long): JsonNumber = JsonNumber(value.toString())

internal fun string(value: JsonValue?): String? = (value as? JsonString)?.value

internal fun long(value: JsonValue?): Long? = (value as? JsonNumber)?.asLongOrNull()

internal fun optionalLong(value: JsonValue?): Long? = when (value) {
    null, is JsonNull -> null
    is JsonNumber -> value.asLongOrNull()
    else -> throw invalidEvent("value", "value must be an integer")
}

internal fun optionalString(value: JsonValue?): String? = when (value) {
    null, is JsonNull -> null
    is JsonString -> value.value
    else -> throw invalidEvent("value", "value must be a string")
}

private fun Set<String>.allMatch(allowed: Set<String>): Boolean = all { it in allowed }
