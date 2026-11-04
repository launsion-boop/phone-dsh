// Device evidence for the seal, under the app's own UID.
// SPDX-License-Identifier: MIT
//
// The host JVM suite proves the seal's logic against a real filesystem, but it
// runs as the developer's user in a temp directory. The two things only a device
// can settle are:
//
//   1. `chmod 000` really stops a same-UID process in an app's private
//      directory under SELinux enforcing -- the assumption the whole layer rests
//      on (plan §3 layer 3, premise 1);
//   2. the real `FileObserver` really reports a guest `chmod` on a sealed root,
//      which is the only reason `internalAccessObserved` is not decorative
//      (premise for §3 layer 4).
//
// The guest here is a real separate process (`/system/bin/chmod` through `sh`),
// not a same-thread call: inotify is filesystem-wide, but the test should
// exercise the shape production has.

package com.phonedsh.platform.android

import android.content.Context
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import java.io.File
import java.io.FileInputStream
import java.io.IOException
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
class BuildSealDeviceTest {

    private lateinit var home: Path
    private lateinit var sessions: Path
    private lateinit var marker: Path
    private lateinit var fixture: File

    @Before
    fun setUp() {
        val context = ApplicationProvider.getApplicationContext<Context>()
        fixture = File(context.filesDir, "l46-seal-${System.nanoTime()}")
        home = Files.createDirectories(fixture.toPath().resolve("materialized/home"))
        sessions = Files.createDirectories(home.resolve(SealTargets.SESSIONS))
        PosixModeControl.write(sessions, 0b111_000_000)
        Files.write(sessions.resolve("s1.jsonl"), "device secret".toByteArray(Charsets.UTF_8))
        marker = fixture.toPath().resolve(BuildSeal.MARKER_NAME)
    }

    @After
    fun tearDown() {
        // A failed test may leave a root at 000, which cannot be deleted.
        if (this::sessions.isInitialized) PosixModeControl.write(sessions, 0b111_000_000)
        if (this::fixture.isInitialized) fixture.deleteRecursively()
    }

    private fun sealer(): BuildSeal = BuildSeal(
        targets = SealTargets(
            home = home,
            roots = listOf(SealRoot(SealTargets.SESSIONS, sessions, required = true)),
        ),
        markerPath = marker,
    )

    @Test
    fun aSealedRootCannotBeReadByTheAppUid() = runBlocking {
        val seal = sealer()
        val handle = seal.seal("device-job-1")

        assertEquals("the app uid must see the root as 000", 0, PosixModeControl.read(sessions))
        assertTrue("the seal must be reported as protecting a root", !handle.isVacuous)

        val denied = try {
            FileInputStream(sessions.resolve("s1.jsonl").toFile()).use { it.readBytes() }
            false
        } catch (failure: IOException) {
            true
        }
        assertTrue("a same-UID read of a sealed root must fail", denied)

        // External evidence for the same claim, from a different process.
        val shell = ProcessBuilder("/system/bin/sh", "-c", "cat '${sessions.resolve("s1.jsonl")}' >/dev/null 2>&1")
            .start()
        assertTrue("the shell must not be able to read it either", shell.waitFor() != 0)

        seal.restore(handle)
        val bytes = FileInputStream(sessions.resolve("s1.jsonl").toFile()).use { it.readBytes() }
        assertEquals("device secret", String(bytes, Charsets.UTF_8))
        assertEquals(0b111_000_000, PosixModeControl.read(sessions))
        assertFalse(Files.exists(marker))
    }

