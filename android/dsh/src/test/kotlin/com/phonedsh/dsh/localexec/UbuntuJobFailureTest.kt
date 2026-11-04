// phone-dsh — :dsh unit test: the five failure conditions bridge.md §12.6 names.
// SPDX-License-Identifier: MIT
//
// The acceptance runs prove the happy paths; these prove that the *un*happy ones
// are typed, that they reuse the vocabulary `spec/v1/` already has, and that the
// fail-closed ones never reach an adapter. The last claim is the one worth a test
// of its own: an implementation that seals, fails, and starts the command anyway
// would look identical from the outside until the day it matters.

package com.phonedsh.dsh.localexec

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class UbuntuJobFailureTest {

    @Test
    fun anEnvironmentWithNoAdapterFailsTheJobWithoutGuessing() {
        val clock = TestClock()
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
        TempDir().use { temp ->
            // Nothing is registered for a GitHub-hosted environment: this device has
            // no such capability, and that must be a terminal job, not a bridge error.
            val lane = newLane(scope, clock, temp)
            try {
                runBlocking {
                    val answer = lane.submit(
                        UbuntuExecRequest(env = "gh-actions:ubuntu-latest", argv = listOf("make")),
                    )
                    assertTrue("an accepted request always has a record: $answer", answer is UbuntuSubmit.Accepted)
                    val job = (answer as UbuntuSubmit.Accepted).job
                    val done = awaitTerminal(lane, job.jobId)
                    assertEquals(UbuntuJobState.FAILED, done.state)
                    assertEquals(UbuntuJobFailure.PROVIDER_UNAVAILABLE, done.failure!!.code)
                    assertEquals(UbuntuOutcome.NOT_STARTED, done.failure!!.outcome)
                    assertEquals(UbuntuCause.ENV_UNAVAILABLE, done.failure!!.cause)
                    assertFalse("no retry can create an adapter", done.failure!!.retryable)
                    assertNull(done.authorityExited)
                    assertFalse(done.egress)
                }
            } finally {
                scope.cancel()
            }
        }
    }

    @Test
    fun aSealThatWillNotSealNeverContactsTheAdapter() {
        val clock = TestClock()
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
        TempDir().use { temp ->
            val adapter = MockUbuntuAdapter(clock = clock, delayMillis = 80)
            val seal = FakeSeal(sealFails = true)
            val lane = newLane(scope, clock, temp, adapters = listOf(adapter), seal = seal)
            try {
                runBlocking {
                    val job = (lane.submit(UbuntuExecRequest(adapter.env, listOf("make"))) as UbuntuSubmit.Accepted).job
                    val done = awaitTerminal(lane, job.jobId)
                    assertEquals(UbuntuJobState.FAILED, done.state)
                    assertEquals(UbuntuCause.SEAL_FAILED, done.failure!!.cause)
                    assertEquals(UbuntuOutcome.NOT_STARTED, done.failure!!.outcome)
                    assertEquals(UbuntuSealState.FAILED, done.seal)
                    assertEquals("chmod_failed", done.sealReason)
                    // §12.3 row 5: fail-closed means the environment never heard of it.
                    assertEquals(0, adapter.startCount)
                    assertEquals(0, adapter.stopCount)
                }
            } finally {
                scope.cancel()
            }
        }
    }

    @Test
    fun aMemoryPrecheckBelowTheJobsBudgetRefusesToStart() {
        val clock = TestClock()
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
        TempDir().use { temp ->
            val adapter = MockUbuntuAdapter(
                clock = clock,
                delayMillis = 80,
                // budgets.md §4's 8 GiB app-process row.
                rssLimitBytes = 230L * UbuntuJobLimits.MIB,
            )
            val lane = newLane(
                scope,
                clock,
                temp,
                adapters = listOf(adapter),
                availableMemoryBytes = { 100L * UbuntuJobLimits.MIB },
            )
            try {
                runBlocking {
                    val job = (lane.submit(UbuntuExecRequest(adapter.env, listOf("gcc", "-O2"))) as UbuntuSubmit.Accepted).job
                    val done = awaitTerminal(lane, job.jobId)
                    assertEquals(UbuntuJobState.FAILED, done.state)
                    assertEquals(UbuntuCause.MEMORY_INSUFFICIENT, done.failure!!.cause)
                    assertEquals(UbuntuOutcome.NOT_STARTED, done.failure!!.outcome)
                    assertTrue("the memory may come back", done.failure!!.retryable)
                    assertEquals(0, adapter.startCount)
                }
            } finally {
                scope.cancel()
            }
        }
    }

    @Test
    fun aSnapshotBiggerThanTheStagingBucketIsRefusedNotTruncated() {
        val clock = TestClock()
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
        TempDir().use { temp ->
            val adapter = MockUbuntuAdapter(clock = clock, delayMillis = 80)
            // The 8 GiB row's `tmp` bucket is 50 MB; the input is 60 MB.
            val lane = newLane(
                scope,
                clock,
                temp,
                adapters = listOf(adapter),
                snapshotBytes = { 60L * UbuntuJobLimits.MIB },
            )
            try {
                runBlocking {
                    val job = (lane.submit(UbuntuExecRequest(adapter.env, listOf("make"))) as UbuntuSubmit.Accepted).job
                    val done = awaitTerminal(lane, job.jobId)
                    assertEquals(UbuntuCause.SNAPSHOT_TOO_LARGE, done.failure!!.cause)
                    assertEquals(UbuntuOutcome.NOT_STARTED, done.failure!!.outcome)
                    assertFalse(done.failure!!.retryable)
                    assertEquals(0, adapter.startCount)
                }
            } finally {
                scope.cancel()
            }
        }
    }

    @Test
    fun aDrainWhoseAdapterNeverAcknowledgesIsUnknownNotCancelled() {
        val clock = TestClock()
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
        TempDir().use { temp ->
            val adapter = MockUbuntuAdapter(
                clock = clock,
                delayMillis = 30_000,
                stopsCleanly = false,
            )
            val lane = newLane(scope, clock, temp, adapters = listOf(adapter))
            try {
                runBlocking {
                    val job = (lane.submit(UbuntuExecRequest(adapter.env, listOf("sleep", "30"))) as UbuntuSubmit.Accepted).job
                    awaitState(lane, job.jobId) { it.state == UbuntuJobState.REMOTE }
                    lane.beginDrain()
                    val finished = lane.finishDrain(deadlineMs = 300)
                    val done = finished.first { it.jobId == job.jobId }
                    // The host cannot claim it stopped a command it cannot observe.
                    assertEquals(UbuntuJobState.FAILED, done.state)
                    assertEquals(UbuntuJobFailure.PROVIDER_TIMEOUT, done.failure!!.code)
                    assertEquals(UbuntuOutcome.UNKNOWN, done.failure!!.outcome)
                    assertEquals(UbuntuCause.DRAIN_DEADLINE, done.failure!!.cause)
                    assertFalse(done.failure!!.retryable)
                    assertNull("no exit was ever observed", done.exitCode)
                    // The window is still closed on the way out.
                    assertEquals(UbuntuSealState.RESTORED, done.seal)
                }
            } finally {
                scope.cancel()
            }
        }
    }

    @Test
    fun aClosedAdmissionIsReportedAsForegroundRequiredNotAsASealFailure() {
        val clock = TestClock()
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
        TempDir().use { temp ->
            val adapter = MockUbuntuAdapter(clock = clock, delayMillis = 80)
            val lane = newLane(
                scope,
                clock,
                temp,
                adapters = listOf(adapter),
                admissionOpen = { false },
            )
            try {
                runBlocking {
                    val job = (lane.submit(UbuntuExecRequest(adapter.env, listOf("make"))) as UbuntuSubmit.Accepted).job
                    val done = awaitTerminal(lane, job.jobId)
                    assertEquals(UbuntuJobState.FAILED, done.state)
                    assertEquals(UbuntuJobFailure.ADMISSION_CLOSED, done.failure!!.code)
                    assertEquals(UbuntuOutcome.NOT_STARTED, done.failure!!.outcome)
                    assertTrue(done.failure!!.foregroundRequired)
                    assertTrue(done.failure!!.retryable)
                    assertEquals(0, adapter.startCount)
                }
            } finally {
                scope.cancel()
            }
        }
    }

    @Test
    fun aManifestOverTheBoundIsRefusedRatherThanTruncated() {
        val clock = TestClock()
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
        TempDir().use { temp ->
            val adapter = MockUbuntuAdapter(
                clock = clock,
                delayMillis = 80,
                manifest = (1..33).map { UbuntuArtifactLine("f$it.txt", 1) },
            )
            val lane = newLane(scope, clock, temp, adapters = listOf(adapter))
            try {
                runBlocking {
                    val job = (lane.submit(UbuntuExecRequest(adapter.env, listOf("make"))) as UbuntuSubmit.Accepted).job
                    val done = awaitTerminal(lane, job.jobId)
                    assertEquals(UbuntuJobState.FAILED, done.state)
                    assertEquals(UbuntuCause.ADAPTER_FAILED, done.failure!!.cause)
                    assertEquals(UbuntuOutcome.UNKNOWN, done.failure!!.outcome)
                    assertTrue("nothing may be truncated into the record", done.artifacts.isEmpty())
                }
            } finally {
                scope.cancel()
            }
        }
    }

    @Test
    fun aSecondJobWhileOneIsInFlightIsBusyAndCreatesNoRecord() {
        val clock = TestClock()
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
        TempDir().use { temp ->
            val adapter = MockUbuntuAdapter(clock = clock, delayMillis = 10_000)
            val lane = newLane(scope, clock, temp, adapters = listOf(adapter))
            try {
                runBlocking {
                    val first = lane.submit(UbuntuExecRequest(adapter.env, listOf("sleep", "10")))
                    assertTrue(first is UbuntuSubmit.Accepted)
                    val second = lane.submit(UbuntuExecRequest(adapter.env, listOf("sleep", "10")))
                    assertTrue("$second", second is UbuntuSubmit.Refused)
                    assertEquals(UbuntuJobLane.BRIDGE_BUSY, (second as UbuntuSubmit.Refused).bridgeCode)
                    // One non-terminal job per workspace; the refusal recorded nothing.
                    assertEquals(1, lane.jobs().size)
                }
            } finally {
                scope.cancel()
            }
        }
    }

    @Test
    fun aFailedRestoreKeepsTheExitCodeAndSaysTheWorkspaceIsUnprotected() {
        val clock = TestClock()
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
        TempDir().use { temp ->
            val adapter = MockUbuntuAdapter(
                clock = clock,
                delayMillis = 80,
                manifest = listOf(UbuntuArtifactLine("tiny.txt", 12)),
            )
            val lane = newLane(
                scope,
                clock,
                temp,
                adapters = listOf(adapter),
                seal = FakeSeal(restoreFails = true),
            )
            try {
                runBlocking {
                    val job = (lane.submit(UbuntuExecRequest(adapter.env, listOf("make"))) as UbuntuSubmit.Accepted).job
                    val done = awaitTerminal(lane, job.jobId)
                    // The command's outcome is a fact and does not change; the seal
                    // is a separate question and answers it separately (§12.8).
                    assertEquals(UbuntuJobState.SUCCEEDED, done.state)
                    assertEquals(0, done.exitCode)
                    assertEquals(UbuntuSealState.FAILED, done.seal)
                    assertEquals("restore_failed", done.sealReason)
                    assertNull("the window never closed, so the tripwire proves nothing", done.internalAccessObserved)
                }
            } finally {
                scope.cancel()
            }
        }
    }
}
