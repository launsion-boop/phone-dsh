// phone-dsh — :net / com.phonedsh.gateway: the model-key CredentialProvider.
// SPDX-License-Identifier: MIT
//
// The Android counterpart of `Sources/PhoneDSH/PhoneModelProviderSettings.swift`
// (`ModelProviderCredentialProvider`, `ModelProviderEndpointOrigin` and
// `ModelProviderEndpointPaths`): the host keeps exactly one model key in the
// device key store, and this class is the only production code that turns that
// key into an outbound header.
//
// Rules it ports from the Swift baseline, and why each one exists:
//   * the key is released only for the **configured** model origin — lowercased
//     host, scheme and effective port all have to agree, so a same-host request
//     on another port or scheme never sees it;
//   * the key is released only for the **model protocol paths** derived from the
//     configured base URL, so a same-host MCP, Search or Fetch route is answered
//     `Credential.none` instead of being turned into a model-key request;
//   * a host that is neither the model origin nor an explicitly anonymous egress
//     host is refused, never silently sent anonymously;
//   * an absent key fails closed (`credential_unavailable`), it is not turned
//     into an anonymous request that the upstream would answer with 401. This is
//     the baseline's `ProviderError.unauthorized`;
//   * no message, no `toString()` and no exception carries the key or the store
//     path, because the failure surface (§7) never forwards provider text.
//
// The key itself never lives here: [ModelKeySource] is the host's secret store
// adapter, and this class holds it only for the duration of one [resolve].

package com.phonedsh.gateway

/**
 * The host's stored model key, as the credential provider sees it.
 *
 * The three answers are deliberately distinct:
 *   * [readKey] returns the key — a non-empty value that may be injected;
 *   * [readKey] returns `null` — the host read its secret store and there is no
 *     key for a model service (未配置);
 *   * [readKey] throws [CredentialUnavailableException] — a key exists but cannot
 *     be read (Keystore entry gone, GCM tag failed), or the store itself failed.
 *     This is *not* "no key": the caller must fail closed rather than pretend the
 *     host is anonymous.
 *
 * Implementations must not log, cache, or put the value into a `toString()`.
 */
fun interface ModelKeySource {
    /**
     * The stored key, or `null` when none is configured.
     *
     * @throws CredentialUnavailableException when a key exists but cannot be read.
     *   The message is a constant diagnostic and must never contain key material.
     */
    @Throws(CredentialUnavailableException::class)
    fun readKey(): String?
}

/**
 * One configured model base URL: its exact origin and its protocol paths.
 *
 * Built from the value the host puts into `DEEPSEEK_BASE_URL`, so the credential
 * scope and the Worker's model client cannot drift apart: both are derived from
 * the same string.
 */
