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
import com.google.firebase.FirebaseApp
import com.phonedsh.account.TonoAccountState
import com.phonedsh.cloudtasks.HttpUrlConnectionCloudTaskTransport
import com.phonedsh.cloudtasks.CloudTaskPassStatus
import com.phonedsh.cloudtasks.CloudTaskWire
import com.phonedsh.platform.SecureLookup
import com.phonedsh.probe.HostWakeScheduler
import com.phonedsh.probe.SecureStoreTonoAccountStore
import com.phonedsh.probe.bot.AppBotProfileStore
import java.io.File
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
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.runInterruptible
import kotlinx.coroutines.withContext

/** The two facts only the view model has. */
internal interface CloudTaskHostHooks {
    /** Called on the cloud task lane (never the main thread); must not start the engine. */
    fun presence(target: AdmissionTarget): CloudTaskTargetPresence

    /** A pass admitted new records: the existing dispatch entry looks at the journal. */
    fun onAdmitted()

    val inForeground: Boolean get() = false
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
        presence = { target -> hooks?.presence(target) ?: cachedTargetPresence(target) },
        onAdmitted = { hooks?.onAdmitted() },
        appVersion = appVersion(appContext),
        fcmToken = ::readFcmToken,
    )

    val facts: StateFlow<CloudTaskUiFacts> = service.facts
    val isEnabled: Boolean get() = service.isEnabled
    val hasForegroundHost: Boolean get() = hooks?.inForeground == true

    private fun readFcmToken(): String? {
        if (FirebaseApp.getApps(appContext).isEmpty()) return null
        return runBlocking(Dispatchers.IO) {
            (accountHost.secureStore.get(FCM_TOKEN) as? SecureLookup.Found)?.value?.toString(Charsets.UTF_8)
        }
    }

    fun pushTokenRotated(token: String) {
        if (!CloudTaskWire.isFcmToken(token)) return
        lane.execute {
            runCatching {
                if (readFcmToken() != token) {
                    runBlocking(Dispatchers.IO) {
                        accountHost.secureStore.put(FCM_TOKEN, token.toByteArray(Charsets.UTF_8))
                    }
                    service.runPass(dispatch = hasForegroundHost)
                }
            }
        }
    }

    private fun refreshFcmTokenIfEnabled() {
        if (service.isEnabled && service.signedInAccountId() != null) {
            requestFcmToken(appContext, ::pushTokenRotated)
        }
    }

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
                    HostWakeScheduler.get(appContext).setCloudPolling(signedIn && service.isEnabled)
                    if (signedIn) refreshFcmTokenIfEnabled()
                }
            }
        }
    }

    /** Activity start / foreground return. Coalesced: one queued pass is enough. */
    fun appBecameActive() {
        if (!passQueued.compareAndSet(false, true)) return
        lane.execute {
            passQueued.set(false)
            refreshFcmTokenIfEnabled()
            runCatching { service.runPass() }.onSuccess { report ->
                if (report.status == CloudTaskPassStatus.COMPLETED) {
                    lastSuccessfulWakePullMs = android.os.SystemClock.elapsedRealtime()
                }
            }
        }
    }

    /** One owned pass, with no engine or dispatch side effects for a background worker. */
    suspend fun pullForWake(dispatch: Boolean) = runInterruptible(Dispatchers.IO) {
        service.runPass(dispatch)
    }

    @Volatile private var lastSuccessfulWakePullMs: Long? = null

    suspend fun pullForReadySweep(): Boolean {
        val now = android.os.SystemClock.elapsedRealtime()
        if (lastSuccessfulWakePullMs?.let { now - it < 30_000 } == true) return false
        val report = pullForWake(dispatch = false)
        if (report.status == CloudTaskPassStatus.COMPLETED) {
            lastSuccessfulWakePullMs = android.os.SystemClock.elapsedRealtime()
        }
        return report.admittedIds.isNotEmpty()
    }

    /** The settings switch. */
    fun setEnabled(value: Boolean) {
        service.markBusy()
        lane.execute {
            runCatching { service.setEnabled(value) }
            HostWakeScheduler.get(appContext).setCloudPolling(
                service.isEnabled && service.signedInAccountId() != null,
            )
            if (value) refreshFcmTokenIfEnabled()
        }
    }

    /** A cold worker can authenticate a persisted Bot. Unknown sessions stay in the cloud. */
    private fun cachedTargetPresence(target: AdmissionTarget): CloudTaskTargetPresence {
        if (target !is AdmissionTarget.Bot) return CloudTaskTargetPresence.UNKNOWN
        val profiles = AppBotProfileStore(File(appContext.filesDir, "PhoneDSHBot"), System::currentTimeMillis)
        val present = runCatching { profiles.read().bots.any { it.id == target.botId } }.getOrDefault(false)
        return if (present) CloudTaskTargetPresence.PRESENT else CloudTaskTargetPresence.UNKNOWN
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
        private const val FCM_TOKEN = "cloud-tasks.fcm-token"
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
