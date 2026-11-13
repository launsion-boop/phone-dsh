// SPDX-License-Identifier: MIT
package com.phonedsh.ui.bot.state

import com.phonedsh.agentcore.JsonNull
import com.phonedsh.agentcore.JsonObject
import com.phonedsh.agentcore.JsonString
import com.phonedsh.agentcore.JsonValue
import com.phonedsh.bot.BotJson
import com.phonedsh.bot.BotJsonException
import com.phonedsh.bot.fish.BotFishLifecycle
import com.phonedsh.bot.fish.BotFishOneShot

/** `activity.status` (P09 `activity.schema.json`). */
public enum class BotActivityStatus(public val wire: String) {
    THINKING("thinking"),
    TOOL_RUNNING("tool-running"),
    STREAMING("streaming"),
    ;

    public companion object {
        public fun fromWire(value: String): BotActivityStatus =
            entries.firstOrNull { it.wire == value }
                ?: throw BotJsonException("unknown activity status: $value")
    }
}

/** `activity.category` (P09 `activity.schema.json`). */
public enum class BotActivityCategory(public val wire: String) {
    THINKING("thinking"),
    READING("reading"),
    SEARCHING("searching"),
    BROWSING("browsing"),
    RUNNING("running"),
    WRITING("writing"),
    MEMORY("memory"),
    MESSAGING("messaging"),
    REVIEWING("reviewing"),
    WAITING("waiting"),
    REPLYING("replying"),
    GENERIC("generic"),
    ;

    public companion object {
        public fun fromWire(value: String): BotActivityCategory =
            entries.firstOrNull { it.wire == value }
                ?: throw BotJsonException("unknown activity category: $value")
    }
}

/** The fish's App-only working sub-style (`ui-state.md` §2.3 / §4.6). */
public enum class BotWorkStyle(public val wire: String) {
    GENERIC("generic"),
    READING("reading"),
    SEARCHING("searching"),
    RUNNING("running"),
    WRITING("writing"),
}

/**
 * The current phase of the running turn (`BotRuntimePresentation.activity`).
 * `detail` is display text; `category` always follows the tool name.
 */
public data class BotActivity(
    public val status: BotActivityStatus,
    public val detail: String = "",
    public val category: BotActivityCategory = BotActivityCategory.GENERIC,
    public val startedAt: Long = 0,
) {
    public fun toJson(): JsonObject = BotJson.objectOf(
        "status" to JsonString(status.wire),
        "detail" to JsonString(detail),
        "category" to JsonString(category.wire),
        "startedAt" to BotJson.number(startedAt),
    )

    public companion object {
        public fun fromJson(value: JsonValue): BotActivity {
            val members = JsonSupport.objectMembers(value, "activity")
            return BotActivity(
                status = BotActivityStatus.fromWire(
                    JsonSupport.requiredString(members, "status", "activity.status")),
                detail = JsonSupport.requiredString(members, "detail", "activity.detail"),
                category = BotActivityCategory.fromWire(
                    JsonSupport.requiredString(members, "category", "activity.category")),
                startedAt = JsonSupport.requiredNonNegativeLong(
                    members, "startedAt", "activity.startedAt"),
            )
        }
    }
}

/** `reaction.kind` (P09 `presentation.schema.json`). */
public enum class BotFishReactionKind(public val wire: String) {
    ACTION("action"),
    EXPRESSION("expression"),
    ;

    public companion object {
        public fun fromWire(value: String): BotFishReactionKind =
            entries.firstOrNull { it.wire == value }
                ?: throw BotJsonException("unknown reaction kind: $value")
    }
}

/**
 * The latest active one-shot reaction of a Bot. It is active iff
 * `startedAt <= now < startedAt + durationMs`; the view never extends it.
 */
public data class BotFishReaction(
    public val id: String,
    public val botID: String? = null,
    public val kind: BotFishReactionKind,
    public val name: String,
    public val startedAt: Long,
    public val durationMs: Long,
) {
    public fun isActive(now: Long): Boolean = startedAt <= now && now < startedAt + durationMs

    public fun toJson(): JsonObject = BotJson.objectOf(
        "id" to JsonString(id),
        "botID" to (botID?.let(::JsonString) ?: JsonNull),
        "kind" to JsonString(kind.wire),
        "name" to JsonString(name),
        "startedAt" to BotJson.number(startedAt),
        "durationMs" to BotJson.number(durationMs),
    )

    public companion object {
        public fun fromJson(value: JsonValue): BotFishReaction {
            val members = JsonSupport.objectMembers(value, "reaction")
            val id = JsonSupport.requiredString(members, "id", "reaction.id")
            if (id.isEmpty()) throw BotJsonException("reaction.id must not be empty")
            val name = JsonSupport.requiredString(members, "name", "reaction.name")
            if (name.isEmpty()) throw BotJsonException("reaction.name must not be empty")
            val duration = JsonSupport.requiredLong(members, "durationMs", "reaction.durationMs")
            if (duration < 1) throw BotJsonException("reaction.durationMs must be >= 1")
            return BotFishReaction(
                id = id,
                botID = JsonSupport.optionalString(members, "botID", "reaction.botID"),
                kind = BotFishReactionKind.fromWire(
                    JsonSupport.requiredString(members, "kind", "reaction.kind")),
                name = name,
                startedAt = JsonSupport.requiredNonNegativeLong(
                    members, "startedAt", "reaction.startedAt"),
                durationMs = duration,
            )
        }
    }
}

