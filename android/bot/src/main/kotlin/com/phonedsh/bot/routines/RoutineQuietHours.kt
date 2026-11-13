// SPDX-License-Identifier: MIT
package com.phonedsh.bot.routines

/**
 * The quiet-hours subset of the proactive settings that the routine scheduler
 * reads. The full settings surface and its persistence key are B4; this value
 * keeps the scheduler's deferral rule independent of the proactive engine.
 *
 * `normalized()` is the same fallback as `ProactiveSettings.normalized()`: an
 * unparsable window falls back to 23:00–08:00 and an unknown zone to the
 * current zone, never to "no quiet hours".
 */
data class RoutineQuietSettings(
    val mode: String = "would",
    val dnd: Boolean = false,
    val quietStart: String = "23:00",
    val quietEnd: String = "08:00",
    val routineQuietWeekends: Boolean = false,
    val timeZone: String = RoutineTime.defaultZoneId(),
) {
    fun normalized(): RoutineQuietSettings {
        var copy = this
        if (RoutineTime.minutesOfDay(quietStart) == null) copy = copy.copy(quietStart = "23:00")
        if (RoutineTime.minutesOfDay(quietEnd) == null) copy = copy.copy(quietEnd = "08:00")
        if (!RoutineTime.isKnownZone(timeZone)) copy = copy.copy(timeZone = RoutineTime.defaultZoneId())
        return copy
    }
}

/**
 * Quiet hours: a non-urgent due routine is delayed, never dropped (v2 §2,
 * D9 §5). `urgent` with a non-empty reason bypasses the check in the scheduler;
 * the notification path may still reject a quiet candidate (B4).
 */
object RoutineQuietHours {
    fun contains(now: Long, settings: RoutineQuietSettings): Boolean {
        val normalized = settings.normalized()
        val parts = RoutineTime.parts(now, normalized.timeZone)
        val sundayFirst = if (parts.weekday == 7) 1 else parts.weekday + 1
        if (normalized.routineQuietWeekends && (sundayFirst == 1 || sundayFirst == 7)) return true
        return isWithinQuietHours(
            now, start = normalized.quietStart, end = normalized.quietEnd,
            timeZone = normalized.timeZone,
        )
    }

    fun isWithinQuietHours(
        now: Long,
        start: String,
        end: String,
        timeZone: String = RoutineTime.defaultZoneId(),
    ): Boolean {
        val from = RoutineTime.minutesOfDay(start) ?: return false
        val to = RoutineTime.minutesOfDay(end) ?: return false
        if (from == to) return false
        val current = RoutineTime.parts(now, timeZone).let { it.hour * 60 + it.minute }
        if (from < to) return current in from until to
        return current >= from || current < to
    }

    /**
     * The first quiet-free minute after now, or `now` rounded down to the
     * minute when now is already outside quiet hours. Null when no end is
     * found in nine days.
     */
    fun nextEnd(now: Long, settings: RoutineQuietSettings): Long? {
        val normalized = settings.normalized()
        if (!contains(now, normalized)) return now / 60_000L * 60_000L
        var cursor = now / 60_000L * 60_000L + 60_000L
        repeat(9 * 24 * 60) {
            if (!contains(cursor, normalized)) return cursor
            cursor += 60_000L
        }
        return null
    }

    fun dayKey(now: Long, timeZone: String): String = RoutineTime.dayKey(now, timeZone)
}
