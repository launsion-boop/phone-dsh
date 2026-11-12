// SPDX-License-Identifier: MIT
package com.phonedsh.bot.routines

/**
 * The five-field cron subset frozen for routines: `minute hour day-of-month
 * month day-of-week`, each a `*`, an integer, a range, or a list, with an
 * optional `/step`. Weekday 7 is Sunday and is stored as 0 (Swift
 * `CronExpression`).
 */
class CronExpression private constructor(
    private val minute: Field,
    private val hour: Field,
    private val dayOfMonth: Field,
    private val month: Field,
    private val dayOfWeek: Field,
) {
    data class Field(val values: Set<Int>, val restricted: Boolean)

    fun matches(date: RoutineTime.Parts): Boolean {
        if (date.month !in month.values) return false
        val domMatch = date.day in dayOfMonth.values
        val dowMatch = (date.weekday % 7) in dayOfWeek.values
        if (dayOfMonth.restricted && dayOfWeek.restricted) return domMatch || dowMatch
        return domMatch && dowMatch
    }

    val minutesOfDay: List<Int>
        get() = hour.values.sorted().flatMap { h ->
            minute.values.sorted().map { m -> h * 60 + m }
        }.sorted()

    companion object {
        fun parse(expression: String): CronExpression {
            val fields = expression.trim().split(Regex("\\s+")).filter { it.isNotEmpty() }
            if (fields.size != 5) {
                throw RoutineError.InvalidSchedule(
                    "cron expr must have five fields: minute hour day-of-month month day-of-week",
                )
            }
            val dow = parseField(fields[4], 0, 7, "day-of-week")
            return CronExpression(
                minute = parseField(fields[0], 0, 59, "minute"),
                hour = parseField(fields[1], 0, 23, "hour"),
                dayOfMonth = parseField(fields[2], 1, 31, "day-of-month"),
                month = parseField(fields[3], 1, 12, "month"),
                dayOfWeek = Field(
                    values = dow.values.map { if (it == 7) 0 else it }.toSet(),
                    restricted = dow.restricted,
                ),
            )
        }

        private fun parseField(text: String, min: Int, max: Int, label: String): Field {
            if (text.isEmpty()) throw RoutineError.InvalidSchedule("cron $label field is empty")
            val values = HashSet<Int>()
            for (part in text.split(',')) {
                if (part.isEmpty()) {
                    throw RoutineError.InvalidSchedule("cron $label field has an empty list item")
                }
                val slash = part.split('/')
                if (slash.size > 2) {
                    throw RoutineError.InvalidSchedule("cron $label item \"$part\" has too many \"/\"")
                }
                val step = if (slash.size == 2) slash[1].toIntOrNull() else 1
                if (step == null || step < 1) {
                    throw RoutineError.InvalidSchedule("cron $label step is invalid")
                }
                val range = slash[0]
                val start: Int
                val end: Int
                if (range == "*") {
                    start = min
                    end = max
                } else if (range.contains('-')) {
                    val bounds = range.split('-')
                    val lower = bounds.getOrNull(0)?.toIntOrNull()
                    val upper = bounds.getOrNull(1)?.toIntOrNull()
                    if (bounds.size != 2 || lower == null || upper == null) {
                        throw RoutineError.InvalidSchedule(
                            "cron $label range \"$part\" must be $min–$max",
                        )
                    }
                    start = lower
                    end = upper
                } else {
                    val value = range.toIntOrNull()
                        ?: throw RoutineError.InvalidSchedule("cron $label range \"$part\" must be $min–$max")
                    start = value
                    end = if (slash.size == 2) max else value
                }
                if (start < min || end > max || start > end) {
                    throw RoutineError.InvalidSchedule("cron $label range \"$part\" must be $min–$max")
                }
                var value = start
                while (value <= end) {
                    values += value
                    value += step
                }
            }
            return Field(values, text != "*" && text != "*/1")
        }
    }
}

