// Preview path resolution: one normal form, one safe workspace root.
// SPDX-License-Identifier: MIT
//
// Mirror source: `PreviewSurface.swift:37`–`:64` of the iOS PR #15 (commit
// `8dd17496`), `enum PreviewPathResolver`. The iOS preview has exactly one target
// (`.workspaceFile(path)`) and every path reaching it — a tool row, a chat path, a
// files row, a Markdown image — goes through these two functions. Android had no
// equivalent (only an extension classification, `FilesPage.classifyFileKind`), so
// this file is the whole safety boundary and it is ported item by item:
//
//   iOS `normalize(_:)`                     → [PreviewPathResolver.normalize]
//   1. trim whitespace and newlines          → 1. same
//   2. strip a leading `file://`             → 2. same
//   3. strip a leading `sandbox:`            → 3. same
//   4. percent-decode                        → 4. same (strict `%XX` only; a
//                                              malformed escape keeps the input,
//                                              like Foundation's `nil`)
//   5. strip a leading `/dsh/workspace/`     → 5. same
//   6. strip a leading `./`                  → 6. same
//   7. NFC (precomposed canonical)           → 7. same (`Normalizer.Form.NFC`)
//   8. trim `/` from both ends               → 8. same
//
//   iOS `fileURL(for:)`                     → [PreviewPathResolver.resolve]
//   1. root = `<workspace>/materialized/workspace`, symlinks resolved
//   2. reject an empty path                   → [PreviewUnresolved.REJECTED]
//   3. reject any `..` segment                → [PreviewUnresolved.REJECTED]
//   4. candidate = root + path, symlinks resolved
//   5. require `candidate` under `root + "/"` → [PreviewUnresolved.REJECTED]
//   6. require `isRegularFile`                → [PreviewUnresolved.NOT_A_FILE]
//
// The `..` check runs **before** the filesystem is touched and **again** through
// the resolved path (`toRealPath`), so a symlink planted inside the workspace that
// points outside is refused by step 5 even though step 3 saw no `..`. That is the
// one property this file exists for and it is the property the device test
// (`PreviewSurfaceDeviceTest`) proves with a real symlink.
//
// Three deliberate Android deviations, all *more* honest rather than more
// permissive, and all pinned by `PreviewPathResolverTest`:
//
//   * **Reasons are distinguished.** iOS returns `nil` for "still being written",
//     "escaped the root" and "not a file" alike, so its 12 retries burn six
//     seconds on a path that can never resolve. Here a refusal is final at once
//     and only a genuinely missing candidate is retried (see [isRetryable]).
//   * **`NO_WORKSPACE` is its own answer.** A host that reported no workspace root
//     is not a workspace that is empty; the preview says so instead of waiting.
//   * **The size comes from the resolved file**, never from a listing that may be
//     stale, so the unsupported card's byte count is the bytes on disk.
package com.phonedsh.ui.surface.preview

import java.io.IOException
import java.nio.file.Files
import java.nio.file.LinkOption
import java.nio.file.NoSuchFileException
import java.nio.file.Path
import java.text.Normalizer

/**
 * One resolved (or refused) preview path.
 *
 * @property relativePath the path after [PreviewPathResolver.normalize]; carried
 *   by both cases so a failure can name the file the user asked for.
 */
public sealed interface PreviewResolution {
    /** The normalized path the request named. */
    public val relativePath: String

    /**
     * The file exists, is a regular file, and lives inside the workspace root.
     *
     * @param file the **resolved** path (symlinks already followed); every read
     *   goes through this value, never through a re-join of root and path.
     * @param sizeBytes the measured size; `0` for an empty file is a fact, not a
     *   missing read.
     */
    public data class Resolved(
        override val relativePath: String,
        val file: Path,
        val sizeBytes: Long,
    ) : PreviewResolution

    /** The path cannot be previewed; [reason] says which of the four it is. */
    public data class Unresolved(
        override val relativePath: String,
        val reason: PreviewUnresolved,
    ) : PreviewResolution
}

