// SPDX-License-Identifier: MIT
package com.phonedsh.bot.routines

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** The presence ladder and the Bot information page's deferral list (v2 §3.2). */
class RoutinePresenceTest {
    private val t0 = 1_760_000_000_000L

    private fun routine(
        id: String,
        enabled: Boolean = true,
        nextRunAt: Long? = t0 + 60_000,
        quietDefer: RoutineQuietDefer? = null,
        status: RoutineRunStatus? = null,
    ): Routine = Routine(
        id = id, agentId = "main", title = "T$id", prompt = "P",
        schedule = RoutineSchedule.daily("09:00", "Asia/Taipei"),
        enabled = enabled, createdAt = t0, nextRunAt = nextRunAt, quietDefer = quietDefer,
        runState = status?.let {
            RoutineRunState(runId = "run-$id", attempt = 1, status = it, startedAt = t0)
        },
    )

    @Test
    fun theLevelFollowsForegroundKeepAliveThenScheduledNotification() {
        assertEquals(
            RoutinePresenceLevel.FOREGROUND,
            RoutinePresencePolicy.level(appActive = true, keepingAlive = false, scheduledNotificationCount = 0),
        )
        assertEquals(
            RoutinePresenceLevel.BACKGROUND_KEEP_ALIVE,
            RoutinePresencePolicy.level(appActive = false, keepingAlive = true, scheduledNotificationCount = 0),
        )
        assertEquals(
            RoutinePresenceLevel.SCHEDULED_NOTIFICATION,
            RoutinePresencePolicy.level(appActive = false, keepingAlive = false, scheduledNotificationCount = 2),
        )
        assertEquals("foreground", RoutinePresenceLevel.FOREGROUND.rawValue)
        assertEquals("backgroundKeepAlive", RoutinePresenceLevel.BACKGROUND_KEEP_ALIVE.rawValue)
        assertEquals("scheduledNotification", RoutinePresenceLevel.SCHEDULED_NOTIFICATION.rawValue)
    }

    @Test
    fun theKeepAliveWindowIsFifteenMinutes() {
        assertEquals(900_000L, RoutinePresencePolicy.KEEP_ALIVE_WINDOW_MS)
        assertTrue(RoutinePresencePolicy.hasRoutineDueSoon(listOf(routine("a", nextRunAt = t0 + 900_000)), now = t0))
        assertFalse(RoutinePresencePolicy.hasRoutineDueSoon(listOf(routine("a", nextRunAt = t0 + 900_001)), now = t0))
        assertFalse(RoutinePresencePolicy.hasRoutineDueSoon(listOf(routine("a", enabled = false)), now = t0))
        assertFalse(
            RoutinePresencePolicy.hasRoutineDueSoon(
                listOf(routine("a", status = RoutineRunStatus.NEEDS_RECONCILIATION)), now = t0,
            ),
        )
        assertFalse(RoutinePresencePolicy.hasRoutineDueSoon(listOf(routine("a", nextRunAt = null)), now = t0))
        assertFalse(
            RoutinePresencePolicy.hasRoutineDueSoon(
                listOf(routine("a")), now = t0, windowMs = -1,
            ),
        )
    }

    @Test
    fun theDeferralListIsEnabledSortedAndNotFabricated() {
        val deferred = listOf(
            routine(
                "b", quietDefer = RoutineQuietDefer(until = t0 + 20, scheduledFor = t0, at = t0),
            ),
            routine(
                "a", quietDefer = RoutineQuietDefer(until = t0 + 10, scheduledFor = t0, at = t0),
            ),
            routine("c", enabled = false, quietDefer = RoutineQuietDefer(until = t0 + 5, scheduledFor = t0, at = t0)),
            routine("d"),
        )
        val list = RoutinePresencePolicy.deferred(deferred)
        assertEquals(listOf("a", "b"), list.map { it.routineId })
        assertEquals("Ta", list[0].title)
        assertEquals(t0, list[0].scheduledFor)
        assertEquals(t0 + 10, list[0].deferredUntil)
        assertEquals("a", list[0].id)
    }

    @Test
    fun thePresenceValueKeepsTheRegisteredFacts() {
        val presence = RoutinePresence(
            level = RoutinePresenceLevel.SCHEDULED_NOTIFICATION,
            deferred = emptyList(),
            scheduledNotificationCount = 3,
            nextNotificationAt = t0 + 1_000,
        )
        assertEquals(3, presence.scheduledNotificationCount)
        assertEquals(t0 + 1_000, presence.nextNotificationAt)
        assertNull(RoutinePresence(level = RoutinePresenceLevel.FOREGROUND).nextNotificationAt)
        try {
            RoutinePresence(level = RoutinePresenceLevel.FOREGROUND, scheduledNotificationCount = -1)
            org.junit.Assert.fail("a negative count is not a fact")
        } catch (_: IllegalArgumentException) {
            // expected
        }
    }

    @Test
    fun theProcessWidePresenceCenterUpdatesIndependently() {
        val center = BotPresenceCenter()
        assertEquals(BotPresenceCenter.Context.foreground, center.context())
        center.update(appActive = false)
        assertEquals(false, center.appActive())
        assertEquals(false, center.keepingAlive())
        center.update(keepingAlive = true)
        assertEquals(BotPresenceCenter.Context(appActive = false, keepingAlive = true), center.context())
        center.update(appActive = true, keepingAlive = false)
        assertEquals(BotPresenceCenter.Context.foreground, center.context())
    }
}
