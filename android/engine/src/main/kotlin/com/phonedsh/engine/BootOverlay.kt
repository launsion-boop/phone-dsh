// phone-dsh — :engine / com.phonedsh.engine: the wal.md §8 boot overlay.
// SPDX-License-Identifier: MIT
//
// ---- what this file is for -------------------------------------------------
// `spec/v1/wal.md` §8: "After recovery, reconcile and tail replay, the host packs
// the materialized tree as an uncompressed ustar archive (the boot overlay) whose
// entries are only `home/...` and `workspace/...`; the loopback service hands it to
// the worker at boot. … The overlay is rebuilt for each boot and is an input, not
// an authority."
//
// On Android nothing produced that archive, so a reloaded Worker mounted the base
// image only: `/dsh/workspace` was empty in its memory VFS while the host's
// `materialized/workspace` held every file the WAL had replayed. The Worker then
// wrote its empty view back through `VFS_MUT`, and "empty" overwrote "content".
// This packer is the producer; [WebViewEngine] hands the result to the page as the
// one `?overlay=` URL the pinned runtime fetches before boot.
//
// ---- the envelope: one gzip member around the ustar ------------------------
// §8 says "uncompressed ustar", and that is the *archive*: plain ustar, no
// per-entry gzip, no tar.gz inside. The contract's later decision D21 (the one
// iOS ships, `Sources/PhoneDSHLog/OverlayPacker.swift`) wraps that archive in one
// gzip member, because the pinned runtime's `storage/image-gzip.ts` refuses a body
// whose first two bytes are not `1f 8b`:
//
//     webworker image: <source> is not the gzip-compressed tar this deployment
//     serves as its image (expected a member starting 1f 8b, read …)
//
// and `worker-host.ts` reads the boot overlay through that same `readImage`. A
// plain ustar at `?overlay=` therefore does not fail as "plain tar is fine" — it
// fails the boot. The bytes here are therefore `gzip(ustar(entries))`, and the
// ustar inside stays the pre-D21 archive byte for byte.
//
// ---- the subset, and what it refuses --------------------------------------
// Entries are `home/...` and `workspace/...` only — `memory.ts`'s
// `loadVfsOverlay` throws for any other first segment (`IMAGE_OVERLAY_DIRECTORIES`
// is exactly `['home', 'workspace']`), so `tmp/`, `wal/`, `manifest.json` and the
// step records cannot leak into the Worker's memory by accident: the packer never
// looks at them. Directories and regular files carry their POSIX mode; symlinks
// and anything else fail loud, because the Worker VFS has no symlink model and a
// skipped entry would be a silently missing file (iOS rejects them too).
//
// ---- size: fail loud, never truncate --------------------------------------
// A real workspace is not 150 files. The archive is bounded by the caller's
// contract number (the app passes `ControllerBudgets.vfsLogicalBytes`, the cap the
// Worker's own memory VFS is sized for), and a tree above it is refused with
// [BootOverlayException.Refusal.TOO_LARGE] naming both numbers. It is never
// truncated: a truncated overlay is an incomplete tree, and an incomplete tree is
// exactly the "worker writes its empty view over real content" failure this lane
// exists to close. `WebViewEngine` turns the refusal into `Failed`; no Worker boots
// onto a partial view.
//
// ---- determinism ----------------------------------------------------------
// Names are walked in sorted order, mtime is 0, and the gzip header is the fixed
// one `java.util.zip.GZIPOutputStream` writes (mtime 0), so packing the same tree
// twice yields the same bytes. The repair loop in [MaterializedBootOverlaySource]
// relies on that: a snapshot is accepted only when the materialized watermark did
// not move while it was packed.

package com.phonedsh.engine

import java.io.IOException
import java.nio.file.Files
import java.nio.file.LinkOption
import java.nio.file.NoSuchFileException
import java.nio.file.Path
import java.nio.file.StandardCopyOption
import java.nio.file.StandardOpenOption
import java.nio.file.attribute.BasicFileAttributes
import java.nio.file.attribute.PosixFilePermission
import java.util.zip.GZIPOutputStream

/**
 * A boot overlay that could not be produced, with the reason as data.
 *
 * Every refusal is loud by construction: there is no variant that means "packed
 * something close enough". [bytes] and [limit] name the numbers for
 * [Refusal.TOO_LARGE] / [Refusal.TOO_MANY_ENTRIES]; [entry] names the archive
 * path (never an absolute one) that caused [Refusal.SYMLINK], [Refusal.UNSTABLE]
 * or [Refusal.UNSUPPORTED].
 */
