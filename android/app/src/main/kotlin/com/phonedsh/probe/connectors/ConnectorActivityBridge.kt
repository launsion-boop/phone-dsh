// phone-dsh — :app: the foreground activity seam for the account connectors.
// SPDX-License-Identifier: MIT
//
// Both connectors need the visible activity for one step each
// (PC-20261119-android-connectors):
//   * Gmail launches Google's consent `PendingIntent` and waits for its result;
//   * GitHub opens the browser, then learns that `MainActivity` resumed with no
//     callback, which is the user dismissing the authorization.
// `MainActivity` attaches itself in `onCreate` (the result launcher must be
// registered before STARTED) and detaches in `onDestroy`.

package com.phonedsh.probe.connectors

import android.app.PendingIntent
import android.content.Intent
import androidx.activity.ComponentActivity
import androidx.activity.result.ActivityResult
import androidx.activity.result.ActivityResultLauncher
import androidx.activity.result.IntentSenderRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.lifecycle.DefaultLifecycleObserver
import androidx.lifecycle.LifecycleOwner
import java.lang.ref.WeakReference
import kotlinx.coroutines.CompletableDeferred

internal object ConnectorActivityBridge {
    private var activity: WeakReference<ComponentActivity>? = null
    private var launcher: ActivityResultLauncher<IntentSenderRequest>? = null
    private var pending: CompletableDeferred<ActivityResult>? = null
    private val resumeListeners = mutableListOf<() -> Unit>()

    /** Called from `MainActivity.onCreate`, on the main thread. */
    fun attach(owner: ComponentActivity) {
        activity = WeakReference(owner)
        launcher = owner.registerForActivityResult(ActivityResultContracts.StartIntentSenderForResult()) { result ->
            pending?.complete(result)
            pending = null
        }
        owner.lifecycle.addObserver(object : DefaultLifecycleObserver {
            override fun onResume(owner: LifecycleOwner) {
                resumeListeners.toList().forEach { it() }
            }
        })
    }

    /**
     * Called from `MainActivity.onDestroy`. On a configuration change the pending
     * consent is kept: the recreated activity registers the same launcher key,
     * and the result registry delivers the user's answer there. Only a real
     * finish cancels it, so it is never left hanging.
     */
    fun detach(owner: ComponentActivity) {
        if (activity?.get() !== owner) return
        activity = null
        launcher = null
        if (owner.isChangingConfigurations) return
        pending?.complete(ActivityResult(android.app.Activity.RESULT_CANCELED, null))
        pending = null
    }

    /** Launches [intent]'s sender and waits for its result; `null` when no activity is attached. */
    suspend fun resolve(intent: PendingIntent): ActivityResult? {
        val launch = launcher ?: return null
        pending?.complete(ActivityResult(android.app.Activity.RESULT_CANCELED, null))
        val deferred = CompletableDeferred<ActivityResult>()
        pending = deferred
        launch.launch(IntentSenderRequest.Builder(intent.intentSender).build())
        return deferred.await()
    }

    /** Starts [intent] from the visible activity; false when there is none or nothing handles it. */
    fun startActivity(intent: Intent): Boolean {
        val host = activity?.get() ?: return false
        return try {
            host.startActivity(intent)
            true
        } catch (_: android.content.ActivityNotFoundException) {
            false
        }
    }

    /**
     * Opens [url] in the default browser. The authorization URL carries the
     * attempt's state and challenge, so it is not offered to whatever app claims
     * github.com links: the intent is pinned to the package that handles a plain
     * https link by default. With no default browser (the resolver is the
     * chooser) the platform chooser is shown, as for any link.
     */
    fun openInBrowser(url: String): Boolean {
        val host = activity?.get() ?: return false
        val intent = Intent(Intent.ACTION_VIEW, android.net.Uri.parse(url)).addCategory(Intent.CATEGORY_BROWSABLE)
        val probe = Intent(Intent.ACTION_VIEW, android.net.Uri.parse("https://example.com/"))
            .addCategory(Intent.CATEGORY_BROWSABLE)
        val browser = host.packageManager
            .resolveActivity(probe, android.content.pm.PackageManager.MATCH_DEFAULT_ONLY)
            ?.activityInfo?.packageName
            ?.takeIf { it != "android" }
        if (browser != null) intent.setPackage(browser)
        return startActivity(intent)
    }

    /** [listener] runs on every `MainActivity` resume until it is removed. Main thread only. */
    fun addResumeListener(listener: () -> Unit) {
        resumeListeners += listener
    }

    fun removeResumeListener(listener: () -> Unit) {
        resumeListeners -= listener
    }
}
