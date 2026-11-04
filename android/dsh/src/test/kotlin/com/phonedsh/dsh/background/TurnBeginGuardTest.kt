// phone-dsh — :dsh unit test: a late component start cannot resurrect a stopped turn.
// SPDX-License-Identifier: MIT
//
// The audit's interleaving (L60 #7):
//
//   controller coroutine:  TurnBackground.stop() -> closeWindow()      -> STOPPED
//   main-thread queue:     onStartJob (already dispatched) -> begin()  -> RUNNING
//
// The second half is the ghost: `TurnWindowRead.Platform` reads
// `InPlace(RUNNING)`, so the drain guard exempts a host whose turn the user just
// killed, and `InterruptedTurnStore.begin` rewrites the marker. `begin` is now a
// result type and refuses the stopped epoch; these tests pin the refusal and its
// two boundaries:
//
//   * epoch scope — the next turn starts from STOPPED normally;
//   * retriability — `onStopJob` returns `true` and the system reschedules the
//     *same* job/epoch, so that start is a resume, not a resurrection. The flag
//     is cleared by every terminal close, including one that arrives after the
//     system stop.

package com.phonedsh.dsh.background

import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

class TurnBeginGuardTest {
    @Before
    fun clearTheProcessWideWindow() {
        TurnRuntime.resetForTest()
    }

    @After
    fun leaveNoWindowBehind() {
        TurnRuntime.resetForTest()
    }

    @Test
    fun aStartQueuedBeforeTheUserStopIsRefused() {
        val request = request(epoch = 101, step = 3)
        assertTrue(
            "the turn must have been running for the stop to mean anything",
            TurnRuntime.begin(TurnRuntime.Backend.USER_INITIATED_JOB, request) is
                TurnRuntime.BeginResult.Started,
        )
        assertTrue(TurnRuntime.closeWindow(TurnRuntime.StopReason.USER_STOPPED))

        // The queued onStartJob now reaches the runtime.
        val refused = TurnRuntime.begin(TurnRuntime.Backend.USER_INITIATED_JOB, request) as
            TurnRuntime.BeginResult.Refused
        assertEquals(TurnRuntime.RefusalReason.TURN_ENDED, refused.reason)
        assertEquals("the refusal reports the state it refused from", TurnRuntime.snapshot(), refused.snapshot)

        val after = TurnRuntime.snapshot()
        assertEquals("no ghost window", TurnRuntime.Phase.STOPPED, after.phase)
        assertFalse("a refused start never opens admission", after.admissionOpen)
        assertEquals(TurnRuntime.StopReason.USER_STOPPED, after.stopReason)
        assertEquals(101L, after.epoch)
        assertEquals(TurnRuntime.Backend.USER_INITIATED_JOB, after.backend)
        assertEquals("the refused start must not rewind the step", 3, after.step)
    }

    @Test
    fun theRefusalIsEpochScopedAndNotSticky() {
        TurnRuntime.begin(TurnRuntime.Backend.USER_INITIATED_JOB, request(epoch = 102))
        TurnRuntime.closeWindow(TurnRuntime.StopReason.COMPLETED)

        // A queued start for the *next* turn is the normal case, not a ghost.
        val next = TurnRuntime.begin(TurnRuntime.Backend.USER_INITIATED_JOB, request(epoch = 103))
        assertTrue(next is TurnRuntime.BeginResult.Started)
        assertEquals(TurnRuntime.Phase.RUNNING, next.snapshot.phase)
        assertTrue(next.snapshot.admissionOpen)
        assertEquals(103L, next.snapshot.epoch)
    }

    @Test
    fun aCompletedTurnRefusesItsOwnLateStart() {
        TurnRuntime.begin(TurnRuntime.Backend.FOREGROUND_SERVICE, request(epoch = 104))
        TurnRuntime.finish(TurnRuntime.StopReason.COMPLETED)

        val refused = TurnRuntime.begin(TurnRuntime.Backend.FOREGROUND_SERVICE, request(epoch = 104)) as
            TurnRuntime.BeginResult.Refused
        assertEquals(TurnRuntime.RefusalReason.TURN_ENDED, refused.reason)
        assertEquals(TurnRuntime.Phase.STOPPED, TurnRuntime.snapshot().phase)
        assertEquals(TurnRuntime.StopReason.COMPLETED, TurnRuntime.snapshot().stopReason)
    }

