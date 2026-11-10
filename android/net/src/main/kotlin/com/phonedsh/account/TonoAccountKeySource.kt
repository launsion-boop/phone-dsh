// phone-dsh — :net / com.phonedsh.account: the account token behind the key seam.
// SPDX-License-Identifier: MIT
//
// spec/v1/tono-account.md §4 on Android. The model and independent-search
// providers already resolve their key through `ModelKeySource`; this overlay
// puts the access token in front of the stored key only when the endpoint is
// the cloud origin, so origin and path admission stay where they are
// (`ModelGatewayCredentialProvider`, `IndependentSearchCredentialProvider`).
// Signed out the stored key is read exactly as before; signed in without a
// token the read fails closed instead of falling back to the shared key.

package com.phonedsh.account

import com.phonedsh.gateway.CredentialUnavailableException
import com.phonedsh.gateway.ModelKeySource
import com.phonedsh.gateway.TonoCloudResponsePolicy

object TonoAccountKeySource {
    /**
     * The key source for an endpoint whose origin is [endpointOrigin]
     * (`scheme://host[:port]`). Any other origin gets [stored] unchanged.
     */
    fun overlay(endpointOrigin: String, tokens: TonoAccessTokenSource, stored: ModelKeySource): ModelKeySource {
        if (!TonoCloudResponsePolicy.PRODUCTION.applies(endpointOrigin)) return stored
        return object : ModelKeySource {
            override fun readKey(): String? {
                val token = try {
                    tokens.accessToken()
                } catch (_: TonoAccountException) {
                    throw CredentialUnavailableException(NO_TOKEN)
                }
                return token ?: stored.readKey()
            }

            override fun invalidate(value: String) {
                // The session ignores any value that is not its current token.
                tokens.invalidate(value)
                stored.invalidate(value)
            }

            override fun toString(): String = "TonoAccountKeySource($endpointOrigin)"
        }
    }

    /** Launch hint: the endpoint is the cloud origin and a session is present. */
    fun usesAccount(endpointOrigin: String, tokens: TonoAccessTokenSource?): Boolean =
        tokens != null && TonoCloudResponsePolicy.PRODUCTION.applies(endpointOrigin) && tokens.hasSession

    private const val NO_TOKEN: String = "the tono account session has no usable access token"
}
