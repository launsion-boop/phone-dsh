// phone-dsh — :net / com.phonedsh.account: tono-account wire rules.
// SPDX-License-Identifier: MIT
//
// The pure half of spec/v1/tono-account.md, ported from
// `Sources/PhoneDSH/TonoAccount/TonoAccountProtocol.swift`: phone and code
// normalization, the four request encodings, token-response validation,
// outcome classes, the stored session record and the access-token clock. No
// I/O and no logging; no value type prints a secret. The shared cases
// (`spec/v1/golden/tono-account/cases.json`) drive exactly these functions.

package com.phonedsh.account

import com.phonedsh.gateway.GatewayJson
import com.phonedsh.gateway.JsonValue

/** One request to the account service. `toString` never prints the body. */
class TonoAccountRequest(
    val method: String,
    val url: String,
    val headers: Map<String, String>,
    val body: ByteArray,
) {
    override fun toString(): String = "TonoAccountRequest($method $url)"
}

/** One answer from the account service. */
class TonoAccountAnswer(
    val status: Int,
    val headers: Map<String, String> = emptyMap(),
    val body: ByteArray = ByteArray(0),
) {
    override fun toString(): String = "TonoAccountAnswer($status)"
}

/** A validated token response. `toString` never prints a token. */
data class TonoTokenGrant(
    val accessToken: String,
    val refreshToken: String,
    val expiresIn: Int,
    val userId: String?,
    val phoneHint: String?,
) {
    override fun toString(): String = "TonoTokenGrant(expiresIn=$expiresIn, phoneHint=$phoneHint)"
}

/** §3 stored record. `toString` never prints the refresh token. */
data class TonoSessionRecord(
    val refreshToken: String,
    val loginAtMs: Long,
    val userId: String?,
    val phoneHint: String?,
) {
    override fun toString(): String = "TonoSessionRecord(loginAtMs=$loginAtMs, phoneHint=$phoneHint)"
}

/** What the device says about itself at sign-in; a model family, not a personal name. */
data class TonoDeviceInfo(
    val platform: String,
    val deviceName: String,
    val appVersion: String,
    val osVersion: String,
)

sealed interface TonoOtpOutcome {
    data class Challenge(val challengeId: String) : TonoOtpOutcome
    data object ProtocolError : TonoOtpOutcome
    data object Rejected : TonoOtpOutcome
    data class RateLimited(val retryAfterSeconds: Int?) : TonoOtpOutcome
    data object Transient : TonoOtpOutcome
}

sealed interface TonoLoginOutcome {
    data class SignedIn(val grant: TonoTokenGrant) : TonoLoginOutcome
    data object ProtocolError : TonoLoginOutcome
    data object InvalidCode : TonoLoginOutcome
    data object Rejected : TonoLoginOutcome
    data class RateLimited(val retryAfterSeconds: Int?) : TonoLoginOutcome
    data object Transient : TonoLoginOutcome
}

sealed interface TonoRefreshOutcome {
    data class Rotated(val grant: TonoTokenGrant) : TonoRefreshOutcome
    data object SessionEnded : TonoRefreshOutcome
    data object Transient : TonoRefreshOutcome
}

enum class TonoClockDecision { USE, REFRESH, REVERIFY_REQUIRED }

object TonoAccountProtocol {
    const val ACCOUNT_ORIGIN: String = "https://account.tonoai.cn"
    const val CLIENT_ID: String = "phone-dsh-ios"
    const val OTP_GRANT_TYPE: String = "urn:tono:params:oauth:grant-type:phone-otp"
    const val DEFAULT_ACCESS_LIFETIME_SECONDS: Int = 7200
    const val REFRESH_SKEW_SECONDS: Int = 300
    const val REVERIFY_AFTER_SECONDS: Long = 15_552_000
    const val TOKEN_MAX_LENGTH: Int = 4096
    const val RECORD_VERSION: Int = 1

    // ---- input normalization

    /** §2.1: `+86` and 11 ASCII digits starting with `1`; `null` otherwise. */
    fun canonicalPhone(raw: String): String? {
        var compact = raw.filterNot { it == ' ' || it == '-' || it == '\n' || it == '\r' || it == '\t' }
        if (compact.startsWith("+86")) compact = compact.substring(3)
        if (compact.length != 11 || !compact.startsWith("1") || !compact.all { it in '0'..'9' }) return null
        return "+86$compact"
    }

    /** §2.2: 4–8 ASCII digits after trimming whitespace. */
    fun canonicalCode(raw: String): String? {
        val trimmed = raw.trim()
        if (trimmed.length !in 4..8 || !trimmed.all { it in '0'..'9' }) return null
        return trimmed
    }

    /** The last four digits of a phone number, or `null`. */
    fun phoneHint(phone: String?): String? {
        if (phone == null || phone.length < 4) return null
        val tail = phone.takeLast(4)
        return if (tail.all { it in '0'..'9' }) tail else null
    }

