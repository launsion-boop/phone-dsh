// phone-dsh — :net / com.phonedsh.gateway: the Bot MCP egress policy.
// SPDX-License-Identifier: MIT
//
// `spec/bot/v1/mcp-endpoint.md` §1/§1.1 put one exact scheme/host/effective-
// port/normalized-path policy in front of every Worker `/v1/http` request:
//
//   1. an exact MCP route (the four Bot routes and every user connector) is
//      admitted only with `X-PDSH-MCP-Egress` equal to this host start's
//      `PDSH_MCP_EGRESS_TOKEN`, compared byte-exact and in length-independent
//      constant time; a missing/empty/different value is the frozen 403 before
//      any credential is resolved or any socket is opened;
//   2. the same predicate selects the credential the gateway injects: the Bot
//      bearer for the four Bot routes, the stored header map for a user
//      connector;
//   3. a route with no Bot bearer fails closed instead of injecting an empty
//      Authorization; a host without an egress token admits no exact route.
//
// The generic Worker `/v1/http`, curl, git, WASI Python and PTC paths never add
// the header. Any request they make to an exact route is therefore rejected by
// (1), which is the documented new-App/old-Worker behaviour (§6).

package com.phonedsh.gateway

import com.phonedsh.loopback.LoopbackHttpEgress
import com.phonedsh.loopback.LoopbackHttpRequest
import com.phonedsh.loopback.LoopbackHttpResponse

/**
 * The per-host-start `PDSH_MCP_EGRESS_TOKEN` generator (mcp-endpoint.md §1.1).
 *
 * 16 bytes from the system CSPRNG as lowercase hex: the contract's 128-bit
 * minimum. The value lives in host memory only; it is not persisted, logged or
 * handed to the Worker outside the page `?env=` map.
 */
object McpEgressCredential {
    /** 16 random bytes is the contract's 128-bit minimum. */
    const val BYTE_COUNT: Int = 16

    private val random = java.security.SecureRandom()
    private val HEX = "0123456789abcdef".toCharArray()

    /** One fresh lowercase-hex credential, 32 characters for [BYTE_COUNT] = 16. */
    fun make(): String {
        val raw = ByteArray(BYTE_COUNT)
        random.nextBytes(raw)
        val out = CharArray(BYTE_COUNT * 2)
        for (index in raw.indices) {
            val value = raw[index].toInt() and 0xFF
            out[index * 2] = HEX[value ushr 4]
            out[index * 2 + 1] = HEX[value and 0x0F]
        }
        return String(out)
    }
}

/** The credential decision for one exact MCP route. */
sealed interface McpRouteCredential {
    /** The header map the host stores for this route (may be empty for a connector). */
    data class Headers(val headers: Map<String, String>) : McpRouteCredential

    /**
     * The route exists but its credential cannot be used: the Bot bearer is
     * absent, or this host start has no egress token. Fail closed.
     */
    data object Unavailable : McpRouteCredential
}

/**
 * Exact-origin/path policy shared by the `/v1/http` gate and the credential
 * router.
 *
 * The instance is host-start scoped: [installEgressToken] is replaced when the
 * loopback endpoint rotates, while a Worker restart reuses the same instance
 * and the same value (PC D13 rulings 12 and §1.1). Routes are added/removed in
 * place when the user edits a connector, so no host restart is needed.
 */
class McpEgressPolicy {
    private data class Route(
        val serverName: String,
        val scope: CredentialOriginScope,
        val headers: Map<String, String>,
        val botRoute: Boolean,
    )

    private val lock = Any()
    private var routes: Map<String, Route> = emptyMap()
    private var egressToken: String? = null

    /**
     * Installs this host start's `PDSH_MCP_EGRESS_TOKEN`. A later endpoint
     * rotation replaces it; `null` makes every exact route fail closed.
     */
    fun installEgressToken(token: String?) {
        synchronized(lock) { egressToken = token }
    }

    /** The current token, or null when this host has none. Never log it. */
    internal fun egressToken(): String? = synchronized(lock) { egressToken }

