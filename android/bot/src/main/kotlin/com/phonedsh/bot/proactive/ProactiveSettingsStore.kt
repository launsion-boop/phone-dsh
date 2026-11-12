// SPDX-License-Identifier: MIT
package com.phonedsh.bot.proactive

import com.phonedsh.agentcore.JsonBool
import com.phonedsh.agentcore.JsonObject
import com.phonedsh.agentcore.JsonString
import com.phonedsh.agentcore.JsonValue
import com.phonedsh.bot.routines.RoutineTime

/**
 * The six-member persisted proactive settings blob (P18). This is the existing
 * on-disk shape, not a second form of the nine-member effective document:
 * `fuseWindowMs`/`fuseMaxWakeups` come from the policy configuration and
 * `deliveryKinds` from the engine assembly.
 *
 * Decoding follows Swift `Codable`: the six members are required, unknown
 * members are ignored, and an invalid enum/type fails the decode. Quiet-time
 * and zone strings are not format-checked here; [normalized] recovers them.
 */
public data class ProactivePersistedSettings(
    public val mode: ProactiveMode = ProactiveMode.WOULD,
    public val dnd: Boolean = false,
    public val quietStart: String = "23:00",
    public val quietEnd: String = "08:00",
    public val routineQuietWeekends: Boolean = false,
    public val timeZone: String = RoutineTime.defaultZoneId(),
) {
    public fun normalized(): ProactivePersistedSettings {
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

    public fun toEffective(
        fuseWindowMs: Long = ProactiveSettings.DEFAULT_FUSE_WINDOW_MS,
        fuseMaxWakeups: Int = ProactiveSettings.DEFAULT_FUSE_MAX_WAKEUPS,
        deliveryKinds: List<ProactiveKind> = ProactiveSettings.DEFAULT_DELIVERY_KINDS,
    ): ProactiveSettings = ProactiveSettings(
        mode = mode,
        dnd = dnd,
        quietStart = quietStart,
        quietEnd = quietEnd,
        routineQuietWeekends = routineQuietWeekends,
        timeZone = timeZone,
        fuseWindowMs = fuseWindowMs,
        fuseMaxWakeups = fuseMaxWakeups,
        deliveryKinds = deliveryKinds,
    ).normalized()

    public fun toJson(): JsonObject {
        val members = LinkedHashMap<String, JsonValue>()
        members["mode"] = JsonString(mode.wire)
        members["dnd"] = JsonBool(dnd)
        members["quietStart"] = JsonString(quietStart)
        members["quietEnd"] = JsonString(quietEnd)
        members["routineQuietWeekends"] = JsonBool(routineQuietWeekends)
        members["timeZone"] = JsonString(timeZone)
        return JsonObject(members)
    }

    public companion object {
        public fun productionDefault(): ProactivePersistedSettings = ProactivePersistedSettings(
            mode = ProactiveMode.ON,
            dnd = false,
            quietStart = "23:00",
            quietEnd = "08:00",
            routineQuietWeekends = false,
        )

        public fun fromSettings(settings: ProactiveSettings): ProactivePersistedSettings {
            val normalized = settings.normalized()
            return ProactivePersistedSettings(
                mode = normalized.mode,
                dnd = normalized.dnd,
                quietStart = normalized.quietStart,
                quietEnd = normalized.quietEnd,
                routineQuietWeekends = normalized.routineQuietWeekends,
                timeZone = normalized.timeZone,
            )
        }

        /** Lenient persistence decode; returns null on a Codable-level failure. */
        public fun fromJson(value: JsonValue?): ProactivePersistedSettings? {
            val members = (value as? JsonObject)?.members ?: return null
            if (members.keys.containsAll(ProactiveSettings.PERSISTED_FIELDS).not()) return null

            val mode = (members["mode"] as? JsonString)?.let { ProactiveMode.parse(it.value) }
                ?: return null
            val dnd = (members["dnd"] as? JsonBool)?.value ?: return null
            val quietStart = (members["quietStart"] as? JsonString)?.value ?: return null
            val quietEnd = (members["quietEnd"] as? JsonString)?.value ?: return null
            val routineQuietWeekends =
                (members["routineQuietWeekends"] as? JsonBool)?.value ?: return null
            val timeZone = (members["timeZone"] as? JsonString)?.value ?: return null
            return ProactivePersistedSettings(
                mode = mode,
                dnd = dnd,
                quietStart = quietStart,
                quietEnd = quietEnd,
                routineQuietWeekends = routineQuietWeekends,
                timeZone = timeZone,
            )
        }
    }
}

/**
 * P18 persistence seam. The host injects the storage key and owns the actual
 * storage; `:bot` never imports Android storage. The key is the existing
 * `phone-dsh.bot.proactive-settings.v1`.
 */
public interface ProactiveSettingsStore {
    public val key: String

    public fun load(): ProactiveSettings

    public fun save(settings: ProactiveSettings)

    public companion object {
        public const val DEFAULT_KEY: String = ProactiveSettingsPersistence.KEY
    }
}

/** Small host-independent store used by tests and by hosts without storage. */
public class InMemoryProactiveSettingsStore(
    override val key: String = ProactiveSettingsStore.DEFAULT_KEY,
    initial: ProactiveSettings? = null,
) : ProactiveSettingsStore {
    private var value: ProactiveSettings? = initial

    override fun load(): ProactiveSettings =
        (value ?: ProactiveSettings.productionDefault()).normalized()

    override fun save(settings: ProactiveSettings) {
        value = settings.normalized()
    }
}

/** The six-member persisted codec and its production-default recovery. */
public object ProactiveSettingsPersistence {
    public const val KEY: String = "phone-dsh.bot.proactive-settings.v1"

    /** Canonical writer: six members, normalized, no effective-only fields. */
    public fun encode(settings: ProactiveSettings): JsonObject =
        ProactivePersistedSettings.fromSettings(settings).toJson()

    public fun decode(value: JsonValue?): ProactivePersistedSettings? =
        ProactivePersistedSettings.fromJson(value)

    /**
     * Swift `ProactiveSettingsStore.settings()`: a decode failure or absent
     * blob falls back to the production default, then normalization runs.
     */
    public fun decodeOrProductionDefault(
        value: JsonValue?,
        fuseWindowMs: Long = ProactiveSettings.DEFAULT_FUSE_WINDOW_MS,
        fuseMaxWakeups: Int = ProactiveSettings.DEFAULT_FUSE_MAX_WAKEUPS,
        deliveryKinds: List<ProactiveKind> = ProactiveSettings.DEFAULT_DELIVERY_KINDS,
    ): ProactiveSettings {
        val persisted = decode(value) ?: ProactivePersistedSettings.productionDefault()
        return persisted.normalized().toEffective(
            fuseWindowMs = fuseWindowMs,
            fuseMaxWakeups = fuseMaxWakeups,
            deliveryKinds = deliveryKinds,
        )
    }
}
