// phone-dsh — :net / com.phonedsh.gateway: URL parsing, paths, credential scopes.
// SPDX-License-Identifier: MIT
//
// Two scopes exist and must not be confused:
//  - CredentialScope is what the host CredentialProvider is asked about: the
//    lowercased host, the normalized path, the scheme and the explicit port.
//    Query and fragment never take part (ModelGatewayCredentialRouting.swift).
//  - CredentialOriginScope is the redirect pin: scheme, lowercased host,
//    effective port and normalized path. A credentialed request may only
//    follow a hop inside that scope (GatewaySession.swift:185, :373).
// Normalization collapses repeated separators, resolves `.`/`..`, keeps a
// leading `/` and drops one trailing separator (except for the root path).

package com.phonedsh.gateway

import java.net.URI
import java.net.URISyntaxException

/** An absolute http(s) URL as the gateway sees it. */
data class GatewayUrl internal constructor(
    /** The URL exactly as it was handed to the transport. */
    val raw: String,
    val scheme: String,
    val host: String,
    val explicitPort: Int?,
    val path: String,
) {
    val effectivePort: Int
        get() = explicitPort ?: if (scheme == "https") 443 else 80

    val isHttp: Boolean
        get() = scheme == "http" || scheme == "https"

    val normalizedPath: String
        get() = GatewayPaths.normalize(path)

    val credentialOriginScope: CredentialOriginScope
        get() = CredentialOriginScope(scheme, host, effectivePort, normalizedPath)
}

/** The host/URL scope one credential was resolved for. */
data class CredentialScope(
    val service: String,
    val audience: String,
    val scheme: String,
    val port: Int?,
) {
    companion object {
        fun of(url: GatewayUrl): CredentialScope =
            CredentialScope(url.host, url.normalizedPath, url.scheme, url.explicitPort)
    }
}

/** The exact origin a host credential is pinned to across redirects. */
data class CredentialOriginScope(
    val scheme: String,
    val host: String,
    val effectivePort: Int,
    val normalizedPath: String,
) {
    fun matches(url: GatewayUrl): Boolean =
        url.isHttp &&
            scheme == url.scheme &&
            host == url.host &&
            effectivePort == url.effectivePort &&
            normalizedPath == url.normalizedPath

    companion object {
        fun of(url: GatewayUrl): CredentialOriginScope =
            CredentialOriginScope(url.scheme, url.host, url.effectivePort, url.normalizedPath)
    }
}

object GatewayPaths {
    /** Normalizes a request path for credential routing. */
    fun normalize(rawPath: String): String {
        if (rawPath.isEmpty()) return "/"
        var path = if (rawPath.startsWith("/")) rawPath else "/$rawPath"
        while (path.contains("//")) {
            path = path.replace("//", "/")
        }
        val segments = ArrayDeque<String>()
        for (segment in path.split('/')) {
            when (segment) {
                "", "." -> Unit
                ".." -> if (segments.isNotEmpty()) segments.removeLast()
                else -> segments.addLast(segment)
            }
        }
        if (segments.isEmpty()) return "/"
        return "/" + segments.joinToString("/")
    }
}

object GatewayUrls {
    /**
     * Parses an absolute URL. Returns null when the text is not an absolute
     * URL with a host; the caller maps null to `invalid_request`.
     */
    fun parse(raw: String): GatewayUrl? {
        val text = raw.trim()
        if (text.isEmpty()) return null
        val uri = try {
            URI(text)
        } catch (exception: URISyntaxException) {
            return null
        }
        val scheme = uri.scheme?.lowercase() ?: return null
        val host = uri.host?.lowercase()
        if (host.isNullOrEmpty()) return null
        val port = if (uri.port < 0) null else uri.port
        return GatewayUrl(
            raw = text,
            scheme = scheme,
            host = host,
            explicitPort = port,
            path = uri.rawPath ?: "",
        )
    }

    /**
     * Resolves a `Location` header against the URL that produced it. The
     * vectors always carry an absolute location; relative locations are still
     * resolved so a real origin cannot smuggle one past the scope check.
     */
    fun resolveLocation(base: GatewayUrl, location: String): String {
        val text = location.trim()
        if (text.isEmpty()) return base.raw
        return try {
            val target = URI(text)
            if (target.isAbsolute) text else URI(base.raw).resolve(target).toString()
        } catch (exception: URISyntaxException) {
            text
        }
    }
}
