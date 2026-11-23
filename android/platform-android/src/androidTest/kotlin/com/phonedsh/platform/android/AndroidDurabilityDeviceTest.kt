// Instrumented evidence that the real Os directory fsync works on a device.
// SPDX-License-Identifier: MIT
//
// The host suite injects the directory sync because android.system.Os is a stub
// on the JVM. This test runs the production seam instead: Os.open(O_RDONLY) +
// Os.fsync on the parent directory, plus the full atomicReplace order, on the
// device's own filesystem.

package com.phonedsh.platform.android

import android.content.Context
import android.system.Os
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.phonedsh.platform.DurabilityLevel
import java.io.File
import java.io.IOException
import java.nio.file.Files
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class AndroidDurabilityDeviceTest {

    private lateinit var root: File
    private val durability = AndroidDurability()

    @Before
    fun setUp() {
        val context = ApplicationProvider.getApplicationContext<Context>()
        root = File(context.cacheDir, "durability-${System.nanoTime()}").apply { mkdirs() }
        assertTrue("could not create the fixture directory", root.isDirectory)
    }

    @After
    fun tearDown() {
        root.deleteRecursively()
    }

    @Test
    fun aRealDirectoryFsyncThroughOsSucceeds() = runBlocking {
        // The host JVM cannot run this call at all; on a device it must pass.
        durability.fsyncPath(root.toPath())

        val target = File(root, "manifest.bin")
        target.writeText("old")

        durability.atomicReplace(target.toPath()) { temp ->
            Files.write(temp, "new".toByteArray(Charsets.UTF_8))
        }

        assertEquals("new", target.readText())
        assertEquals(
            "the temp file must be gone",
            listOf("manifest.bin"),
            root.list()!!.sorted(),
        )
        durability.fsyncPath(target.toPath())
    }

    @Test
    fun aReadOnlyMaterializedFileCanBeSyncedWithoutChangingItsMode() = runBlocking {
        val target = File(root, "attachment")
        target.writeText("attachment bytes")
        val ownerReadOnly = 0b100_000_000
        Os.chmod(target.path, ownerReadOnly)
        assertFalse(target.canWrite())

        durability.fsyncPath(target.toPath())

        assertEquals(ownerReadOnly, Os.stat(target.path).st_mode and 0b111_111_111)
        assertEquals("attachment bytes", target.readText())
    }

    @Test
    fun aFileThatCannotBeOpenedStillFailsToSync() = runBlocking {
        val target = File(root, "unreadable")
        target.writeText("bytes")
        Os.chmod(target.path, 0)

        val failure = try {
            durability.fsyncPath(target.toPath())
            null
        } catch (expected: IOException) {
            expected
        }

        assertNotNull("an inaccessible file must not be reported as synced", failure)
        assertEquals(0, Os.stat(target.path).st_mode and 0b111_111_111)
    }

    @Test
    fun anInterruptedDeviceWriteKeepsTheOldBytes() = runBlocking {
        val target = File(root, "manifest.bin")
        target.writeText("old-bytes")

        var failure: Throwable? = null
        try {
            durability.atomicReplace(target.toPath()) { temp ->
                Files.write(temp, "partial".toByteArray(Charsets.UTF_8))
                throw IOException("simulated power loss")
            }
        } catch (expected: IOException) {
            failure = expected
        }

        assertNotNull("the injected failure must propagate", failure)
        assertEquals("old-bytes", target.readText())
        assertEquals(
            "no half file may survive on the device either",
            listOf("manifest.bin"),
            root.list()!!.sorted(),
        )
    }

    @Test
    fun theDeviceLevelIsTheUnverifiedLevelTwo() {
        assertEquals(DurabilityLevel.LEVEL_2_POWER_LOSS_UNVERIFIED, durability.level())
    }
}
