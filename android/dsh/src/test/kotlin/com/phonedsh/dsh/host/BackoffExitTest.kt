// phone-dsh — :dsh unit test: the Backoff exit and the boot-side retry (P15).
// SPDX-License-Identifier: MIT
//
// The defect these tests pin down: `networkPath(unsatisfied)` moved the host to
// `Backoff`, nothing performed the row's "start the retry schedule" action, and
// `RetryAfterElapsed` / `RetryProbeSucceeded` had no producer in any main source
// set. The network came back, NWPath reported `satisfied`, the controller
// recorded it as an observation, and the guard's third conjunct stayed false
// forever: `Backoff` was terminal and admission never reopened (P15 reproduced
// it on emulator API 35, 2026-11-01).
//
// What is asserted here, and nothing weaker:
//   * a network loss parks the host in `Backoff`, and a restored path returns it
//     to `Running` through the written row — not through a loosened guard;
//   * the 429/5xx entry reaches `Running` too (the same row, the other entry);
//   * a failed probe keeps the host in `Backoff`: the lane feeds nothing, so the
//     guard is never faked;
//   * a host that boots from a persisted `Backoff` has an exit in this process,
//     because the boot mapping arms the same schedule;
//   * `ILLEGAL_TRANSITION` never appears for these signals.
//
// Allocation: pure JVM, `FakePlatform` for Clock/LifecycleSignals/Notifier/engine
// and a real `HostStateStore` on a temporary directory.

package com.phonedsh.dsh.host