    /**
     * Adds or replaces one exact route.
     *
     * @throws IllegalArgumentException when [url] is not an absolute http(s)
     *   URL, or when a different server already owns the same exact route.
     */
    fun grant(serverName: String, url: String, headers: Map<String, String>) {
        require(serverName.isNotBlank()) { "an MCP route needs a server name" }
        val parsed = GatewayUrls.parse(url)
            ?: throw IllegalArgumentException("an MCP route must be an absolute http(s) URL")
        require(parsed.isHttp) { "an MCP route must be http(s)" }
        val route = Route(
            serverName = serverName,
            scope = parsed.credentialOriginScope,
            headers = LinkedHashMap(headers),
            botRoute = false,
        )
        synchronized(lock) {
            val duplicate = routes.values.firstOrNull {
                it.serverName != serverName && it.scope == route.scope
            }
            require(duplicate == null) {
                "the exact MCP route is already owned by ${duplicate?.serverName}"
            }
            routes = routes + (serverName to route)
        }
    }

    /**
     * Grants the four Bot runtime routes rooted at [endpointUrl] (`.../mcp`).
     *
     * [bearerToken] is the Bot listener token injected as `Authorization:
     * Bearer <token>`. When it is null/empty the routes are still tracked by
     * the egress gate (so they fail closed) but the credential provider refuses
     * to inject an empty bearer.
     */
    fun grantBotRuntimeEndpoint(endpointUrl: String, bearerToken: String?) {
        val parsed = GatewayUrls.parse(endpointUrl)
            ?: throw IllegalArgumentException("the Bot endpoint must be an absolute http(s) URL")
        require(parsed.isHttp) { "the Bot endpoint must be http(s)" }
        require(parsed.path == "/mcp") {
            "the Bot endpoint path must be exactly /mcp, was ${parsed.path}"
        }
        val authority = if (parsed.explicitPort != null) {
            "${parsed.host}:${parsed.explicitPort}"
        } else {
            parsed.host
        }
        val base = "${parsed.scheme}://$authority"
        val headers = if (bearerToken.isNullOrEmpty()) {
            emptyMap()
        } else {
            mapOf("Authorization" to "Bearer $bearerToken")
        }
        val entries = listOf(
            "dshbot" to "$base/mcp",
            "dshbot-identity-register" to "$base/identity/register",
            "dshbot-identity-cancel" to "$base/identity/cancel",
            "dshbot-approval" to "$base/approval",
        )
        synchronized(lock) {
            val next = LinkedHashMap(routes)
            for ((serverName, url) in entries) {
                val route = GatewayUrls.parse(url)
                    ?: throw IllegalArgumentException("the Bot route is not an absolute URL")
                val candidate = route.credentialOriginScope
                val duplicate = next.values.firstOrNull {
                    it.serverName != serverName && it.scope == candidate
                }
                require(duplicate == null) {
                    "the exact Bot route is already owned by ${duplicate?.serverName}"
                }
                next[serverName] = Route(
                    serverName = serverName,
                    scope = candidate,
                    headers = headers,
                    botRoute = true,
                )
            }
            routes = next
        }
    }

    /** Removes one server's route. Unknown names are a no-op. */
    fun revoke(serverName: String) {
        synchronized(lock) { routes = routes - serverName }
    }

    /** Removes every route (a host leaving the Bot runtime). */
    fun clear() {
        synchronized(lock) { routes = emptyMap() }
    }

    /** The admitted URLs, without header values, for status/diagnostics. */
    fun authorizedURLs(): List<String> = synchronized(lock) {
        routes.values
            .sortedBy { it.serverName }
            .map { urlString(it.scope) }
    }

    /** True when [url] is one of the exact MCP routes (the credential-injection predicate). */
    fun allowsEgressHost(url: String): Boolean {
        val parsed = GatewayUrls.parse(url) ?: return false
        return allowsEgressHost(parsed)
    }

    /** True when [url] is one of the exact MCP routes. */
    fun allowsEgressHost(url: GatewayUrl): Boolean = routeFor(url.credentialOriginScope) != null

