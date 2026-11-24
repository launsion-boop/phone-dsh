// SPDX-License-Identifier: MIT
// Kotlin end of `Sources/PhoneDSH/PhoneMCPOAuth.swift`: host-owned OAuth for
// hosted MCP connectors (docs/design-connectors-2026-11-24.md §5). Discovery
// (RFC 9728 via the 401 header, RFC 8414), dynamic client registration
// (RFC 7591), PKCE S256, code exchange and refresh all run in the app process;
// tokens live only in the app's Keystore-backed store.
package com.phonedsh.connectors.mcpoauth

import com.phonedsh.agentcore.JsonArray
import com.phonedsh.agentcore.JsonNumber
import com.phonedsh.agentcore.JsonObject
import com.phonedsh.agentcore.JsonString
import com.phonedsh.agentcore.JsonValue
import com.phonedsh.agentcore.toJsonString
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import java.io.IOException
import java.net.HttpURLConnection
import java.net.URI
import java.net.URL
import java.net.URLDecoder
import java.net.URLEncoder
import java.security.MessageDigest
import java.security.SecureRandom
import java.util.Base64

/** One hosted MCP connector the app ships; the Worker can never add or redirect one. */
public data class McpConnector(
    val id: String,
    val serverName: String,
    val url: String,
    val scope: String?,
    /** Native tool-name prefix on `/mcp/native`. */
    val toolPrefix: String,
    val displayName: String,
)

public object McpConnectorCatalog {
    public val TENCENT_DOCS: McpConnector = McpConnector(
        id = "tencent-docs",
        serverName = "tencent-docs",
        url = "https://docs.qq.com/openapi/mcp",
        scope = "docs:read docs:write",
        toolPrefix = "tencent_docs__",
        displayName = "腾讯文档",
    )
    public val ALL: List<McpConnector> = listOf(TENCENT_DOCS)

    /** Custom scheme the callback activity receives. */
    public const val CALLBACK_SCHEME: String = "phonedsh-oauth"
    public fun redirectUri(connector: McpConnector): String = "$CALLBACK_SCHEME://callback/${connector.id}"
}

public class McpOAuthException(public val code: String, message: String) : IOException(message) {
    public companion object {
        public fun discovery(detail: String): McpOAuthException = McpOAuthException("discovery_failed", "无法读取授权服务器信息：$detail")
        public fun registration(detail: String): McpOAuthException = McpOAuthException("registration_failed", "无法向授权服务器注册本应用：$detail")
        public fun unsupported(detail: String): McpOAuthException = McpOAuthException("unsupported_server", "授权服务器不支持所需的授权方式：$detail")
        public fun token(detail: String): McpOAuthException = McpOAuthException("token_failed", "无法取得访问令牌：$detail")
        public val insecure: McpOAuthException get() = McpOAuthException("insecure_endpoint", "授权服务器必须使用 HTTPS。")
        public val callbackInvalid: McpOAuthException get() = McpOAuthException("callback_invalid", "授权回调无效。")
        public val stateMismatch: McpOAuthException get() = McpOAuthException("state_mismatch", "授权回调与本次请求不匹配，已拒绝。")
        public fun denied(detail: String): McpOAuthException = McpOAuthException("denied", "授权未完成：$detail")
        public val reauthorizationRequired: McpOAuthException get() = McpOAuthException("reauthorization_required", "授权已失效，请重新连接。")
    }
}

public data class McpOAuthRegistration(
    val issuer: String,
    val authorizationEndpoint: String,
    val tokenEndpoint: String,
    val clientId: String,
    val redirectUri: String,
    val resource: String,
)

public data class McpOAuthTokens(val accessToken: String, val refreshToken: String?, val expiresAtMillis: Long?, val scope: String?)

