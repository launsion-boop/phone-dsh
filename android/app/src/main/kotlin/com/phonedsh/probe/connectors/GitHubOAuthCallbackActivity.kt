// phone-dsh — :app: receives the fixed GitHub OAuth callback.
// SPDX-License-Identifier: MIT
//
// `phonedsh-github://oauth/callback` (spec/v1/github-oauth.md) lands here from
// the browser. This activity has no UI: it hands the URI to the one pending
// attempt in this process, brings `MainActivity` back, and finishes. It never
// reads, logs or keeps the query; `GitHubOAuthCallbackValidator` decides whether
// the URI is acceptable. A callback with no pending attempt is dropped
// (PC-20261119-android-connectors rev 2).

package com.phonedsh.probe.connectors

import android.app.Activity
import android.content.Intent
import android.os.Bundle
import com.phonedsh.probe.MainActivity

class GitHubOAuthCallbackActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        intent?.dataString?.let(BrowserGitHubWebAuthorizer::deliver)
        // SINGLE_TOP + CLEAR_TOP returns to the existing MainActivity without
        // recreating it; NEW_TASK because the browser started this activity.
        startActivity(
            Intent(this, MainActivity::class.java).addFlags(
                Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP,
            ),
        )
        finish()
    }
}
