// phone-dsh — :engine / com.phonedsh.engine: APK assets -> filesDir/worker materialization.
// SPDX-License-Identifier: MIT
//
// The 65 MB worker bundle ships inside the APK as one read-only zip asset (why a
// zip: see ZipWorkerAssetSource). This class copies it once into
// `filesDir/worker/` (the loopback origin needs a real directory to serve, and a
// reload after a renderer death must not re-read the APK), and skips the copy
// while the version stamp is unchanged.
//
// Copy discipline:
//   * stage in `worker.staging-<nanos>/`, swap into place only after the whole
//     bundle is on disk and the entry point exists; a failure leaves the previous
//     `worker/` and its stamp untouched and deletes the staging directory;
//   * the stamp (`worker.version`) is written last, so a half-written bundle is
//     never marked current;
//   * the copy is a plain blocking loop. The caller runs it on a background
//     thread: `WebViewEngine` calls materialize() inside `withContext(IO)`.
//
// Nothing here touches android.*: the APK-specific part is [ApkWorkerAssetSource],
// which is why WorkerAssetsTest can run on the JVM against a temp directory.

package com.phonedsh.engine

import java.io.Closeable
import java.io.File
import java.io.IOException
import java.io.InputStream
import java.nio.file.Path

/** One source of worker assets: the APK asset tree in production (see ApkWorkerAssetSource). */
interface WorkerAssetSource {
    /**
     * Changes whenever the bundle content may have changed; it is the cache key
     * of the materialized copy. The APK source uses versionCode + lastUpdateTime,
     * i.e. "the installed APK that carries the bundle". Any change forces a
     * re-copy from scratch.
     */
    val versionStamp: String

    /** Every asset file, '/'-separated and relative to the bundle root. */
    fun listAssets(): List<String>

    /** Opens one asset. The caller closes the stream. */
    fun open(assetPath: String): InputStream
}

/** Progress of one copy, reported per file. */
data class WorkerAssetProgress(
    val filesCopied: Int,
    val filesTotal: Int,
    val bytesCopied: Long,
) {
    /** 0.0 ... 1.0 over the file count. */
    val fraction: Double get() = if (filesTotal <= 0) 0.0 else filesCopied.toDouble() / filesTotal

    fun describe(): String =
        "$filesCopied/$filesTotal files, ${WorkerAssets.mebibytes(bytesCopied)} MiB"

    /** 0 ... 100, for one INFO line per ten percent instead of one per file. */
    internal fun percent(): Int = if (filesTotal <= 0) 100 else filesCopied * 100 / filesTotal
}

/** Result of [WorkerAssets.materialize]. */
data class WorkerMaterialization(
    /** Directory to hand to `LoopbackServer.start(assetsDir)`. */
    val directory: Path,
    val files: Int,
    val bytes: Long,
    /** False when a current copy was reused; true when this call copied the bundle. */
    val copied: Boolean,
    val elapsedMillis: Long,
) {
    fun describe(): String =
        "${if (copied) "copied" else "reused"} $files files, " +
            "${WorkerAssets.mebibytes(bytes)} MiB in $elapsedMillis ms"
}

/**
 * Materializes a [WorkerAssetSource] into `filesDir/worker/` once per stamp.
 *
 * [materialize] is synchronized: two concurrent `start()` calls cannot copy the
 * same bundle twice or interleave a staging directory.
 */
