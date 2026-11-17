// SPDX-License-Identifier: MIT
// phone-dsh — :app: phone task queue ↔ external admission journal.
//
// spec/v1/cloud-tasks.md §7 on the app side (iOS: `CloudTaskAdmissionBridge.swift`):
// the three seams `CloudTaskCoordinator` calls. It only reads and writes the
// admission journal; it never boots an engine and executes nothing. A fetched
// task is an ordinary request attributed to `account:<user id>`: it carries no
// approval and bypasses no permission prompt.
//
// "Cannot tell" is never "missing": an unknown target, an unknown account and
// an unavailable journal all leave the task without an ack (the coordinator's
// existing transient path — a throwing seam or `STORAGE`), so the lease expires
// and the cloud redelivers. Only a target the app knows to be absent is acked
// `rejected` / `target_missing`.
//
// UI-free and Android-free on purpose: the JVM suite drives it with the real
// journal and the real coordinator.
package com.phonedsh.probe.cloudtasks

import com.phonedsh.cloudtasks.CloudTaskAdmission
import com.phonedsh.cloudtasks.CloudTaskAdmissionRequest
import com.phonedsh.cloudtasks.CloudTaskAdmissionResult
import com.phonedsh.cloudtasks.CloudTaskAdmitter
import com.phonedsh.cloudtasks.CloudTaskState
import com.phonedsh.cloudtasks.CloudTaskTarget
import com.phonedsh.cloudtasks.CloudTaskTargetCheck
import com.phonedsh.cloudtasks.CloudTaskTargetKind
import com.phonedsh.cloudtasks.CloudTaskTerminal
import com.phonedsh.cloudtasks.CloudTaskTerminalSource
import com.phonedsh.probe.admission.AdmissionRecord
import com.phonedsh.probe.admission.AdmissionRequest
import com.phonedsh.probe.admission.AdmissionResult
import com.phonedsh.probe.admission.AdmissionSource
import com.phonedsh.probe.admission.AdmissionSourceKind
import com.phonedsh.probe.admission.AdmissionStage
import com.phonedsh.probe.admission.AdmissionTarget
import com.phonedsh.probe.admission.ExternalAdmissionJournal
import com.phonedsh.probe.admission.OutboxAdmissionDispatcher
import java.util.UUID

/** What the app can say about a task's target without booting anything. */
internal enum class CloudTaskTargetPresence {
    PRESENT,

    /** Definitely not on this phone: the task is acked `rejected` / `target_missing`. */
    ABSENT,

    /** Cannot tell now (engine not running and no known session, Bot roster not loaded). */
    UNKNOWN,
}

/** How the app's two session facts combine into one answer. */
internal object CloudTaskPresenceRule {
    /**
     * [known]: the app holds a claim for the session (what the dispatcher will
     * accept). [listed]: whether the running engine's own session list contains
     * it, or null when no authoritative list could be read now. Only an
     * authoritative "not listed" is `ABSENT`.
     */
    fun session(known: Boolean, listed: Boolean?): CloudTaskTargetPresence = when {
        listed == false -> CloudTaskTargetPresence.ABSENT
        known -> CloudTaskTargetPresence.PRESENT
        else -> CloudTaskTargetPresence.UNKNOWN
    }
}

/** The tono account as the app can read it at the moment of use. */
internal sealed interface CloudTaskAccount {
    /** A session record with this user id is stored. */
    data class SignedIn(val userId: String) : CloudTaskAccount

    /** No account is signed in. */
    data object SignedOut : CloudTaskAccount

    /**
     * Cannot tell now: the secure store is unreadable, or the stored session has
     * no usable user id. Nothing is admitted and nothing is cancelled.
     */
    data object Unknown : CloudTaskAccount
}

/** Thrown into the coordinator's transient path: the task gets no ack and is redelivered. */
internal class CloudTaskDeferredException(reason: String) : Exception(reason)

