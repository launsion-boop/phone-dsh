// Applying wal.md §6.1 mutations to the materialized copy, with D9 in place.
// SPDX-License-Identifier: MIT

package com.phonedsh.log

import com.phonedsh.wire.NativeWal
import com.phonedsh.wire.WalException
import java.io.IOException
import java.nio.ByteBuffer
import java.nio.channels.FileChannel
import java.nio.file.FileAlreadyExistsException
import java.nio.file.FileVisitResult
import java.nio.file.Files
import java.nio.file.LinkOption
import java.nio.file.Path
import java.nio.file.SimpleFileVisitor
import java.nio.file.StandardCopyOption
import java.nio.file.StandardOpenOption
import java.nio.file.attribute.BasicFileAttributes
import java.nio.file.attribute.PosixFilePermission

/**
 * What applying one mutation to the materialized copy must do.
 *
 * `Applied` means the copy changed, `Skipped` is the D9 idempotent no-op, and
 * `Resync` is the §5.1 base mismatch: the watermark must stay below the record
 * and the caller sends `VFS_RESYNC`.
 */
internal sealed interface MaterializeOutcome {
    /** The record was applied. */
    data object Applied : MaterializeOutcome

    /** D9: the bytes are already present, so the record is a no-op. */
    data object Skipped : MaterializeOutcome

    /** §5.1: the copy and the WAL diverged at this appended record. */
    data class Resync(val path: String) : MaterializeOutcome
}

/**
 * The materialized files and directories changed since the last epoch close.
 *
 * `wal.md` §5.2 step 1 fsyncs **every file materialized in the epoch and every
 * changed directory** (create, rename, remove, chmod, including the parent of
 * a chmod), deepest first. This type is that set: an insertion-ordered set of
 * files and directories with the one ordering rule the spec fixes.
 *
 * Deepest-first matters because a child entry can only be published after the
 * directory that holds it; [ordered] sorts by the path's depth below the
 * workspace root, stable for equal depth.
 */
internal class EpochChanges(private val paths: WalPaths) {
    private val files = LinkedHashSet<Path>()
    private val directories = LinkedHashSet<Path>()

    /** Records a file whose bytes changed; [directoryChanged] adds its parent. */
    fun touchFile(path: Path, directoryChanged: Boolean = true) {
        files.add(normalize(path))
        if (directoryChanged) {
            normalize(path).parent?.let { directories.add(it) }
        }
    }

    /** Records a directory entry that was created, renamed or removed. */
    fun touchDirectory(path: Path) {
        val normalized = normalize(path)
        directories.add(normalized)
        normalized.parent?.let { directories.add(it) }
    }

    /** Whether nothing changed in the epoch. */
    val isEmpty: Boolean
        get() = files.isEmpty() && directories.isEmpty()

    /**
     * The §5.2 step 1 fsync order: every file and directory, deepest first.
     */
    fun ordered(): List<Path> {
        val all = ArrayList<Path>(files.size + directories.size)
        all.addAll(files)
        all.addAll(directories)
        return all.sortedByDescending { depth(it) }
    }

    /** Forgets the epoch; the next change set starts empty. */
    fun clear() {
        files.clear()
        directories.clear()
    }

    private fun depth(path: Path): Int = try {
        val root = paths.root.toAbsolutePath().normalize()
        val absolute = path.toAbsolutePath().normalize()
        if (absolute.startsWith(root)) root.relativize(absolute).nameCount else absolute.nameCount
    } catch (_: IllegalArgumentException) {
        path.nameCount
    }

    private fun normalize(path: Path): Path = path.toAbsolutePath().normalize()
}

