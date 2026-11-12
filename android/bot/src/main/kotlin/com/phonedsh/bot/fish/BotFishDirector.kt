// SPDX-License-Identifier: MIT
package com.phonedsh.bot.fish

import com.phonedsh.agentcore.JsonBool
import com.phonedsh.agentcore.JsonNull
import com.phonedsh.agentcore.JsonNumber
import com.phonedsh.agentcore.JsonObject
import com.phonedsh.agentcore.JsonString
import com.phonedsh.agentcore.JsonValue
import com.phonedsh.bot.BotJson
import com.phonedsh.bot.BotJsonException
import com.phonedsh.bot.requiredLong
import com.phonedsh.bot.requiredString

/** The frozen `BotFishLifecycle` vocabulary (`Avatar/BotFishDirector.swift`). */
public enum class BotFishLifecycle(public val wire: String) {
    IDLE("idle"),
    THINKING("thinking"),
    STREAMING("streaming"),
    WORKING("working"),
    SLEEPING("sleeping"),
    ALERTING("alerting"),
    LISTENING("listening"),
    SPEAKING("speaking"),
    HAPPY("happy"),
    SAD("sad"),
    SURPRISED("surprised"),
    CONFUSED("confused"),
    LAUGHING("laughing"),
    LOVE("love"),
    ANGRY("angry"),
    WINK("wink"),
    NOD("nod"),
    SHRUG("shrug"),
    CELEBRATE("celebrate"),
    POKE("poke"),
    WAKING("waking"),
    WAITING("waiting"),
    LOADING("loading"),
    DONE("done"),
    STANDBY("standby"),
    SPAWNING("spawning"),
    BOUNCING("bouncing"),
    DANCING("dancing"),
    WAVING("waving"),
    SHY("shy"),
    SMUG("smug"),
    CRYING("crying"),
    SIGHING("sighing"),
    CHEERING("cheering"),
    BOWING("bowing"),
    CLAPPING("clapping"),
    STRETCHING("stretching"),
    YAWNING("yawning"),
    KISS("kiss"),
    SHAKING_HEAD("shaking-head"),
    HIGH_FIVE("high-five"),
    POWERING_DOWN("powering-down"),
    ;

    public companion object {
        public fun fromWire(value: String): BotFishLifecycle? = entries.firstOrNull { it.wire == value }
    }
}

/** A one-shot reaction overlay and its TTL window. */
public data class BotFishOneShot(
    public val state: BotFishLifecycle,
    public val priority: Int,
    public val startedAt: Long,
    public val endsAt: Long,
) {
    public fun toJson(): JsonObject = BotJson.objectOf(
        "state" to JsonString(state.wire),
        "priority" to JsonNumber(priority.toString()),
        "startedAt" to JsonNumber(startedAt.toString()),
        "endsAt" to JsonNumber(endsAt.toString()),
    )
}

/** The deterministic director state; a pure value that can be checkpointed. */
public data class BotFishDirectorState(
    public val lifecycle: BotFishLifecycle = BotFishLifecycle.IDLE,
    public val current: BotFishLifecycle = lifecycle,
    public val priority: Int = BotFishDirector.priority(lifecycle),
    public val oneShot: BotFishOneShot? = null,
    public val lastOneShotAt: Map<String, Long> = emptyMap(),
    public val now: Long = 0,
    public val debounceMs: Long = 3_000,
    public val lastEvent: String? = null,
    public val version: Int = 0,
    public val schemaVersion: Int = 1,
) {
    public fun toJson(): JsonObject {
        val members = LinkedHashMap<String, JsonValue>()
        members["schemaVersion"] = JsonNumber(schemaVersion.toString())
        members["lifecycle"] = JsonString(lifecycle.wire)
        members["current"] = JsonString(current.wire)
        members["priority"] = JsonNumber(priority.toString())
        members["oneShot"] = oneShot?.toJson() ?: JsonNull
        val observed = LinkedHashMap<String, JsonValue>()
        for ((key, value) in lastOneShotAt) observed[key] = JsonNumber(value.toString())
        members["lastOneShotAt"] = JsonObject(observed)
        members["now"] = JsonNumber(now.toString())
        members["debounceMs"] = JsonNumber(debounceMs.toString())
        members["lastEvent"] = lastEvent?.let(::JsonString) ?: JsonNull
        members["version"] = JsonNumber(version.toString())
        return JsonObject(members)
    }

    public companion object {
        /** Builds the initial state from the golden's `initial` object. */
        public fun fromInitialJson(value: JsonValue): BotFishDirectorState {
            val members = (value as? JsonObject)?.members
                ?: throw BotJsonException("fish director initial must be an object")
            val lifecycle = BotFishLifecycle.fromWire(members.requiredString("lifecycle"))
                ?: throw BotJsonException("unknown fish lifecycle")
            val now = members.requiredLong("now")
            if (now < 0) throw BotJsonException("now must be >= 0")
            return BotFishDirectorState(
                lifecycle = lifecycle,
                now = now.coerceAtLeast(0),
            )
        }
    }
}

