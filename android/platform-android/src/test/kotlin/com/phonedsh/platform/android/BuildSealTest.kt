// Host-JVM tests for the seal: denial, idempotency, fail-closed, crash recovery.
// SPDX-License-Identifier: MIT
//
// These run against the real filesystem with the real [PosixModeControl], so
// "sealed" means a `chmod 000` that the JVM's own `open()` honours. The device
// suite (`BuildSealDeviceTest`) repeats it under the app's UID on Android,
// where Selinux and the per-app domain are the things being proven -- but the
// denial itself is already a real denial here, not a fake returning false.
//
// `restore()` and `recover()` are the other half: a seal that cannot be undone
// is worse than no seal (§3 layer 3 item 3), so every failure path here keeps
// the marker alive for the next boot.

package com.phonedsh.platform.android

import com.phonedsh.platform.Durability
import java.io.FileInputStream
import java.io.FileNotFoundException
import java.io.IOException
import java.nio.file.Files
import java.nio.file.Path
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Assume.assumeTrue
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class BuildSealTest {

    @get:Rule
    val temporary = TemporaryFolder()

    private lateinit var home: Path
    private lateinit var sessions: Path
    private lateinit var storages: Path
    private lateinit var marker: Path

    private val events = mutableListOf<String>()

    /** Real files, real chmod; only the fsyncs are faked, as the module does. */
    private val durability: Durability = AndroidDurability(
        fileSync = FileSync { },
        directorySync = DirectorySync { },
    )

    @Before
    fun setUp() {
        val root = temporary.root.toPath()
        home = Files.createDirectories(root.resolve("materialized/home"))
        sessions = Files.createDirectories(home.resolve("sessions"))
        storages = Files.createDirectories(home.resolve("storages"))
        marker = root.resolve(BuildSeal.MARKER_NAME)
        PosixModeControl.write(sessions, 0b111_000_000)
        PosixModeControl.write(storages, 0b111_000_000)
        Files.write(sessions.resolve("s1.jsonl"), "session secret".toByteArray(Charsets.UTF_8))
    }

    private fun sealer(
        roots: List<SealRoot> = listOf(
            SealRoot(SealTargets.SESSIONS, sessions, required = true),
            SealRoot(SealTargets.STORAGES, storages, required = true),
        ),
        modes: ModeControl = PosixModeControl,
        selfEvents: SealSelfEvents? = null,
    ): BuildSeal = BuildSeal(
        targets = SealTargets(home = home, roots = roots),
        markerPath = marker,
        durability = durability,
        modes = modes,
        nowMs = { 1_700_000_000_000L },
        log = { events.add(it) },
        selfEvents = selfEvents,
    )

    /** A mode primitive that refuses the restore chmod of `sessions` while [failing]. */
    private fun failingSessionsRestore(failing: () -> Boolean): ModeControl =
        object : ModeControl by PosixModeControl {
            override fun write(path: Path, mode: Int) {
                if (failing() && mode != BuildSeal.SEALED_MODE && path == sessions) {
                    throw IOException("synthetic restore failure")
                }
                PosixModeControl.write(path, mode)
            }
        }

    /** Root is not a useful environment for a permission test: skip there. */
    private fun requirePermissionEnforcement() {
        assumeTrue(
            "the test user can read a 000 file, so this OS does not enforce permissions",
            PosixModeControl.let { control ->
                val probe = Files.createDirectories(home.resolve("probe-dir"))
                control.write(probe, 0)
                val denied = try {
                    Files.newDirectoryStream(probe).close()
                    false
                } catch (failure: IOException) {
                    true
                }
                control.write(probe, 0b111_000_000)
                denied
            },
        )
    }

    @Test
    fun aSealedRootCannotBeOpened() = runBlocking {
        requirePermissionEnforcement()
        val handle = sealer().seal("job-1")
        assertEquals("both roots must be sealed", listOf("sessions", "storages"), handle.protectedLabels)
        assertEquals("the root must be 000", 0, PosixModeControl.read(sessions))

        val failure = try {
            FileInputStream(sessions.resolve("s1.jsonl").toFile()).use { it.readBytes() }
            null
        } catch (failure: FileNotFoundException) {
            failure
        }
        assertTrue("a sealed root must not open, got $failure", failure != null)
        assertFalse(
            "no byte may be readable while sealed",
            Files.isReadable(sessions.resolve("s1.jsonl")),
        )
    }

    @Test
    fun restoreMakesTheSameFileReadableAgain() = runBlocking {
        requirePermissionEnforcement()
        val seal = sealer()
        val handle = seal.seal("job-1")
        seal.restore(handle)

        assertEquals("the original mode must be back", 0b111_000_000, PosixModeControl.read(sessions))
        val bytes = FileInputStream(sessions.resolve("s1.jsonl").toFile()).use { it.readBytes() }
        assertEquals("session secret", String(bytes, Charsets.UTF_8))
        assertFalse("the marker must be gone after a restore", Files.exists(marker))
        assertTrue("the handle must report the restore", handle.isRestored)
        assertNull("the seal must not still be active", seal.active())
    }

    @Test
    fun restoreIsIdempotent() = runBlocking {
        requirePermissionEnforcement()
        val writes = mutableListOf<Pair<Path, Int>>()
        val recording = object : ModeControl by PosixModeControl {
            override fun write(path: Path, mode: Int) {
                writes.add(path to mode)
                PosixModeControl.write(path, mode)
            }
        }
        val seal = sealer(modes = recording)
        val handle = seal.seal("job-1")
        val afterSeal = writes.size
        seal.restore(handle)
        val afterFirstRestore = writes.size
        seal.restore(handle)
        assertEquals(
            "a second restore must not chmod again",
            afterFirstRestore,
            writes.size,
        )
        assertTrue("the first restore must have written something", afterFirstRestore > afterSeal)
        assertEquals(0b111_000_000, PosixModeControl.read(sessions))
    }

    @Test
    fun aMissingRequiredRootFailsClosed() = runBlocking {
        val missing = home.resolve("never-created")
        val seal = sealer(
            roots = listOf(SealRoot(SealTargets.SESSIONS, missing, required = true)),
        )
        val failure = try {
            seal.seal("job-1")
            null
        } catch (failure: SealException) {
            failure
        }
        assertEquals(SealFailure.ROOT_MISSING, failure?.failure)
        assertNull("a refused seal must not be active", seal.active())
        assertFalse("no marker may exist for a refused seal", Files.exists(marker))
        assertEquals(
            "a root that was not sealed must keep its mode",
            0b111_000_000,
            PosixModeControl.read(sessions),
        )
    }

    @Test
    fun anAbsentOptionalRootIsRecordedButNotSealed() = runBlocking {
        val handle = sealer(
            roots = listOf(
                SealRoot(SealTargets.SESSIONS, sessions, required = true),
                SealRoot(SealTargets.TOOL_JOURNAL, home.resolve("tool-journal"), required = false),
            ),
        ).seal("job-1")
        assertEquals(listOf("sessions"), handle.protectedLabels)
        val absent = handle.entries.first { it.label == SealTargets.TOOL_JOURNAL }
        assertNull("an absent optional root has no original mode", absent.originalMode)
        assertFalse("an absent optional root is not sealed", absent.isSealed)
    }

    @Test
    fun theMarkerIsWrittenBeforeTheFirstChmod() = runBlocking {
        var markerExistedAtFirstChmod: Boolean? = null
        val watching = object : ModeControl by PosixModeControl {
            override fun write(path: Path, mode: Int) {
                if (markerExistedAtFirstChmod == null) markerExistedAtFirstChmod = Files.exists(marker)
                PosixModeControl.write(path, mode)
            }
        }
        sealer(modes = watching).seal("job-1")
        assertEquals(
            "the crash marker must be durable before the seal hides anything",
            true,
            markerExistedAtFirstChmod,
        )
    }

    @Test
    fun aCrashBetweenSealAndRestoreIsRepairedOnTheNextBoot() = runBlocking {
        requirePermissionEnforcement()
        // The crashing process: seals and dies before restore.
        sealer().seal("job-1")
        assertEquals("the fixture must be left sealed", 0, PosixModeControl.read(sessions))
        assertTrue("the marker must outlive the crash", Files.exists(marker))

        // The next boot: a fresh instance, no handle, no knowledge of job-1.
        val recovery = sealer().recoverIfNeeded()

        val repaired = recovery as? SealRecovery.Repaired
            ?: throw AssertionError("recovery must repair, got $recovery")
        assertEquals("job-1", repaired.job)
        assertEquals(2, repaired.roots.size)
        assertEquals("the mode must be back", 0b111_000_000, PosixModeControl.read(sessions))
        assertEquals("every root must be back", 0b111_000_000, PosixModeControl.read(storages))
        assertFalse("the marker must be consumed", Files.exists(marker))
        val bytes = FileInputStream(sessions.resolve("s1.jsonl").toFile()).use { it.readBytes() }
        assertEquals("session secret", String(bytes, Charsets.UTF_8))
    }

    @Test
    fun recoveryDoesNothingWithoutAMarker() = runBlocking {
        assertEquals(SealRecovery.NothingToDo, sealer().recoverIfNeeded())
    }

    @Test
    fun recoveryOnlyTouchesRootsThatAreStillSealed() = runBlocking {
        requirePermissionEnforcement()
        sealer().seal("job-1")
        // Half of the seal was undone by something else before the boot.
        PosixModeControl.write(storages, 0b111_000_000)

        val repaired = sealer().recoverIfNeeded() as SealRecovery.Repaired
        val byLabel = repaired.roots.associateBy { it.label }
        assertEquals(
            "sessions was still 000 and must be repaired",
            0,
            byLabel.getValue(SealTargets.SESSIONS).modeBefore,
        )
        assertEquals(
            "storages was already back and must not be chmod'd",
            byLabel.getValue(SealTargets.STORAGES).modeBefore,
            byLabel.getValue(SealTargets.STORAGES).modeAfter,
        )
        assertEquals(0b111_000_000, PosixModeControl.read(sessions))
    }

    @Test
    fun recoveryIsIdempotent() = runBlocking {
        sealer().seal("job-1")
        assertTrue(sealer().recoverIfNeeded() is SealRecovery.Repaired)
        assertEquals(SealRecovery.NothingToDo, sealer().recoverIfNeeded())
    }

    @Test
    fun aChmodFailureRollsBackTheRootsAlreadySealed() = runBlocking {
        val failing = object : ModeControl by PosixModeControl {
            override fun write(path: Path, mode: Int) {
                if (mode == 0 && path == storages) throw IOException("synthetic chmod failure")
                PosixModeControl.write(path, mode)
            }
        }
        val seal = sealer(modes = failing)
        val failure = try {
            seal.seal("job-1")
            null
        } catch (failure: SealException) {
            failure
        }
        assertNotEquals("the seal must be refused", null, failure)
        assertNull("a rolled-back seal must not stay active", seal.active())
        assertEquals(
            "the root sealed before the failure must be back at its mode",
            0b111_000_000,
            PosixModeControl.read(sessions),
        )
        assertFalse("a complete rollback removes the marker", Files.exists(marker))
    }

    @Test
    fun aRootThatDoesNotReadBackAsSealedIsRefused() = runBlocking {
        val lying = object : ModeControl by PosixModeControl {
            override fun read(path: Path): Int = if (path == sessions) 0b111_000_000 else PosixModeControl.read(path)
        }
        val failure = try {
            sealer(modes = lying).seal("job-1")
            null
        } catch (failure: SealException) {
            failure
        }
        assertEquals(SealFailure.VERIFY_FAILED, failure?.failure)
        assertEquals("a refused seal must not leave a root sealed", 0b111_000_000, PosixModeControl.read(sessions))
    }

    @Test
    fun aSecondSealWhileOneIsActiveIsRefused() = runBlocking {
        val seal = sealer()
        seal.seal("job-1")
        val failure = try {
            seal.seal("job-2")
            null
        } catch (failure: SealException) {
            failure
        }
        assertEquals(SealFailure.ALREADY_SEALED, failure?.failure)
        assertEquals("job-1", seal.active()?.job)
    }

    @Test
    fun aFailedRestoreBlocksTheNextSealUntilRecovery() = runBlocking {
        var failRestore = true
        val seal = sealer(modes = failingSessionsRestore { failRestore })
        val handle = seal.seal("job-a")

        val restoreFailure = try {
            seal.restore(handle)
            null
        } catch (failure: SealException) {
            failure
        }
        assertEquals(SealFailure.RESTORE_FAILED, restoreFailure?.failure)
        assertFalse("a failed restore must stay retryable", handle.isRestored)
        assertTrue("a failed restore keeps the marker", Files.exists(marker))
        assertEquals("sessions failed to restore and stays 000", 0, PosixModeControl.read(sessions))
        assertTrue("a failed restore keeps the handle active", seal.active() === handle)

        val alreadySealed = try {
            seal.seal("job-b")
            null
        } catch (failure: SealException) {
            failure
        }
        assertEquals(SealFailure.ALREADY_SEALED, alreadySealed?.failure)
        assertEquals("job-a", seal.active()?.job)

        // A new process has no active handle, but the roots are still 000: its
        // seal must be refused instead of recording 000 as an "original" mode.
        val markerBefore = Files.readAllBytes(marker)
        val nextBoot = sealer()
        val refused = try {
            nextBoot.seal("job-b")
            null
        } catch (failure: SealException) {
            failure
        }
        assertEquals(SealFailure.VERIFY_FAILED, refused?.failure)
        assertTrue(
            "the refusal must name the boot repair: ${refused?.detail}",
            refused?.detail?.contains("boot repair") == true,
        )
        assertNull("a refused seal must not become active", nextBoot.active())
        assertArrayEquals(
            "a refused seal must leave the original marker untouched",
            markerBefore,
            Files.readAllBytes(marker),
        )

        failRestore = false
        val recovery = seal.recoverIfNeeded()
        assertTrue("the boot repair must succeed, got $recovery", recovery is SealRecovery.Repaired)
        assertEquals(0b111_000_000, PosixModeControl.read(sessions))
        assertEquals(0b111_000_000, PosixModeControl.read(storages))
        assertFalse("recovery consumes the marker", Files.exists(marker))

        val recoveredHandle = seal.seal("job-b")
        assertEquals(listOf("sessions", "storages"), recoveredHandle.protectedLabels)
        seal.restore(recoveredHandle)
        assertEquals(0b111_000_000, PosixModeControl.read(sessions))
    }

    @Test
    fun aZeroModeRootIsNeverRecordedAsItsOriginalMode() = runBlocking {
        PosixModeControl.write(sessions, 0b111_111_111)
        PosixModeControl.write(storages, 0b111_111_111)
        var failRestore = true
        val seal = sealer(modes = failingSessionsRestore { failRestore })
        val handle = seal.seal("job-a")
        val markerBefore = String(Files.readAllBytes(marker), Charsets.UTF_8)
        assertTrue(markerBefore.contains("root 511 sessions"))
        assertTrue(markerBefore.contains("root 511 storages"))

        val failure = try {
            seal.restore(handle)
            null
        } catch (failure: SealException) {
            failure
        }
        assertEquals(SealFailure.RESTORE_FAILED, failure?.failure)

        val refused = try {
            sealer().seal("job-b")
            null
        } catch (failure: SealException) {
            failure
        }
        assertEquals(SealFailure.VERIFY_FAILED, refused?.failure)
        val markerAfter = String(Files.readAllBytes(marker), Charsets.UTF_8)
        assertEquals("a refused seal must not rewrite the marker", markerBefore, markerAfter)
        assertTrue("the previous original mode must not be lost", markerAfter.contains("root 511 sessions"))
        assertTrue("the previous original mode must not be lost", markerAfter.contains("root 511 storages"))
    }

    @Test
    fun recoveryUnblocksSealingWithoutZeroes() = runBlocking {
        PosixModeControl.write(sessions, 0b111_111_111)
        PosixModeControl.write(storages, 0b111_111_111)
        var failRestore = true
        val seal = sealer(modes = failingSessionsRestore { failRestore })
        val handle = seal.seal("job-a")
        val failure = try {
            seal.restore(handle)
            null
        } catch (failure: SealException) {
            failure
        }
        assertEquals(SealFailure.RESTORE_FAILED, failure?.failure)
        assertEquals(0, PosixModeControl.read(sessions))

        failRestore = false
        assertTrue("the boot repair must succeed", seal.recoverIfNeeded() is SealRecovery.Repaired)
        assertEquals(0b111_111_111, PosixModeControl.read(sessions))
        assertEquals(0b111_111_111, PosixModeControl.read(storages))
        assertFalse(Files.exists(marker))

        // Recovery clears the failed handle, so this seal must be accepted and
        // must record the real 511 origins, never the 000 the repair has undone.
        val recoveredHandle = seal.seal("job-b")
        val markerText = String(Files.readAllBytes(marker), Charsets.UTF_8)
        assertTrue(markerText.contains("root 511 sessions"))
        assertTrue(markerText.contains("root 511 storages"))
        seal.restore(recoveredHandle)
        assertEquals(0b111_111_111, PosixModeControl.read(sessions))
        assertEquals(0b111_111_111, PosixModeControl.read(storages))
    }

    @Test
    fun aRestoreFailureKeepsTheMarkerForTheNextBoot() = runBlocking {
        val failing = object : ModeControl by PosixModeControl {
            override fun write(path: Path, mode: Int) {
                if (mode != 0 && path == sessions) throw IOException("synthetic restore failure")
                PosixModeControl.write(path, mode)
            }
        }
        val seal = sealer(modes = failing)
        val handle = seal.seal("job-1")
        val failure = try {
            seal.restore(handle)
            null
        } catch (failure: SealException) {
            failure
        }
        assertEquals(SealFailure.RESTORE_FAILED, failure?.failure)
        assertTrue("the marker must survive a failed restore", Files.exists(marker))
        assertFalse("a failed restore must be retryable", handle.isRestored)
    }

    @Test
    fun theSealAnnouncesItsOwnModeChanges() = runBlocking {
        val announced = mutableListOf<Path>()
        sealer(selfEvents = { path -> announced.add(path) }).let { seal ->
            val handle = seal.seal("job-1")
            seal.restore(handle)
        }
        assertEquals(
            "one announcement per chmod, seal and restore both",
            listOf(sessions, storages, sessions, storages),
            announced,
        )
    }

    @Test
    fun anUnreadableMarkerIsReportedInsteadOfGuessed() = runBlocking {
        Files.write(marker, "not a marker".toByteArray(Charsets.UTF_8))
        val recovery = sealer().recoverIfNeeded()
        assertTrue("an unknown marker must be reported, got $recovery", recovery is SealRecovery.Failed)
        assertEquals(SealFailure.MARKER_UNREADABLE, (recovery as SealRecovery.Failed).failure)
        assertTrue("the unreadable marker must be kept for a human", Files.exists(marker))
    }
}
