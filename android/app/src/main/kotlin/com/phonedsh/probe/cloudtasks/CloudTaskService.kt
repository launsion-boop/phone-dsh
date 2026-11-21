// SPDX-License-Identifier: MIT
// phone-dsh — :app: the app's owner of the phone task queue (iOS: `CloudTaskCenter`).
//
// spec/v1/cloud-tasks.md §7. One `CloudTaskCoordinator` for the app, built
// without the engine: it pulls tasks left by the user's other signed-in devices,
// writes them into the external admission journal and acknowledges them. It has
// no timer and never polls: a pass runs when the Activity starts (foreground
// return), after sign-in and when the switch is turned on. There is no push on
// Android in v1; the registration always carries `"push": null`. It never boots
// the engine: admitted records go to the existing dispatch entry
// (`ChatSendQueue.onAdmission`), which keeps its own §10.1 eligibility.
//
// Every method here blocks (network, journal, key store): callers are off the
// main thread. `CloudTaskCenter` is the Android composition and its one lane.
package com.phonedsh.probe.cloudtasks

import com.phonedsh.account.TonoAccessTokenSource
import com.phonedsh.cloudtasks.CloudTaskClient
import com.phonedsh.cloudtasks.CloudTaskCoordinator
import com.phonedsh.cloudtasks.CloudTaskKeyStore
import com.phonedsh.cloudtasks.CloudTaskPassReport
import com.phonedsh.cloudtasks.CloudTaskPassStatus
import com.phonedsh.cloudtasks.CloudTaskPreferences
import com.phonedsh.cloudtasks.CloudTaskReply
import com.phonedsh.cloudtasks.CloudTaskTransport
import com.phonedsh.probe.admission.AdmissionRecord
import com.phonedsh.probe.admission.AdmissionTarget
import com.phonedsh.probe.admission.ExternalAdmissionJournal
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update

/** What the 云端任务 section shows. */
internal data class CloudTaskUiFacts(
    val enabled: Boolean = false,
    val status: String = CloudTaskStatusText.OFF,
    val busy: Boolean = false,
)

/** The settings row's status line, in plain words (iOS `CloudTaskStatusText`; Android has no push). */
internal object CloudTaskStatusText {
    const val OFF: String = "未开启"
    const val ON: String = "已开启"
    const val ON_NOT_CHECKED: String = "已开启，回到前台时检查新任务"
    const val SIGNED_OUT: String = "未登录：登录 Tono 账号后才会接收任务"
    const val UNAVAILABLE: String = "暂不可用：云端还没有开放这项服务"
    const val DEVICE_LIMIT: String = "设备数已满：这个账号已登记 8 台设备，请先在其他设备上关闭"
    const val STORE_UNAVAILABLE: String = "暂不可用：手机解锁后再试"
    const val FAILED: String = "暂时连不上云端，下次回到前台时重试"
    const val TURNED_OFF_PENDING: String = "已关闭；云端的登记会在下次联网时删除"

    /** [report] is the last finished pass, or null when none ran since the state changed. */
    fun describe(enabled: Boolean, signedIn: Boolean, report: CloudTaskPassReport?): String {
        if (!enabled) return OFF
        if (!signedIn) return SIGNED_OUT
        return when (report?.status) {
            null, CloudTaskPassStatus.BUSY -> ON_NOT_CHECKED
            CloudTaskPassStatus.COMPLETED -> ON
            CloudTaskPassStatus.DISABLED -> OFF
            CloudTaskPassStatus.NO_CREDENTIAL -> SIGNED_OUT
            CloudTaskPassStatus.UNAVAILABLE -> UNAVAILABLE
            CloudTaskPassStatus.KEY_STORE_UNAVAILABLE -> STORE_UNAVAILABLE
            CloudTaskPassStatus.REFUSED -> if (report.refusedCode == "device_limit") DEVICE_LIMIT else FAILED
            CloudTaskPassStatus.UNREACHABLE,
            CloudTaskPassStatus.PROTOCOL_ERROR,
            CloudTaskPassStatus.NO_DEVICE_ID,
            -> FAILED
        }
    }

    /** What the cloud did when the switch was turned off. */
    fun describeTurnedOff(reply: CloudTaskReply<Unit>): String = when (reply) {
        is CloudTaskReply.Ok, CloudTaskReply.NoCredential -> OFF
        else -> TURNED_OFF_PENDING
    }
}