    // ---- requests

    fun sendCodeRequest(phone: String, origin: String = ACCOUNT_ORIGIN): TonoAccountRequest =
        jsonRequest(origin, "/v1/auth/otp/send", JsonValue.objOfStrings(mapOf(
            "phone" to phone, "purpose" to "login", "client_id" to CLIENT_ID,
        )))

    fun signInRequest(
        phone: String,
        challengeId: String,
        code: String,
        device: TonoDeviceInfo,
        origin: String = ACCOUNT_ORIGIN,
    ): TonoAccountRequest = jsonRequest(origin, "/v1/oauth/token", JsonValue.obj(
        "grant_type" to JsonValue.Str(OTP_GRANT_TYPE),
        "client_id" to JsonValue.Str(CLIENT_ID),
        "phone" to JsonValue.Str(phone),
        "challenge_id" to JsonValue.Str(challengeId),
        "code" to JsonValue.Str(code),
        "device_info" to JsonValue.objOfStrings(mapOf(
            "platform" to device.platform,
            "device_name" to device.deviceName,
            "app_version" to device.appVersion,
            "os_version" to device.osVersion,
        )),
    ))

    fun refreshRequest(refreshToken: String, origin: String = ACCOUNT_ORIGIN): TonoAccountRequest =
        TonoAccountRequest(
            method = "POST",
            url = endpoint(origin, "/v1/oauth/token"),
            headers = linkedMapOf(
                "content-type" to "application/x-www-form-urlencoded",
                "accept" to "application/json",
            ),
            body = formEncode(listOf(
                "grant_type" to "refresh_token",
                "client_id" to CLIENT_ID,
                "refresh_token" to refreshToken,
            )).toByteArray(Charsets.UTF_8),
        )

    fun signOutRequest(accessToken: String, origin: String = ACCOUNT_ORIGIN): TonoAccountRequest =
        TonoAccountRequest(
            method = "POST",
            url = endpoint(origin, "/v1/auth/logout"),
            headers = linkedMapOf("authorization" to "Bearer $accessToken", "accept" to "application/json"),
            body = ByteArray(0),
        )

    /** §2.3 form encoding: unreserved bytes kept, every other UTF-8 byte `%XX`. */
    fun formEncode(pairs: List<Pair<String, String>>): String =
        pairs.joinToString("&") { (name, value) -> "${percentEncode(name)}=${percentEncode(value)}" }

    private fun percentEncode(value: String): String {
        val out = StringBuilder()
        for (byte in value.toByteArray(Charsets.UTF_8)) {
            val unsigned = byte.toInt() and 0xFF
            val char = unsigned.toChar()
            if (char in 'A'..'Z' || char in 'a'..'z' || char in '0'..'9' || char == '-' || char == '.' || char == '_' || char == '~') {
                out.append(char)
            } else {
                out.append('%').append(HEX[unsigned shr 4]).append(HEX[unsigned and 0x0F])
            }
        }
        return out.toString()
    }

    private const val HEX = "0123456789ABCDEF"

    private fun endpoint(origin: String, path: String): String = origin.trimEnd('/') + path

    private fun jsonRequest(origin: String, path: String, body: JsonValue): TonoAccountRequest =
        TonoAccountRequest(
            method = "POST",
            url = endpoint(origin, path),
            headers = linkedMapOf("content-type" to "application/json", "accept" to "application/json"),
            body = GatewayJson.canonicalBytes(body),
        )

    // ---- responses

    /** 1–4096 visible ASCII characters, no space or control. */
    fun isValidToken(value: String): Boolean =
        value.isNotEmpty() && value.length <= TOKEN_MAX_LENGTH && value.all { it in '!'..'~' }

    /** §2 token-response rules; `null` when the body is not a valid grant. */
    fun parseTokenResponse(body: ByteArray): TonoTokenGrant? {
        val root = GatewayJson.parseOrNull(body) as? JsonValue.Obj ?: return null
        val access = (root.get("access_token") as? JsonValue.Str)?.value ?: return null
        val refresh = (root.get("refresh_token") as? JsonValue.Str)?.value ?: return null
        if (!isValidToken(access) || access.startsWith("pdsk_") || !isValidToken(refresh)) return null
        var expiresIn = DEFAULT_ACCESS_LIFETIME_SECONDS
        root.get("expires_in")?.let { raw ->
            val value = integer(raw) ?: return null
            if (value < 1 || value > Int.MAX_VALUE) return null
            expiresIn = value.toInt()
        }
        root.get("token_type")?.let { raw ->
            val type = (raw as? JsonValue.Str)?.value ?: return null
            if (!type.equals("bearer", ignoreCase = true)) return null
        }
        val user = root.get("user") as? JsonValue.Obj
        return TonoTokenGrant(
            accessToken = access,
            refreshToken = refresh,
            expiresIn = expiresIn,
            userId = (user?.get("id") as? JsonValue.Str)?.value,
            phoneHint = phoneHint((user?.get("phone") as? JsonValue.Str)?.value),
        )
    }

