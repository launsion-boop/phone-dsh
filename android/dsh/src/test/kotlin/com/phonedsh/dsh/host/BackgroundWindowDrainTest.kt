// phone-dsh — :dsh unit test: the turn window guards the drain (L49).
// SPDX-License-Identifier: MIT
//
// The defect these tests pin down: `scenePhase(background)` was fed to D14
// unconditionally, so the drain closed the epoch and stopped the worker *while
// the platform still held a UIDT/foreground-service window for the turn*. L39
// measured the result on API 35 — job 8401 in its execution slot, notification
// 7301 attached, `oom adj 201`, and `APP_TURN_FAILED reason=channel_lost`.
//
// What is asserted here, and nothing weaker:
//   * a window in place keeps `Running`: no epoch close, no worker stop, no
//     `Draining` row;
//   * no window keeps the old behaviour exactly (drain -> `Parked`);
//   * the window ending after the turn drains and advances `durable_upto`;
//   * a user stop (the notification's 停止本轮 ends the window) drains on the
//     very next window look — the window is never an exemption from a stop;
//   * a window that never ends is bounded: the hold expires, the drain runs, no
//     hold is left behind;
//   * an unreadable window (a throwing provider, or an inconsistent reading) is
//     treated as no window — the fail-safe direction is the drain, never an
//     exemption.
//
// Allocation: pure JVM, `FakePlatform` for Clock/LifecycleSignals/Notifier/engine
// and `FakeHostWal` for the WAL seam. `Dispatchers.Unconfined` makes the drain run
// inline; the window watch is armed with an interval that never fires and the
// tests drive `checkWindowHold()` themselves, so nothing here waits on a clock.

package com.phonedsh.dsh.host

