// phone-dsh — :app: Gmail authorization through Google Identity Services.
// SPDX-License-Identifier: MIT
//
// The Android half of iOS `GmailSignIn.swift` (PC-20261119-android-connectors):
// `AuthorizationClient` asks for `gmail.readonly` only. The OAuth client is
// registered by package and signing certificate, so no client id ships; the build
// flag `PDSH_GMAIL_ENABLED` says the registration exists.
//
// Google Play services keeps the grant and the access token. This app stores one
// Boolean, `phone-dsh-gmail` / `connected.v1`, so a page open restores silently
// and a disconnect is not undone by a grant whose revoke failed. No token,
// address or mail is persisted, and nothing here logs.

package com.phonedsh.probe.connectors

import android.accounts.Account
import android.app.Activity
import android.content.Context
import com.google.android.gms.auth.api.identity.AuthorizationRequest
import com.google.android.gms.auth.api.identity.AuthorizationResult
import com.google.android.gms.auth.api.identity.ClearTokenRequest
import com.google.android.gms.auth.api.identity.Identity
import com.google.android.gms.auth.api.identity.RevokeAccessRequest
import com.google.android.gms.common.api.ApiException
import com.google.android.gms.common.api.Scope
import com.google.android.gms.tasks.Task
import com.phonedsh.connectors.gmail.GmailAuthorizationException
import com.phonedsh.connectors.gmail.GmailAuthorizationFailure
import com.phonedsh.connectors.gmail.GmailAuthorizer
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException
import kotlinx.coroutines.suspendCancellableCoroutine

internal class GoogleGmailAuthorizer(
    context: Context,
    override val isConfigured: Boolean,
    /** The connected address, for the revoke request; Google needs the account it revokes. */
    private val connectedEmail: () -> String?,
) : GmailAuthorizer {
    private val appContext = context.applicationContext
    private val client = Identity.getAuthorizationClient(appContext)
    private val preferences = appContext.getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE)
    private val request: AuthorizationRequest = AuthorizationRequest.builder()
        .setRequestedScopes(listOf(Scope(READ_SCOPE)))
        .build()
    private var lastToken: String? = null

    private var connected: Boolean
        get() = preferences.getBoolean(KEY_CONNECTED, false)
        set(value) {
            preferences.edit().putBoolean(KEY_CONNECTED, value).apply()
        }

    override suspend fun restore(): Boolean = isConfigured && connected

    override suspend fun connect() {
        if (!isConfigured) throw GmailAuthorizationException(GmailAuthorizationFailure.UNAVAILABLE)
        var result = authorize()
        if (result.hasResolution()) {
            val intent = result.pendingIntent ?: throw GmailAuthorizationException(GmailAuthorizationFailure.UNAVAILABLE)
            val activityResult = ConnectorActivityBridge.resolve(intent)
                ?: throw GmailAuthorizationException(GmailAuthorizationFailure.UNAVAILABLE)
            if (activityResult.resultCode != Activity.RESULT_OK) {
                throw GmailAuthorizationException(GmailAuthorizationFailure.CANCELLED)
            }
            result = try {
                client.getAuthorizationResultFromIntent(activityResult.data)
            } catch (_: ApiException) {
                throw GmailAuthorizationException(GmailAuthorizationFailure.CANCELLED)
            }
        }
        checkGranted(result)
        connected = true
    }

    override suspend fun accessToken(): String {
        if (!isConfigured || !connected) throw GmailAuthorizationException(GmailAuthorizationFailure.NOT_AUTHORIZED)
        val result = authorize()
        // Consent is needed again: the grant was removed outside this app.
        if (result.hasResolution()) throw GmailAuthorizationException(GmailAuthorizationFailure.NOT_AUTHORIZED)
        return checkGranted(result)
    }

    override suspend fun disconnect(): Boolean {
        val email = connectedEmail()
        signOut()
        if (email.isNullOrEmpty()) return false
        return try {
            await(
                client.revokeAccess(
                    RevokeAccessRequest.builder()
                        .setAccount(Account(email, GOOGLE_ACCOUNT_TYPE))
                        .setScopes(listOf(Scope(READ_SCOPE)))
                        .build(),
                ),
            )
            true
        } catch (_: Exception) {
            false
        }
    }

    override fun signOut() {
        connected = false
        val token = lastToken ?: return
        lastToken = null
        // Drop Play services' cached token; the result does not change local state.
        runCatching { client.clearToken(ClearTokenRequest.builder().setToken(token).build()) }
    }

    private suspend fun authorize(): AuthorizationResult = try {
        await(client.authorize(request))
    } catch (failure: GmailAuthorizationException) {
        throw failure
    } catch (_: Exception) {
        throw GmailAuthorizationException(GmailAuthorizationFailure.UNAVAILABLE)
    }

    private fun checkGranted(result: AuthorizationResult): String {
        if (result.grantedScopes.none { it == READ_SCOPE }) {
            throw GmailAuthorizationException(GmailAuthorizationFailure.READ_PERMISSION_REQUIRED)
        }
        val token = result.accessToken
            ?: throw GmailAuthorizationException(GmailAuthorizationFailure.NOT_AUTHORIZED)
        lastToken = token
        return token
    }

    private suspend fun <T> await(task: Task<T>): T = suspendCancellableCoroutine { continuation ->
        task.addOnSuccessListener { continuation.resume(it) }
        task.addOnFailureListener { continuation.resumeWithException(it) }
        task.addOnCanceledListener { continuation.cancel() }
    }

    companion object {
        const val READ_SCOPE: String = "https://www.googleapis.com/auth/gmail.readonly"
        const val PREFERENCES: String = "phone-dsh-gmail"
        const val KEY_CONNECTED: String = "connected.v1"
        private const val GOOGLE_ACCOUNT_TYPE: String = "com.google"
    }
}