internal class CloudTaskAdmissionBridge(
    /** The process's journal, or null while it cannot be opened (then nothing is admitted). */
    private val journal: () -> ExternalAdmissionJournal?,
    private val account: () -> CloudTaskAccount,
    private val presence: (AdmissionTarget) -> CloudTaskTargetPresence,
    /** A fresh lowercase UUIDv4 per admission; a duplicate keeps the record's own. */
    private val newDownstreamId: () -> String = { UUID.randomUUID().toString() },
) : CloudTaskTargetCheck, CloudTaskAdmitter, CloudTaskTerminalSource {

    /** Task ids the cloud holds a final answer for, in this process only (nothing is persisted). */
    private val settled = HashSet<String>()

    /** `account:<user id>` of the signed-in account, or null when there is none to attribute to. */
    fun signedInPrincipal(): String? = (account() as? CloudTaskAccount.SignedIn)?.let { principal(it.userId) }

    // ---- CloudTaskTargetCheck

    override fun exists(target: CloudTaskTarget): Boolean {
        // Without an account nothing is admitted, so nothing is decided about the target either.
        signedInPrincipal() ?: throw CloudTaskDeferredException("no signed-in account")
        return when (presence(target(target))) {
            CloudTaskTargetPresence.PRESENT -> true
            CloudTaskTargetPresence.ABSENT -> false
            CloudTaskTargetPresence.UNKNOWN -> throw CloudTaskDeferredException("target presence unknown")
        }
    }

    // ---- CloudTaskAdmitter

    override fun admit(request: CloudTaskAdmissionRequest): CloudTaskAdmission {
        val principal = signedInPrincipal() ?: throw CloudTaskDeferredException("no signed-in account")
        val journal = journal() ?: return CloudTaskAdmission(CloudTaskAdmissionResult.STORAGE)
        val result = journal.admit(
            AdmissionRequest(
                principal = principal,
                source = AdmissionSource(AdmissionSourceKind.CLOUD_TASK, request.deviceId),
                sourceRequestId = request.taskId,
                target = target(request.target),
                text = request.text,
                expiresAtMs = request.expiresAtMs,
                downstreamId = newDownstreamId().lowercase(),
            ),
        )
        return when (result) {
            is AdmissionResult.Admitted ->
                CloudTaskAdmission(CloudTaskAdmissionResult.ADMITTED, result.receipt.admissionId)
            is AdmissionResult.Duplicate ->
                CloudTaskAdmission(CloudTaskAdmissionResult.DUPLICATE, result.receipt.admissionId)
            AdmissionResult.Invalid -> CloudTaskAdmission(CloudTaskAdmissionResult.INVALID)
            AdmissionResult.Conflict -> CloudTaskAdmission(CloudTaskAdmissionResult.CONFLICT)
            AdmissionResult.Capacity -> CloudTaskAdmission(CloudTaskAdmissionResult.CAPACITY)
            is AdmissionResult.Storage -> CloudTaskAdmission(CloudTaskAdmissionResult.STORAGE)
        }
    }

    // ---- CloudTaskTerminalSource

    /**
     * Terminal cloud-task records of this device and of the signed-in account,
     * oldest first. Another account's records are never offered to this
     * account's session. "Settled" is derived: a record stays in the journal
     * until its own tombstone sweep, and this process remembers which task ids
     * the cloud already answered finally; a new process offers them once more
     * and the cloud answers `duplicate`.
     */
    override fun pending(deviceId: String, limit: Int): List<CloudTaskTerminal> {
        val principal = signedInPrincipal() ?: return emptyList()
        val journal = journal() ?: return emptyList()
        // An `admitted` record past `expiresAtMs` becomes `expired` by the journal's own sweep.
        runCatching { journal.sweep() }
        val terminal = journal.records().filter { record ->
            record.principal == principal && record.source.kind == AdmissionSourceKind.CLOUD_TASK &&
                record.source.id == deviceId && record.stage.isTerminal
        }
        synchronized(settled) {
            settled.retainAll(terminal.mapTo(HashSet()) { it.sourceRequestId })
            return terminal.filterNot { it.sourceRequestId in settled }.take(limit).map(::terminal)
        }
    }

    override fun settled(taskId: String, cloudState: CloudTaskState) {
        synchronized(settled) { settled += taskId }
    }

    // ---- account changes

    /**
     * The account changed or signed out: `admitted` records of every account
     * that is no longer signed in become `cancelled` (external-admission.md §3).
     * While the account cannot be read nothing is cancelled. Returns the
     * cancelled records.
     */
    fun cancelAdmissionsOfSignedOutAccounts(): List<AdmissionRecord> {
        val keep = when (val current = account()) {
            is CloudTaskAccount.SignedIn -> principal(current.userId) ?: return emptyList()
            CloudTaskAccount.SignedOut -> null
            CloudTaskAccount.Unknown -> return emptyList()
        }
        val journal = journal() ?: return emptyList()
        return journal.records()
            .filter { it.stage == AdmissionStage.ADMITTED && it.principal.startsWith(ACCOUNT_PREFIX) && it.principal != keep }
            .mapNotNull { record ->
                // A record the dispatcher moved on in the meantime keeps its own stage.
                runCatching {
                    journal.cancel(record.admissionId, OutboxAdmissionDispatcher.REASON_ACCOUNT_SIGNED_OUT)
                }.getOrNull()
            }
    }

    companion object {
        private const val ACCOUNT_PREFIX = "account:"
        private val USER_ID = Regex("[A-Za-z0-9._-]{1,128}")

        /** `account:<user id>`, or null when [userId] cannot be a journal principal. */
        fun principal(userId: String): String? =
            if (USER_ID.matches(userId)) CloudTaskAdmissionRequest.principal(userId) else null

        fun target(target: CloudTaskTarget): AdmissionTarget = when (target.kind) {
            CloudTaskTargetKind.DSH_SESSION -> AdmissionTarget.DshSession(target.id)
            CloudTaskTargetKind.BOT -> AdmissionTarget.Bot(target.id)
        }

        /** The record's own stage and reason; `CloudTaskWire.terminalAck` maps them (§7). */
        fun terminal(record: AdmissionRecord): CloudTaskTerminal =
            CloudTaskTerminal(record.sourceRequestId, record.admissionId, record.stage.wire, record.reason)
    }
}
