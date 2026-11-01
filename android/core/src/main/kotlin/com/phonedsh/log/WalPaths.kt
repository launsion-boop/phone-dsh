// The workspace directory layout of wal.md §1 and §7.
// SPDX-License-Identifier: MIT

package com.phonedsh.log

import java.io.IOException
import java.nio.file.Files
import java.nio.file.Path

/**
 * The paths of one workspace under `Library/xl/<workspace_id>/` (`wal.md` §1).
 *
 * Only workspace-relative names live here. `wal.md` §7 says neither the
 * manifest nor the directory contains an absolute local path, and this type is
 * the single place that turns a name into a `Path`, so no other file in the
 * package has to concatenate one.
 *
 * @property root the workspace root, for example `Library/xl/w1`.
 */
class WalPaths(val root: Path) {
    /** `wal/`, the segment directory (`wal.md` §1). */
    val walDirectory: Path = root.resolve("wal")

    /** `materialized/`, the derived copy (`wal.md` §6). */
    val materializedDirectory: Path = root.resolve("materialized")

    /** `materialized/home/`, mirroring `/dsh/home/…`. */
    val materializedHome: Path = materializedDirectory.resolve("home")

    /** `materialized/workspace/`, mirroring `/dsh/workspace/…`. */
    val materializedWorkspace: Path = materializedDirectory.resolve("workspace")

    /** `materialized.staging/`, the reconcile output (`wal.md` §7.2). */
    val stagingDirectory: Path = root.resolve("materialized.staging")

    /**
     * `materialized.old/`, the preimage half of the two-rename exchange.
     *
     * `wal.md` §7.2 says "exchange `materialized/` and
     * `materialized.staging/` by rename"; POSIX exposes no portable atomic
     * directory swap, so the exchange is two renames and this name holds the
     * old tree between them. A crash between the renames is repaired on the
     * next boot because `reconcile.inprogress` still exists.
     */
    val previousMaterializedDirectory: Path = root.resolve("materialized.old")

    /** `manifest.json` (`wal.md` §7). */
    val manifestFile: Path = root.resolve("manifest.json")

    /** `reconcile.inprogress` (`wal.md` §7.2). */
    val reconcileMarker: Path = root.resolve("reconcile.inprogress")

    /** The absolute path of [name] inside [walDirectory]. */
    fun segment(name: WalSegmentName): Path = name.resolveIn(walDirectory)

    /** The materialized location of a D4 VFS path, below [materializedDirectory]. */
    fun materialized(vfsPath: String): Path = VfsPath.resolve(materializedDirectory, vfsPath)

    /** The materialized location of a D4 VFS path in [stagingDirectory]. */
    fun staged(vfsPath: String): Path = VfsPath.resolve(stagingDirectory, vfsPath)

    /**
     * Creates the directories the log owns (`wal.md` §1).
     *
     * `steps/` and `exec/` belong to other host components and are not created
     * here.
     *
     * @throws LogException `WAL_DIRECTORY_IO` when a directory cannot be
     *   created.
     */
    fun createDirectories() {
        try {
            Files.createDirectories(root)
            Files.createDirectories(walDirectory)
            Files.createDirectories(materializedHome)
            Files.createDirectories(materializedWorkspace)
        } catch (error: IOException) {
            throw LogException(
                LogFailure.WAL_DIRECTORY_IO,
                "cannot create the workspace directories: ${error.message}",
                error,
            )
        }
    }

    /** A workspace-relative label for a message; never an absolute path. */
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
}
