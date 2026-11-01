// A real java.nio durability backend used to test the atomicReplace contract.
// SPDX-License-Identifier: MIT
//
// Test-only on purpose: the production Android backend must report
// LEVEL_2_POWER_LOSS_MEASURED only after a device power-loss bench (plan D2a),
// and that decision does not belong in a JVM test fixture. It performs the full
// ordering the SPI promises: file fsync, atomic rename, parent-directory fsync.

package com.phonedsh.platform

import java.nio.channels.FileChannel
import java.nio.file.Files
import java.nio.file.Path
import java.nio.file.StandardCopyOption
import java.nio.file.StandardOpenOption

/**
 * POSIX implementation of [Durability] over a caller-supplied directory tree.
 *
 * It reports [LEVEL_2_POWER_LOSS_UNVERIFIED] by default: the ordering is the
 * production ordering, but no power-loss measurement took place here.
 */
class LocalDurability(
    private val reportedLevel: DurabilityLevel = DurabilityLevel.LEVEL_2_POWER_LOSS_UNVERIFIED,
) : Durability {
    override fun level(): DurabilityLevel = reportedLevel

    override suspend fun fsyncPath(path: Path) {
        if (Files.isDirectory(path)) {
            FileChannel.open(path, StandardOpenOption.READ).use { it.force(true) }
        } else {
            FileChannel.open(path, StandardOpenOption.WRITE).use { it.force(true) }
        }
    }

    override suspend fun atomicReplace(target: Path, write: (Path) -> Unit) {
        val absolute = target.toAbsolutePath()
        val parent = absolute.parent
            ?: throw IllegalArgumentException("target has no parent directory: $target")
        Files.createDirectories(parent)
        val temp = Files.createTempFile(parent, ".${absolute.fileName}.", ".tmp")
        var published = false
        try {
            write(temp)
            fsyncPath(temp)
            Files.move(
                temp,
                absolute,
                StandardCopyOption.ATOMIC_MOVE,
                StandardCopyOption.REPLACE_EXISTING,
            )
            published = true
            fsyncPath(parent)
        } finally {
            if (!published) {
                Files.deleteIfExists(temp)
            }
        }
    }
}
