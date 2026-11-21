// phone-dsh — :net / com.phonedsh.connectors.gmail: the Gmail page state.
// SPDX-License-Identifier: MIT
//
// Kotlin port of `GmailMailbox` in the iOS baseline
// `examples/probe-app/PhoneDSHProbe/GmailConnectorPage.swift`
// (PC-20261111-ios-gmail; Android mechanics in PC-20261119-android-connectors).
// The authorization surface (Google Identity Services on Android, Google
// Sign-In on iOS) sits behind [GmailAuthorizer]. Stale searches are dropped by
// request id, a read is dropped when the connection changed, and cancellation
// never replaces the current account or results. Nothing here logs a token,
// an address or mail content.

package com.phonedsh.connectors.gmail

import kotlin.coroutines.cancellation.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch

sealed interface GmailAccount {
    data object Unconfigured : GmailAccount
    data object Disconnected : GmailAccount
    data object Connecting : GmailAccount
    data class Connected(val email: String, val connection: Long) : GmailAccount
    data object Disconnecting : GmailAccount
    data object Reconnect : GmailAccount
}

data class GmailMailboxSnapshot(
    val account: GmailAccount,
    val messages: List<GmailSummary>,
    val nextPage: String?,
    val loading: Boolean,
    val notice: String?,
    val query: String,
)

enum class GmailAuthorizationFailure { NOT_AUTHORIZED, READ_PERMISSION_REQUIRED, CANCELLED, INVALID_GRANT, UNAVAILABLE }

class GmailAuthorizationException(val failure: GmailAuthorizationFailure) : Exception(failure.name)

interface GmailAuthorizer {
    val isConfigured: Boolean

    /** Silent; false = no previous connection. */
    suspend fun restore(): Boolean

    /** Interactive; throws [GmailAuthorizationException]. */
    suspend fun connect()

    /** Throws [GmailAuthorizationException]. */
    suspend fun accessToken(): String

    /** True when the grant was revoked. */
    suspend fun disconnect(): Boolean

    fun signOut()
}

/**
 * Mutators launch on [scope], which must be single-threaded (the main
 * dispatcher in the app). [setQuery] is applied immediately so a text field
 * stays in step; every snapshot write is an atomic [MutableStateFlow.update].
 */
