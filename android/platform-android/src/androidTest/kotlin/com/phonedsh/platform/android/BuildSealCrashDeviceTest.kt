// Device evidence that a seal survives a process kill **and gets repaired**.
// SPDX-License-Identifier: MIT
//
// Plan §3 layer 3 item 3 calls this the layer's biggest engineering risk: one
// crash between `chmod 000` and the restore would leave the user's sessions
// unreadable forever. The repair is the marker, and the only honest way to prove
// it is to let a real process death happen between the two phases:
//
//   adb shell am instrument -w -e class <this> -e l46phase seal <pkg>/<runner>
//   adb shell am force-stop com.phonedsh.probe          # the crash, externally
//   adb shell run-as com.phonedsh.probe ls -ld ...      # still 000, outside the app
//   adb shell am instrument -w -e class <this> -e l46phase recover <pkg>/<runner>
//
// Both phases use one deterministic directory under `filesDir`, because the
// point is that it outlives the process. The phase is selected by an
// instrumentation argument so a normal full-suite run skips both (an `@Ignore`
// would also skip them when they are the whole point of the invocation).

package com.phonedsh.platform.android

import android.content.Context
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import java.io.FileInputStream
import java.nio.file.Files
import java.nio.file.Path
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class BuildSealCrashDeviceTest {

    private fun phase(): String? =
        InstrumentationRegistry.getArguments().getString(PHASE_ARGUMENT)

    private fun fixture(context: Context): Pair<Path, Path> {
        val root = context.filesDir.toPath().resolve(FIXTURE)
        val home = Files.createDirectories(root.resolve("materialized/home"))
        val sessions = Files.createDirectories(home.resolve(SealTargets.SESSIONS))
        return home to sessions
    }

    private fun sealer(home: Path, root: Path): BuildSeal = BuildSeal(
        targets = SealTargets(
            home = home,
            roots = listOf(SealRoot(SealTargets.SESSIONS, home.resolve(SealTargets.SESSIONS), required = true)),
        ),
        markerPath = root.resolve(BuildSeal.MARKER_NAME),
    )

    /**
     * Seals and then *does not restore*, leaving exactly what a crash leaves.
     */
    @Test
    fun phaseSeal() = runBlocking {
        assumeTrue("only the seal phase", phase() == PHASE_SEAL)
        val context = ApplicationProvider.getApplicationContext<Context>()
        val root = context.filesDir.toPath().resolve(FIXTURE)
        val (home, sessions) = fixture(context)
        // Start from a clean fixture; a failed earlier run may have left 000.
        PosixModeControl.write(sessions, 0b111_000_000)
        Files.write(sessions.resolve("s1.jsonl"), "device secret".toByteArray(Charsets.UTF_8))
        Files.deleteIfExists(root.resolve(BuildSeal.MARKER_NAME))

        val handle = sealer(home, root).seal("crash-device-job")

        assertEquals("the seal must be real", 0, PosixModeControl.read(sessions))
        assertTrue("the marker must be durable", Files.exists(root.resolve(BuildSeal.MARKER_NAME)))
        assertEquals(listOf(SealTargets.SESSIONS), handle.protectedLabels)
        // No restore: the process is force-stopped after this returns.
    }

    /**
     * The next boot: a fresh process finds the marker and repairs the modes.
     */
    @Test
    fun phaseRecover() = runBlocking {
        assumeTrue("only the recover phase", phase() == PHASE_RECOVER)
        val context = ApplicationProvider.getApplicationContext<Context>()
        val root = context.filesDir.toPath().resolve(FIXTURE)
        val (home, sessions) = fixture(context)
        val marker = root.resolve(BuildSeal.MARKER_NAME)

        assertTrue(
            "the seal phase must have run first and been killed; run " +
                "-e $PHASE_ARGUMENT $PHASE_SEAL first",
            Files.exists(marker),
        )
        assertEquals("the crashed seal must still be 000", 0, PosixModeControl.read(sessions))

        val recovery = sealer(home, root).recoverIfNeeded()

        val repaired = recovery as? SealRecovery.Repaired
            ?: throw AssertionError("recovery must repair, got $recovery")
        assertEquals("crash-device-job", repaired.job)
        assertEquals("the mode must be back", 0b111_000_000, PosixModeControl.read(sessions))
        assertFalse("the marker must be consumed", Files.exists(marker))
        val bytes = FileInputStream(sessions.resolve("s1.jsonl").toFile()).use { it.readBytes() }
        assertEquals("the bytes must be readable again", "device secret", String(bytes, Charsets.UTF_8))
        assertNull("a repaired seal must not stay active", sealer(home, root).active())
    }

    private companion object {
        const val PHASE_ARGUMENT = "l46phase"
        const val PHASE_SEAL = "seal"
        const val PHASE_RECOVER = "recover"

        /** Deterministic, because the point is that it outlives the process. */
        const val FIXTURE = "l46-crash-seal"

    }
}
