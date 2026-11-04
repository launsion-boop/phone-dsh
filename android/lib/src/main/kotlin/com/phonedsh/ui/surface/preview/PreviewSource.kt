// The workspace read behind the preview: the filesystem to preview face seam.
// SPDX-License-Identifier: MIT
//
// Status of the host read (L29, step 1). The bytes are already on disk: `:app`'s
// composition root builds the whole durable workspace over
// `File(application.filesDir, "xl")` (`ProbeEngineViewModel.workspaceRoot`), and
// `:core`'s `WalPaths` derives `materialized/workspace/` from it — the same
// `<root>/materialized/workspace` the iOS baseline reads (`ChatModel.workspaceRoot`
// + `PreviewSurface.swift:55`). Nothing in `:dsh` or `:core` has to change to read
// a file: the materialized copy is an ordinary directory tree.
//
// What was missing was the *read*: `PdshNavHost`'s files route was handed
// `FilesSource(files = null)` (L28 §3) and no host object could produce a listing.
// This file is that read, and it is deliberately the only place in `:lib` that
// touches the filesystem:
//
//   * [PreviewWorkspace.defaultRoot] repeats the app-side directory name (`"xl"`)
//     instead of importing it, because `:lib` cannot depend on `:app`. The two
//     spellings are pinned by `PreviewWorkspaceTest` against the app's own constant
//     read out of `ProbeEngineViewModel.kt`, so a rename on either side fails the
//     JVM suite rather than silently emptying the page.
//   * the read is `suspend` and every operation runs on `Dispatchers.IO`; a page
//     body never blocks on the disk (spec §3.1: the page is a pure function of the
//     state, the route is what reads).
//   * a root that does not exist answers `null` / `NO_WORKSPACE`, never an empty
//     list: "the host did not report a workspace" and "the workspace is empty" are
//     different facts, and the files page renders them differently.
package com.phonedsh.ui.surface.preview

import android.content.Context
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.platform.LocalContext
import com.phonedsh.ui.page.WorkspaceFile
import java.io.File
import java.io.IOException
import java.nio.file.FileVisitResult
import java.nio.file.Files
import java.nio.file.Path
import java.nio.file.SimpleFileVisitor
import java.nio.file.attribute.BasicFileAttributes
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/**
 * Where the Android host keeps the materialized workspace.
 *
 * `wal.md` §1 puts the workspace under `Library/xl/<workspace_id>/`; on Android the
 * app's private `filesDir` is the equivalent root, so the tree the Worker's VFS
 * mutations are materialized into is `filesDir/xl/materialized/workspace`.
 */
public object PreviewWorkspace {
    /**
     * The directory `:app` uses (`ProbeEngineViewModel.WORKSPACE_DIRECTORY`).
     *
     * Duplicated on purpose: `:lib` is published as an AAR and cannot see `:app`.
     * `PreviewWorkspaceTest` reads the app's constant from its source file and
     * asserts the two strings are the same, so the copy cannot drift unnoticed.
     */
    public const val DIRECTORY: String = "xl"

    /** `materialized/`, the WAL's derived tree (`WalPaths.materializedDirectory`). */
    public const val MATERIALIZED: String = "materialized"

    /** `workspace/`, the mirror of the Worker's `/dsh/workspace` (`WalPaths.materializedWorkspace`). */
    public const val WORKSPACE: String = "workspace"

    /** The workspace root a device host reads by default. */
    public fun defaultRoot(filesDir: File): Path =
        filesDir.toPath().resolve(DIRECTORY).resolve(MATERIALIZED).resolve(WORKSPACE)
}

/**
 * The real [PreviewFileSource]: a directory tree, read on an IO dispatcher.
 *
 * @param root the materialized workspace root, or `null` when the host has none.
 *   Every operation then answers "not reported" instead of inventing a workspace.
 */
public class WorkspacePreviewSource(public val root: Path?) : PreviewFileSource {

    override suspend fun files(): List<WorkspaceFile>? = withContext(Dispatchers.IO) {
        val directory = root ?: return@withContext null
        if (!Files.isDirectory(directory)) return@withContext null
        val found = mutableListOf<WorkspaceFile>()
        try {
            Files.walkFileTree(
                directory,
                emptySet(),
                MAX_DEPTH,
                object : SimpleFileVisitor<Path>() {
                    override fun visitFile(file: Path, attrs: BasicFileAttributes): FileVisitResult {
                        // A symlink is not followed (the visitor's default) and is
                        // not listed: the preview would refuse it unless it resolves
                        // inside the root, and a row that cannot open is worse than
                        // no row.
                        if (!attrs.isRegularFile || attrs.isSymbolicLink) return FileVisitResult.CONTINUE
                        if (found.size >= MAX_ENTRIES) return FileVisitResult.TERMINATE
                        val relative = directory.relativize(file).toString().replace(File.separatorChar, '/')
                        found.add(
                            WorkspaceFile(
                                id = relative,
                                relativePath = relative,
                                size = attrs.size(),
                            ),
                        )
                        return FileVisitResult.CONTINUE
                    }

                    // An unreadable sub-directory must not abort the listing: the
                    // rest of the workspace is still a fact.
                    override fun visitFileFailed(file: Path, error: IOException): FileVisitResult =
                        FileVisitResult.CONTINUE
                },
            )
        } catch (_: IOException) {
            // A listing that failed half-way is not a listing: report "not
            // reported" so the page says so instead of showing a truncated tree.
            return@withContext null
        }
        found.sortedBy { it.relativePath }
    }

    override suspend fun resolve(relativePath: String): PreviewResolution =
        withContext(Dispatchers.IO) { PreviewPathResolver.resolve(root, relativePath) }

    override suspend fun readPage(file: Path, offset: Long): PreviewTextPage =
        withContext(Dispatchers.IO) { PreviewPager.readPage(file, offset) }

    override suspend fun looksLikeText(file: Path): Boolean =
        withContext(Dispatchers.IO) { PreviewPager.looksLikeText(file) }

    private companion object {
        /**
         * How deep the listing walks.
         *
         * A workspace is a working directory, not a filesystem: eight levels covers
         * every tool layout this host has seen (`src/main/kotlin/...` is six) and
         * bounds the walk on a pathological tree.
         */
        const val MAX_DEPTH: Int = 8

        /**
         * How many rows one listing returns.
         *
         * The page scrolls a lazy list, so the cap is about the *read*, not the
         * screen: 2 000 `stat` calls is a fraction of a frame's worth of IO on a
         * warm cache, and a bigger tree is reported as the first 2 000 sorted rows
         * rather than as a hang.
         */
        const val MAX_ENTRIES: Int = 2_000
    }
}

/**
 * The source the routes use.
 *
 * @param workspaceRoot an explicit root (a host that measured its own workspace, or
 *   a test), or `null` for [PreviewWorkspace.defaultRoot] of this app's `filesDir`.
 *   A host with **no** workspace passes a path that does not exist: the source then
 *   reports `NO_WORKSPACE` instead of silently reading somebody else's directory.
 */
@Composable
public fun rememberPreviewSource(workspaceRoot: File? = null): PreviewFileSource {
    val context = LocalContext.current.applicationContext
    return remember(context, workspaceRoot) { previewSourceFor(context, workspaceRoot) }
}

/** The non-composable form of [rememberPreviewSource] (used by tests and hosts). */
public fun previewSourceFor(context: Context, workspaceRoot: File? = null): PreviewFileSource {
    val root = workspaceRoot?.toPath() ?: PreviewWorkspace.defaultRoot(context.filesDir)
    return WorkspacePreviewSource(root)
}