public data class McpOAuthRecord(val registration: McpOAuthRegistration, val tokens: McpOAuthTokens) {
    public fun encode(): String = JsonObject(linkedMapOf(
        "version" to JsonNumber("1"),
        "issuer" to JsonString(registration.issuer),
        "authorization_endpoint" to JsonString(registration.authorizationEndpoint),
        "token_endpoint" to JsonString(registration.tokenEndpoint),
        "client_id" to JsonString(registration.clientId),
        "redirect_uri" to JsonString(registration.redirectUri),
        "resource" to JsonString(registration.resource),
        "access_token" to JsonString(tokens.accessToken),
        "refresh_token" to (tokens.refreshToken?.let(::JsonString) ?: com.phonedsh.agentcore.JsonNull),
        "expires_at" to (tokens.expiresAtMillis?.let { JsonNumber(it.toString()) } ?: com.phonedsh.agentcore.JsonNull),
        "scope" to (tokens.scope?.let(::JsonString) ?: com.phonedsh.agentcore.JsonNull),
    )).toJsonString()

    public companion object {
        public fun decode(text: String): McpOAuthRecord? {
            val o = try { JsonValue.parse(text) as? JsonObject } catch (_: Exception) { null } ?: return null
            fun s(key: String) = (o[key] as? JsonString)?.value
            return McpOAuthRecord(
                McpOAuthRegistration(
                    s("issuer") ?: return null, s("authorization_endpoint") ?: return null, s("token_endpoint") ?: return null,
                    s("client_id") ?: return null, s("redirect_uri") ?: return null, s("resource") ?: return null,
                ),
                McpOAuthTokens(s("access_token") ?: return null, s("refresh_token"),
                    (o["expires_at"] as? JsonNumber)?.asLongOrNull(), s("scope")),
            )
        }
    }
}

/** Keystore-backed record store, one entry per connector id (app-provided). */
public interface McpOAuthStore {
    public fun read(connectorId: String): McpOAuthRecord?
    public fun write(connectorId: String, record: McpOAuthRecord)
    public fun delete(connectorId: String)
}

// MARK: HTTP seam

public class HttpReply(public val status: Int, public val headers: Map<String, String>, public val body: ByteArray) {
    public fun header(name: String): String? = headers.entries.firstOrNull { it.key.equals(name, true) }?.value
    public fun text(): String = String(body, Charsets.UTF_8)
}

public fun interface HttpExchange {
    public fun send(method: String, url: String, headers: Map<String, String>, body: ByteArray?): HttpReply
}

/** `HttpURLConnection`, no redirects, no cookies; callers run it on [Dispatchers.IO]. */
public object UrlConnectionExchange : HttpExchange {
    override fun send(method: String, url: String, headers: Map<String, String>, body: ByteArray?): HttpReply {
        val connection = URL(url).openConnection() as HttpURLConnection
        try {
            connection.instanceFollowRedirects = false
            connection.connectTimeout = 15_000
            connection.readTimeout = 60_000
            connection.requestMethod = method
            connection.useCaches = false
            for ((k, v) in headers) connection.setRequestProperty(k, v)
            if (body != null) {
                connection.doOutput = true
                connection.outputStream.use { it.write(body) }
            }
            val status = connection.responseCode
            val stream = if (status >= 400) connection.errorStream else connection.inputStream
            val bytes = stream?.use { it.readBytes() } ?: ByteArray(0)
            val replyHeaders = connection.headerFields.filterKeys { it != null }.mapValues { it.value.joinToString(", ") }
            return HttpReply(status, replyHeaders, bytes)
        } finally {
            connection.disconnect()
        }
    }
}

// MARK: client

public data class McpOAuthServerMetadata(
    val issuer: String,
    val authorizationEndpoint: String,
    val tokenEndpoint: String,
    val registrationEndpoint: String?,
    val resource: String,
)

public class McpOAuthAttempt(
    public val url: String,
    public val state: String,
    internal val verifier: String,
    public val registration: McpOAuthRegistration,
)

