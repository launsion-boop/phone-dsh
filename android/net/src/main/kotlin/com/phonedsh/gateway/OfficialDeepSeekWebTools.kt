// SPDX-License-Identifier: MIT

package com.phonedsh.gateway

import com.phonedsh.loopback.LoopbackHttpEgress
import com.phonedsh.loopback.LoopbackHttpRequest
import com.phonedsh.loopback.LoopbackHttpResponse
import java.net.URI

object OfficialDeepSeekWebTools {
    const val MODEL_HOST: String = "api.deepseek.com"

    const val SEARCH_API_BASE_URL: String = "https://api.deepseek.com/v1/tools"

    const val SEARCH_URL: String = "$SEARCH_API_BASE_URL/search"
    const val FETCH_URL: String = "$SEARCH_API_BASE_URL/fetch"

    val TOOL_PATHS: List<String> = listOf("/v1/tools/search", "/v1/tools/fetch")

    const val SEARCH_PROVIDER: String = "deepseek-search-api"
    const val FETCH_PROVIDER: String = "deepseek-fetch-api"

    const val SEARCH_PROVIDER_ENV: String = "PDSH_WEB_SEARCH_PROVIDER"
    const val FETCH_PROVIDER_ENV: String = "PDSH_WEB_FETCH_PROVIDER"
    const val SEARCH_BASE_URL_ENV: String = "DEEPSEEK_SEARCH_API_BASE_URL"
    const val SEARCH_API_KEY_ENV: String = "DEEPSEEK_SEARCH_API_KEY"

    const val PLACEHOLDER: String = "phone-host-injects-key"

    private val CANONICAL_URLS: Set<String> = linkedSetOf(SEARCH_URL, FETCH_URL)

    private val SUPPORTED_MODEL_BASE_PATHS: Set<String> = linkedSetOf(
        "/",
        "/v1",
        "/v1/",
        "/anthropic",
        "/anthropic/",
        "/anthropic/v1",
        "/anthropic/v1/",
    )

    fun isOfficialModelBase(baseUrl: String?): Boolean {
        val text = baseUrl?.trim().orEmpty()
        if (text.isEmpty()) return false
        val uri = try {
            URI(text)
        } catch (_: Exception) {
            return false
        }
        if (!uri.scheme.equals("https", ignoreCase = true)) return false
        if (!uri.host.equals(MODEL_HOST, ignoreCase = true)) return false
        if (uri.userInfo != null || uri.rawQuery != null || uri.rawFragment != null) return false
        if (uri.port != -1 && uri.port != 443) return false
        return uri.rawPath.ifEmpty { "/" } in SUPPORTED_MODEL_BASE_PATHS
    }

    fun isCanonicalRequest(method: String?, url: String?): Boolean {
        if (method?.trim()?.equals("POST", ignoreCase = true) != true) return false
        return url?.trim().orEmpty() in CANONICAL_URLS
    }

    fun workerEnvironment(): Map<String, String> = linkedMapOf(
        SEARCH_PROVIDER_ENV to SEARCH_PROVIDER,
        FETCH_PROVIDER_ENV to FETCH_PROVIDER,
        SEARCH_BASE_URL_ENV to SEARCH_API_BASE_URL,
        SEARCH_API_KEY_ENV to PLACEHOLDER,
    )
}

internal object OfficialDeepSeekToolEgressPolicy : EgressPolicy {
    override fun permits(url: GatewayUrl): Boolean = url.raw in CANONICAL_URL_SET

    override fun admitsMcpGrant(url: GatewayUrl): Boolean = false

    private val CANONICAL_URL_SET: Set<String> =
        linkedSetOf(OfficialDeepSeekWebTools.SEARCH_URL, OfficialDeepSeekWebTools.FETCH_URL)
}

internal object NoRedirectAuthorizer : RedirectAuthorizer {
    override fun authorize(
        target: GatewayUrl,
        credentialScope: CredentialOriginScope?,
        egress: EgressPolicy,
    ): RedirectDecision = RedirectDecision.Refuse(RedirectReasons.TARGET_NOT_ALLOWED)
}

internal class OfficialDeepSeekToolCredentialProvider(
    private val keys: ModelKeySource,
) : GatewayCredentialProvider {
    override fun resolve(scope: CredentialScope): GatewayCredential {
        if (!admits(scope)) throw CredentialUnavailableException(NOT_AN_OFFICIAL_SCOPE)
        val key = keys.readKey() ?: throw CredentialUnavailableException(NO_KEY)
        if (key.isEmpty()) throw CredentialUnavailableException(NO_KEY)
        return GatewayCredential.Bearer(key)
    }

    private fun admits(scope: CredentialScope): Boolean {
        if (!scope.scheme.equals("https", ignoreCase = true)) return false
        if (scope.service != OfficialDeepSeekWebTools.MODEL_HOST) return false
        // The canonical spelling has no explicit port; `:443` is an alias and is
        // not the URL the frozen case names.
        if (scope.port != null) return false
        return scope.audience in TOOL_PATH_SET
    }

    private companion object {
        const val NO_KEY: String = "no model API key is configured on this phone"
        const val NOT_AN_OFFICIAL_SCOPE: String = "scope is not an official DeepSeek tool endpoint"
        val TOOL_PATH_SET: Set<String> = OfficialDeepSeekWebTools.TOOL_PATHS.toSet()
    }
}

class OfficialDeepSeekWebToolsEgress(
    keys: ModelKeySource,
    transport: GatewayTransport,
    private val fallback: LoopbackHttpEgress? = null,
) : LoopbackHttpEgress {
    internal val session: GatewaySession = GatewaySession(
        transport = transport,
        credentialProvider = OfficialDeepSeekToolCredentialProvider(keys),
        egress = OfficialDeepSeekToolEgressPolicy,
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
        if (!OfficialDeepSeekWebTools.isCanonicalRequest(method, target)) {
            return fallback?.handle(request) ?: refusal()
        }
        return gateway.handle(request.copy(headers = request.headers.filterKeys {
            it.lowercase() !in alternateAuthHeaders
        }))
    }

    private companion object {
        val alternateAuthHeaders = setOf("x-api-key", "api-key", "x-dsh-auth-token")
    }

    private fun refusal(): LoopbackHttpResponse {
        val failure = GatewayFailure.invalidRequest(
            "the official web route accepts only POST to /v1/tools/search and /v1/tools/fetch",
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
}
