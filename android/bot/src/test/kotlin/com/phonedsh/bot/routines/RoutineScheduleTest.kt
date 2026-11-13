// SPDX-License-Identifier: MIT
package com.phonedsh.bot.routines

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import java.time.Instant

/**
 * Schedule math and cron parsing (D9 §1–§2). Every expected instant is an
 * absolute epoch computed independently with `java.time`, so a timezone or DST
 * regression fails the test instead of being hidden by a round trip.
 */
class RoutineScheduleTest {
    private val taipei = "Asia/Taipei"

    @Test
    fun intervalAnchorsOnCreatedAtAndCatchesUpOnce() {
        val schedule = RoutineSchedule.interval(60, timezone = "UTC")
        assertEquals(3_600_000L, RoutineScheduleMath.nextRunAt(schedule, now = 0, createdAt = 0))
        assertEquals(
            7_200_000L,
            RoutineScheduleMath.nextRunAt(schedule, now = 3_600_000, createdAt = 0, lastRunAt = 3_600_000),
        )
        // Three missed occurrences are skipped to one next run, never replayed N times.
        assertEquals(
            10_800_000L,
            RoutineScheduleMath.nextRunAt(schedule, now = 10_000_000, createdAt = 0),
        )
    }

    @Test
    fun phasedIntervalUsesThePhaseOffset() {
        val schedule = RoutineSchedule.interval(60, phaseMinutes = 15, timezone = "UTC")
        assertEquals(900_000L, RoutineScheduleMath.nextRunAt(schedule, now = 0, createdAt = 0))
        assertEquals(4_500_000L, RoutineScheduleMath.nextRunAt(schedule, now = 1_000_000, createdAt = 0))
    }

    @Test
    fun dailyUsesTheLocalWallClock() {
        val schedule = RoutineSchedule.daily("09:00", taipei)
        assertEquals(
            1_760_058_000_000L,
            RoutineScheduleMath.nextRunAt(schedule, now = 1_760_000_000_000L),
        )
        // Before the wall-clock time the same day fires that day.
        assertEquals(
            1_759_971_600_000L,
            RoutineScheduleMath.nextRunAt(schedule, now = 1_759_968_000_000L),
        )
    }

    @Test
    fun weeklyPicksTheNextListedIsoWeekday() {
        val schedule = RoutineSchedule.weekly("09:00", listOf(3, 1), taipei)
        assertEquals(listOf(1, 3), schedule.validated().weekdays)
        assertEquals(
            1_760_317_200_000L,
            RoutineScheduleMath.nextRunAt(schedule, now = 1_759_888_800_000L),
        )
    }

    @Test
    fun cronMatchesTheExpectedMinuteAndDate() {
        val schedule = RoutineSchedule.cron("30 8 * * *", taipei)
        assertEquals(
            1_760_056_200_000L,
            RoutineScheduleMath.nextRunAt(schedule, now = 1_760_000_000_000L),
        )
        assertEquals("30 8 * * *", RoutineScheduleMath.expression(schedule))
        // Day-of-month and day-of-week are OR-ed when both are restricted.
        val firstOrMonday = RoutineSchedule.cron("0 9 1 * 1", "UTC")
        val from = Instant.parse("2025-10-02T00:00:00Z").toEpochMilli()
        assertEquals(
            Instant.parse("2025-10-06T09:00:00Z").toEpochMilli(),
            RoutineScheduleMath.nextRunAt(firstOrMonday, now = from),
        )
    }

    @Test
    fun dailyAcrossSpringForwardResolvesLikeTheReference() {
        // 2025-03-09 02:30 does not exist in New York; the fixed point lands on
        // 03:30 EDT (07:30Z), the same instant Swift's three-pass loop returns.
        val schedule = RoutineSchedule.daily("02:30", "America/New_York")
        val now = Instant.parse("2025-03-09T05:00:00Z").toEpochMilli()
        assertEquals(
            Instant.parse("2025-03-09T07:30:00Z").toEpochMilli(),
            RoutineScheduleMath.nextRunAt(schedule, now = now),
        )
    }

    @Test
    fun dailyAcrossFallBackUsesTheFirstOccurrence() {
        val schedule = RoutineSchedule.daily("01:30", "America/New_York")
        val now = Instant.parse("2025-11-02T04:00:00Z").toEpochMilli()
        assertEquals(
            Instant.parse("2025-11-02T05:30:00Z").toEpochMilli(),
            RoutineScheduleMath.nextRunAt(schedule, now = now),
        )
    }

