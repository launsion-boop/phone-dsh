// SPDX-License-Identifier: MIT
package com.phonedsh.bot.watchdog

import com.phonedsh.agentcore.JsonNumber
import com.phonedsh.agentcore.JsonObject
import com.phonedsh.agentcore.JsonValue
import java.math.BigDecimal

/**
 * The frozen watchdog configuration (`spec/bot/v1/watchdog.md` §2).
 *
 * Every member is optional when decoding; an absent member takes its default.
 * Unknown members and explicit `null` are rejected rather than ignored, and a
 * negative or out-of-range value is an error rather than a clamp.
 */
public data class BotWatchdogConfig(
    public val heartbeatTimeoutMs: Long = 120_000,
    public val turnDeadlineMs: Long = 900_000,
    public val taskDeadlineMs: Long = 600_000,
    public val routineDeadlineMs: Long = 660_000,
    public val repeatedToolCalls: Long = 5,
    public val repeatedToolErrors: Long = 3,
    public val maxUnitTokens: Long = 200_000,
    public val maxUnitCostUsd: Double = 2.0,
    public val goalMaxTotalTokens: Long = 0,
    public val goalMaxTotalCostUsd: Double = 0.0,
    public val tickMs: Long = 5_000,
    public val historyLimit: Long = 200,
    public val maxUnits: Long = 1_000,
) {
    /** The deadline for a new unit, before `startedAt` is added (`watchdog.md` §3). */
    public fun deadlineMs(kind: BotWatchdogUnitKind, override: Long? = null): Long {
        if (override != null && override > 0) return override
        return when (kind) {
            BotWatchdogUnitKind.TURN -> turnDeadlineMs
            BotWatchdogUnitKind.TASK -> taskDeadlineMs
            BotWatchdogUnitKind.ROUTINE -> routineDeadlineMs
            BotWatchdogUnitKind.GOAL -> 0
        }
    }

    /** Writes every member, including defaults, as a closed object. */
    public fun toJson(): JsonObject = JsonObject(
        linkedMapOf(
            "heartbeatTimeoutMs" to number(heartbeatTimeoutMs),
            "turnDeadlineMs" to number(turnDeadlineMs),
            "taskDeadlineMs" to number(taskDeadlineMs),
            "routineDeadlineMs" to number(routineDeadlineMs),
            "repeatedToolCalls" to number(repeatedToolCalls),
            "repeatedToolErrors" to number(repeatedToolErrors),
            "maxUnitTokens" to number(maxUnitTokens),
            "maxUnitCostUsd" to number(maxUnitCostUsd),
            "goalMaxTotalTokens" to number(goalMaxTotalTokens),
            "goalMaxTotalCostUsd" to number(goalMaxTotalCostUsd),
            "tickMs" to number(tickMs),
            "historyLimit" to number(historyLimit),
            "maxUnits" to number(maxUnits),
        ),
    )

    public companion object {
        public val DEFAULT: BotWatchdogConfig = BotWatchdogConfig()
        public val default: BotWatchdogConfig get() = DEFAULT

        /** Swift-style alias for [decode]. */
        public fun fromJson(value: JsonValue): BotWatchdogConfig = decode(value)

        private val INTEGER_FIELDS: Set<String> = setOf(
            "heartbeatTimeoutMs", "turnDeadlineMs", "taskDeadlineMs",
            "routineDeadlineMs", "repeatedToolCalls", "repeatedToolErrors",
            "maxUnitTokens", "goalMaxTotalTokens", "tickMs", "historyLimit", "maxUnits",
        )
        private val NUMBER_FIELDS: Set<String> = setOf("maxUnitCostUsd", "goalMaxTotalCostUsd")
        private val KNOWN_FIELDS: Set<String> = INTEGER_FIELDS + NUMBER_FIELDS

        /**
         * Decodes one config object. The caller supplies the object itself, not
         * the enclosing vector, because the frozen error paths are `/config/...`.
         */
        public fun decode(value: JsonValue): BotWatchdogConfig {
            val members = (value as? JsonObject)?.members
                ?: throw BotWatchdogConfigException(
                    "watchdog.config.type", "/config", "config must be an object",
                )
            for (name in members.keys) {
                if (name !in KNOWN_FIELDS) {
                    throw BotWatchdogConfigException(
                        "watchdog.config.unknown", "/config/$name",
                        "unknown watchdog config member $name",
                    )
                }
            }
            fun integer(name: String, fallback: Long): Long {
                if (!members.containsKey(name)) return fallback
                val raw = members[name] as? JsonNumber
                    ?: throw BotWatchdogConfigException(
                        "watchdog.config.type", "/config/$name",
                        "watchdog config $name must be a non-negative integer",
                    )
                val value = try {
                    BigDecimal(raw.raw)
                } catch (_: NumberFormatException) {
                    throw BotWatchdogConfigException(
                        "watchdog.config.type", "/config/$name",
                        "watchdog config $name must be a non-negative integer",
                    )
                }
                if (value.stripTrailingZeros().scale() > 0) {
                    throw BotWatchdogConfigException(
                        "watchdog.config.type", "/config/$name",
                        "watchdog config $name must be a non-negative integer",
                    )
                }
                if (value.signum() < 0 || value > LONG_MAX) {
                    throw BotWatchdogConfigException(
                        "watchdog.config.range", "/config/$name",
                        "watchdog config $name is outside the signed 64-bit range",
                    )
                }
                return value.longValueExact()
            }
            fun number(name: String, fallback: Double): Double {
                if (!members.containsKey(name)) return fallback
                val raw = members[name] as? JsonNumber
                    ?: throw BotWatchdogConfigException(
                        "watchdog.config.type", "/config/$name",
                        "watchdog config $name must be a non-negative finite number",
                    )
                val value = raw.raw.toDoubleOrNull()
                    ?: throw BotWatchdogConfigException(
                        "watchdog.config.type", "/config/$name",
                        "watchdog config $name must be a non-negative finite number",
                    )
                if (!value.isFinite() || value < 0) {
                    throw BotWatchdogConfigException(
                        "watchdog.config.range", "/config/$name",
                        "watchdog config $name must be a non-negative finite number",
                    )
                }
                return value
            }
            return BotWatchdogConfig(
                heartbeatTimeoutMs = integer("heartbeatTimeoutMs", 120_000),
                turnDeadlineMs = integer("turnDeadlineMs", 900_000),
                taskDeadlineMs = integer("taskDeadlineMs", 600_000),
                routineDeadlineMs = integer("routineDeadlineMs", 660_000),
                repeatedToolCalls = integer("repeatedToolCalls", 5),
                repeatedToolErrors = integer("repeatedToolErrors", 3),
                maxUnitTokens = integer("maxUnitTokens", 200_000),
                maxUnitCostUsd = number("maxUnitCostUsd", 2.0),
                goalMaxTotalTokens = integer("goalMaxTotalTokens", 0),
                goalMaxTotalCostUsd = number("goalMaxTotalCostUsd", 0.0),
                tickMs = integer("tickMs", 5_000),
                historyLimit = integer("historyLimit", 200),
                maxUnits = integer("maxUnits", 1_000),
            )
        }

        private val LONG_MAX: BigDecimal = BigDecimal.valueOf(Long.MAX_VALUE)
    }
}

