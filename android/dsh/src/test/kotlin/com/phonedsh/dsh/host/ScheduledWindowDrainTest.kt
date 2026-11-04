// phone-dsh — :dsh unit test: a scheduled-but-not-started window guards the drain (L53).
// SPDX-License-Identifier: MIT
//
// L49 made "a window in place" defer `Running -> Draining`, but the reading could
// only see `RUNNING` — `onStartJob` / `onStartCommand` had actually run. The
// earliest real case was still broken: on a just-booted device whose network is
// not validated, `JobScheduler.schedule()` returns RESULT_SUCCESS and the UIDT job
// sits pending on its CONNECTIVITY constraint, so HOME before the job enters its
// execution slot read `Absent`, the drain ran, and the turn died.
//
// These tests drive the **production** reading (`TurnWindowRead.Platform`) against
// the real `TurnRuntime` and a real `DefaultPhoneDshHost`, so they fail if:
//   * a successful schedule is not recorded as `SCHEDULED`;
//   * `SCHEDULED` is not read as a window in place (the early-HOME regression);
//   * a schedule *failure* is mistakenly read as a window (the opposite failure —
//     an exemption with no OS promise behind it);
//   * the 600 s bound stops applying to a phase that never becomes `RUNNING`;
//   * 停止本轮 stops ending the edge immediately;
//   * the `SCHEDULED -> RUNNING` transition arms a second hold or restarts the
//     bound;
//   * the end of the turn leaves a scheduled window (or a late schedule result
//     resurrects it).
//
// Allocation: pure JVM. `FakePlatform` for Clock/LifecycleSignals/Notifier/engine,
// `FakeHostWal` for the WAL seam, `Dispatchers.Unconfined` so the drain runs
// inline. The window watch interval is set to an hour and the tests call
// `checkWindowHold()` themselves, so nothing waits on a wall clock.

package com.phonedsh.dsh.host

import com.phonedsh.controller.Admission
import com.phonedsh.controller.ControllerStateMachine
import com.phonedsh.controller.HostState
import com.phonedsh.dsh.background.TurnRequest
import com.phonedsh.dsh.background.TurnRuntime
import com.phonedsh.dsh.background.TurnStartResult
import com.phonedsh.dsh.background.WindowMark
import com.phonedsh.dsh.background.markAcceptedWindow
import com.phonedsh.dsh.background.windowBackend
import com.phonedsh.platform.AppForeground
import com.phonedsh.platform.EngineHostState
import com.phonedsh.platform.ScenePhase
import com.phonedsh.platform.testing.FakePlatform
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

class ScheduledWindowDrainTest {
    private val logger = RecordingHostLog()

    @Before
    fun clearTheProcessWideWindow() {
        TurnRuntime.resetForTest()
    }

    @After
    fun leaveNoWindowBehind() {
        TurnRuntime.resetForTest()
    }

    @Test
    fun aScheduledWindowThatHasNotStartedStillDefersTheDrain() {
        val request = TurnRequest(epoch = 81, step = 1, totalSteps = 4)
        // What `TurnJobScheduler.schedule()` does when the platform accepts a UIDT
        // job that has not entered its execution slot yet:
        TurnRuntime.scheduled(TurnRuntime.Backend.USER_INITIATED_JOB, request)
        assertEquals(
            "a success is recorded as SCHEDULED, not as RUNNING",
            TurnRuntime.Phase.SCHEDULED,
            TurnRuntime.snapshot().phase,
        )
        assertEquals(
            "the reading names the backend and how far it got",
            TurnWindow.InPlace(TurnWindowBackend.USER_INITIATED_JOB, TurnWindowPhase.SCHEDULED),
            TurnWindowRead.Platform.read(),
        )

        val platform = FakePlatform()
        val wal = FakeHostWal()
        val host = newHost(platform, wal)
        try {
            becomeRunning(host, platform)

            goBackground(platform)

            assertEquals("the D14 state is still Running", HostState.RUNNING, host.controller.state)
            assertEquals(HostState.RUNNING, host.state.value)
            assertEquals("admission stays open for the turn", Admission.OPEN, host.controller.admission)
            assertEquals("no epoch close while the window is scheduled", 0, wal.closeCalls)
            assertEquals("no worker stop while the window is scheduled", 0, platform.engine.stopCount)
            assertTrue("the background edge is held", host.isBackgroundEdgeHeld())
            assertFalse(
                "no Draining row may be taken for a scheduled window",
                host.controller.transitions.any { it.to == HostState.DRAINING },
            )
            assertTrue(
                "the hold names the scheduled phase: ${logger.messages}",
                logger.messages.any {
                    it.contains("window: the turn window is in place") &&
                        it.contains("phase=scheduled") &&
                        it.contains("backend=uidt")
                },
            )
        } finally {
            host.stop()
        }
    }

