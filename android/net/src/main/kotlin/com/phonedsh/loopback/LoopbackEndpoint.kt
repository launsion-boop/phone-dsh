// phone-dsh — :loopback / com.phonedsh.loopback: the port + token pair of one start.
// SPDX-License-Identifier: MIT
//
// This is the only object that hands the token back to the caller (:engine).
// Its toString() is deliberately redacted: a value put in a log line, a crash
// report or a screenshot must never carry the secret.

package com.phonedsh.loopback

import java.net.URLEncoder

/**
 * The result of one successful [LoopbackServer.start].
 *
 * [origin] is `http://127.0.0.1:<port>` with no trailing slash; every URL this
 * class builds hangs off that string. The token is *not* part of [origin]: a
 * URL only carries it when the caller explicitly asks for it through
 * [launchUrl], which exists for the one page that reads the token from its own
 * query string (`examples/probe-app/Bundle/worker/boot.js`).
 *
 * Instances come from [LoopbackServer.start]; the constructor is public only so
 * a test can build a standalone value.
 */
data class LoopbackEndpoint(
    /** The actually bound port (never 0, even when the configuration asked for 0). */
    val port: Int,
    /** The per-start token. Redacted by [toString]. */
    val token: String,
    /** `http://127.0.0.1:<port>`, no trailing slash. */
    val origin: String,
) {
    val host: String get() = LoopbackConfiguration.LOOPBACK_HOST

    /** Absolute URL of [path] on this origin. The token is not attached. */
    fun urlFor(path: String): String {
        require(path.startsWith("/")) { "path must start with '/', was '$path'" }
        return origin + path
    }

    /** The one WebSocket endpoint, with the token attached as `?token=` **only** when asked. */
    fun channelUrl(includeToken: Boolean = false): String {
        val url = "ws" + origin.removePrefix("http") + LoopbackConfiguration.CHANNEL_PATH
        return if (includeToken) "$url?token=${encode(token)}" else url
    }

    /**
     * The D22 launch URL: `origin/?token=...&<params>`.
     *
     * This is the single place where the token is allowed in a URL. A browser
     * that opens it gets `303 Location: /` plus the [LaunchCookie], so the page
     * itself is reached without the token in the address bar (see
     * `LoopbackServer.start` and `LaunchCookie`).
     *
     * The App's engine does not use this spelling for its own page load: it
     * seeds the cookie directly and hands the token to the worker through the
     * `env` page parameter instead. [includeToken] exists so a caller can build
     * the same URL for a probe without the secret.
     */
    fun launchUrl(params: Map<String, String> = emptyMap(), includeToken: Boolean = true): String {
        val query = LinkedHashMap<String, String>()
        if (includeToken) query["token"] = token
        for ((name, value) in params) {
            require(name.isNotEmpty()) { "a query parameter name must not be empty" }
            query[name] = value
        }
        if (query.isEmpty()) return urlFor("/")
        val encoded = query.entries.joinToString("&") { (name, value) -> "${encode(name)}=${encode(value)}" }
        return urlFor("/") + "?" + encoded
    }

    /** Never prints the token. */
    override fun toString(): String =
        "LoopbackEndpoint(origin=$origin, port=$port, token=<redacted>)"

    // `URLEncoder.encode(String, Charset)` is API 33+; the app's minSdk is 26 and
    // this overload is not desugared, so calling it would throw NoSuchMethodError on
    // API 26-32. The String-charset overload exists on every API level.
    private fun encode(value: String): String = URLEncoder.encode(value, Charsets.UTF_8.name())
}