/**
 * Why a path did not resolve.
 *
 * The distinction is what makes the preview honest: [MISSING] and [NO_WORKSPACE]
 * can still become a file (a tool reports a path a moment before the bytes land,
 * the host creates the workspace on boot), the other two can never.
 */
public enum class PreviewUnresolved {
    /**
     * The path itself is refused: empty, a `..` segment, or outside the root.
     *
     * Refused **before** any IO and refused again after symlink resolution; this
     * is the security boundary, never a retry.
     */
    REJECTED,

    /** Nothing at the resolved location yet: the file is still being written. */
    MISSING,

    /** The entry exists but is not a regular file (a directory, a fifo, …). */
    NOT_A_FILE,

    /** The host reported no materialized workspace root at all. */
    NO_WORKSPACE,
    ;

    /** True when waiting could still produce a file (`PreviewPolicy` retries these). */
    public val isRetryable: Boolean
        get() = this == MISSING || this == NO_WORKSPACE
}

/**
 * The normal form of a preview path, and the only place a path becomes a [Path].
 *
 * Every function is pure (no clock, no environment) except [resolve], which reads
 * the filesystem and is therefore called from the route on an IO dispatcher, never
 * from a page body.
 */
public object PreviewPathResolver {
    /** The D4 mount path the Worker uses; a tool row quotes paths under it. */
    private const val WORKSPACE_MOUNT: String = "/dsh/workspace/"

    /** The two prefixes the baseline strips before anything else (`:41`). */
    private val STRIPPED_PREFIXES: List<String> = listOf("file://", "sandbox:")

    /** A path separator, as a char array for [String.split]. */
    private const val SEPARATOR: Char = '/'

    /** The parent segment the resolver refuses on sight. */
    private const val PARENT: String = ".."

    private const val PERCENT: Char = '%'
    private const val HEX_RADIX: Int = 16
    private const val HEX_DIGITS: Int = 2
    private const val ALL_BITS: Int = 0xFF

    /**
     * The baseline's normal form (`PreviewSurface.swift:38`).
     *
     * Idempotent: `normalize(normalize(x)) == normalize(x)` for every input, which
     * is what lets a route store the normalized path as its identity and a page
     * re-normalize the same value without drift.
     */
    public fun normalize(raw: String): String {
        var path = raw.trim()
        for (prefix in STRIPPED_PREFIXES) {
            if (path.startsWith(prefix)) path = path.removePrefix(prefix)
        }
        path = percentDecode(path)
        if (path.startsWith(WORKSPACE_MOUNT)) path = path.removePrefix(WORKSPACE_MOUNT)
        if (path.startsWith("./")) path = path.removePrefix("./")
        return Normalizer.normalize(path, Normalizer.Form.NFC).trim(SEPARATOR)
    }