/** A director command for the fish renderer. */
public data class BotFishCommand(
    public val state: BotFishLifecycle,
    public val oneShot: Boolean,
    public val priority: Int,
    public val ttlMs: Long,
) {
    public fun toJson(): JsonObject = BotJson.objectOf(
        "state" to JsonString(state.wire),
        "oneShot" to JsonBool(oneShot),
        "priority" to JsonNumber(priority.toString()),
        "ttlMs" to JsonNumber(ttlMs.toString()),
    )
}

/** An immutable event fed to the director. */
public data class BotFishEvent(
    public val type: String,
    public val time: Long,
    public val data: Map<String, JsonValue> = emptyMap(),
) {
    init {
        require(time >= 0) { "time must be >= 0" }
    }
}

/** The reducer result. */
public data class BotFishDirectorResult(
    public val directorState: BotFishDirectorState,
    public val command: BotFishCommand?,
)

/**
 * Port of Swift `BotFishDirector`: a deterministic priority/debounce/one-shot
 * TTL reducer. Turn start, delta, tool call, approval, task settle, memory,
 * errors, turn end and watchdog flags map onto the lifecycle table; unknown
 * events are ignored without a state change.
 */
public object BotFishDirector {
    private data class Mapping(
        val state: BotFishLifecycle,
        val priority: Int,
        val base: BotFishLifecycle? = null,
        val oneShotTTL: Long = 0,
        val force: Boolean = false,
    )

    private val TURN_START = setOf("turn.start", "turn.started", "turn_start", "conversation.turn_started")
    private val TURN_END = setOf("turn.end", "turn.ended", "turn_end", "conversation.turn_ended")
    private val DELTA = setOf("model.delta", "model.stream", "stream.delta")
    private val TOOL_START = setOf("tool.start", "tool.started", "tool_start", "conversation.tool_call")
    private val APPROVAL_REQUEST = setOf("approval.requested", "approval_requested")
    private val APPROVAL_RESOLVE = setOf("approval.resolved", "approval.decided", "approval_resolved")
    private val TASK_DONE = setOf("task.done", "task.settled", "task_done")
    private val ERRORS = setOf("error", "conversation.error", "runtime.error")
    private val MEMORY_WRITTEN = setOf("memory.written", "memory_written")
    private val USER_MESSAGE = setOf("user.message", "user-message", "conversation.user_message")

    public fun priority(forState: BotFishLifecycle): Int = when (forState) {
        BotFishLifecycle.IDLE -> 0
        BotFishLifecycle.SLEEPING, BotFishLifecycle.STANDBY -> 5
        BotFishLifecycle.WAKING, BotFishLifecycle.WAITING -> 10
        BotFishLifecycle.LOADING -> 15
        BotFishLifecycle.LISTENING, BotFishLifecycle.NOD, BotFishLifecycle.LOVE -> 20
        BotFishLifecycle.THINKING -> 30
        BotFishLifecycle.STREAMING -> 35
        BotFishLifecycle.SPEAKING -> 40
        BotFishLifecycle.WORKING -> 45
        BotFishLifecycle.CONFUSED, BotFishLifecycle.SURPRISED -> 50
        BotFishLifecycle.HAPPY, BotFishLifecycle.CELEBRATE -> 70
        BotFishLifecycle.SAD, BotFishLifecycle.CRYING -> 75
        BotFishLifecycle.ALERTING -> 100
        else -> 10
    }

