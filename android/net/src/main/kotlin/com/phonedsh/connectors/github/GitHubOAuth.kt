// phone-dsh — :net / com.phonedsh.connectors.github: github-oauth-v1 client.
// SPDX-License-Identifier: MIT
//
// The Android consumer of spec/v1/github-oauth.md, ported from
// `examples/probe-app/ProbeKit/GitHubOAuthFlow.swift`
// (PC-20261119-android-connectors). Same configuration, state, code, verifier
// and `ghu_` token domains, same strict callback check, same broker status
// mapping. No code, verifier or token is ever logged or put in a message.

package com.phonedsh.connectors.github

import com.phonedsh.gateway.GatewayJson
import com.phonedsh.gateway.JsonValue
import java.io.ByteArrayOutputStream
import java.net.URI
import java.security.MessageDigest
import java.security.SecureRandom
import java.util.Base64
import kotlinx.coroutines.CancellationException

/** Everything the connector can fail with across session, callback and broker. */
enum class GitHubOAuthError {
    CANCELLED,
    RANDOM_UNAVAILABLE,
    INVALID_CONFIGURATION,
    INVALID_STATE,
    INVALID_CODE,
    INVALID_VERIFIER,
    INVALID_CALLBACK,
    STATE_MISMATCH,
    INVALID_TOKEN,
    INVALID_REQUEST,
    AUTHORIZATION_FAILED,
    INVALID_RESPONSE,
    SERVICE_UNAVAILABLE,
}

/** Carries only the fixed case; raw transport or broker strings are never kept. */
class GitHubOAuthException(val error: GitHubOAuthError) : Exception(error.name)

