// phone-dsh — :engine / com.phonedsh.engine: who produces the §8 overlay, and when.
// SPDX-License-Identifier: MIT
//
// ---- the seam ---------------------------------------------------------------
// `:engine` owns the page load, but it does not own the materialized tree: the
// WAL's `materialized/` directory belongs to `:core` and the composition root
// (`:app`) is the only place that holds both. [BootOverlaySource] is therefore a
// one-method seam: the engine asks for a freshly packed overlay immediately before
// every page load, and the app answers from the materialized tree of the log it
// already recovered.
//
// ---- "rebuilt for each boot" (wal.md §8) -----------------------------------
// The overlay is an input, not an authority, so a stale one is worse than none: a
// Worker seeded from an old tree has a view the host's WAL already moved past, and
// the channel has no per-path "which generation do you hold" check that would
// catch it. The engine therefore calls [BootOverlaySource.pack] before *each* page
// load — the first boot, a renderer rebuild and a channel-reopen reload alike —
// never once per process.
//
// ---- the watermark check ----------------------------------------------------
// `materialized/` is updated by `WorkspaceLog.appendMutation` under its mutex, so a
// pack that races one can read file A after the mutation and file B before it.
// [MaterializedBootOverlaySource] brackets each pack with the log's
// `materializedUptoMseq` and discards a snapshot whose watermark moved: the
// accepted overlay is exactly "the materialized tree at one mseq", which is what
// the Worker mounts. A packer that refuses because a file changed mid-read
// ([BootOverlayException.Refusal.UNSTABLE]) is retried the same way, and only a
// tree that never settles becomes a failure.

package com.phonedsh.engine

import java.io.IOException
import java.nio.file.Files
import java.nio.file.Path
import java.nio.file.attribute.FileTime
import java.util.UUID

/**
 * A boot overlay ready to hand to the page.
 *
 * @property file the gzip member on disk.
 * @property urlPath the loopback path the page's `?overlay=` carries
 *   (`/image/overlay/<id>.tar`, the shape iOS serves).
 * @property watermark the `materializedUptoMseq` the snapshot was taken at, or
 *   [UNKNOWN_WATERMARK] when the caller has no watermark to report.
 */
data class BootOverlaySnapshot(
    val file: Path,
    val urlPath: String,
    val entries: Int,
    val treeBytes: Long,
    val archiveBytes: Long,
    val compressedBytes: Long,
    val elapsedMillis: Long,
    val watermark: Long,
    /**
     * The media type the loopback route declares.
     *
     * `application/gzip` because this member is gzip: the runtime refuses a body
     * that does not start `1f 8b` (`storage/image-gzip.ts`), so the type states
     * what the bytes are.
     */
    val contentType: String = MaterializedBootOverlaySource.CONTENT_TYPE,
) {
    /** Human-readable size line; never contains an absolute path. */
    fun describe(): String =
        "$entries entries, ${mebibytes(treeBytes)} MiB tree, " +
            "${mebibytes(archiveBytes)} MiB ustar, ${mebibytes(compressedBytes)} MiB gzip, " +
            "${elapsedMillis} ms, materialized_upto_mseq=${
                if (watermark == UNKNOWN_WATERMARK) "unknown" else watermark.toString()
            }"

    companion object {
        /** A caller with no `materializedUptoMseq` seam; the check is then skipped. */
        const val UNKNOWN_WATERMARK: Long = -1L

        fun mebibytes(bytes: Long): String = String.format(java.util.Locale.US, "%.1f", bytes / 1048576.0)
    }
}

/**
 * Produces one boot overlay on demand.
 *
 * Implementations do the I/O themselves; [WebViewEngine] calls [pack] on
 * `Dispatchers.IO` before every page load. A thrown [BootOverlayException] is a
 * refusal to boot, never a reason to boot without an overlay.
 */
fun interface BootOverlaySource {
    /**
     * Packs the current materialized tree.
     *
     * @return the overlay, with the file still on disk and servable.
     * @throws BootOverlayException when no honest overlay can be produced.
     */
    suspend fun pack(): BootOverlaySnapshot
}

/**
 * The production source: `materialized/{home,workspace}` → one gzip ustar.
 *
 * Files live beside the workspace log (`boot-overlay/` under its root), are named
 * `<32 hex>.tar` and are served at `/image/overlay/<32 hex>.tar`, so the loopback
 * route's shape is the iOS one and a per-load URL is unique. Only the newest
 * [keepFiles] survive, because a reload replaces the previous boot's overlay.
 *
 * @param materializedDirectory the tree to pack (`<workspace>/materialized`).
 * @param outputDirectory where the packed members are written.
 * @param maxArchiveBytes the uncompressed-ustar cap; the app passes the tier's
 *   `vfsLogicalBytes`, because the Worker must hold this tree in its memory VFS.
 * @param logger one line per produced overlay, one line per failed attempt.
 * @param watermark the log's `materializedUptoMseq`; a pack that straddles a
 *   change is discarded and retried. Default reports "unknown" and skips the
 *   check, which is the honest behaviour for a caller with no WAL.
 * @param idSource the per-load id; 32 lowercase hex, as the iOS route requires.
 * @param packerFactory the packer, injected so a test can refuse on demand.
 */
