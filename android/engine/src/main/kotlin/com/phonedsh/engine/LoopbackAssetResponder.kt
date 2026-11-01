// phone-dsh — :engine / com.phonedsh.engine: worker assets for the WebView, not the origin.
// SPDX-License-Identifier: MIT
//
// Why the WebView reads its subresources from disk instead of the origin:
//
//   * the plan (§D2) asks `:engine` to serve static resources through
//     shouldInterceptRequest, which this file does: the main frame still comes
//     from the real origin (requirement 8), the WebSocket still goes to the real
//     origin, only GET/HEAD for same-origin bundle files is answered here;
//   * the bundle's big archives (`image.tar.gz` is ~25 MB, `lazy/*` is more)
//     never cross the Ktor origin: reading them from the materialized directory
//     keeps the HTTP layer for the page and the channel;
//   * the origin now accepts the D22 launch cookie (see `:net`'s LaunchCookie),
//     so this is no longer the only way to authenticate a subresource; keeping
//     the interceptor means a subresource load does not depend on cookie
//     plumbing at all.
//
// ---- what this interceptor must NOT answer (M2) ----------------------------
// `shouldInterceptRequest` sees request *types* it was never meant to own: the
// Worker's model client POSTs to `/v1/messages` on this same origin, and a
// route like `/v1/models` is a GET that has no bundle file behind it. Answering
// those here would shadow the `:net` model edge: measured before the fix, the
// Worker's real Messages POST came back `405` from this class and never reached
// the proxy at all. The rule is therefore narrow and data-driven: answer only a
// GET/HEAD whose path resolves to a file that actually exists in the
// materialized bundle; everything else returns null and is performed by the
// WebView against the origin, which owns auth and routing.
//
// The origin is the security boundary for the token, this file for the bundle
// path. It runs on a WebView network thread: no UI access, no android.webkit
// state beyond the immutable store and port.

package com.phonedsh.engine

import android.webkit.WebResourceRequest
import android.webkit.WebResourceResponse
import com.phonedsh.loopback.LoopbackConfiguration
import java.io.ByteArrayInputStream
import java.io.FileInputStream
import java.io.IOException
import java.nio.file.Files
import java.nio.file.Path

/**
 * One file served outside the immutable bundle.
 *
 * The boot overlay (`wal.md` §8) is rebuilt per page load, so it cannot live in
 * the version-stamped bundle directory.
 *
 * @property urlPath the exact request path, query stripped.
 * @property file the file behind it; a missing file is a fall-through, never a
 *   crash.
 * @property contentType the media type to declare.
 */
data class ServedAsset(
    val urlPath: String,
    val file: Path,
    val contentType: String,
)

/**
 * Answers [WebResourceRequest]s for one materialized bundle.
 *
 * Returns null for anything this class does not own, which tells the WebView to
 * use the network (i.e. the loopback origin): the launch page (`/`,
 * `/index.html`), the WebSocket endpoint (`/channel`), every non-GET/HEAD
 * request (the Worker's model-protocol POSTs) and every GET whose path is not a
 * file of the bundle (a model-protocol GET such as `/v1/models`, or a genuinely
 * missing asset, which the origin answers with its own 404).
 */