/**
 * The projection half of a Bot page (`BotRuntimePresentation`). Every member
 * is optional at the JSON edge; absent means the value's default.
 */
public data class BotRuntimePresentation(
    public val fishState: BotFishLifecycle = BotFishLifecycle.IDLE,
    public val runningTurnID: String? = null,
    public val activity: BotActivity? = null,
    public val reaction: BotFishReaction? = null,
    public val oneShot: BotFishOneShot? = null,
) {
    public fun toJson(): JsonObject = BotJson.objectOf(
        "fishState" to JsonString(fishState.wire),
        "runningTurnID" to (runningTurnID?.let(::JsonString) ?: JsonNull),
        "activity" to (activity?.toJson() ?: JsonNull),
        "reaction" to (reaction?.toJson() ?: JsonNull),
        "oneShot" to (oneShot?.toJson() ?: JsonNull),
    )

    public companion object {
        public fun fromJson(value: JsonValue): BotRuntimePresentation {
            val members = JsonSupport.objectMembers(value, "presentation")
            val fishState = JsonSupport.string(members["fishState"])?.let { raw ->
                BotFishLifecycle.fromWire(raw)
                    ?: throw BotJsonException("presentation.fishState has unknown value: $raw")
            } ?: BotFishLifecycle.IDLE
            val activity = JsonSupport.optionalObject(members["activity"], "presentation.activity")
                ?.let { BotActivity.fromJson(JsonObject(it)) }
            val reaction = JsonSupport.optionalObject(members["reaction"], "presentation.reaction")
                ?.let { BotFishReaction.fromJson(JsonObject(it)) }
            val oneShot = JsonSupport.optionalObject(members["oneShot"], "presentation.oneShot")
                ?.let { decodeOneShot(it) }
            return BotRuntimePresentation(
                fishState = fishState,
                runningTurnID = JsonSupport.optionalString(
                    members, "runningTurnID", "presentation.runningTurnID"),
                activity = activity,
                reaction = reaction,
                oneShot = oneShot,
            )
        }

        private fun decodeOneShot(members: Map<String, JsonValue>): BotFishOneShot {
            val rawState = JsonSupport.requiredString(members, "state", "oneShot.state")
            val state = BotFishLifecycle.fromWire(rawState)
                ?: throw BotJsonException("oneShot.state has unknown value: $rawState")
            return BotFishOneShot(
                state = state,
                priority = JsonSupport.requiredLong(members, "priority", "oneShot.priority").toInt(),
                startedAt = JsonSupport.requiredNonNegativeLong(
                    members, "startedAt", "oneShot.startedAt"),
                endsAt = JsonSupport.requiredNonNegativeLong(members, "endsAt", "oneShot.endsAt"),
            )
        }
    }
}

/**
 * The UI-visible connection state (`BotRuntimeState`), bound as
 * `{"kind":"failed","message":"…"}` for the associated value.
 */
public sealed interface BotRuntimeState {
    public val wire: String

    public data object Idle : BotRuntimeState {
        override val wire: String get() = "idle"
    }

    public data object Preparing : BotRuntimeState {
        override val wire: String get() = "preparing"
    }

    public data object Connecting : BotRuntimeState {
        override val wire: String get() = "connecting"
    }

    public data object Ready : BotRuntimeState {
        override val wire: String get() = "ready"
    }

    public data object Recovering : BotRuntimeState {
        override val wire: String get() = "recovering"
    }

    public data class Failed(public val message: String) : BotRuntimeState {
        override val wire: String get() = "failed"
    }

    public data object Stopped : BotRuntimeState {
        override val wire: String get() = "stopped"
    }

    /** Creates the JSON binding; `failed` always carries its non-empty message. */
    public fun toJson(): JsonObject {
        val members = LinkedHashMap<String, JsonValue>()
        members["kind"] = JsonString(wire)
        if (this is Failed) members["message"] = JsonString(message)
        return JsonObject(members)
    }

    public companion object {
        public fun fromJson(value: JsonValue): BotRuntimeState {
            val members = JsonSupport.objectMembers(value, "runtimeState")
            return when (val kind = JsonSupport.requiredString(
                members, "kind", "runtimeState.kind")) {
                "idle" -> Idle
                "preparing" -> Preparing
                "connecting" -> Connecting
                "ready" -> Ready
                "recovering" -> Recovering
                "stopped" -> Stopped
                "failed" -> {
                    val message = JsonSupport.requiredString(
                        members, "message", "runtimeState.message")
                    if (message.isEmpty()) {
                        throw BotJsonException("runtimeState.message must not be empty")
                    }
                    Failed(message)
                }
                else -> throw BotJsonException("unknown runtimeState kind: $kind")
            }
        }
    }
}

/** True when the runtime needs the disconnect banner (`recovering`/`failed`). */
public val BotRuntimeState.requiresDisconnectBanner: Boolean
    get() = this is BotRuntimeState.Recovering || this is BotRuntimeState.Failed