    /**
     * The §1.1 host gate.
     *
     * Returns true when [url] is not an exact MCP route; otherwise the request
     * must carry the current `X-PDSH-MCP-Egress` value. An absent/empty host
     * token denies every exact route.
     */
    fun admitsEgress(url: String, headers: Map<String, String>): Boolean {
        val parsed = GatewayUrls.parse(url) ?: return true
        if (routeFor(parsed.credentialOriginScope) == null) return true
        val expected = egressToken()
        if (expected.isNullOrEmpty()) return false
        return constantTimeEquals(headerValue(headers, EGRESS_HEADER), expected)
    }

    /**
     * The credential for [scope], or null when the scope is not an exact route.
     *
     * The Bot bearer route fails closed when the host has no bearer; a user
     * connector's stored header map is returned as-is (empty means anonymous).
     */
    fun credentialFor(scope: CredentialScope): McpRouteCredential? {
        val route = routeFor(scopeScope(scope)) ?: return null
        // Defence in depth: if the host never installed this start's egress
        // token, the gate already denies the route; a miswired caller must not
        // turn that into a credential injection either.
        if (egressToken().isNullOrEmpty()) return McpRouteCredential.Unavailable
        if (route.botRoute && route.headers.isEmpty()) return McpRouteCredential.Unavailable
        return McpRouteCredential.Headers(route.headers)
    }

    /** True when [scope] is an exact route; exposed for provider tests. */
    fun admitsScope(scope: CredentialScope): Boolean = routeFor(scopeScope(scope)) != null

    private fun routeFor(scope: CredentialOriginScope): Route? = synchronized(lock) {
        routes.values.firstOrNull { it.scope == scope }
    }

    private fun scopeScope(scope: CredentialScope): CredentialOriginScope {
        val scheme = scope.scheme.trim().lowercase()
        val host = bareHost(scope.service)
        val port = scope.port ?: defaultPort(scheme)
        return CredentialOriginScope(
            scheme = scheme,
            host = host,
            effectivePort = port ?: 0,
            normalizedPath = GatewayPaths.normalize(scope.audience),
        )
    }

    private fun urlString(scope: CredentialOriginScope): String {
        val default = defaultPort(scope.scheme)
        val authority = if (default == scope.effectivePort) {
            scope.host
        } else {
            "${scope.host}:${scope.effectivePort}"
        }
        return "${scope.scheme}://$authority${scope.normalizedPath}"
    }

    companion object {
        /** The one hop header of §1.1. */
        const val EGRESS_HEADER: String = "X-PDSH-MCP-Egress"

        /** The frozen §1.1 failure code. */
        const val FORBIDDEN_CODE: String = "mcp_egress_forbidden"

        /** The frozen §1.1 message. */
        const val FORBIDDEN_MESSAGE: String = "the MCP egress credential is missing or invalid"

        /** The exact §1.1 body. */
        val FORBIDDEN_BODY: String =
            """{"error":{"code":"$FORBIDDEN_CODE","message":"$FORBIDDEN_MESSAGE"}}"""

        private fun defaultPort(scheme: String): Int? = when (scheme) {
            "http" -> 80
            "https" -> 443
            else -> null
        }

        private fun bareHost(raw: String): String {
            var value = raw.trim().lowercase()
            val separator = value.indexOf("://")
            if (separator >= 0) value = value.substring(separator + 3)
            val slash = value.indexOf('/')
            if (slash >= 0) value = value.substring(0, slash)
            val colon = value.lastIndexOf(':')
            if (colon >= 0 && value.count { it == ':' } == 1) {
                val port = value.substring(colon + 1)
                if (port.isNotEmpty() && port.all { it in '0'..'9' }) value = value.substring(0, colon)
            }
            return value
        }

        /** Case-insensitive header lookup; the value itself stays byte-exact. */
        internal fun headerValue(headers: Map<String, String>, name: String): String? {
            for ((candidate, value) in headers) {
                if (candidate.equals(name, ignoreCase = true)) return value
            }
            return null
        }

        /**
         * Length-independent UTF-8 comparison. An absent/empty value never
         * matches; a length difference is folded into the result instead of
         * returning before the loop.
         */
        internal fun constantTimeEquals(left: String?, right: String): Boolean {
            if (left.isNullOrEmpty() || right.isEmpty()) return false
            val first = left.toByteArray(Charsets.UTF_8)
            val second = right.toByteArray(Charsets.UTF_8)
            var difference = first.size xor second.size
            val length = maxOf(first.size, second.size)
            for (index in 0 until length) {
                val a = if (index < first.size) first[index].toInt() else 0
                val b = if (index < second.size) second[index].toInt() else 0
                difference = difference or (a xor b)
            }
            return difference == 0
        }
    }
}