/** Validated connection inputs; [create] returns `null` for any bad value. */
class GitHubOAuthConfiguration private constructor(
    val origin: String,
    val clientId: String,
    val appSlug: String,
    val redirectUri: String,
    val exchangeEndpoint: String,
    val revokeEndpoint: String,
) {
    /** GitHub's authorization page. The verifier never appears here. */
    fun authorizationUrl(state: String, codeChallenge: String): String? {
        if (!GitHubOAuthPkce.isValidState(state) || !GitHubOAuthPkce.isValidChallenge(codeChallenge)) return null
        val query = listOf(
            "client_id" to clientId,
            "redirect_uri" to redirectUri,
            "state" to state,
            "code_challenge" to codeChallenge,
            "code_challenge_method" to "S256",
        ).joinToString("&") { (name, value) -> "${encodeQuery(name)}=${encodeQuery(value)}" }
        return "https://github.com/login/oauth/authorize?$query"
    }

    /** Fixed by the contract: the user picks repositories on GitHub's page. */
    val installationUrl: String get() = "https://github.com/apps/$appSlug/installations/new"

    override fun equals(other: Any?): Boolean =
        other is GitHubOAuthConfiguration && origin == other.origin &&
            clientId == other.clientId && appSlug == other.appSlug

    override fun hashCode(): Int = (origin.hashCode() * 31 + clientId.hashCode()) * 31 + appSlug.hashCode()

    override fun toString(): String = "GitHubOAuthConfiguration(origin=$origin, appSlug=$appSlug)"

    companion object {
        const val CALLBACK_SCHEME: String = "phonedsh-github"
        const val CALLBACK_HOST: String = "oauth"
        const val CALLBACK_PATH: String = "/callback"

        /** GitHub's page for reviewing and revoking GitHub App authorizations. */
        const val AUTHORIZED_APP_SETTINGS_URL: String = "https://github.com/settings/apps/authorizations"

        fun create(origin: String, clientId: String, appSlug: String): GitHubOAuthConfiguration? {
            val originText = origin.trim { it.isWhitespace() }
            val id = clientId.trim { it.isWhitespace() }
            val slug = appSlug.trim { it.isWhitespace() }
            val normalized = normalizedHttpsOrigin(originText) ?: return null
            if (!isValidClientId(id) || !isValidAppSlug(slug)) return null
            return GitHubOAuthConfiguration(
                origin = normalized,
                clientId = id,
                appSlug = slug,
                redirectUri = "$normalized/v1/github/oauth/callback",
                exchangeEndpoint = "$normalized/v1/github/oauth/exchange",
                revokeEndpoint = "$normalized/v1/github/oauth/revoke",
            )
        }

        private fun normalizedHttpsOrigin(raw: String): String? {
            if (raw.isEmpty() || raw.any { it.isWhitespace() }) return null
            val parsed = try {
                URI(raw)
            } catch (_: Exception) {
                return null
            }
            if (parsed.scheme?.lowercase() != "https") return null
            val authority = UrlAuthority.parse(parsed.rawAuthority) ?: return null
            if (authority.hasUserInfo || authority.host.isEmpty()) return null
            val path = parsed.rawPath ?: ""
            if (path.isNotEmpty() && path != "/") return null
            if (parsed.rawQuery != null || parsed.rawFragment != null) return null
            val port = authority.port
            if (port != null && port !in 1..65535) return null
            return "https://" + authority.host.lowercase() + (port?.let { ":$it" } ?: "")
        }

        private fun isValidClientId(value: String): Boolean {
            val bytes = value.toByteArray(Charsets.UTF_8)
            if (bytes.size !in 1..128) return false
            return bytes.all { isAsciiAlphaNumeric(it) || it == '-'.code.toByte() || it == '.'.code.toByte() || it == '_'.code.toByte() }
        }

        private fun isValidAppSlug(value: String): Boolean {
            val bytes = value.toByteArray(Charsets.UTF_8)
            if (bytes.size !in 1..100) return false
            if (bytes.first() == '-'.code.toByte() || bytes.last() == '-'.code.toByte()) return false
            return bytes.all { isAsciiAlphaNumeric(it) || it == '-'.code.toByte() }
        }

        private fun encodeQuery(value: String): String {
            val out = StringBuilder()
            for (byte in value.toByteArray(Charsets.UTF_8)) {
                val c = byte.toInt() and 0xFF
                if (c < 0x80 && (c.toChar().isLetterOrDigit() || c.toChar() in QUERY_SAFE)) {
                    out.append(c.toChar())
                } else {
                    out.append('%').append(HEX[c shr 4]).append(HEX[c and 0x0F])
                }
            }
            return out.toString()
        }

        private const val QUERY_SAFE = "-._~!$'()*,;:@/?"
        private const val HEX = "0123456789ABCDEF"
    }
}

/** The fixed native callback. */
sealed interface GitHubOAuthCallback {
    data class Code(val code: String) : GitHubOAuthCallback {
        override fun toString(): String = "Code(<redacted>)"
    }
    data object AccessDenied : GitHubOAuthCallback
}

/**
 * Strict validation of the broker's native callback: exactly one state plus
 * one code or the normalized `access_denied`; everything else is rejected.
 */