    @Test
    fun aFailedScheduleIsNotAWindowAndStillDrains() {
        // `TurnJobScheduler.schedule()` ends a failed schedule with
        // `markAcceptedWindow(request, ForegroundOnly(...))`; the production
        // recorder must return NOT_A_WINDOW here, or "maybe it was queued" would
        // exempt a turn with no OS promise behind it.
        val request = TurnRequest(epoch = 83)
        val failure = TurnStartResult.ForegroundOnly(
            TurnStartResult.ForegroundOnlyReason.START_NOT_ALLOWED,
        )
        assertNull("a failure names no backend", failure.windowBackend())
        assertEquals(
            "a failed schedule must not be recorded as a window",
            WindowMark.NOT_A_WINDOW,
            markAcceptedWindow(request, failure),
        )
        assertSame(TurnWindow.Absent, TurnWindowRead.Platform.read())
        assertEquals(
            "a failed schedule leaves the runtime IDLE",
            TurnRuntime.Phase.IDLE,
            TurnRuntime.snapshot().phase,
        )

        val platform = FakePlatform()
        val wal = FakeHostWal()
        val host = newHost(platform, wal)
        try {
            becomeRunning(host, platform)

            goBackground(platform)

            assertEquals("no window means the ordinary drain", HostState.PARKED, host.controller.state)
            assertEquals(Admission.CLOSED, host.controller.admission)
            assertEquals("one epoch close", 1, wal.closeCalls)
            assertEquals("one worker stop", 1, platform.engine.stopCount)
            assertFalse(host.isBackgroundEdgeHeld())
            assertEquals(
                listOf(HostState.DRAINING, HostState.PARKED),
                host.controller.transitions.map { it.to }.drop(1),
            )
        } finally {
            host.stop()
        }
    }

    @Test
    fun aScheduledWindowThatNeverStartsIsStillBoundedByTheHold() {
        assertEquals(
            "the production bound is 600 s",
            600_000L,
            DefaultPhoneDshHost.WINDOW_HOLD_MAX_MILLIS,
        )
        TurnRuntime.scheduled(TurnRuntime.Backend.USER_INITIATED_JOB, TurnRequest(epoch = 82))
        val platform = FakePlatform()
        val wal = FakeHostWal()
        // The production 600 s with a fake clock: nothing here waits on wall time.
        val host = newHost(platform, wal, holdMaxMillis = DefaultPhoneDshHost.WINDOW_HOLD_MAX_MILLIS)
        try {
            becomeRunning(host, platform)
            goBackground(platform)
            assertTrue("a scheduled window is held", host.isBackgroundEdgeHeld())

            // The job's constraint is never satisfied: the phase stays SCHEDULED
            // and the platform never calls back. The bound is the only exit.
            platform.advanceBy(DefaultPhoneDshHost.WINDOW_HOLD_MAX_MILLIS - 1)
            assertTrue(
                "one millisecond before the bound the scheduled window still holds",
                host.checkWindowHold(),
            )
            assertEquals(HostState.RUNNING, host.controller.state)

            platform.advanceBy(1)
            assertFalse(
                "the bound expires even though the window is still scheduled",
                host.checkWindowHold(),
            )

            assertEquals(HostState.PARKED, host.controller.state)
            assertEquals("the fallback takes the ordinary drain exit", 1, wal.closeCalls)
            assertEquals(1, platform.engine.stopCount)
            assertEquals(
                listOf(HostState.DRAINING, HostState.PARKED),
                host.controller.transitions.map { it.to }.drop(1),
            )
            assertTrue(
                "the deadline names itself and the phase: ${logger.messages}",
                logger.messages.any {
                    it.contains("the hold expires and the drain runs") &&
                        it.contains("phase=scheduled")
                },
            )
            assertFalse("no hold is left hanging", host.isBackgroundEdgeHeld())
            assertFalse("the watch has nothing left to do", host.checkWindowHold())
            assertEquals("a repeated look cannot close a second epoch", 1, wal.closeCalls)
        } finally {
            host.stop()
        }
    }