    @Test
    fun theRetriableSystemStopIsTheOneStartThatResumes() {
        val request = request(epoch = 105)
        TurnRuntime.begin(TurnRuntime.Backend.USER_INITIATED_JOB, request)

        // `TurnJobService.onStopJob`: close admission, keep the marker, tell the
        // system to reschedule this same job.
        TurnRuntime.closeAdmission(TurnRuntime.StopReason.JOB_STOPPED)
        TurnRuntime.finish(TurnRuntime.StopReason.JOB_STOPPED, retriable = true)
        assertTrue("a rescheduled job must be allowed to resume", TurnRuntime.snapshot().retriable)

        val resumed = TurnRuntime.begin(TurnRuntime.Backend.USER_INITIATED_JOB, request)
        assertTrue("the system's retry is not a ghost", resumed is TurnRuntime.BeginResult.Started)
        assertEquals(TurnRuntime.Phase.RUNNING, resumed.snapshot.phase)
        assertTrue(resumed.snapshot.admissionOpen)
        assertFalse("a live window is never retriable", resumed.snapshot.retriable)
    }

    @Test
    fun aUserStopAfterTheSystemStopRevokesTheRetry() {
        TurnRuntime.begin(TurnRuntime.Backend.USER_INITIATED_JOB, request(epoch = 106))
        TurnRuntime.finish(TurnRuntime.StopReason.JOB_STOPPED, retriable = true)

        // The user stops in the gap between onStopJob and the reschedule.
        assertFalse("there is no window left to close", TurnRuntime.closeWindow(TurnRuntime.StopReason.USER_STOPPED))
        assertFalse("the stop still revokes the retry", TurnRuntime.snapshot().retriable)
        assertEquals(TurnRuntime.StopReason.USER_STOPPED, TurnRuntime.snapshot().stopReason)

        val refused = TurnRuntime.begin(TurnRuntime.Backend.USER_INITIATED_JOB, request(epoch = 106)) as
            TurnRuntime.BeginResult.Refused
        assertEquals(TurnRuntime.RefusalReason.TURN_ENDED, refused.reason)
        assertEquals(TurnRuntime.Phase.STOPPED, TurnRuntime.snapshot().phase)
    }

    @Test
    fun aLateSystemStopDoesNotRearmATurnThatAlreadyEnded() {
        TurnRuntime.begin(TurnRuntime.Backend.USER_INITIATED_JOB, request(epoch = 107))
        TurnRuntime.closeWindow(TurnRuntime.StopReason.USER_STOPPED)

        // The platform's stop callback lands after the user's stop.
        TurnRuntime.finish(TurnRuntime.StopReason.JOB_STOPPED, retriable = true)
        assertFalse(
            "a stop that found no window must not make the ended turn resumable",
            TurnRuntime.snapshot().retriable,
        )

        val refused = TurnRuntime.begin(TurnRuntime.Backend.USER_INITIATED_JOB, request(epoch = 107)) as
            TurnRuntime.BeginResult.Refused
        assertEquals(TurnRuntime.RefusalReason.TURN_ENDED, refused.reason)
    }

    @Test
    fun aRefusedStartLeavesTheRefusingSnapshotUnchanged() {
        TurnRuntime.begin(TurnRuntime.Backend.USER_INITIATED_JOB, request(epoch = 108))
        TurnRuntime.closeWindow(TurnRuntime.StopReason.USER_STOPPED)
        val before = TurnRuntime.snapshot()

        TurnRuntime.begin(TurnRuntime.Backend.USER_INITIATED_JOB, request(epoch = 108))
        assertEquals("a refusal is not a state write", before, TurnRuntime.snapshot())
    }

    private fun request(epoch: Long, step: Int = 1) =
        TurnRequest(epoch = epoch, step = step, totalSteps = 4)
}
