// Host-JVM tests for the state machine: every edge in and out of "warm but sealed".
// SPDX-License-Identifier: MIT
//
// Plan §3 layer 0 says the environment may stay warm while the internal roots
// stay at chmod 000, and that this is the only shape with both the low latency
// and the small window. A state that is not tested is a state that will rot, so
// every legal edge is asserted here along with the illegal ones -- especially
// the illegal ones, because a refused `beginJob` is the fail-closed rule.

package com.phonedsh.platform.android

import com.phonedsh.platform.Durability
import java.io.IOException
import java.nio.file.Files
import java.nio.file.Path
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class BuildRuntimeStateMachineTest {

    @get:Rule
    val temporary = TemporaryFolder()

    private lateinit var home: Path
    private lateinit var sessions: Path
    private lateinit var marker: Path

    private val durability: Durability = AndroidDurability(
        fileSync = FileSync { },
        directorySync = DirectorySync { },
    )

    @Before
    fun setUp() {
        val root = temporary.root.toPath()
        home = Files.createDirectories(root.resolve("materialized/home"))
        sessions = Files.createDirectories(home.resolve("sessions"))
        marker = root.resolve(BuildSeal.MARKER_NAME)
        PosixModeControl.write(sessions, 0b111_000_000)
    }

    private fun sealer(
        roots: List<SealRoot> = listOf(SealRoot(SealTargets.SESSIONS, sessions, required = true)),
    ): BuildSeal = BuildSeal(
        targets = SealTargets(home = home, roots = roots),
        markerPath = marker,
        durability = durability,
        modes = PosixModeControl,
        nowMs = { 1_700_000_000_000L },
    )

    private fun reaper(
        proc: FakeProc? = null,
        error: Throwable? = null,
    ): ProcessTreeReaper {
        if (error != null) {
            return ProcessTreeReaper(
                uid = 10_207,
                selfPid = 3_790,
                selfPgrp = 3_790,
                table = ProcTable { throw error },
                signal = SignalSender { _, _ -> },
            )
        }
        val table = proc ?: FakeProc(listOf())
        return ProcessTreeReaper(
            uid = 10_207,
            selfPid = 3_790,
            selfPgrp = 3_790,
            table = table,
            signal = SignalSender { _, _ -> },
        )
    }

    private fun runtime(
        seal: BuildSeal = sealer(),
        tripwire: BuildSealTripwire = BuildSealTripwire(),
        reaper: ProcessTreeReaper? = reaper(),
        watch: SealWatch? = null,
    ): BuildRuntime = BuildRuntime(
        seal = seal,
        tripwire = tripwire,
        reaper = reaper,
        watch = watch,
        nowMs = { 1_700_000_000_000L },
    )

    @Test
    fun startParksInTheWarmButSealedState() = runBlocking {
        val runtime = runtime()
        assertEquals(BuildRuntimeState.NotStarted, runtime.snapshot())

        val transition = runtime.start("environment")

        val to = (transition as Transition.Accepted).to
        assertTrue("the environment must be warm", to is BuildRuntimeState.IdleSealed)
        assertEquals("the roots must be 000 while idle", 0, PosixModeControl.read(sessions))
        assertTrue("the tripwire is per job, so it is not armed yet", !runtime.lastAudit().armed)
    }

    @Test
    fun startTwiceIsRefused() = runBlocking {
        val runtime = runtime()
        runtime.start()
        val refused = runtime.start()
        assertTrue(refused is Transition.Refused)
        assertEquals(1, (runtime.snapshot() as BuildRuntimeState.IdleSealed).seal.protectedLabels.size)
    }

    @Test
    fun beginJobFromNotStartedIsRefused() = runBlocking {
        val runtime = runtime()
        val refused = runtime.beginJob("job-1")
        assertTrue("a job may not start without a seal", refused is Transition.Refused)
        assertEquals(BuildRuntimeState.NotStarted, runtime.snapshot())
        assertEquals(0b111_000_000, PosixModeControl.read(sessions))
    }

    @Test
    fun beginJobKeepsTheSealAndArmsTheAudit() = runBlocking {
        val tripwire = BuildSealTripwire()
        val runtime = runtime(tripwire = tripwire)
        runtime.start()
        val accepted = runtime.beginJob("job-1") as Transition.Accepted

        assertTrue(accepted.to is BuildRuntimeState.JobRunning)
        assertEquals("starting a job must not widen the seal", 0, PosixModeControl.read(sessions))
        assertTrue("the audit window must be open", tripwire.isArmed())
    }

    @Test
    fun beginJobWhileAJobRunsIsRefused() = runBlocking {
        val runtime = runtime()
        runtime.start()
        runtime.beginJob("job-1")
        val refused = runtime.beginJob("job-2")
        assertTrue(refused is Transition.Refused)
        assertEquals("job-1", (runtime.snapshot() as BuildRuntimeState.JobRunning).job)
    }

    @Test
    fun endJobReturnsToIdleSealedWithoutRestoring() = runBlocking {
        val tripwire = BuildSealTripwire()
        val runtime = runtime(tripwire = tripwire)
        runtime.start()
        runtime.beginJob("job-1")
        tripwire.record("sessions", BuildSealTripwire.IN_ATTRIB)
        runtime.endJob("job-1", settleMs = 0)

        assertTrue(runtime.snapshot() is BuildRuntimeState.IdleSealed)
        assertEquals("the gap between jobs is sealed", 0, PosixModeControl.read(sessions))
        assertTrue("the job's audit closed", !tripwire.isArmed())
        assertTrue("the audit kept the job's event", runtime.lastAudit().observed)
        assertTrue("the seal is still there", runtime.snapshot().let { it is BuildRuntimeState.IdleSealed })
    }

    @Test
    fun endJobWithoutAJobIsRefused() = runBlocking {
        val runtime = runtime()
        runtime.start()
        assertTrue(runtime.endJob("job-1", settleMs = 0) is Transition.Refused)
        assertTrue(runtime.snapshot() is BuildRuntimeState.IdleSealed)
    }

    @Test
    fun endJobWithAnotherIdIsRefused() = runBlocking {
        val runtime = runtime()
        runtime.start()
        runtime.beginJob("job-1")
        assertTrue(runtime.endJob("job-2", settleMs = 0) is Transition.Refused)
        assertTrue(runtime.snapshot() is BuildRuntimeState.JobRunning)
    }

    @Test
    fun aSealFailureParksInBrokenAndNoJobMayStart() = runBlocking {
        val runtime = runtime(
            seal = sealer(roots = listOf(SealRoot(SealTargets.SESSIONS, home.resolve("absent"), required = true))),
        )
        val transition = runtime.start() as Transition.Accepted
        val broken = transition.to as? BuildRuntimeState.Broken
            ?: throw AssertionError("a missing required root must break the runtime, got ${transition.to}")
        assertEquals(SealFailure.ROOT_MISSING, broken.failure)

        val refused = runtime.beginJob("job-1")
        assertTrue("fail-closed: a broken seal must refuse the job", refused is Transition.Refused)
        assertTrue(runtime.snapshot() is BuildRuntimeState.Broken)
        val refusedStart = runtime.start()
        assertTrue("a broken environment must not restart without a close", refusedStart is Transition.Refused)
    }

    @Test
    fun closeFromJobRunningReapsAndRestores() = runBlocking {
        val proc = FakeProc(
            listOf(ProcEntry(pid = 5_000, ppid = 3_790, pgrp = 5_000, uid = 10_207, name = "job")),
        )
        val signals = FakeSignals(proc)
        val runtime = runtime(
            reaper = ProcessTreeReaper(
                uid = 10_207,
                selfPid = 3_790,
                selfPgrp = 3_790,
                table = proc,
                signal = signals,
            ),
        )
        runtime.start()
        runtime.beginJob("job-1")
        runtime.noteProcess(5_000)

        val close = runtime.close(CloseReason.SYSTEM_BACKGROUND)

        assertEquals("the system closes without asking", BuildRuntimeState.Closed, close.state)
        assertTrue(close.sealRestored)
        assertEquals("the roots are readable again", 0b111_000_000, PosixModeControl.read(sessions))
        assertEquals("the job's group was reaped", listOf(5_000), close.harvest?.groups)
        assertFalse("the marker is consumed", Files.exists(marker))
    }

    @Test
    fun closeIsIdempotent() = runBlocking {
        val runtime = runtime()
        runtime.start()
        val first = runtime.close(CloseReason.AGENT)
        val second = runtime.close(CloseReason.AGENT)
        assertEquals(BuildRuntimeState.Closed, first.state)
        assertEquals(BuildRuntimeState.Closed, second.state)
        assertTrue("a second close reports success without a second reap", second.sealRestored)
        assertNull("a second close has nothing to restore", second.restoreDetail)
    }

    @Test
    fun closeFromNotStartedClosesWithoutTouchingTheRoots() = runBlocking {
        val runtime = runtime()
        val close = runtime.close(CloseReason.AGENT)
        assertEquals(BuildRuntimeState.Closed, close.state)
        assertEquals(0b111_000_000, PosixModeControl.read(sessions))
        assertFalse(Files.exists(marker))
    }

    @Test
    fun closeRestoresTheRootsEvenWhenTheReapThrows() = runBlocking {
        val runtime = runtime(reaper = reaper(error = IllegalStateException("synthetic /proc failure")))
        runtime.start()
        runtime.beginJob("job-1")

        val close = runtime.close(CloseReason.MEMORY_PRESSURE)

        assertEquals("the restore is the finally, not the happy path", BuildRuntimeState.Closed, close.state)
        assertEquals("the roots must be back", 0b111_000_000, PosixModeControl.read(sessions))
        assertTrue("the reap failure must be reported", close.harvest?.errors?.isNotEmpty() == true)
    }

    @Test
    fun aFailedRestoreLeavesBrokenAndKeepsTheMarker() = runBlocking {
        val failing = object : ModeControl by PosixModeControl {
            override fun write(path: Path, mode: Int) {
                if (mode != 0) throw IOException("synthetic restore failure")
                PosixModeControl.write(path, mode)
            }
        }
        val seal = BuildSeal(
            targets = SealTargets(home = home, roots = listOf(SealRoot(SealTargets.SESSIONS, sessions, required = true))),
            markerPath = marker,
            durability = durability,
            modes = failing,
            nowMs = { 1_700_000_000_000L },
        )
        val runtime = runtime(seal = seal)
        runtime.start()

        val close = runtime.close(CloseReason.AGENT)

        val broken = close.state as? BuildRuntimeState.Broken
            ?: throw AssertionError("a failed restore must be Broken, got ${close.state}")
        assertEquals(SealFailure.RESTORE_FAILED, broken.failure)
        assertFalse("a failed restore must not claim success", close.sealRestored)
        assertTrue("the marker must survive for the next boot", Files.exists(marker))
    }

    @Test
    fun closeClearsABrokenEnvironment() = runBlocking {
        val runtime = runtime(
            seal = sealer(roots = listOf(SealRoot(SealTargets.SESSIONS, home.resolve("absent"), required = true))),
        )
        runtime.start()
        val close = runtime.close(CloseReason.AGENT)
        assertEquals(BuildRuntimeState.Closed, close.state)
    }

    @Test
    fun theWatchIsArmedPerJobAndDisarmedOnClose() = runBlocking {
        val watch = RecordingWatch()
        val runtime = runtime(watch = watch)
        runtime.start()
        assertEquals("no job, no watch", emptyList<String>(), watch.calls)

        runtime.beginJob("job-1")
        assertEquals(listOf("start"), watch.calls)
        runtime.endJob("job-1", settleMs = 0)
        assertEquals(listOf("start", "stop"), watch.calls)

        runtime.close(CloseReason.AGENT)
        assertEquals("a close after endJob does not stop twice", listOf("start", "stop"), watch.calls)
    }

    private class RecordingWatch : SealWatch {
        val calls = mutableListOf<String>()

        override fun start() {
            calls.add("start")
        }

        override fun stop() {
            calls.add("stop")
        }
    }
}
