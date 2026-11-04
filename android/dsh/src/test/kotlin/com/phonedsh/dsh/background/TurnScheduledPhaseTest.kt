// phone-dsh — :dsh unit test: schedule success is SCHEDULED, failure is nothing (L53).
// SPDX-License-Identifier: MIT
//
// `TurnJobScheduler.schedule()` is the only place that learns whether the
// platform accepted a window before any component ran. Its decision is factored
// into the pure `markAcceptedWindow` (no `Context`, no `Log`) so the rule can be
// asserted on the JVM — the Context-bound half (`NotificationCapability.probe`,
// `JobScheduler.schedule`, `startForegroundService`) is one `when` over the
// result and is not reachable here without Robolectric.
//
// What must never happen, and is asserted below:
//   * a [TurnStartResult.ForegroundOnly] being recorded as a window — "maybe it
//     was queued" would exempt a turn with no OS promise behind it;
//   * a late schedule result downgrading a window the platform already started;
//   * a late schedule result resurrecting a turn that already ended;
//   * the stop refusal becoming sticky for the *next* turn.

package com.phonedsh.dsh.background

import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

class TurnScheduledPhaseTest {
    @Before
    fun clearTheProcessWideWindow() {
        TurnRuntime.resetForTest()
    }

    @After
    fun leaveNoWindowBehind() {
        TurnRuntime.resetForTest()
    }

    @Test
    fun onlyAChannelBearingResultIsAWindow() {
        assertEquals(
            TurnRuntime.Backend.USER_INITIATED_JOB,
            TurnStartResult.UserInitiatedJobScheduled(TurnJobScheduler.JOB_ID).windowBackend(),
        )
        assertEquals(
            TurnRuntime.Backend.FOREGROUND_SERVICE,
            TurnStartResult.DataSyncForegroundServiceStarted.windowBackend(),
        )
        for (reason in TurnStartResult.ForegroundOnlyReason.entries) {
            assertNull(
                "$reason is not a window",
                TurnStartResult.ForegroundOnly(reason).windowBackend(),
            )
        }
    }

    @Test
    fun anAcceptedUidtIsReservedAsScheduledNotRunning() {
        assertEquals(
            WindowMark.RESERVED,
            markAcceptedWindow(
                request(epoch = 81),
                TurnStartResult.UserInitiatedJobScheduled(TurnJobScheduler.JOB_ID),
            ),
        )
        val snapshot = TurnRuntime.snapshot()
        assertEquals(TurnRuntime.Phase.SCHEDULED, snapshot.phase)
        assertEquals(TurnRuntime.Backend.USER_INITIATED_JOB, snapshot.backend)
        assertEquals(81L, snapshot.epoch)
        assertFalse("a queued window is not execution", snapshot.admissionOpen)
        assertTrue("a queued window is still a window", snapshot.hasWindow)
        assertTrue(snapshot.isScheduled)
        assertFalse(snapshot.isRunning)
    }

    @Test
    fun anAcceptedForegroundServiceIsReservedWithItsOwnBackend() {
        assertEquals(
            WindowMark.RESERVED,
            markAcceptedWindow(request(epoch = 82), TurnStartResult.DataSyncForegroundServiceStarted),
        )
        val snapshot = TurnRuntime.snapshot()
        assertEquals(TurnRuntime.Phase.SCHEDULED, snapshot.phase)
        assertEquals(TurnRuntime.Backend.FOREGROUND_SERVICE, snapshot.backend)
    }

    @Test
    fun aFailureReservesNothingAndLeavesTheRuntimeUntouched() {
        for (reason in TurnStartResult.ForegroundOnlyReason.entries) {
            TurnRuntime.resetForTest()
            assertEquals(
                "$reason must not be recorded as a window",
                WindowMark.NOT_A_WINDOW,
                markAcceptedWindow(
                    request(epoch = 83),
                    TurnStartResult.ForegroundOnly(reason),
                ),
            )
            val snapshot = TurnRuntime.snapshot()
            assertEquals(TurnRuntime.Phase.IDLE, snapshot.phase)
            assertNull("no backend may be invented", snapshot.backend)
            assertFalse(snapshot.hasWindow)
        }

        // A failure must not disturb a window that is already live either.
        TurnRuntime.begin(TurnRuntime.Backend.USER_INITIATED_JOB, request(epoch = 90))
        assertEquals(
            WindowMark.NOT_A_WINDOW,
            markAcceptedWindow(
                request(epoch = 91),
                TurnStartResult.ForegroundOnly(
                    TurnStartResult.ForegroundOnlyReason.NOTIFICATIONS_UNAVAILABLE,
                ),
            ),
        )
        assertTrue(TurnRuntime.snapshot().isRunning)
        assertEquals(90L, TurnRuntime.snapshot().epoch)
    }

