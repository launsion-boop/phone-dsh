// SPDX-License-Identifier: MIT
package com.phonedsh.bot.proactive

import com.phonedsh.agentcore.JsonBool
import com.phonedsh.agentcore.JsonNumber
import com.phonedsh.agentcore.JsonObject
import com.phonedsh.agentcore.JsonString
import com.phonedsh.agentcore.JsonValue
import com.phonedsh.bot.BotJson
import com.phonedsh.bot.routines.RoutineQuietHours
import com.phonedsh.bot.routines.RoutineQuietSettings
import com.phonedsh.bot.routines.RoutineTime

/** The effective settings document violates `proactive-settings.schema.json`. */
public class ProactiveSettingsException(
    public val code: String,
    public val path: String,
    message: String = "$code at $path",
) : Exception(message)

/**
 * The nine-member effective proactive settings (README §3.0):
 *
 * - six persisted members: `mode`/`dnd`/`quietStart`/`quietEnd`/
 *   `routineQuietWeekends`/`timeZone`;
 * - `fuseWindowMs`/`fuseMaxWakeups` from the policy configuration;
 * - `deliveryKinds` from the engine assembly.
 *
 * Defaults mirror the Swift defaults. The production persisted default is
 * [productionDefault] (mode `on`, delivery kinds `[routine-result]`); it is a
 * named value, not a second schema default.
 */
public data class ProactiveSettings(
    public val mode: ProactiveMode = ProactiveMode.WOULD,
    public val dnd: Boolean = false,
    public val quietStart: String = "23:00",
    public val quietEnd: String = "08:00",
    public val routineQuietWeekends: Boolean = false,
    public val timeZone: String = RoutineTime.defaultZoneId(),
    public val fuseWindowMs: Long = DEFAULT_FUSE_WINDOW_MS,
    public val fuseMaxWakeups: Int = DEFAULT_FUSE_MAX_WAKEUPS,
    public val deliveryKinds: List<ProactiveKind> = DEFAULT_DELIVERY_KINDS,
) {
    /**
     * Persistence recovery, not a relaxation of the shared schema: an
     * unparsable quiet time falls back to 23:00 or 08:00 and an unknown zone to
     * the current zone. Fuse values and delivery kinds are not recovered.
     */
    public fun normalized(): ProactiveSettings {
        var copy = this
        if (RoutineTime.minutesOfDay(quietStart) == null) {
            copy = copy.copy(quietStart = "23:00")
        }
        if (RoutineTime.minutesOfDay(quietEnd) == null) {
            copy = copy.copy(quietEnd = "08:00")
        }
        if (!RoutineTime.isKnownZone(timeZone)) {
            copy = copy.copy(timeZone = RoutineTime.defaultZoneId())
        }
        return copy
    }

    public fun toJson(): JsonObject {
        val members = LinkedHashMap<String, JsonValue>()
        members["mode"] = JsonString(mode.wire)
        members["dnd"] = JsonBool(dnd)
        members["quietStart"] = JsonString(quietStart)
        members["quietEnd"] = JsonString(quietEnd)
        members["routineQuietWeekends"] = JsonBool(routineQuietWeekends)
        members["timeZone"] = JsonString(timeZone)
        members["fuseWindowMs"] = BotJson.number(fuseWindowMs)
        members["fuseMaxWakeups"] = BotJson.number(fuseMaxWakeups.toLong())
        members["deliveryKinds"] = proactiveKindArray(deliveryKinds)
        return JsonObject(members)
    }

    public companion object {
        public const val DEFAULT_FUSE_WINDOW_MS: Long = 900_000L
        public const val DEFAULT_FUSE_MAX_WAKEUPS: Int = 4

        /** Engine default from Swift `ProactiveEngine`; production narrows it. */
        public val DEFAULT_DELIVERY_KINDS: List<ProactiveKind> =
            listOf(ProactiveKind.TASK_DONE, ProactiveKind.ROUTINE_RESULT)

        public val PERSISTED_FIELDS: List<String> = listOf(
            "mode", "dnd", "quietStart", "quietEnd", "routineQuietWeekends", "timeZone",
        )
        public val FIELDS: List<String> = PERSISTED_FIELDS + listOf(
            "fuseWindowMs", "fuseMaxWakeups", "deliveryKinds",
        )

        /** Production store default: delivery on, routine results only (PC §2.2). */
        public fun productionDefault(): ProactiveSettings = ProactiveSettings(
            mode = ProactiveMode.ON,
            dnd = false,
            quietStart = "23:00",
            quietEnd = "08:00",
            routineQuietWeekends = false,
            deliveryKinds = listOf(ProactiveKind.ROUTINE_RESULT),
        )

        /** Strict shared-document decoder; returns the first frozen code/path. */
        public fun fromJson(value: JsonValue?): ProactiveSettings {
            val members = (value as? JsonObject)?.members
                ?: throw ProactiveSettingsException("proactive-settings-type", "$")

            val unknown = members.keys.filterNot(FIELDS::contains).sorted().firstOrNull()
            if (unknown != null) {
                throw ProactiveSettingsException(
                    "proactive-settings-unknown-field", "$.$unknown",
                )
            }
            for (field in FIELDS) {
                if (!members.containsKey(field)) {
                    throw ProactiveSettingsException(
                        "proactive-settings-missing-field", "$.$field",
                    )
                }
            }

            val modeText = members["mode"] as? JsonString
                ?: throw ProactiveSettingsException("proactive-settings-type", "$.mode")
            val mode = ProactiveMode.parse(modeText.value)
                ?: throw ProactiveSettingsException(
                    "proactive-settings-unknown-enum", "$.mode",
                )

            fun boolean(field: String): Boolean {
                val raw = members[field]
                return (raw as? JsonBool)?.value
                    ?: throw ProactiveSettingsException(
                        "proactive-settings-type", "$.$field",
                    )
            }
            val dnd = boolean("dnd")
            val routineQuietWeekends = boolean("routineQuietWeekends")

            fun clock(field: String): String {
                val raw = members[field] as? JsonString
                    ?: throw ProactiveSettingsException(
                        "proactive-settings-type", "$.$field",
                    )
                if (!CLOCK_PATTERN.matches(raw.value)) {
                    throw ProactiveSettingsException(
                        "proactive-settings-time-format", "$.$field",
                    )
                }
                return raw.value
            }
            val quietStart = clock("quietStart")
            val quietEnd = clock("quietEnd")

            val timeZone = members["timeZone"] as? JsonString
                ?: throw ProactiveSettingsException(
                    "proactive-settings-type", "$.timeZone",
                )
            if (timeZone.value.isBlank()) {
                throw ProactiveSettingsException(
                    "proactive-settings-timezone", "$.timeZone",
                )
            }

            fun positiveLong(field: String): Long {
                val raw = members[field] as? JsonNumber
                    ?: throw ProactiveSettingsException(
                        "proactive-settings-type", "$.$field",
                    )
                val number = raw.asLongOrNull()
                    ?: throw ProactiveSettingsException(
                        "proactive-settings-type", "$.$field",
                    )
                if (number < 1) {
                    throw ProactiveSettingsException(
                        "proactive-settings-range", "$.$field",
                    )
                }
                return number
            }
            val fuseWindowMs = positiveLong("fuseWindowMs")
            val fuseMaxLong = positiveLong("fuseMaxWakeups")
            if (fuseMaxLong > Int.MAX_VALUE) {
                throw ProactiveSettingsException(
                    "proactive-settings-range", "$.fuseMaxWakeups",
                )
            }

            val rawKinds = members["deliveryKinds"] as? com.phonedsh.agentcore.JsonArray
                ?: throw ProactiveSettingsException(
                    "proactive-settings-type", "$.deliveryKinds",
                )
            val kinds = ArrayList<ProactiveKind>(rawKinds.values.size)
            val seen = HashSet<ProactiveKind>()
            for ((index, raw) in rawKinds.values.withIndex()) {
                val path = "$.deliveryKinds[$index]"
                val text = raw as? JsonString
                    ?: throw ProactiveSettingsException(
                        "proactive-settings-type", path,
                    )
                val kind = ProactiveKind.parse(text.value)
                    ?: throw ProactiveSettingsException(
                        "proactive-settings-unknown-enum", path,
                    )
                if (!seen.add(kind)) {
                    throw ProactiveSettingsException(
                        "proactive-settings-duplicate-delivery-kind", path,
                    )
                }
                kinds += kind
            }

            return ProactiveSettings(
                mode = mode,
                dnd = dnd,
                quietStart = quietStart,
                quietEnd = quietEnd,
                routineQuietWeekends = routineQuietWeekends,
                timeZone = timeZone.value,
                fuseWindowMs = fuseWindowMs,
                fuseMaxWakeups = fuseMaxLong.toInt(),
                deliveryKinds = kinds,
            )
        }

        /**
         * Swift `QuietClock.minutes`: trimmed `H:MM` or `HH:MM`, hour 0–23,
         * minute 0–59; `+9` is accepted because `Int("+9")` is.
         */
        public fun quietMinutes(value: String?): Int? = RoutineTime.minutesOfDay(value ?: "")

        private val CLOCK_PATTERN: Regex =
            Regex("""^\s*(\+?[0-9]|0[0-9]|1[0-9]|2[0-3]):[0-5][0-9]\s*$""")
    }
}