object GitHubOAuthCallbackValidator {
    fun validate(url: String, expectedState: String): GitHubOAuthCallback {
        if (!GitHubOAuthPkce.isValidState(expectedState)) throw GitHubOAuthException(GitHubOAuthError.INVALID_STATE)
        val invalid = GitHubOAuthException(GitHubOAuthError.INVALID_CALLBACK)
        val parsed = try {
            URI(url)
        } catch (_: Exception) {
            throw invalid
        }
        if (parsed.scheme?.lowercase() != GitHubOAuthConfiguration.CALLBACK_SCHEME) throw invalid
        val authority = UrlAuthority.parse(parsed.rawAuthority) ?: throw invalid
        if (authority.host.lowercase() != GitHubOAuthConfiguration.CALLBACK_HOST) throw invalid
        if (parsed.rawPath != GitHubOAuthConfiguration.CALLBACK_PATH) throw invalid
        if (authority.port != null || authority.hasUserInfo || parsed.rawFragment != null) throw invalid
        val query = parsed.rawQuery ?: throw invalid
        val items = query.split('&')
        if (items.size != 2) throw invalid

        val values = HashMap<String, String>()
        for (item in items) {
            val separator = item.indexOf('=')
            if (separator < 0) throw invalid
            val name = percentDecode(item.substring(0, separator)) ?: throw invalid
            val value = percentDecode(item.substring(separator + 1)) ?: throw invalid
            if (name != "state" && name != "code" && name != "error") throw invalid
            if (values.containsKey(name) || value.isEmpty()) throw invalid
            values[name] = value
        }

        val state = values["state"] ?: throw invalid
        if (state != expectedState) throw GitHubOAuthException(GitHubOAuthError.STATE_MISMATCH)

        val code = values["code"]
        val error = values["error"]
        if (code != null && error == null) {
            if (!GitHubOAuthPkce.isValidCode(code)) throw invalid
            return GitHubOAuthCallback.Code(code)
        }
        if (error != null && code == null) {
            if (error != "access_denied") throw invalid
            return GitHubOAuthCallback.AccessDenied
        }
        throw invalid
    }

    /** RFC 3986 percent-decoding (no `+` to space); `null` on a bad escape or bad UTF-8. */
    private fun percentDecode(raw: String): String? {
        if (raw.indexOf('%') < 0) return raw
        val out = ByteArrayOutputStream()
        var index = 0
        while (index < raw.length) {
            val c = raw[index]
            if (c == '%') {
                if (index + 2 >= raw.length) return null
                val high = Character.digit(raw[index + 1], 16)
                val low = Character.digit(raw[index + 2], 16)
                if (high < 0 || low < 0) return null
                out.write(high * 16 + low)
                index += 3
            } else {
                out.write(c.toString().toByteArray(Charsets.UTF_8))
                index += 1
            }
        }
        val decoder = Charsets.UTF_8.newDecoder()
        return try {
            decoder.decode(java.nio.ByteBuffer.wrap(out.toByteArray())).toString()
        } catch (_: java.nio.charset.CharacterCodingException) {
            null
        }
    }
}

/** State, RFC 7636 verifier and S256 challenge for one authorization attempt. */
class GitHubOAuthAttempt(val state: String, val verifier: String) {
    val challenge: String

    init {
        if (!GitHubOAuthPkce.isValidState(state)) throw GitHubOAuthException(GitHubOAuthError.INVALID_STATE)
        if (!GitHubOAuthPkce.isValidVerifier(verifier)) throw GitHubOAuthException(GitHubOAuthError.INVALID_VERIFIER)
        challenge = GitHubOAuthPkce.codeChallenge(verifier)
    }

    override fun equals(other: Any?): Boolean =
        other is GitHubOAuthAttempt && state == other.state && verifier == other.verifier

    override fun hashCode(): Int = state.hashCode() * 31 + verifier.hashCode()

    override fun toString(): String = "GitHubOAuthAttempt(<redacted>)"
}

object GitHubOAuthPkce {
    /** 32 random bytes encode to exactly 43 base64url characters. */
    fun makeAttempt(randomBytes: (Int) -> ByteArray = GitHubOAuthSecureRandom::bytes): GitHubOAuthAttempt {
        val state = randomUrlSafeString(randomBytes)
        val verifier = randomUrlSafeString(randomBytes)
        return GitHubOAuthAttempt(state, verifier)
    }

    fun codeChallenge(verifier: String): String {
        if (!isValidVerifier(verifier)) throw GitHubOAuthException(GitHubOAuthError.INVALID_VERIFIER)
        val digest = MessageDigest.getInstance("SHA-256").digest(verifier.toByteArray(Charsets.UTF_8))
        return base64Url(digest)
    }

    fun base64Url(data: ByteArray): String = Base64.getUrlEncoder().withoutPadding().encodeToString(data)

    fun isValidState(value: String): Boolean {
        val bytes = value.toByteArray(Charsets.UTF_8)
        return bytes.size == 43 && bytes.all(::isBase64UrlByte)
    }

