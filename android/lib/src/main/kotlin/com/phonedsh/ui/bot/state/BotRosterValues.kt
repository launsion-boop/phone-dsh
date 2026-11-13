// SPDX-License-Identifier: MIT
package com.phonedsh.ui.bot.state

import com.phonedsh.agentcore.JsonNull
import com.phonedsh.agentcore.JsonObject
import com.phonedsh.agentcore.JsonString
import com.phonedsh.agentcore.JsonValue
import com.phonedsh.bot.BotJson
import com.phonedsh.bot.BotJsonException
import com.phonedsh.bot.fish.BotFishLifecycle
import com.phonedsh.bot.profile.BotFishAppearance
import com.phonedsh.bot.profile.BotFishColor
import com.phonedsh.bot.profile.BotFishHairstyle

/**
 * The UI-visible runtime state of one roster row (`BotRosterRuntimeState`).
 * Every member is optional at the JSON edge and takes the documented default.
 */
public data class BotRosterRuntimeState(
    public val fishState: BotFishLifecycle = BotFishLifecycle.IDLE,
    public val activity: BotActivity? = null,
    public val isRunning: Boolean = false,
    public val pendingApprovalCount: Int = 0,
    public val reaction: BotFishReaction? = null,
    public val runtimeState: BotRuntimeState = BotRuntimeState.Idle,
) {
    public fun toJson(): JsonObject = BotJson.objectOf(
        "fishState" to JsonString(fishState.wire),
        "activity" to (activity?.toJson() ?: JsonNull),
        "isRunning" to com.phonedsh.agentcore.JsonBool(isRunning),
        "pendingApprovalCount" to BotJson.number(pendingApprovalCount.toLong()),
        "reaction" to (reaction?.toJson() ?: JsonNull),
        "runtimeState" to runtimeState.toJson(),
    )

    public companion object {
        public fun fromJson(value: JsonValue): BotRosterRuntimeState {
            val members = JsonSupport.objectMembers(value, "roster.runtime")
            val fishState = JsonSupport.string(members["fishState"])?.let { raw ->
                BotFishLifecycle.fromWire(raw)
                    ?: throw BotJsonException("roster.runtime.fishState has unknown value: $raw")
            } ?: BotFishLifecycle.IDLE
            val activity = JsonSupport.optionalObject(members["activity"], "roster.runtime.activity")
                ?.let { BotActivity.fromJson(JsonObject(it)) }
            val reaction = JsonSupport.optionalObject(members["reaction"], "roster.runtime.reaction")
                ?.let { BotFishReaction.fromJson(JsonObject(it)) }
            val pending = JsonSupport.optionalNonNegativeInt(
                members, "pendingApprovalCount", "roster.runtime.pendingApprovalCount") ?: 0
            val runtimeState = members["runtimeState"]?.let { BotRuntimeState.fromJson(it) }
                ?: BotRuntimeState.Idle
            return BotRosterRuntimeState(
                fishState = fishState,
                activity = activity,
                isRunning = JsonSupport.optionalBool(
                    members, "isRunning", "roster.runtime.isRunning") ?: false,
                pendingApprovalCount = pending,
                reaction = reaction,
                runtimeState = runtimeState,
            )
        }
    }
}

/**
 * One drawer row (`BotRosterEntry`). The entry's fish/activity/running/
 * approval/reaction accessors are pass-throughs of [runtime].
 */
