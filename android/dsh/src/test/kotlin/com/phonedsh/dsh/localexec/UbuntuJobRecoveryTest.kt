// phone-dsh — :dsh unit test: acceptance run 4, a killed process.
// SPDX-License-Identifier: MIT
//
// ---- what "the JobRef is recoverable" has to mean ---------------------------
// Not "the file is still there": a JSON file that says `remote` and can never be
// advanced is not a recovered job, it is a stuck one. The claim bridge.md §12.3
// makes is stronger and it is the same claim budgets.md §3 makes about the host's
// own `Remote`: a job found in `remote` **stays** `remote`, polling resumes
// against the same adapter (the environment is the authority and answers per
// `jobId`), and the job still reaches a terminal state with its audit intact.
//
// ---- what a kill leaves behind ---------------------------------------------
// The first lane is cancelled, which is as close to `SIGKILL` as a JVM test gets:
// no restore, no terminal write, the last durable record is `remote`. The seal
// fake still holds the job, exactly as `chmod 000` would still be on disk, and the
// second lane's `repair()` is what stands in for the boot's mode repair.
//
// ---- the audit values the test pins ----------------------------------------
// `env`, `argvDigest`, `createdAtMs`, `egress: false` and
// `authorityExited: "worker-vfs"` are the testimony §12.5 refuses to let a later
// reader rewrite. All five are compared before and after the kill.

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

class UbuntuJobRecoveryTest {

    @Test
    fun aJobKilledInRemoteResumesFromTheAdapterAndKeepsItsAudit() {
        TempDir().use { temp ->
            val clock = TestClock()
            val adapter = MockUbuntuAdapter(
                clock = clock,
                delayMillis = 500,
                manifest = listOf(UbuntuArtifactLine("tiny.txt", 12)),
            )

            val firstScope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
            val firstSeal = FakeSeal()
            val firstLane = newLane(firstScope, clock, temp, adapters = listOf(adapter), seal = firstSeal)
            var killed = false
            runBlocking {
                val job = (
                    firstLane.submit(UbuntuExecRequest(adapter.env, listOf("make", "app"))) as UbuntuSubmit.Accepted
                    ).job
                awaitState(firstLane, job.jobId) { it.state == UbuntuJobState.REMOTE }
                val before = firstLane.status(job.jobId)!!
                assertEquals(UbuntuJobState.REMOTE, before.state)
                assertFalse(before.egress)
                assertEquals(UbuntuJobRecord.AUTHORITY_WORKER_VFS, before.authorityExited)

                // The process dies here: no restore, no terminal record.
                firstScope.cancel()
                killed = true
                assertTrue("the seal is still on disk", firstSeal.sealed.contains(job.jobId))

                val secondScope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
                // A fresh seal fake: the boot repaired the mode, and the resumed job
                // re-seals before it resumes.
                val bootSeal = FakeSeal()
                val secondLane = newLane(secondScope, clock, temp, adapters = listOf(adapter), seal = bootSeal)
                try {
                    val decisions = secondLane.recover()
                    assertEquals(1, decisions.size)
                    assertEquals(job.jobId, decisions[0].jobId)
                    assertEquals(1, bootSeal.repairCalls)
                    assertTrue("a resumed job re-seals", bootSeal.sealCalls >= 1)

                    val done = awaitTerminal(secondLane, job.jobId)
                    assertEquals(UbuntuJobState.SUCCEEDED, done.state)
                    assertEquals(0, done.exitCode)
                    // The five audit values, unchanged across the kill.
                    assertEquals(before.jobId, done.jobId)
                    assertEquals(before.env, done.env)
                    assertEquals(before.argvDigest, done.argvDigest)
                    assertEquals(before.createdAtMs, done.createdAtMs)
                    assertFalse(done.egress)
                    assertEquals("worker-vfs", done.authorityExited)
                    // The window was closed on the way out, once.
                    assertEquals(UbuntuSealState.RESTORED, done.seal)
                    assertEquals(false, done.internalAccessObserved)
                } finally {
                    secondScope.cancel()
                }
            }
            if (!killed) firstScope.cancel()
        }
    }

