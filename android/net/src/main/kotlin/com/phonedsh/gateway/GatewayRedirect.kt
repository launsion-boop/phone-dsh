// phone-dsh — :net / com.phonedsh.gateway: redirect scope.
// SPDX-License-Identifier: MIT
//
// Every hop is re-authorized before it is followed (§4). The order matters:
// an off-list target is `redirect_target_not_allowed`, a target inside the list
// but outside the credential's origin scope is `redirect_scope_mismatch`
// (gw-redir-001 vs :003/:004). A refused hop is never re-issued, receives no
// credential, and the caller gets the original 3xx. A request that carries no
// secret may cross hosts when both are allow-listed (gw-redir-006).

package com.phonedsh.gateway

object RedirectReasons {
    /** The hop target is not on the allow-list (or not http(s)). */
    const val TARGET_NOT_ALLOWED = "redirect_target_not_allowed"

    /** The hop target is allow-listed but outside the credential origin scope. */
    const val SCOPE_MISMATCH = "redirect_scope_mismatch"
}

sealed interface RedirectDecision {
    data object Follow : RedirectDecision

    data class Refuse(val reason: String) : RedirectDecision
}

/** Decides whether one 3xx hop may be re-issued. */
interface RedirectAuthorizer {
    fun authorize(
        target: GatewayUrl,
        credentialScope: CredentialOriginScope?,
        egress: EgressPolicy,
    ): RedirectDecision
}

/** The real rule: re-check the allow-list, then pin a credentialed chain. */
class ScopePinningRedirectAuthorizer : RedirectAuthorizer {
    override fun authorize(
        target: GatewayUrl,
        credentialScope: CredentialOriginScope?,
        egress: EgressPolicy,
    ): RedirectDecision {
        if (!target.isHttp || !egress.permits(target)) {
            return RedirectDecision.Refuse(RedirectReasons.TARGET_NOT_ALLOWED)
        }
        if (credentialScope != null && !credentialScope.matches(target)) {
            return RedirectDecision.Refuse(RedirectReasons.SCOPE_MISMATCH)
        }
        return RedirectDecision.Follow
    }
}
