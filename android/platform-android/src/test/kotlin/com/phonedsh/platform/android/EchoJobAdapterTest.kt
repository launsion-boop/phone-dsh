// Host-JVM acceptance for the echo adapter: seal -> run -> reap -> restore -> audit.
// SPDX-License-Identifier: MIT
//
// Plan §6 phase 1 acceptance, without Ubuntu: a fake job (`sh -c 'echo hi'`) has
// to walk the whole chain and come back with the result **and**
// `internalAccessObserved`. The inotify half is faked here (the device suite
// proves the real `FileObserver`), but nothing else is: the seal is a real
// `chmod 000`, the job's read attempt is a real `open()` that the kernel
// refuses, the guest's `chmod` is a real mode change, and the restore is the
// real one.

package com.phonedsh.platform.android

import com.phonedsh.platform.Durability
import java.io.FileInputStream
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

class EchoJobAdapterTest {

    @get:Rule
    val temporary = TemporaryFolder()

    private lateinit var home: Path
    private lateinit var sessions: Path
    private lateinit var marker: Path
    private lateinit var tripwire: BuildSealTripwire

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
        Files.write(sessions.resolve("s1.jsonl"), "session secret".toByteArray(Charsets.UTF_8))
        tripwire = BuildSealTripwire(nowMs = { 1_700_000_000_000L })
    }

    private fun runtime(missingRoot: Boolean = false): BuildRuntime {
        val path = if (missingRoot) home.resolve("absent") else sessions
        val seal = BuildSeal(
            targets = SealTargets(
                home = home,
                roots = listOf(SealRoot(SealTargets.SESSIONS, path, required = true)),
                exclusions = listOf(
                    SealExclusion("host-journal", home.parent.resolve("journal"), "host-hot"),
                ),
            ),
            markerPath = marker,
            durability = durability,
            modes = PosixModeControl,
            nowMs = { 1_700_000_000_000L },
        )
        val proc = FakeProc(listOf(ProcEntry(4_242, 3_790, 4_242, 10_207, "echo-job")))
        return BuildRuntime(
            seal = seal,
            tripwire = tripwire,
            reaper = ProcessTreeReaper(
                uid = 10_207,
                selfPid = 3_790,
                selfPgrp = 3_790,
                table = proc,
                signal = FakeSignals(proc),
            ),
            nowMs = { 1_700_000_000_000L },
        )
    }

    /** A job launcher whose "process" runs [body] at launch and returns its stdout. */
    private class ScriptedLauncher(private val body: () -> String) : JobLauncher {
        var launched = false
        var command: List<String>? = null

        override fun launch(command: List<String>): JobProcess {
            launched = true
            this.command = command
            val output = body()
            return object : JobProcess {
                override val pid: Int = 4_242
                override fun stdout(): String = output
                override fun await(timeoutMs: Long): Int = 0
                override fun destroy() = Unit
            }
        }
    }

    @Test
    fun aBenignJobRunsEndToEndAndReportsNoAccess() = runBlocking {
        var modeWhileRunning = -1
        var readWhileRunning: Boolean? = null
        val launcher = ScriptedLauncher {
            modeWhileRunning = PosixModeControl.read(sessions)
            readWhileRunning = try {
                FileInputStream(sessions.resolve("s1.jsonl").toFile()).use { it.readBytes() }
                true
            } catch (failure: IOException) {
                false
            }
            "hi\n"
        }
        val adapter = EchoJobAdapter(runtime = runtime(), launcher = launcher)

        val outcome = adapter.run("echo-1")

        assertEquals("the acceptance command runs", listOf("sh", "-c", "echo hi"), launcher.command)
        assertTrue(launcher.launched)
        assertEquals("hi\n", outcome.stdout)
        assertEquals(0, outcome.exitCode)
        assertNull("a clean run has nothing to refuse", outcome.refusal)
        assertEquals(
            "the environment must be warm and sealed when the job starts",
            mapOf("sessions" to 0),
            outcome.modesAtIdle,
        )
        assertEquals("the job must run inside the seal", 0, modeWhileRunning)
        assertEquals("a sealed root must not be readable by the job", false, readWhileRunning)
        assertFalse("a benign job observed no access", outcome.internalAccessObserved)
        assertEquals(BuildRuntimeState.Closed, outcome.state)
        assertTrue("the roots must be restored", outcome.sealRestored)
        assertEquals("the mode is back", 0b111_000_000, PosixModeControl.read(sessions))
        assertEquals("one exclusion must be reported", 1, outcome.exclusions.size)
    }

    @Test
    fun aJobThatBypassesTheSealIsReported() = runBlocking {
        var bypassedRead: String? = null
        val launcher = ScriptedLauncher {
            // The guest does what the design says it can: restore the mode
            // itself (a deliberate, observable act) and read the bytes.
            PosixModeControl.write(sessions, 0b111_101_101)
            tripwire.record("sessions", BuildSealTripwire.IN_ATTRIB)
            bypassedRead = try {
                FileInputStream(sessions.resolve("s1.jsonl").toFile()).use {
                    String(it.readBytes(), Charsets.UTF_8)
                }
            } catch (failure: IOException) {
                null
            }
            "hi\n"
        }
        val adapter = EchoJobAdapter(runtime = runtime(), launcher = launcher)

        val outcome = adapter.run("echo-2")

        assertEquals("the bypass is a real read", "session secret", bypassedRead)
        assertTrue("the bypass must be reported", outcome.internalAccessObserved)
        assertEquals(1, outcome.audit.events.size)
        assertEquals(AccessKind.ATTRIB, outcome.audit.events.single().kind)
        assertEquals("sessions", outcome.audit.events.single().name)
        assertTrue("the status line carries the field", outcome.statusLine().contains("internalAccessObserved=true"))
        assertTrue("the restore still happens after a bypass", outcome.sealRestored)
        assertEquals("and it wins over the guest's mode", 0b111_000_000, PosixModeControl.read(sessions))
    }

    @Test
    fun aRefusedSealMeansTheJobNeverStarts() = runBlocking {
        val launcher = ScriptedLauncher { "must not run" }
        val adapter = EchoJobAdapter(runtime = runtime(missingRoot = true), launcher = launcher)

        val outcome = adapter.run("echo-3")

        assertFalse("fail-closed: the command must not execute", launcher.launched)
        assertFalse(outcome.jobRan)
        assertTrue("the refusal must be reported", outcome.refusal?.isNotEmpty() == true)
        assertFalse("no access can be observed when nothing ran", outcome.internalAccessObserved)
        assertTrue("the close still ran", outcome.state is BuildRuntimeState.Closed)
        assertTrue("nothing to restore, and that is reported as success", outcome.sealRestored)
        assertFalse("no marker may be left behind", Files.exists(marker))
    }

    @Test
    fun aLaunchFailureStillRestoresTheSeal() = runBlocking {
        val adapter = EchoJobAdapter(
            runtime = runtime(),
            launcher = JobLauncher { throw IOException("synthetic exec failure") },
        )

        val outcome = adapter.run("echo-4")

        assertTrue(outcome.jobRan)
        assertEquals("synthetic exec failure", outcome.launchError)
        assertEquals("a launch failure is not a sealed report", 0b111_000_000, PosixModeControl.read(sessions))
        assertTrue(outcome.sealRestored)
        assertEquals(BuildRuntimeState.Closed, outcome.state)
        assertFalse("no marker may survive a failure", Files.exists(marker))
    }

    @Test
    fun theStatusLineNamesEveryFieldTheContractNeeds() = runBlocking {
        val adapter = EchoJobAdapter(
            runtime = runtime(),
            launcher = ScriptedLauncher { "hi\n" },
        )
        val line = adapter.run("echo-5").statusLine()

        for (field in listOf("state=", "jobRan=", "internalAccessObserved=", "exit=", "sealRestored=")) {
            assertTrue("the status line must carry $field: $line", line.contains(field))
        }
    }
}