    @Test
    fun anArtifactIngestedBeforeTheKillIsNotRefusedAfterIt() {
        TempDir().use { temp ->
            val clock = TestClock()
            val adapter = MockUbuntuAdapter(
                clock = clock,
                delayMillis = 80,
                fileLimitBytes = SIXTEEN_MIB,
                manifest = listOf(UbuntuArtifactLine("tiny.txt", 12)),
            )
            val sink = RecordingSink(temp.path)
            val firstScope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
            val firstLane = newLane(firstScope, clock, temp, adapters = listOf(adapter), sink = sink)
            var jobId = ""
            runBlocking {
                val job = (firstLane.submit(UbuntuExecRequest(adapter.env, listOf("true"))) as UbuntuSubmit.Accepted).job
                jobId = job.jobId
                awaitTerminal(firstLane, job.jobId)
                assertTrue(firstLane.ingest(job.jobId, "tiny.txt") is UbuntuIngest.Ingested)
                firstScope.cancel()

                val secondScope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
                val secondLane = newLane(secondScope, clock, temp, adapters = listOf(adapter), sink = sink)
                try {
                    secondLane.recover()
                    val reloaded = secondLane.status(jobId)!!
                    // The precheck keeps an ingested entry instead of refusing it
                    // again, and the job is terminal so nothing resumes.
                    assertEquals(UbuntuArtifactState.INGESTED, reloaded.artifact("tiny.txt")!!.state)
                    assertEquals(UbuntuJobState.SUCCEEDED, reloaded.state)
                    assertEquals(1, sink.writes.size)
                } finally {
                    secondScope.cancel()
                }
            }
        }
    }

    // ---- §12.3's boot table, row by row ----------------------------------

    @Test
    fun theBootTableFailsWhatItCannotResumeAndKeepsWhatItCan() {
        TempDir().use { temp ->
            val clock = TestClock()
            val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
            val store = UbuntuJobStore(temp.path.resolve("jobs"), TestDurability)
            runBlocking {
                store.save(seededRecord("uj-admitted", UbuntuJobState.ADMITTED, UbuntuSealState.PENDING))
                store.save(seededRecord("uj-sealing", UbuntuJobState.SEALING, UbuntuSealState.SEALED))
                store.save(seededRecord("uj-handoff", UbuntuJobState.HANDING_OFF, UbuntuSealState.SEALED))
                store.save(seededRecord("uj-done", UbuntuJobState.SUCCEEDED, UbuntuSealState.RESTORED))
            }
            val adapter = MockUbuntuAdapter(clock = clock, delayMillis = 80)
            val lane = newLane(scope, clock, temp, adapters = listOf(adapter))
            try {
                runBlocking {
                    val byId = lane.recover().associateBy { it.jobId }
                    // admitted: nothing was contacted, so `not_started` is not a guess.
                    with(byId.getValue("uj-admitted")) {
                        assertEquals(UbuntuJobState.FAILED, state)
                        assertEquals(UbuntuOutcome.NOT_STARTED, failure!!.outcome)
                        assertEquals(UbuntuCause.HOST_LOST, failure!!.cause)
                        assertNull("nothing left the host", authorityExited)
                        assertEquals(UbuntuSealState.PENDING, seal)
                    }
                    // sealing: the same claim, and the seal it did take is restored.
                    with(byId.getValue("uj-sealing")) {
                        assertEquals(UbuntuJobState.FAILED, state)
                        assertEquals(UbuntuOutcome.NOT_STARTED, failure!!.outcome)
                        assertEquals(UbuntuCause.HOST_LOST, failure!!.cause)
                        assertEquals(UbuntuSealState.RESTORED, seal)
                    }
                    // handingOff: a half-finished handoff cannot be replayed, and the
                    // command may have run.
                    with(byId.getValue("uj-handoff")) {
                        assertEquals(UbuntuJobState.FAILED, state)
                        assertEquals(UbuntuOutcome.UNKNOWN, failure!!.outcome)
                        assertEquals(UbuntuCause.HANDOFF_LOST, failure!!.cause)
                        assertEquals(UbuntuSealState.RESTORED, seal)
                    }
                    // a terminal job is untouched.
                    with(byId.getValue("uj-done")) {
                        assertEquals(UbuntuJobState.SUCCEEDED, state)
                        assertNull(failure)
                    }
                }
            } finally {
                scope.cancel()
            }
        }
    }