class MaterializedBootOverlaySource(
    private val materializedDirectory: Path,
    private val outputDirectory: Path,
    private val maxArchiveBytes: Long,
    private val logger: EngineLogger,
    private val watermark: () -> Long = { BootOverlaySnapshot.UNKNOWN_WATERMARK },
    private val idSource: () -> String = ::freshOverlayId,
    private val keepFiles: Int = 2,
    private val attempts: Int = 3,
    private val packerFactory: (Path, Long) -> BootOverlayPacker = { directory, limit ->
        BootOverlayPacker(directory, limit)
    },
) : BootOverlaySource {
    /** The last refusal [pack] would have thrown; kept so a caller can log the numbers. */
    @Volatile
    private var lastRefusal: BootOverlayException? = null

    override suspend fun pack(): BootOverlaySnapshot {
        try {
            Files.createDirectories(outputDirectory)
        } catch (failure: IOException) {
            throw BootOverlayException(
                "cannot create the boot overlay directory",
                BootOverlayException.Refusal.IO,
                cause = failure,
            )
        }
        var refusal: BootOverlayException? = null
        repeat(attempts) { attempt ->
            val before = watermark()
            val id = idSource().lowercase()
            require(id.matches(HEX32)) { "a boot overlay id must be 32 lowercase hex characters" }
            val file = outputDirectory.resolve("$id.tar")
            val pack = try {
                packerFactory(materializedDirectory, maxArchiveBytes).pack(file)
            } catch (unstable: BootOverlayException) {
                runCatching { Files.deleteIfExists(file) }
                refusal = unstable
                logger.warn(
                    "boot overlay: attempt ${attempt + 1}/$attempts refused " +
                        "(${unstable.refusal}), retrying",
                )
                if (unstable.refusal == BootOverlayException.Refusal.UNSTABLE) return@repeat
                lastRefusal = unstable
                throw unstable
            }
            val after = watermark()
            if (before == BootOverlaySnapshot.UNKNOWN_WATERMARK || after == before) {
                prune(keep = file)
                lastRefusal = null
                return BootOverlaySnapshot(
                    file = pack.file,
                    urlPath = "$ROUTE_PREFIX/$id.tar",
                    entries = pack.entries,
                    treeBytes = pack.treeBytes,
                    archiveBytes = pack.archiveBytes,
                    compressedBytes = pack.compressedBytes,
                    elapsedMillis = pack.elapsedMillis,
                    watermark = before,
                    contentType = CONTENT_TYPE,
                )
            }
            // The materialized tree moved while it was read: this snapshot is not
            // "the tree at one mseq", so it is thrown away rather than served.
            runCatching { Files.deleteIfExists(file) }
            refusal = BootOverlayException(
                "the materialized tree advanced from mseq $before to $after while the boot overlay " +
                    "was packed; the snapshot was discarded",
                BootOverlayException.Refusal.UNSTABLE,
            )
            logger.warn("boot overlay: attempt ${attempt + 1}/$attempts straddled a materialization")
        }
        lastRefusal = refusal
        throw refusal ?: BootOverlayException(
            "the boot overlay could not be produced",
            BootOverlayException.Refusal.IO,
        )
    }

    /** The most recent refusal, or null after a successful [pack]. */
    fun lastRefusal(): BootOverlayException? = lastRefusal

    /**
     * Deletes every overlay member except [keep] and the newest `keepFiles - 1`
     * others. A reload's predecessor is still being fetched while the successor is
     * written, which `keepFiles = 2` covers.
     */
    private fun prune(keep: Path) {
        val members = try {
            Files.newDirectoryStream(outputDirectory, "$GLOB").use { stream ->
                stream.toList()
            }
        } catch (failure: IOException) {
            logger.warn("boot overlay: cannot list old overlay members to prune: ${failure::class.java.simpleName}")
            return
        }
        // Newest first. `FileTime` carries the filesystem's precision, and the
        // name is the deterministic tie-break: two packs can land inside one clock
        // tick, and an unstable sort would then be free to delete the newer member.
        val others = members
            .filter { it.toAbsolutePath().normalize() != keep.toAbsolutePath().normalize() }
            .sortedWith(
                compareByDescending<Path> { file -> lastModified(file) }
                    .thenByDescending { file -> file.fileName.toString() },
            )
        for (stale in others.drop(maxOf(0, keepFiles - 1))) {
            runCatching { Files.deleteIfExists(stale) }
        }
    }

    private fun lastModified(file: Path): FileTime =
        runCatching { Files.getLastModifiedTime(file) }
            .getOrDefault(FileTime.fromMillis(0L))

    companion object {
        /** Loopback path prefix the engine serves the overlay under (the iOS shape). */
        const val ROUTE_PREFIX: String = "/image/overlay"

        /** Media type of the gzip member the worker inflates. */
        const val CONTENT_TYPE: String = "application/gzip"

        private const val GLOB = "*.tar"
        private val HEX32 = Regex("^[0-9a-f]{32}$")

        /** A fresh 32-hex id, the spelling the loopback overlay route documents. */
        fun freshOverlayId(): String = UUID.randomUUID().toString().replace("-", "")
    }
}