/**
 * Applies `wal.md` §6.1 mutations to one materialized tree.
 *
 * The tree is `materialized/` for a normal boot or a direct tail replay, and
 * `materialized.staging/` for the §7.2 staged reconcile. Materialization is
 * always derived from WAL records, never an input to a write (`wal.md` §6).
 *
 * D9 (`wal.md` §6.2) is decided by [NativeWal.appendedReplay], not by a local
 * size comparison: the kernel owns the skip/applied/resync verdict, and a
 * second implementation here is exactly the drift the two WAL goldens exist to
 * prevent.
 *
 * Every I/O failure is a host defect (`wal.md` §5.1): [LogException] with
 * [LogFailure.MATERIALIZATION_FAILED]. A missing chmod target and a
 * non-directory where a mkdir belongs are host defects too; a missing remove
 * target is the tombstone replay §6.1 defines.
 */
internal class Materializer(
    private val paths: WalPaths,
    private val root: Path,
    private val changes: EpochChanges,
) {
    /** Applies one mutation body. */
    fun apply(body: MutationBody): MaterializeOutcome = when (body.op) {
        VfsOp.WRITE -> if (body.appended) appendInPlace(body) else writeComplete(body)
        VfsOp.MKDIR -> mkdir(body)
        VfsOp.REMOVE -> remove(body)
        VfsOp.CHMOD -> chmod(body)
    }

    private fun writeComplete(body: MutationBody): MaterializeOutcome {
        val target = targetOf(body)
        val parent = target.parent ?: throw fail("write", target, "target has no parent")
        createParents(parent)
        val temp = try {
            Files.createTempFile(parent, TEMP_PREFIX, TEMP_SUFFIX)
        } catch (error: IOException) {
            throw failure("creating a temporary file for", target, error)
        }
        try {
            FileChannel.open(temp, StandardOpenOption.WRITE).use { channel ->
                writeFully(channel, ByteBuffer.wrap(body.data))
                // §6.1: the temporary file is fsynced before the rename, so a
                // crash leaves the old file or the new file, never a torn one.
                channel.force(true)
            }
            PosixModes.set(temp, body.mode)
            Files.move(temp, target, StandardCopyOption.ATOMIC_MOVE, StandardCopyOption.REPLACE_EXISTING)
        } catch (error: IOException) {
            try {
                Files.deleteIfExists(temp)
            } catch (_: IOException) {
                // The failed temporary file is best-effort cleanup; the record
                // failure below is the real host defect.
            }
            throw failure("replacing", target, error)
        }
        changes.touchFile(target, directoryChanged = true)
        return MaterializeOutcome.Applied
    }

    private fun appendInPlace(body: MutationBody): MaterializeOutcome {
        val target = targetOf(body)
        if (!Files.isRegularFile(target, LinkOption.NOFOLLOW_LINKS)) {
            return MaterializeOutcome.Resync(body.path)
        }
        val size = try {
            Files.size(target)
        } catch (error: IOException) {
            throw failure("reading the size of", target, error)
        }
        if (size < body.appendFrom) {
            return MaterializeOutcome.Resync(body.path)
        }
        val readable = minOf(body.data.size.toLong(), size - body.appendFrom).toInt()
        val existing = try {
            readAt(target, body.appendFrom, readable)
        } catch (error: IOException) {
            throw failure("reading", target, error)
        }
        val verdict = try {
            val reply = WalJson.objectOf(
                WalJson.parse(
                    NativeWal.appendedReplay(size, body.appendFrom, body.data, existing),
                ),
                "D9 verdict",
            )
            WalJson.string(reply, "verdict", "D9 verdict")
        } catch (error: WalException) {
            throw failure("asking the D9 verdict for", target, error)
        }
        return when (verdict) {
            "applied" -> {
                try {
                    FileChannel.open(target, StandardOpenOption.WRITE).use { channel ->
                        channel.position(body.appendFrom)
                        writeFully(channel, ByteBuffer.wrap(body.data))
                    }
                } catch (error: IOException) {
                    throw failure("appending to", target, error)
                }
                changes.touchFile(target, directoryChanged = false)
                MaterializeOutcome.Applied
            }
            "skip" -> MaterializeOutcome.Skipped
            else -> MaterializeOutcome.Resync(body.path)
        }
    }

    private fun mkdir(body: MutationBody): MaterializeOutcome {
        val target = targetOf(body)
        createParents(target.parent ?: throw fail("mkdir", target, "target has no parent"))
        if (Files.isDirectory(target, LinkOption.NOFOLLOW_LINKS)) {
            return MaterializeOutcome.Applied
        }
        if (Files.exists(target, LinkOption.NOFOLLOW_LINKS)) {
            throw fail("mkdir", target, "a non-directory is in the way")
        }
        try {
            Files.createDirectory(target)
            PosixModes.set(target, body.mode)
        } catch (error: FileAlreadyExistsException) {
            // Another writer created it; an existing directory is not an error.
        } catch (error: IOException) {
            throw failure("creating", target, error)
        }
        changes.touchDirectory(target)
        return MaterializeOutcome.Applied
    }

    private fun remove(body: MutationBody): MaterializeOutcome {
        val target = targetOf(body)
        if (!Files.exists(target, LinkOption.NOFOLLOW_LINKS)) {
            return MaterializeOutcome.Applied
        }
        try {
            Files.walkFileTree(
                target,
                object : SimpleFileVisitor<Path>() {
                    override fun visitFile(file: Path, attrs: BasicFileAttributes): FileVisitResult {
                        Files.deleteIfExists(file)
                        return FileVisitResult.CONTINUE
                    }

                    override fun postVisitDirectory(dir: Path, error: IOException?): FileVisitResult {
                        if (error != null) throw error
                        Files.deleteIfExists(dir)
                        return FileVisitResult.CONTINUE
                    }
                },
            )
        } catch (error: IOException) {
            throw failure("removing", target, error)
        }
        changes.touchDirectory(target.parent ?: throw fail("remove", target, "target has no parent"))
        return MaterializeOutcome.Applied
    }

    private fun chmod(body: MutationBody): MaterializeOutcome {
        val target = targetOf(body)
        if (!Files.exists(target, LinkOption.NOFOLLOW_LINKS)) {
            throw fail("chmod", target, "the target does not exist")
        }
        try {
            PosixModes.set(target, body.mode)
        } catch (error: IOException) {
            throw failure("chmod", target, error)
        }
        changes.touchFile(target, directoryChanged = true)
        return MaterializeOutcome.Applied
    }

    private fun targetOf(body: MutationBody): Path = VfsPath.resolve(root, body.path)

    /**
     * Creates every missing ancestor of [directory] below the materialized
     * root, recording each created directory as a §5.2 change.
     */
    private fun createParents(directory: Path) {
        val missing = ArrayList<Path>()
        var cursor: Path? = directory
        val stop = root.toAbsolutePath().normalize()
        while (cursor != null && !cursor.toAbsolutePath().normalize().startsWith(stop)) {
            throw fail("creating parents below", directory, "the path leaves the materialized root")
        }
        while (cursor != null && !Files.exists(cursor, LinkOption.NOFOLLOW_LINKS)) {
            missing.add(cursor)
            cursor = cursor.parent
        }
        for (dir in missing.asReversed()) {
            try {
                Files.createDirectory(dir)
                PosixModes.set(dir, DEFAULT_DIRECTORY_MODE)
            } catch (error: FileAlreadyExistsException) {
                continue
            } catch (error: IOException) {
                throw failure("creating", dir, error)
            }
            changes.touchDirectory(dir)
        }
    }

    private fun readAt(path: Path, offset: Long, length: Int): ByteArray {
        if (length == 0) return ByteArray(0)
        FileChannel.open(path, StandardOpenOption.READ).use { channel ->
            channel.position(offset)
            val bytes = ByteArray(length)
            val buffer = ByteBuffer.wrap(bytes)
            while (buffer.hasRemaining()) {
                if (channel.read(buffer) < 0) break
            }
            return if (buffer.hasRemaining()) bytes.copyOf(buffer.position()) else bytes
        }
    }

    private fun writeFully(channel: FileChannel, buffer: ByteBuffer) {
        while (buffer.hasRemaining()) {
            channel.write(buffer)
        }
    }

    private fun fail(operation: String, path: Path, reason: String): LogException =
        LogException(
            LogFailure.MATERIALIZATION_FAILED,
            "$operation ${paths.label(path)}: $reason",
        )

    private fun failure(operation: String, path: Path, cause: Throwable): LogException =
        LogException(
            LogFailure.MATERIALIZATION_FAILED,
            "$operation ${paths.label(path)} failed: ${cause.message}",
            cause,
        )

    private companion object {
        const val TEMP_PREFIX = ".pdsh-write-"
        const val TEMP_SUFFIX = ".tmp"

        /** Missing parents inherit the usual directory mode; §6.1 fixes no mode. */
        const val DEFAULT_DIRECTORY_MODE = 493
    }
}

