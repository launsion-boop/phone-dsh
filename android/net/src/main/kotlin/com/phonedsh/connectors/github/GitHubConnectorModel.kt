// phone-dsh — :net / com.phonedsh.connectors.github: the connector page model.
// SPDX-License-Identifier: MIT
//
// Ported from `GitHubConnectorModel` in
// `examples/probe-app/PhoneDSHProbe/GitHubConnectorPage.swift`
// (PC-20261119-android-connectors). Same states, epoch guards, legacy-token
// discard, expiry → reconnect, delete-retry and revocation fallback, and the
// same notices. Platform seams (secure store, browser hand-off) are injected.
//
// Threading: every public method launches on [scope], which must be
// single-threaded (the main dispatcher in the app). All mutable state is
// confined to it. Where iOS reads or writes the Keychain synchronously, the
// Android store is suspending, so each read re-checks the epoch afterwards and
// a pending delete blocks connect/restore until its outcome is known.

package com.phonedsh.connectors.github

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch

sealed interface GitHubConnectorState {
    data object Disconnected : GitHubConnectorState
    data object Connecting : GitHubConnectorState
    data class Connected(
        val login: String,
        val repos: List<GitHubRepository>,
        val nextPage: Int?,
        val notice: String?,
    ) : GitHubConnectorState
}

data class GitHubConnectorSnapshot(
    val state: GitHubConnectorState,
    val connectionNotice: String?,
    val loading: Boolean,
    val needsDeleteRetry: Boolean,
    val canRetryRestore: Boolean,
    val isConfigured: Boolean,
    val installationUrl: String?,
    val revocationSettingsUrl: String?,
)

sealed interface GitHubTokenRead {
    data object Absent : GitHubTokenRead
    data class Present(val token: String) : GitHubTokenRead {
        override fun toString(): String = "Present(<redacted>)"
    }
    data object Unreadable : GitHubTokenRead
}

/** The one saved access token (P18). [write] and [delete] throw on failure. */
interface GitHubTokenStore {
    suspend fun read(): GitHubTokenRead
    suspend fun write(token: String)
    suspend fun delete()
}

class GitHubWebAuthorizationException(val cancelled: Boolean) : Exception()

/** Opens [url] and returns the callback URL, or throws [GitHubWebAuthorizationException]. */
fun interface GitHubWebAuthorizer {
    suspend fun authorize(url: String): String
}

