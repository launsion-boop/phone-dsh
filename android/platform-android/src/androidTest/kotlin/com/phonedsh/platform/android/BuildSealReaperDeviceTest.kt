// Device evidence for the process-tree reap, against live processes.
// SPDX-License-Identifier: MIT
//
// The host JVM suite proves the decision making against a fake `/proc`. This
// suite proves the three things only a device can:
//
//   1. `/proc` is readable for this app's uid and names this process correctly;
//   2. `android.system.Os.kill(-pgid, SIGKILL)` works with a **negative** pid,
//      which is the whole "kill the group, not the child" mechanism;
//   3. a background fork (`sleep 300 &`) whose parent has already exited does
//      not survive the close -- the §5.1.1 claim that "用后即弃" is otherwise
//      only nominal.
//
// The job is started through [ShellJobLauncher], so it is the production launch
// path with `setsid`, and the group is the one the launcher created.

package com.phonedsh.platform.android

import android.content.Context
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import java.io.File
import java.nio.file.Files
import java.nio.file.Path
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class BuildSealReaperDeviceTest {

    private lateinit var directory: Path
    private lateinit var fixture: File

    @Before
    fun setUp() {
        val context = ApplicationProvider.getApplicationContext<Context>()
        fixture = File(context.filesDir, "l46-reap-${System.nanoTime()}")
        directory = Files.createDirectories(fixture.toPath())
    }

    @After
    fun tearDown() {
        // Be defensive: kill any leftover sleep the test itself started, so a
        // failed assertion cannot poison the next test's uid scan.
        for (entry in ProcfsTable().entries()) {
            if (entry.uid == android.os.Process.myUid() && entry.name.contains("sleep")) {
                runCatching { OsSignalSender.send(entry.pid, ProcessTreeReaper.SIGKILL) }
            }
        }
        if (this::fixture.isInitialized) fixture.deleteRecursively()
    }

    private fun reaper(): ProcessTreeReaper = ProcessTreeReaper(
        uid = android.os.Process.myUid(),
        selfPid = android.os.Process.myPid(),
        selfPgrp = ProcfsTable().pgrpOf(android.os.Process.myPid()),
        table = ProcfsTable(),
        signal = OsSignalSender,
    )

    private fun sameUidNamed(fragment: String): List<ProcEntry> = ProcfsTable().entries()
        .filter { it.uid == android.os.Process.myUid() && it.name.contains(fragment) }

    @Test
    fun theRealProcTableNamesThisProcess() {
        val pid = android.os.Process.myPid()
        val table = ProcfsTable()

        assertEquals(android.os.Process.myUid(), table.uidOf(pid))
        assertTrue("the pgrp must be readable", table.pgrpOf(pid) > 0)
        assertTrue(
            "the snapshot must contain this process",
            table.entries().any { it.pid == pid },
        )
    }

    @Test
    fun aBackgroundForkDoesNotSurviveTheClose() = runBlocking {
        val launcher = ShellJobLauncher(directory)
        val job = launcher.launch(listOf("sh", "-c", "sleep 300 & echo started"))
        val pid = job.pid
        assertTrue("the launcher must report a pid, got $pid", pid > 0)
        assertEquals("the job shell must exit cleanly", 0, job.await(15_000))
        val printed = job.stdout()
        assertTrue("the job printed to stdout: \"$printed\"", printed.contains("started"))
        assertTrue(
            "the background fork must be alive before the close",
            sameUidNamed("sleep").isNotEmpty(),
        )

        val report = reaper().harvest(listOf(pid), knownGroups = listOf(pid))

        assertEquals("the group the job led must be reaped", listOf(pid), report.groups)
        assertTrue("nothing may survive the close: $report", report.clean)
        assertTrue(
            "the background fork must be gone afterwards",
            sameUidNamed("sleep").isEmpty(),
        )
        assertTrue("the reap must not report delivery errors: ${report.errors}", report.errors.isEmpty())
    }

    @Test
    fun theReaperNeverSignalsThisAppsOwnGroup() {
        val pid = android.os.Process.myPid()
        val table = ProcfsTable()
        val ownGroup = table.pgrpOf(pid)
        val reaper = ProcessTreeReaper(
            uid = android.os.Process.myUid(),
            selfPid = pid,
            selfPgrp = ownGroup,
            table = table,
            signal = OsSignalSender,
        )

        val report = reaper.harvest(listOf(pid))

        assertEquals("own group must be refused", listOf(ownGroup), report.skippedGroups)
        assertTrue("no group signal may be sent", report.groups.none { it == ownGroup })
        assertTrue("this process is still alive", Files.exists(Path.of("/proc/$pid")))
    }

    @Test
    fun aResidualProcessIsKilledByTheRealSighandler() = runBlocking {
        // A fork the launcher did not start: exactly the "stranger under the same
        // uid" the contract says must be reported and killed.
        val orphan = ProcessBuilder("/system/bin/sh", "-c", "sleep 300 &")
            .start()
        assertEquals(0, orphan.waitFor())
        assertTrue("the orphan must be alive", sameUidNamed("sleep").isNotEmpty())

        val report = reaper().harvest(emptyList())

        assertFalse("a stranger must be reported, not ignored", report.survivors.isEmpty())
        assertTrue("and killed: $report", report.clean)
        assertTrue("the orphan must be gone", sameUidNamed("sleep").isEmpty())
    }
}
