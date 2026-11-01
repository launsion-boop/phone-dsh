// phone-dsh — :engine / com.phonedsh.engine: HTTP path -> materialized bundle file.
// SPDX-License-Identifier: MIT
//
// The loopback origin (:net) serves the launch page and owns the WebSocket. The
// worker's subresources (`boot.js`, `worker-entry.js`, `image.tar.gz`, `lazy/*`)
// are served by :engine from the materialized directory through
// WebViewClient.shouldInterceptRequest: the :net gate is header-or-launch-page
// only, and a WebView subresource request can carry neither a bearer header nor
// (on :net today) the launch cookie. See README, "Loopback API seams".
//
// This file is the security boundary for that path and has no android.* import:
// the URL -> file mapping is unit-tested on the JVM. The rules mirror :net's
// StaticAssetStore on purpose (no empty segment, no `.`/`..`, no backslash, NUL,
// percent or colon, and the resolved path must stay under the root).

package com.phonedsh.engine

import java.nio.file.Files
import java.nio.file.Path

/** Read-only view of one materialized worker bundle directory. */
class WorkerFileStore(root: Path) {
    private val root: Path = root.toAbsolutePath().normalize()

    init {
        require(Files.isDirectory(this.root)) { "the worker bundle directory is not a directory: $root" }
    }

    /**
     * Maps one request path (query already stripped by the caller) to a regular
     * file under the bundle root, or null for everything that must be a 404.
     */
    fun resolve(urlPath: String): Path? {
        val path = urlPath.substringBefore('?')
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
        val normalized = candidate.normalize()
        if (!normalized.startsWith(root)) return null
        // Mirror :net's StaticAssetStore: a directory request serves its index.html.
        if (Files.isDirectory(normalized)) {
            val index = normalized.resolve(INDEX_FILE).normalize()
            if (!index.startsWith(root) || !Files.isRegularFile(index)) return null
            return index
        }
        return normalized.takeIf { Files.isRegularFile(it) }
    }

    /** Media type of [file], from its file name. */
    fun contentType(file: Path): String = contentTypeFor(file.fileName.toString())

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
         * Media types the worker bundle uses. `.wasm` must be `application/wasm`
         * (streaming compilation is refused otherwise) and `.js`/`.mjs` are
         * `text/javascript` (the WHATWG value, not the retired
         * `application/javascript`).
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
            "xml" to "application/xml",
            "gz" to "application/gzip",
            "tgz" to "application/gzip",
            "tar" to "application/x-tar",
            "woff" to "font/woff",
            "woff2" to "font/woff2",
            "ttf" to "font/ttf",
            "otf" to "font/otf",
            "pdf" to "application/pdf",
        )

        /** Media type of a file name, or [OCTET_STREAM] when the extension is unknown. */
        fun contentTypeFor(fileName: String): String {
            val dot = fileName.lastIndexOf('.')
            if (dot <= 0 || dot == fileName.length - 1) return OCTET_STREAM
            return MEDIA_TYPES[fileName.substring(dot + 1).lowercase()] ?: OCTET_STREAM
        }
    }
}
