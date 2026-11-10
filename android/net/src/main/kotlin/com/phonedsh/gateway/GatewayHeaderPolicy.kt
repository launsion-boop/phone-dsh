// phone-dsh — :net / com.phonedsh.gateway: request and response header policy.
// SPDX-License-Identifier: MIT
//
// Request side (§3): a denylist by name plus every `x-pdsh-*` internal header,
// the host-managed placeholder value dropped per value, then the credential
// applied last. The denylist is recorded in `stripped`; a value-level drop and
// a same-name override are not.
//
// Response side (§6): the response denylist is dropped, a non-structural value
// that carries an injected value is replaced whole by `[redacted]`, the media
// type is validated rather than substring-rewritten, the two MCP transport
// headers are withheld when they contain a secret, and `cache-control` always
// becomes `no-store` (vectors gw-hop-001..003, gw-resp-001..006, gw-log-001).

package com.phonedsh.gateway

/** Header names the caller may never forward. */
object GatewayRequestHeaders {
    /** The non-secret placeholder a Worker puts into a host-managed header. */
    const val HOST_MANAGED_PLACEHOLDER = "phone-host-injects-mcp-key"

    /** Removed by name before the credential is applied. */
    val DROPPED: Set<String> = linkedSetOf(
        "authorization", "proxy-authorization", "host", "connection",
        "content-length", "transfer-encoding", "accept-encoding", "expect",
        "upgrade", "te", "trailer", "proxy-connection",
        "cookie", "cookie2", "referer", "referrer",
    )

    /** Names whose presence means the Worker tried to supply a credential. */
    val WORKER_CREDENTIAL_HEADERS: Set<String> = setOf(
        "authorization", "proxy-authorization", "x-pdsh-upstream-authorization",
    )

    /** The tool-journal key; it alone survives, and only to a loopback target (§3). */
    const val JOURNAL_KEY = "x-pdsh-idempotency-key"

    fun isLoopbackHost(host: String?): Boolean =
        host != null && host.lowercase().trim('[', ']') in setOf("127.0.0.1", "::1", "localhost")

    fun isDropped(name: String, targetHost: String? = null): Boolean =
        name in DROPPED || (name.startsWith("x-pdsh-") && !(name == JOURNAL_KEY && isLoopbackHost(targetHost)))
}

/** What one request-header pass produced. */
data class SanitizedRequestHeaders(
    val headers: Map<String, String>,
    /** Caller header names removed by name, sorted. */
    val stripped: List<String>,
    /** 1 when the Worker supplied a credential header, otherwise 0. */
    val workerCredentialsDropped: Int,
    /** True when the Worker sent the host-managed placeholder value. */
    val placeholderSeen: Boolean,
)

interface RequestHeaderSanitizer {
    /** [targetHost] is the upstream host; only a loopback target keeps the journal key. */
    fun sanitize(callerHeaders: Map<String, String>, targetHost: String? = null): SanitizedRequestHeaders
}

/** The real rule: denylist by name, placeholder by value, credential last. */
class DenylistRequestHeaderSanitizer : RequestHeaderSanitizer {
    override fun sanitize(callerHeaders: Map<String, String>, targetHost: String?): SanitizedRequestHeaders {
        val outbound = LinkedHashMap<String, String>()
        val stripped = ArrayList<String>()
        var placeholderSeen = false
        var workerCredentialsDropped = 0
        for ((rawName, value) in callerHeaders) {
            val name = rawName.lowercase()
            val isWorkerCredential = name in GatewayRequestHeaders.WORKER_CREDENTIAL_HEADERS
            if (isWorkerCredential) workerCredentialsDropped = 1
            if (GatewayRequestHeaders.isDropped(name, targetHost)) {
                stripped.add(name)
                continue
            }
            if (value == GatewayRequestHeaders.HOST_MANAGED_PLACEHOLDER) {
                // The header name stays (it is not in `stripped`); the host
                // credential map supplies the real value, if any.
                placeholderSeen = true
                continue
            }
            outbound[name] = value
        }
        stripped.sort()
        return SanitizedRequestHeaders(
            headers = outbound,
            stripped = stripped,
            workerCredentialsDropped = workerCredentialsDropped,
            placeholderSeen = placeholderSeen,
        )
    }
}

/** The response headers handed to the Worker, already filtered and sanitized. */
interface ResponseHeaderSanitizer {
    fun sanitize(upstreamHeaders: Map<String, String>, secrets: List<String>): Map<String, String>
}

