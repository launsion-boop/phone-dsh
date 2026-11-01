// fsync, atomic rename and directory fsync over the Android platform.
// SPDX-License-Identifier: MIT
//
// D18 fixes the epoch-close order (spec/v1/wal.md §5.2): fsync every file the
// epoch touched, then publish the manifest with a rename, then fsync the
// containing directory so the rename itself survives. Java can do the first two;
// there is no Java API that fsyncs a directory, so the directory step goes
// through `android.system.Os.open(O_RDONLY)` + `Os.fsync` on the raw fd. That is
// the one primitive Android has and the JVM does not.
//
// Both sync steps are injected seams. The host JVM cannot call `Os`, so the JVM
// suite proves the ordering with recording fakes, and the device suite
// (AndroidDurabilityDeviceTest) proves the real `Os` path on an emulator.

package com.phonedsh.platform.android

import android.system.ErrnoException
import android.system.Os
import android.system.OsConstants
import com.phonedsh.platform.Durability
import com.phonedsh.platform.DurabilityLevel
import java.io.IOException
import java.nio.channels.FileChannel
import java.nio.file.Files
import java.nio.file.Path
import java.nio.file.StandardCopyOption
import java.nio.file.StandardOpenOption
import java.util.UUID
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/**
 * The file fsync primitive, as a seam.
 *
 * Production uses [ChannelFileSync]; a test supplies a recorder to observe the
 * order without a real disk.
 */
fun interface FileSync {
    /** Forces [path] to stable storage; throws [IOException] on failure. */
    fun fsync(path: Path)
}

/**
 * The directory fsync primitive, as a seam.
 *
 * This is the operation Java cannot express. Production uses [OsDirectorySync]
 * (`Os.open` + `Os.fsync`); host JVM tests must inject a fake because
 * `android.system.Os` is a stub there.
 */
fun interface DirectorySync {
    /** Publishes the entries created or renamed in [directory]. */
    fun fsync(directory: Path)
}

/** [FileSync] through `FileChannel.force(true)`; works on device and on a JVM. */
object ChannelFileSync : FileSync {
    override fun fsync(path: Path) {
        FileChannel.open(path, StandardOpenOption.WRITE).use { channel ->
            channel.force(true)
        }
    }
}

/**
 * Directory fsync through the raw POSIX fd.
 *
 * `FileChannel.open` cannot open a directory for writing, and `force()` on a
 * read-only channel is not a documented directory fsync, so the fd comes from
 * `Os.open` directly. This is the D18 requirement Java cannot satisfy.
 */
object OsDirectorySync : DirectorySync {
    override fun fsync(directory: Path) {
        val fd = try {
            Os.open(directory.toAbsolutePath().toString(), OsConstants.O_RDONLY, 0)
        } catch (failure: ErrnoException) {
            throw IOException("cannot open directory for fsync", failure)
        }
        try {
            Os.fsync(fd)
        } catch (failure: ErrnoException) {
            throw IOException("directory fsync failed", failure)
        } finally {
            try {
                Os.close(fd)
            } catch (ignored: ErrnoException) {
                // The sync result is what matters; a close failure cannot undo it.
            }
        }
    }
}

/**
 * [Durability] over the Android filesystem.
 *
 * `atomicReplace` performs the full D18 order: write the sibling temp file,
 * fsync it, rename it over the target, fsync the parent directory. A failure
 * before the rename leaves the old bytes (or nothing) and removes the temp file.
 *
 * The reported level is honest, never aspirational: see [level].
 *
 * @param fileSync file fsync seam; [ChannelFileSync] in production.
 * @param directorySync directory fsync seam; [OsDirectorySync] in production.
 */
class AndroidDurability(
    private val fileSync: FileSync = ChannelFileSync,
    private val directorySync: DirectorySync = OsDirectorySync,
) : Durability {

    /**
     * Reports [DurabilityLevel.LEVEL_2_POWER_LOSS_UNVERIFIED].
     *
     * The implementation *has* the level-2 mechanism: file fsync, atomic rename
     * and parent-directory fsync are exactly the D18 order, and a process kill
     * therefore loses nothing whose close returned. That is a level-1 property
     * proven by the mechanism, not by a bench.
     *
     * [DurabilityLevel.LEVEL_2_POWER_LOSS_MEASURED] is a different claim: "at
     * most the last epoch is lost" under sudden power removal. Whether fsync
     * survives the device's write cache and the filesystem's journal depends on
     * the device class, so the claim may only be returned after a power-cut
     * bench on that class (plan §11-R1, D2a; §14.3-4). No such bench exists for
     * Android, and no API can report it, so this adapter must not return it.
     * Returning it here would be a product-claim bug, not an optimization:
     * `supportsLevel2Claim()` would start lying to the controller.
     */
    override fun level(): DurabilityLevel = DurabilityLevel.LEVEL_2_POWER_LOSS_UNVERIFIED

    override suspend fun fsyncPath(path: Path): Unit = withContext(Dispatchers.IO) {
        fsyncBlocking(path)
    }

    override suspend fun atomicReplace(target: Path, write: (Path) -> Unit): Unit =
        withContext(Dispatchers.IO) {
            val absolute = target.toAbsolutePath()
            val parent = absolute.parent
                ?: throw IllegalArgumentException("target has no parent directory: $target")
            Files.createDirectories(parent)

            val temp = parent.resolve(".${absolute.fileName}.${UUID.randomUUID()}.tmp")
            var renamed = false
            try {
                write(temp)
                fsyncBlocking(temp)
                Files.move(
                    temp,
                    absolute,
                    StandardCopyOption.ATOMIC_MOVE,
                    StandardCopyOption.REPLACE_EXISTING,
                )
                renamed = true
                // Publishing the rename is what makes the new bytes survive a
                // crash; a failure here propagates, as the SPI contract says.
                directorySync.fsync(parent)
            } catch (failure: Throwable) {
                // A throw from `write` may leave a partial temp file; a throw
                // from the rename leaves no temp at all. Removing it is
                // idempotent either way.
                if (!renamed) {
                    try {
                        Files.deleteIfExists(temp)
                    } catch (ignored: IOException) {
                        // Keep the original failure: it is the actionable one.
                    }
                }
                throw failure
            }
        }

    private fun fsyncBlocking(path: Path) {
        if (Files.isDirectory(path)) {
            directorySync.fsync(path)
        } else {
            fileSync.fsync(path)
        }
    }
}