/**
 * Layers the exact MCP routes over the host's ordinary egress allow-list.
 *
 * The static list is never widened by this class: a route is an additional
 * exact authorizer, exactly like the Swift `MCPEgressPolicy` `EgressHostAuthorizing`
 * conformance. A request outside every exact route sees the base policy
 * unchanged.
 */
class McpRouteEgressPolicy(
    private val policy: McpEgressPolicy,
    private val base: EgressPolicy,
) : EgressPolicy {
    override fun permits(url: GatewayUrl): Boolean =
        base.permits(url) || policy.allowsEgressHost(url)

    override fun admitsMcpGrant(url: GatewayUrl): Boolean =
        base.admitsMcpGrant(url) || policy.allowsEgressHost(url)
}

/**
 * The `/v1/http` decorator that applies the §1.1 gate before credential
 * resolution.
 *
 * It sits between the loopback route and [GatewayHttpEgress]: a matching route
 * without the current header returns the frozen 403, and the delegate (the
 * gateway, its response log and the upstream transport) is never called.
 */
class McpEgressGate(
    private val policy: McpEgressPolicy,
    private val delegate: LoopbackHttpEgress,
) : LoopbackHttpEgress {
    override fun handle(request: LoopbackHttpRequest): LoopbackHttpResponse {
        if (request.targetUrl.isNotBlank() &&
            !policy.admitsEgress(request.targetUrl, request.headers)
        ) {
            return forbidden()
        }
        return delegate.handle(request)
    }

    private fun forbidden(): LoopbackHttpResponse = LoopbackHttpResponse(
        status = 403,
        headers = linkedMapOf(
            "content-type" to "application/json; charset=utf-8",
            "x-pdsh-proxy-error" to McpEgressPolicy.FORBIDDEN_CODE,
        ),
        body = McpEgressPolicy.FORBIDDEN_BODY.toByteArray(Charsets.UTF_8),
    )
}

/**
 * Injects the exact-route credential and delegates every other scope to [base].
 *
 * A Bot route without a bearer throws [CredentialUnavailableException], which
 * the gateway maps to its pre-flight `credential_unavailable` failure. This is
 * the "no Bot credential" fail-closed arm of §1.1; the request still has to
 * pass [McpEgressGate] first, so a Worker request that never carried the hop
 * header is refused before this provider is consulted.
 */
class McpEgressCredentialProvider(
    private val policy: McpEgressPolicy,
    private val base: GatewayCredentialProvider,
) : GatewayCredentialProvider {
    override fun resolve(scope: CredentialScope): GatewayCredential =
        when (val credential = policy.credentialFor(scope)) {
            null -> base.resolve(scope)
            is McpRouteCredential.Headers ->
                if (credential.headers.isEmpty()) {
                    GatewayCredential.None
                } else {
                    GatewayCredential.Headers(credential.headers)
                }
            McpRouteCredential.Unavailable -> throw CredentialUnavailableException(
                "the Bot MCP bearer is not configured",
            )
        }

    override fun invalidate(credential: GatewayCredential, scope: CredentialScope) {
        // Host-managed route credentials are fixed for the host start; only a
        // non-route scope may refresh the base provider.
        if (policy.admitsScope(scope)) return
        base.invalidate(credential, scope)
    }
}