import com.phonedsh.controller.Admission
import com.phonedsh.controller.ControllerSignal
import com.phonedsh.controller.ControllerStateMachine
import com.phonedsh.controller.HostState
import com.phonedsh.platform.EngineHostState
import com.phonedsh.platform.NetworkPath
import com.phonedsh.platform.testing.FakePlatform
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class BackoffExitTest {
    @get:Rule
    val temporary = TemporaryFolder()

    private val logger = RecordingHostLog()

    @Test
    fun aLostNetworkParksInBackoffAndARestoredPathReturnsToRunning() {
        val platform = FakePlatform()
        val host = newHost(platform, ControllerStateMachine.boot(persistedState = null))
        host.start()
        platform.engine.setState(RUNNING)
        assertEquals(HostState.RUNNING, host.controller.state)

        platform.emit(NetworkPath(available = false, expensive = false))

        assertEquals(HostState.BACKOFF, host.controller.state)
        assertEquals(Admission.CLOSED, host.controller.admission)
        assertTrue(
            "the entry's actions include the retry schedule",
            host.controller.transitions.last().effects.contains(
                com.phonedsh.controller.ControllerEffect.START_RETRY_SCHEDULE,
            ),
        )

        // The network comes back. Before P15 this was the last line the host ever
        // recorded; now the schedule elapses, the probe runs and the table takes
        // `Backoff -> Running`.
        platform.emit(NetworkPath(available = true, expensive = false))

        runBlocking {
            withTimeout(5_000) { host.state.first { it == HostState.RUNNING } }
        }
        assertEquals(HostState.RUNNING, host.controller.state)
        assertEquals(Admission.OPEN, host.controller.admission)
        assertEquals(
            listOf(HostState.BACKOFF, HostState.RUNNING),
            host.controller.transitions.map { it.to }.drop(1),
        )
        assertNoIllegalTransition()
    }

    @Test
    fun theUpstreamEntryReachesRunningThroughTheSameRow() {
        val platform = FakePlatform()
        val host = newHost(platform, ControllerStateMachine.boot(persistedState = null))
        host.start()
        platform.engine.setState(RUNNING)

        // The 429 arm of `Running -> Backoff`. Nothing in this composition
        // produces it yet (the model edge is another lane's), so the signal is
        // fed through the facade's one entry point.
        host.handle(ControllerSignal.UpstreamUnavailable(statusCode = 429))
        assertEquals(HostState.BACKOFF, host.controller.state)

        platform.emit(NetworkPath(available = true, expensive = false))

        runBlocking {
            withTimeout(5_000) { host.state.first { it == HostState.RUNNING } }
        }
        assertEquals(Admission.OPEN, host.controller.admission)
        assertEquals(
            listOf(HostState.BACKOFF, HostState.RUNNING),
            host.controller.transitions.map { it.to }.drop(1),
        )
        assertNoIllegalTransition()
    }

    @Test
    fun aFailedProbeKeepsTheHostInBackoff() {
        val platform = FakePlatform()
        val host = newHost(
            platform,
            ControllerStateMachine.boot(persistedState = null),
            probe = RetryProbe { false },
        )
        host.start()
        platform.engine.setState(RUNNING)
        platform.emit(NetworkPath(available = false, expensive = false))
        platform.emit(NetworkPath(available = true, expensive = false))

        // Enough windows to prove the schedule really runs and still refuses to
        // open admission on a probe that failed.
        Thread.sleep(250L)

        assertEquals("a failed probe is not an exit", HostState.BACKOFF, host.controller.state)
        assertEquals(Admission.CLOSED, host.controller.admission)
        assertEquals(
            "nothing but the entry was recorded",
            listOf(HostState.BACKOFF),
            host.controller.transitions.map { it.to }.drop(1),
        )
        assertTrue(
            "the lane says why it stays: ${logger.messages}",
            logger.messages.any { it.contains("retry probe failed") },
        )
        assertNoIllegalTransition()
    }

    @Test
    fun aHostBootedIntoAPersistedBackoffCanLeaveIt() {
        val platform = FakePlatform()
        // A previous process died while in Backoff; its record still names it and
        // its window is already over.
        val store = newStore(platform)
        val dead = ControllerStateMachine.boot(persistedState = HostState.BACKOFF)
        assertTrue(store.save(dead, backoffUntilMillis = platform.nowMillis() - 1_000L))

        val controller = ControllerStateMachine.boot(persistedState = store.load()?.state)
        assertEquals(HostState.BACKOFF, controller.state)
        assertEquals(
            com.phonedsh.controller.BootDisposition.CRASH_RECOVERY,
            controller.bootDisposition,
        )

        val host = newHost(platform, controller, store = store)
        host.start()
        // The first frame of the subscription carries the current path, which is
        // what the `Backoff` guard needs; the boot mapping armed the schedule.
        platform.emit(NetworkPath(available = true, expensive = false))

        runBlocking {
            withTimeout(5_000) { host.state.first { it == HostState.RUNNING } }
        }
        assertEquals(Admission.OPEN, host.controller.admission)
        assertNoIllegalTransition()
    }

    @Test
    fun everyTransitionPersistsTheHostState() {
        val platform = FakePlatform()
        val store = newStore(platform)
        val host = newHost(platform, ControllerStateMachine.boot(persistedState = null), store = store)
        host.start()
        assertEquals(
            "the boot mapping persists too, so a second boot has a record",
            HostState.RECOVERING,
            store.load()?.state,
        )

        platform.engine.setState(RUNNING)
        assertEquals(HostState.RUNNING, store.load()?.state)

        platform.emit(NetworkPath(available = false, expensive = false))
        val backoff = store.load()
        assertEquals(HostState.BACKOFF, backoff?.state)
        assertTrue(
            "a Backoff record carries the retry deadline, was ${backoff?.backoffUntilMillis}",
            (backoff?.backoffUntilMillis ?: 0L) > 0L,
        )

        platform.emit(NetworkPath(available = true, expensive = false))
        runBlocking { withTimeout(5_000) { host.state.first { it == HostState.RUNNING } } }
        // The probe runs on the lane's coroutine, and `dispatch` publishes the
        // new state before it performs the row's `PERSIST_HOST_STATE` effect, so
        // the file is asserted through a bounded poll rather than a race.
        awaitPersisted(store, HostState.RUNNING)
        assertNull("a non-Backoff record carries no retry deadline", store.load()?.backoffUntilMillis)
    }

    @Test
    fun aKilledParkedHostBootsBackIntoParkedResume() {
        val platform = FakePlatform()
        val store = newStore(platform)
        val parked = ControllerStateMachine.boot(persistedState = HostState.PARKED)
        assertEquals(HostState.PARKED, parked.state)
        assertTrue(store.save(parked))

        val restored = ControllerStateMachine.boot(persistedState = store.load()?.state)

        assertEquals(HostState.PARKED, restored.state)
        assertEquals(
            com.phonedsh.controller.BootDisposition.PARKED_RESUME,
            restored.bootDisposition,
        )
        assertEquals("persisted_parked", restored.bootReason)
    }

    /** Waits (bounded) until `host-state.json` names [state]. */
    private fun awaitPersisted(store: HostStateStore, state: HostState) {
        val deadline = System.nanoTime() + 5_000L * 1_000_000L
        while (System.nanoTime() < deadline) {
            if (store.load()?.state == state) return
            Thread.sleep(5L)
        }
        fail("host-state.json never said $state; it says ${store.load()?.state}")
    }

    private fun assertNoIllegalTransition() {
        val illegal = logger.messages.filter { it.contains("ILLEGAL_TRANSITION") }
        assertTrue("no Backoff round trip may be refused: $illegal", illegal.isEmpty())
    }

    private fun newStore(platform: FakePlatform): HostStateStore = HostStateStore(
        file = temporary.newFolder().toPath().resolve(HostStateStore.FILE_NAME),
        durability = platform,
        clock = platform,
        logger = logger,
    )

    private fun newHost(
        platform: FakePlatform,
        controller: ControllerStateMachine,
        probe: RetryProbe = RetryProbe.leaseCheck(LeaseProbe.LocalOnly),
        store: HostStateStore? = null,
    ): DefaultPhoneDshHost = DefaultPhoneDshHost(
        engine = platform.engine,
        controller = controller,
        clock = platform,
        signals = platform,
        notifier = platform,
        scope = CoroutineScope(Dispatchers.Unconfined),
        logger = logger,
        retryProbe = probe,
        // 1 ms windows: the test asserts the row, not the schedule's rhythm.
        retryPolicy = RetryPolicy(
            initialDelayMillis = 1L,
            multiplier = 2,
            maximumDelayMillis = 4L,
            jitterFraction = 0.0,
        ),
        stateStore = store,
    )

    private companion object {
        /** A live origin; the port is what channel.md §1 would carry. */
        val RUNNING: EngineHostState = EngineHostState.Running("http://127.0.0.1:41234", 41234)
    }
}