    public fun reduce(state: BotFishDirectorState, event: BotFishEvent): BotFishDirectorResult {
        val now = event.time
        val freshened = expire(state, now)
        val mapping = mappingFor(event) ?: return freshened
        val active = freshened.directorState.oneShot?.takeIf { now < it.endsAt }
        val oneShot = mapping.oneShotTTL > 0
        if (oneShot) {
            if (active != null && active.state == mapping.state) return freshened
            val last = freshened.directorState.lastOneShotAt[mapping.state.wire]
            if (last != null && now - last < freshened.directorState.debounceMs) return freshened
        }
        if (!mapping.force) {
            if (active != null && mapping.priority < active.priority) return freshened
            if (oneShot && mapping.priority < freshened.directorState.priority) return freshened
            if (!oneShot && freshened.directorState.current == BotFishLifecycle.ALERTING &&
                mapping.priority < freshened.directorState.priority
            ) {
                return freshened
            }
        }

        var next = freshened.directorState
        if (mapping.base != null) next = next.copy(lifecycle = mapping.base)
        next = next.copy(
            now = now,
            current = mapping.state,
            priority = mapping.priority,
            oneShot = if (oneShot) {
                BotFishOneShot(
                    state = mapping.state,
                    priority = mapping.priority,
                    startedAt = now,
                    endsAt = now + mapping.oneShotTTL,
                )
            } else {
                null
            },
        )
        if (oneShot) {
            next = next.copy(
                lastOneShotAt = next.lastOneShotAt + (mapping.state.wire to now))
        }
        next = next.copy(lastEvent = event.type, version = next.version + 1)
        val shouldCommand = oneShot || mapping.force ||
            mapping.state != freshened.directorState.current ||
            mapping.priority != freshened.directorState.priority
        val command = if (shouldCommand) {
            BotFishCommand(
                state = mapping.state,
                oneShot = oneShot,
                priority = mapping.priority,
                ttlMs = mapping.oneShotTTL,
            )
        } else {
            freshened.command
        }
        return BotFishDirectorResult(next, command)
    }

    public fun setLifecycle(
        state: BotFishDirectorState,
        lifecycle: BotFishLifecycle,
        now: Long? = null,
    ): BotFishDirectorResult {
        val at = (now ?: state.now).coerceAtLeast(0)
        val freshened = expire(state, at)
        if (freshened.directorState.oneShot != null) {
            val next = freshened.directorState.copy(lifecycle = lifecycle, now = at)
            return BotFishDirectorResult(next, freshened.command)
        }
        var next = freshened.directorState
        next = next.copy(now = at, lifecycle = lifecycle, current = lifecycle,
            priority = priority(lifecycle))
        val command = if (freshened.directorState.current == lifecycle) {
            freshened.command
        } else {
            BotFishCommand(state = lifecycle, oneShot = false, priority = next.priority, ttlMs = 0)
        }
        return BotFishDirectorResult(next, command)
    }

    public fun expireOneShot(state: BotFishDirectorState, now: Long): BotFishDirectorResult =
        expire(state, now.coerceAtLeast(0))

    private fun expire(state: BotFishDirectorState, now: Long): BotFishDirectorResult {
        val reaction = state.oneShot
        if (reaction == null || now < reaction.endsAt) {
            return BotFishDirectorResult(state, null)
        }
        var next = state
        next = next.copy(
            now = now,
            current = next.lifecycle,
            priority = priority(next.lifecycle),
            oneShot = null,
        )
        val command = if (state.current == next.current) {
            null
        } else {
            BotFishCommand(state = next.current, oneShot = false, priority = next.priority, ttlMs = 0)
        }
        return BotFishDirectorResult(next, command)
    }