/** A config reader failure carrying the frozen code/path pair (`watchdog.md` §2). */
public class BotWatchdogConfigException(
    public val code: String,
    public val path: String,
    message: String,
) : Exception("$code $path: $message")

/** `turn|task|routine|goal` (`watchdog.schema.json#$defs/unitKind`). */
public enum class BotWatchdogUnitKind(public val wireValue: String) {
    TURN("turn"),
    TASK("task"),
    ROUTINE("routine"),
    GOAL("goal");

    public companion object {
        public fun fromWire(value: String): BotWatchdogUnitKind? =
            values().firstOrNull { it.wireValue == value }
    }
}

/** The eight frozen check names (`watchdog.schema.json#$defs/check`). */
public enum class BotWatchdogCheck(public val wireValue: String) {
    DEADLINE("deadline"),
    HEARTBEAT("heartbeat"),
    REPEATED_TOOL_SIGNATURE("repeated_tool_signature"),
    REPEATED_TOOL_ERROR("repeated_tool_error"),
    QUOTA("quota"),
    WEBCONTENT_TERMINATED("webcontent_terminated"),
    THERMAL_PRESSURE("thermal_pressure"),
    BATTERY_PRESSURE("battery_pressure");

    public companion object {
        public fun fromWire(value: String): BotWatchdogCheck? =
            values().firstOrNull { it.wireValue == value }
    }
}

