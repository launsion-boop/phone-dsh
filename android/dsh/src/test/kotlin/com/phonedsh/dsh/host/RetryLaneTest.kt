// phone-dsh — :dsh unit test: the retry lane's own contract (P15).
// SPDX-License-Identifier: MIT
//
// The facade test (`BackoffExitTest`) proves the round trip; this file proves
// the three properties of the lane itself that the round trip depends on:
//   * the lane feeds `RetryAfterElapsed` **before** it probes — the machine's
//     guard is a conjunction and a probe that arrived first would be a
//     GUARD_FAILED rejection;
//   * the lane does not probe while the network path is unsatisfied (the guard
//     needs both facts; probing anyway would only manufacture a rejection);
//   * a failed probe feeds nothing and proposes another window — "one probe
//     succeeded" is not made true by a probe that failed.
//
// Time is controlled by the injected `sleepFor`, so no assertion depends on a
// wall clock; only the scheduling uses a real dispatcher, with `withTimeout`
// bounds so a broken lane fails fast instead of hanging the build.

package com.phonedsh.dsh.host

import com.phonedsh.platform.testing.FakePlatform
import java.util.Collections
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class RetryLaneTest {
    private val logger = RecordingHostLog()

    @Test
    fun theWindowElapsesBeforeTheProbeAndThePathIsRequiredBeforeIt() {
        val clock = FakePlatform()
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
        val events = Collections.synchronizedList(mutableListOf<String>())
        val windowStarted = CompletableDeferred<Long>()
        val windowGate = CompletableDeferred<Unit>()
        val succeeded = CompletableDeferred<Unit>()

        val lane = RetryLane(
            scope = scope,
            clock = clock,
            probe = RetryProbe {
                events += "probe"
                true
            },
            onRetryAfterElapsed = { events += "retryAfter(attempt=${it.attempt})" },
            onProbeSucceeded = {
                events += "probeSucceeded(attempt=${it.attempt})"
                succeeded.complete(Unit)
            },
            policy = RetryPolicy(initialDelayMillis = 40L, jitterFraction = 0.0),
            logger = logger,
            sleepFor = {
                windowStarted.complete(it)
                windowGate.await()
            },
        )
        try {
            runBlocking {
                lane.arm(RetryLane.Entry.NETWORK_PATH)
                val window = withTimeout(5_000) { windowStarted.await() }
                assertEquals("the first window is the policy's initial delay", 40L, window)

                // The window has not elapsed yet: nothing is fed.
                assertTrue(lane.isWaiting)
                assertEquals(emptyList<String>(), events.toList())

                windowGate.complete(Unit)

                // The window elapsed and the path was never reported satisfied:
                // `RetryAfterElapsed` is fed, and the probe must wait.
                withTimeout(5_000) {
                    while (events.isEmpty()) delay(5)
                }
                assertEquals(listOf("retryAfter(attempt=1)"), events.toList())
                withTimeout(5_000) {
                    while (!lane.isWaitingForPath) delay(5)
                }
                assertEquals("no probe before the path is satisfied", listOf("retryAfter(attempt=1)"), events.toList())

                lane.onNetworkPath(true)

                withTimeout(5_000) { succeeded.await() }
                assertEquals(
                    listOf(
                        "retryAfter(attempt=1)",
                        "probe",
                        "probeSucceeded(attempt=1)",
                    ),
                    events.toList(),
                )
            }
        } finally {
            scope.cancel()
            clock.close()
        }
    }

    @Test
    fun aFailedProbeFeedsNoSignalAndProposesTheNextWindow() {
        val clock = FakePlatform()
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
        val windows = Collections.synchronizedList(mutableListOf<Long>())
        val secondWindow = CompletableDeferred<Unit>()
        var probes = 0
        var successes = 0
        var afterElapsed = 0

        val lane = RetryLane(
            scope = scope,
            clock = clock,
            probe = RetryProbe {
                probes += 1
                false
            },
            onRetryAfterElapsed = { afterElapsed += 1 },
            onProbeSucceeded = { successes += 1 },
            policy = RetryPolicy(
                initialDelayMillis = 10L,
                multiplier = 2,
                maximumDelayMillis = 40L,
                jitterFraction = 0.0,
            ),
            logger = logger,
            sleepFor = { millis ->
                windows += millis
                if (windows.size >= 2) secondWindow.complete(Unit)
            },
        )
        try {
            runBlocking {
                // `arm` starts a new entry, so the path observation follows it:
                // one window of 10 ms, then 20 ms (the schedule grows).
                lane.arm(RetryLane.Entry.UPSTREAM)
                lane.onNetworkPath(true)
                withTimeout(5_000) { secondWindow.await() }
                // Two windows means one failed probe and one reschedule.
                withTimeout(5_000) {
                    while (probes < 2) delay(5)
                }
                assertEquals("a failed probe is never reported as a success", 0, successes)
                assertTrue("RetryAfterElapsed was fed per window", afterElapsed >= 2)
                assertEquals(
                    "the schedule grows: 10 ms then 20 ms, then the 40 ms cap",
                    listOf(10L, 20L),
                    windows.toList().take(2),
                )
                assertTrue(
                    "attempts after the cap stay at maximumDelayMillis: ${windows.toList()}",
                    windows.toList().drop(2).all { it == 40L },
                )
            }
        } finally {
            lane.release()
            scope.cancel()
            clock.close()
        }
    }

    @Test
    fun aRepeatedArmDoesNotStartASecondSchedule() {
        val clock = FakePlatform()
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
        val windows = Collections.synchronizedList(mutableListOf<Long>())
        val firstWindow = CompletableDeferred<Unit>()

        val lane = RetryLane(
            scope = scope,
            clock = clock,
            probe = RetryProbe { false },
            onRetryAfterElapsed = {},
            onProbeSucceeded = {},
            policy = RetryPolicy(initialDelayMillis = 30L, jitterFraction = 0.0),
            logger = logger,
            sleepFor = { millis ->
                windows += millis
                firstWindow.complete(Unit)
                // Returns at once: the loop then feeds `RetryAfterElapsed` and
                // suspends waiting for a path, which is where the second arm
                // calls must find it.
            },
        )
        try {
            runBlocking {
                lane.arm(RetryLane.Entry.NETWORK_PATH)
                withTimeout(5_000) { firstWindow.await() }
                withTimeout(5_000) {
                    while (!lane.isWaitingForPath) delay(5)
                }
                lane.arm(RetryLane.Entry.NETWORK_PATH)
                lane.arm(RetryLane.Entry.UPSTREAM)
                assertEquals("one schedule per entry", 1, windows.size)
                assertTrue(lane.isWaiting)
            }
        } finally {
            lane.release()
            assertFalse("release ends the schedule", lane.isWaiting)
            scope.cancel()
            clock.close()
        }
    }

    @Test
    fun releaseStopsTheScheduleSoNoStaleSignalIsFed() {
        val clock = FakePlatform()
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
        val windowStarted = CompletableDeferred<Unit>()
        val windowGate = CompletableDeferred<Unit>()
        val events = Collections.synchronizedList(mutableListOf<String>())

        val lane = RetryLane(
            scope = scope,
            clock = clock,
            probe = RetryProbe {
                events += "probe"
                true
            },
            onRetryAfterElapsed = { events += "retryAfter" },
            onProbeSucceeded = { events += "probeSucceeded" },
            policy = RetryPolicy(initialDelayMillis = 10L, jitterFraction = 0.0),
            logger = logger,
            sleepFor = {
                windowStarted.complete(Unit)
                windowGate.await()
            },
        )
        try {
            runBlocking {
                lane.arm(RetryLane.Entry.NETWORK_PATH)
                withTimeout(5_000) { windowStarted.await() }
                lane.release()
                lane.onNetworkPath(true)
                windowGate.complete(Unit)
                // The cancelled schedule must not feed a window it no longer owns.
                Thread.sleep(120L)
                assertEquals(emptyList<String>(), events.toList())
                assertFalse(lane.isWaiting)
            }
        } finally {
            scope.cancel()
            clock.close()
        }
    }
}