class LoopbackAssetResponder(
    private val store: WorkerFileStore,
    private val port: Int,
    private val logger: EngineLogger,
    /**
     * Files served outside the immutable bundle; empty for a composition that has
     * none.
     *
     * The one entry the engine publishes is the boot overlay (`wal.md` §8): it is
     * rebuilt on every page load, so it cannot live in the version-stamped bundle
     * directory. The supplier is read on a WebView network thread.
     */
    private val servedAssets: () -> List<ServedAsset> = { emptyList() },
) {
    /** A [WebResourceResponse] for a same-origin bundle file, or null to fall through. */
    fun respond(request: WebResourceRequest): WebResourceResponse? {
        return try {
            val url = request.url ?: return null
            if (url.scheme != "http" || url.host != LOOPBACK_HOST || url.port != port) return null
            val path = url.path ?: return null
            if (path == "/" || path == "/${WorkerFileStore.INDEX_FILE}") return null
            if (path == LoopbackConfiguration.CHANNEL_PATH) return null
            val method = request.method
            if (!isStaticRead(method)) {
                // The model edge lives on this origin and its requests are POSTs.
                // A 405 from here would never reach the Ktor route that owns them.
                logger.debug("bundle: $method $path -> origin (not a static read)")
                return null
            }
            val asset = resolveAsset(path)
            if (asset == null) {
                // Could be a missing asset or a model-protocol GET: the origin
                // decides, because only it knows the mounted route table.
                logger.debug("bundle: $method $path -> origin (no such bundle file)")
                return null
            }
            val file = asset.file
            logger.debug("bundle: $method $path -> 200 (${file.fileName}, ${Files.size(file)} bytes)")
            val stream = if (method == HEAD_METHOD) {
                ByteArrayInputStream(ByteArray(0))
            } else {
                FileInputStream(file.toFile())
            }
            WebResourceResponse(
                asset.contentType,
                null,
                HttpStatus.OK,
                "OK",
                RESPONSE_HEADERS,
                stream,
            )
        } catch (missing: IOException) {
            logger.error("bundle asset read failed: ${EngineLogText.reasonOf(missing)}")
            error(HttpStatus.INTERNAL_ERROR, "asset_read_failed")
        } catch (failure: Throwable) {
            // shouldInterceptRequest must not throw: a thrown callback fails the load
            // with an opaque net error and hides the real cause.
            logger.error("bundle asset responder failed: ${EngineLogText.reasonOf(failure)}")
            error(HttpStatus.INTERNAL_ERROR, "asset_responder_failed")
        }
    }

    /**
     * True only for the two methods that read a file.
     *
     * Everything else is a proxy/API request the origin owns. The predicate is a
     * named function so a JVM test can pin the rule without a WebView.
     */
    internal fun isStaticRead(method: String): Boolean = method == GET_METHOD || method == HEAD_METHOD

    /**
     * The asset behind one request path, or null for everything this class does
     * not own.
     *
     * Order: the bundle first (it is immutable and cannot change under a request),
     * then [servedAssets] by exact path. The overlay path is matched exactly rather
     * than resolved, so a page cannot ask for an arbitrary file by walking the
     * lookup (`/image/overlay/../../worker/...`).
     */
    internal fun resolveAsset(urlPath: String): ServedAsset? {
        val path = urlPath.substringBefore('?')
        store.resolve(path)?.let { file -> return ServedAsset(path, file, store.contentType(file)) }
        val served = servedAssets().firstOrNull { it.urlPath == path }
            ?: return null
        return served.takeIf { Files.isRegularFile(it.file) }
    }

    private fun error(status: Int, reason: String): WebResourceResponse = WebResourceResponse(
        "application/json",
        "utf-8",
        status,
        reason,
        RESPONSE_HEADERS,
        ByteArrayInputStream("""{"error":"$reason"}""".toByteArray(Charsets.UTF_8)),
    )

    private companion object {
        /** Same host the origin binds; :net never listens on anything else. */
        const val LOOPBACK_HOST = "127.0.0.1"

        const val GET_METHOD = "GET"
        const val HEAD_METHOD = "HEAD"

        /**
         * Loopback files are per-start; never let the WebView cache one.
         *
         * `Cross-Origin-Resource-Policy` is belt and braces. The measured blocker
         * was `Cross-Origin-Embedder-Policy: require-corp` on the launch page,
         * which made Chromium reject intercepted *worker* scripts with
         * `net::ERR_BLOCKED_BY_RESPONSE` (see the crossOriginIsolation = false
         * decision in WebViewEngine). This header alone did not fix it; keep it for
         * a future page-level COEP.
         */
        val RESPONSE_HEADERS: Map<String, String> = mapOf(
            "Cache-Control" to "no-store",
            "X-Content-Type-Options" to "nosniff",
            "Cross-Origin-Resource-Policy" to "same-origin",
        )
    }

    /** HTTP statuses the responder can produce (avoids an OkHttp/HttpURLConnection dep). */
    private object HttpStatus {
        const val OK = 200
        const val INTERNAL_ERROR = 500
    }
}
