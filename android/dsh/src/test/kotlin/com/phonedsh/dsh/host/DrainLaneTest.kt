// phone-dsh — :dsh unit test: the drain lane's own contract (P10).
// SPDX-License-Identifier: MIT
//
// The facade tests (`DrainExitTest`) prove the round trip; this file proves the
// two properties of the lane itself that the round trip depends on:
//   * the 20 s deadline ends the *wait* and never cancels the epoch close — a
//     torn epoch is worse than a late `Parked` (plan §7.10);
//   * one `Draining` entry closes exactly one epoch.
//
// Real time is used (a 60 ms deadline) because the bound is a wall-clock
// duration by definition; nothing else in the test is timing-dependent.

package com.phonedsh.dsh.host

import com.phonedsh.platform.testing.FakePlatform
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class DrainLaneTest {
    private val logger = RecordingHostLog()

    @Test
    fun theDeadlineEndsTheWaitButNeverTheEpochClose() {
        val clock = FakePlatform()
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
        val closeGate = CompletableDeferred<Unit>()
        val closedAfterGate = CompletableDeferred<Unit>()
        val deadlineFed = CompletableDeferred<Unit>()
        val drained = CompletableDeferred<DrainLane.DrainOutcome>()
        var closes = 0
        var workerStops = 0

        val lane = DrainLane(
            scope = scope,
            clock = clock,
            closeEpoch = {
                closes += 1
                closeGate.await()
                closedAfterGate.complete(Unit)
                41L
            },
            stopWorker = { workerStops += 1 },
            awaitWorkerStopped = { true },
            onDeadlineElapsed = { deadlineFed.complete(Unit) },
            onDrained = { drained.complete(it) },
            logger = logger,
        )
        try {
            runBlocking {
                lane.arm(clock.monotonicMillis() + 60L)
                val outcome = withTimeout(5_000) { drained.await() }

                assertEquals(DrainLane.Reason.DEADLINE, outcome.reason)
                // The deadline signal is fed so the controller records
                // FORCE_DRAIN_DEADLINE / CANCEL_IN_FLIGHT_REQUESTS itself.
                withTimeout(5_000) { deadlineFed.await() }
                assertEquals("the worker is stopped even on the deadline path", 1, workerStops)
                assertEquals(null, outcome.durableUpto)

                // The close is still inside the seam: unbounded, uncancelled.
                assertFalse("the deadline must not cancel the close", closedAfterGate.isCompleted)
                closeGate.complete(Unit)
                withTimeout(5_000) { closedAfterGate.await() }
                assertEquals(1, closes)
            }
        } finally {
            scope.cancel()
            clock.close()
        }
    }

    @Test
    fun oneDrainingEntryClosesOneEpoch() {
        val clock = FakePlatform()
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
        val closeGate = CompletableDeferred<Unit>()
        val drained = CompletableDeferred<DrainLane.DrainOutcome>()
        var closes = 0

        val lane = DrainLane(
            scope = scope,
            clock = clock,
            closeEpoch = {
                closes += 1
                closeGate.await()
                7L
            },
            stopWorker = {},
            awaitWorkerStopped = { true },
            onDeadlineElapsed = {},
            onDrained = { drained.complete(it) },
            logger = logger,
        )
        try {
            runBlocking {
                lane.arm(clock.monotonicMillis() + 30_000L)
                // A duplicated effect while the same drain runs must not arm a
                // second close.
                lane.arm(clock.monotonicMillis() + 30_000L)
                assertTrue(lane.isDraining)
                assertEquals(0, closes)
                closeGate.complete(Unit)
                val outcome = withTimeout(5_000) { drained.await() }
                assertEquals(DrainLane.Reason.CLOSED, outcome.reason)
                assertEquals(7L, outcome.durableUpto)
                assertEquals(1, closes)
                assertTrue("the worker was stopped by the drain", outcome.workerStopped)
            }
        } finally {
            scope.cancel()
            clock.close()
        }
    }

    @Test
    fun aForegroundReturnDoesNotCancelTheCloseAndReportsNoDrainInFlightAfterwards() {
        val clock = FakePlatform()
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
        val closeGate = CompletableDeferred<Unit>()
        val drained = CompletableDeferred<DrainLane.DrainOutcome>()
        var closes = 0

        val lane = DrainLane(
            scope = scope,
            clock = clock,
            closeEpoch = {
                closes += 1
                closeGate.await()
                5L
            },
            stopWorker = {},
            awaitWorkerStopped = { true },
            onDeadlineElapsed = {},
            onDrained = { drained.complete(it) },
            logger = logger,
        )
        try {
            runBlocking {
                lane.arm(clock.monotonicMillis() + 30_000L)
                assertTrue(lane.foregroundReturn())
                // Still draining: the close has to return before the host parks.
                assertTrue(lane.isDraining)
                closeGate.complete(Unit)
                val outcome = withTimeout(5_000) { drained.await() }
                assertEquals(DrainLane.Reason.CLOSED, outcome.reason)
                assertEquals(1, closes)
                assertFalse(lane.isDraining)
                // Nothing is in flight any more, so a later return is the
                // caller's to drive (it is already Parked).
                assertFalse(lane.foregroundReturn())
            }
        } finally {
            scope.cancel()
            clock.close()
        }
    }
}