    @Test
    fun theWarmButSealedStateKeepsTheRootAtZero() = runBlocking {
        val tripwire = BuildSealTripwire()
        val runtime = BuildRuntime(
            seal = sealer(),
            tripwire = tripwire,
            reaper = ProcessTreeReaper(
                uid = android.os.Process.myUid(),
                selfPid = android.os.Process.myPid(),
                selfPgrp = ProcfsTable().pgrpOf(android.os.Process.myPid()),
                table = ProcfsTable(),
                signal = OsSignalSender,
            ),
        )

        val started = runtime.start("device-warm") as Transition.Accepted
        assertTrue("the environment must be warm", started.to is BuildRuntimeState.IdleSealed)
        assertEquals("warm but sealed: no job and the root is 000", 0, PosixModeControl.read(sessions))
        assertFalse("no job means no armed audit", tripwire.isArmed())

        runtime.beginJob("device-job-2")
        assertEquals("a running job is still sealed", 0, PosixModeControl.read(sessions))
        runtime.endJob("device-job-2")
        assertEquals("the gap between jobs is sealed", 0, PosixModeControl.read(sessions))

        val close = runtime.close(CloseReason.AGENT)
        assertEquals(BuildRuntimeState.Closed, close.state)
        assertEquals(0b111_000_000, PosixModeControl.read(sessions))
    }

    @Test
    fun theRealFileObserverReportsAGuestChmodDuringTheJob() = runBlocking {
        val tripwire = BuildSealTripwire()
        val watch = FileObserverTripwireSource(home, tripwire)
        val runtime = BuildRuntime(
            seal = sealer(),
            tripwire = tripwire,
            reaper = null,
            watch = watch,
        )

        runtime.start("device-watch")
        runtime.beginJob("device-job-3")
        assertTrue("the audit window must be open", tripwire.isArmed())

        // A real second process changes the mode of the sealed root. This is the
        // "deliberate act" §3 layer 4 has to catch.
        val guest = ProcessBuilder("/system/bin/sh", "-c", "chmod 755 '${sessions.toAbsolutePath()}'")
            .redirectErrorStream(true)
            .start()
        assertEquals("the guest chmod must succeed", 0, guest.waitFor())

        assertTrue("a chmod on a sealed root must be observed", awaitAudit(tripwire))
        runtime.endJob("device-job-3", settleMs = 0)
        val jobAudit = runtime.lastAudit()
        val close = runtime.close(CloseReason.AGENT)

        assertTrue("the report must carry the access", jobAudit.observed)
        assertEquals(
            "the chmod must be the recorded kind",
            AccessKind.ATTRIB,
            jobAudit.events.first().kind,
        )
        assertEquals(
            "and it must name the root",
            SealTargets.SESSIONS,
            jobAudit.events.first().name,
        )
        assertTrue("the seal is still restored after a bypass", close.sealRestored)
        assertEquals("the restore wins over the guest's 755", 0b111_000_000, PosixModeControl.read(sessions))
    }

    @Test
    fun aSealLeftBehindInThisProcessIsRepairedByRecovery() = runBlocking {
        sealer().seal("device-crash")
        assertEquals("the crash fixture must be sealed", 0, PosixModeControl.read(sessions))
        assertTrue(Files.exists(marker))

        val recovery = sealer().recoverIfNeeded()

        assertTrue("recovery must repair, got $recovery", recovery is SealRecovery.Repaired)
        assertEquals(0b111_000_000, PosixModeControl.read(sessions))
        assertFalse("the marker must be consumed", Files.exists(marker))
    }

    @Test
    fun theRealProcTableDescribesThisProcess() {
        val table = ProcfsTable()
        val pid = android.os.Process.myPid()
        val uid = android.os.Process.myUid()

        assertEquals("the app uid must be readable from /proc", uid, table.uidOf(pid))
        assertTrue("the process group must be readable", table.pgrpOf(pid) > 0)
        assertTrue(
            "the app process must appear in the snapshot",
            table.entries().any { it.pid == pid && it.ppid >= 0 },
        )
    }

    /** Polls the audit for up to two seconds; inotify delivery is asynchronous. */
    private fun awaitAudit(tripwire: BuildSealTripwire): Boolean {
        val deadline = System.currentTimeMillis() + 2_000L
        while (System.currentTimeMillis() < deadline) {
            if (tripwire.observedSoFar()) return true
            Thread.sleep(20)
        }
        return false
    }
}