public data class BotRosterEntry(
    public val id: String,
    public val name: String,
    public val description: String,
    public val appearance: BotFishAppearance,
    public val isMainBot: Boolean,
    public val isHidden: Boolean,
    public val unreadCount: Int,
    public val lastMessageAt: Long?,
    public val runtime: BotRosterRuntimeState,
) {
    public val fishState: BotFishLifecycle get() = runtime.fishState
    public val activity: BotActivity? get() = runtime.activity
    public val isRunning: Boolean get() = runtime.isRunning
    public val pendingApprovalCount: Int get() = runtime.pendingApprovalCount
    public val reaction: BotFishReaction? get() = runtime.reaction
    public val runtimeState: BotRuntimeState get() = runtime.runtimeState

    public fun toJson(): JsonObject = BotJson.objectOf(
        "id" to JsonString(id),
        "name" to JsonString(name),
        "description" to JsonString(description),
        "appearance" to BotJson.objectOf(
            "color" to JsonString(appearance.color.wire),
            "hairstyle" to JsonString(appearance.hairstyle.wire),
            "autoColor" to com.phonedsh.agentcore.JsonBool(appearance.autoColor),
            "autoHairstyle" to com.phonedsh.agentcore.JsonBool(appearance.autoHairstyle),
        ),
        "isMainBot" to com.phonedsh.agentcore.JsonBool(isMainBot),
        "isHidden" to com.phonedsh.agentcore.JsonBool(isHidden),
        "unreadCount" to BotJson.number(unreadCount.toLong()),
        "lastMessageAt" to (lastMessageAt?.let(BotJson::number) ?: JsonNull),
        "runtime" to runtime.toJson(),
    )

    public companion object {
        public fun fromJson(value: JsonValue): BotRosterEntry {
            val members = JsonSupport.objectMembers(value, "rosterEntry")
            val id = JsonSupport.requiredString(members, "id", "rosterEntry.id")
            if (id.isEmpty()) throw BotJsonException("rosterEntry.id must not be empty")
            val name = JsonSupport.requiredString(members, "name", "rosterEntry.name")
            if (name.isEmpty()) throw BotJsonException("rosterEntry.name must not be empty")
            // The schema's `maxLength` is 60; the profile-store rule in
            // ui-state.md §4.10 is 60 UTF-16 code units.
            if (name.length > 60) throw BotJsonException("rosterEntry.name must be <= 60 units")
            val appearance = JsonSupport.objectMembers(
                members["appearance"] ?: throw BotJsonException("missing member appearance"),
                "rosterEntry.appearance",
            )
            val color = BotFishColor.fromWire(
                JsonSupport.requiredString(appearance, "color", "appearance.color"))
                ?: throw BotJsonException("appearance.color has unknown value")
            val hairstyle = BotFishHairstyle.fromWire(
                JsonSupport.requiredString(appearance, "hairstyle", "appearance.hairstyle"))
                ?: throw BotJsonException("appearance.hairstyle has unknown value")
            val runtime = members["runtime"]
                ?: throw BotJsonException("missing member runtime")
            return BotRosterEntry(
                id = id,
                name = name,
                description = JsonSupport.requiredString(
                    members, "description", "rosterEntry.description"),
                appearance = BotFishAppearance(
                    color = color,
                    hairstyle = hairstyle,
                    autoColor = JsonSupport.requiredBool(
                        appearance, "autoColor", "appearance.autoColor"),
                    autoHairstyle = JsonSupport.requiredBool(
                        appearance, "autoHairstyle", "appearance.autoHairstyle"),
                ),
                isMainBot = JsonSupport.requiredBool(members, "isMainBot", "rosterEntry.isMainBot"),
                isHidden = JsonSupport.requiredBool(members, "isHidden", "rosterEntry.isHidden"),
                unreadCount = JsonSupport.requiredNonNegativeInt(
                    members, "unreadCount", "rosterEntry.unreadCount"),
                lastMessageAt = JsonSupport.optionalNonNegativeLong(
                    members, "lastMessageAt", "rosterEntry.lastMessageAt"),
                runtime = BotRosterRuntimeState.fromJson(runtime),
            )
        }
    }
}

/**
 * The frozen roster order: the main Bot first, then insertion order.
 * `visibleEntries` additionally removes hidden Bots and is what the drawer shows.
 */
public object BotRosterOrdering {
    public fun ordered(entries: List<BotRosterEntry>): List<BotRosterEntry> {
        val main = entries.filter { it.isMainBot }
        val rest = entries.filterNot { it.isMainBot }
        return main + rest
    }

    public fun visibleEntries(entries: List<BotRosterEntry>): List<BotRosterEntry> =
        ordered(entries).filterNot { it.isHidden }
}