    /**
     * Resolves [raw] against the materialized workspace root.
     *
     * @param workspaceRoot the host's materialized workspace
     *   (`<workspace>/materialized/workspace`), or `null` when the host reported
     *   none — the honest answer for a host that has no workspace yet.
     * @param raw a path as any surface quoted it: relative, `./`-prefixed,
     *   `/dsh/workspace/`-prefixed, `file://`-prefixed, percent-encoded, or NFD.
     */
    public fun resolve(workspaceRoot: Path?, raw: String): PreviewResolution {
        val relative = normalize(raw)
        // `:49`: an empty path and any `..` segment are refused before the disk is
        // touched. `split` on a normalized (trimmed) path has no empty segments
        // other than the ones a `//` produced, which are harmless.
        if (relative.isEmpty() || relative.split(SEPARATOR).contains(PARENT)) {
            return PreviewResolution.Unresolved(relative, PreviewUnresolved.REJECTED)
        }
        if (workspaceRoot == null) {
            return PreviewResolution.Unresolved(relative, PreviewUnresolved.NO_WORKSPACE)
        }
        val root = toRealDirectory(workspaceRoot)
            ?: return PreviewResolution.Unresolved(relative, PreviewUnresolved.NO_WORKSPACE)
        val candidate = root.resolve(relative).normalize()
        // The lexical containment check: `root/../../etc/passwd` never reaches the
        // disk even if the caller skipped the segment check above.
        if (candidate == root || !candidate.startsWith(root)) {
            return PreviewResolution.Unresolved(relative, PreviewUnresolved.REJECTED)
        }
        val real = try {
            candidate.toRealPath()
        } catch (_: NoSuchFileException) {
            return PreviewResolution.Unresolved(relative, PreviewUnresolved.MISSING)
        } catch (_: IOException) {
            // An unreadable path (`EACCES`, `ELOOP`, …) is not distinguishable from
            // a missing one here and both can still change under us; the read that
            // follows reports the real reason if it is still broken.
            return PreviewResolution.Unresolved(relative, PreviewUnresolved.MISSING)
        }
        // The resolved containment check: a symlink inside the root that points
        // outside it resolves outside and is refused here (`:52`).
        if (!real.startsWith(root)) {
            return PreviewResolution.Unresolved(relative, PreviewUnresolved.REJECTED)
        }
        if (!Files.isRegularFile(real, LinkOption.NOFOLLOW_LINKS)) {
            return PreviewResolution.Unresolved(relative, PreviewUnresolved.NOT_A_FILE)
        }
        val size = try {
            Files.size(real)
        } catch (_: IOException) {
            return PreviewResolution.Unresolved(relative, PreviewUnresolved.MISSING)
        }
        return PreviewResolution.Resolved(relative, real, size)
    }

    /**
     * The root as a resolved directory, or `null` when it does not exist (yet).
     *
     * `toRealPath` is what makes the containment check sound: comparing a resolved
     * candidate against an unresolved root would accept `/root/../root2` when the
     * root itself is a symlink.
     */
    private fun toRealDirectory(root: Path): Path? = try {
        val real = root.toRealPath()
        if (Files.isDirectory(real)) real else null
    } catch (_: IOException) {
        null
    }

    /**
     * Foundation's `removingPercentEncoding`, in strict mode.
     *
     * `URLDecoder` is deliberately not used: it decodes `+` as a space, which is a
     * form-encoding rule and would rename a file on every preview. A malformed
     * escape keeps the whole input, which is what iOS does when
     * `removingPercentEncoding` returns `nil`.
     */
    private fun percentDecode(path: String): String {
        if (!path.contains(PERCENT)) return path
        val output = StringBuilder(path.length)
        var index = 0
        while (index < path.length) {
            if (path[index] != PERCENT) {
                output.append(path[index])
                index += 1
                continue
            }
            // A multi-byte scalar is encoded as a *run* of consecutive escapes, so
            // the run is decoded as one UTF-8 sequence. A lone escape before a
            // literal character is its own run and decodes to one ASCII byte.
            val run = java.io.ByteArrayOutputStream(HEX_DIGITS)
            while (index < path.length && path[index] == PERCENT) {
                if (index + HEX_DIGITS >= path.length) return path
                val high = Character.digit(path[index + 1], HEX_RADIX)
                val low = Character.digit(path[index + 2], HEX_RADIX)
                if (high < 0 || low < 0) return path
                run.write((high shl 4) or low and ALL_BITS)
                index += HEX_DIGITS + 1
            }
            output.append(decodeStrict(run.toByteArray()) ?: return path)
        }
        return output.toString()
    }
}

/**
 * Decodes [bytes] as UTF-8 with no replacement characters, or returns `null`.
 *
 * Shared by the resolver's percent decoder and the pager; a single strict decoder
 * keeps "is this text?" answering the same question in both places.
 */
internal fun decodeStrict(bytes: ByteArray): String? {
    if (bytes.isEmpty()) return ""
    val decoder = Charsets.UTF_8.newDecoder()
        .onMalformedInput(java.nio.charset.CodingErrorAction.REPORT)
        .onUnmappableCharacter(java.nio.charset.CodingErrorAction.REPORT)
    return try {
        decoder.decode(java.nio.ByteBuffer.wrap(bytes)).toString()
    } catch (_: java.nio.charset.CharacterCodingException) {
        null
    }
}