class ModelEndpoint private constructor(
    val scheme: String,
    val host: String,
    val effectivePort: Int,
    private val basePath: String,
) {
    private val paths: ModelProtocolPaths = ModelProtocolPaths(basePath)

    /** `https://host:port` — no path, no credential, safe to show in a log. */
    val origin: String
        get() = "$scheme://$host:$effectivePort"

    /** The base path this endpoint was parsed from, normalized. */
    val normalizedBasePath: String
        get() = GatewayPaths.normalize(basePath)

    /**
     * The model-protocol routes a host-edge proxy mounts on the loopback origin.
     *
     * The loopback side is the canonical `/v1` spelling; each [ModelProtocolRoute]
     * also carries the path this configured origin sees. Exposed for
     * `com.phonedsh.loopback.LoopbackModelProxy`, which must not invent a second
     * route table: a mounted route the credential provider does not admit would
     * be forwarded without the key.
     */
    internal fun protocolRoutes(): List<ModelProtocolRoute> = paths.routes()

    /**
     * True when [scope] is a model-protocol request for this exact origin.
     *
     * A scope whose path is outside the protocol paths is `false`, even when the
     * host matches: the gateway admitted the origin, not the key.
     */
    fun admits(scope: CredentialScope): Boolean {
        if (bareHost(scope.service) != host) return false
        val requestedScheme = scope.scheme.trim().lowercase()
        if (requestedScheme != scheme) return false
        val requestedPort = scope.port ?: defaultPort(requestedScheme)
        if (requestedPort != effectivePort) return false
        return paths.admits(scope.audience)
    }

    override fun toString(): String = "ModelEndpoint($origin, base=$normalizedBasePath)"

    companion object {
        /**
         * Parses an absolute http(s) base URL, or returns `null`.
         *
         * A base URL with userinfo, a query or a fragment is refused rather than
         * silently normalized: none of those can participate in a credential
         * scope, so accepting one would mean guessing which part was meant.
         */
        fun parse(rawBaseUrl: String): ModelEndpoint? {
            val text = rawBaseUrl.trim()
            if (text.isEmpty()) return null
            val uri = try {
                java.net.URI(text)
            } catch (failure: Exception) {
                return null
            }
            val scheme = uri.scheme?.lowercase() ?: return null
            if (scheme != "http" && scheme != "https") return null
            val host = uri.host?.lowercase()?.takeIf { it.isNotEmpty() } ?: return null
            if (uri.userInfo != null || uri.rawQuery != null || uri.rawFragment != null) return null
            val port = if (uri.port < 0) defaultPort(scheme) else uri.port
            if (port == null || port <= 0) return null
            return ModelEndpoint(scheme, host, port, uri.rawPath ?: "/")
        }

        /** The scheme default port, or `null` for a non-HTTP scheme. */
        fun defaultPort(scheme: String): Int? = when (scheme.trim().lowercase()) {
            "http" -> 80
            "https" -> 443
            else -> null
        }

        /**
         * The bare lowercased host of a `service` scope value.
         *
         * The gateway already supplies a bare host; this only makes a hand-written
         * scope (`https://host:8443`) safe instead of matching nothing.
         */
        fun bareHost(raw: String): String {
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
    }
}

/**
 * One model-protocol route as a host-edge proxy mounts it.
 *
 * The loopback side always uses the canonical `/v1` spelling a Worker appends to
 * `DEEPSEEK_BASE_URL`, while [upstreamPath] is where the same operation lives on
 * the configured origin: a base with a prefix (`/anthropic`) becomes
 * `/anthropic/v1/messages` upstream. Both sides come from the same
 * [ModelProtocolPaths] instance, so the proxy cannot mount a route the
 * credential provider would not admit.
 */
internal data class ModelProtocolRoute(
    /** Exact path on the loopback origin, e.g. `/v1/messages`. */
    val loopbackPath: String,
    /** Exact path on the configured upstream origin, e.g. `/anthropic/v1/messages`. */
    val upstreamPath: String,
    /** True when descendants (`/v1/models/<id>`) are protocol operations too. */
    val includesDescendants: Boolean,
)

/**
 * The operation paths a configured model base can produce for the protocols DSH
 * ships (ported from `ModelProviderEndpointPaths`).
 *
 * The base is a prefix, not a whole host: Messages lives below `base[/v1]`, the
 * OpenAI-compatible chat/completions/responses routes below the base, and the
 * account/model listing at `/models` on the origin. Search/Fetch has its own
 * router and is deliberately absent here.
 */
internal class ModelProtocolPaths(basePath: String) {
    private val exact: Set<String>
    private val prefixes: List<String>
    private val routes: List<ModelProtocolRoute>

    init {
        val base = GatewayPaths.normalize(basePath)
        val root = when {
            base == "/" -> "/v1"
            base.endsWith("/v1") -> base
            else -> base + "/v1"
        }
        // The loopback origin has no base prefix: a Worker points its base URL at
        // the origin and appends `/v1/...`. The upstream side keeps the configured
        // prefix, except that Messages sits below `root` (base + `/v1` when the
        // base is not already `/v1`), matching ModelProviderEndpointPaths.
        routes = listOf(
            ModelProtocolRoute("/v1/messages", GatewayPaths.normalize("$root/messages"), false),
            ModelProtocolRoute(
                "/v1/messages/count_tokens",
                GatewayPaths.normalize("$root/messages/count_tokens"),
                false,
            ),
            ModelProtocolRoute("/v1/models", GatewayPaths.normalize("$root/models"), true),
            ModelProtocolRoute("/v1/files", GatewayPaths.normalize("$root/files"), true),
            ModelProtocolRoute(
                "/v1/chat/completions",
                GatewayPaths.normalize("$base/chat/completions"),
                false,
            ),
            ModelProtocolRoute("/v1/completions", GatewayPaths.normalize("$base/completions"), false),
            ModelProtocolRoute("/v1/responses", GatewayPaths.normalize("$base/responses"), true),
            ModelProtocolRoute("/models", "/models", true),
        )
        exact = LinkedHashSet<String>().apply {
            routes.mapTo(this) { it.upstreamPath }
            // A configured prefix exposes its own account listing too; it is not
            // a route the loopback proxy mounts but the credential scope admits it.
            add(GatewayPaths.normalize("$base/models"))
        }

        // A prefix only admits its own descendants, never a sibling whose name
        // merely starts with it (`/v1/models/deepseek` yes, `/v1/models-mcp` no).
        prefixes = (
            routes.filter { it.includesDescendants }.map { it.upstreamPath } + listOf(
                GatewayPaths.normalize("$base/files"),
                GatewayPaths.normalize("$base/models"),
            )
            ).distinct().sorted()
    }

    fun admits(rawPath: String): Boolean {
        val path = GatewayPaths.normalize(rawPath)
        if (path in exact) return true
        return prefixes.any { path.startsWith("$it/") }
    }

    /** The loopback route set of this base, in a stable order. */
    fun routes(): List<ModelProtocolRoute> = routes
}

/**
 * Resolves the host's model key for the model origin only.
 *
 * @param endpoint the configured model base URL.
 * @param keys the host's secret store; read once per credential resolution.
 * @param anonymousHosts egress hosts that are deliberately credential-free (the
 *   launch's extra `network.allow` entries). Entries use the gateway grammar
 *   (`host`, `*.suffix`, `*`); anything outside this set that is not the model
 *   origin is refused instead of being sent anonymously by accident.
 */
class ModelGatewayCredentialProvider(
    private val endpoint: ModelEndpoint,
    private val keys: ModelKeySource,
    anonymousHosts: Set<String> = emptySet(),
) : GatewayCredentialProvider {

    /** Convenience form for a host that only has the launch's base URL string. */
    constructor(
        baseUrl: String,
        keys: ModelKeySource,
        anonymousHosts: Set<String> = emptySet(),
    ) : this(
        endpoint = ModelEndpoint.parse(baseUrl)
            ?: throw IllegalArgumentException("model base URL must be an absolute http(s) URL with a host"),
        keys = keys,
        anonymousHosts = anonymousHosts,
    )

    private val anonymousPatterns: List<String> =
        anonymousHosts.map { ModelEndpoint.bareHost(it) }.filter { it.isNotEmpty() }.distinct()

    override fun resolve(scope: CredentialScope): GatewayCredential {
        val host = ModelEndpoint.bareHost(scope.service)
        if (host == endpoint.host) {
            // The gateway admitted this origin; only a model-protocol path may
            // turn that admission into a model-key request.
            if (!endpoint.admits(scope)) return GatewayCredential.None
            val key = keys.readKey() ?: throw CredentialUnavailableException(NO_KEY)
            if (key.isEmpty()) throw CredentialUnavailableException(NO_KEY)
            return GatewayCredential.Bearer(key)
        }
        if (anonymousPatterns.any { GatewayHostRule.hostMatches(host, it) }) {
            return GatewayCredential.None
        }
        throw CredentialUnavailableException(HOST_NOT_ON_LIST)
    }

    /** Never prints the key, the store or the full base URL. */
    override fun toString(): String =
        "ModelGatewayCredentialProvider(${endpoint.origin}, anonymous=$anonymousPatterns)"

    private companion object {
        /** Baseline wording: a missing key is a refusal, not an anonymous call. */
        const val NO_KEY: String = "no model API key is configured on this phone"

        /** Never carries the host: the failure surface has its own reason. */
        const val HOST_NOT_ON_LIST: String = "host is not on the configured allow-list"
    }
}
