// phone-dsh — :app: the process-owned GitHub connector (发现 › GitHub).
// SPDX-License-Identifier: MIT
//
// Composition root for `com.phonedsh.connectors.github`, one per process like
// iOS `GitHubConnectorModel.shared` (spec/v1/github-oauth.md,
// PC-20261119-android-connectors):
//   * configuration from BuildConfig, validated by `GitHubOAuthConfiguration`;
//   * the one access token in `AndroidSecureStore` under
//     `github.connector.access-token` (AndroidKeyStore AES-GCM, no backup);
//   * the browser + callback activity as the authorization surface.
// The page sees login and repository metadata only. Nothing here logs.

package com.phonedsh.probe.connectors

import android.content.Context
import com.phonedsh.connectors.github.GitHubConnectorApi
import com.phonedsh.connectors.github.GitHubConnectorModel
import com.phonedsh.connectors.github.GitHubConnectorSnapshot
import com.phonedsh.connectors.github.GitHubConnectorState
import com.phonedsh.connectors.github.GitHubOAuthBroker
import com.phonedsh.connectors.github.GitHubOAuthConfiguration
import com.phonedsh.connectors.github.GitHubTokenRead
import com.phonedsh.connectors.github.GitHubTokenStore
import com.phonedsh.platform.SecureLookup
import com.phonedsh.platform.SecureStore
import com.phonedsh.platform.android.AndroidSecureStore
import com.phonedsh.probe.BuildConfig
import com.phonedsh.ui.page.GitHubConnectorAction
import com.phonedsh.ui.page.GitHubConnectorFacts
import com.phonedsh.ui.page.GitHubConnectorPhase
import com.phonedsh.ui.page.GitHubRepositoryRow
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.withContext

/** The one secure-store item holding the GitHub App user access token. */
internal class SecureStoreGitHubTokenStore(private val store: SecureStore) : GitHubTokenStore {
    override suspend fun read(): GitHubTokenRead = withContext(Dispatchers.IO) {
        when (val lookup = store.get(KEY)) {
            is SecureLookup.Found -> GitHubTokenRead.Present(String(lookup.value, Charsets.UTF_8))
            SecureLookup.Absent -> GitHubTokenRead.Absent
            // Unreadable is not absent: the page offers 重试, never a silent reset.
            is SecureLookup.Unreadable -> GitHubTokenRead.Unreadable
        }
    }

    override suspend fun write(token: String) = withContext(Dispatchers.IO) {
        store.put(KEY, token.toByteArray(Charsets.UTF_8))
    }

    override suspend fun delete() = withContext(Dispatchers.IO) { store.delete(KEY) }

    companion object {
        const val KEY: String = "github.connector.access-token"
    }
}

internal class GitHubConnectorHost private constructor(context: Context) {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)

    private val model = GitHubConnectorModel(
        configuration = GitHubOAuthConfiguration.create(
            BuildConfig.PDSH_GITHUB_OAUTH_ORIGIN,
            BuildConfig.PDSH_GITHUB_OAUTH_CLIENT_ID,
            BuildConfig.PDSH_GITHUB_APP_SLUG,
        ),
        api = GitHubConnectorApi(),
        broker = { configuration -> GitHubOAuthBroker(configuration) },
        tokenStore = SecureStoreGitHubTokenStore(AndroidSecureStore(context.applicationContext)),
        authorizer = BrowserGitHubWebAuthorizer,
        scope = scope,
        text = { zh, en -> GmailConnectorHost.text(zh, en) },
    )

    val facts: StateFlow<GitHubConnectorFacts> = model.snapshot
        .map(::project)
        .stateIn(scope, SharingStarted.Eagerly, project(model.snapshot.value))

    fun handle(action: GitHubConnectorAction) {
        when (action) {
            GitHubConnectorAction.APPEARED -> model.restore()
            GitHubConnectorAction.DISAPPEARED -> model.cancelAuthorization()
            GitHubConnectorAction.CONNECT -> model.connect()
            GitHubConnectorAction.DISCONNECT -> model.disconnect()
            GitHubConnectorAction.REFRESH -> model.refresh()
            GitHubConnectorAction.LOAD_MORE -> model.loadMore()
            GitHubConnectorAction.RETRY_REPOSITORIES -> model.retry()
            GitHubConnectorAction.RETRY_RESTORE -> model.restore()
            GitHubConnectorAction.RETRY_DELETE -> model.retryDelete()
        }
    }

    private fun project(snapshot: GitHubConnectorSnapshot): GitHubConnectorFacts {
        val connected = snapshot.state as? GitHubConnectorState.Connected
        return GitHubConnectorFacts(
            configured = snapshot.isConfigured,
            phase = when (snapshot.state) {
                GitHubConnectorState.Disconnected -> GitHubConnectorPhase.DISCONNECTED
                GitHubConnectorState.Connecting -> GitHubConnectorPhase.CONNECTING
                is GitHubConnectorState.Connected -> GitHubConnectorPhase.CONNECTED
            },
            login = connected?.login,
            repositories = connected?.repos.orEmpty().map { GitHubRepositoryRow(it.id, it.name, it.fullName, it.htmlUrl) },
            hasNextPage = connected?.nextPage != null,
            repositoryNotice = connected?.notice,
            connectionNotice = snapshot.connectionNotice,
            canRetryRestore = snapshot.canRetryRestore,
            loading = snapshot.loading,
            needsDeleteRetry = snapshot.needsDeleteRetry,
            installationUrl = snapshot.installationUrl,
            revocationSettingsUrl = snapshot.revocationSettingsUrl,
        )
    }

    companion object {
        @Volatile
        private var instance: GitHubConnectorHost? = null

        fun get(context: Context): GitHubConnectorHost =
            instance ?: synchronized(this) {
                instance ?: GitHubConnectorHost(context.applicationContext).also { instance = it }
            }
    }
}
