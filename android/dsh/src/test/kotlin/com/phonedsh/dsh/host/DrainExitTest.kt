// phone-dsh — :dsh unit test: the drain's exit and the foreground return (P10).
// SPDX-License-Identifier: MIT
//
// The defect these tests pin down: `scenePhase(background)` moved the host to
// `Draining`, nothing performed the row's actions (no epoch close, no worker
// stop, no `DrainCompleted`), and the later `scenePhase(active)` was refused
// with `ILLEGAL_TRANSITION`, so the App stayed unusable until a force-stop
// (P5 measured it, P10 reproduced it on emulator API 35, 2026-11-01).
//
// What is asserted here, and nothing weaker:
//   * a background switch ends in `Parked` through the `Draining -> Parked` row,
//     with the epoch closed exactly once and the worker stopped;
//   * a foreground return from `Parked` returns to `Running` with admission
//     open, i.e. the App is usable again;
//   * a foreground return *while* the epoch close is still running (the gate)
//     is not an `ILLEGAL_TRANSITION`: the drain finishes, the same signal is
//     re-fed afterwards, and no data is lost — the close still runs to
//     completion and the WAL body list is untouched;
//   * `ILLEGAL_TRANSITION` never appears in the log for these signals. That is
//     the exact line the device evidence showed.
//
// Allocation: pure JVM, `FakePlatform` for Clock/LifecycleSignals/Notifier/engine
// and `FakeHostWal` for the WAL seam. `Dispatchers.Unconfined` makes the drain
// run inline, so an `emit` returns with the drain where the fake left it.

package com.phonedsh.dsh.host

