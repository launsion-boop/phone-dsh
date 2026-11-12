// SPDX-License-Identifier: MIT
package com.phonedsh.bot.memory

import com.phonedsh.agentcore.JsonArray
import com.phonedsh.agentcore.JsonNull
import com.phonedsh.agentcore.JsonNumber
import com.phonedsh.agentcore.JsonObject
import com.phonedsh.agentcore.JsonString
import com.phonedsh.agentcore.JsonValue
import com.phonedsh.bot.BotJsonException

public enum class BotMemoryTier(public val wire: String) {
    PROFILE("profile"),
    LOG("log"),
    NOTE("note"),
    ;

    public companion object {
        public fun parse(value: String?): BotMemoryTier? = entries.firstOrNull { it.wire == value }
    }
}

/**
 * Pre-v2 fact payload (`memory-legacy-fact.schema.json`). This is a migration
 * input only; it is not a live memory shape. Unknown members are tolerated
 * because the schema allows them.
 */
public data class BotMemoryLegacyFact(
    public val factId: String,
    public val text: String,
    public val learnedAtMs: Long,
    public val tier: BotMemoryTier,
    public val scope: BotMemoryScope,
    public val key: String? = null,
    public val evidence: List<String> = emptyList(),
) {
    public fun toJson(): JsonObject {
        val members = LinkedHashMap<String, JsonValue>()
        members["fact_id"] = JsonString(factId)
        members["text"] = JsonString(text)
        members["learned_at_ms"] = JsonNumber(learnedAtMs.toString())
        members["tier"] = JsonString(tier.wire)
        members["scope"] = JsonString(scope.wire)
        key?.let { members["key"] = JsonString(it) }
        if (evidence.isNotEmpty()) members["evidence"] = JsonArray(evidence.map(::JsonString))
        return JsonObject(members)
    }

    public companion object {
        public fun fromJson(value: JsonValue?): BotMemoryLegacyFact {
            val members = BotMemoryJson.objectMembers(value, "fact")
            val factId = BotMemoryJson.string(members["fact_id"], "fact.fact_id")
            if (factId.isEmpty()) throw BotJsonException("fact.fact_id must not be empty")
            val text = BotMemoryJson.string(members["text"], "fact.text")
            if (text.isEmpty()) throw BotJsonException("fact.text must not be empty")
            if (BotMemoryText.scalarCount(text) > 2_000) {
                throw BotJsonException("fact.text exceeds 2000 scalars")
            }
            val learned = BotMemoryJson.integer64(members["learned_at_ms"], "fact.learned_at_ms")
            if (learned < 0) throw BotJsonException("fact.learned_at_ms must not be negative")
            val tier = BotMemoryTier.parse(BotMemoryJson.string(members["tier"], "fact.tier"))
                ?: throw BotJsonException("fact.tier must be profile, log or note")
            val scope = BotMemoryScope.parse(BotMemoryJson.string(members["scope"], "fact.scope"))
                ?: throw BotJsonException("fact.scope must be agent or user")
            val key = when (val raw = members["key"]) {
                null, is JsonNull -> null
                is JsonString -> raw.value
                else -> throw BotJsonException("fact.key must be a string or null")
            }
            if (key != null && BotMemoryText.scalarCount(key) > 200) {
                throw BotJsonException("fact.key is too long")
            }
            val evidence = BotMemoryJson.evidenceArray(members["evidence"], "fact.evidence")
            if (evidence.size > 8) throw BotJsonException("fact.evidence may have at most 8 items")
            evidence.forEach { BotMemoryEvidence.validateStoredReference(it) }
            return BotMemoryLegacyFact(
                factId = factId,
                text = text,
                learnedAtMs = learned,
                tier = tier,
                scope = scope,
                key = key,
                evidence = evidence,
            )
        }
    }
}
