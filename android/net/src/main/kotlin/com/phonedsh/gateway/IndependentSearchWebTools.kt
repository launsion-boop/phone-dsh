// SPDX-License-Identifier: MIT
//
// The independent Search/Fetch grant (`spec/v1/gateway-independent-search.md`).
// The person's own Search/Fetch service has its own base URL and its own key; the
// host grants exactly `POST <base>/search` and `POST <base>/fetch`, injects that
// key per request, refuses redirects and never logs the exchange. The shared
// cases (`spec/v1/golden/gateway/independent-search/cases.json`) judge both the
// base normalization and the request scope, here and in the Worker bridge.

package com.phonedsh.gateway

import com.phonedsh.loopback.LoopbackHttpEgress
import com.phonedsh.loopback.LoopbackHttpRequest
import com.phonedsh.loopback.LoopbackHttpResponse

object IndependentSearchWebTools {
    /** The independent mode's non-secret Worker key placeholder (§3). */
    const val PLACEHOLDER: String = "phone-host-injects-search-key"

    private const val SCHEME_PREFIX: String = "https://"
    private const val MAX_HOST_LENGTH: Int = 253
    private const val MAX_BASE_LENGTH: Int = 512
    private val DNS_LABEL = Regex("^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$")
    private val PATH_SEGMENT = Regex("^[A-Za-z0-9._~-]+$")
    private val ASCII_WHITESPACE = charArrayOf(' ', '\t', '\n', '\u000C', '\r')

    /**
     * The canonical base for [raw], or `null` when §1 rejects it.
     *
     * Character-level on purpose: a URL parser would silently accept or rewrite
     * spellings (`:443`, `%xx`, `..`) that the frozen cases refuse.
     */
    fun canonicalBase(raw: String?): String? {
        val text = raw?.trim(*ASCII_WHITESPACE) ?: return null
        if (!text.regionMatches(0, SCHEME_PREFIX, 0, SCHEME_PREFIX.length, ignoreCase = true)) return null
        val rest = text.substring(SCHEME_PREFIX.length)
        if (rest.any { it in "?#%\\@" || it.code !in 0x21..0x7e }) return null
        val slash = rest.indexOf('/')
        val host = (if (slash < 0) rest else rest.substring(0, slash)).lowercase()
        var path = if (slash < 0) "" else rest.substring(slash)
        if (host.isEmpty() || host.length > MAX_HOST_LENGTH || host.any { it == ':' || it == '[' || it == ']' }) {
            return null
        }
        val labels = host.split('.')
        if (labels.size < 2 || !labels.all(DNS_LABEL::matches)) return null
        if (labels.last().none { it in 'a'..'z' }) return null
        if (path.endsWith("/")) path = path.dropLast(1)
        val segments = if (path.isEmpty()) emptyList() else path.substring(1).split('/')
        if (!segments.all { PATH_SEGMENT.matches(it) && it != "." && it != ".." }) return null
        val last = segments.lastOrNull()?.lowercase()
        if (last == "search" || last == "fetch") return null
        val canonical = SCHEME_PREFIX + host + path
        return canonical.takeIf { it.length <= MAX_BASE_LENGTH }
    }

    /** The two operation URLs of a canonical [base]. */
    fun operationUrls(base: String): List<String> = listOf("$base/search", "$base/fetch")

    /** True only for `POST` to one of the two exact operation URLs (§2). */
    fun isOperationRequest(base: String, method: String?, url: String?): Boolean {
        if (method?.trim()?.equals("POST", ignoreCase = true) != true) return false
        return url?.trim().orEmpty() in operationUrls(base)
    }

    /**
     * The four Worker entries for a canonical [base] (§3). The key is never here.
     *
     * @throws IllegalArgumentException when [base] is not already canonical.
     */
    fun workerEnvironment(base: String): Map<String, String> {
        require(canonicalBase(base) == base) { "the independent search base is not canonical" }
        return linkedMapOf(
            OfficialDeepSeekWebTools.SEARCH_PROVIDER_ENV to OfficialDeepSeekWebTools.SEARCH_PROVIDER,
            OfficialDeepSeekWebTools.FETCH_PROVIDER_ENV to OfficialDeepSeekWebTools.FETCH_PROVIDER,
            OfficialDeepSeekWebTools.SEARCH_BASE_URL_ENV to base,
            OfficialDeepSeekWebTools.SEARCH_API_KEY_ENV to PLACEHOLDER,
        )
    }
}

internal class IndependentSearchEgressPolicy(base: String) : EgressPolicy {
    private val operations: Set<String> = IndependentSearchWebTools.operationUrls(base).toSet()