import com.phonedsh.controller.Admission
import com.phonedsh.controller.ControllerBudgets
import com.phonedsh.controller.ControllerFailure
import com.phonedsh.controller.ControllerSignal
import com.phonedsh.controller.ControllerStateMachine
import com.phonedsh.controller.HostState
import com.phonedsh.platform.EngineHostState
import com.phonedsh.platform.ScenePhase
import com.phonedsh.platform.testing.FakePlatform
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class DrainExitTest {
    private val logger = RecordingHostLog()

    @Test
    fun backgroundParksThroughTheDrainExitWithOneEpochCloseAndTheWorkerStopped() {
        val platform = FakePlatform()
        val wal = FakeHostWal()
        val host = newHost(platform, wal)
        host.start()
        platform.engine.setState(RUNNING)
        assertEquals(HostState.RUNNING, host.controller.state)

        platform.emit(ScenePhase(ScenePhase.Phase.BACKGROUND))

        // The row is taken, and its exit is taken: Draining is not terminal.
        assertEquals(HostState.PARKED, host.controller.state)
        assertEquals(HostState.PARKED, host.state.value)
        assertEquals(Admission.CLOSED, host.controller.admission)
        assertEquals(
            listOf(HostState.DRAINING, HostState.PARKED),
            host.controller.transitions.map { it.to }.drop(1),
        )
        assertEquals("the epoch is closed exactly once", 1, wal.closeCalls)
        assertEquals("the worker is stopped by the drain row", 1, platform.engine.stopCount)
        assertFalse("no drain is left in flight", host.isDrainInFlight())
        assertNoIllegalTransition()
    }

    @Test
    fun aForegroundReturnFromParkedReturnsToRunningWithAdmissionOpen() {
        val platform = FakePlatform()
        val host = newHost(platform, FakeHostWal())
        host.start()
        platform.engine.setState(RUNNING)
        platform.emit(ScenePhase(ScenePhase.Phase.BACKGROUND))
        assertEquals(HostState.PARKED, host.controller.state)

        platform.emit(ScenePhase(ScenePhase.Phase.ACTIVE))

        // `Parked -> Recovering` is the spec row; it starts the worker it parked.
        assertEquals(HostState.RECOVERING, host.controller.state)
        assertEquals("the resume starts the worker", 2, platform.engine.startCount)

        // The worker comes back and the lease check opens admission.
        platform.engine.setState(RUNNING)

        assertEquals(HostState.RUNNING, host.controller.state)
        assertEquals(Admission.OPEN, host.controller.admission)
        assertEquals(HostState.RUNNING, host.state.value)
        assertNoIllegalTransition()
    }

    @Test
    fun aForegroundReturnWhileTheEpochCloseRunsFinishesTheDrainAndResumesWithoutLosingBytes() {
        val platform = FakePlatform()
        val closeGate = CompletableDeferred<Unit>()
        val wal = FakeHostWal(closeGate = closeGate)
        val host = newHost(platform, wal)
        host.start()
        platform.engine.setState(RUNNING)
        assertEquals(HostState.RUNNING, host.controller.state)
        val appendedBefore = wal.appendedBodies.size

        // The close is still running, so the host is genuinely `Draining` when
        // the user comes back — the state the device evidence was stuck in.
        platform.emit(ScenePhase(ScenePhase.Phase.BACKGROUND))
        assertEquals(HostState.DRAINING, host.controller.state)
        assertTrue("the epoch close is inside the WAL seam", wal.isClosing)
        // The 20 s deadline of §1 is armed from the injected monotonic clock, not
        // from a wall clock this test does not control.
        assertEquals(
            ControllerBudgets.DRAIN_DEADLINE_MILLIS,
            host.controller.drainDeadlineAtMillis!! - host.controller.drainStartedAtMillis!!,
        )

        platform.emit(ScenePhase(ScenePhase.Phase.ACTIVE))

        // Not refused, not routed through an invented edge: still Draining, with
        // the resume queued behind the drain.
        assertEquals(HostState.DRAINING, host.controller.state)
        assertEquals(Admission.CLOSED, host.controller.admission)
        assertNoIllegalTransition()

        // The close finishes; its fsync was not cancelled by the return.
        closeGate.complete(Unit)

        assertEquals(
            "the queued resume ran after the drain",
            HostState.RECOVERING,
            host.controller.state,
        )
        assertEquals(
            listOf(HostState.DRAINING, HostState.PARKED, HostState.RECOVERING),
            host.controller.transitions.map { it.to }.drop(1),
        )
        assertEquals("exactly one epoch close", 1, wal.closeCalls)
        assertEquals("no durable byte is added or dropped", appendedBefore, wal.appendedBodies.size)

        platform.engine.setState(RUNNING)

        assertEquals(HostState.RUNNING, host.controller.state)
        assertEquals(Admission.OPEN, host.controller.admission)
        assertNoIllegalTransition()
    }

    @Test
    fun aSecondBackgroundWhileDrainingDoesNotCloseASecondEpoch() {
        val platform = FakePlatform()
        val closeGate = CompletableDeferred<Unit>()
        val wal = FakeHostWal(closeGate = closeGate)
        val host = newHost(platform, wal)
        host.start()
        platform.engine.setState(RUNNING)
        platform.emit(ScenePhase(ScenePhase.Phase.BACKGROUND))
        assertEquals(HostState.DRAINING, host.controller.state)

        // A duplicated background frame while the first drain runs is rejected by
        // the machine and must not arm a second close.
        platform.emit(ScenePhase(ScenePhase.Phase.BACKGROUND))
        assertEquals(1, wal.closeCalls)

        closeGate.complete(Unit)
        assertEquals(HostState.PARKED, host.controller.state)
        assertEquals("one close per Draining entry", 1, wal.closeCalls)
    }

    @Test
    fun aForegroundReturnFromFailedDoesNotInventAnExit() {
        val platform = FakePlatform()
        val host = newHost(platform, FakeHostWal())
        host.start()
        platform.engine.setState(RUNNING)
        platform.emit(ScenePhase(ScenePhase.Phase.BACKGROUND))

        // A WAL failure is the one condition with no automatic exit (§1).
        host.controller.handle(
            ControllerSignal.FailureRaised(reason = ControllerFailure.WAL_CORRUPT, detail = null),
            atMillis = platform.monotonicMillis(),
        )
        platform.emit(ScenePhase(ScenePhase.Phase.ACTIVE))

        assertEquals("Failed has no automatic exit (budgets.md §1)", HostState.FAILED, host.controller.state)
        assertEquals(Admission.CLOSED, host.controller.admission)
    }

    @Test
    fun aForegroundReturnInRecoveringRestartsTheWorkerSoTheLeaseCanOpen() {
        val platform = FakePlatform()
        val host = newHost(platform, FakeHostWal())
        // The boot mapping for a new workspace is Recovering, and the fake engine
        // does not move on its own: this is a host whose worker never came up.
        host.start()
        assertEquals(HostState.RECOVERING, host.controller.state)
        assertEquals(Admission.CLOSED, host.controller.admission)

        // A background switch here is not a row (§2 has no Recovering -> Draining)
        // and must leave the host exactly where it was.
        platform.emit(ScenePhase(ScenePhase.Phase.BACKGROUND))
        assertEquals(HostState.RECOVERING, host.controller.state)

        platform.emit(ScenePhase(ScenePhase.Phase.ACTIVE))
        assertEquals("the return re-starts the worker the host is waiting for", 2, platform.engine.startCount)

        platform.engine.setState(RUNNING)
        assertEquals(HostState.RUNNING, host.controller.state)
        assertEquals(Admission.OPEN, host.controller.admission)
    }

    private fun assertNoIllegalTransition() {
        val illegal = logger.messages.filter { it.contains("ILLEGAL_TRANSITION") }
        assertTrue(
            "a background/foreground round trip must not be refused: $illegal",
            illegal.isEmpty(),
        )
    }

    private fun newHost(platform: FakePlatform, wal: HostWal): DefaultPhoneDshHost =
        DefaultPhoneDshHost(
            engine = platform.engine,
            controller = ControllerStateMachine.boot(persistedState = null),
            clock = platform,
            signals = platform,
            notifier = platform,
            wal = wal,
            scope = CoroutineScope(Dispatchers.Unconfined),
            logger = logger,
        )

    private companion object {
        /** A live origin; the port is what channel.md §1 would carry. */
        val RUNNING: EngineHostState = EngineHostState.Running("http://127.0.0.1:41234", 41234)
    }
}