/** `@every`/`@daily`/`CRON_TZ=` parsing for the model-facing `schedule` string. */
object RoutineScheduleParser {
    fun parse(
        input: String,
        now: Long = System.currentTimeMillis(),
        timezone: String = RoutineTime.defaultZoneId(),
    ): RoutineSchedule {
        var text = input.trim()
        if (text.isEmpty()) throw RoutineError.InvalidSchedule("schedule string is empty")
        var zone = timezone
        if (text.startsWith("CRON_TZ=")) {
            val pieces = text.split(Regex("\\s+")).filter { it.isNotEmpty() }
            val prefix = pieces.firstOrNull()
            if (pieces.size < 2 || prefix == null || prefix.length <= 8) {
                throw RoutineError.InvalidSchedule(
                    "CRON_TZ= prefix must be followed by an IANA zone and a schedule",
                )
            }
            zone = prefix.drop(8)
            if (!RoutineTime.isKnownZone(zone)) {
                throw RoutineError.InvalidSchedule("unsupported time zone: $zone")
            }
            text = pieces.drop(1).joinToString(" ")
        }
        if (text.lowercase().startsWith("@every")) return parseEvery(text, zone)
        val shorthand = text.lowercase()
        if (shorthand in setOf("@hourly", "@daily", "@weekly", "@monthly")) {
            val parts = RoutineTime.parts(now, zone)
            val expression = when (shorthand) {
                "@hourly" -> "${parts.minute} * * * *"
                "@daily" -> "${parts.minute} ${parts.hour} * * *"
                "@weekly" -> "${parts.minute} ${parts.hour} * * ${parts.weekday % 7}"
                else -> "${parts.minute} ${parts.hour} ${parts.day} * *"
            }
            return RoutineSchedule.cron(expression, timezone = zone).validated()
        }
        if (text.startsWith("@")) {
            throw RoutineError.InvalidSchedule("unsupported schedule shorthand: $text")
        }
        return RoutineSchedule.cron(text, timezone = zone).validated()
    }

    private val everyPattern = Regex(
        "^@every\\s+(\\d+)\\s*([mhd])(?:\\s*/\\s*(\\d+)\\s*([mhd])?)?$",
        RegexOption.IGNORE_CASE,
    )

    private fun parseEvery(input: String, timezone: String): RoutineSchedule {
        val match = everyPattern.find(input)
            ?: throw RoutineError.InvalidSchedule(
                "@every must look like \"@every 5m\", \"@every 2h\", \"@every 1d\" or \"@every 30m/17m\"",
            )
        val amount = match.groupValues[1].toIntOrNull()
            ?: throw RoutineError.InvalidSchedule(
                "@every must look like \"@every 5m\", \"@every 2h\", \"@every 1d\" or \"@every 30m/17m\"",
            )
        val unit = match.groupValues[2].lowercase()
        val unitMultiplier = when (unit) {
            "m" -> 1
            "h" -> 60
            else -> 1_440
        }
        val every = amount * unitMultiplier
        if (every < 5 || every > 525_600) {
            throw RoutineError.InvalidSchedule(
                "@every interval must be 5–525600 minutes (official minimum is 5m)",
            )
        }
        val phaseText = match.groupValues[3]
        val phase = if (phaseText.isEmpty()) {
            null
        } else {
            val phaseUnit = if (match.groupValues[4].isEmpty()) unit else match.groupValues[4].lowercase()
            val phaseMultiplier = when (phaseUnit) {
                "m" -> 1
                "h" -> 60
                else -> 1_440
            }
            val amountValue = phaseText.toIntOrNull() ?: throw RoutineError.InvalidSchedule(
                "@every must look like \"@every 5m\", \"@every 2h\", \"@every 1d\" or \"@every 30m/17m\"",
            )
            amountValue * phaseMultiplier
        }
        return RoutineSchedule.interval(every, phaseMinutes = phase, timezone = timezone).validated()
    }
}