internal class CloudTaskService(
    transport: CloudTaskTransport,
    tokens: TonoAccessTokenSource,
    preferences: CloudTaskPreferences,
    keys: CloudTaskKeyStore,
    journal: () -> ExternalAdmissionJournal?,
    private val account: () -> CloudTaskAccount,
    presence: (AdmissionTarget) -> CloudTaskTargetPresence,
    /** Called after a pass that admitted at least one new record; must not start the engine. */
    private val onAdmitted: () -> Unit,
    /** `app_version` of the registration, 1–32 characters. */
    appVersion: String,
    clock: () -> Long = System::currentTimeMillis,
    sleepSeconds: (Long) -> Unit = { seconds -> Thread.sleep(seconds * 1000) },
) {
    val bridge = CloudTaskAdmissionBridge(journal, account, presence)

    private val coordinator = CloudTaskCoordinator(
        client = CloudTaskClient(transport, tokens, sleepSeconds),
        preferences = preferences,
        keys = keys,
        targets = bridge,
        admitter = bridge,
        terminals = bridge,
        appVersion = appVersion,
        clock = clock,
    )

    /** The switch was turned off but the cloud did not confirm the DELETE. In memory only. */
    @Volatile
    private var deletePending = false

    private val state = MutableStateFlow(CloudTaskUiFacts(enabled = coordinator.isEnabled))
    val facts: StateFlow<CloudTaskUiFacts> = state.asStateFlow()

    init {
        publish(null)
    }

    val isEnabled: Boolean get() = coordinator.isEnabled

    /** The id after `account:` of the account signed in now, or null (signed out, or cannot tell). */
    fun signedInAccountId(): String? = (account() as? CloudTaskAccount.SignedIn)?.userId

    /**
     * One pull → admit → ack pass (Activity start, after sign-in, switch on).
     * Sends nothing while the feature is off or no account is signed in.
     */
    fun runPass(dispatch: Boolean = true): CloudTaskPassReport {
        if (!coordinator.isEnabled) {
            retryPendingDelete()
            return CloudTaskPassReport(CloudTaskPassStatus.DISABLED)
        }
        if (account() == CloudTaskAccount.SignedOut) {
            publish(null)
            return CloudTaskPassReport(CloudTaskPassStatus.NO_CREDENTIAL)
        }
        val report = coordinator.runPass()
        // Admitted records go to the existing dispatch entry; it decides when they run.
        if (dispatch && report.admittedIds.isNotEmpty()) runCatching(onAdmitted)
        // A running pass publishes its own result.
        if (report.status != CloudTaskPassStatus.BUSY) publish(report)
        return report
    }

    /** The settings switch. On: store the flag, then one pass. Off: store the flag, then DELETE. */
    fun setEnabled(value: Boolean) {
        state.update { it.copy(busy = true) }
        try {
            if (value) {
                deletePending = false
                coordinator.enable()
                state.update { it.copy(enabled = true) }
                runPass()
            } else {
                val reply = coordinator.disable()
                deletePending = reply !is CloudTaskReply.Ok && reply != CloudTaskReply.NoCredential
                state.update { it.copy(enabled = false, status = CloudTaskStatusText.describeTurnedOff(reply)) }
            }
        } finally {
            state.update { it.copy(enabled = coordinator.isEnabled, busy = false) }
        }
    }

    /** Shows the switch as busy before [setEnabled] reaches its lane. */
    fun markBusy() = state.update { it.copy(busy = true) }

    /**
     * Before the account signs out, while its token still works: the cloud
     * forgets this phone (§2). Call [accountDidSignOut] after the session is cleared.
     */
    fun accountWillSignOut() {
        if (!coordinator.isEnabled && !deletePending) return
        coordinator.deleteRegistration()
        // The token is about to go; a DELETE that did not land cannot be repeated for this account.
        deletePending = false
    }

    /** The session is cleared: `admitted` records of the account that left become `cancelled`. */
    fun accountDidSignOut(): List<AdmissionRecord> {
        val cancelled = bridge.cancelAdmissionsOfSignedOutAccounts()
        publish(null)
        return cancelled
    }

    /** A sign-in: records of any other account are cancelled, then one pass. */
    fun accountDidSignIn(): CloudTaskPassReport {
        bridge.cancelAdmissionsOfSignedOutAccounts()
        return runPass()
    }

    /** At launch: an account that ended while the app was not running. */
    fun reconcileAccount() {
        bridge.cancelAdmissionsOfSignedOutAccounts()
        if (!deletePending) publish(null)
    }

    private fun retryPendingDelete() {
        if (!deletePending) return
        val reply = coordinator.deleteRegistration()
        if (reply is CloudTaskReply.Ok || reply == CloudTaskReply.NoCredential) {
            deletePending = false
            publish(null)
        }
    }

    private fun publish(report: CloudTaskPassReport?) {
        val enabled = coordinator.isEnabled
        val signedIn = account() != CloudTaskAccount.SignedOut
        state.update { it.copy(enabled = enabled, status = CloudTaskStatusText.describe(enabled, signedIn, report)) }
    }
}
