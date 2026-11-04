// phone-dsh — :dsh unit test: the four `ubuntu.exec` acceptance runs.
// SPDX-License-Identifier: MIT
//
// These are the end-to-end runs of the mock adapter, and they are the evidence
// for bridge.md §12. Each test names the contract section it pins, and each one
// is written so that a wrong answer fails it rather than a slow one:
//
//   1. a call answers a JobRef and polling converges — §12.2;
//   2. artifacts come back as ≤ 15 MiB mutations plus appended suffixes — §12.7;
//   3. a drain during polling is consistent and terminal inside the deadline —
//      §12.9;
//   5. an artifact over the ingest bound is refused and the job says "succeeded
//      but the ingest failed" — §12.7/§12.8.
//
// (Run 4, the process kill, is `UbuntuJobRecoveryTest` because it needs two lanes
// over one directory.)

package com.phonedsh.dsh.localexec

import java.nio.file.Files
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class UbuntuJobLaneTest {

    // ---- 1. the call answers a JobRef, and polling converges --------------

    @Test
    fun anExecCallAnswersAJobRefAndPollingConverges() {
        val clock = TestClock()
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
        TempDir().use { temp ->
            val adapter = MockUbuntuAdapter(
                clock = clock,
                delayMillis = 400,
                manifest = listOf(UbuntuArtifactLine("tiny.txt", 12)),
            )
            val lane = newLane(scope, clock, temp, adapters = listOf(adapter))
            try {
                runBlocking {
                    val argv = listOf("bash", "-lc", "echo hi")
                    val startedAt = System.nanoTime()
                    val answer = lane.submit(UbuntuExecRequest(env = adapter.env, argv = argv, label = "smoke"))
                    val callMillis = (System.nanoTime() - startedAt) / 1_000_000L

                    assertTrue("the call is refused: $answer", answer is UbuntuSubmit.Accepted)
                    val jobRef = (answer as UbuntuSubmit.Accepted).job
                    assertTrue(
                        "a blocking call would have waited 400 ms, not ${callMillis}ms",
                        callMillis < 200,
                    )

                    // §12.2's JobRef, field by field.
                    assertTrue(UbuntuJobRecord.JOB_ID.matches(jobRef.jobId))
                    assertEquals(adapter.env, jobRef.env)
                    assertEquals(UbuntuJobState.ADMITTED, jobRef.state)
                    assertEquals(1, jobRef.seq)
                    assertFalse(jobRef.egress)
                    assertNull(jobRef.authorityExited)
                    assertEquals(UbuntuJobLane.digest(argv), jobRef.argvDigest)
                    assertEquals(argv.size, jobRef.argvLength)
                    assertEquals(FIFTEEN_MIB, jobRef.limits.fileLimitBytes)
                    assertEquals(WORKSPACE_BUCKET, jobRef.limits.workspaceLimitBytes)

                    assertFalse("the job cannot be done yet", lane.status(jobRef.jobId)!!.terminal)

                    val done = awaitTerminal(lane, jobRef.jobId)
                    assertEquals(UbuntuJobState.SUCCEEDED, done.state)
                    assertEquals(0, done.exitCode)
                    assertTrue(done.seq > jobRef.seq)
                    // §12.5: the two audit fields, still true after the command ran.
                    assertFalse(done.egress)
                    assertEquals(UbuntuJobRecord.AUTHORITY_WORKER_VFS, done.authorityExited)
                    // §12.8: the window is closed before the terminal record is written.
                    assertEquals(UbuntuSealState.RESTORED, done.seal)
                    assertEquals(false, done.internalAccessObserved)
                    assertEquals(UbuntuArtifactState.AVAILABLE, done.artifact("tiny.txt")!!.state)
                    assertNull(done.failure)
                    assertEquals(argv, adapter.lastArgv)
                    assertEquals("one command was handed over", 1, adapter.startCount)
                }
            } finally {
                scope.cancel()
            }
        }
    }

    // ---- 2. ≤ 15 MiB mutations plus appended suffixes ---------------------

    @Test
    fun anArtifactOverOneMutationLandsAsACompleteWritePlusAnAppend() {
        val clock = TestClock()
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
        TempDir().use { temp ->
            val adapter = MockUbuntuAdapter(
                clock = clock,
                delayMillis = 80,
                fileLimitBytes = SIXTEEN_MIB,
                manifest = listOf(
                    UbuntuArtifactLine("tiny.txt", 12),
                    UbuntuArtifactLine("mid.bin", MockUbuntuAdapter.MID_BYTES),
                ),
            )
            val sink = RecordingSink(temp.path)
            val lane = newLane(scope, clock, temp, adapters = listOf(adapter), sink = sink)
            try {
                runBlocking {
                    val job = (lane.submit(UbuntuExecRequest(adapter.env, listOf("make"))) as UbuntuSubmit.Accepted).job
                    val done = awaitTerminal(lane, job.jobId)
                    assertEquals(UbuntuJobState.SUCCEEDED, done.state)
                    assertEquals(SIXTEEN_MIB, done.limits.fileLimitBytes)
                    assertEquals(UbuntuArtifactState.AVAILABLE, done.artifact("mid.bin")!!.state)

                    // The ordinary case: one complete mutation, no append.
                    val small = lane.ingest(job.jobId, "tiny.txt")
                    assertTrue("$small", small is UbuntuIngest.Ingested)
                    val smallIngest = small as UbuntuIngest.Ingested
                    assertEquals(1, smallIngest.mutations.size)
                    assertEquals(
                        UbuntuMutation(complete = true, appendFrom = 0, length = 12),
                        smallIngest.mutations[0],
                    )
                    assertEquals(12L, Files.size(sink.file(smallIngest.path)))

                    // The boundary case: 15 MiB + 512 KiB is one complete write of
                    // exactly 15 MiB plus one appended suffix of 512 KiB.
                    val mid = lane.ingest(job.jobId, "mid.bin")
                    assertTrue("$mid", mid is UbuntuIngest.Ingested)
                    val ingested = mid as UbuntuIngest.Ingested
                    assertEquals(2, ingested.mutations.size)
                    assertEquals(
                        UbuntuMutation(complete = true, appendFrom = 0, length = FIFTEEN_MIB),
                        ingested.mutations[0],
                    )
                    assertEquals(
                        UbuntuMutation(complete = false, appendFrom = FIFTEEN_MIB, length = 512L * 1024L),
                        ingested.mutations[1],
                    )
                    // 30 chunks fill the complete write, 1 fills the suffix.
                    assertEquals(31, ingested.chunks)
                    // One write for tiny.txt, two for mid.bin.
                    assertEquals(3, sink.writes.size)
                    assertTrue(
                        "no mutation may carry more than 15 MiB",
                        sink.writes.all { it.second.length <= FIFTEEN_MIB },
                    )
                    assertEquals(listOf(12L, FIFTEEN_MIB, 512L * 1024L), sink.lengths)

                    val file = sink.file(ingested.path)
                    assertEquals(MockUbuntuAdapter.MID_BYTES, Files.size(file))
                    // The bytes are in the right places: the append continued the
                    // stream instead of restarting or overwriting it.
                    val bytes = Files.readAllBytes(file)
                    for (index in listOf(0L, FIFTEEN_MIB - 1, FIFTEEN_MIB, MockUbuntuAdapter.MID_BYTES - 1)) {
                        assertEquals(
                            "byte $index of mid.bin",
                            MockUbuntuAdapter.byteAt("mid.bin", index),
                            bytes[index.toInt()],
                        )
                    }
                    assertEquals(
                        UbuntuArtifactState.INGESTED,
                        lane.status(job.jobId)!!.artifact("mid.bin")!!.state,
                    )
                }
            } finally {
                scope.cancel()
            }
        }
    }

    // ---- 3. a drain during polling ---------------------------------------

    @Test
    fun aDrainDuringPollingNeverReportsRemoteAndReachesATerminalState() {
        val clock = TestClock()
        val laneScope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
        val samplerScope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
        TempDir().use { temp ->
            val adapter = MockUbuntuAdapter(
                clock = clock,
                delayMillis = 10_000,
                manifest = listOf(UbuntuArtifactLine("tiny.txt", 12)),
            )
            val seal = FakeSeal()
            val lane = newLane(laneScope, clock, temp, adapters = listOf(adapter), seal = seal)
            try {
                runBlocking {
                    val job = (lane.submit(UbuntuExecRequest(adapter.env, listOf("sleep", "9"))) as UbuntuSubmit.Accepted).job
                    awaitState(lane, job.jobId) { it.state == UbuntuJobState.REMOTE }

                    // §12.9: the record moves before the drain waits.
                    assertEquals(listOf(job.jobId), lane.beginDrain())
                    assertEquals(UbuntuJobState.RECLAIMING, lane.status(job.jobId)!!.state)

                    val sampled = mutableListOf<UbuntuJobState>()
                    val sampler = samplerScope.launch {
                        while (isActive) {
                            lane.status(job.jobId)?.let { record ->
                                synchronized(sampled) { sampled += record.state }
                            }
                            delay(1)
                        }
                    }
                    val startedAt = System.nanoTime()
                    val finished = lane.finishDrain(deadlineMs = 1_000)
                    val drainMillis = (System.nanoTime() - startedAt) / 1_000_000L
                    sampler.cancel()

                    assertTrue("the drain sampled nothing", sampled.isNotEmpty())
                    assertFalse(
                        "a job the host has abandoned must never be reported remote, saw $sampled",
                        sampled.contains(UbuntuJobState.REMOTE),
                    )

                    val done = finished.first { it.jobId == job.jobId }
                    assertTrue("the drain must finish inside its deadline: ${drainMillis}ms", drainMillis < 1_000)
                    assertEquals(UbuntuJobState.CANCELLED, done.state)
                    assertNotNull(done.failure)
                    assertEquals(UbuntuJobFailure.CANCELLED, done.failure!!.code)
                    assertEquals(UbuntuOutcome.CANCELLED, done.failure!!.outcome)
                    assertEquals(UbuntuCause.HOST_DRAINING, done.failure!!.cause)
                    // The adapter acknowledged and reported an exit, so the exit code
                    // is recorded instead of being guessed at.
                    assertEquals(MockUbuntuAdapter.DEADLINE_EXIT_CODE, done.exitCode)
                    // Every path out of the window restores it and reads the tripwire.
                    assertEquals(UbuntuSealState.RESTORED, done.seal)
                    assertEquals(false, done.internalAccessObserved)
                    assertTrue(seal.sealed.isEmpty())
                }
            } finally {
                samplerScope.cancel()
                laneScope.cancel()
            }
        }
    }

    // ---- 5. an artifact over the ingest bound ----------------------------

    @Test
    fun anArtifactOverTheIngestBoundIsRefusedAndTheJobSaysIngestFailed() {
        val clock = TestClock()
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
        TempDir().use { temp ->
            val adapter = MockUbuntuAdapter(clock = clock, delayMillis = 80)
            val sink = RecordingSink(temp.path)
            val lane = newLane(scope, clock, temp, adapters = listOf(adapter), sink = sink)
            try {
                runBlocking {
                    val job = (lane.submit(UbuntuExecRequest(adapter.env, listOf("make", "release"))) as UbuntuSubmit.Accepted).job
                    val done = awaitTerminal(lane, job.jobId)

                    // "The job succeeded but the ingest failed": the command's exit
                    // code is a fact, and the job is *not* a failure.
                    assertEquals(UbuntuJobState.INGEST_REFUSED, done.state)
                    assertEquals(0, done.exitCode)
                    assertNull("an ingest refusal is not a job failure", done.failure)

                    // 20 MiB is over the 15 MiB default bound.
                    val huge = done.artifact("huge.bin")
                    assertNotNull(huge)
                    assertEquals(UbuntuArtifactState.REFUSED, huge!!.state)
                    assertEquals(UbuntuVfsRefusal.CODE, huge.refusal!!.code)
                    assertEquals(UbuntuVfsRefusal.FILE_TOO_LARGE, huge.refusal!!.reason)
                    assertEquals(FIFTEEN_MIB, huge.refusal!!.limit)
                    assertEquals(MockUbuntuAdapter.HUGE_BYTES, huge.refusal!!.bytes)
                    // 15 MiB + 512 KiB is over the default bound too, and a refusal
                    // never depends on fetch order: the precheck walks names.
                    assertEquals(UbuntuArtifactState.REFUSED, done.artifact("mid.bin")!!.state)
                    assertEquals(UbuntuArtifactState.AVAILABLE, done.artifact("tiny.txt")!!.state)

                    // The fetch refuses before the first byte, and writes nothing.
                    val writesBefore = sink.writes.size
                    val refused = lane.ingest(job.jobId, "huge.bin")
                    assertTrue("$refused", refused is UbuntuIngest.Refused)
                    assertEquals(huge.refusal, (refused as UbuntuIngest.Refused).refusal)
                    assertEquals(writesBefore, sink.writes.size)
                    val target = "/dsh/workspace/${UbuntuJobLane.ARTIFACT_DIR}/${job.jobId}/huge.bin"
                    assertFalse(Files.exists(sink.file(target)))

                    // A refused sibling does not poison the rest of the manifest.
                    assertTrue(lane.ingest(job.jobId, "tiny.txt") is UbuntuIngest.Ingested)
                }
            } finally {
                scope.cancel()
            }
        }
    }

    // ---- §12.3 row 15: the one terminal revision -------------------------

    @Test
    fun aFetchRefusedAfterSuccessRevisesTheJobToIngestRefused() {
        var usedBytes = 0L
        val clock = TestClock()
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
        TempDir().use { temp ->
            val adapter = MockUbuntuAdapter(
                clock = clock,
                delayMillis = 80,
                fileLimitBytes = SIXTEEN_MIB,
                manifest = listOf(UbuntuArtifactLine("tiny.txt", 12)),
            )
            val lane = newLane(
                scope,
                clock,
                temp,
                adapters = listOf(adapter),
                workspaceUsedBytes = { usedBytes },
            )
            try {
                runBlocking {
                    val job = (lane.submit(UbuntuExecRequest(adapter.env, listOf("true"))) as UbuntuSubmit.Accepted).job
                    val done = awaitTerminal(lane, job.jobId)
                    assertEquals(UbuntuJobState.SUCCEEDED, done.state)
                    assertEquals(UbuntuArtifactState.AVAILABLE, done.artifact("tiny.txt")!!.state)

                    // The workspace filled between the manifest and the fetch.
                    usedBytes = WORKSPACE_BUCKET - 4
                    val refused = lane.ingest(job.jobId, "tiny.txt")
                    assertTrue("$refused", refused is UbuntuIngest.Refused)
                    assertEquals(UbuntuVfsRefusal.QUOTA_EXCEEDED, (refused as UbuntuIngest.Refused).refusal.reason)
                    assertEquals(WORKSPACE_BUCKET, refused.refusal.limit)

                    val revised = lane.status(job.jobId)!!
                    assertEquals(UbuntuJobState.INGEST_REFUSED, revised.state)
                    assertEquals(UbuntuArtifactState.REFUSED, revised.artifact("tiny.txt")!!.state)
                    assertTrue("the revision is a recorded change", revised.seq > done.seq)
                    // The command's outcome did not change: it still ran and exited 0.
                    assertEquals(0, revised.exitCode)
                    assertNull(revised.failure)
                }
            } finally {
                scope.cancel()
            }
        }
    }

    @Test
    fun anObservedJobDeadlineIsAnExitCodeNotAFailure() {
        val clock = TestClock()
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
        TempDir().use { temp ->
            val adapter = MockUbuntuAdapter(
                clock = clock,
                delayMillis = 30_000,
                manifest = listOf(UbuntuArtifactLine("tiny.txt", 12)),
            )
            val lane = newLane(scope, clock, temp, adapters = listOf(adapter))
            try {
                runBlocking {
                    val job = (
                        lane.submit(
                            UbuntuExecRequest(
                                env = adapter.env,
                                argv = listOf("sleep", "30"),
                                jobTimeoutMs = 1_000,
                            ),
                        ) as UbuntuSubmit.Accepted
                        ).job
                    val done = awaitTerminal(lane, job.jobId)
                    // exec.md's deadline value is a result: the adapter acknowledged
                    // the stop and reported an exit, so the host knows what happened.
                    assertEquals(UbuntuJobState.SUCCEEDED, done.state)
                    assertEquals(MockUbuntuAdapter.DEADLINE_EXIT_CODE, done.exitCode)
                    assertNull(done.failure)
                }
            } finally {
                scope.cancel()
            }
        }
    }
}