    /** A JSON integer literal (no fraction, no exponent) as a Long. */
    private fun integer(value: JsonValue): Long? {
        val literal = (value as? JsonValue.Num)?.literal ?: return null
        if (literal.any { it == '.' || it == 'e' || it == 'E' }) return null
        return literal.toLongOrNull()
    }

    fun classifySendCode(answer: TonoAccountAnswer?): TonoOtpOutcome {
        answer ?: return TonoOtpOutcome.Transient
        return when (answer.status) {
            in 200..299 -> {
                val id = ((GatewayJson.parseOrNull(answer.body) as? JsonValue.Obj)?.get("challenge_id") as? JsonValue.Str)?.value
                if (id.isNullOrEmpty()) TonoOtpOutcome.ProtocolError else TonoOtpOutcome.Challenge(id)
            }
            400, 401, 403 -> TonoOtpOutcome.Rejected
            429 -> TonoOtpOutcome.RateLimited(retryAfterSeconds(answer.headers))
            else -> TonoOtpOutcome.Transient
        }
    }

    fun classifySignIn(answer: TonoAccountAnswer?): TonoLoginOutcome {
        answer ?: return TonoLoginOutcome.Transient
        return when (answer.status) {
            in 200..299 -> parseTokenResponse(answer.body)?.let { TonoLoginOutcome.SignedIn(it) }
                ?: TonoLoginOutcome.ProtocolError
            400, 401 -> TonoLoginOutcome.InvalidCode
            403 -> TonoLoginOutcome.Rejected
            429 -> TonoLoginOutcome.RateLimited(retryAfterSeconds(answer.headers))
            else -> TonoLoginOutcome.Transient
        }
    }

    fun classifyRefresh(answer: TonoAccountAnswer?): TonoRefreshOutcome {
        answer ?: return TonoRefreshOutcome.Transient
        return when (answer.status) {
            in 200..299 -> parseTokenResponse(answer.body)?.let { TonoRefreshOutcome.Rotated(it) }
                ?: TonoRefreshOutcome.SessionEnded
            400, 401, 403 -> TonoRefreshOutcome.SessionEnded
            else -> TonoRefreshOutcome.Transient
        }
    }

    /** `Retry-After` as whole seconds for a 429, or `null`. */
    private fun retryAfterSeconds(headers: Map<String, String>): Int? {
        val raw = headers.entries.firstOrNull { it.key.equals("retry-after", ignoreCase = true) }?.value?.trim()
            ?: return null
        if (raw.isEmpty() || raw.length > 9 || !raw.all { it in '0'..'9' }) return null
        return raw.toInt()
    }

    // ---- stored record (P18)

    fun decodeRecord(bytes: ByteArray): TonoSessionRecord? {
        val root = GatewayJson.parseOrNull(bytes) as? JsonValue.Obj ?: return null
        val version = root.get("version")?.let { integer(it) } ?: return null
        if (version != RECORD_VERSION.toLong()) return null
        val refresh = (root.get("refresh_token") as? JsonValue.Str)?.value ?: return null
        if (!isValidToken(refresh)) return null
        val loginAt = root.get("login_at_ms")?.let { integer(it) } ?: return null
        if (loginAt < 0) return null
        return TonoSessionRecord(
            refreshToken = refresh,
            loginAtMs = loginAt,
            userId = (root.get("user_id") as? JsonValue.Str)?.value,
            phoneHint = (root.get("phone_hint") as? JsonValue.Str)?.value,
        )
    }

    fun encodeRecord(record: TonoSessionRecord): ByteArray = GatewayJson.canonicalBytes(JsonValue.obj(
        "version" to JsonValue.num(RECORD_VERSION),
        "refresh_token" to JsonValue.Str(record.refreshToken),
        "login_at_ms" to JsonValue.num(record.loginAtMs),
        "user_id" to (record.userId?.let { JsonValue.Str(it) } ?: JsonValue.Null),
        "phone_hint" to (record.phoneHint?.let { JsonValue.Str(it) } ?: JsonValue.Null),
    ))

    // ---- clock

    /** §3 clock rule. */
    fun clockDecision(issuedAtMs: Long, expiresIn: Int, loginAtMs: Long, nowMs: Long): TonoClockDecision {
        if (nowMs - loginAtMs >= REVERIFY_AFTER_SECONDS * 1000) return TonoClockDecision.REVERIFY_REQUIRED
        if (nowMs < issuedAtMs) return TonoClockDecision.REFRESH
        val lifetimeMs = expiresIn.toLong() * 1000
        val skewMs = minOf(REFRESH_SKEW_SECONDS.toLong() * 1000, lifetimeMs / 2)
        return if (nowMs < issuedAtMs + lifetimeMs - skewMs) TonoClockDecision.USE else TonoClockDecision.REFRESH
    }
}
