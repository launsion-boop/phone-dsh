// SPDX-License-Identifier: MIT
package com.phonedsh.bot.authz

import com.phonedsh.agentcore.JsonArray
import com.phonedsh.agentcore.JsonNull
import com.phonedsh.agentcore.JsonObject
import com.phonedsh.agentcore.JsonString
import com.phonedsh.bot.BotJson
import java.util.UUID

/** The reason a durable grant snapshot could not be trusted. */
public enum class BotGrantRecoveryReason {
    MISSING_SNAPSHOT,
    INVALID_SNAPSHOT,
    UNSUPPORTED_SNAPSHOT,
    REPLAY_FAILED,
}

public class BotGrantRecoveryException(
    public val reason: BotGrantRecoveryReason,
    message: String,
) : Exception(message)

/**
 * The frozen `authz.grant_snapshot` payload (`BotGrantSnapshot.swift`).
 *
 * The entry encoder writes all eleven members, including explicit `null` for
 * `sessionId`/`expiresAt`; decoding requires exactly those keys and rejects a
 * non-canonical resource. Recovery keeps the latest snapshot event and drops
 * entries already expired at recovery time.
 */
public object BotGrantSnapshot {
    public const val EVENT_TYPE: String = "authz.grant_snapshot"
    public const val SCHEMA_VERSION: Int = 1

    private val ENTRY_KEYS = setOf(
        "grantId", "botId", "tool", "operation", "canonicalResource", "scope",
        "sessionId", "expiresAt", "createdAt", "source", "decision",
    )

    public fun encode(grants: List<BotGrant>): JsonObject = BotJson.objectOf(
        "grants" to JsonArray(grants.map { it.toSnapshotJson() }),
    )

    public fun decode(event: BotAuthzEvent, now: Long): List<BotGrant> {
        if (event.schemaVersion != SCHEMA_VERSION) {
            throw BotGrantRecoveryException(
                BotGrantRecoveryReason.UNSUPPORTED_SNAPSHOT,
                "unsupported grant snapshot schema ${event.schemaVersion}",
            )
        }
        return decode(event.data, now)
    }

    public fun decode(data: JsonObject, now: Long): List<BotGrant> {
        if (data.members.keys != setOf("grants")) {
            throw invalid("grant snapshot requires exactly one grants member")
        }
        val raw = data.members["grants"] as? JsonArray
            ?: throw invalid("grants must be an array")
        if (raw.values.size > BotGrantStore.MAXIMUM_GRANTS) {
            throw invalid("grant snapshot exceeds the grant limit")
        }
        val identifiers = HashSet<String>()
        val restored = ArrayList<BotGrant>(raw.values.size)
        for (value in raw.values) {
            val grant = decodeEntry(value)
            if (!identifiers.add(grant.id)) throw invalid("duplicate grant id ${grant.id}")
            if (grant.expiresAt == null || grant.expiresAt > now) restored += grant
        }
        return restored
    }

    public fun event(
        grants: List<BotGrant>,
        at: Long,
        eventId: String = "authz-snapshot-" + UUID.randomUUID().toString().lowercase(),
    ): BotAuthzEvent = BotAuthzEvent(
        sequence = 0,
        type = EVENT_TYPE,
        eventId = eventId,
        time = at,
        principal = null,
        data = encode(grants),
        schemaVersion = SCHEMA_VERSION,
    )

    private fun decodeEntry(value: com.phonedsh.agentcore.JsonValue): BotGrant {
        val members = (value as? JsonObject)?.members
            ?: throw invalid("grant entry must be an object")
        if (members.keys != ENTRY_KEYS) {
            throw invalid("grant snapshot entries require exactly the frozen grant fields")
        }
        fun requiredString(key: String): String =
            BotJson.string(members[key]) ?: throw invalid("grant.$key must be a string")
        fun requiredLong(key: String): Long =
            BotJson.long(members[key]) ?: throw invalid("grant.$key must be an integer")

        val grantId = requiredString("grantId")
        val botId = requiredString("botId")
        val tool = requiredString("tool")
        val operation = requiredString("operation")
        val canonicalResource = requiredString("canonicalResource")
        val scope = BotGrantScope.fromWire(requiredString("scope"))
            ?: throw invalid("grant.scope is not frozen")
        val decision = BotGrantDecision.fromWire(requiredString("decision"))
            ?: throw invalid("grant.decision is not frozen")
        val sessionId = when (val raw = members["sessionId"]) {
            null, JsonNull -> null
            is JsonString -> raw.value
            else -> throw invalid("grant.sessionId must be a string or null")
        }
        val expiresAt = when (val raw = members["expiresAt"]) {
            null, JsonNull -> null
            else -> BotJson.long(raw) ?: throw invalid("grant.expiresAt must be an integer or null")
        }
        val createdAt = requiredLong("createdAt")
        val source = requiredString("source")

        val trimmedId = grantId.trim()
        val trimmedBot = botId.trim()
        val trimmedTool = tool.trim()
        val trimmedOperation = operation.trim()
        val trimmedSource = source.trim()
        val normalizedSession = sessionId?.trim()
        if (trimmedId.isEmpty() ||
            trimmedBot != botId || trimmedBot.isEmpty() ||
            trimmedTool != tool || trimmedTool.isEmpty() ||
            trimmedOperation != operation || trimmedOperation.isEmpty() ||
            trimmedSource != source || trimmedSource.isEmpty() ||
            BotResourceNormalizer.normalize(canonicalResource) != canonicalResource ||
            canonicalResource.isEmpty() ||
            createdAt < 0 ||
            normalizedSession != sessionId ||
            (normalizedSession != null && normalizedSession.isEmpty())
        ) {
            throw invalid("grant $grantId is not canonical")
        }
        return BotGrant(
            id = grantId,
            botId = botId,
            tool = tool,
            operation = operation,
            resource = canonicalResource,
            scope = scope,
            sessionId = sessionId,
            expiresAt = expiresAt,
            createdAt = createdAt,
            source = source,
            decision = decision,
        )
    }

    private fun invalid(message: String): BotGrantRecoveryException =
        BotGrantRecoveryException(BotGrantRecoveryReason.INVALID_SNAPSHOT, message)
}