    @Test
    fun nextAfterAttemptSkipsForwardButNeverReplaysMissedRuns() {
        val routine = Routine(
            id = "r", agentId = "main", title = "t", prompt = "p",
            schedule = RoutineSchedule.daily("09:00", taipei), createdAt = 0,
            nextRunAt = 1_760_058_000_000L,
        )
        assertEquals(
            1_760_144_400_000L,
            RoutineScheduleMath.nextAfterAttempt(
                routine,
                startedAt = 1_760_058_000_000L,
                finishedAt = 1_760_058_000_000L + 5_000,
                scheduledFor = 1_760_058_000_000L,
            ),
        )
        // A run that finished a day later skips the occurrence it missed.
        assertEquals(
            1_760_230_800_000L,
            RoutineScheduleMath.nextAfterAttempt(
                routine,
                startedAt = 1_760_058_000_000L,
                finishedAt = 1_760_148_000_000L,
                scheduledFor = 1_760_058_000_000L,
            ),
        )
        assertNull(
            RoutineScheduleMath.nextAfterAttempt(
                routine.copy(enabled = false),
                startedAt = 1_760_058_000_000L,
                finishedAt = 1_760_058_000_000L,
                scheduledFor = 1_760_058_000_000L,
            ),
        )
    }

    @Test
    fun scheduleDslParsesEvery() {
        val every = RoutineScheduleParser.parse("@every 5m", now = 0, timezone = "UTC")
        assertEquals(RoutineSchedule.Kind.INTERVAL, every.kind)
        assertEquals(5, every.everyMinutes)

        val phased = RoutineScheduleParser.parse("@every 1h/15m", now = 0, timezone = "UTC")
        assertEquals(60, phased.everyMinutes)
        assertEquals(15, phased.phaseMinutes)

        val zoned = RoutineScheduleParser.parse(
            "CRON_TZ=Asia/Taipei 30 8 * * *", now = 0, timezone = "UTC",
        )
        assertEquals(taipei, zoned.timezone)
        assertEquals("30 8 * * *", zoned.expr)

        for (invalid in listOf("@every 2m", "@every 5m/5m", "@yearly", "not a cron", "")) {
            try {
                RoutineScheduleParser.parse(invalid, now = 0, timezone = "UTC")
                fail("$invalid must be rejected")
            } catch (_: RoutineError.InvalidSchedule) {
                // expected
            }
        }
    }

    @Test
    fun shorthandDailyUsesTheCurrentWallClock() {
        val now = 1_759_968_000_000L // 2025-10-09 08:00 +08
        val schedule = RoutineScheduleParser.parse("@daily", now = now, timezone = taipei)
        assertEquals(RoutineSchedule.Kind.CRON, schedule.kind)
        assertEquals("0 8 * * *", schedule.expr)
        assertEquals(1_760_054_400_000L, RoutineScheduleMath.nextRunAt(schedule, now = now))
    }

    @Test
    fun invalidSchedulesFailWithTheFrozenMessages() {
        data class Case(val schedule: RoutineSchedule, val message: String)
        val cases = listOf(
            Case(
                RoutineSchedule.interval(0, timezone = "UTC"),
                "schedule.everyMinutes must be an integer 1–525600",
            ),
            Case(
                RoutineSchedule.interval(10, phaseMinutes = 10, timezone = "UTC"),
                "schedule.phaseMinutes must be an integer offset shorter than everyMinutes",
            ),
            Case(
                RoutineSchedule.daily("9:5", timezone = "UTC"),
                "schedule.time must be HH:MM (00:00–23:59), got \"9:5\"",
            ),
            Case(
                RoutineSchedule.daily("24:00", timezone = "UTC"),
                "schedule.time must be HH:MM (00:00–23:59), got \"24:00\"",
            ),
            Case(
                RoutineSchedule.weekly("09:00", emptyList(), timezone = "UTC"),
                "schedule.weekdays must be a non-empty array of ISO weekdays 1=Mon … 7=Sun",
            ),
            Case(
                RoutineSchedule.weekly("09:00", listOf(0, 8), timezone = "UTC"),
                "schedule.weekdays must be a non-empty array of ISO weekdays 1=Mon … 7=Sun",
            ),
            Case(
                RoutineSchedule.cron("30 8 * *", timezone = "UTC"),
                "cron expr must have five fields: minute hour day-of-month month day-of-week",
            ),
            Case(
                RoutineSchedule.daily("09:00", timezone = ""),
                "schedule.timezone must be a non-empty IANA time zone",
            ),
            Case(
                RoutineSchedule.daily("09:00", timezone = "Mars/Olympus"),
                "unsupported time zone: Mars/Olympus",
            ),
        )
        for (case in cases) {
            try {
                case.schedule.validated()
                fail("expected rejection: ${case.message}")
            } catch (error: RoutineError.InvalidSchedule) {
                assertEquals(case.message, error.message)
            }
        }
    }