    @Test
    fun aBootNamesMemoryPressureOnlyWhenItHasEvidence() {
        TempDir().use { temp ->
            val clock = TestClock()
            val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
            val store = UbuntuJobStore(temp.path.resolve("jobs"), TestDurability)
            runBlocking {
                store.save(seededRecord("uj-handoff-a", UbuntuJobState.HANDING_OFF, UbuntuSealState.SEALED))
                store.save(seededRecord("uj-handoff-b", UbuntuJobState.HANDING_OFF, UbuntuSealState.SEALED))
            }
            val adapter = MockUbuntuAdapter(clock = clock, delayMillis = 80)
            val lane = newLane(
                scope,
                clock,
                temp,
                adapters = listOf(adapter),
                // The host recorded pressure after the job's last transition.
                memoryPressureEvidence = { true },
            )
            try {
                runBlocking {
                    val byId = lane.recover().associateBy { it.jobId }
                    byId.values.forEach { record ->
                        assertEquals(UbuntuJobState.FAILED, record.state)
                        // The evidence changes the cause, never the outcome: the
                        // command still may have run.
                        assertEquals(UbuntuCause.MEMORY_RECLAIMED, record.failure!!.cause)
                        assertEquals(UbuntuOutcome.UNKNOWN, record.failure!!.outcome)
                        assertEquals(UbuntuJobFailure.PROVIDER_UNAVAILABLE, record.failure!!.code)
                    }
                }
            } finally {
                scope.cancel()
            }
        }
    }

    @Test
    fun aJobKilledWhileReclaimingWithoutAnExitGetsTheExitFromTheAdapter() {
        TempDir().use { temp ->
            val clock = TestClock()
            val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
            val store = UbuntuJobStore(temp.path.resolve("jobs"), TestDurability)
            val adapter = MockUbuntuAdapter(
                clock = clock,
                delayMillis = 80,
                manifest = listOf(UbuntuArtifactLine("tiny.txt", 12)),
            )
            runBlocking {
                // The state a drain leaves behind when the process dies before the
                // adapter reports the exit: `reclaiming`, no exit code.
                adapter.start("uj-reclaim", listOf("make"), "/dsh/workspace")
                store.save(
                    seededRecord("uj-reclaim", UbuntuJobState.RECLAIMING, UbuntuSealState.SEALED).copy(egress = true),
                )
            }
            val lane = newLane(scope, clock, temp, adapters = listOf(adapter))
            try {
                runBlocking {
                    lane.recover()
                    val done = awaitTerminal(lane, "uj-reclaim")
                    // The exit was observed, not invented, and the job converges.
                    assertEquals(UbuntuJobState.SUCCEEDED, done.state)
                    assertEquals(0, done.exitCode)
                    assertEquals(UbuntuSealState.RESTORED, done.seal)
                }
            } finally {
                scope.cancel()
            }
        }
    }

    @Test
    fun aResumedJobWhoseSealWillNotReformIsUnknownNotNotStarted() {
        TempDir().use { temp ->
            val clock = TestClock()
            val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
            val store = UbuntuJobStore(temp.path.resolve("jobs"), TestDurability)
            runBlocking {
                store.save(seededRecord("uj-remote", UbuntuJobState.REMOTE, UbuntuSealState.SEALED))
            }
            val adapter = MockUbuntuAdapter(clock = clock, delayMillis = 80)
            val lane = newLane(
                scope,
                clock,
                temp,
                adapters = listOf(adapter),
                // The window cannot be re-established after the restart.
                seal = FakeSeal(sealFails = true),
            )
            try {
                runBlocking {
                    val record = lane.recover().first { it.jobId == "uj-remote" }
                    assertEquals(UbuntuJobState.FAILED, record.state)
                    assertEquals(UbuntuCause.SEAL_FAILED, record.failure!!.cause)
                    // Fail-closed, but honest: the command may already have run.
                    assertEquals(UbuntuOutcome.UNKNOWN, record.failure!!.outcome)
                    assertEquals(0, adapter.startCount)
                }
            } finally {
                scope.cancel()
            }
        }
    }
}
