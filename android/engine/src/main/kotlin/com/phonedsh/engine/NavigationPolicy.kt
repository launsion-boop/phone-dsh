// phone-dsh — :engine / com.phonedsh.engine: the navigation whitelist (§15-3).
// SPDX-License-Identifier: MIT
//
// The page may navigate only inside the one loopback origin. Everything else —
// another port on 127.0.0.1, a public host, `file:`, `content:`, `javascript:`,
// `data:` — is blocked in WebViewClient.shouldOverrideUrlLoading. Pure Kotlin so
// the rule is unit-tested on the JVM; WebViewEngine owns the callback.

package com.phonedsh.engine

/**
 * Decides whether one navigation URL belongs to [origin].
 *
 * [origin] is the exact string from LoopbackEndpoint.origin: `http://127.0.0.1`
 * plus the bound port, no trailing slash. Matching is a string boundary check,
 * never a prefix-only match: `http://127.0.0.1:1234.evil.test/` is not the origin
 * `http://127.0.0.1:1234`.
 */
class NavigationPolicy(private val origin: String) {
    init {
        require(origin.startsWith("http://") && !origin.endsWith("/")) {
            "origin must be http://host:port without a trailing slash, was '$origin'"
        }
    }

    /** True for the origin root, any path below it, and blob URLs minted by it. */
    fun isAllowed(url: String?): Boolean {
        if (url.isNullOrEmpty()) return false
        if (url == origin) return true
        if (url.length > origin.length && url.startsWith(origin)) {
            val boundary = url[origin.length]
            if (boundary == '/' || boundary == '?' || boundary == '#') return true
        }
        // `blob:http://127.0.0.1:PORT/<uuid>` is minted by this origin; the Web UI
        // uses it for document previews. The embedded origin is checked verbatim.
        return url.startsWith("blob:$origin/")
    }

    /** The inverse of [isAllowed], for call sites that read better that way. */
    fun isBlocked(url: String?): Boolean = !isAllowed(url)
}