class GitHubConnectorModel(
    private val configuration: GitHubOAuthConfiguration?,
    private val api: GitHubConnectorApi,
    private val broker: (GitHubOAuthConfiguration) -> GitHubOAuthBroker,
    private val tokenStore: GitHubTokenStore,
    private val authorizer: GitHubWebAuthorizer,
    private val scope: CoroutineScope,
    private val text: (zh: String, en: String) -> String,
    private val nowMillis: () -> Long = System::currentTimeMillis,
    private val randomBytes: (Int) -> ByteArray = GitHubOAuthSecureRandom::bytes,
) {
    private val snapshots = MutableStateFlow(
        GitHubConnectorSnapshot(
            state = GitHubConnectorState.Disconnected,
            connectionNotice = null,
            loading = false,
            needsDeleteRetry = false,
            canRetryRestore = false,
            isConfigured = configuration != null,
            installationUrl = configuration?.installationUrl,
            revocationSettingsUrl = null,
        ),
    )

    val snapshot: StateFlow<GitHubConnectorSnapshot> = snapshots.asStateFlow()

    private var state: GitHubConnectorState = GitHubConnectorState.Disconnected
        set(value) { field = value; publish() }
    private var connectionNotice: String? = null
        set(value) { field = value; publish() }
    private var loading = false
        set(value) { field = value; publish() }
    private var needsDeleteRetry = false
        set(value) { field = value; publish() }
    private var canRetryRestore = false
        set(value) { field = value; publish() }
    private var revocationFailed = false
        set(value) { field = value; publish() }

    private var epoch = 0L
    private var activeToken: String? = null
    private var expiresAtMillis: Long? = null
    private var connectJob: Job? = null
    private var failedRepositoryLoad: Pair<Int, Boolean>? = null
    private var restoring = false
    private var deleting = false

    private fun publish() {
        snapshots.value = GitHubConnectorSnapshot(
            state = state,
            connectionNotice = connectionNotice,
            loading = loading,
            needsDeleteRetry = needsDeleteRetry,
            canRetryRestore = canRetryRestore,
            isConfigured = configuration != null,
            installationUrl = configuration?.installationUrl,
            revocationSettingsUrl = if (revocationFailed) GitHubOAuthConfiguration.AUTHORIZED_APP_SETTINGS_URL else null,
        )
    }

    private fun nextEpoch(): Long {
        epoch += 1
        return epoch
    }

    // ---- public surface

    fun restore() {
        scope.launch { restoreNow() }
    }

    fun connect() {
        scope.launch { connectNow() }
    }

    /** Stops a session and exchange that have not completed; never changes an established connection. */
    fun cancelAuthorization() {
        scope.launch {
            if (state !is GitHubConnectorState.Connecting) return@launch
            nextEpoch()
            connectJob?.cancel()
            connectJob = null
            activeToken = null
            expiresAtMillis = null
            loading = false
            canRetryRestore = false
            connectionNotice = null
            state = GitHubConnectorState.Disconnected
        }
    }

    fun loadMore() {
        scope.launch {
            val current = state as? GitHubConnectorState.Connected ?: return@launch
            val nextPage = current.nextPage
            if (current.notice != null || nextPage == null || loading) return@launch
            val token = storedToken() ?: return@launch
            val id = nextEpoch()
            loadRepositories(nextPage, append = true, token = token, id = id)
        }
    }

    /** Re-reads the first page after the user changes repositories on GitHub. */
    fun refresh() {
        scope.launch {
            if (state !is GitHubConnectorState.Connected || loading) return@launch
            val token = storedToken() ?: return@launch
            val current = state as? GitHubConnectorState.Connected ?: return@launch
            val id = nextEpoch()
            state = current.copy(notice = null)
            loadRepositories(1, append = false, token = token, id = id)
        }
    }

    fun retry() {
        scope.launch {
            if (state !is GitHubConnectorState.Connected || failedRepositoryLoad == null || loading) return@launch
            val token = storedToken() ?: return@launch
            val request = failedRepositoryLoad ?: return@launch
            val id = nextEpoch()
            loadRepositories(request.first, append = request.second, token = token, id = id)
        }
    }

    /**
     * Clears the local token and results, then asks the broker to revoke the
     * token. A failed revoke leaves the GitHub app-settings link.
     */
    fun disconnect() {
        scope.launch {
            if (state !is GitHubConnectorState.Connected) return@launch
            val token = activeToken
            val id = clearConnection(null)
            revocationFailed = false

            if (token == null) return@launch
            val configuration = configuration
            if (configuration == null) {
                revocationFailed = true
                connectionNotice = revocationFailure
                return@launch
            }
            try {
                broker(configuration).revoke(token)
            } catch (_: Exception) {
                if (epoch != id) return@launch
                revocationFailed = true
                if (connectionNotice == null) connectionNotice = revocationFailure
            }
        }
    }

    fun retryDelete() {
        scope.launch {
            if (!needsDeleteRetry || deleting) return@launch
            deleting = true
            try {
                tokenStore.delete()
                needsDeleteRetry = false
                if (state is GitHubConnectorState.Disconnected && !revocationFailed) connectionNotice = null
            } catch (error: Exception) {
                connectionNotice = deleteFailure
                if (error is CancellationException) throw error
            } finally {
                deleting = false
            }
        }
    }

    // ---- flows

    private suspend fun restoreNow() {
        if (state !is GitHubConnectorState.Disconnected || needsDeleteRetry || deleting || restoring) return
        restoring = true
        val token: String?
        try {
            canRetryRestore = false
            val started = epoch
            val read = readToken()
            if (epoch != started || state !is GitHubConnectorState.Disconnected) return
            val stored = when (read) {
                GitHubTokenRead.Absent -> return
                GitHubTokenRead.Unreadable -> {
                    connectionNotice = readFailure
                    canRetryRestore = true
                    return
                }
                is GitHubTokenRead.Present -> read.token
            }
            if (!GitHubConnectorApi.isValidToken(stored)) {
                // A previous build stored a fine-grained PAT in the same slot.
                // It cannot be used with the app-token path; discard it.
                deleting = true
                try {
                    tokenStore.delete()
                    needsDeleteRetry = false
                    connectionNotice = legacyTokenDiscarded
                } catch (error: Exception) {
                    needsDeleteRetry = true
                    connectionNotice = deleteFailure
                    if (error is CancellationException) throw error
                } finally {
                    deleting = false
                }
                return
            }
            token = if (configuration == null) null else stored
        } finally {
            restoring = false
        }
        if (token != null) authenticate(token, persist = false, expiresAt = null)
    }

    private fun connectNow() {
        if (state !is GitHubConnectorState.Disconnected || needsDeleteRetry || deleting) return
        val configuration = configuration
        if (configuration == null) {
            connectionNotice = unconfiguredNotice
            return
        }

        connectJob?.cancel()
        val id = nextEpoch()
        activeToken = null
        expiresAtMillis = null
        connectionNotice = null
        canRetryRestore = false
        revocationFailed = false
        loading = false
        state = GitHubConnectorState.Connecting

        connectJob = scope.launch { authorize(configuration, id) }
    }

    private suspend fun authorize(configuration: GitHubOAuthConfiguration, id: Long) {
        try {
            val attempt = GitHubOAuthPkce.makeAttempt(randomBytes)
            if (epoch != id) return
            val url = configuration.authorizationUrl(attempt.state, attempt.challenge)
                ?: throw GitHubOAuthException(GitHubOAuthError.INVALID_CONFIGURATION)

            val callbackUrl = authorizer.authorize(url)
            if (epoch != id) return

            when (val callback = GitHubOAuthCallbackValidator.validate(callbackUrl, attempt.state)) {
                GitHubOAuthCallback.AccessDenied -> {
                    state = GitHubConnectorState.Disconnected
                    loading = false
                    connectionNotice = authorizationDenied
                }
                is GitHubOAuthCallback.Code -> {
                    val token = broker(configuration).exchange(callback.code, attempt.verifier)
                    if (epoch != id) return
                    authenticate(token.accessToken, persist = true, expiresAt = expiry(token.expiresIn))
                }
            }
        } catch (error: GitHubWebAuthorizationException) {
            if (epoch != id) return
            state = GitHubConnectorState.Disconnected
            loading = false
            connectionNotice = if (error.cancelled) null else genericFailure
        } catch (error: GitHubOAuthException) {
            if (epoch != id) return
            state = GitHubConnectorState.Disconnected
            loading = false
            connectionNotice = if (error.error == GitHubOAuthError.CANCELLED) null else oauthNotice(error.error)
        } catch (_: CancellationException) {
            if (epoch != id) return
            state = GitHubConnectorState.Disconnected
            loading = false
        } catch (_: Exception) {
            if (epoch != id) return
            state = GitHubConnectorState.Disconnected
            loading = false
            connectionNotice = genericFailure
        }
    }

    private suspend fun authenticate(token: String, persist: Boolean, expiresAt: Long?) {
        if (!GitHubConnectorApi.isValidToken(token)) {
            state = GitHubConnectorState.Disconnected
            connectionNotice = legacyTokenDiscarded
            return
        }

        val id = nextEpoch()
        connectionNotice = null
        canRetryRestore = false
        revocationFailed = false
        loading = false
        state = GitHubConnectorState.Connecting
        try {
            val login = api.account(token).login
            if (epoch != id) return
            if (!currentCoroutineContext().isActive) {
                state = GitHubConnectorState.Disconnected
                return
            }
            if (persist) {
                try {
                    tokenStore.write(token)
                } catch (_: Exception) {
                    if (epoch != id) return
                    state = GitHubConnectorState.Disconnected
                    connectionNotice = saveFailure
                    return
                }
            }
            if (epoch != id) return
            needsDeleteRetry = false
            activeToken = token
            expiresAtMillis = expiresAt
            state = GitHubConnectorState.Connected(login, emptyList(), null, null)
            loadRepositories(1, append = false, token = token, id = id)
        } catch (error: Exception) {
            if (epoch != id) return
            state = GitHubConnectorState.Disconnected
            if (!currentCoroutineContext().isActive || error is CancellationException) return
            if ((error as? GitHubConnectorException)?.error == GitHubConnectorError.UNAUTHORIZED) {
                clearConnection(reconnectNotice)
            } else {
                connectionNotice = connectorNotice(error)
                canRetryRestore = !persist
            }
        }
    }

    private suspend fun loadRepositories(page: Int, append: Boolean, token: String, id: Long) {
        if (epoch != id) return
        val current = state as? GitHubConnectorState.Connected ?: return
        loading = true
        failedRepositoryLoad = null
        try {
            val result = api.repositories(page, token)
            if (epoch != id || state !is GitHubConnectorState.Connected) return
            val repositories = if (append) {
                val existing = current.repos.map { it.id }.toSet()
                current.repos + result.repositories.filter { it.id !in existing }
            } else {
                result.repositories
            }
            state = GitHubConnectorState.Connected(current.login, repositories, result.nextPage, null)
        } catch (error: Exception) {
            if (epoch != id) return
            if (!currentCoroutineContext().isActive || error is CancellationException) {
                activeToken = null
                expiresAtMillis = null
                state = GitHubConnectorState.Disconnected
                return
            }
            if ((error as? GitHubConnectorException)?.error == GitHubConnectorError.UNAUTHORIZED) {
                clearConnection(reconnectNotice)
            } else {
                failedRepositoryLoad = page to append
                state = GitHubConnectorState.Connected(
                    current.login, current.repos, current.nextPage, connectorNotice(error),
                )
            }
        } finally {
            if (epoch == id) loading = false
        }
    }

    private suspend fun clearConnection(notice: String?): Long {
        val id = nextEpoch()
        loading = false
        failedRepositoryLoad = null
        canRetryRestore = false
        activeToken = null
        expiresAtMillis = null
        state = GitHubConnectorState.Disconnected
        connectionNotice = notice
        deleting = true
        try {
            tokenStore.delete()
            needsDeleteRetry = false
        } catch (error: Exception) {
            needsDeleteRetry = true
            connectionNotice = deleteFailure
            if (error is CancellationException) throw error
        } finally {
            deleting = false
        }
        return id
    }

    private suspend fun storedToken(): String? {
        val expiresAt = expiresAtMillis
        if (expiresAt != null && expiresAt <= nowMillis()) {
            clearConnection(reconnectNotice)
            return null
        }
        val started = epoch
        val read = readToken()
        // Superseded while the store was read: the newer operation owns the page.
        if (epoch != started) return null
        if (read is GitHubTokenRead.Present && GitHubConnectorApi.isValidToken(read.token)) return read.token
        // Fall through to the reconnect state; never surface a raw error.
        nextEpoch()
        loading = false
        activeToken = null
        expiresAtMillis = null
        state = GitHubConnectorState.Disconnected
        connectionNotice = reconnectNotice
        return null
    }

    private suspend fun readToken(): GitHubTokenRead = try {
        tokenStore.read()
    } catch (error: CancellationException) {
        throw error
    } catch (_: Exception) {
        GitHubTokenRead.Unreadable
    }

    private fun expiry(expiresIn: Long): Long {
        val now = nowMillis()
        return if (expiresIn > (Long.MAX_VALUE - now) / 1000) Long.MAX_VALUE else now + expiresIn * 1000
    }

    // ---- notices (verbatim from the iOS page)

    private fun connectorNotice(error: Exception): String {
        val connectorError = (error as? GitHubConnectorException)?.error ?: return genericFailure
        return when (connectorError) {
            GitHubConnectorError.UNAUTHORIZED -> reconnectNotice
            GitHubConnectorError.RATE_LIMITED -> text(
                "GitHub 暂时限制了请求频率，请稍后重试。",
                "GitHub is temporarily rate limiting requests. Try again later.",
            )
            GitHubConnectorError.FORBIDDEN -> text(
                "GitHub 拒绝访问。请确认 GitHub App 已获得仓库权限，然后重新连接。",
                "GitHub denied access. Check that the GitHub App can read repositories, then reconnect.",
            )
            GitHubConnectorError.INVALID_RESPONSE -> text(
                "GitHub 返回了无法读取的数据，请稍后重试。",
                "GitHub returned unreadable data. Try again later.",
            )
            GitHubConnectorError.SERVICE_UNAVAILABLE -> genericFailure
        }
    }

    private fun oauthNotice(error: GitHubOAuthError): String = when (error) {
        GitHubOAuthError.INVALID_CONFIGURATION -> unconfiguredNotice
        GitHubOAuthError.INVALID_TOKEN -> invalidAuthorization
        GitHubOAuthError.INVALID_STATE,
        GitHubOAuthError.INVALID_CODE,
        GitHubOAuthError.INVALID_VERIFIER,
        GitHubOAuthError.INVALID_CALLBACK,
        GitHubOAuthError.STATE_MISMATCH,
        GitHubOAuthError.INVALID_REQUEST,
        GitHubOAuthError.AUTHORIZATION_FAILED,
        -> authorizationFailure
        GitHubOAuthError.INVALID_RESPONSE,
        GitHubOAuthError.SERVICE_UNAVAILABLE,
        GitHubOAuthError.RANDOM_UNAVAILABLE,
        -> genericFailure
        GitHubOAuthError.CANCELLED -> genericFailure
    }

    private val genericFailure: String
        get() = text("暂时无法连接 GitHub，请稍后重试。", "Could not reach GitHub. Try again later.")
    private val reconnectNotice: String
        get() = text("GitHub 授权已失效，请重新连接。", "Reconnect GitHub to continue.")
    private val authorizationFailure: String
        get() = text("GitHub 授权未能完成，请重试。", "GitHub authorization could not be completed. Try again.")
    private val invalidAuthorization: String
        get() = text("GitHub 返回了无效的授权，请重试。", "GitHub returned an invalid authorization. Try again.")
    private val authorizationDenied: String
        get() = text("你取消了 GitHub 授权。", "GitHub authorization was cancelled.")
    private val unconfiguredNotice: String
        get() = text("此构建未配置 GitHub OAuth 服务。", "This build is not configured for GitHub OAuth.")
    private val legacyTokenDiscarded: String
        get() = text(
            "已清除旧的 GitHub 令牌，请重新连接。",
            "The old GitHub token was cleared. Reconnect GitHub.",
        )
    private val readFailure: String
        get() = text(
            "无法读取本机保存的 GitHub 令牌，请重试。",
            "Could not read the saved GitHub token on this phone. Try again.",
        )
    private val saveFailure: String
        get() = text(
            "已验证授权，但无法保存到钥匙串。请重试。",
            "The authorization was verified, but it could not be saved to the keychain. Try again.",
        )
    private val deleteFailure: String
        get() = text(
            "已清除本机 GitHub 数据，但未能删除钥匙串里的令牌。请重试。",
            "GitHub data was cleared on this phone, but the keychain token could not be removed. Try again.",
        )
    private val revocationFailure: String
        get() = text(
            "本机已断开 GitHub，但未能撤销服务器上的授权。可在 GitHub 应用设置中撤销。",
            "GitHub was disconnected on this phone, but the server could not revoke the authorization. Revoke it in GitHub app settings.",
        )
}