class GmailMailbox(
    private val authorizer: GmailAuthorizer,
    private val api: GmailApi,
    private val scope: CoroutineScope,
    private val text: (zh: String, en: String) -> String,
) {
    private val state = MutableStateFlow(
        GmailMailboxSnapshot(
            account = if (authorizer.isConfigured) GmailAccount.Disconnected else GmailAccount.Unconfigured,
            messages = emptyList(),
            nextPage = null,
            loading = false,
            notice = null,
            query = "",
        ),
    )
    val snapshot: StateFlow<GmailMailboxSnapshot> = state.asStateFlow()

    private var activeQuery = ""
    private var requestId = 0L
    private var connections = 0L

    private val account: GmailAccount get() = state.value.account

    fun setQuery(query: String) = state.update { it.copy(query = query) }

    fun restore() {
        scope.launch {
            if (account != GmailAccount.Disconnected) return@launch
            state.update { it.copy(account = GmailAccount.Connecting, notice = null) }
            try {
                if (!authorizer.restore()) {
                    state.update { it.copy(account = GmailAccount.Disconnected) }
                    return@launch
                }
                checkAccount()
            } catch (cancel: CancellationException) {
                throw cancel
            } catch (error: Throwable) {
                failConnection(error)
            }
        }
    }

    fun connect() {
        scope.launch {
            when (account) {
                GmailAccount.Disconnected, GmailAccount.Reconnect -> Unit
                else -> return@launch
            }
            state.update { it.copy(account = GmailAccount.Connecting, notice = null) }
            try {
                authorizer.connect()
                checkAccount()
            } catch (cancel: CancellationException) {
                throw cancel
            } catch (error: Throwable) {
                failConnection(error)
            }
        }
    }

    private suspend fun checkAccount() {
        val token = authorizer.accessToken()
        val email = api.accountEmail(token)
        val connection = ++connections
        state.update { it.copy(account = GmailAccount.Connected(email, connection)) }
        performSearch(append = false)
    }

    fun search(append: Boolean = false) {
        scope.launch { performSearch(append) }
    }

    private suspend fun performSearch(append: Boolean) {
        if (account !is GmailAccount.Connected) return
        val pageToken: String?
        if (append) {
            val current = state.value
            pageToken = current.nextPage ?: return
            if (current.loading) return
        } else {
            activeQuery = state.value.query.trim()
            pageToken = null
            clearSearch()
        }
        val id = ++requestId
        state.update { it.copy(loading = true, notice = null) }
        try {
            val token = authorizer.accessToken()
            if (id != requestId) return
            val page = api.search(activeQuery, pageToken, token)
            if (id != requestId) return
            state.update { current ->
                val existing = current.messages.mapTo(HashSet()) { it.id }
                current.copy(
                    messages = current.messages + page.messages.filter { it.id !in existing },
                    nextPage = page.nextPageToken,
                )
            }
        } catch (cancel: CancellationException) {
            throw cancel
        } catch (error: Throwable) {
            if (id != requestId || !currentCoroutineContext().isActive) return
            if (!handleAuthorizationError(error)) {
                val message = readErrorMessage(error)
                state.update { it.copy(notice = message) }
            }
        } finally {
            if (requestId == id) state.update { it.copy(loading = false) }
        }
    }

    /**
     * Reads one message in the caller's coroutine. Throws
     * [CancellationException] when the connection changed meanwhile.
     */
    suspend fun read(id: String): GmailMessage {
        val connection = (account as? GmailAccount.Connected)?.connection
            ?: throw GmailAuthorizationException(GmailAuthorizationFailure.NOT_AUTHORIZED)
        try {
            val token = authorizer.accessToken()
            if (!isCurrent(connection)) throw CancellationException("Gmail connection changed")
            val message = api.message(id, token)
            if (!isCurrent(connection)) throw CancellationException("Gmail connection changed")
            if (!currentCoroutineContext().isActive) throw CancellationException("read cancelled")
            return message
        } catch (error: Throwable) {
            if (isCurrent(connection) && currentCoroutineContext().isActive) {
                handleAuthorizationError(error)
            }
            throw error
        }
    }

    fun disconnect() {
        scope.launch {
            if (account !is GmailAccount.Connected) return@launch
            state.update { it.copy(account = GmailAccount.Disconnecting) }
            clearSearch()
            state.update { it.copy(query = "", notice = null) }
            val revoked = try {
                authorizer.disconnect()
            } catch (cancel: CancellationException) {
                throw cancel
            } catch (_: Throwable) {
                false
            }
            val notice = if (revoked) {
                null
            } else {
                text(
                    "已在此手机断开。若要撤销 Google 授权，请到 Google 账号的第三方连接页面移除 Phone DSH。",
                    "Disconnected on this phone. To revoke access, remove Phone DSH in your Google Account connections.",
                )
            }
            state.update { it.copy(account = GmailAccount.Disconnected, notice = notice ?: it.notice) }
        }
    }

    fun readErrorMessage(error: Throwable): String {
        if (needsAuthorization(error)) {
            return text("Gmail 授权已失效，请重新连接。", "Reconnect Gmail to continue.")
        }
        return when ((error as? GmailException)?.error) {
            GmailError.FORBIDDEN -> text(
                "Google 拒绝了这次 Gmail 请求。请检查账号权限、Gmail API 配额和配置。",
                "Google denied this Gmail request. Check account permissions, Gmail API quota and setup.",
            )
            GmailError.NOT_FOUND -> text("找不到这封邮件。", "This email is no longer available.")
            else -> text("暂时无法读取 Gmail，请稍后重试。", "Could not read Gmail. Try again.")
        }
    }

    private fun failConnection(error: Throwable) {
        if (authorizationFailure(error) == GmailAuthorizationFailure.CANCELLED) {
            state.update { it.copy(account = GmailAccount.Disconnected) }
        } else if (!handleAuthorizationError(error)) {
            val message = readErrorMessage(error)
            state.update { it.copy(account = GmailAccount.Disconnected, notice = message) }
        }
    }

    private fun handleAuthorizationError(error: Throwable): Boolean {
        if (authorizationFailure(error) == GmailAuthorizationFailure.READ_PERMISSION_REQUIRED) {
            clearSearch()
            val notice = text(
                "请点击“连接 Google 账号”，并在 Google 页面勾选 Gmail 读取权限。",
                "Tap Connect Google account and select Gmail read access on the Google page.",
            )
            state.update { it.copy(account = GmailAccount.Reconnect, notice = notice) }
            return true
        }
        if (needsAuthorization(error)) {
            loseAuthorization()
            return true
        }
        return false
    }

    private fun isCurrent(connection: Long): Boolean =
        (account as? GmailAccount.Connected)?.connection == connection

    private fun needsAuthorization(error: Throwable): Boolean {
        val failure = authorizationFailure(error)
        return failure == GmailAuthorizationFailure.NOT_AUTHORIZED ||
            failure == GmailAuthorizationFailure.INVALID_GRANT ||
            (error as? GmailException)?.error == GmailError.UNAUTHORIZED
    }

    private fun loseAuthorization() {
        authorizer.signOut()
        clearSearch()
        val notice = text("Gmail 授权已失效，请重新连接。", "Reconnect Gmail to continue.")
        state.update { it.copy(account = GmailAccount.Reconnect, notice = notice) }
    }

    private fun clearSearch() {
        requestId++
        state.update { it.copy(loading = false, messages = emptyList(), nextPage = null) }
    }

    private fun authorizationFailure(error: Throwable): GmailAuthorizationFailure? =
        (error as? GmailAuthorizationException)?.failure
}
