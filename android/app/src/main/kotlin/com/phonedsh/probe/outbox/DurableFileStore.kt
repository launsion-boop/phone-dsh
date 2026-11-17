// SPDX-License-Identifier: MIT
// The atomic write order of spec/host/v1/README.md section 7, shared by the
// send outbox (section 10) and the external admission journal (section 12):
// temp file in the same directory, write, fsync, rename, directory fsync.
//
// It is a class with one overridable checkpoint so that a test can stop the
// real sequence at a named step and leave exactly what a killed process would
// leave. Production uses the same code path with the empty checkpoint.
//
// Plain java.io / java.nio only: the stores built on it open with no Android
// framework object, and a host JVM test drives the same bytes the device writes.
package com.phonedsh.probe.outbox

import java.io.File
import java.io.IOException
import java.nio.ByteBuffer
import java.nio.channels.FileChannel
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.nio.file.StandardOpenOption
import java.nio.file.attribute.PosixFilePermission
import java.util.UUID

/** The steps of one atomic write, in order. A checkpoint runs after the named step. */
internal enum class DurableWriteStep {
    /** Nothing has been created for this write yet. */
    BEFORE_TEMP,

    /** The temporary file holds every byte and has been fsynced; the target is unchanged. */
    TEMP_SYNCED,

    /** The rename happened; the containing directory has not been fsynced. */
    RENAMED,

    /** The containing directory has been fsynced. */
    DIRECTORY_SYNCED,
}

internal open class DurableFileStore {
    /**
     * Called after each step of [writeAtomically] with the final target. The
     * default does nothing. A test may throw a non-[IOException] here to model a
     * process kill: nothing in this file or in the stores catches it, so the
     * directory is left as the kill would leave it.
     */
    protected open fun checkpoint(step: DurableWriteStep, target: File) {}

    /**
     * Replaces [target] with [bytes]. After it returns the bytes are in a file
     * named [target] and the rename has been published by a directory fsync.
     * After an [IOException] the target either still holds its previous content
     * or holds the complete new content whose directory fsync was not confirmed;
     * the temporary file has been removed.
     */
    @Throws(IOException::class)
    open fun writeAtomically(target: File, bytes: ByteArray) {
        val directory = target.parentFile ?: throw IOException("target has no parent directory")
        createDirectories(directory)
        checkpoint(DurableWriteStep.BEFORE_TEMP, target)
        // Hidden name: a directory scan never mistakes a half-written file for a record.
        val temporary = File(directory, ".${target.name}.tmp.${UUID.randomUUID()}")
        try {
            FileChannel.open(
                temporary.toPath(),
                StandardOpenOption.CREATE_NEW,
                StandardOpenOption.WRITE,
            ).use { channel ->
                restrictToOwner(temporary)
                val buffer = ByteBuffer.wrap(bytes)
                while (buffer.hasRemaining()) {
                    channel.write(buffer)
                }
                channel.force(true)
            }
            checkpoint(DurableWriteStep.TEMP_SYNCED, target)
            Files.move(
                temporary.toPath(),
                target.toPath(),
                StandardCopyOption.ATOMIC_MOVE,
                StandardCopyOption.REPLACE_EXISTING,
            )
        } catch (failure: IOException) {
            temporary.delete()
            throw failure
        }
        checkpoint(DurableWriteStep.RENAMED, target)
        syncDirectory(directory)
        checkpoint(DurableWriteStep.DIRECTORY_SYNCED, target)
    }

    /** Unlinks [target] and publishes the removal. Returns false when it did not exist. */
    @Throws(IOException::class)
    open fun deleteDurably(target: File): Boolean {
        val directory = target.parentFile ?: throw IOException("target has no parent directory")
        if (!Files.deleteIfExists(target.toPath())) {
            return false
        }
        syncDirectory(directory)
        return true
    }

    /**
     * Forces the entries of [directory] to stable storage. A directory opened
     * read-only can be fsynced through its channel on Linux, Android and macOS.
     */
    @Throws(IOException::class)
    open fun syncDirectory(directory: File) {
        FileChannel.open(directory.toPath(), StandardOpenOption.READ).use { channel ->
            channel.force(true)
        }
    }

    @Throws(IOException::class)
    open fun createDirectories(directory: File) {
        Files.createDirectories(directory.toPath())
    }

    private fun restrictToOwner(file: File) {
        // Mode 0600 where the file system has POSIX modes. The app-private
        // filesDir is already owner-only on a device; a file system without the
        // view keeps its default and is not an error.
        try {
            Files.setPosixFilePermissions(
                file.toPath(),
                setOf(PosixFilePermission.OWNER_READ, PosixFilePermission.OWNER_WRITE),
            )
        } catch (_: UnsupportedOperationException) {
            // No POSIX attribute view on this file system.
        }
    }
}
