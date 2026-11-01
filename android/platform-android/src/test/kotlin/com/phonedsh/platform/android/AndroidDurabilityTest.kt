// Host-JVM tests for the atomicReplace ordering and the two sync seams.
// SPDX-License-Identifier: MIT
//
// android.system.Os is a device-only stub on the host, so the directory fsync is
// injected here; AndroidDurabilityDeviceTest proves the real Os path on an
// emulator. The ordering assertions are what the SPI contract actually promises:
// old bytes or new bytes, never a half file, and the parent directory published
// only after the rename.

package com.phonedsh.platform.android

import java.io.IOException
import java.nio.file.Files
import java.nio.file.Path
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class AndroidDurabilityTest {

    @get:Rule
    val temporary = TemporaryFolder()

    private val root: Path
        get() = temporary.root.toPath()

    /** Shared observation log; the seam callbacks append into it. */
    private class Recording {
        val events = mutableListOf<String>()
    }

    private fun durability(
        recording: Recording,
        onDirectorySync: (Path) -> Unit = {},
    ): AndroidDurability = AndroidDurability(
        fileSync = FileSync { path -> recording.events += "file:${path.fileName}" },
        directorySync = DirectorySync { directory ->
            recording.events += "directory:${directory.fileName}"
            onDirectorySync(directory)
        },
    )

    @Test
    fun aSuccessfulReplacePublishesTheNewBytesAndFsyncsTheDirectory() = runBlocking {
        val target = root.resolve("manifest.bin")
        writeText(target, "old")
        val recording = Recording()

        durability(recording).atomicReplace(target) { temp ->
            writeText(temp, "new")
        }

        assertEquals("new", readText(target))
        assertEquals("the temp file must be gone", listOf("manifest.bin"), children(root))
        assertEquals(
            "the order is fsync(file) -> fsync(directory)",
            listOf("file", "directory"),
            recording.events.map { it.substringBefore(':') },
        )
        assertTrue(
            "the file fsync must target the temp file",
            recording.events[0].endsWith(".tmp"),
        )
    }

    @Test
    fun theDirectoryIsFsyncedOnlyAfterTheRenameIsVisible() = runBlocking {
        val target = root.resolve("manifest.bin")
        writeText(target, "old")
        var bytesWhenDirectorySynced: String? = null

        durability(Recording()) { _ ->
            bytesWhenDirectorySynced = readText(target)
        }.atomicReplace(target) { temp ->
            writeText(temp, "new")
        }

        assertEquals(
            "the directory must be fsynced after the rename publishes the new bytes",
            "new",
            bytesWhenDirectorySynced,
        )
    }

    @Test
    fun aWriteFailureKeepsTheOldBytesAndLeavesNoTempFile() = runBlocking {
        val target = root.resolve("manifest.bin")
        writeText(target, "old-bytes")
        val recording = Recording()

        val failure = try {
            durability(recording).atomicReplace(target) { temp ->
                writeText(temp, "new-but-partial")
                throw IOException("simulated power loss")
            }
            null
        } catch (expected: IOException) {
            expected
        }

        assertTrue("the injected failure must propagate", failure != null)
        assertEquals("old-bytes", readText(target))
        assertEquals("no half file may survive", listOf("manifest.bin"), children(root))
        assertTrue("nothing may be fsynced after a failed write", recording.events.isEmpty())
    }

    @Test
    fun aWriteFailureAgainstAnAbsentTargetCreatesNothing() = runBlocking {
        val target = root.resolve("manifest.bin")

        val failure = try {
            durability(Recording()).atomicReplace(target) { temp ->
                writeText(temp, "partial")
                throw IOException("simulated power loss")
            }
            null
        } catch (expected: IOException) {
            expected
        }

        assertTrue("the injected failure must propagate", failure != null)
        assertFalse("the target must not appear", Files.exists(target))
        assertEquals("no temp file may survive", emptyList<String>(), children(root))
    }

    @Test
    fun aFailedRenameLeavesTheOldTreeIntactAndRemovesTheTempFile() = runBlocking {
        val target = root.resolve("manifest.bin")
        Files.createDirectories(target)
        writeText(target.resolve("keep"), "old")

        val failure = try {
            durability(Recording()).atomicReplace(target) { temp ->
                writeText(temp, "new")
            }
            null
        } catch (expected: Exception) {
            expected
        }

        assertTrue("moving a file over a non-empty directory must fail", failure != null)
        assertEquals("old", readText(target.resolve("keep")))
        assertEquals(
            "the failed rename must not leave a temp file",
            listOf("manifest.bin"),
            children(root),
        )
    }

    @Test
    fun fsyncPathRoutesFilesAndDirectoriesToTheirSeam() = runBlocking {
        val file = root.resolve("wal.segment")
        writeText(file, "record")
        val recording = Recording()
        val durability = durability(recording)

        durability.fsyncPath(file)
        durability.fsyncPath(root)

        assertEquals(
            "a directory must go through the Os directory seam, a file through the file seam",
            listOf("file:wal.segment", "directory:${root.fileName}"),
            recording.events,
        )
    }

    // java.nio.file.Files in the Android SDK has no readString/writeString
    // (Java 11 additions), so the fixtures use bytes explicitly.
    private fun writeText(path: Path, text: String) {
        Files.write(path, text.toByteArray(Charsets.UTF_8))
    }

    private fun readText(path: Path): String = String(Files.readAllBytes(path), Charsets.UTF_8)

    private fun children(directory: Path): List<String> =
        (directory.toFile().listFiles() ?: emptyArray()).map { it.name }.sorted()
}