class BootOverlayException(
    message: String,
    val refusal: Refusal,
    val entry: String? = null,
    val bytes: Long = 0L,
    val limit: Long = 0L,
    cause: Throwable? = null,
) : IOException(message, cause) {
    /** Why the overlay was refused; stable values, safe to log and to assert on. */
    enum class Refusal {
        /** The archive would exceed the caller's cap. */
        TOO_LARGE,

        /** The tree has more entries than the caller's cap. */
        TOO_MANY_ENTRIES,

        /** A symlink (or a special file) is in the tree; the Worker VFS has no model for one. */
        SYMLINK,

        /** A ustar name that does not fit the 100-byte name + 155-byte prefix split. */
        PATH_TOO_LONG,

        /** A file changed while it was being read; the snapshot is not a snapshot. */
        UNSTABLE,

        /** Reading the tree failed. */
        IO,
    }
}

/** One produced boot overlay, with the numbers the engine logs and the app checks. */
data class BootOverlayPack(
    /** The gzip member on disk. */
    val file: Path,
    /** Number of ustar entries, directories included. */
    val entries: Int,
    /** Sum of the file contents, before headers. */
    val treeBytes: Long,
    /** Size of the uncompressed ustar archive. */
    val archiveBytes: Long,
    /** Size of the gzip member that was written. */
    val compressedBytes: Long,
    val elapsedMillis: Long,
)

/**
 * Packs `materialized/{home,workspace}` as the §8 boot overlay.
 *
 * Nothing here touches `android.*`: the archive is produced on the JVM (and in
 * the JVM tests) from a directory, which is also why this is not in `:core` (the
 * WAL owns the tree; the engine owns the bytes the Worker receives).
 */