    @Test
    fun aUserStopWhileScheduledEndsTheWindowWithoutWaitingForTheBound() {
        TurnRuntime.scheduled(
            TurnRuntime.Backend.FOREGROUND_SERVICE,
            TurnRequest(epoch = 83),
        )
        val platform = FakePlatform()
        val wal = FakeHostWal()
        val host = newHost(platform, wal)
        try {
            becomeRunning(host, platform)
            goBackground(platform)
            assertTrue(host.isBackgroundEdgeHeld())

            // 停止本轮. `TurnBackground.stop`'s Context-bound cleanup is not
            // reachable on the JVM; the phase transition is, and it is the same
            // call stop() makes: `closeWindow` clears SCHEDULED as well as RUNNING.
            assertTrue(
                "a scheduled window counts as a live window for a stop",
                TurnRuntime.closeWindow(TurnRuntime.StopReason.USER_STOPPED),
            )
            assertEquals(TurnRuntime.Phase.STOPPED, TurnRuntime.snapshot().phase)
            assertSame(TurnWindow.Absent, TurnWindowRead.Platform.read())
            assertFalse(
                "a second stop has nothing left to close",
                TurnRuntime.closeWindow(TurnRuntime.StopReason.USER_STOPPED),
            )

            // One watch tick, far below the 600 s bound.
            platform.advanceBy(1_000)
            assertFalse("the stop ends the hold immediately", host.checkWindowHold())

            assertEquals("a user stop is not exempted by the window", HostState.PARKED, host.controller.state)
            assertEquals(1, wal.closeCalls)
            assertEquals(1, platform.engine.stopCount)
            assertTrue(
                "the release names the window end, not the deadline: ${logger.messages}",
                logger.messages.any { it.contains("reason=window_ended") },
            )
            assertTrue(
                "the released window is reported with the phase it had: ${logger.messages}",
                logger.messages.any {
                    it.contains("foreground_service window ended after") &&
                        it.contains("phase=scheduled")
                },
            )
            assertFalse(
                "no deadline may be involved in an immediate stop: ${logger.messages}",
                logger.messages.any { it.contains("the hold expires and the drain runs") },
            )
        } finally {
            host.stop()
        }
    }

    @Test
    fun scheduledTurningIntoRunningKeepsOneHoldAndTheSameBound() {
        val request = TurnRequest(epoch = 84, step = 2, totalSteps = 5)
        TurnRuntime.scheduled(TurnRuntime.Backend.USER_INITIATED_JOB, request)
        val platform = FakePlatform()
        val wal = FakeHostWal()
        val host = newHost(platform, wal, holdMaxMillis = HOLD_MAX_MILLIS)
        try {
            becomeRunning(host, platform)
            goBackground(platform)
            assertTrue(host.isBackgroundEdgeHeld())

            // The job enters its execution slot 3 s into the background spell.
            platform.advanceBy(3_000)
            TurnRuntime.begin(TurnRuntime.Backend.USER_INITIATED_JOB, request)
            assertEquals(
                TurnWindow.InPlace(TurnWindowBackend.USER_INITIATED_JOB, TurnWindowPhase.RUNNING),
                TurnWindowRead.Platform.read(),
            )

            assertTrue(
                "the same hold continues; the transition is not a new edge",
                host.checkWindowHold(),
            )
            assertEquals(HostState.RUNNING, host.controller.state)
            assertEquals(0, wal.closeCalls)
            assertFalse(host.controller.transitions.any { it.to == HostState.DRAINING })
            assertEquals(
                "the phase transition must not arm a second hold: ${logger.messages}",
                1,
                logger.messages.count { it.contains("window: the turn window is in place") },
            )
            assertTrue(
                "the hold reports the sharper reading without re-arming: ${logger.messages}",
                logger.messages.any {
                    it.contains("changed reading") && it.contains("uidt/scheduled -> uidt/running")
                },
            )

            // The bound still counts from the background edge: it expires
            // HOLD_MAX_MILLIS after the edge, not after the job started.
            platform.advanceBy(HOLD_MAX_MILLIS - 3_000)
            assertFalse(host.checkWindowHold())
            assertEquals(HostState.PARKED, host.controller.state)
            assertTrue(
                "the bound measured from the edge, not from the start: ${logger.messages}",
                logger.messages.any {
                    it.contains("is still in place after $HOLD_MAX_MILLIS ms") &&
                        it.contains("phase=running")
                },
            )
        } finally {
            host.stop()
        }
    }

