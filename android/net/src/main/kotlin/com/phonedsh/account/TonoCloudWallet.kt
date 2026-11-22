// phone-dsh — :net / com.phonedsh.account: cloud wallet, claim and credits notices.
// SPDX-License-Identifier: MIT
//
// The Kotlin end of spec/v1/tono-account.md §10–§11
// (PC-20261121-cloud-wallet-credits), ported from
// `Sources/PhoneDSH/TonoAccount/TonoCloudWallet.swift`. The wallet is read and
// claimed only with a signed-in user's access token, never an API key. A
// cloud-origin 402 is classified by [TonoCloudResponsePolicy] and posted to
// [TonoCloudCreditsSignal]; the app turns it into one notice and re-reads the
// wallet. The shared cases (`spec/v1/golden/tono-account/cases.json`:
// `wallet_responses`, `claim_responses`, `credit_display`, `credits_guidance`)
// judge this file.

package com.phonedsh.account

import com.phonedsh.gateway.GatewayJson
import com.phonedsh.gateway.JsonValue
import com.phonedsh.gateway.TonoCloudResponsePolicy
import kotlinx.coroutines.channels.BufferOverflow
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.asSharedFlow

typealias TonoCreditsCondition = TonoCloudResponsePolicy.CreditsCondition

/** What the wallet page may show. Counters are micro-credit decimal strings. */
data class TonoCloudWallet(
    val availableMicroCredits: String,
    val claimable: Boolean,
    /** `shadow`, `live` or a future value; informational only. */
    val mode: String?,
) {
    /** §10 display: credits, truncated to two decimals. */
    val displayCredits: String get() = TonoCloudWalletProtocol.displayCredits(availableMicroCredits) ?: "0"
}

sealed interface TonoWalletReadOutcome {
    data class Wallet(val wallet: TonoCloudWallet) : TonoWalletReadOutcome
    data object ProtocolError : TonoWalletReadOutcome
    data object Unauthorized : TonoWalletReadOutcome
    data object Rejected : TonoWalletReadOutcome
    data object Unavailable : TonoWalletReadOutcome
    data object Transient : TonoWalletReadOutcome
}

sealed interface TonoWalletClaimOutcome {
    data class Claimed(val grantedNow: Boolean, val wallet: TonoCloudWallet) : TonoWalletClaimOutcome
    data object ProtocolError : TonoWalletClaimOutcome
    data object Unauthorized : TonoWalletClaimOutcome
    data object Rejected : TonoWalletClaimOutcome
    data object Unavailable : TonoWalletClaimOutcome
    data object Transient : TonoWalletClaimOutcome
}

/** §11 guidance for one credits condition. */
enum class TonoCreditsGuidance(val wire: String) { CLAIM("claim"), EXHAUSTED("exhausted"), UNKNOWN("unknown") }

object TonoCloudWalletProtocol {
    const val WALLET_PATH: String = "/v1/wallet"
    const val CLAIM_PATH: String = "/v1/wallet/claim"
    const val MICRO_CREDITS_PER_CREDIT: Int = 1_000_000
    const val MICRO_CREDITS_MAX_DIGITS: Int = 30

    fun walletRequest(origin: String, accessToken: String): TonoAccountRequest =
        request(origin, WALLET_PATH, "GET", accessToken)

    fun claimRequest(origin: String, accessToken: String): TonoAccountRequest =
        request(origin, CLAIM_PATH, "POST", accessToken)

    private fun request(origin: String, path: String, method: String, accessToken: String) = TonoAccountRequest(
        method = method,
        url = origin.trimEnd('/') + path,
        headers = linkedMapOf("Accept" to "application/json", "Authorization" to "Bearer $accessToken"),
        body = ByteArray(0),
    )

    fun classifyRead(answer: TonoAccountAnswer?): TonoWalletReadOutcome {
        answer ?: return TonoWalletReadOutcome.Transient
        return when (answer.status) {
            in 200..299 -> wallet(GatewayJson.parseOrNull(answer.body) as? JsonValue.Obj)
                ?.let { TonoWalletReadOutcome.Wallet(it) } ?: TonoWalletReadOutcome.ProtocolError
            401 -> TonoWalletReadOutcome.Unauthorized
            403 -> TonoWalletReadOutcome.Rejected
            404 -> TonoWalletReadOutcome.Unavailable
            else -> TonoWalletReadOutcome.Transient
        }
    }