import com.phonedsh.controller.Admission
import com.phonedsh.controller.ControllerStateMachine
import com.phonedsh.controller.HostState
import com.phonedsh.platform.AppForeground
import com.phonedsh.platform.EngineHostState
import com.phonedsh.platform.ScenePhase
import com.phonedsh.platform.testing.FakePlatform
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class BackgroundWindowDrainTest {
    private val logger = RecordingHostLog()

    @Test
    fun aWindowInPlaceKeepsRunningWithoutDraining() {
        val platform = FakePlatform()
        val wal = FakeHostWal()
        val window = FakeTurnWindow(TurnWindow.InPlace(TurnWindowBackend.USER_INITIATED_JOB))
        val host = newHost(platform, wal, window)
        try {
            becomeRunning(host, platform)

            goBackground(platform)

            assertEquals("the D14 state is still Running", HostState.RUNNING, host.controller.state)
            assertEquals(HostState.RUNNING, host.state.value)
            assertEquals("admission stays open for the running turn", Admission.OPEN, host.controller.admission)
            assertEquals("no epoch close while the window is in place", 0, wal.closeCalls)
            assertEquals("no worker stop while the window is in place", 0, platform.engine.stopCount)
            assertTrue("the background edge is held", host.isBackgroundEdgeHeld())
            assertTrue(heldMessage(), logger.messages.any { it.contains("window: the turn window is in place") })
            assertFalse(
                "no Draining row may be taken while the window is in place",
                host.controller.transitions.any { it.to == HostState.DRAINING },
            )
        } finally {
            host.stop()
        }
    }

    @Test
    fun noWindowStillDrainsAsBefore() {
        val platform = FakePlatform()
        val wal = FakeHostWal()
        val window = FakeTurnWindow(TurnWindow.Absent)
        val host = newHost(platform, wal, window)
        try {
            becomeRunning(host, platform)

            goBackground(platform)

            assertEquals(HostState.PARKED, host.controller.state)
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
    fun theWindowEndingAfterTheTurnDrainsAndAdvancesDurableUpto() {
        val platform = FakePlatform()
        val wal = FakeHostWal()
        val window = FakeTurnWindow(TurnWindow.InPlace(TurnWindowBackend.USER_INITIATED_JOB))
        val host = newHost(platform, wal, window)
        try {
            becomeRunning(host, platform)
            goBackground(platform)
            assertTrue(host.isBackgroundEdgeHeld())

            // `TurnBackground.complete()` ran: the turn finished, the window is gone.
            window.reading = TurnWindow.Absent
            assertFalse("the watch ends after the release", host.checkWindowHold())

            assertEquals(HostState.PARKED, host.controller.state)
            assertEquals("exactly one epoch close", 1, wal.closeCalls)
            assertEquals("the worker is stopped by the ordinary drain row", 1, platform.engine.stopCount)
            assertEquals(
                listOf(HostState.DRAINING, HostState.PARKED),
                host.controller.transitions.map { it.to }.drop(1),
            )
            assertTrue(
                "the close's watermark is reported (FakeHostWal closes at 41): ${logger.messages}",
                logger.messages.any { it.contains("drain done: reason=closed, durable_upto=41") },
            )
            assertFalse("no hold is left behind", host.isBackgroundEdgeHeld())
        } finally {
            host.stop()
        }
    }

    @Test
    fun aUserStopEndsTheHoldAndDrainsOnTheNextLook() {
        val platform = FakePlatform()
        val wal = FakeHostWal()
        val window = FakeTurnWindow(TurnWindow.InPlace(TurnWindowBackend.USER_INITIATED_JOB))
        val host = newHost(platform, wal, window)
        try {
            becomeRunning(host, platform)
            goBackground(platform)
            assertTrue(host.isBackgroundEdgeHeld())

            // 停止本轮: TurnStopReceiver -> TurnBackground.stop(USER_STOPPED) ends
            // the window synchronously. The host must not stay exempt because the
            // edge was held for a window; one look is enough.
            window.reading = TurnWindow.Absent
            assertFalse(host.checkWindowHold())

            assertEquals("a user stop is not exempted by the window", HostState.PARKED, host.controller.state)
            assertEquals(1, wal.closeCalls)
            assertEquals(1, platform.engine.stopCount)
            assertEquals(
                listOf(HostState.DRAINING, HostState.PARKED),
                host.controller.transitions.map { it.to }.drop(1),
            )
            assertTrue(
                "the release names the window end, not the deadline: ${logger.messages}",
                logger.messages.any { it.contains("reason=window_ended") },
            )
        } finally {
            host.stop()
        }
    }

    @Test
    fun aWindowThatNeverEndsIsBoundedAndStillDrains() {
        val platform = FakePlatform()
        val wal = FakeHostWal()
        val window = FakeTurnWindow(TurnWindow.InPlace(TurnWindowBackend.USER_INITIATED_JOB))
        val host = newHost(platform, wal, window, holdMaxMillis = HOLD_MAX_MILLIS)
        try {
            becomeRunning(host, platform)
            goBackground(platform)
            assertTrue(host.isBackgroundEdgeHeld())

            // The turn is wedged and the window never ends: the bound is the exit.
            platform.advanceBy(HOLD_MAX_MILLIS)

            assertFalse(host.checkWindowHold())

            assertEquals(HostState.PARKED, host.controller.state)
            assertEquals("the fallback takes the ordinary drain exit", 1, wal.closeCalls)
            assertEquals(1, platform.engine.stopCount)
            assertEquals(
                listOf(HostState.DRAINING, HostState.PARKED),
                host.controller.transitions.map { it.to }.drop(1),
            )
            assertTrue(
                "the deadline names itself: ${logger.messages}",
                logger.messages.any { it.contains("the hold expires and the drain runs") },
            )
            assertFalse("no hold is left hanging", host.isBackgroundEdgeHeld())
            assertFalse("the watch has nothing left to do", host.checkWindowHold())
            assertEquals("a repeated look cannot close a second epoch", 1, wal.closeCalls)
        } finally {
            host.stop()
        }
    }

    @Test
    fun anExpiredHoldIsNotReArmedUntilTheAppIsForeground() {
        val platform = FakePlatform()
        val window = FakeTurnWindow(TurnWindow.InPlace(TurnWindowBackend.USER_INITIATED_JOB))
        val hold = WindowHold(platform, window.read, HOLD_MAX_MILLIS, logger)
        try {
            assertNotNull("a measured window defers the edge", hold.hold())

            platform.advanceBy(HOLD_MAX_MILLIS)
            assertEquals(
                WindowHold.ReleaseReason.HOLD_DEADLINE,
                hold.check()?.reason,
            )
            assertTrue("the hold is now expired for this background spell", hold.isExpired)

            assertNull("the same background spell may not defer again", hold.hold())

            // The return is a foreground fact even when no hold is live: the next
            // background spell is a fresh window.
            hold.onForeground()
            assertFalse("the foreground return clears the refusal", hold.isExpired)
            assertNotNull("the next background spell may defer again", hold.hold())
        } finally {
            platform.close()
        }
    }

    @Test
    fun anUnreadableWindowIsTreatedAsNoWindow() {
        val platform = FakePlatform()
        val wal = FakeHostWal()
        val window = FakeTurnWindow(TurnWindow.Absent).apply {
            failure = IllegalStateException("PackageManager query failed")
        }
        val host = newHost(platform, wal, window)
        try {
            becomeRunning(host, platform)

            goBackground(platform)

            assertEquals("a failed reading drains", HostState.PARKED, host.controller.state)
            assertEquals(1, wal.closeCalls)
            assertEquals(1, platform.engine.stopCount)
            assertTrue(
                "the fail-safe direction is logged: ${logger.messages}",
                logger.messages.any {
                    it.contains("fail-safe direction") && it.contains("IllegalStateException")
                },
            )
            assertFalse(host.isBackgroundEdgeHeld())
        } finally {
            host.stop()
        }
    }

    @Test
    fun anInconsistentWindowReadingIsTreatedAsNoWindow() {
        val platform = FakePlatform()
        val wal = FakeHostWal()
        val window = FakeTurnWindow(TurnWindow.Unreadable("running turn with no backend"))
        val host = newHost(platform, wal, window)
        try {
            becomeRunning(host, platform)

            goBackground(platform)

            assertEquals(HostState.PARKED, host.controller.state)
            assertEquals(1, wal.closeCalls)
            assertTrue(
                "the reason is named: ${logger.messages}",
                logger.messages.any { it.contains("running turn with no backend") },
            )
        } finally {
            host.stop()
        }
    }

    @Test
    fun aForegroundReturnDropsTheHeldEdgeAndTheTurnStaysRunning() {
        val platform = FakePlatform()
        val wal = FakeHostWal()
        val window = FakeTurnWindow(TurnWindow.InPlace(TurnWindowBackend.USER_INITIATED_JOB))
        val host = newHost(platform, wal, window)
        try {
            becomeRunning(host, platform)
            goBackground(platform)
            assertTrue(host.isBackgroundEdgeHeld())

            // The adapter's order on a real return: AppForeground(true) first, then
            // scenePhase(active). The queued "background" no longer describes the
            // world, so it is dropped instead of fed.
            platform.emit(com.phonedsh.platform.AppForeground(true))
            platform.emit(ScenePhase(ScenePhase.Phase.ACTIVE))

            assertEquals(HostState.RUNNING, host.controller.state)
            assertEquals(0, wal.closeCalls)
            assertEquals(0, platform.engine.stopCount)
            assertFalse(host.isBackgroundEdgeHeld())
            assertFalse(
                "the held edge was dropped without an invented D14 row",
                logger.messages.any { it.contains("ILLEGAL_TRANSITION") },
            )

            // The window is gone and the app is visible: the next background edge
            // is the ordinary drain again.
            window.reading = TurnWindow.Absent
            goBackground(platform)
            assertEquals(HostState.PARKED, host.controller.state)
            assertEquals(1, wal.closeCalls)
        } finally {
            host.stop()
        }
    }

    private fun heldMessage(): String = "the window hold was not logged: ${logger.messages}"

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
        window: FakeTurnWindow,
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
        turnWindow = window.read,
        windowHoldMaxMillis = holdMaxMillis,
        // The watch must never race the test's own `checkWindowHold()` calls; the
        // interval is a real-time delay and these tests run in milliseconds.
        windowWatchIntervalMillis = 3_600_000L,
    )

    /** One mutable window reading, with a failure switch for the fail-safe test. */
    private class FakeTurnWindow(var reading: TurnWindow) {
        var failure: RuntimeException? = null

        val read: TurnWindowRead = TurnWindowRead {
            failure?.let { throw it }
            reading
        }
    }

    private companion object {
        /** A live origin; the port is what channel.md §1 would carry. */
        val RUNNING: EngineHostState = EngineHostState.Running("http://127.0.0.1:41234", 41234)

        const val HOLD_MAX_MILLIS: Long = 20_000L
    }
}
