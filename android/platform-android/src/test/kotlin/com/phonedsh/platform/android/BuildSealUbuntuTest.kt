// SPDX-License-Identifier: MIT
// Host-JVM tests for the `ubuntu` lane's seal: the four seam methods, the four
// reason tokens, and the wiring that keeps layer 3's own chmods out of layer 4's
// audit.
// SPDX-License-Identifier: MIT
//
// The seal's own logic is `BuildSealTest`'s subject; this file is about the
// **adapter**, which is the piece that was missing from the production path:
//
//   * `seal(jobId)` / `restore(jobId)` are job-keyed while `BuildSeal` is
//     handle-keyed, so the job -> handle table is what these tests hold to
//     account (including "a second restore touches no mode");
//   * `observed(jobId)` is read *after* the restore, so the verdict has to
//     survive the window's close;
//   * `repair()` must undo what a killed process left, and must not lie about it;
//   * every `SealFailure` must reach `seal.reason` as one of the contract's
//     tokens, never as an enum `toString()`.
//
// A real `chmod 000` on real files (the host JVM's own `open()` honours it); the
// device suite repeats it under the app's UID.

package com.phonedsh.platform.android

import com.phonedsh.platform.Durability
import java.io.FileInputStream
import java.io.IOException
import java.nio.file.Files
import java.nio.file.Path
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class BuildSealUbuntuTest {

    @get:Rule
    val temporary = TemporaryFolder()

    private lateinit var root: Path
    private lateinit var home: Path
    private lateinit var sessions: Path
    private lateinit var storages: Path
    private lateinit var marker: Path

    private val log = mutableListOf<String>()

    /** Real files and real chmod; only the fsyncs are faked, as the module does. */
    private val durability: Durability = AndroidDurability(
        fileSync = FileSync { },
        directorySync = DirectorySync { },
    )

    @Before
    fun setUp() {
        root = temporary.root.toPath()
        home = Files.createDirectories(root.resolve("materialized/home"))
        sessions = Files.createDirectories(home.resolve(SealTargets.SESSIONS))
        storages = Files.createDirectories(home.resolve(SealTargets.STORAGES))
        marker = root.resolve(BuildSeal.MARKER_NAME)
        PosixModeControl.write(sessions, ORIGINAL_MODE)
        PosixModeControl.write(storages, ORIGINAL_MODE)
        Files.write(sessions.resolve("s1.jsonl"), "session secret".toByteArray(Charsets.UTF_8))
    }

    private fun targets(): SealTargets = SealTargets(
        home = home,
        roots = listOf(
            SealRoot(SealTargets.SESSIONS, sessions),
            SealRoot(SealTargets.STORAGES, storages),
        ),
    )

    /**
     * The adapter under test, with the tripwire wired as the seal's own
     * `SealSelfEvents` exactly as [BuildSealUbuntu.forWorkspace] does.
     */
    private fun adapter(
        modes: ModeControl = PosixModeControl,
        tripwire: BuildSealTripwire = BuildSealTripwire(nowMs = { 1_700_000_000_000L }),
        watch: (() -> SealWatch?)? = null,
        selfEvents: SealSelfEvents? = tripwire,
    ): Pair<BuildSealUbuntu, BuildSealTripwire> {
        val seal = BuildSeal(
            targets = targets(),
            markerPath = marker,
            durability = durability,
            modes = modes,
            nowMs = { 1_700_000_000_000L },
            log = { log.add(it) },
            selfEvents = selfEvents,
        )
        return BuildSealUbuntu(
            seal = seal,
            tripwire = tripwire,
            watch = watch,
            // No settle in the JVM suite: inotify delivery is what the settle
            // waits for, and there is no inotify here. The device suite keeps the
            // real value.
            settleMs = 0L,
            log = { log.add(it) },
        ) to tripwire
    }

    /** Root or a permissive userns cannot be denied by a mode bit; skip there. */
    private fun requirePermissionEnforcement() {
        val probe = Files.createDirectories(home.resolve("probe-dir"))
        PosixModeControl.write(probe, 0)
        val denied = try {
            Files.newDirectoryStream(probe).close()
            false
        } catch (failure: IOException) {
            true
        }
        PosixModeControl.write(probe, ORIGINAL_MODE)
        assumeTrue("this OS does not enforce a 000 mode for its own user", denied)
    }

    /** One watch that only counts calls; events are recorded by the test. */
    private class CountingWatch : SealWatch {
        var starts = 0
        var stops = 0
        override fun start() {
            starts += 1
        }

        override fun stop() {
            stops += 1
        }
    }

    @Test
    fun sealThenRestoreChangeTheRealModeAndTheAuditSaysNothingWasSeen() = runBlocking {
        requirePermissionEnforcement()
        val watch = CountingWatch()
        val (adapter, _) = adapter(watch = { watch })

        assertEquals(SealOutcome.Sealed, adapter.seal("uj-1"))
        assertEquals("the job really chmods the root", 0, PosixModeControl.read(sessions))
        assertEquals(0, PosixModeControl.read(storages))
        assertTrue("the marker is written before the first chmod", Files.exists(marker))
        assertEquals("the watch is armed for the job", 1, watch.starts)
        val denied = try {
            FileInputStream(sessions.resolve("s1.jsonl").toFile()).use { it.readBytes() }
            false
        } catch (failure: IOException) {
            true
        }
        assertTrue("a same-UID read of a sealed root must fail", denied)

        assertEquals(SealOutcome.Sealed, adapter.restore("uj-1"))
        assertEquals(ORIGINAL_MODE, PosixModeControl.read(sessions))
        assertEquals(ORIGINAL_MODE, PosixModeControl.read(storages))
        assertFalse("a completed restore removes the marker", Files.exists(marker))
        assertEquals(1, watch.stops)
        assertEquals(
            "nothing touched the roots but the seal itself",
            false,
            adapter.observed("uj-1"),
        )
    }

    @Test
    fun aSecondRestoreTouchesNoMode() = runBlocking {
        val (adapter, _) = adapter()
        assertEquals(SealOutcome.Sealed, adapter.seal("uj-2"))
        assertEquals(SealOutcome.Sealed, adapter.restore("uj-2"))
        // Something else changes the mode after the window closed. A restore that
        // ran twice would put 0750 back and hide that.
        PosixModeControl.write(sessions, 0b110_000_000)
        assertEquals(SealOutcome.Sealed, adapter.restore("uj-2"))
        assertEquals(0b110_000_000, PosixModeControl.read(sessions))
    }

    @Test
    fun theSealsOwnChmodIsNotAnAccess() = runBlocking {
        val (adapter, tripwire) = adapter()
        assertEquals(SealOutcome.Sealed, adapter.seal("uj-3"))
        // What the FileObserver would deliver for the seal's own chmod. The seal
        // announced it through SealSelfEvents, so it must be excused; without
        // that wiring every single job would report an access.
        tripwire.record(SealTargets.SESSIONS, BuildSealTripwire.IN_ATTRIB)
        tripwire.record(SealTargets.STORAGES, BuildSealTripwire.IN_ATTRIB)
        assertFalse("the seal's own chmod is not an access", tripwire.observedSoFar())
        assertEquals(SealOutcome.Sealed, adapter.restore("uj-3"))
        assertFalse(adapter.observed("uj-3"))
    }

    @Test
    fun aGuestChmodAfterTheSealsOwnIsObserved() = runBlocking {
        val (adapter, tripwire) = adapter()
        assertEquals(SealOutcome.Sealed, adapter.seal("uj-4"))
        // The seal's two announcements come first (they are FIFO), then the
        // guest's third chmod of the same name has nothing left to excuse it.
        tripwire.record(SealTargets.SESSIONS, BuildSealTripwire.IN_ATTRIB)
        tripwire.record(SealTargets.STORAGES, BuildSealTripwire.IN_ATTRIB)
        tripwire.record(SealTargets.SESSIONS, BuildSealTripwire.IN_ATTRIB)
        assertTrue(tripwire.observedSoFar())
        assertEquals(SealOutcome.Sealed, adapter.restore("uj-4"))

        // The verdict survives the window's close: the lane reads it after the
        // restore, which is the ordering §12.8 requires.
        assertTrue("the audit must describe the closed window", adapter.observed("uj-4"))
        assertTrue(log.any { it.contains("saw") && it.contains("access") })
    }

    @Test
    fun aReadIsObservedEvenWhenNothingWasChmodded() = runBlocking {
        val (adapter, tripwire) = adapter()
        assertEquals(SealOutcome.Sealed, adapter.seal("uj-5"))
        tripwire.record(SealTargets.SESSIONS, BuildSealTripwire.IN_OPEN)
        assertEquals(SealOutcome.Sealed, adapter.restore("uj-5"))
        assertTrue(adapter.observed("uj-5"))
    }

    @Test
    fun aMiswiredSealCountsItsOwnChmodsAsAccesses() = runBlocking {
        // The negative control for `theSealsOwnChmodIsNotAnAccess`: no
        // SealSelfEvents means no excuse, which is exactly why
        // `forWorkspace` passes the tripwire to the seal.
        val (adapter, tripwire) = adapter(selfEvents = null)
        assertEquals(SealOutcome.Sealed, adapter.seal("uj-6"))
        tripwire.record(SealTargets.SESSIONS, BuildSealTripwire.IN_ATTRIB)
        assertEquals(SealOutcome.Sealed, adapter.restore("uj-6"))
        assertTrue(adapter.observed("uj-6"))
    }

    @Test
    fun aFailingChmodIsReportedAsChmodFailed() = runBlocking {
        val (adapter, _) = adapter(modes = FailingWrites(failAfterWrites = 0))
        assertEquals(SealOutcome.Failed("chmod_failed"), adapter.seal("uj-7"))
        assertEquals("a failed seal changes nothing", ORIGINAL_MODE, PosixModeControl.read(sessions))
        assertTrue(
            "the token is logged with the failure",
            log.any { it.contains("not sealed (chmod_failed)") },
        )
        // No handle was published, so a restore has nothing to undo and answers
        // Sealed without touching a mode.
        assertEquals(SealOutcome.Sealed, adapter.restore("uj-7"))
        assertEquals(ORIGINAL_MODE, PosixModeControl.read(sessions))
    }

    @Test
    fun aRootThatDoesNotReadBackAs000IsReportedAsVerifyFailed() = runBlocking {
        val (adapter, _) = adapter(modes = IgnoringWrites)
        assertEquals(SealOutcome.Failed("verify_failed"), adapter.seal("uj-8"))
        assertEquals(ORIGINAL_MODE, PosixModeControl.read(sessions))
        // The rollback was clean (the writes did not throw), so the marker is gone.
        assertFalse(Files.exists(marker))
    }

    @Test
    fun aFailingRestoreIsReportedAsRestoreFailedAndKeepsTheMarker() = runBlocking {
        val modes = FailingWrites(failAfterWrites = Int.MAX_VALUE)
        val (adapter, _) = adapter(modes = modes)
        assertEquals(SealOutcome.Sealed, adapter.seal("uj-9"))
        assertEquals(0, PosixModeControl.read(sessions))
        modes.failWrites = true

        assertEquals(SealOutcome.Failed("restore_failed"), adapter.restore("uj-9"))
        assertEquals("the root stays sealed when the restore fails", 0, PosixModeControl.read(sessions))
        assertTrue("the marker is kept so the next boot repairs it", Files.exists(marker))
    }

    @Test
    fun aGarbageMarkerIsReportedByRepairAsMarkerUnreadable() = runBlocking {
        Files.write(marker, "not a seal marker\n".toByteArray(Charsets.UTF_8))
        val (adapter, _) = adapter()
        assertFalse("a marker that cannot be read is not a repair", adapter.repair())
        assertTrue(
            "the reason token reaches the log",
            log.any { it.contains("repair failed") && it.contains("marker_unreadable") },
        )
        assertTrue("the marker is kept for the next boot", Files.exists(marker))
    }

    @Test
    fun repairUndoesWhatAKilledSealLeftAt000() = runBlocking {
        // The first process seals and dies: no restore, the marker stays, the
        // roots stay 000. A new adapter over the same workspace is the next boot.
        val (first, _) = adapter()
        assertEquals(SealOutcome.Sealed, first.seal("uj-10"))
        assertEquals(0, PosixModeControl.read(sessions))
        assertTrue(Files.exists(marker))

        val (second, _) = adapter()
        assertTrue("the boot repair must succeed", second.repair())
        assertEquals(ORIGINAL_MODE, PosixModeControl.read(sessions))
        assertEquals(ORIGINAL_MODE, PosixModeControl.read(storages))
        assertFalse("the repair removes the marker", Files.exists(marker))
        assertTrue(log.any { it.contains("repaired job") })
    }

    @Test
    fun repairOnAHealthyBootIsANoOp() = runBlocking {
        val (adapter, _) = adapter()
        assertTrue(adapter.repair())
        assertFalse(log.any { it.contains("repaired job") })
    }

    @Test
    fun anAbsentRootSealsVacuouslyRatherThanFailing() = runBlocking {
        // The worker materializes the internal roots lazily, so "not there yet"
        // means "no bytes to protect yet". `BuildSeal`'s standard targets mark
        // all three optional for exactly this reason.
        val empty = Files.createDirectories(root.resolve("empty/materialized/home"))
        val seal = BuildSeal(
            targets = SealTargets(
                home = empty,
                roots = listOf(SealRoot(SealTargets.SESSIONS, empty.resolve(SealTargets.SESSIONS))),
            ),
            markerPath = root.resolve("empty/${BuildSeal.MARKER_NAME}"),
            durability = durability,
            log = { log.add(it) },
        )
        val tripwire = BuildSealTripwire()
        val adapter = BuildSealUbuntu(seal = seal, tripwire = tripwire, settleMs = 0L)
        assertEquals(SealOutcome.Sealed, adapter.seal("uj-11"))
        assertEquals(SealOutcome.Sealed, adapter.restore("uj-11"))
        assertFalse(adapter.observed("uj-11"))
        assertTrue(log.any { it.contains("protects nothing") })
    }

    @Test
    fun everySealFailureMapsToItsContractToken() {
        // L47's four are the contract; the other four are named so a status reader
        // never sees an enum `toString()`.
        assertEquals("chmod_failed", SealFailure.CHMOD_FAILED.reasonToken())
        assertEquals("verify_failed", SealFailure.VERIFY_FAILED.reasonToken())
        assertEquals("restore_failed", SealFailure.RESTORE_FAILED.reasonToken())
        assertEquals("marker_unreadable", SealFailure.MARKER_UNREADABLE.reasonToken())
        assertEquals("marker_failed", SealFailure.MARKER_FAILED.reasonToken())
        assertEquals("root_missing", SealFailure.ROOT_MISSING.reasonToken())
        assertEquals("already_sealed", SealFailure.ALREADY_SEALED.reasonToken())
        assertEquals("handle_unknown", SealFailure.HANDLE_UNKNOWN.reasonToken())
        assertEquals(
            "every enum value is mapped, and no two share a token",
            SealFailure.entries.size,
            SealFailure.entries.map { it.reasonToken() }.toSet().size,
        )
        // The tokens are what a status line carries: lowercase snake_case, no
        // spaces, never the Kotlin constant name.
        for (failure in SealFailure.entries) {
            val token = failure.reasonToken()
            assertTrue("$failure -> '$token'", Regex("^[a-z][a-z0-9_]*$").matches(token))
        }
    }

    @Test
    fun sealIsIdempotentForOneJob() = runBlocking {
        val (adapter, _) = adapter()
        assertEquals(SealOutcome.Sealed, adapter.seal("uj-12"))
        // The lane's boot recovery can re-seal a job it resumed; a second chmod of
        // an already-000 root is harmless, but the handle must not be replaced.
        assertEquals(SealOutcome.Sealed, adapter.seal("uj-12"))
        assertEquals(0, PosixModeControl.read(sessions))
        assertEquals(SealOutcome.Sealed, adapter.restore("uj-12"))
        assertEquals(ORIGINAL_MODE, PosixModeControl.read(sessions))
    }

    /** A mode primitive whose writes start failing after [failAfterWrites]. */
    private class FailingWrites(private val failAfterWrites: Int) : ModeControl {
        var failWrites: Boolean = false
        private var writes: Int = 0

        override fun read(path: Path): Int = PosixModeControl.read(path)

        override fun write(path: Path, mode: Int) {
            if (failWrites || writes >= failAfterWrites) {
                // `BuildSeal` maps a non-SealException from `modes.write` to
                // CHMOD_FAILED and an IOException on the restore to RESTORE_FAILED.
                throw IOException("no")
            }
            writes += 1
            PosixModeControl.write(path, mode)
        }
    }

    /** A mode primitive that accepts every write and applies none. */
    private object IgnoringWrites : ModeControl {
        override fun read(path: Path): Int = PosixModeControl.read(path)

        override fun write(path: Path, mode: Int) = Unit
    }

    private companion object {
        /** `0750`: the mode the seal must put back. */
        const val ORIGINAL_MODE: Int = 0b111_101_000
    }
}