    fun classifyClaim(answer: TonoAccountAnswer?): TonoWalletClaimOutcome {
        answer ?: return TonoWalletClaimOutcome.Transient
        return when (answer.status) {
            in 200..299 -> {
                val root = GatewayJson.parseOrNull(answer.body) as? JsonValue.Obj
                val grantedNow = root?.bool("granted_now")
                val wallet = wallet(root?.obj("wallet"))
                if (grantedNow == null || wallet == null) TonoWalletClaimOutcome.ProtocolError
                else TonoWalletClaimOutcome.Claimed(grantedNow, wallet)
            }
            401 -> TonoWalletClaimOutcome.Unauthorized
            403 -> TonoWalletClaimOutcome.Rejected
            404 -> TonoWalletClaimOutcome.Unavailable
            else -> TonoWalletClaimOutcome.Transient
        }
    }

    /** A valid §10 wallet object, or `null`. */
    internal fun wallet(root: JsonValue.Obj?): TonoCloudWallet? {
        root ?: return null
        val available = root.string("available_micro_credits")?.takeIf(::isMicroCredits) ?: return null
        val claimable = root.bool("claimable") ?: return null
        val rawMode = root.get("mode")
        val mode = when (rawMode) {
            null -> null
            is JsonValue.Str -> rawMode.value
            else -> return null
        }
        return TonoCloudWallet(available, claimable, mode)
    }

    /** 1…30 ASCII digits. */
    fun isMicroCredits(value: String): Boolean =
        value.isNotEmpty() && value.length <= MICRO_CREDITS_MAX_DIGITS && value.all { it in '0'..'9' }

    /** §10: ÷ 1 000 000, truncated to two decimals, trailing zeros and point removed, no grouping. */
    fun displayCredits(micro: String): String? {
        if (!isMicroCredits(micro)) return null
        val digits = micro.trimStart('0').padStart(7, '0')
        val integer = digits.dropLast(6)
        val fraction = digits.takeLast(6).take(2).trimEnd('0')
        return if (fraction.isEmpty()) integer else "$integer.$fraction"
    }

    /** §11 rule 2. */
    fun guidance(condition: TonoCreditsCondition, walletClaimable: Boolean?): TonoCreditsGuidance = when (condition) {
        TonoCreditsCondition.NOT_CLAIMED -> TonoCreditsGuidance.CLAIM
        TonoCreditsCondition.INSUFFICIENT -> TonoCreditsGuidance.EXHAUSTED
        TonoCreditsCondition.UNSPECIFIED -> when (walletClaimable) {
            null -> TonoCreditsGuidance.UNKNOWN
            true -> TonoCreditsGuidance.CLAIM
            false -> TonoCreditsGuidance.EXHAUSTED
        }
    }
}

/**
 * §10: wallet read and claim over the account transport (no redirects, bounded
 * body). §5 applies: one refresh and re-send on 401 `credential_expired` when
 * the token changed. Blocking; call from an IO thread. `null` = signed out.
 */
class TonoCloudWalletClient(
    private val transport: TonoAccountTransport,
    private val tokens: TonoAccessTokenSource,
    private val origin: String = TonoCloudResponsePolicy.CLOUD_ORIGIN,
) {
    fun read(): TonoWalletReadOutcome? =
        exchange { TonoCloudWalletProtocol.walletRequest(origin, it) }?.let { TonoCloudWalletProtocol.classifyRead(it.answer) }

    fun claim(): TonoWalletClaimOutcome? =
        exchange { TonoCloudWalletProtocol.claimRequest(origin, it) }?.let { TonoCloudWalletProtocol.classifyClaim(it.answer) }

    private class Exchanged(val answer: TonoAccountAnswer?)

    private fun exchange(make: (String) -> TonoAccountRequest): Exchanged? {
        val token = try {
            tokens.accessToken() ?: return null
        } catch (_: TonoAccountException) {
            return Exchanged(null)
        }
        val first = runCatching { transport.send(make(token)) }.getOrNull()
        if (first == null || first.status != 401 ||
            TonoCloudResponsePolicy.PRODUCTION.decide(origin, 401, first.headers, first.body) !=
            TonoCloudResponsePolicy.Decision.RefreshRetry
        ) {
            return Exchanged(first)
        }
        tokens.invalidate(token)
        val fresh = try {
            tokens.accessToken()
        } catch (_: TonoAccountException) {
            null
        }
        if (fresh == null || fresh == token) return Exchanged(first)
        return Exchanged(runCatching { transport.send(make(fresh)) }.getOrNull())
    }
}

/** Process-wide broadcast of §11 credits conditions; no effect without a collector. */
object TonoCloudCreditsSignal {
    private val flow = MutableSharedFlow<TonoCreditsCondition>(
        extraBufferCapacity = 8,
        onBufferOverflow = BufferOverflow.DROP_OLDEST,
    )

    val conditions: SharedFlow<TonoCreditsCondition> = flow.asSharedFlow()

    fun post(condition: TonoCreditsCondition) {
        flow.tryEmit(condition)
    }
}
