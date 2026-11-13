// SPDX-License-Identifier: MIT
package com.phonedsh.bot.authz

import com.phonedsh.agentcore.JsonArray
import com.phonedsh.agentcore.JsonObject
import com.phonedsh.agentcore.JsonString
import com.phonedsh.agentcore.JsonValue
import com.phonedsh.bot.BotJson
import com.phonedsh.bot.session.BotSessionKind
import java.util.UUID

public data class BotAuditPrincipal(
    public val botId: String?,
    public val sessionId: String? = null,
    public val kind: String,
    public val sessionKind: BotSessionKind? = null,
    public val certain: Boolean,
) {
    public fun toJson(): JsonObject {
        val members = linkedMapOf<String, JsonValue>(
            "kind" to JsonString(kind),
            "certain" to com.phonedsh.agentcore.JsonBool(certain),
        )
        botId?.let { members["botId"] = JsonString(it) }
        sessionId?.let { members["sessionId"] = JsonString(it) }
        sessionKind?.let { members["sessionKind"] = JsonString(it.wire) }
        return JsonObject(members)
    }
}

public data class BotAuditEffect(
    public val tool: String,
    public val operation: String,
    public val resourceDigest: String,
    public val argsDigest: String?,
    public val mutability: BotToolMutability,
    public val policy: BotToolPolicy,
) {
    public fun toJson(): JsonObject = BotJson.objectOf(
        "tool" to JsonString(tool),
        "operation" to JsonString(operation),
        "resourceDigest" to JsonString(resourceDigest),
        "argsDigest" to (argsDigest?.let(::JsonString) ?: com.phonedsh.agentcore.JsonNull),
        "mutability" to JsonString(mutability.wire),
        "policy" to JsonString(policy.wire),
    )
}

public data class BotAuditGrant(
    public val id: String,
    public val scope: BotGrantScope,
    public val decision: BotGrantDecision,
    public val resourceDigest: String,
) {
    public fun toJson(): JsonObject = BotJson.objectOf(
        "id" to JsonString(id),
        "scope" to JsonString(scope.wire),
        "decision" to JsonString(decision.wire),
        "resourceDigest" to JsonString(resourceDigest),
    )
}

public data class BotAuditRecord(
    public val at: Long,
    public val event: String = "tool-execution",
    public val source: String,
    public val decision: BotGrantDecision,
    public val principal: BotAuditPrincipal,
    public val effects: List<BotAuditEffect> = emptyList(),
    public val grants: List<BotAuditGrant> = emptyList(),
    public val reason: String,
) {
    public val schemaVersion: Int = 1

    public fun toJson(): JsonObject = BotJson.objectOf(
        "schemaVersion" to BotJson.number(schemaVersion.toLong()),
        "at" to BotJson.number(at),
        "event" to JsonString(event),
        "source" to JsonString(source),
        "decision" to JsonString(decision.wire),
        "principal" to principal.toJson(),
        "effects" to JsonArray(effects.map { it.toJson() }),
        "grants" to JsonArray(grants.map { it.toJson() }),
        "reason" to JsonString(reason),
    )
}

public interface BotAuditRecorder {
    /** Returns false when the audit backend rejected the record. */
    public fun append(record: BotAuditRecord): Boolean
}

/**
 * The durable audit writer. It maps the audit kinds onto the existing P25
 * event types instead of inventing an `authz.audit` event type.
 */
public class BotAuditLog(
    private val eventLog: BotAuthzEventLog,
) : BotAuditRecorder {
    override fun append(record: BotAuditRecord): Boolean {
        val type = when (record.event) {
            "tool-execution" -> "effect.attempted"
            "grant.added", "grant.consumed", "grant.revoked" -> record.event
            else -> return false
        }
        val eventId = "authz-" + UUID.randomUUID().toString().lowercase()
        return try {
            eventLog.append(
                BotAuthzEvent(
                    sequence = 0,
                    type = type,
                    eventId = eventId,
                    time = record.at,
                    principal = BotAuthzPrincipal(
                        botId = record.principal.botId,
                        sessionId = record.principal.sessionId,
                        kind = principalKind(record.principal),
                    ),
                    data = record.toJson(),
                ),
            )
            true
        } catch (_: Exception) {
            false
        }
    }

    private fun principalKind(principal: BotAuditPrincipal): String {
        principal.sessionKind?.let { return it.wire }
        return when (principal.kind) {
            "chat", "task", "routine", "team", "proactive", "watchdog", "ipc" -> principal.kind
            "model" -> "chat"
            else -> "ipc"
        }
    }
}

/** A deterministic in-memory recorder for tests and port adapters. */
public class BotInMemoryAuditRecorder : BotAuditRecorder {
    private val recordsMutable = ArrayList<BotAuditRecord>()

    public val records: List<BotAuditRecord>
        @Synchronized get() = recordsMutable.toList()

    @Synchronized
    override fun append(record: BotAuditRecord): Boolean {
        recordsMutable += record
        return true
    }
}
