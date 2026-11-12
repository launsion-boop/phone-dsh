// SPDX-License-Identifier: MIT
package com.phonedsh.bot.routines

/**
 * The presence ladder from v2 §3.2. The App reports the inputs; this library
 * owns the decision so the Bot information page and the keep-alive branch
 * cannot drift apart.
 */
enum class RoutinePresenceLevel(val rawValue: String) {
    FOREGROUND("foreground"),
    BACKGROUND_KEEP_ALIVE("backgroundKeepAlive"),
    SCHEDULED_NOTIFICATION("scheduledNotification"),
}

data class RoutinePresenceDelay(
    val routineId: String,
    val title: String,
    val scheduledFor: Long,
    val deferredUntil: Long,
) {
    val id: String get() = routineId
}

data class RoutinePresence(
    val level: RoutinePresenceLevel,
    val deferred: List<RoutinePresenceDelay> = emptyList(),
    val scheduledNotificationCount: Int = 0,
    /** Earliest fire time among the notifications actually registered, if any. */
    val nextNotificationAt: Long? = null,
) {
    init {
        require(scheduledNotificationCount >= 0) { "scheduledNotificationCount must not be negative" }
    }
}

object RoutinePresencePolicy {
    /** A Bot whose routine is due inside this window keeps the silent-audio session alive. */
    const val KEEP_ALIVE_WINDOW_MS: Long = 15 * 60 * 1_000L

    fun hasRoutineDueSoon(
        routines: List<Routine>,
        now: Long,
        windowMs: Long = KEEP_ALIVE_WINDOW_MS,
    ): Boolean {
        val horizon = now + maxOf(0L, windowMs)
        return routines.any {
            it.enabled && it.runState?.status != RoutineRunStatus.NEEDS_RECONCILIATION &&
                (it.nextRunAt ?: Long.MAX_VALUE) <= horizon
        }
    }

    fun level(appActive: Boolean, keepingAlive: Boolean, scheduledNotificationCount: Int): RoutinePresenceLevel =
        when {
            appActive -> RoutinePresenceLevel.FOREGROUND
            keepingAlive -> RoutinePresenceLevel.BACKGROUND_KEEP_ALIVE
            else -> RoutinePresenceLevel.SCHEDULED_NOTIFICATION
        }

    fun deferred(routines: List<Routine>): List<RoutinePresenceDelay> = routines
        .mapNotNull { routine ->
            val deferral = routine.quietDefer
            if (!routine.enabled || deferral == null) {
                null
            } else {
                RoutinePresenceDelay(
                    routineId = routine.id,
                    title = routine.title,
                    scheduledFor = deferral.scheduledFor,
                    deferredUntil = deferral.until,
                )
            }
        }
        .sortedWith(compareBy({ it.deferredUntil }, { it.routineId }))
}

/**
 * One process-wide answer to "is the App foreground and is the silent-audio
 * keep-alive active". The host writes the two flags from its scene-phase and
 * keep-alive owners; the information service reads them.
 */
class BotPresenceCenter {
    data class Context(val appActive: Boolean, val keepingAlive: Boolean) {
        companion object {
            val foreground: Context = Context(appActive = true, keepingAlive = false)
        }
    }

    private var active: Boolean = true
    private var keepAlive: Boolean = false

    @Synchronized
    fun update(appActive: Boolean? = null, keepingAlive: Boolean? = null) {
        appActive?.let { active = it }
        keepingAlive?.let { keepAlive = it }
    }

    @Synchronized
    fun context(): Context = Context(appActive = active, keepingAlive = keepAlive)

    @Synchronized
    fun appActive(): Boolean = active

    @Synchronized
    fun keepingAlive(): Boolean = keepAlive
}