    @Test
    fun theComponentStartingUpgradesTheScheduleToRunning() {
        markAcceptedWindow(
            request(epoch = 84),
            TurnStartResult.UserInitiatedJobScheduled(TurnJobScheduler.JOB_ID),
        )
        // `TurnJobService.onStartJob` / `TurnForegroundService.onStartCommand`:
        val started = TurnRuntime.begin(TurnRuntime.Backend.USER_INITIATED_JOB, request(epoch = 84))
        assertTrue("the component's own start opens the window", started is TurnRuntime.BeginResult.Started)
        assertEquals(TurnRuntime.Phase.RUNNING, started.snapshot.phase)
        assertTrue("execution opens admission", started.snapshot.admissionOpen)
    }

    @Test
    fun aLateResultDoesNotDowngradeAWindowThePlatformAlreadyStarted() {
        TurnRuntime.begin(TurnRuntime.Backend.USER_INITIATED_JOB, request(epoch = 85))
        assertEquals(
            "the platform started the component before schedule() returned",
            WindowMark.ALREADY_RUNNING,
            markAcceptedWindow(
                request(epoch = 85),
                TurnStartResult.UserInitiatedJobScheduled(TurnJobScheduler.JOB_ID),
            ),
        )
        assertEquals(TurnRuntime.Phase.RUNNING, TurnRuntime.snapshot().phase)
        assertTrue(TurnRuntime.snapshot().admissionOpen)
    }

    @Test
    fun aLateResultAfterTheStopIsReportedAndNotReserved() {
        markAcceptedWindow(request(epoch = 86), TurnStartResult.DataSyncForegroundServiceStarted)
        assertTrue(
            "the stop closes a scheduled window",
            TurnRuntime.closeWindow(TurnRuntime.StopReason.USER_STOPPED),
        )
        assertEquals(
            "the scheduler must cancel what it just queued",
            WindowMark.TURN_ENDED,
            markAcceptedWindow(request(epoch = 86), TurnStartResult.DataSyncForegroundServiceStarted),
        )
        val snapshot = TurnRuntime.snapshot()
        assertEquals(TurnRuntime.Phase.STOPPED, snapshot.phase)
        assertEquals(TurnRuntime.StopReason.USER_STOPPED, snapshot.stopReason)
    }

    @Test
    fun theStopRefusalIsEpochScopedNotSticky() {
        markAcceptedWindow(
            request(epoch = 87),
            TurnStartResult.UserInitiatedJobScheduled(TurnJobScheduler.JOB_ID),
        )
        assertTrue(TurnRuntime.closeWindow(TurnRuntime.StopReason.COMPLETED))

        // A *new* turn after a stop is the normal case (every second turn).
        assertEquals(
            WindowMark.RESERVED,
            markAcceptedWindow(
                request(epoch = 88),
                TurnStartResult.UserInitiatedJobScheduled(TurnJobScheduler.JOB_ID),
            ),
        )
        assertEquals(TurnRuntime.Phase.SCHEDULED, TurnRuntime.snapshot().phase)
        assertEquals(88L, TurnRuntime.snapshot().epoch)
    }

    @Test
    fun closingAWindowIsIdempotentAndReportsWhetherOneExisted() {
        assertFalse("an idle runtime has no window to close", TurnRuntime.closeWindow(TurnRuntime.StopReason.USER_STOPPED))
        markAcceptedWindow(request(epoch = 89), TurnStartResult.DataSyncForegroundServiceStarted)
        assertTrue(TurnRuntime.closeWindow(TurnRuntime.StopReason.USER_STOPPED))
        assertFalse(TurnRuntime.closeWindow(TurnRuntime.StopReason.USER_STOPPED))
    }

    private fun request(epoch: Long) = TurnRequest(epoch = epoch, step = 1, totalSteps = 4)
}