public class McpOAuthClient(
    private val http: HttpExchange = UrlConnectionExchange,
    private val clientName: String = "Phone DSH",
    private val now: () -> Long = System::currentTimeMillis,
) {
    public suspend fun discover(resource: String): McpOAuthServerMetadata = io {
        requireHttps(resource)
        val resourceDocument = getJson(resourceMetadataLocation(resource), "protected resource")
        val issuer = ((resourceDocument["authorization_servers"] as? JsonArray)?.values?.firstOrNull() as? JsonString)?.value
            ?: throw McpOAuthException.discovery("protected resource lists no authorization server")
        requireHttps(issuer)
        val resourceId = (resourceDocument["resource"] as? JsonString)?.value ?: resource
        val server = authorizationServerMetadataUrls(issuer).firstNotNullOfOrNull { runCatching { getJson(it, "authorization server") }.getOrNull() }
            ?: throw McpOAuthException.discovery("authorization server metadata unavailable")
        fun s(key: String) = (server[key] as? JsonString)?.value
        val authorization = s("authorization_endpoint") ?: throw McpOAuthException.discovery("no authorization_endpoint")
        val token = s("token_endpoint") ?: throw McpOAuthException.discovery("no token_endpoint")
        requireHttps(authorization); requireHttps(token)
        val methods = (server["code_challenge_methods_supported"] as? JsonArray)?.values?.mapNotNull { (it as? JsonString)?.value }.orEmpty()
        if ("S256" !in methods) throw McpOAuthException.unsupported("PKCE S256")
        val registration = s("registration_endpoint")?.also(::requireHttps)
        McpOAuthServerMetadata(s("issuer") ?: issuer, authorization, token, registration, resourceId)
    }

    public suspend fun register(metadata: McpOAuthServerMetadata, redirectUri: String, scope: String?): McpOAuthRegistration = io {
        val endpoint = metadata.registrationEndpoint ?: throw McpOAuthException.unsupported("dynamic client registration")
        val members = linkedMapOf<String, JsonValue>(
            "client_name" to JsonString(clientName),
            "redirect_uris" to JsonArray(listOf(JsonString(redirectUri))),
            "grant_types" to JsonArray(listOf(JsonString("authorization_code"), JsonString("refresh_token"))),
            "response_types" to JsonArray(listOf(JsonString("code"))),
            "token_endpoint_auth_method" to JsonString("none"),
        )
        if (scope != null) members["scope"] = JsonString(scope)
        val reply = http.send("POST", endpoint, mapOf("Content-Type" to "application/json", "Accept" to "application/json"),
            JsonObject(members).toJsonString().toByteArray())
        val clientId = ((parse(reply.body) as? JsonObject)?.get("client_id") as? JsonString)?.value
        if (reply.status !in 200..299 || clientId.isNullOrEmpty()) throw McpOAuthException.registration(errorSummary(reply))
        McpOAuthRegistration(metadata.issuer, metadata.authorizationEndpoint, metadata.tokenEndpoint, clientId, redirectUri, metadata.resource)
    }

    /** Browser URL with PKCE S256, state and the RFC 8707 resource; existing query items are kept. */
    public fun begin(registration: McpOAuthRegistration, scope: String?): McpOAuthAttempt {
        val verifier = randomUrlSafe(32)
        val state = randomUrlSafe(32)
        val params = linkedMapOf(
            "response_type" to "code", "client_id" to registration.clientId, "redirect_uri" to registration.redirectUri,
            "code_challenge" to challenge(verifier), "code_challenge_method" to "S256", "state" to state,
            "resource" to registration.resource,
        )
        if (scope != null) params["scope"] = scope
        val separator = if (registration.authorizationEndpoint.contains('?')) "&" else "?"
        return McpOAuthAttempt(registration.authorizationEndpoint + separator + form(params), state, verifier, registration)
    }

    public suspend fun finish(attempt: McpOAuthAttempt, callback: String): McpOAuthRecord = io {
        val received = URI(callback)
        val expected = URI(attempt.registration.redirectUri)
        if (received.scheme != expected.scheme || received.host != expected.host || received.path != expected.path) {
            throw McpOAuthException.callbackInvalid
        }
        val query = parseQuery(received.rawQuery.orEmpty())
        val state = query["state"]
        if (state == null || !MessageDigest.isEqual(state.toByteArray(), attempt.state.toByteArray())) throw McpOAuthException.stateMismatch
        query["error"]?.let { throw McpOAuthException.denied(query["error_description"] ?: it) }
        query["iss"]?.let { if (it != attempt.registration.issuer) throw McpOAuthException.callbackInvalid }
        val code = query["code"]?.takeIf { it.isNotEmpty() } ?: throw McpOAuthException.callbackInvalid
        val tokens = tokenRequest(attempt.registration, linkedMapOf(
            "grant_type" to "authorization_code", "code" to code, "redirect_uri" to attempt.registration.redirectUri,
            "code_verifier" to attempt.verifier, "client_id" to attempt.registration.clientId,
            "resource" to attempt.registration.resource,
        ), null)
        McpOAuthRecord(attempt.registration, tokens)
    }

    public suspend fun refresh(record: McpOAuthRecord): McpOAuthRecord = io {
        val refreshToken = record.tokens.refreshToken?.takeIf { it.isNotEmpty() } ?: throw McpOAuthException.reauthorizationRequired
        val tokens = tokenRequest(record.registration, linkedMapOf(
            "grant_type" to "refresh_token", "refresh_token" to refreshToken,
            "client_id" to record.registration.clientId, "resource" to record.registration.resource,
        ), refreshToken)
        record.copy(tokens = tokens)
    }

    private fun tokenRequest(registration: McpOAuthRegistration, params: Map<String, String>, previousRefresh: String?): McpOAuthTokens {
        val reply = http.send("POST", registration.tokenEndpoint,
            mapOf("Content-Type" to "application/x-www-form-urlencoded", "Accept" to "application/json"),
            form(params.toSortedMap()).toByteArray())
        val document = parse(reply.body) as? JsonObject
        if (reply.status !in 200..299) {
            if ((document?.get("error") as? JsonString)?.value == "invalid_grant" && params["grant_type"] == "refresh_token") {
                throw McpOAuthException.reauthorizationRequired
            }
            throw McpOAuthException.token(errorSummary(reply))
        }
        val access = (document?.get("access_token") as? JsonString)?.value?.takeIf { it.isNotEmpty() }
            ?: throw McpOAuthException.token("response has no access_token")
        (document["token_type"] as? JsonString)?.value?.let {
            if (!it.equals("bearer", true)) throw McpOAuthException.unsupported("token_type $it")
        }
        val expiresIn = when (val raw = document["expires_in"]) {
            is JsonNumber -> raw.raw.toDoubleOrNull()
            is JsonString -> raw.value.toDoubleOrNull()
            else -> null
        }
        return McpOAuthTokens(
            accessToken = access,
            // RFC 6749 §6: a refresh response may omit the refresh token; the previous one stays valid.
            refreshToken = (document["refresh_token"] as? JsonString)?.value ?: previousRefresh,
            expiresAtMillis = expiresIn?.let { now() + (it * 1000).toLong() },
            scope = (document["scope"] as? JsonString)?.value,
        )
    }

    private fun resourceMetadataLocation(resource: String): String {
        val probe = runCatching {
            http.send("POST", resource, mapOf("Content-Type" to "application/json", "Accept" to "application/json, text/event-stream"),
                """{"jsonrpc":"2.0","id":0,"method":"ping"}""".toByteArray())
        }.getOrNull()
        val location = probe?.takeIf { it.status == 401 }?.header("WWW-Authenticate")?.let { parameter("resource_metadata", it) }
        if (location != null) { requireHttps(location); return location }
        // RFC 9728 §3.1: the well-known segment goes before the path.
        val uri = URI(resource)
        val path = if (uri.path.isNullOrEmpty() || uri.path == "/") "" else uri.path
        return "${uri.scheme}://${uri.authority}/.well-known/oauth-protected-resource$path"
    }

    private fun getJson(url: String, stage: String): JsonObject {
        val reply = http.send("GET", url, mapOf("Accept" to "application/json"), null)
        return (parse(reply.body) as? JsonObject)?.takeIf { reply.status in 200..299 }
            ?: throw McpOAuthException.discovery("$stage metadata HTTP ${reply.status}")
    }

    private suspend fun <T> io(block: () -> T): T = withContext(Dispatchers.IO) { block() }

    public companion object {
        internal fun authorizationServerMetadataUrls(issuer: String): List<String> {
            val uri = URI(issuer)
            val path = if (uri.path.isNullOrEmpty() || uri.path == "/") "" else uri.path
            return listOf("/.well-known/oauth-authorization-server", "/.well-known/openid-configuration")
                .map { "${uri.scheme}://${uri.authority}$it$path" }
        }

        internal fun parameter(name: String, header: String): String? =
            Regex(Regex.escape(name) + "=\"([^\"]*)\"", RegexOption.IGNORE_CASE).find(header)?.groupValues?.get(1)

        internal fun requireHttps(url: String) {
            val uri = try { URI(url) } catch (_: Exception) { throw McpOAuthException.insecure }
            if (!uri.scheme.equals("https", true) || uri.host.isNullOrEmpty()) throw McpOAuthException.insecure
        }

        public fun challenge(verifier: String): String =
            Base64.getUrlEncoder().withoutPadding().encodeToString(MessageDigest.getInstance("SHA-256").digest(verifier.toByteArray()))

        private val random = SecureRandom()
        internal fun randomUrlSafe(bytes: Int): String =
            Base64.getUrlEncoder().withoutPadding().encodeToString(ByteArray(bytes).also(random::nextBytes))

        internal fun form(params: Map<String, String>): String =
            params.entries.joinToString("&") { "${enc(it.key)}=${enc(it.value)}" }

        private fun enc(value: String) = URLEncoder.encode(value, "UTF-8").replace("+", "%20")

        internal fun parseQuery(raw: String): Map<String, String> = raw.split('&').filter { it.isNotEmpty() }.associate {
            val key = it.substringBefore('=')
            val value = it.substringAfter('=', "")
            URLDecoder.decode(key, "UTF-8") to URLDecoder.decode(value, "UTF-8")
        }

        internal fun parse(body: ByteArray): JsonValue? = try { JsonValue.parse(String(body, Charsets.UTF_8)) } catch (_: Exception) { null }

        internal fun errorSummary(reply: HttpReply): String {
            val o = parse(reply.body) as? JsonObject
            val error = (o?.get("error") as? JsonString)?.value ?: return "HTTP ${reply.status}"
            val description = (o["error_description"] as? JsonString)?.value
            return if (description.isNullOrEmpty()) error else "$error（${description.take(120)}）"
        }
    }
}