    @Test
    fun moreFrequentComparesTheNextTwoOccurrenceGaps() {
        val now = 1_760_000_000_000L
        assertTrue(
            RoutineScheduleMath.isMoreFrequent(
                RoutineSchedule.interval(30, timezone = taipei),
                RoutineSchedule.daily("09:00", taipei),
                now = now,
            ),
        )
        assertFalse(
            RoutineScheduleMath.isMoreFrequent(
                RoutineSchedule.daily("09:00", taipei),
                RoutineSchedule.daily("09:00", taipei),
                now = now,
            ),
        )
        assertFalse(
            RoutineScheduleMath.isMoreFrequent(
                RoutineSchedule.interval(30, timezone = taipei),
                RoutineSchedule.interval(0, timezone = taipei),
                now = now,
            ),
        )
    }

    @Test
    fun descriptionsAndExpressionsMatchTheFrozenText() {
        assertEquals("每天 08:30（Asia/Taipei）", RoutineScheduleMath.describe(RoutineSchedule.daily("08:30", taipei)))
        assertEquals("daily 08:30 (Asia/Taipei)", RoutineScheduleMath.describe(RoutineSchedule.daily("08:30", taipei), "en"))
        assertEquals("30 8 * * *", RoutineScheduleMath.expression(RoutineSchedule.daily("08:30", taipei)))
        assertEquals("每 30 分钟（UTC）", RoutineScheduleMath.describe(RoutineSchedule.interval(30, timezone = "UTC")))
        assertEquals(
            "每 30 分钟（相位 :15）（UTC）",
            RoutineScheduleMath.describe(RoutineSchedule.interval(30, phaseMinutes = 15, timezone = "UTC")),
        )
        assertEquals("@every 30m/15m", RoutineScheduleMath.expression(RoutineSchedule.interval(30, phaseMinutes = 15, timezone = "UTC")))
        assertEquals("每週一、三 09:00（Asia/Taipei）", RoutineScheduleMath.describe(RoutineSchedule.weekly("09:00", listOf(1, 3), taipei)))
        assertEquals("0 9 * * 1,3", RoutineScheduleMath.expression(RoutineSchedule.weekly("09:00", listOf(1, 3), taipei)))
        assertEquals("0 9 * * 1", RoutineScheduleMath.expression(RoutineSchedule.cron("0 9 * * 1", "UTC")))
    }

    @Test
    fun summarizeKeepsTheFirstSentenceAndCapsTheLength() {
        assertEquals("有三项变化。", RoutineScheduleMath.summarize("  有三项变化。  另外两项  "))
        assertEquals("检查完成.", RoutineScheduleMath.summarize("检查完成. Next sentence"))
        assertEquals("e.g.", RoutineScheduleMath.summarize("e.g. a value"))
        assertEquals("", RoutineScheduleMath.summarize("   "))
        assertEquals("长", RoutineScheduleMath.summarize("长".repeat(200), max = 1))
        assertTrue(RoutineScheduleMath.summarize("a".repeat(200)).length <= 100)
    }

    @Test
    fun formatMinuteIsFixedWidthOrNull() {
        assertEquals("2025-10-10 08:30", RoutineTime.formatMinute(1_760_056_200_000L, taipei))
        assertNull(RoutineTime.formatMinute(null, taipei))
        assertNull(RoutineTime.formatMinute(0, taipei))
        assertEquals("2025-10-09", RoutineTime.dayKey(1_760_000_000_000L, taipei))
    }
}