/** The three host signal checks, each observe-only and once per unit. */
public enum class BotMobileWatchdogEvent(public val wireValue: String) {
    WEBCONTENT_TERMINATED("webcontent_terminated"),
    THERMAL_PRESSURE("thermal_pressure"),
    BATTERY_PRESSURE("battery_pressure");

    public val check: BotWatchdogCheck
        get() = when (this) {
            WEBCONTENT_TERMINATED -> BotWatchdogCheck.WEBCONTENT_TERMINATED
            THERMAL_PRESSURE -> BotWatchdogCheck.THERMAL_PRESSURE
            BATTERY_PRESSURE -> BotWatchdogCheck.BATTERY_PRESSURE
        }

    public companion object {
        public fun fromWire(value: String): BotMobileWatchdogEvent? =
            values().firstOrNull { it.wireValue == value }
    }
}

public data class BotWatchdogMobileDescriptor(
    public val check: BotWatchdogCheck,
    public val eventType: String = "watchdog.flagged",
    public val observeOnly: Boolean = true,
    public val oncePerUnit: Boolean = true,
) {
    public companion object {
        public val FROZEN: List<BotWatchdogMobileDescriptor> =
            BotMobileWatchdogEvent.values().map { BotWatchdogMobileDescriptor(it.check) }
        public val frozen: List<BotWatchdogMobileDescriptor> get() = FROZEN
    }
}

/**
 * A host reading for one mobile check. Thermal/battery readings must be
 * non-empty: an unavailable or failed platform read is represented by a null
 * [BotMobileWatchdogSignalPort] result, never by an invented normal value.
 */
public data class BotMobileWatchdogSignal(
    public val event: BotMobileWatchdogEvent,
    public val evidence: Map<String, JsonValue>,
) {
    init {
        require(event == BotMobileWatchdogEvent.WEBCONTENT_TERMINATED || evidence.isNotEmpty()) {
            "${event.wireValue} requires a real host reading"
        }
    }
}

/**
 * Host/platform adapter for the three mobile signals. Returning `null` means
 * the signal is unavailable (no callback, no API, or a failed read) and the
 * monitor emits nothing (`watchdog.md` §6).
 */
public fun interface BotMobileWatchdogSignalPort {
    public fun read(event: BotMobileWatchdogEvent): BotMobileWatchdogSignal?
}

/** In-memory unit state; the durable identity is the `(kind,id,check)` event id. */
public data class BotWatchdogUnit(
    public val kind: BotWatchdogUnitKind,
    public val id: String,
    public val botId: String? = null,
    public val sessionId: String? = null,
    public val startedAt: Long = 0,
    public val lastEventAt: Long? = null,
    public val deadlineAt: Long? = null,
    public val repeatedToolSignatureCount: Long = 0,
    public val lastToolSignature: String? = null,
    public val repeatedToolErrorCount: Long = 0,
    public val lastToolErrorSignature: String? = null,
    public val pendingApproval: Int = 0,
    public val tokens: Long = 0,
    public val costUsd: Double = 0.0,
)

public data class BotWatchdogFinding(
    public val check: BotWatchdogCheck,
    public val evidence: Map<String, JsonValue>,
)

/** One successfully appended durable flag, also retained in the recent history. */
public data class BotWatchdogFlag(
    public val unitKind: BotWatchdogUnitKind,
    public val unitId: String,
    public val botId: String?,
    public val sessionId: String?,
    public val check: BotWatchdogCheck,
    public val evidence: Map<String, JsonValue>,
    public val at: Long,
    public val eventId: String,
    public val commitSeq: Long?,
)

internal fun number(value: Long): JsonNumber = JsonNumber(value.toString())

internal fun number(value: Int): JsonNumber = JsonNumber(value.toString())

internal fun number(value: Double): JsonNumber = when {
    value == 0.0 -> JsonNumber("0")
    value.isFinite() && value == Math.rint(value) && value >= Long.MIN_VALUE && value <= Long.MAX_VALUE ->
        JsonNumber(value.toLong().toString())
    else -> JsonNumber(BigDecimal.valueOf(value).stripTrailingZeros().toPlainString())
}

internal fun nullableString(value: String?): JsonValue =
    value?.let { com.phonedsh.agentcore.JsonString(it) } ?: com.phonedsh.agentcore.JsonNull
