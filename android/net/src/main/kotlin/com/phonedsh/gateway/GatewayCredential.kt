// phone-dsh — :net / com.phonedsh.gateway: host-managed credentials.
// SPDX-License-Identifier: MIT
//
// The Worker never holds an upstream key: the host CredentialProvider resolves
// one credential for the URL scope and the gateway applies it inside request
// construction, after the caller headers were copied and stripped. The exact
// injected values are also the redaction set for the response side, so
// `secretValues` is part of the credential, not of the response code
// (gw-cred-001..003, gw-resp-001..005).

package com.phonedsh.gateway

/** Thrown by a [GatewayCredentialProvider] when no credential can be resolved. */
class CredentialUnavailableException(message: String = "credential provider failed") :
    Exception(message)

/** What the host provider returns for one URL scope. */
sealed interface GatewayCredential {
    /** Anonymous: no header is injected. */
    data object None : GatewayCredential

    /** `Authorization: Bearer <value>`. */
    data class Bearer(val value: String) : GatewayCredential

    /** `<header>: <value>`. */
    data class ApiKey(val header: String, val value: String) : GatewayCredential

    /** A host-managed header map injected whole. */
    data class Headers(val headers: Map<String, String>) : GatewayCredential

    /** True when real header material was applied. */
    val carriesSecret: Boolean
        get() = when (this) {
            None -> false
            is Headers -> headers.isNotEmpty()
            is Bearer -> value.isNotEmpty()
            is ApiKey -> value.isNotEmpty()
        }

    /** Applies this credential last, so it overrides a same-name caller header. */
    fun applyTo(headers: MutableMap<String, String>) {
        when (this) {
            None -> Unit
            is Bearer -> headers[AUTHORIZATION] = "Bearer $value"
            is ApiKey -> headers[header.lowercase()] = value
            is Headers -> for ((name, value) in this.headers.entries.toList()) {
                headers[name.lowercase()] = value
            }
        }
    }

    /**
     * The exact values this credential injected, longest first.
     *
     * A server that echoes only the credential part of a standard
     * `Authorization` value (`mcp-token` from `Bearer mcp-token`) is still
     * echoing an injected secret, so that part is derived from the header the
     * host actually injected rather than guessed from a token shape.
     */
    fun secretValues(): List<String> = when (this) {
        None -> emptyList()
        is Bearer -> if (value.isEmpty()) emptyList() else sortSecrets(listOf(value, "Bearer $value"))
        is ApiKey -> if (value.isEmpty()) emptyList() else listOf(value)
        is Headers -> {
            val values = ArrayList<String>()
            for ((name, value) in headers) {
                if (value.isEmpty()) continue
                values.add(value)
                val lowercased = name.lowercase()
                if (lowercased != AUTHORIZATION && lowercased != PROXY_AUTHORIZATION) continue
                val separator = value.indexOfFirst { it == ' ' || it == '\t' }
                if (separator < 0) continue
                val scheme = value.substring(0, separator).lowercase()
                if (scheme !in AUTH_SCHEMES) continue
                val remainder = value.substring(separator + 1).trim()
                if (remainder.isNotEmpty()) values.add(remainder)
            }
            sortSecrets(values)
        }
    }

    companion object {
        const val AUTHORIZATION = "authorization"
        const val PROXY_AUTHORIZATION = "proxy-authorization"

        /** Standard schemes whose value is followed by the credential part. */
        val AUTH_SCHEMES: Set<String> = setOf("bearer", "basic", "token")

        /** De-duplicates and orders longest first, then lexicographically. */
        fun sortSecrets(values: Iterable<String>): List<String> =
            values.filter { it.isNotEmpty() }
                .distinct()
                .sortedWith { left, right ->
                    if (left.length != right.length) right.length - left.length
                    else compareValues(left, right)
                }
    }
}

/** Resolves the credential for one URL scope; throwing means "unavailable". */
fun interface GatewayCredentialProvider {
    @Throws(CredentialUnavailableException::class)
    fun resolve(scope: CredentialScope): GatewayCredential

    /**
     * The upstream rejected [credential] as expired (spec/v1/tono-account.md §5);
     * the next [resolve] must refresh or return the same value. The default keeps
     * every existing provider unchanged: a fixed key is never re-sent.
     */
    fun invalidate(credential: GatewayCredential, scope: CredentialScope) {}
}