/**
 * Quiet-hours helpers for the proactive chain. The calendar arithmetic is the
 * existing routine implementation, not a second copy; the proactive chain only
 * uses the clock-window check (routine weekends are a scheduler concern).
 */
public object ProactiveQuietHours {
    public fun contains(now: Long, settings: ProactiveSettings): Boolean {
        val normalized = settings.normalized()
        return RoutineQuietHours.contains(
            now,
            RoutineQuietSettings(
                mode = normalized.mode.wire,
                dnd = normalized.dnd,
                quietStart = normalized.quietStart,
                quietEnd = normalized.quietEnd,
                routineQuietWeekends = normalized.routineQuietWeekends,
                timeZone = normalized.timeZone,
            ),
        )
    }

    public fun isWithinQuietHours(
        now: Long,
        start: String,
        end: String,
        timeZone: String = RoutineTime.defaultZoneId(),
    ): Boolean = RoutineQuietHours.isWithinQuietHours(now, start, end, timeZone)

    public fun nextEnd(now: Long, settings: ProactiveSettings): Long? {
        val normalized = settings.normalized()
        return RoutineQuietHours.nextEnd(
            now,
            RoutineQuietSettings(
                mode = normalized.mode.wire,
                dnd = normalized.dnd,
                quietStart = normalized.quietStart,
                quietEnd = normalized.quietEnd,
                routineQuietWeekends = normalized.routineQuietWeekends,
                timeZone = normalized.timeZone,
            ),
        )
    }
}
