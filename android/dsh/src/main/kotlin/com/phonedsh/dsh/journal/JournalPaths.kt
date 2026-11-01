// phone-dsh — :dsh / com.phonedsh.dsh.journal: the journal store's directory layout.
// SPDX-License-Identifier: MIT
//
// ---- why this store is not the WAL ----------------------------------------
// The WAL is the VFS mutation log: `wal.md` fixes its segment layout, its
// records are `MutationBody` bytes and `pdsh_wal` parses them. The journal is
// the tool-call evidence the worker sends in JOURNAL frames; its record bytes
// are opaque to the host. Sharing a file layout would make one parser decide
// both, which is exactly the second-implementation trap this lane exists to
// avoid. So the journal gets its own directory, its own framing (JournalStore)
// and its own quota row (budgets.md §5, 64 MiB), and reuses only the platform
// `Durability` SPI and the `HostLog` seam.
//
// ---- one file per session --------------------------------------------------
// Appending one record is one file append plus one fsync, and pruning is
// per-session, so a session's evidence never rewrites another session's file.
// The store lives at `journal/`, a sibling of `wal/` under the workspace root.
//
// ---- why the file name is hex ---------------------------------------------
// D6 allows `.` and `..` as session ids (`^[A-Za-z0-9._-]{1,64}$`), so a direct
// `<session_id>.xljournal` mapping would be a path traversal. Hex of the UTF-8
// bytes is injective, contains no separator and cannot start with a dot. The
// session id itself is stored in the file header, so recovery never has to
// guess which id a file belongs to.

package com.phonedsh.dsh.journal

import java.io.IOException
import java.nio.file.Files
import java.nio.file.Path

/**
 * The paths of the journal store of one workspace.
 *
 * @property root the workspace root (the same root `wal/` and `materialized/`
 *   live under). The store adds exactly one directory: [journalDirectory].
 */
class JournalPaths(val root: Path) {
    /** `journal/`, the whole store; budgets.md §5 caps it at 64 MiB. */
    val journalDirectory: Path = root.resolve("journal")

    /**
     * The one file of [sessionId].
     *
     * The session id is not used verbatim as a file name: see the file comment
     * for the traversal and recovery reasons.
     */
    fun sessionFile(sessionId: String): Path {
        require(sessionId.isNotEmpty()) { "a session id is never empty" }
        return journalDirectory.resolve(fileName(sessionId))
    }

    /**
     * Creates the directories this store owns (`journal/`, and the workspace
     * root when it does not exist yet).
     *
     * `wal/`, `materialized/` and `steps/` belong to other components and are
     * never created here.
     *
     * @throws JournalException `JOURNAL_IO` when a directory cannot be created.
     */
    fun createDirectories() {
        try {
            Files.createDirectories(root)
            Files.createDirectories(journalDirectory)
        } catch (error: IOException) {
            throw JournalException(
                JournalFailure.IO,
                "cannot create the journal directory: ${error.message}",
                cause = error,
            )
        }
    }

    /** A workspace-relative label for a log line; never an absolute path. */
    internal fun label(path: Path): String {
        val absoluteRoot = root.toAbsolutePath().normalize()
        val absolute = path.toAbsolutePath().normalize()
        if (absolute == absoluteRoot) return "."
        return try {
            absoluteRoot.relativize(absolute).toString()
        } catch (_: IllegalArgumentException) {
            path.fileName?.toString() ?: "?"
        }
    }

    companion object {
        /**
         * The one file suffix.
         *
         * An `atomicReplace` leaves a `.tmp` sibling on failure, and a `.tmp`
         * sibling is never a session file, so the suffix also keeps compaction
         * temporaries out of recovery and out of the quota measurement.
         */
        const val FILE_SUFFIX: String = ".xljournal"

        /** The header magic: the ASCII bytes `PJNL`, big-endian. */
        const val MAGIC: Int = 0x504A_4E4C

        /** The one file version this host writes. */
        const val VERSION: Int = 1

        /** magic `u32` + version `u8` + flags `u8` + session_id_len `u16`. */
        const val HEADER_PREFIX_BYTES: Int = 8

        /** `pruned_upto` `u64`, after the session id. */
        const val HEADER_TRAILER_BYTES: Int = 8

        private const val HEX = "0123456789abcdef"

        /** Lowercase hex of the UTF-8 [sessionId] plus [FILE_SUFFIX]. */
        internal fun fileName(sessionId: String): String {
            val bytes = sessionId.toByteArray(Charsets.UTF_8)
            val builder = StringBuilder(bytes.size * 2 + FILE_SUFFIX.length)
            for (byte in bytes) {
                val value = byte.toInt() and 0xFF
                builder.append(HEX[value ushr 4]).append(HEX[value and 0x0F])
            }
            return builder.append(FILE_SUFFIX).toString()
        }
    }
}
