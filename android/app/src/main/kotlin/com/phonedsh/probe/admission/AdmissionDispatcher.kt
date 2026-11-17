// SPDX-License-Identifier: MIT
// The seam between the admission journal and the owners that execute a request
// (spec/host/v1/external-admission.md section 4). The journal decides order,
// stages and retry; a dispatcher answers two questions about one record and
// performs one downstream write keyed by `downstreamId`.
//
// A `dsh-session` record is handed to the send outbox with
// `rpcId = downstreamId`. A `bot` record belongs to that Bot's user-action path
// with `nonce = downstreamId`; this build has no such owner wired, so a `bot`
// record stays `admitted` behind [AdmissionPrecheck.Wait] and nothing in it
// changes. There is no TonoLink voice source on Android (GAP-20).
package com.phonedsh.probe.admission

import com.phonedsh.probe.outbox.SendOutbox
import com.phonedsh.probe.outbox.SendOutboxException

/** The re-check made immediately before an `admitted` record is dispatched. */
internal sealed interface AdmissionPrecheck {
    /** The target exists, the principal is still valid and the owner can take the write now. */
    data object Proceed : AdmissionPrecheck

    /**
     * The owner cannot take the write yet (Bot unit not started, no owner in
     * this build). Not an attempt: nothing in the record changes.
     */
    data object Wait : AdmissionPrecheck

    /** `admitted → cancelled`: the target was deleted or the `account:` principal signed out. */
    data class Cancel(val reason: String) : AdmissionPrecheck
}

/** The outcome of one downstream write for a `dispatching` record. */
internal sealed interface AdmissionDelivery {
    /** The downstream owner durably holds `downstreamId`: `dispatching → linked`. */
    data object Linked : AdmissionDelivery

    /** This sender saw the write fail definitely: `dispatching → admitted` with backoff. */
    data class Retry(val lastError: String) : AdmissionDelivery

    /** The owner refused definitely (`target_missing`, `not_authorized`): `dispatching → failed`. */
    data class Refused(val reason: String) : AdmissionDelivery

    /** No proof either way. The record stays `dispatching` and the write is repeated later. */
    data object Unresolved : AdmissionDelivery
}

internal interface AdmissionDispatcher {
    /** Must not change anything. */
    fun precheck(record: AdmissionRecord): AdmissionPrecheck

    /**
     * Performs the downstream write with `record.downstreamId`. It is called
     * again with the same id after a restart, so it must be idempotent by that
     * id. Return [AdmissionDelivery.Unresolved] rather than guessing.
     */
    fun deliver(record: AdmissionRecord): AdmissionDelivery
}

/**
 * Hands `dsh-session` records to the durable send outbox.
 *
 * [sessionExists] and [isSignedInAccount] are the host's own facts, asked
 * immediately before each dispatch; the dispatcher keeps no copy of them.
 * [isSignedInAccount] receives the id after `account:`.
 */
internal class OutboxAdmissionDispatcher(
    private val outbox: SendOutbox,
    private val sessionExists: (sessionId: String) -> Boolean,
    private val isSignedInAccount: (accountId: String) -> Boolean,
) : AdmissionDispatcher {
    override fun precheck(record: AdmissionRecord): AdmissionPrecheck {
        if (record.principal.startsWith(ACCOUNT_PREFIX) &&
            !isSignedInAccount(record.principal.removePrefix(ACCOUNT_PREFIX))
        ) {
            return AdmissionPrecheck.Cancel(REASON_ACCOUNT_SIGNED_OUT)
        }
        return when (val target = record.target) {
            is AdmissionTarget.DshSession ->
                if (sessionExists(target.sessionId)) AdmissionPrecheck.Proceed
                else AdmissionPrecheck.Cancel(REASON_TARGET_DELETED)
            is AdmissionTarget.Bot -> AdmissionPrecheck.Wait
        }
    }

    override fun deliver(record: AdmissionRecord): AdmissionDelivery {
        val target = record.target as? AdmissionTarget.DshSession ?: return AdmissionDelivery.Unresolved
        val rpcId = record.downstreamId
        // A repeat after a restart: the outbox already holds this rpcId.
        if (outbox.entry(rpcId) != null) return AdmissionDelivery.Linked
        val text = record.text ?: return AdmissionDelivery.Unresolved
        return try {
            outbox.enqueue(sessionId = target.sessionId, text = text, rpcId = rpcId)
            AdmissionDelivery.Linked
        } catch (_: SendOutboxException.AlreadyExists) {
            // A file with this name exists but is not a readable entry: the
            // outbox does not durably hold the id, and nothing may overwrite it.
            AdmissionDelivery.Unresolved
        } catch (_: SendOutboxException.Storage) {
            // The entry write may have failed before or after its rename. Only
            // an entry that is certainly absent is a definite failure.
            if (!outbox.hasEntryFile(rpcId)) {
                AdmissionDelivery.Retry(ERROR_OUTBOX_STORAGE)
            } else {
                AdmissionDelivery.Unresolved
            }
        } catch (_: SendOutboxException) {
            // The outbox cannot hold this session id or text at all; no retry
            // can change that.
            AdmissionDelivery.Refused(REASON_TARGET_MISSING)
        }
    }

    companion object {
        const val REASON_TARGET_MISSING: String = "target_missing"
        const val REASON_TARGET_DELETED: String = "target_deleted"
        const val REASON_ACCOUNT_SIGNED_OUT: String = "account_signed_out"
        const val ERROR_OUTBOX_STORAGE: String = "outbox_storage"
        private const val ACCOUNT_PREFIX: String = "account:"
    }
}