    fun isValidChallenge(value: String): Boolean {
        val bytes = value.toByteArray(Charsets.UTF_8)
        return bytes.size == 43 && bytes.all(::isBase64UrlByte)
    }

    /** 1 to 512 URL-safe ASCII characters: letters, digits, underscore, hyphen. */
    fun isValidCode(value: String): Boolean {
        val bytes = value.toByteArray(Charsets.UTF_8)
        if (bytes.size !in 1..512) return false
        return bytes.all(::isBase64UrlByte)
    }

    /** 43 to 128 RFC 7636 unreserved characters. */
    fun isValidVerifier(value: String): Boolean {
        val bytes = value.toByteArray(Charsets.UTF_8)
        if (bytes.size !in 43..128) return false
        return bytes.all { isAsciiAlphaNumeric(it) || it == '-'.code.toByte() || it == '.'.code.toByte() || it == '_'.code.toByte() || it == '~'.code.toByte() }
    }

    private fun randomUrlSafeString(randomBytes: (Int) -> ByteArray): String {
        val data = randomBytes(32)
        if (data.size != 32) throw GitHubOAuthException(GitHubOAuthError.RANDOM_UNAVAILABLE)
        return base64Url(data)
    }

    private fun isBase64UrlByte(byte: Byte): Boolean =
        isAsciiAlphaNumeric(byte) || byte == '-'.code.toByte() || byte == '_'.code.toByte()
}

object GitHubOAuthSecureRandom {
    private val random: SecureRandom by lazy { SecureRandom() }

    fun bytes(count: Int): ByteArray {
        if (count !in 1..1024) throw GitHubOAuthException(GitHubOAuthError.RANDOM_UNAVAILABLE)
        return try {
            ByteArray(count).also { random.nextBytes(it) }
        } catch (_: Exception) {
            throw GitHubOAuthException(GitHubOAuthError.RANDOM_UNAVAILABLE)
        }
    }
}

class GitHubOAuthToken(val accessToken: String, val expiresIn: Long) {
    override fun equals(other: Any?): Boolean =
        other is GitHubOAuthToken && accessToken == other.accessToken && expiresIn == other.expiresIn

    override fun hashCode(): Int = accessToken.hashCode() * 31 + expiresIn.hashCode()

    override fun toString(): String = "GitHubOAuthToken(<redacted>, expiresIn=$expiresIn)"
}

