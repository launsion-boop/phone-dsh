// SPDX-License-Identifier: MIT
package com.phonedsh.bot.profile

import com.phonedsh.agentcore.JsonBool
import com.phonedsh.agentcore.JsonNull
import com.phonedsh.agentcore.JsonString
import com.phonedsh.agentcore.JsonValue

/**
 * The Bot roster read from `agents-index.json` plus the repaired main-Bot
 * pointer from `runtime-settings.json`.
 *
 * `bots` keeps the on-disk insertion order and includes hidden Bots; the
 * sidebar consumes [visibleBots]. The main Bot is a pointer, not a record flag.
 */
public data class BotRoster(
    public val bots: List<BotProfile>,
    public val mainBotID: String?,
) {
    public val visibleBots: List<BotProfile>
        get() = bots.filter { !it.hiddenByUser }
}

/** The pure roster rules frozen by `bot-profile.json#/rosterRules`. */
public object BotRosterRules {
    /**
     * A valid stored pointer wins; nil, dangling and empty-roster pointers fall
     * back to the first record in insertion order.
     */
    public fun repairMainBotID(recordIDs: List<String>, stored: String?): String? {
        if (stored != null && recordIDs.contains(stored)) return stored
        return recordIDs.firstOrNull()
    }

    /**
     * Delete one record and migrate the pointer. The store refuses the last
     * Bot; this pure rule exposes that as [BotRosterDeleteOutcome.LastBot].
     */
    public fun delete(
        recordIDs: List<String>,
        mainAgentID: String?,
        deleteID: String,
    ): BotRosterDeleteOutcome {
        val removedIndex = recordIDs.indexOf(deleteID)
        if (removedIndex < 0) return BotRosterDeleteOutcome.UnknownBot
        if (recordIDs.size <= 1) return BotRosterDeleteOutcome.LastBot
        val oldMain = repairMainBotID(recordIDs, mainAgentID)
        val remaining = recordIDs.filterIndexed { index, _ -> index != removedIndex }
        val newMain = when {
            oldMain == deleteID -> remaining.firstOrNull()
            oldMain != null && remaining.contains(oldMain) -> oldMain
            else -> remaining.firstOrNull()
        }
        return BotRosterDeleteOutcome.Deleted(remaining = remaining, mainBotID = newMain)
    }

    /**
     * Normalize a profile patch as `agents/model.cjs` does: identity and the
     * main pointer are control fields the caller may not inject, names are
     * trimmed, fish fields go through the null/auto normalizer, and fields not
     * in [PATCHABLE_FIELDS] are dropped.
     */
    public fun normalizePatch(input: Map<String, JsonValue>): Map<String, JsonValue> {
        val output = LinkedHashMap<String, JsonValue>()
        for ((key, value) in input) {
            when (key) {
                "name" -> if (value is JsonString) output["name"] = JsonString(value.value.trim())
                "description" -> if (value is JsonString) output["description"] = value
                "fish_color" -> output["fish_color"] = normalizedFishColor(value)
                "fish_hairstyle" -> output["fish_hairstyle"] = normalizedFishHairstyle(value)
                "hidden_by_user" -> if (value is JsonBool) output["hidden_by_user"] = value
                else -> Unit
            }
        }
        return output
    }

    private fun normalizedFishColor(value: JsonValue): JsonValue {
        if (value is JsonNull) return JsonNull
        val normalized = BotProfileNormalizer.fishColor((value as? JsonString)?.value)
        return normalized?.let { JsonString(it.wire) } ?: JsonNull
    }

    private fun normalizedFishHairstyle(value: JsonValue): JsonValue {
        if (value is JsonNull) return JsonNull
        val normalized = BotProfileNormalizer.fishHairstyle((value as? JsonString)?.value)
        return normalized?.let { JsonString(it.wire) } ?: JsonNull
    }

    public val PATCHABLE_FIELDS: Set<String> =
        setOf("name", "description", "fish_color", "fish_hairstyle", "hidden_by_user")
}

/** Result of [BotRosterRules.delete]. */
public sealed interface BotRosterDeleteOutcome {
    public data class Deleted(
        public val remaining: List<String>,
        public val mainBotID: String?,
    ) : BotRosterDeleteOutcome

    public data object UnknownBot : BotRosterDeleteOutcome
    public data object LastBot : BotRosterDeleteOutcome
}