/**
 * POSIX mode access for the materialized copy.
 *
 * `wal.md` §6.1 materializes a mutation's `mode`, and the invariant of §7.2
 * compares "bytes and POSIX mode". `unix:mode` carries the full `0o7777` field
 * where the platform supports it; `PosixFilePermissions` is the portable
 * fallback and covers the low nine bits.
 */
internal object PosixModes {
    /** Applies [mode] (at most `0o7777`) to [path]. */
    fun set(path: Path, mode: Int) {
        val masked = mode and MutationBody.MAX_MODE
        try {
            Files.setAttribute(path, "unix:mode", masked)
        } catch (_: UnsupportedOperationException) {
            Files.setPosixFilePermissions(path, permissions(masked))
        } catch (_: IllegalArgumentException) {
            Files.setPosixFilePermissions(path, permissions(masked))
        }
    }

    /** Reads the permission bits of [path], at most `0o7777`. */
    fun read(path: Path): Int = try {
        (Files.getAttribute(path, "unix:mode") as Int) and MutationBody.MAX_MODE
    } catch (_: UnsupportedOperationException) {
        fromPermissions(Files.getPosixFilePermissions(path))
    } catch (_: IllegalArgumentException) {
        fromPermissions(Files.getPosixFilePermissions(path))
    }