/** The broker exchange/revoke client: no redirects, ten-second timeout. */
class GitHubOAuthBroker(
    val configuration: GitHubOAuthConfiguration,
    private val transport: GitHubHttpTransport = HttpUrlConnectionGitHubTransport(TIMEOUT_MILLIS),
) {
    suspend fun exchange(code: String, codeVerifier: String): GitHubOAuthToken {
        if (!GitHubOAuthPkce.isValidCode(code)) throw GitHubOAuthException(GitHubOAuthError.INVALID_CODE)
        if (!GitHubOAuthPkce.isValidVerifier(codeVerifier)) throw GitHubOAuthException(GitHubOAuthError.INVALID_VERIFIER)

        val body = GatewayJson.canonicalBytes(
            JsonValue.obj("code" to JsonValue.Str(code), "code_verifier" to JsonValue.Str(codeVerifier)),
        )
        val response = post(configuration.exchangeEndpoint, body)
        when (response.status) {
            200 -> Unit
            400 -> throw GitHubOAuthException(GitHubOAuthError.INVALID_REQUEST)
            401 -> throw GitHubOAuthException(GitHubOAuthError.AUTHORIZATION_FAILED)
            else -> throw GitHubOAuthException(GitHubOAuthError.SERVICE_UNAVAILABLE)
        }

        val root = GatewayJson.parseOrNull(response.body) as? JsonValue.Obj
            ?: throw GitHubOAuthException(GitHubOAuthError.INVALID_RESPONSE)
        val accessToken = (root.get("access_token") as? JsonValue.Str)?.value
            ?: throw GitHubOAuthException(GitHubOAuthError.INVALID_RESPONSE)
        val expiresIn = (root.get("expires_in") as? JsonValue.Num)?.literal?.toLongOrNull()
            ?: throw GitHubOAuthException(GitHubOAuthError.INVALID_RESPONSE)
        if (!GitHubConnectorApi.isValidToken(accessToken) || expiresIn <= 0) {
            throw GitHubOAuthException(GitHubOAuthError.INVALID_TOKEN)
        }
        return GitHubOAuthToken(accessToken, expiresIn)
    }

    suspend fun revoke(token: String) {
        if (!GitHubConnectorApi.isValidToken(token)) throw GitHubOAuthException(GitHubOAuthError.INVALID_TOKEN)
        val body = GatewayJson.canonicalBytes(JsonValue.obj("access_token" to JsonValue.Str(token)))
        val response = post(configuration.revokeEndpoint, body)
        when (response.status) {
            204 -> return
            400 -> throw GitHubOAuthException(GitHubOAuthError.INVALID_REQUEST)
            401 -> throw GitHubOAuthException(GitHubOAuthError.AUTHORIZATION_FAILED)
            else -> throw GitHubOAuthException(GitHubOAuthError.SERVICE_UNAVAILABLE)
        }
    }

    private suspend fun post(url: String, body: ByteArray): ConnectorHttpResponse {
        // The broker caps app POST bodies at 4 KiB; validated fields cannot
        // reach it, so this is a defensive assertion, not a fallback.
        if (body.size > MAX_REQUEST_BYTES) throw GitHubOAuthException(GitHubOAuthError.INVALID_REQUEST)
        val request = ConnectorHttpRequest(
            method = "POST",
            url = url,
            headers = mapOf(
                "Content-Type" to "application/json",
                "Accept" to "application/json",
                "User-Agent" to "phone-dsh",
            ),
            body = body,
        )
        return try {
            transport.send(request)
        } catch (error: GitHubOAuthException) {
            throw error
        } catch (_: CancellationException) {
            throw GitHubOAuthException(GitHubOAuthError.CANCELLED)
        } catch (_: Exception) {
            throw GitHubOAuthException(GitHubOAuthError.SERVICE_UNAVAILABLE)
        }
    }

    companion object {
        const val TIMEOUT_MILLIS: Int = 10_000
        const val MAX_REQUEST_BYTES: Int = 4096
    }
}

/** `[userinfo@]host[:port]` split of a raw authority; `null` when malformed. */
internal class UrlAuthority(val hasUserInfo: Boolean, val host: String, val port: Int?) {
    companion object {
        fun parse(raw: String?): UrlAuthority? {
            if (raw == null) return null
            val at = raw.lastIndexOf('@')
            val hasUserInfo = at >= 0
            val hostPort = if (hasUserInfo) raw.substring(at + 1) else raw
            val host: String
            val portText: String?
            if (hostPort.startsWith("[")) {
                val close = hostPort.indexOf(']')
                if (close < 0) return null
                host = hostPort.substring(0, close + 1)
                val rest = hostPort.substring(close + 1)
                portText = when {
                    rest.isEmpty() -> null
                    rest.startsWith(":") -> rest.substring(1)
                    else -> return null
                }
            } else {
                val colon = hostPort.lastIndexOf(':')
                host = if (colon >= 0) hostPort.substring(0, colon) else hostPort
                portText = if (colon >= 0) hostPort.substring(colon + 1) else null
            }
            val port = when {
                portText.isNullOrEmpty() -> null
                portText.all { it in '0'..'9' } -> portText.toIntOrNull() ?: return null
                else -> return null
            }
            return UrlAuthority(hasUserInfo, host, port)
        }
    }
}

internal fun isAsciiAlphaNumeric(byte: Byte): Boolean {
    val c = byte.toInt() and 0xFF
    return c in 48..57 || c in 65..90 || c in 97..122
}