    private fun mappingFor(event: BotFishEvent): Mapping? {
        val type = event.type
        if (type in TURN_START) {
            return Mapping(BotFishLifecycle.THINKING, 40, base = BotFishLifecycle.THINKING, force = true)
        }
        if (type in USER_MESSAGE) {
            return Mapping(BotFishLifecycle.LISTENING, 30, base = BotFishLifecycle.LISTENING)
        }
        if (type in DELTA) {
            val mapped = if (string(event.data["channel"]) == "reasoning") {
                BotFishLifecycle.THINKING
            } else {
                BotFishLifecycle.SPEAKING
            }
            return Mapping(mapped, 45, base = mapped)
        }
        if (type in TOOL_START) {
            return Mapping(BotFishLifecycle.WORKING, 50, base = BotFishLifecycle.WORKING)
        }
        if (type in APPROVAL_REQUEST) {
            return Mapping(BotFishLifecycle.ALERTING, 100, base = BotFishLifecycle.ALERTING)
        }
        if (type in APPROVAL_RESOLVE) {
            if (isApprovalDenied(event.data)) {
                return Mapping(BotFishLifecycle.SAD, 80, base = BotFishLifecycle.IDLE,
                    oneShotTTL = 3_200, force = true)
            }
            return Mapping(BotFishLifecycle.WORKING, 50, base = BotFishLifecycle.WORKING, force = true)
        }
        if (type in TASK_DONE) {
            if (isTaskOk(event.data)) {
                return Mapping(BotFishLifecycle.CELEBRATE, 70, base = BotFishLifecycle.IDLE,
                    oneShotTTL = 2_200)
            }
            if (isTaskError(event.data)) {
                return Mapping(BotFishLifecycle.SAD, 75, base = BotFishLifecycle.IDLE,
                    oneShotTTL = 3_600)
            }
            return null
        }
        if (type in ERRORS) {
            return Mapping(BotFishLifecycle.SAD, 75, base = BotFishLifecycle.IDLE, oneShotTTL = 3_600)
        }
        if (type in MEMORY_WRITTEN) {
            val mapped = if (string(event.data["scope"]) == "user") {
                BotFishLifecycle.LOVE
            } else {
                BotFishLifecycle.NOD
            }
            return Mapping(mapped, 20, oneShotTTL = 2_000)
        }
        if (type in TURN_END) {
            return Mapping(BotFishLifecycle.IDLE, 0, base = BotFishLifecycle.IDLE, force = true)
        }
        if (type == "watchdog.flagged") {
            return Mapping(BotFishLifecycle.ALERTING, 100, base = BotFishLifecycle.ALERTING)
        }
        return null
    }

    private fun isTaskOk(data: Map<String, JsonValue>): Boolean {
        if (bool(data["ok"]) == true) return true
        return status(data) in setOf("ok", "done", "completed", "complete", "success", "succeeded")
    }

    private fun isTaskError(data: Map<String, JsonValue>): Boolean {
        if (bool(data["ok"]) == false) return true
        if (data.containsKey("error")) return true
        return status(data) in setOf(
            "error", "failed", "failure", "stopped", "cancelled", "canceled", "timed_out",
            "timeout", "aborted", "interrupted",
        )
    }

    private fun isApprovalDenied(data: Map<String, JsonValue>): Boolean {
        if (bool(data["denied"]) == true || bool(data["deny"]) == true) return true
        val resolution = (string(data["resolution"]) ?: string(data["decision"]) ?: "")
            .trim().lowercase()
        return resolution in setOf(
            "deny", "denied", "never", "timeout", "timed-out", "reject", "rejected",
        )
    }

    private fun status(data: Map<String, JsonValue>): String =
        (string(data["status"]) ?: string(data["state"]) ?: "").trim().lowercase()

    private fun string(value: JsonValue?): String? = (value as? JsonString)?.value

    private fun bool(value: JsonValue?): Boolean? = (value as? JsonBool)?.value
}