/** `RoutineScheduleMath` (next run, comparability, descriptions). */
object RoutineScheduleMath {
    fun nextRunAt(
        input: RoutineSchedule,
        now: Long,
        createdAt: Long? = null,
        lastRunAt: Long? = null,
    ): Long {
        val schedule = input.validated()
        return when (schedule.kind) {
            RoutineSchedule.Kind.INTERVAL -> nextInterval(schedule, now, createdAt, lastRunAt)
            RoutineSchedule.Kind.DAILY -> {
                val time = RoutineTime.parseTime(schedule.time)
                val today = RoutineTime.parts(now, schedule.timezone)
                var found: Long? = null
                for (offset in 0..2) {
                    val date = RoutineTime.addDays(today, offset)
                    val candidate = RoutineTime.wallToUtc(
                        date.year, date.month, date.day, time.hour, time.minute, schedule.timezone,
                    )
                    if (candidate > now) {
                        found = candidate
                        break
                    }
                }
                found ?: throw RoutineError.InvalidSchedule(
                    "daily schedule has no occurrence in the next three days",
                )
            }
            RoutineSchedule.Kind.WEEKLY -> {
                val time = RoutineTime.parseTime(schedule.time)
                val days = (schedule.weekdays ?: emptyList()).toSet()
                val today = RoutineTime.parts(now, schedule.timezone)
                var found: Long? = null
                for (offset in 0..8) {
                    val date = RoutineTime.addDays(today, offset)
                    if (date.weekday !in days) continue
                    val candidate = RoutineTime.wallToUtc(
                        date.year, date.month, date.day, time.hour, time.minute, schedule.timezone,
                    )
                    if (candidate > now) {
                        found = candidate
                        break
                    }
                }
                found ?: throw RoutineError.InvalidSchedule(
                    "weekly schedule has no occurrence in the next eight days",
                )
            }
            RoutineSchedule.Kind.CRON -> {
                val cron = CronExpression.parse(schedule.expr ?: "")
                val minutes = cron.minutesOfDay
                if (minutes.isEmpty()) {
                    throw RoutineError.InvalidSchedule("cron expression matches no minute of the day")
                }
                val today = RoutineTime.parts(now, schedule.timezone)
                var found: Long? = null
                for (offset in 0..366) {
                    val date = RoutineTime.addDays(today, offset)
                    if (!cron.matches(date)) continue
                    for (minuteOfDay in minutes) {
                        val candidate = RoutineTime.wallToUtc(
                            date.year, date.month, date.day,
                            minuteOfDay / 60, minuteOfDay % 60, schedule.timezone,
                        )
                        if (candidate > now) {
                            found = candidate
                            break
                        }
                    }
                    if (found != null) break
                }
                found ?: throw RoutineError.InvalidSchedule(
                    "cron expression has no occurrence in the next year",
                )
            }
        }
    }

    /**
     * True when `candidate` fires more often than `current`, compared on the
     * next two occurrences in the schedule's own timezone. Invalid input is
     * not "more frequent"; callers validate before storing it.
     */
    fun isMoreFrequent(candidate: RoutineSchedule, current: RoutineSchedule, now: Long): Boolean {
        fun gap(schedule: RoutineSchedule): Long? {
            val first = try {
                nextRunAt(schedule, now, createdAt = now)
            } catch (_: Exception) {
                return null
            }
            val second = try {
                nextRunAt(schedule, first + 1_000, createdAt = now)
            } catch (_: Exception) {
                return null
            }
            val value = second - first
            return if (value > 0) value else null
        }
        val candidateGap = gap(candidate) ?: return false
        val currentGap = gap(current) ?: return false
        return candidateGap < currentGap
    }

    fun nextAfterAttempt(
        routine: Routine,
        startedAt: Long,
        finishedAt: Long,
        scheduledFor: Long?,
    ): Long? {
        if (!routine.enabled) return null
        if (routine.schedule.kind == RoutineSchedule.Kind.INTERVAL) {
            return nextRunAt(
                routine.schedule, now = finishedAt,
                createdAt = routine.createdAt, lastRunAt = finishedAt,
            )
        }
        var next = nextRunAt(
            routine.schedule, now = scheduledFor ?: startedAt,
            createdAt = routine.createdAt, lastRunAt = startedAt,
        )
        if (next <= finishedAt) {
            next = nextRunAt(
                routine.schedule, now = finishedAt,
                createdAt = routine.createdAt, lastRunAt = startedAt,
            )
        }
        return next
    }

    private fun nextInterval(
        schedule: RoutineSchedule,
        now: Long,
        createdAt: Long?,
        lastRunAt: Long?,
    ): Long {
        val every = (schedule.everyMinutes ?: 0).toLong() * 60_000L
        val phase = schedule.phaseMinutes
        if (phase != null) {
            val phaseMs = phase.toLong() * 60_000L
            val parts = RoutineTime.parts(now, schedule.timezone)
            val wallNow = RoutineTime.utcDate(
                parts.year, parts.month, parts.day, parts.hour, parts.minute, parts.second,
            )
            var candidateWall = ((wallNow - phaseMs) / every) * every + phaseMs
            while (candidateWall <= wallNow) candidateWall += every
            repeat(10) {
                val candidateParts = RoutineTime.parts(candidateWall, "UTC")
                val candidate = RoutineTime.wallToUtc(
                    candidateParts.year, candidateParts.month, candidateParts.day,
                    candidateParts.hour, candidateParts.minute, schedule.timezone,
                )
                if (candidate > now) return candidate
                candidateWall += every
            }
            throw RoutineError.InvalidSchedule("phased interval has no occurrence after now")
        }
        val anchor = lastRunAt ?: createdAt ?: now
        if (anchor + every > now) return anchor + every
        val steps = (now - anchor) / every + 1
        return anchor + steps * every
    }

