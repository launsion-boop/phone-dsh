// phone-dsh — :net / com.phonedsh.gateway: the egress allow-list.
// SPDX-License-Identifier: MIT
//
// Entry syntax is the host one: a bare host (any port), `host:port`,
// `scheme://host[:port]`, `*`, `scheme://*` and `*.suffix` (apex included).
// The list is the only gate: loopback, private and public literals are treated
// identically, so an unlisted 127.0.0.1 is denied exactly like an unlisted
// public host (vectors gw-egress-001..005). The MCP grant is a second, exact
// scheme/host/effective-port/normalized-path authorizer layered on top of the
// same gate; it never widens the static list.

package com.phonedsh.gateway

/** One entry of `allowedUpstreamHosts`. */
data class GatewayHostRule(
    val scheme: String?,
    val host: String,
    val port: Int?,
) {
    val isWildcard: Boolean
        get() = host == "*" || host.startsWith("*.")

    fun matches(url: GatewayUrl): Boolean {
        if (!url.isHttp) return false
        if (scheme != null && scheme != url.scheme) return false
        if (!hostMatches(url.host, host)) return false
        // A rule without a port accepts any effective port; an explicit port
        // compares the effective one, so `:443` admits `https://host/path`.
        if (port != null && url.effectivePort != port) return false
        return true
    }

    companion object {
        /** Parses one entry, or returns null when it is blank or malformed. */
        fun parse(raw: String): GatewayHostRule? {
            var text = raw.trim().lowercase()
            if (text.isEmpty()) return null
            var scheme: String? = null
            val separator = text.indexOf("://")
            if (separator >= 0) {
                scheme = text.substring(0, separator)
                if (scheme != "http" && scheme != "https") return null
                text = text.substring(separator + 3)
            }
            val slash = text.indexOf('/')
            if (slash >= 0) text = text.substring(0, slash)
            var port: Int? = null
            val colon = text.lastIndexOf(':')
            if (colon >= 0) {
                val suffix = text.substring(colon + 1)
                if (suffix.isNotEmpty() && suffix.all { it in '0'..'9' }) {
                    val parsed = suffix.toIntOrNull() ?: return null
                    if (parsed <= 0 || parsed > 65535) return null
                    port = parsed
                    text = text.substring(0, colon)
                }
            }
            if (text.isEmpty()) return null
            return GatewayHostRule(scheme = scheme, host = text, port = port)
        }

        /** `*` admits every host; `*.suffix` admits the apex and every host below. */
        fun hostMatches(candidate: String, pattern: String): Boolean {
            if (pattern == "*") return true
            if (pattern.startsWith("*.")) {
                val suffix = pattern.substring(2)
                if (suffix.isEmpty()) return false
                return candidate == suffix || candidate.endsWith(".$suffix")
            }
            return candidate == pattern
        }
    }
}

/** The single egress decision point: static rules plus an optional MCP grant. */
interface EgressPolicy {
    /** True when [url] may be contacted at all (initial request or a hop). */
    fun permits(url: GatewayUrl): Boolean

    /** True when [url] is admitted by the exact-URL MCP egress grant. */
    fun admitsMcpGrant(url: GatewayUrl): Boolean
}

/**
 * `allowedUpstreamHosts` plus an optional exact-URL MCP grant.
 *
 * An empty rule list denies every host; there is no implicit loopback or
 * RFC1918 exemption, and a wildcard admits every literal host it covers.
 */
class AllowListEgressPolicy(
    private val rules: List<GatewayHostRule>,
    private val mcpGrant: CredentialOriginScope? = null,
) : EgressPolicy {
    override fun permits(url: GatewayUrl): Boolean =
        rules.any { it.matches(url) } || admitsMcpGrant(url)

    override fun admitsMcpGrant(url: GatewayUrl): Boolean =
        mcpGrant?.matches(url) == true
}