    override fun permits(url: GatewayUrl): Boolean = url.raw in operations

    override fun admitsMcpGrant(url: GatewayUrl): Boolean = false
}

internal class IndependentSearchCredentialProvider(
    base: String,
    private val keys: ModelKeySource,
) : GatewayCredentialProvider {
    private val host: String = base.removePrefix("https://").substringBefore('/')
    private val paths: Set<String> = base.removePrefix("https://").let { rest ->
        val prefix = if (rest.contains('/')) "/" + rest.substringAfter('/') else ""
        setOf("$prefix/search", "$prefix/fetch")
    }

    override fun resolve(scope: CredentialScope): GatewayCredential {
        if (!admits(scope)) throw CredentialUnavailableException(NOT_AN_OPERATION)
        val key = keys.readKey() ?: throw CredentialUnavailableException(NO_KEY)
        if (key.isEmpty()) throw CredentialUnavailableException(NO_KEY)
        return GatewayCredential.Bearer(key)
    }

    override fun invalidate(credential: GatewayCredential, scope: CredentialScope) {
        if (!admits(scope)) return
        val value = (credential as? GatewayCredential.Bearer)?.value ?: return
        if (value.isNotEmpty()) keys.invalidate(value)
    }

    private fun admits(scope: CredentialScope): Boolean =
        scope.scheme == "https" && scope.service == host && scope.port == null && scope.audience in paths

    private companion object {
        const val NO_KEY: String = "no independent web-search API key is configured on this phone"
        const val NOT_AN_OPERATION: String = "scope is not an independent Search/Fetch operation"
    }
}

/**
 * The `/v1/http` policy while the independent Search/Fetch mode is selected.
 *
 * It replaces [OfficialDeepSeekWebToolsEgress]; there is never a fallback to the
 * model key. Requests outside the two operations go to [fallback] (the launch's
 * diagnostic policy) or are refused.
 *
 * @param base the canonical base (`IndependentSearchWebTools.canonicalBase`).
 * @param keys reads the independent key on every request.
 */
class IndependentSearchWebToolsEgress(
    private val base: String,
    keys: ModelKeySource,
    transport: GatewayTransport,
    private val fallback: LoopbackHttpEgress? = null,
) : LoopbackHttpEgress {
    init {
        require(IndependentSearchWebTools.canonicalBase(base) == base) {
            "the independent search base is not canonical"
        }
    }

    internal val session: GatewaySession = GatewaySession(
        transport = transport,
        credentialProvider = IndependentSearchCredentialProvider(base, keys),
        egress = IndependentSearchEgressPolicy(base),
        redirects = NoRedirectAuthorizer,
        sensitiveCalls = object : SensitiveCallClassifier {
            override fun isSensitive(
                workerHeaders: Map<String, String>,
                credential: GatewayCredential,
                mcpAdmitted: Boolean,
            ): Boolean = true
        },
        sensitiveKind = SensitiveResponseKind.WEB_TOOL,
    )

    private val gateway: GatewayHttpEgress = GatewayHttpEgress(session)

    override fun handle(request: LoopbackHttpRequest): LoopbackHttpResponse {
        val target = header(request.headers, GatewayHttpEgress.TARGET_URL)
        val method = (header(request.headers, GatewayHttpEgress.TARGET_METHOD) ?: request.targetMethod)
            .trim()
            .uppercase()
        if (!IndependentSearchWebTools.isOperationRequest(base, method, target)) {
            return fallback?.handle(request) ?: refusal()
        }
        return gateway.handle(request.copy(headers = request.headers.filterKeys {
            it.lowercase() !in ALTERNATE_AUTH_HEADERS
        }))
    }

    private fun refusal(): LoopbackHttpResponse {
        val failure = GatewayFailure.invalidRequest(
            "the independent web route accepts only POST to <base>/search and <base>/fetch",
        )
        return LoopbackHttpResponse(
            status = failure.code.proxyStatus,
            headers = linkedMapOf(
                "content-type" to GatewayHttpEgress.JSON_CONTENT_TYPE,
                GatewayHttpEgress.PROXY_ERROR to failure.code.proxyError,
                GatewayHttpEgress.DENY_REASON to failure.code.wire,
            ),
            body = failure.envelopeJson().toByteArray(Charsets.UTF_8),
        )
    }

    private fun header(headers: Map<String, String>, name: String): String? {
        for ((key, value) in headers) {
            if (key.equals(name, ignoreCase = true)) return value
        }
        return null
    }

    private companion object {
        val ALTERNATE_AUTH_HEADERS = setOf("x-api-key", "api-key", "x-dsh-auth-token")
    }
}