    /** The cron-shaped rendering used by the wake prompt and automation status. */
    fun expression(schedule: RoutineSchedule): String? = when (schedule.kind) {
        RoutineSchedule.Kind.CRON -> schedule.expr?.trim()
        RoutineSchedule.Kind.INTERVAL -> {
            val every = schedule.everyMinutes
            when {
                every == null || every < 1 -> null
                schedule.phaseMinutes != null -> {
                    val phase = schedule.phaseMinutes
                    if (phase < 0 || phase >= every) null else "@every ${every}m/${phase}m"
                }
                else -> "@every ${every}m"
            }
        }
        RoutineSchedule.Kind.DAILY -> {
            val parsed = try {
                RoutineTime.parseTime(schedule.time)
            } catch (_: Exception) {
                null
            }
            parsed?.let { "${it.minute} ${it.hour} * * *" }
        }
        RoutineSchedule.Kind.WEEKLY -> {
            val parsed = try {
                RoutineTime.parseTime(schedule.time)
            } catch (_: Exception) {
                null
            }
            val weekdays = schedule.weekdays
            if (parsed == null || weekdays == null || weekdays.isEmpty() ||
                weekdays.any { it !in 1..7 }
            ) {
                null
            } else {
                "${parsed.minute} ${parsed.hour} * * ${weekdays.distinct().sorted().joinToString(",")}"
            }
        }
    }

    /** Chinese/English one-line description, including the timezone. */
    fun describe(schedule: RoutineSchedule, lang: String = "zh"): String {
        val zh = lang != "en"
        val base: String = when (schedule.kind) {
            RoutineSchedule.Kind.INTERVAL -> {
                val every = schedule.everyMinutes ?: 0
                var text = if (zh) "每 $every 分钟" else "every $every minutes"
                schedule.phaseMinutes?.let { phase ->
                    text += if (zh) {
                        "（相位 :${phase.toString().padStart(2, '0')}）"
                    } else {
                        " (phase :${phase.toString().padStart(2, '0')})"
                    }
                }
                text
            }
            RoutineSchedule.Kind.DAILY ->
                if (zh) "每天 ${schedule.time ?: ""}" else "daily ${schedule.time ?: ""}"
            RoutineSchedule.Kind.WEEKLY -> {
                val zhLabels = listOf("", "一", "二", "三", "四", "五", "六", "日")
                val enLabels = listOf("", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun")
                val days = (schedule.weekdays ?: emptyList())
                    .map { if (zh) zhLabels[it] else enLabels[it] }
                    .joinToString(if (zh) "、" else ", ")
                if (zh) "每週$days ${schedule.time ?: ""}" else "weekly $days ${schedule.time ?: ""}"
            }
            RoutineSchedule.Kind.CRON -> "cron ${schedule.expr ?: ""}"
        }
        return if (zh) "$base（${schedule.timezone}）" else "$base (${schedule.timezone})"
    }

    /**
     * First sentence, whitespace-collapsed, capped at [max] scalars
     * (`RoutineScheduleMath.summarize`).
     */
    fun summarize(value: String, max: Int = 100): String {
        val text = RoutineJson.collapseWhitespace(value)
        if (text.isEmpty()) return ""
        var sentenceEnd = -1
        var index = 0
        while (index < text.length) {
            val character = text[index]
            if (character in "。！？") {
                sentenceEnd = index + 1
                break
            }
            if (character in ".!?") {
                val next = index + 1
                if (next == text.length || text[next].isWhitespace()) {
                    sentenceEnd = next
                    break
                }
            }
            index++
        }
        val sentence = if (sentenceEnd >= 0) text.substring(0, sentenceEnd) else text
        return RoutineJson.prefixCodePoints(sentence, maxOf(1, max)).trim()
    }
}
