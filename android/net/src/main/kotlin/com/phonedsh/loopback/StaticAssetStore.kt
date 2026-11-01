// phone-dsh — :loopback / com.phonedsh.loopback: static worker assets from one directory.
// SPDX-License-Identifier: MIT
//
// java.nio only (this module is pure JVM and must not touch android.*). The
// resolver is the security boundary between an HTTP path and the filesystem:
// no empty segment, no `.`/`..`, no backslash, no NUL, no percent escape, and
// the real path must stay under the real asset root after symlinks resolve.

package com.phonedsh.loopback

import java.io.IOException
import java.nio.file.Files
import java.nio.file.Path

internal class StaticAssetStore(assetsDir: Path) {
    /** Real (symlink-resolved) root every served file must stay under. */
    private val root: Path

    init {
        val absolute = assetsDir.toAbsolutePath().normalize()
        require(Files.isDirectory(absolute)) { "assetsDir is not a directory: $absolute" }
        root = absolute.toRealPath()
    }

    /**
     * Maps one request path (no query string) to a regular file under [root].
     *
     * Returns null for anything that must be a 404: traversal attempts, missing
     * files, directories without an `index.html` and symlinks escaping the root.
     */
    fun resolve(requestPath: String): Path? {
        val path = requestPath.substringBefore('?')
        if (!path.startsWith("/")) return null
        val relative = path.removePrefix("/")
        val segments = if (relative.isEmpty()) {
            listOf(INDEX_FILE)
        } else {
            relative.trimEnd('/').split('/')
        }
        if (segments.isEmpty()) return null
        for (segment in segments) {
            if (!isSafeSegment(segment)) return null
        }
        var candidate = root
        for (segment in segments) candidate = candidate.resolve(segment)
        val real = realPathOrNull(candidate) ?: return null
        // A symlink that points outside the asset tree is not served.
        if (!real.startsWith(root)) return null
        if (Files.isDirectory(real)) {
            val index = realPathOrNull(real.resolve(INDEX_FILE)) ?: return null
            if (!index.startsWith(root) || !Files.isRegularFile(index)) return null
            return index
        }
        return real.takeIf { Files.isRegularFile(it) }
    }

    /** Media type of one resolved file, from its file name. */
    fun contentType(file: Path): String = contentTypeFor(file.fileName.toString())

    private fun realPathOrNull(path: Path): Path? = try {
        path.toRealPath()
    } catch (missing: IOException) {
        null
    }

    private fun isSafeSegment(segment: String): Boolean =
        segment.isNotEmpty() &&
            segment != "." &&
            segment != ".." &&
            segment.length <= MAX_SEGMENT_LENGTH &&
            segment.none { it == '\\' || it == '\u0000' || it == '%' || it == ':' }

    companion object {
        const val INDEX_FILE: String = "index.html"
        const val OCTET_STREAM: String = "application/octet-stream"
        private const val MAX_SEGMENT_LENGTH = 255

        /**
         * Media types the worker bundle actually uses.
         *
         * `.wasm` must be `application/wasm` (streaming compilation is refused
         * otherwise) and `.js`/`.mjs` are `text/javascript` (the WHATWG value,
         * not the retired `application/javascript`); `.map` is JSON.
         */
        private val MEDIA_TYPES: Map<String, String> = mapOf(
            "html" to "text/html; charset=utf-8",
            "htm" to "text/html; charset=utf-8",
            "js" to "text/javascript; charset=utf-8",
            "mjs" to "text/javascript; charset=utf-8",
            "cjs" to "text/javascript; charset=utf-8",
            "json" to "application/json; charset=utf-8",
            "map" to "application/json; charset=utf-8",
            "webmanifest" to "application/manifest+json; charset=utf-8",
            "css" to "text/css; charset=utf-8",
            "wasm" to "application/wasm",
            "svg" to "image/svg+xml",
            "png" to "image/png",
            "jpg" to "image/jpeg",
            "jpeg" to "image/jpeg",
            "gif" to "image/gif",
            "webp" to "image/webp",
            "ico" to "image/x-icon",
            "txt" to "text/plain; charset=utf-8",
            "md" to "text/plain; charset=utf-8",
            "xml" to "application/xml; charset=utf-8",
            "gz" to "application/gzip",
            "tgz" to "application/gzip",
            "tar" to "application/x-tar",
            "woff" to "font/woff",
            "woff2" to "font/woff2",
            "ttf" to "font/ttf",
            "otf" to "font/otf",
            "pdf" to "application/pdf",
        )

        fun contentTypeFor(fileName: String): String {
            val dot = fileName.lastIndexOf('.')
            if (dot <= 0 || dot == fileName.length - 1) return OCTET_STREAM
            return MEDIA_TYPES[fileName.substring(dot + 1).lowercase()] ?: OCTET_STREAM
        }
    }
}
