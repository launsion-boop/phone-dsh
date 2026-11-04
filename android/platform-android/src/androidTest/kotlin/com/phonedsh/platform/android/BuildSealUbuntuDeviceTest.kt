// Device evidence for the `ubuntu` lane's seal adapter, under the app's own UID.
// SPDX-License-Identifier: MIT
//
// The host JVM suite proves the adapter's logic against a real filesystem as the
// developer's user. What only a device can settle is that the four seam methods
// move the *real* mode of a file in the app's private directory (SELinux
// enforcing, same UID as the guest), that the real `FileObserver` reports a
// guest `chmod` through the adapter's window, and that a new adapter over the
// same workspace repairs what a killed one left at 000.
//
// This is the unit the production path exercises: `MockUbuntuSession` ->
// `UbuntuJobLane` -> `BuildSealUbuntu`. The app-level proof (a real `ubuntu run`
// from the Agent, checked with `adb shell ls -ld`) is in
// `docs/receipts/android-port-pr-description.md`.

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
class BuildSealUbuntuDeviceTest {

    private lateinit var fixture: File
    private lateinit var home: Path
    private lateinit var sessions: Path
    private lateinit var marker: Path

    @Before
    fun setUp() {
        val context = ApplicationProvider.getApplicationContext<Context>()
        fixture = File(context.filesDir, "l59-seal-${System.nanoTime()}")
        home = Files.createDirectories(fixture.toPath().resolve("materialized/home"))
        sessions = Files.createDirectories(home.resolve(SealTargets.SESSIONS))
        PosixModeControl.write(sessions, ORIGINAL_MODE)
        Files.write(sessions.resolve("s1.jsonl"), "device secret".toByteArray(Charsets.UTF_8))
        marker = fixture.toPath().resolve(BuildSeal.MARKER_NAME)
    }

    @After
    fun tearDown() {
        // A failed test may leave the root at 000, which cannot be deleted.
        if (this::sessions.isInitialized) PosixModeControl.write(sessions, ORIGINAL_MODE)
        if (this::fixture.isInitialized) fixture.deleteRecursively()
    }

    /** The adapter exactly as `forWorkspace` builds it, over a fixture workspace. */
    private fun adapter(): Pair<BuildSealUbuntu, BuildSealTripwire> {
        val tripwire = BuildSealTripwire()
        val seal = BuildSeal(
            targets = SealTargets(
                home = home,
                roots = listOf(SealRoot(SealTargets.SESSIONS, sessions, required = true)),
            ),
            markerPath = marker,
            log = {},
            selfEvents = tripwire,
        )
        val adapter = BuildSealUbuntu(
            seal = seal,
            tripwire = tripwire,
            watch = { FileObserverTripwireSource(home, tripwire) },
        )
        return adapter to tripwire
    }

    @Test
    fun sealAndRestoreMoveTheRealModeOnDevice() = runBlocking {
        val (adapter, _) = adapter()

        assertEquals(SealOutcome.Sealed, adapter.seal("uj-device-1"))
        assertEquals("the app uid sees the root as 000", 0, PosixModeControl.read(sessions))
        assertTrue("a marker must be durable before the job can run", Files.exists(marker))

        val denied = try {
            FileInputStream(sessions.resolve("s1.jsonl").toFile()).use { it.readBytes() }
            false
        } catch (failure: IOException) {
            true
        }
        assertTrue("a same-UID read of the sealed root must fail", denied)
        val shell = ProcessBuilder("/system/bin/sh", "-c", "cat '${sessions.resolve("s1.jsonl")}' >/dev/null 2>&1")
            .start()
        assertTrue("a second process must not read it either", shell.waitFor() != 0)

        assertEquals(SealOutcome.Sealed, adapter.restore("uj-device-1"))
        assertEquals("the mode comes back", ORIGINAL_MODE, PosixModeControl.read(sessions))
        assertEquals(
            "the file is readable again",
            "device secret",
            String(FileInputStream(sessions.resolve("s1.jsonl").toFile()).use { it.readBytes() }, Charsets.UTF_8),
        )
        assertFalse("a completed restore removes the marker", Files.exists(marker))
        assertFalse("the seal's own chmods are not accesses", adapter.observed("uj-device-1"))
    }

    @Test
    fun theRealObserverReportsAGuestChmodThroughTheAdapter() = runBlocking {
        val (adapter, tripwire) = adapter()
        assertEquals(SealOutcome.Sealed, adapter.seal("uj-device-2"))
        // Let the seal's own chmod arrive and be excused before the guest acts:
        // inotify delivers in cause order and the excuse is keyed by entry name.
        Thread.sleep(SEAL_SETTLE_MS)

        val guest = ProcessBuilder("/system/bin/sh", "-c", "chmod 755 '${sessions.toAbsolutePath()}'")
            .redirectErrorStream(true)
            .start()
        assertEquals("the guest chmod must succeed", 0, guest.waitFor())
        assertTrue("the audit must see the guest's chmod", awaitObserved(tripwire))

        assertEquals(SealOutcome.Sealed, adapter.restore("uj-device-2"))
        assertTrue("the closed window still reports the access", adapter.observed("uj-device-2"))
        assertEquals("the restore wins over the guest's 755", ORIGINAL_MODE, PosixModeControl.read(sessions))
    }

    @Test
    fun aSealAKilledProcessLeftBehindIsRepairedByTheNextAdapter() = runBlocking {
        val (first, _) = adapter()
        assertEquals(SealOutcome.Sealed, first.seal("uj-device-3"))
        assertEquals("the crash fixture must be sealed", 0, PosixModeControl.read(sessions))
        assertTrue(Files.exists(marker))

        // A new adapter over the same workspace is the next boot: no handle, the
        // marker and the 000 root are the whole state it has.
        val (second, _) = adapter()
        assertTrue("the boot repair must succeed", second.repair())
        assertEquals(ORIGINAL_MODE, PosixModeControl.read(sessions))
        assertFalse("the repair consumes the marker", Files.exists(marker))
    }

    @Test
    fun restoreIsIdempotentOnDevice() = runBlocking {
        val (adapter, _) = adapter()
        assertEquals(SealOutcome.Sealed, adapter.seal("uj-device-4"))
        assertEquals(SealOutcome.Sealed, adapter.restore("uj-device-4"))
        PosixModeControl.write(sessions, 0b110_000_000)
        assertEquals(SealOutcome.Sealed, adapter.restore("uj-device-4"))
        assertEquals("a second restore must not re-chmod", 0b110_000_000, PosixModeControl.read(sessions))
    }

    /** Polls the audit for up to two seconds; inotify delivery is asynchronous. */
    private fun awaitObserved(tripwire: BuildSealTripwire): Boolean {
        val deadline = System.currentTimeMillis() + 2_000L
        while (System.currentTimeMillis() < deadline) {
            if (tripwire.observedSoFar()) return true
            Thread.sleep(20)
        }
        return false
    }

    private companion object {
        /** `chmod 750`: the mode the seal must put back. */
        const val ORIGINAL_MODE: Int = 0b111_101_000

        /** Long enough for the kernel to deliver the seal's own IN_ATTRIB. */
        const val SEAL_SETTLE_MS: Long = 300L
    }
}
