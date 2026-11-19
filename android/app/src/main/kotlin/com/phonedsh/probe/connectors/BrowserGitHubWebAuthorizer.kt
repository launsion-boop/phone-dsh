// phone-dsh — :app: the Android GitHub authorization surface.
// SPDX-License-Identifier: MIT
//
// iOS presents `ASWebAuthenticationSession`; Android opens the authorization URL
// in the browser with `ACTION_VIEW` and waits for `GitHubOAuthCallbackActivity`
// to deliver `phonedsh-github://oauth/callback` (PC-20261119-android-connectors).
// One attempt at a time, as on iOS: a new start cancels the previous one.
//
// Cancellation: the browser has no "cancelled" result. `MainActivity` resuming
// while an attempt waits, with no callback delivered first, is the user coming
// back without authorizing. The callback activity delivers before it brings
// `MainActivity` forward, so a real callback always wins that race.

package com.phonedsh.probe.connectors

import android.os.Handler
import android.os.Looper
import com.phonedsh.connectors.github.GitHubWebAuthorizationException
import com.phonedsh.connectors.github.GitHubWebAuthorizer
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CancellationException

internal object BrowserGitHubWebAuthorizer : GitHubWebAuthorizer {
    private val main = Handler(Looper.getMainLooper())
    private var pending: CompletableDeferred<String>? = null
    private var leftApp = false
    private val onResume: () -> Unit = {
        // Only a resume after the browser was opened counts as the user coming back.
        if (leftApp) {
            pending?.completeExceptionally(GitHubWebAuthorizationException(cancelled = true))
        }
    }

    override suspend fun authorize(url: String): String {
        cancelPending()
        val deferred = CompletableDeferred<String>()
        pending = deferred
        leftApp = false
        ConnectorActivityBridge.addResumeListener(onResume)
        try {
            val opened = ConnectorActivityBridge.openInBrowser(url)
            if (!opened) throw GitHubWebAuthorizationException(cancelled = false)
            leftApp = true
            return deferred.await()
        } catch (cancelled: CancellationException) {
            throw cancelled
        } finally {
            ConnectorActivityBridge.removeResumeListener(onResume)
            if (pending === deferred) pending = null
        }
    }

    /** Called by the callback activity with the raw callback URI. */
    fun deliver(uri: String) {
        main.post {
            val waiting = pending
            if (waiting == null) {
                // No attempt in this process (for example after process death):
                // nothing to complete. The page stays on its connect button.
                return@post
            }
            waiting.complete(uri)
        }
    }

    private fun cancelPending() {
        pending?.completeExceptionally(GitHubWebAuthorizationException(cancelled = true))
        pending = null
    }
}
