// Device acceptance for the echo adapter: the whole chain, on real primitives.
// SPDX-License-Identifier: MIT
//
// Plan §6 phase 1's acceptance, on a device and with no Ubuntu: the real seal,
// the real `FileObserver`, the real `setsid` job, the real `/proc` reap and the
// real restore. The only fake thing is the job itself (`sh -c 'echo hi'`).
//
// Two runs are the acceptance:
//   * a benign job: `internalAccessObserved == false`, roots were 000 while the
//     environment was warm, and the close put them back;
//   * a job that does exactly what the design says is possible -- `chmod` a
//     sealed root and read it -- and the audit says so.

package com.phonedsh.platform.android

import android.content.Context
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import java.io.File
import java.io.FileInputStream
import java.nio.file.Files
import java.nio.file.Path
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class EchoJobAdapterDeviceTest {

    private lateinit var fixture: File
    private lateinit var home: Path
    private lateinit var sessions: Path
    private lateinit var marker: Path

    @Before
    fun setUp() {
        val context = ApplicationProvider.getApplicationContext<Context>()
        fixture = File(context.filesDir, "l46-echo-${System.nanoTime()}")
        home = Files.createDirectories(fixture.toPath().resolve("materialized/home"))
        sessions = Files.createDirectories(home.resolve(SealTargets.SESSIONS))
        PosixModeControl.write(sessions, 0b111_000_000)
        Files.write(sessions.resolve("s1.jsonl"), "device secret".toByteArray(Charsets.UTF_8))
        marker = fixture.toPath().resolve(BuildSeal.MARKER_NAME)
    }

    @After
    fun tearDown() {
        if (this::sessions.isInitialized) PosixModeControl.write(sessions, 0b111_000_000)
        if (this::fixture.isInitialized) fixture.deleteRecursively()
    }

    private fun adapter(command: List<String>): Pair<EchoJobAdapter, BuildSealTripwire> {
        val tripwire = BuildSealTripwire()
        val seal = BuildSeal(
            targets = SealTargets(
                home = home,
                roots = listOf(SealRoot(SealTargets.SESSIONS, sessions, required = true)),
                exclusions = listOf(
                    SealExclusion(
                        label = "host-journal",
                        path = fixture.toPath().resolve("journal"),
                        reason = SealTargets.HOST_JOURNAL_NOT_SEALED,
                    ),
                ),
            ),
            markerPath = marker,
        )
        val pid = android.os.Process.myPid()
        val runtime = BuildRuntime(
            seal = seal,
            tripwire = tripwire,
            reaper = ProcessTreeReaper(
                uid = android.os.Process.myUid(),
                selfPid = pid,
                selfPgrp = ProcfsTable().pgrpOf(pid),
                table = ProcfsTable(),
                signal = OsSignalSender,
            ),
            watch = FileObserverTripwireSource(home, tripwire),
        )
        return EchoJobAdapter(
            runtime = runtime,
            launcher = ShellJobLauncher(fixture.toPath()),
            command = command,
        ) to tripwire
    }

    @Test
    fun theChainRunsEndToEndOnDevice() = runBlocking {
        val (adapter, tripwire) = adapter(listOf("sh", "-c", "echo hi"))

        val outcome = adapter.run("device-echo-1")

        assertEquals("hi\n", outcome.stdout)
        assertEquals(0, outcome.exitCode)
        assertNull("a clean run has nothing to refuse", outcome.refusal)
        assertEquals(
            "warm but sealed when the job started",
            mapOf(SealTargets.SESSIONS to 0),
            outcome.modesAtIdle,
        )
        assertFalse("a benign job observed no access", outcome.internalAccessObserved)
        assertEquals(1, outcome.exclusions.size)
        assertEquals(BuildRuntimeState.Closed, outcome.state)
        assertTrue("the roots must be restored", outcome.sealRestored)
        assertEquals("the mode is back", 0b111_000_000, PosixModeControl.read(sessions))
        assertFalse("the audit window must be closed", tripwire.isArmed())
        assertFalse("no marker may be left behind", Files.exists(marker))
        assertTrue("the report must be a clean one", outcome.harvest?.clean == true)
        val bytes = FileInputStream(sessions.resolve("s1.jsonl").toFile()).use { it.readBytes() }
        assertEquals("device secret", String(bytes, Charsets.UTF_8))
    }

    @Test
    fun aGuestChmodDuringTheJobIsReported() = runBlocking {
        val (adapter, _) = adapter(
            listOf("sh", "-c", "chmod 755 '${sessions.toAbsolutePath()}'; echo hi"),
        )

        val outcome = adapter.run("device-echo-2")

        assertEquals("the job still ran", "hi\n", outcome.stdout)
        assertTrue("the bypass must be reported: ${outcome.statusLine()}", outcome.internalAccessObserved)
        assertEquals(
            "the chmod is what the watch must name",
            AccessKind.ATTRIB,
            outcome.audit.events.first().kind,
        )
        assertEquals(SealTargets.SESSIONS, outcome.audit.events.first().name)
        assertTrue("the restore still runs after a bypass", outcome.sealRestored)
        assertEquals(
            "the restore must win over the guest's 755",
            0b111_000_000,
            PosixModeControl.read(sessions),
        )
        assertTrue("the seal really was 000 while the job ran", outcome.modesAtIdle[SealTargets.SESSIONS] == 0)
    }
}
