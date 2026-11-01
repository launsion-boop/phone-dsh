// The D4 sink path grammar and its map onto the materialized copy.
// SPDX-License-Identifier: MIT

package com.phonedsh.log

import com.phonedsh.wire.WalException
import java.nio.file.Path

/**
 * The D4 path grammar of a VFS mutation and its materialized location.
 *
 * `wal.md` §6 materializes only `materialized/home/…` and
 * `materialized/workspace/…`, which mirror `/dsh/home/…` and
 * `/dsh/workspace/…`. The grammar is D4's
 * `^/dsh/(home|workspace)(/[^/]+)+$` with no `.`, `..` or empty component, and
 * `/dsh`, `/dsh/home` and `/dsh/workspace` are not mutation targets.
 *
 * A validated component list is the only thing that may reach
 * [resolve]'s path construction: the materializer trusts no record bytes, not
 * even one that passed a CRC, because a WAL written by a buggy or hostile
 * build must not escape the workspace directory.
 */
internal object VfsPath {
    /** The two materialized roots (`wal.md` §6). */
    val ROOTS: Set<String> = setOf("home", "workspace")

    /**
     * Validates [path] against the D4 grammar.
     *
     * @return [path] unchanged, for use in a fluent call.
     * @throws WalException `BAD_PATH` when the grammar, scope or a component
     *   fails.
     */
    fun requireValid(path: String): String {
        validate(path)
        return path
    }

    /**
     * The components of [path] below `/dsh/`, for example
     * `["workspace", "notes.txt"]`.
     *
     * @throws WalException `BAD_PATH` like [requireValid].
     */
    fun components(path: String): List<String> = validate(path)

    /**
     * Resolves [path] to a file under the materialized [root].
     *
     * `root` is the `materialized/` directory (or its staging counterpart), so
     * `/dsh/home/a` becomes `<root>/home/a`.
     *
     * @throws WalException `BAD_PATH` like [requireValid].
     */
    fun resolve(root: Path, path: String): Path {
        val components = validate(path)
        var resolved = root
        for (component in components) {
            resolved = resolved.resolve(component)
        }
        return resolved
    }

    private fun validate(path: String): List<String> {
        val reason = when {
            path.isEmpty() -> "path is empty"
            !path.startsWith("/dsh/") -> "path is outside /dsh"
            path.endsWith("/") -> "path has a trailing slash"
            path.indexOf('\u0000') >= 0 -> "path contains NUL"
            else -> null
        }
        if (reason != null) {
            throw WalException("BAD_PATH", reason)
        }
        val components = path.removePrefix("/dsh/").split('/')
        if (components.size < 2) {
            throw WalException("BAD_PATH", "a mutation target is below a sink root: $path")
        }
        val root = components.first()
        if (root !in ROOTS) {
            throw WalException("BAD_PATH", "path root is not home or workspace: $path")
        }
        for (component in components) {
            if (component.isEmpty()) {
                throw WalException("BAD_PATH", "path has an empty component: $path")
            }
            if (component == "." || component == "..") {
                throw WalException("BAD_PATH", "path has a relative component: $path")
            }
        }
        return components
    }
}