/** The real rule: response denylist, exact-value redaction, `no-store`. */
class DenylistResponseHeaderSanitizer : ResponseHeaderSanitizer {
    override fun sanitize(
        upstreamHeaders: Map<String, String>,
        secrets: List<String>,
    ): Map<String, String> {
        val filtered = LinkedHashMap<String, String>()
        for ((rawName, value) in upstreamHeaders) {
            val name = rawName.lowercase()
            if (name in DROPPED_RESPONSE_HEADERS) continue
            when (name) {
                "content-type" -> filtered[name] =
                    if (secrets.isEmpty()) value
                    else GatewayMediaTypes.sanitizeContentType(value, secrets)
                // Protocol inputs the MCP client needs exactly: if a secret
                // appears anywhere in the value, withhold the header (fail
                // closed) rather than forward a secret or a broken value.
                "mcp-session-id", "mcp-protocol-version" ->
                    if (!containsSecret(value, secrets)) filtered[name] = value
                else -> filtered[name] = redactHeaderValue(value, secrets)
            }
        }
        filtered["cache-control"] = "no-store"
        return filtered
    }

    companion object {
        /** Headers that must not be copied from the upstream response. */
        val DROPPED_RESPONSE_HEADERS: Set<String> = linkedSetOf(
            "connection", "keep-alive", "proxy-authenticate", "proxy-authorization",
            "te", "trailer", "transfer-encoding", "upgrade", "content-length",
            "content-encoding", "set-cookie", "set-cookie2", "clear-site-data",
            "alt-svc", "alt-used",
        )

        private fun containsSecret(value: String, secrets: List<String>): Boolean =
            secrets.any { it.isNotEmpty() && value.contains(it) }

        /**
         * A non-structural header value is protocol-meaningless diagnostic text.
         * When it carries an injected value the whole value is replaced, not
         * substring-rewritten: gw-resp-004 pins `[redacted]` as the complete
         * value of a `server saw Bearer <token>` echo. A partial rewrite would
         * forward attacker-shaped text around a placeholder.
         */
        private fun redactHeaderValue(value: String, secrets: List<String>): String =
            if (containsSecret(value, secrets)) "[redacted]" else value
    }
}

/** Media-type validation for the `content-type` response header. */
object GatewayMediaTypes {
    const val FALLBACK = "application/octet-stream"

    /** The two media types that give the response its protocol structure. */
    private val KNOWN_STRUCTURAL = setOf("application/json", "text/event-stream")

    private const val SEPARATORS = "()<>@,;:\\\"/[]?={} \t"

    fun sanitizeContentType(value: String, secrets: List<String>): String {
        val components = value.split(';')
        val mediaType = components.firstOrNull().orEmpty().trim()
        if (!isValidMediaType(mediaType)) return FALLBACK
        val lowercased = mediaType.lowercase()
        if (lowercased !in KNOWN_STRUCTURAL && secrets.any { it.isNotEmpty() && mediaType.contains(it) }) {
            return FALLBACK
        }
        val out = StringBuilder(mediaType)
        for (component in components.drop(1)) {
            val parameter = component.trim()
            val separator = parameter.indexOf('=')
            if (separator < 0) continue
            val name = parameter.substring(0, separator).trim().lowercase()
            val rawValue = parameter.substring(separator + 1).trim()
            if (!isValidToken(name)) continue
            if (secrets.any { it.isNotEmpty() && name.contains(it) }) continue
            if (!isValidParameterValue(rawValue)) continue
            if (secrets.any { it.isNotEmpty() && rawValue.contains(it) }) continue
            out.append("; ").append(name).append('=').append(rawValue)
        }
        return out.toString()
    }

    fun isValidMediaType(value: String): Boolean {
        val separator = value.indexOf('/')
        if (separator < 0) return false
        return isValidToken(value.substring(0, separator)) &&
            isValidToken(value.substring(separator + 1))
    }

    fun isValidToken(value: String): Boolean {
        if (value.isEmpty()) return false
        return value.all { character ->
            character.code in 0x21..0x7E && !SEPARATORS.contains(character)
        }
    }

    fun isValidParameterValue(value: String): Boolean {
        if (value.isEmpty()) return false
        if (value.startsWith("\"")) {
            if (value.length < 2 || !value.endsWith("\"")) return false
            val inner = value.substring(1, value.length - 1)
            return inner.all { it.code >= 0x20 && it.code != 0x7F }
        }
        return isValidToken(value)
    }
}