class WorkerAssets(
    private val source: WorkerAssetSource,
    private val filesDir: File,
    private val logger: EngineLogger,
    private val entryPoint: String = ENTRY_POINT,
) {
    private val bundleDir = File(filesDir, BUNDLE_DIR)
    private val versionFile = File(filesDir, VERSION_FILE)

    /**
     * Copies the bundle when the stamp changed, reuses it otherwise. Blocks.
     *
     * A [Closeable] source (the APK zip bridge) is closed in every outcome: it
     * holds one zip handle and one cache copy of the bundle.
     */
    @Synchronized
    fun materialize(onProgress: (WorkerAssetProgress) -> Unit = {}): WorkerMaterialization =
        try {
            copyOrReuse(onProgress)
        } finally {
            (source as? Closeable)?.let { closeable -> runCatching { closeable.close() } }
        }

    private fun copyOrReuse(onProgress: (WorkerAssetProgress) -> Unit): WorkerMaterialization {
        val startedAt = System.nanoTime()
        val stamp = source.versionStamp
        if (isCurrent(stamp)) {
            val inventory = inventory(bundleDir)
            val elapsed = elapsedMillis(startedAt)
            logger.info(
                "worker assets: reusing $BUNDLE_DIR ($stamp, ${inventory.describe()}) in $elapsed ms",
            )
            return WorkerMaterialization(
                directory = bundleDir.toPath(),
                files = inventory.files,
                bytes = inventory.bytes,
                copied = false,
                elapsedMillis = elapsed,
            )
        }

        val assetPaths = source.listAssets()
        require(assetPaths.isNotEmpty()) { "the worker asset source is empty (stamp=$stamp)" }
        for (assetPath in assetPaths) requireSafePath(assetPath)
        if (!filesDir.isDirectory && !filesDir.mkdirs()) {
            throw IOException("cannot create the files directory $filesDir")
        }
        deleteStaleDirectories()

        val staging = File(filesDir, "$STAGING_PREFIX${System.nanoTime()}")
        if (!staging.mkdirs()) throw IOException("cannot create the staging directory $staging")
        logger.info(
            "worker assets: copying ${assetPaths.size} files from the APK bundle " +
                "(stamp=$stamp, staging=${staging.name}) off the main thread",
        )
        var copiedFiles = 0
        var copiedBytes = 0L
        var nextInfoPercent = 0
        try {
            val buffer = ByteArray(COPY_BUFFER_BYTES)
            for (assetPath in assetPaths.sorted()) {
                val target = File(staging, assetPath)
                val parent = target.parentFile
                if (parent != null && !parent.isDirectory && !parent.mkdirs()) {
                    throw IOException("cannot create the asset directory $parent")
                }
                val fileBytes = source.open(assetPath).use { input -> copyInto(input, target, buffer) }
                copiedFiles += 1
                copiedBytes += fileBytes
                val progress = WorkerAssetProgress(copiedFiles, assetPaths.size, copiedBytes)
                onProgress(progress)
                if (progress.percent() >= nextInfoPercent || copiedFiles == assetPaths.size) {
                    logger.info("worker assets: ${progress.describe()} (${progress.percent()}%)")
                    nextInfoPercent = progress.percent() + PROGRESS_LOG_STEP_PERCENT
                }
            }
            val entry = File(staging, entryPoint)
            if (!entry.isFile) {
                throw IOException("the worker bundle has no $entryPoint (staging=${staging.name})")
            }
            val inventory = inventory(staging)
            if (inventory.files != copiedFiles) {
                throw IOException(
                    "worker bundle copy is incomplete: $copiedFiles copied, ${inventory.files} on disk",
                )
            }
            swapIn(staging)
            writeStamp(stamp)
            val elapsed = elapsedMillis(startedAt)
            logger.info(
                "worker assets: ready (${inventory.describe()}, stamp=$stamp) in $elapsed ms",
            )
            return WorkerMaterialization(
                directory = bundleDir.toPath(),
                files = inventory.files,
                bytes = inventory.bytes,
                copied = true,
                elapsedMillis = elapsed,
            )
        } catch (failure: Throwable) {
            deleteRecursively(staging)
            logger.error("worker assets: copy failed, previous bundle kept: ${EngineLogText.reasonOf(failure)}")
            throw failure
        }
    }

    /** True when `filesDir/worker/` already holds the bundle for [versionStamp]. */
    private fun isCurrent(stamp: String): Boolean {
        if (!versionFile.isFile) return false
        if (!File(bundleDir, entryPoint).isFile) return false
        return runCatching { versionFile.readText().trim() }.getOrNull() == stamp
    }

    /**
     * Replaces the previous bundle with [staging].
     *
     * The old directory is renamed aside first, so a failure of the second rename
     * restores it; both renames stay inside `filesDir`, i.e. on one filesystem.
     */
    private fun swapIn(staging: File) {
        val retired = File(filesDir, RETIRED_DIR)
        deleteRecursively(retired)
        val hadBundle = bundleDir.exists()
        if (hadBundle && !bundleDir.renameTo(retired)) {
            throw IOException("cannot move the previous $BUNDLE_DIR aside")
        }
        if (!staging.renameTo(bundleDir)) {
            if (hadBundle) retired.renameTo(bundleDir)
            throw IOException("cannot move the staged worker bundle into $BUNDLE_DIR")
        }
        deleteRecursively(retired)
    }

    /** Writes the stamp last: a half-written bundle never looks current. */
    private fun writeStamp(stamp: String) {
        val temp = File(filesDir, "$VERSION_FILE.tmp")
        temp.writeText(stamp + "\n")
        versionFile.delete()
        if (!temp.renameTo(versionFile)) {
            temp.delete()
            throw IOException("cannot write $VERSION_FILE")
        }
    }

    private fun deleteStaleDirectories() {
        val children = filesDir.listFiles() ?: return
        for (child in children) {
            if (child.name.startsWith(STAGING_PREFIX) || child.name == RETIRED_DIR) {
                if (deleteRecursively(child)) logger.warn("worker assets: removed stale ${child.name}")
            }
        }
    }

    private fun inventory(directory: File): Inventory {
        var files = 0
        var bytes = 0L
        val queue = ArrayDeque<File>()
        queue.addLast(directory)
        while (queue.isNotEmpty()) {
            val current = queue.removeFirst()
            val children = current.listFiles() ?: continue
            for (child in children) {
                if (child.isDirectory) queue.addLast(child) else {
                    files += 1
                    bytes += child.length()
                }
            }
        }
        return Inventory(files, bytes)
    }

    /** Copies [input] to [target]; the caller owns (and closes) [input]. */
    private fun copyInto(input: InputStream, target: File, buffer: ByteArray): Long {
        var total = 0L
        target.outputStream().use { sink ->
            while (true) {
                val read = input.read(buffer)
                if (read < 0) break
                sink.write(buffer, 0, read)
                total += read
            }
        }
        return total
    }

    private fun requireSafePath(assetPath: String) {
        require(assetPath.isNotEmpty()) { "the worker asset source listed an empty path" }
        require(!assetPath.startsWith("/") && !assetPath.contains('\\')) {
            "the worker asset source listed an absolute or backslash path: '$assetPath'"
        }
        for (segment in assetPath.split('/')) {
            require(segment.isNotEmpty() && segment != "." && segment != "..") {
                "the worker asset source listed an unsafe path: '$assetPath'"
            }
        }
    }

    /** Deletes [target] recursively; returns true when nothing is left. */
    private fun deleteRecursively(target: File): Boolean {
        if (!target.exists()) return true
        val children = target.listFiles()
        if (children != null) {
            for (child in children) {
                if (!deleteRecursively(child)) return false
            }
        }
        return target.delete()
    }

    private fun elapsedMillis(startedAt: Long): Long = (System.nanoTime() - startedAt) / 1_000_000

    private class Inventory(val files: Int, val bytes: Long) {
        fun describe(): String = "$files files, ${mebibytes(bytes)} MiB"
    }

    companion object {
        /** Directory under `filesDir` the loopback origin serves. */
        const val BUNDLE_DIR: String = "worker"

        /** Stamp file next to it; content is [WorkerAssetSource.versionStamp]. */
        const val VERSION_FILE: String = "worker.version"

        /** Entry point the bundle must contain; the origin's launch page loads it. */
        const val ENTRY_POINT: String = "index.html"

        internal const val STAGING_PREFIX: String = "worker.staging-"
        internal const val RETIRED_DIR: String = "worker.retired"

        private const val COPY_BUFFER_BYTES = 128 * 1024
        private const val PROGRESS_LOG_STEP_PERCENT = 20

        /** `65.0`-style MiB for logs and README examples. */
        fun mebibytes(bytes: Long): String = String.format(java.util.Locale.ROOT, "%.1f", bytes / 1048576.0)
    }
}