// MARK: live token

/**
 * One connector's bearer, refreshed before expiry. One refresh runs at a time;
 * a rejected refresh drops the token and reports reauthorization.
 */
public class McpOAuthTokenSource(
    public val connector: McpConnector,
    private val store: McpOAuthStore,
    private val client: McpOAuthClient = McpOAuthClient(),
    private val now: () -> Long = System::currentTimeMillis,
    private val onReauthorizationRequired: () -> Unit = {},
) {
    private val mutex = Mutex()

    /** `null` when not connected or the user must authorize again. */
    public suspend fun bearer(forceRefresh: Boolean = false): String? = mutex.withLock {
        val current = store.read(connector.id) ?: return null
        val expiring = current.tokens.expiresAtMillis?.let { it - now() < REFRESH_SKEW_MILLIS } ?: false
        if (!expiring && !forceRefresh) return current.tokens.accessToken
        try {
            val fresh = client.refresh(current)
            // Persist before use, so a crash cannot strand a rotated refresh token.
            store.write(connector.id, fresh)
            fresh.tokens.accessToken
        } catch (failure: McpOAuthException) {
            if (failure.code == "reauthorization_required") {
                onReauthorizationRequired()
                null
            } else {
                current.tokens.accessToken // transient: the server decides
            }
        } catch (_: IOException) {
            current.tokens.accessToken
        }
    }

    private companion object { const val REFRESH_SKEW_MILLIS = 60_000L }
}
