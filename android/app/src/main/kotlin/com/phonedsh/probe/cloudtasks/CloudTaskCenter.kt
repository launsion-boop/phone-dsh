// SPDX-License-Identifier: MIT
// phone-dsh — :app: the process-owned phone task queue (Android composition).
//
// One instance per process, created by the Activity next to `TonoAccountHost`
// and without the engine. It owns the lane every blocking call runs on, follows
// the account state, and takes two facts from the view model once that exists:
// what the app knows about a target, and the dispatch entry to nudge after an
// admission. Before the view model attaches, every target is "cannot tell", so
// nothing is admitted and nothing is acked.
package com.phonedsh.probe.cloudtasks

import android.content.Context
import com.phonedsh.account.TonoAccountState
import com.phonedsh.cloudtasks.HttpUrlConnectionCloudTaskTransport
import com.phonedsh.probe.SecureStoreTonoAccountStore
import com.phonedsh.probe.SharedPreferenceFile
import com.phonedsh.probe.TonoAccountHost
import com.phonedsh.probe.admission.AdmissionTarget
import com.phonedsh.probe.admission.ProcessAdmissionJournal
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/** The two facts only the view model has. */
internal interface CloudTaskHostHooks {
    /** Called on the cloud task lane (never the main thread); must not start the engine. */
    fun presence(target: AdmissionTarget): CloudTaskTargetPresence

    /** A pass admitted new records: the existing dispatch entry looks at the journal. */
    fun onAdmitted()
}

internal class CloudTaskCenter private constructor(context: Context) {
    private val appContext = context.applicationContext
    private val accountHost = TonoAccountHost.get(appContext)

    /** Every blocking call (network, key store, journal) runs here, one at a time. */
    private val lane: ExecutorService = Executors.newSingleThreadExecutor { runnable ->
        Thread(runnable, "pdsh-cloud-tasks").apply { isDaemon = true }
    }
    private val passQueued = AtomicBoolean(false)

    private val service = CloudTaskService(
        transport = HttpUrlConnectionCloudTaskTransport(),
        tokens = accountHost.session,
        preferences = PreferenceFileCloudTaskPreferences(SharedPreferenceFile(appContext)),
        keys = SecureStoreCloudTaskKeyStore(accountHost.secureStore),
        journal = { ProcessAdmissionJournal.get(appContext.filesDir) },
        account = TonoCloudTaskAccountReader(
            loadRecord = SecureStoreTonoAccountStore(accountHost.secureStore)::load,
            sessionSignedIn = { accountHost.session.state is TonoAccountState.SignedIn },
        ),
        presence = { target -> hooks?.presence(target) ?: CloudTaskTargetPresence.UNKNOWN },
        onAdmitted = { hooks?.onAdmitted() },
        appVersion = appVersion(appContext),
    )

    val facts: StateFlow<CloudTaskUiFacts> = service.facts

    init {
        // Follows the account: a sign-in runs a pass; a sign-out (the user's, or one
        // the account service forced) cancels that account's admitted records.
        CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate).launch {
            val states = withContext(Dispatchers.IO) { accountHost.session.stateFlow }
            var previous: Boolean? = null
            states.collect { state ->
                val signedIn = state is TonoAccountState.SignedIn
                val before = previous
                previous = signedIn
                lane.execute {
                    runCatching {
                        when {
                            // Also at launch: an account that ended while the app was not running.
                            before == null -> service.reconcileAccount()
                            before == signedIn -> Unit
                            signedIn -> service.accountDidSignIn()
                            else -> service.accountDidSignOut()
                        }
                    }
                }
            }
        }
    }

    /** Activity start / foreground return. Coalesced: one queued pass is enough. */
    fun appBecameActive() {
        if (!passQueued.compareAndSet(false, true)) return
        lane.execute {
            passQueued.set(false)
            runCatching { service.runPass() }
        }
    }

    /** The settings switch. */
    fun setEnabled(value: Boolean) {
        service.markBusy()
        lane.execute { runCatching { service.setEnabled(value) } }
    }

    /**
     * Blocking; call it off the main thread, before the session is cleared.
     * Waits for a running pass, then sends the DELETE with the still-valid token.
     */
    fun accountWillSignOut() {
        runCatching { service.accountWillSignOut() }
    }

    /** Blocking; call it after the session is cleared. */
    fun accountDidSignOut() {
        runCatching { service.accountDidSignOut() }
    }

    /** For the admission dispatcher: the id after `account:` of the account signed in now. */
    fun signedInAccountId(): String? = runCatching { service.signedInAccountId() }.getOrNull()

    companion object {
        @Volatile
        private var instance: CloudTaskCenter? = null

        /** Process-wide and independent of [instance]: the view model may exist first. */
        @Volatile
        private var hooks: CloudTaskHostHooks? = null

        fun attach(host: CloudTaskHostHooks) {
            hooks = host
        }

        fun detach(host: CloudTaskHostHooks) {
            if (hooks === host) hooks = null
        }

        fun get(context: Context): CloudTaskCenter =
            instance ?: synchronized(this) {
                instance ?: CloudTaskCenter(context.applicationContext).also { instance = it }
            }

        /** The installed center, or `null` before the composition root ran. */
        fun active(): CloudTaskCenter? = instance

        private fun appVersion(context: Context): String = try {
            context.packageManager.getPackageInfo(context.packageName, 0).versionName
                ?.takeIf { it.length in 1..32 } ?: "0"
        } catch (_: Exception) {
            "0"
        }
    }
}