    @Test
    fun theEndOfTheTurnClearsAScheduledWindowAndDoesNotResurrectIt() {
        val request = TurnRequest(epoch = 85)
        TurnRuntime.scheduled(TurnRuntime.Backend.USER_INITIATED_JOB, request)
        assertEquals(TurnRuntime.Phase.SCHEDULED, TurnRuntime.snapshot().phase)

        // End of turn: `TurnBackground.complete()` / `stop()` both close through
        // `TurnRuntime.closeWindow`, which clears SCHEDULED and not only RUNNING.
        assertTrue(TurnRuntime.closeWindow(TurnRuntime.StopReason.COMPLETED))
        assertEquals(TurnRuntime.Phase.STOPPED, TurnRuntime.snapshot().phase)
        assertSame(TurnWindow.Absent, TurnWindowRead.Platform.read())

        // A late schedule result for the same epoch must not resurrect it.
        assertEquals(
            TurnRuntime.Phase.STOPPED,
            TurnRuntime.scheduled(TurnRuntime.Backend.USER_INITIATED_JOB, request).phase,
        )
        assertSame(
            "no window is left behind by a late result",
            TurnWindow.Absent,
            TurnWindowRead.Platform.read(),
        )

        // The refusal is epoch-scoped: the next turn can open a window normally.
        assertEquals(
            TurnRuntime.Phase.SCHEDULED,
            TurnRuntime.scheduled(
                TurnRuntime.Backend.USER_INITIATED_JOB,
                TurnRequest(epoch = 86),
            ).phase,
        )
        assertTrue(TurnRuntime.closeWindow(TurnRuntime.StopReason.COMPLETED))

        // And a host that boots with no window has no residue to hold on: the
        // background edge drains exactly as it did before this phase existed.
        val platform = FakePlatform()
        val wal = FakeHostWal()
        val host = newHost(platform, wal)
        try {
            becomeRunning(host, platform)
            goBackground(platform)
            assertFalse(host.isBackgroundEdgeHeld())
            assertEquals(HostState.PARKED, host.controller.state)
            assertEquals(1, wal.closeCalls)
        } finally {
            host.stop()
        }
    }

    /**
     * A real background switch, in `AndroidLifecycleSignals`' order: the scene
     * phase first, then `AppForeground(false)` — both are recorded inside one
     * `Runnable` on HOME, so this is the pair the facade sees on a device.
     */
    private fun goBackground(platform: FakePlatform) {
        platform.emit(ScenePhase(ScenePhase.Phase.BACKGROUND))
        platform.emit(AppForeground(false))
    }

    private fun becomeRunning(host: DefaultPhoneDshHost, platform: FakePlatform) {
        host.start()
        assertEquals("the boot mapping starts in Recovering", HostState.RECOVERING, host.controller.state)
        platform.engine.setState(RUNNING)
        assertEquals(HostState.RUNNING, host.controller.state)
    }

    private fun newHost(
        platform: FakePlatform,
        wal: HostWal,
        holdMaxMillis: Long = 60_000L,
    ): DefaultPhoneDshHost = DefaultPhoneDshHost(
        engine = platform.engine,
        controller = ControllerStateMachine.boot(persistedState = null),
        clock = platform,
        signals = platform,
        notifier = platform,
        wal = wal,
        scope = CoroutineScope(Dispatchers.Unconfined),
        logger = logger,
        // The production reading: these tests are about what the *scheduler's
        // acceptance* does to the drain, not about a fake that believes it.
        turnWindow = TurnWindowRead.Platform,
        windowHoldMaxMillis = holdMaxMillis,
        // The watch must never race the test's own `checkWindowHold()` calls; the
        // interval is a real-time delay and these tests run in milliseconds.
        windowWatchIntervalMillis = 3_600_000L,
    )

    private companion object {
        /** A live origin; the port is what channel.md §1 would carry. */
        val RUNNING: EngineHostState = EngineHostState.Running("http://127.0.0.1:41235", 41235)

        const val HOLD_MAX_MILLIS: Long = 20_000L
    }
}
