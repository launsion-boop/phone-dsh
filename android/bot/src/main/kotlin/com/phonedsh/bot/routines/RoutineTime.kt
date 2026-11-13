// SPDX-License-Identifier: MIT
package com.phonedsh.bot.routines

import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId
import java.time.ZoneOffset
import java.util.TimeZone

/**
 * Calendar math for routine schedules.
 *
 * The reference is `RoutineClock` (`Sources/PhoneDSHBot/Routines/RoutineSchedule.swift`).
 * It uses `java.time` (available on the Android 26 floor and on the host JVM)
 * and formats English wall-clock strings by hand: `DateFormatter` patterns are
 * locale/CLDR-dependent, and the frozen wake text must not drift with the JDK.
 * The unit tests pin the exact golden strings.
 */
object RoutineTime {
    /** One wall-clock instant in a zone; `weekday` is ISO 1=Mon … 7=Sun. */
    data class Parts(
        val year: Int,
        val month: Int,
        val day: Int,
        val hour: Int,
        val minute: Int,
        val second: Int,
        val weekday: Int,
    )

    private val weekdays = listOf(
        "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday",
    )
    private val months = listOf(
        "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
    )

    fun defaultZoneId(): String = TimeZone.getDefault().id

    fun isKnownZone(identifier: String): Boolean =
        try {
            ZoneId.of(identifier)
            true
        } catch (_: Exception) {
            false
        }

    fun zone(identifier: String): ZoneId =
        try {
            ZoneId.of(identifier)
        } catch (_: Exception) {
            ZoneId.of(defaultZoneId())
        }

    /** `HH:MM` with an optional one-digit hour, normalized to two digits. */
    fun parseTime(value: String?): ParsedTime {
        val text = (value ?: "").trim()
        val pieces = text.split(':')
        if (pieces.size != 2) {
            throw RoutineError.InvalidSchedule(
                "schedule.time must be HH:MM (00:00–23:59), got \"${value ?: ""}\"",
            )
        }
        val hour = pieces[0].toIntOrNull()
        val minute = pieces[1].toIntOrNull()
        if (hour == null || minute == null || pieces[0].length > 2 || pieces[1].length != 2 ||
            hour < 0 || hour > 23 || minute < 0 || minute > 59
        ) {
            throw RoutineError.InvalidSchedule(
                "schedule.time must be HH:MM (00:00–23:59), got \"${value ?: ""}\"",
            )
        }
        return ParsedTime(hour, minute, "%02d:%02d".format(hour, minute))
    }

    data class ParsedTime(val hour: Int, val minute: Int, val text: String)

    fun parts(milliseconds: Long, timezone: String): Parts {
        val zoned = Instant.ofEpochMilli(milliseconds).atZone(zone(timezone))
        return Parts(
            year = zoned.year,
            month = zoned.monthValue,
            day = zoned.dayOfMonth,
            hour = zoned.hour % 24,
            minute = zoned.minute,
            second = zoned.second,
            weekday = zoned.dayOfWeek.value,
        )
    }

    /** Epoch milliseconds of a UTC wall-clock value. */
    fun utcDate(
        year: Int,
        month: Int,
        day: Int,
        hour: Int = 0,
        minute: Int = 0,
        second: Int = 0,
    ): Long = LocalDate.of(year, month, day)
        .atTime(hour, minute, second)
        .toInstant(ZoneOffset.UTC)
        .toEpochMilli()

    fun addDays(parts: Parts, days: Int): Parts {
        val date = LocalDate.of(parts.year, parts.month, parts.day).plusDays(days.toLong())
        return Parts(
            year = date.year,
            month = date.monthValue,
            day = date.dayOfMonth,
            hour = 0,
            minute = 0,
            second = 0,
            weekday = date.dayOfWeek.value,
        )
    }

    /**
     * Converts a zone-local wall clock to epoch ms with the same three-pass
     * fixed point as Swift: the offset is looked up at the candidate instant,
     * not at the nominal UTC base, so a DST boundary is resolved the same way.
     */
    fun wallToUtc(
        year: Int,
        month: Int,
        day: Int,
        hour: Int,
        minute: Int,
        timezone: String,
    ): Long {
        val base = utcDate(year, month, day, hour, minute, 0)
        val rules = zone(timezone).rules
        var candidate = base
        repeat(3) {
            val offset = rules.getOffset(Instant.ofEpochMilli(candidate)).totalSeconds * 1_000L
            val next = base - offset
            if (next == candidate) return candidate
            candidate = next
        }
        return candidate
    }

    /**
     * `"EEEE, MMM d, yyyy, h:mm a"` plus the zone, e.g.
     * `Thursday, Oct 9, 2025, 4:53 PM (Asia/Taipei)` (Swift
     * `RoutineWakeBuilder.formatTimestamp`).
     */
    fun formatTimestamp(milliseconds: Long, timezone: String): String {
        val parts = parts(milliseconds, timezone)
        return "${weekdays[parts.weekday - 1]}, ${months[parts.month - 1]} ${parts.day}, " +
            "${parts.year}, ${hour12(parts.hour)}:${twoDigits(parts.minute)} ${ampm(parts.hour)} " +
            "($timezone)"
    }

    /** `"M/d/yyyy, h:mm:ss a"`, e.g. `10/9/2025, 4:53:20 PM`. */
    fun formatFired(milliseconds: Long, timezone: String): String {
        val parts = parts(milliseconds, timezone)
        return "${parts.month}/${parts.day}/${parts.year}, ${hour12(parts.hour)}:" +
            "${twoDigits(parts.minute)}:${twoDigits(parts.second)} ${ampm(parts.hour)}"
    }

    /** `"yyyy-MM-dd HH:mm"`, e.g. `2025-10-10 08:30`; null for absent/non-positive input. */
    fun formatMinute(milliseconds: Long?, timezone: String): String? {
        if (milliseconds == null || milliseconds <= 0) return null
        val parts = parts(milliseconds, timezone)
        return "${fourDigits(parts.year)}-${twoDigits(parts.month)}-${twoDigits(parts.day)} " +
            "${twoDigits(parts.hour)}:${twoDigits(parts.minute)}"
    }

    /** `HH:MM` → minutes since midnight, or null when malformed (QuietClock). */
    fun minutesOfDay(value: String): Int? {
        val pieces = value.trim().split(':')
        if (pieces.size != 2 || pieces[0].length > 2 || pieces[1].length != 2) return null
        val hour = pieces[0].toIntOrNull() ?: return null
        val minute = pieces[1].toIntOrNull() ?: return null
        if (hour !in 0..23 || minute !in 0..59) return null
        return hour * 60 + minute
    }

    /** `"yyyy-MM-dd"` in the given zone (QuietClock.dayKey). */
    fun dayKey(milliseconds: Long, timezone: String): String {
        val zoned = Instant.ofEpochMilli(milliseconds).atZone(zone(timezone))
        return "${fourDigits(zoned.year)}-${twoDigits(zoned.monthValue)}-${twoDigits(zoned.dayOfMonth)}"
    }

    private fun hour12(hour: Int): Int = when (val value = hour % 12) {
        0 -> 12
        else -> value
    }

    private fun ampm(hour: Int): String = if (hour < 12) "AM" else "PM"

    private fun twoDigits(value: Int): String = value.toString().padStart(2, '0')

    private fun fourDigits(value: Int): String = value.toString().padStart(4, '0')
}
