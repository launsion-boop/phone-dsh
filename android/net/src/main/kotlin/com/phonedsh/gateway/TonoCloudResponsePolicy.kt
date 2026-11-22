// phone-dsh — :net / com.phonedsh.gateway: cloud-origin 401/503 policy.
// SPDX-License-Identifier: MIT
//
// The Kotlin end of spec/v1/tono-account.md §5–§6, ported from
// `Sources/PhoneDSHGateway/TonoCloudResponsePolicy.swift`. The phoneDSH cloud
// answers an expired user token with 401 `credential_expired` and an
// unreachable account service with 503 `identity_unavailable`; both reject the
// request before any model work, so the host may re-send them. The shared
// cases (`spec/v1/golden/tono-account/cases.json`, `cloud_responses`) judge
// [decide].
//
// §11 (PC-20261121-cloud-wallet-credits): a 402 from the cloud origin is a
// credits answer. It is never re-sent; [creditsCondition] classifies it
// (`credits_responses`) so the host can raise one notice.

package com.phonedsh.gateway

import java.net.URI

/** Decides what the host does with a 401/503 answer from the cloud origin. */
class TonoCloudResponsePolicy(origins: Collection<String>) {

    /** One exact origin: lowercased scheme and host, effective port. */
    data class Origin(val scheme: String, val host: String, val port: Int) {
        companion object {
            fun of(url: String): Origin? {
                val uri = try {
                    URI(url.trim())
                } catch (_: Exception) {
                    return null
                }
                val scheme = uri.scheme?.lowercase() ?: return null
                if (scheme != "https" && scheme != "http") return null
                val host = uri.host?.lowercase()?.takeIf { it.isNotEmpty() } ?: return null
                val port = if (uri.port >= 0) uri.port else if (scheme == "https") 443 else 80
                return Origin(scheme, host, port)
            }
        }
    }

    sealed interface Decision {
        /** Hand the answer on unchanged. */
        data object Forward : Decision

        /** Invalidate the injected credential and re-send once if it changed. */
        data object RefreshRetry : Decision

        /** Wait [seconds] and re-send. */
        data class RetryAfter(val seconds: Long) : Decision
    }

    /** §11: what a cloud-origin 402 says about the account's credits. */
    enum class CreditsCondition(val wire: String) {
        NOT_CLAIMED("not_claimed"),
        INSUFFICIENT("insufficient"),
        UNSPECIFIED("unspecified"),
    }

    val origins: Set<Origin> = origins.mapNotNull { Origin.of(it) }.toSet()

    fun applies(url: String): Boolean = Origin.of(url)?.let { it in origins } ?: false

    /** True for an answer whose body must be read before anything is forwarded. */
    fun inspects(url: String, status: Int): Boolean =
        (status == 401 || status == 402 || status == 503) && applies(url)

    /** §11: the credits condition, or `null` when this is not a 402 from an inspected origin. */
    fun creditsCondition(url: String, status: Int, body: ByteArray?): CreditsCondition? {
        if (status != 402 || !applies(url)) return null
        return creditsConditionOf402(body)
    }

    /** The decision for one complete answer of at most [INSPECT_BODY_LIMIT] bytes. */
    fun decide(url: String, status: Int, headers: Map<String, String>, body: ByteArray): Decision {
        if (!inspects(url, status) || body.size > INSPECT_BODY_LIMIT) return Decision.Forward
        val codes = errorCodes(body)
        if (status == 401 && CREDENTIAL_EXPIRED in codes) return Decision.RefreshRetry
        if (status == 503 && IDENTITY_UNAVAILABLE in codes) {
            val raw = headers.entries.firstOrNull { it.key.equals("retry-after", ignoreCase = true) }?.value
            return Decision.RetryAfter(retryAfterSeconds(raw))
        }
        return Decision.Forward
    }

    companion object {
        const val CLOUD_ORIGIN: String = "https://pdsh.tonoai.cn"
        const val INSPECT_BODY_LIMIT: Int = 16_384
        const val CREDENTIAL_RETRY_MAX: Int = 1
        const val IDENTITY_RETRY_MAX: Int = 2
        const val IDENTITY_RETRY_DEFAULT_SECONDS: Long = 1
        const val IDENTITY_RETRY_CAP_SECONDS: Long = 30
        const val CREDENTIAL_EXPIRED: String = "credential_expired"
        const val IDENTITY_UNAVAILABLE: String = "identity_unavailable"

        /** Production: only the cloud origin. */
        val PRODUCTION: TonoCloudResponsePolicy = TonoCloudResponsePolicy(listOf(CLOUD_ORIGIN))

        /** Never inspects anything. */
        val DISABLED: TonoCloudResponsePolicy = TonoCloudResponsePolicy(emptyList())

        const val CREDITS_NOT_CLAIMED: String = "credits_not_claimed"
        const val INSUFFICIENT_CREDITS: String = "insufficient_credits"

        /** §11 for a 402 already known to come from the cloud origin; `null` body = unread. */
        fun creditsConditionOf402(body: ByteArray?): CreditsCondition {
            if (body == null || body.size > INSPECT_BODY_LIMIT) return CreditsCondition.UNSPECIFIED
            val root = GatewayJson.parseOrNull(body) as? JsonValue.Obj ?: return CreditsCondition.UNSPECIFIED
            return when (root.obj("error")?.string("code")) {
                CREDITS_NOT_CLAIMED -> CreditsCondition.NOT_CLAIMED
                INSUFFICIENT_CREDITS -> CreditsCondition.INSUFFICIENT
                else -> CreditsCondition.UNSPECIFIED
            }
        }

        /** §6: non-negative ASCII decimal seconds, capped; anything else is the default. */
        fun retryAfterSeconds(raw: String?): Long {
            val trimmed = raw?.trim() ?: return IDENTITY_RETRY_DEFAULT_SECONDS
            if (trimmed.isEmpty() || trimmed.length > 10 || !trimmed.all { it in '0'..'9' }) {
                return IDENTITY_RETRY_DEFAULT_SECONDS
            }
            return minOf(trimmed.toLong(), IDENTITY_RETRY_CAP_SECONDS)
        }

        /** `error.code` and `error.type` of a JSON object body, when they are strings. */
        internal fun errorCodes(body: ByteArray): Set<String> {
            val root = GatewayJson.parseOrNull(body) as? JsonValue.Obj ?: return emptySet()
            val error = root.obj("error") ?: return emptySet()
            return setOfNotNull(error.string("code"), error.string("type"))
        }
    }
}