    private fun permissions(mode: Int): Set<PosixFilePermission> {
        val result = HashSet<PosixFilePermission>(9)
        if (mode and 0b100_000_000 != 0) result.add(PosixFilePermission.OWNER_READ)
        if (mode and 0b010_000_000 != 0) result.add(PosixFilePermission.OWNER_WRITE)
        if (mode and 0b001_000_000 != 0) result.add(PosixFilePermission.OWNER_EXECUTE)
        if (mode and 0b000_100_000 != 0) result.add(PosixFilePermission.GROUP_READ)
        if (mode and 0b000_010_000 != 0) result.add(PosixFilePermission.GROUP_WRITE)
        if (mode and 0b000_001_000 != 0) result.add(PosixFilePermission.GROUP_EXECUTE)
        if (mode and 0b000_000_100 != 0) result.add(PosixFilePermission.OTHERS_READ)
        if (mode and 0b000_000_010 != 0) result.add(PosixFilePermission.OTHERS_WRITE)
        if (mode and 0b000_000_001 != 0) result.add(PosixFilePermission.OTHERS_EXECUTE)
        return result
    }

    private fun fromPermissions(permissions: Set<PosixFilePermission>): Int {
        var mode = 0
        if (PosixFilePermission.OWNER_READ in permissions) mode = mode or 0b100_000_000
        if (PosixFilePermission.OWNER_WRITE in permissions) mode = mode or 0b010_000_000
        if (PosixFilePermission.OWNER_EXECUTE in permissions) mode = mode or 0b001_000_000
        if (PosixFilePermission.GROUP_READ in permissions) mode = mode or 0b000_100_000
        if (PosixFilePermission.GROUP_WRITE in permissions) mode = mode or 0b000_010_000
        if (PosixFilePermission.GROUP_EXECUTE in permissions) mode = mode or 0b000_001_000
        if (PosixFilePermission.OTHERS_READ in permissions) mode = mode or 0b000_000_100
        if (PosixFilePermission.OTHERS_WRITE in permissions) mode = mode or 0b000_000_010
        if (PosixFilePermission.OTHERS_EXECUTE in permissions) mode = mode or 0b000_000_001
        return mode
    }
}