class BootOverlayPacker(
    /** The `materialized/` root that holds `home/` and `workspace/`. */
    private val materializedDirectory: Path,
    /** Cap on the uncompressed ustar; a bigger tree is refused, never truncated. */
    private val maxArchiveBytes: Long,
    /** Cap on the entry count; a bigger tree is refused, never truncated. */
    private val maxEntries: Int = DEFAULT_MAX_ENTRIES,
) {
    /**
     * Packs the tree into [target] through a temporary file in the same directory.
     *
     * The target is replaced by an atomic rename, so a reader never sees a
     * half-written overlay and a failed pack leaves no target behind.
     *
     * @param target the gzip member to write; its parent must be creatable.
     * @return the written archive's numbers.
     * @throws BootOverlayException for every refusal (see the class documentation).
     */
    fun pack(target: Path): BootOverlayPack {
        val startedAt = System.nanoTime()
        val absoluteTarget = target.toAbsolutePath().normalize()
        val directory = absoluteTarget.parent
            ?: throw BootOverlayException(
                "the overlay target has no parent directory: ${target.fileName}",
                BootOverlayException.Refusal.IO,
            )
        try {
            Files.createDirectories(directory)
        } catch (failure: IOException) {
            throw BootOverlayException(
                "cannot create the overlay directory",
                BootOverlayException.Refusal.IO,
                cause = failure,
            )
        }
        val temporary = directory.resolve(".${absoluteTarget.fileName}.${System.nanoTime()}.tmp")
        var entries = 0
        var treeBytes = 0L
        var archiveBytes = 0L
        val readBuffer = ByteArray(BUFFER_BYTES)
        try {
            Files.newOutputStream(
                temporary,
                StandardOpenOption.CREATE_NEW,
                StandardOpenOption.WRITE,
            ).use { raw ->
                GZIPOutputStream(raw, BUFFER_BYTES).use { gzip ->
                    // One gzip member around one ustar: every byte of the archive
                    // goes through `emit`, which is where the cap is enforced.
                    fun emit(bytes: ByteArray, offset: Int, length: Int) {
                        gzip.write(bytes, offset, length)
                        archiveBytes += length.toLong()
                        if (archiveBytes > maxArchiveBytes) throw tooLarge(archiveBytes)
                    }

                    fun emitBlock(block: ByteArray) = emit(block, 0, block.size)

                    fun addEntry(entryName: String, mode: Int, size: Long, directory: Boolean) {
                        if (entries >= maxEntries) {
                            throw BootOverlayException(
                                "the boot overlay would exceed $maxEntries entries at \"$entryName\"; " +
                                    "it is not truncated",
                                BootOverlayException.Refusal.TOO_MANY_ENTRIES,
                                entry = entryName,
                                bytes = entries.toLong(),
                                limit = maxEntries.toLong(),
                            )
                        }
                        emitBlock(tarHeader(entryName, mode, if (directory) 0L else size, directory))
                        entries += 1
                    }

                    fun addFile(entryName: String, path: Path, before: BasicFileAttributes) {
                        val declaredSize = before.size()
                        val padding = if (declaredSize % TAR_BLOCK == 0L) 0L else TAR_BLOCK - declaredSize % TAR_BLOCK
                        val needed = archiveBytes + TAR_BLOCK + declaredSize + padding + TAR_TERMINATOR_BYTES
                        if (needed > maxArchiveBytes) throw tooLarge(needed, entryName)
                        addEntry(entryName, modeOf(path, DEFAULT_FILE_MODE), declaredSize, directory = false)
                        var copied = 0L
                        try {
                            Files.newInputStream(path, StandardOpenOption.READ).use { input ->
                                while (true) {
                                    val read = input.read(readBuffer)
                                    if (read < 0) break
                                    if (read == 0) continue
                                    emit(readBuffer, 0, read)
                                    copied += read.toLong()
                                }
                            }
                        } catch (failure: IOException) {
                            throw BootOverlayException(
                                "cannot read the overlay entry \"$entryName\"",
                                BootOverlayException.Refusal.IO,
                                entry = entryName,
                                cause = failure,
                            )
                        }
                        if (copied != declaredSize) throw unstable(entryName)
                        val after = attributesOf(path, entryName)
                        if (!after.isRegularFile ||
                            after.size() != declaredSize ||
                            after.lastModifiedTime() != before.lastModifiedTime()
                        ) {
                            throw unstable(entryName)
                        }
                        val remainder = (copied % TAR_BLOCK).toInt()
                        if (remainder != 0) emitBlock(ByteArray((TAR_BLOCK - remainder).toInt()))
                        treeBytes += copied
                    }

                    fun walk(directoryPath: Path, prefix: String) {
                        val names = try {
                            Files.newDirectoryStream(directoryPath).use { stream ->
                                stream.map { it.fileName.toString() }.sorted()
                            }
                        } catch (failure: IOException) {
                            throw BootOverlayException(
                                "cannot list the overlay directory \"$prefix\"",
                                BootOverlayException.Refusal.IO,
                                entry = prefix,
                                cause = failure,
                            )
                        }
                        for (name in names) {
                            val path = directoryPath.resolve(name)
                            val entryName = "$prefix/$name"
                            val entry = attributesOf(path, entryName)
                            when {
                                entry.isSymbolicLink || entry.isOther -> throw BootOverlayException(
                                    "the boot overlay cannot carry the symlink or special file " +
                                        "\"$entryName\": the Worker VFS has no model for one",
                                    BootOverlayException.Refusal.SYMLINK,
                                    entry = entryName,
                                )
                                entry.isDirectory -> {
                                    addEntry("$entryName/", modeOf(path, DEFAULT_DIRECTORY_MODE), 0L, directory = true)
                                    walk(path, entryName)
                                }
                                entry.isRegularFile -> addFile(entryName, path, entry)
                                else -> throw BootOverlayException(
                                    "the boot overlay entry \"$entryName\" is neither a directory nor a file",
                                    BootOverlayException.Refusal.SYMLINK,
                                    entry = entryName,
                                )
                            }
                        }
                    }

                    for (rootName in ROOTS) {
                        val root = materializedDirectory.resolve(rootName)
                        val entry = rootAttributesOf(root, "$rootName/") ?: continue
                        if (entry.isSymbolicLink || !entry.isDirectory) {
                            throw BootOverlayException(
                                "the overlay root \"$rootName\" is not a directory",
                                BootOverlayException.Refusal.SYMLINK,
                                entry = "$rootName/",
                            )
                        }
                        addEntry("$rootName/", modeOf(root, DEFAULT_DIRECTORY_MODE), 0L, directory = true)
                        walk(root, rootName)
                    }
                    // Two zero blocks terminate a ustar; a reader that walks past
                    // them would read whatever followed the archive.
                    emitBlock(ByteArray(TAR_TERMINATOR_BYTES.toInt()))
                }
            }
            Files.move(
                temporary,
                absoluteTarget,
                StandardCopyOption.REPLACE_EXISTING,
                StandardCopyOption.ATOMIC_MOVE,
            )
        } catch (failure: Throwable) {
            runCatching { Files.deleteIfExists(temporary) }
            throw failure
        }
        return BootOverlayPack(
            file = absoluteTarget,
            entries = entries,
            treeBytes = treeBytes,
            archiveBytes = archiveBytes,
            compressedBytes = Files.size(absoluteTarget),
            elapsedMillis = (System.nanoTime() - startedAt) / 1_000_000L,
        )
    }

    private fun tooLarge(bytes: Long, entry: String? = null): BootOverlayException = BootOverlayException(
        "the boot overlay would be $bytes bytes of ustar, over the $maxArchiveBytes-byte limit" +
            (entry?.let { " (at \"$it\")" } ?: "") +
            "; it is not truncated",
        BootOverlayException.Refusal.TOO_LARGE,
        entry = entry,
        bytes = bytes,
        limit = maxArchiveBytes,
    )

    private fun unstable(entry: String): BootOverlayException = BootOverlayException(
        "the boot overlay entry \"$entry\" changed while it was read; no consistent snapshot exists",
        BootOverlayException.Refusal.UNSTABLE,
        entry = entry,
    )

    private fun attributesOf(path: Path, entryName: String): BasicFileAttributes = try {
        Files.readAttributes(path, BasicFileAttributes::class.java, LinkOption.NOFOLLOW_LINKS)
    } catch (missing: NoSuchFileException) {
        throw BootOverlayException(
            "the boot overlay entry \"$entryName\" vanished while the tree was packed",
            BootOverlayException.Refusal.UNSTABLE,
            entry = entryName,
            cause = missing,
        )
    } catch (failure: IOException) {
        throw BootOverlayException(
            "cannot stat the boot overlay entry \"$entryName\"",
            BootOverlayException.Refusal.IO,
            entry = entryName,
            cause = failure,
        )
    }

    /**
     * The attributes of one overlay root, or null when the root simply does not
     * exist (a workspace that has never materialized that tree).
     */
    private fun rootAttributesOf(path: Path, entryName: String): BasicFileAttributes? = try {
        Files.readAttributes(path, BasicFileAttributes::class.java, LinkOption.NOFOLLOW_LINKS)
    } catch (_: NoSuchFileException) {
        null
    } catch (failure: IOException) {
        throw BootOverlayException(
            "cannot stat the boot overlay root \"$entryName\"",
            BootOverlayException.Refusal.IO,
            entry = entryName,
            cause = failure,
        )
    }

    private fun modeOf(path: Path, fallback: Int): Int = try {
        var mode = 0
        for (permission in Files.getPosixFilePermissions(path, LinkOption.NOFOLLOW_LINKS)) {
            mode = mode or when (permission) {
                PosixFilePermission.OWNER_READ -> 0b100_000_000
                PosixFilePermission.OWNER_WRITE -> 0b010_000_000
                PosixFilePermission.OWNER_EXECUTE -> 0b001_000_000
                PosixFilePermission.GROUP_READ -> 0b100_000
                PosixFilePermission.GROUP_WRITE -> 0b010_000
                PosixFilePermission.GROUP_EXECUTE -> 0b001_000
                PosixFilePermission.OTHERS_READ -> 0b100
                PosixFilePermission.OTHERS_WRITE -> 0b010
                PosixFilePermission.OTHERS_EXECUTE -> 0b001
            }
        }
        mode
    } catch (_: UnsupportedOperationException) {
        fallback
    } catch (_: IOException) {
        fallback
    }

    /**
     * One ustar header, with the name/prefix split `storage/tar.ts` reads back.
     *
     * The mtime is 0 and the uid/gid are 0 so the same tree always yields the
     * same bytes; the checksum is written as the six octal digits plus NUL plus
     * space that the format fixes.
     */
    private fun tarHeader(entryName: String, mode: Int, size: Long, directory: Boolean): ByteArray {
        val (prefix, name) = splitUstarName(entryName)
        val header = ByteArray(TAR_BLOCK.toInt())
        writeField(name, header, NAME_OFFSET, NAME_LENGTH)
        writeOctal(mode.toLong(), header, MODE_OFFSET, MODE_LENGTH)
        writeOctal(0L, header, UID_OFFSET, UID_LENGTH)
        writeOctal(0L, header, GID_OFFSET, GID_LENGTH)
        writeOctal(size, header, SIZE_OFFSET, SIZE_LENGTH)
        writeOctal(0L, header, MTIME_OFFSET, MTIME_LENGTH)
        for (index in CHECKSUM_OFFSET until CHECKSUM_OFFSET + CHECKSUM_LENGTH) header[index] = SPACE
        header[TYPEFLAG_OFFSET] = if (directory) TYPE_DIRECTORY else TYPE_REGULAR
        writeField(USTAR_MAGIC, header, MAGIC_OFFSET, MAGIC_LENGTH)
        writeField(USTAR_VERSION, header, VERSION_OFFSET, VERSION_LENGTH)
        if (prefix != null) writeField(prefix, header, PREFIX_OFFSET, PREFIX_LENGTH)
        var checksum = 0L
        for (byte in header) checksum += (byte.toInt() and 0xFF).toLong()
        writeField(checksum.toString(8).padStart(6, '0'), header, CHECKSUM_OFFSET, 6)
        header[CHECKSUM_OFFSET + 6] = 0
        header[CHECKSUM_OFFSET + 7] = SPACE
        return header
    }

    /**
     * The ustar name/prefix split: `name` ≤ 100 bytes, `prefix` ≤ 155 bytes.
     *
     * The same rule `storage/tar.ts` writes and `parseTar` reads back; a name that
     * does not fit is refused rather than truncated.
     */
    private fun splitUstarName(entryName: String): Pair<String?, String> {
        val bytes = entryName.toByteArray(Charsets.UTF_8)
        if (bytes.size <= NAME_LENGTH) return null to entryName
        for (index in bytes.size - 1 downTo 1) {
            if (bytes[index - 1] != SLASH) continue
            val prefixCount = index - 1
            val nameCount = bytes.size - index
            if (prefixCount in 1..PREFIX_LENGTH && nameCount <= NAME_LENGTH) {
                val prefix = String(bytes, 0, prefixCount, Charsets.UTF_8)
                val name = String(bytes, index, nameCount, Charsets.UTF_8)
                return prefix to name
            }
        }
        throw BootOverlayException(
            "the boot overlay entry name \"$entryName\" does not fit the ustar name+prefix split",
            BootOverlayException.Refusal.PATH_TOO_LONG,
            entry = entryName,
        )
    }

    private fun writeField(value: String, header: ByteArray, offset: Int, length: Int) {
        val bytes = value.toByteArray(Charsets.UTF_8)
        val count = minOf(bytes.size, length)
        System.arraycopy(bytes, 0, header, offset, count)
    }

    private fun writeOctal(value: Long, header: ByteArray, offset: Int, length: Int) {
        val digits = value.toString(8)
        val padded = "0".repeat(maxOf(0, length - 1 - digits.length)) + digits
        val bytes = padded.toByteArray(Charsets.US_ASCII)
        System.arraycopy(bytes, 0, header, offset, minOf(bytes.size, length - 1))
        header[offset + length - 1] = 0
    }

    companion object {
        /** The only two trees §8 admits, in the order they are packed. */
        val ROOTS: List<String> = listOf("home", "workspace")

        /** Entries above this are refused; a workspace with more is a budget failure, not an overlay. */
        const val DEFAULT_MAX_ENTRIES: Int = 200_000

        private const val TAR_BLOCK = 512L
        private const val TAR_TERMINATOR_BYTES = TAR_BLOCK * 2
        private const val BUFFER_BYTES = 64 * 1024

        private const val DEFAULT_FILE_MODE = 0b110_100_100 // 0644
        private const val DEFAULT_DIRECTORY_MODE = 0b111_101_101 // 0755

        private const val NAME_OFFSET = 0
        private const val NAME_LENGTH = 100
        private const val MODE_OFFSET = 100
        private const val MODE_LENGTH = 8
        private const val UID_OFFSET = 108
        private const val UID_LENGTH = 8
        private const val GID_OFFSET = 116
        private const val GID_LENGTH = 8
        private const val SIZE_OFFSET = 124
        private const val SIZE_LENGTH = 12
        private const val MTIME_OFFSET = 136
        private const val MTIME_LENGTH = 12
        private const val CHECKSUM_OFFSET = 148
        private const val CHECKSUM_LENGTH = 8
        private const val TYPEFLAG_OFFSET = 156
        private const val TYPE_REGULAR = '0'.code.toByte()
        private const val TYPE_DIRECTORY = '5'.code.toByte()
        private const val MAGIC_OFFSET = 257
        private const val MAGIC_LENGTH = 6
        private const val VERSION_OFFSET = 263
        private const val VERSION_LENGTH = 2
        private const val PREFIX_OFFSET = 345
        private const val PREFIX_LENGTH = 155

        private const val USTAR_MAGIC = "ustar"
        private const val USTAR_VERSION = "00"
        private const val SLASH = '/'.code.toByte()
        private const val SPACE = ' '.code.toByte()
    }
}
