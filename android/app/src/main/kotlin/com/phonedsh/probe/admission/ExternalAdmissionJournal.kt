// SPDX-License-Identifier: MIT
// External admission journal (P06; spec/host/v1/external-admission.md, revision
// external-admission-v1.1; change record PC-20261116-external-admission).
//
// A request that arrives from outside the composer is written here first, and
// only then handed to the owner that executes it. One file per record,
// `<root>/admissions/<admissionId>.json`, in the same app-private tree as
// `send-outbox/`, written with the section 7 order (temp, fsync, rename,
// directory fsync).
//
// The journal owns one fact: that the request was admitted, and which
// `downstreamId` carries it. It executes nothing, boots no engine, copies no
// history, and does not replace the send outbox. It opens with a directory and
// a clock and nothing else.
//
//   admitted → dispatching → linked → completed | failed | unknown
//   dispatching → admitted            (definite downstream failure, backoff)
//   admitted → expired | cancelled | failed
//   dispatching → failed
//
// A file that does not decode as a v1 record is left exactly as it is: counted
// toward the directory bound, never dispatched, never deleted, never overwritten.
//
// Blocking; every operation is serialised on the journal's monitor. Callers run
// it off the main thread.
package com.phonedsh.probe.admission

import com.phonedsh.probe.outbox.DurableFileStore
import java.io.File
import java.io.IOException
import java.util.UUID

/** The durable receipt: never a bare boolean. */
internal data class AdmissionReceipt(
    val admissionId: String,
    val downstreamId: String,
    val stage: AdmissionStage,
)

/** The six results of section 2. Only [Admitted] and [Duplicate] carry a receipt. */
internal sealed interface AdmissionResult {
    /** The record was written with `stage: admitted`, `attempts: 0`. */
    data class Admitted(val receipt: AdmissionReceipt) : AdmissionResult

    /** Nothing was written; the existing record (any stage, including terminal) is the receipt. */
    data class Duplicate(val receipt: AdmissionReceipt) : AdmissionResult

    /** Same `admissionId`, different target or content. Nothing was written or overwritten. */
    data object Conflict : AdmissionResult

    /** 256 pending records or 2048 directory entries. Nothing was written; the source keeps the request. */
    data object Capacity : AdmissionResult

    /** A field breaks the schema, the byte bound or the TTL bound. Nothing was written. */
    data object Invalid : AdmissionResult

    /** The write failed. There is no receipt. */
    data class Storage(val detail: String) : AdmissionResult
}

internal sealed class AdmissionException(message: String, cause: Throwable? = null) : Exception(message, cause) {
    class UnknownRecord : AdmissionException("admission record does not exist")
    class IllegalTransition(val from: AdmissionStage, val to: AdmissionStage) :
        AdmissionException("illegal admission transition ${from.wire} → ${to.wire}")
    class NotExpired : AdmissionException("the record has not reached expiresAtMs")
    class InvalidCode(val value: String) : AdmissionException("not a short code: $value")
    class Storage(detail: String, cause: Throwable? = null) :
        AdmissionException("admission storage failed: $detail", cause)
}

internal data class AdmissionSweepReport(
    val expired: List<String> = emptyList(),
    val unknown: List<String> = emptyList(),
    val deleted: List<String> = emptyList(),
    /** Records whose sweep write or delete failed; they are retried by the next sweep. */
    val failed: List<String> = emptyList(),
)

/** What one dispatch pass did, by `admissionId`. */
internal data class AdmissionPassReport(
    val sweep: AdmissionSweepReport,
    val linked: List<String>,
    val retried: List<String>,
    val failed: List<String>,
    val cancelled: List<String>,
    val expired: List<String>,
    /** The owner is not ready; nothing in the record changed. */
    val waiting: List<String>,
    /** Still `dispatching`: no proof either way, repeated by the next pass. */
    val unresolved: List<String>,
)

internal class ExternalAdmissionJournal(
    root: File,
    private val nowMs: () -> Long = System::currentTimeMillis,
    private val files: DurableFileStore = DurableFileStore(),
    private val newUuid: () -> String = { UUID.randomUUID().toString() },
) {
    /** `<root>/admissions`: one `<admissionId>.json` per record. */
    val directory: File = File(root, DIRECTORY_NAME)

    /** The sweep that ran when this journal was opened. */
    val openSweep: AdmissionSweepReport = sweep()

    // ---------------------------------------------------------------- admission

    /**
     * One decision followed by one atomic write. Tell the source "received" only
     * for [AdmissionResult.Admitted] and [AdmissionResult.Duplicate].
     */
    @Synchronized
    fun admit(request: AdmissionRequest): AdmissionResult {
        val now = nowMs()
        val candidate = AdmissionPolicy.candidate(request, request.downstreamId ?: newUuid(), now)
            ?: return AdmissionResult.Invalid
        val names = listNames() ?: return AdmissionResult.Storage("the admissions directory cannot be read")
        val file = recordFile(candidate.admissionId)
        var existing: AdmissionRecord? = null
        if (file.name in names) {
            existing = when (val loaded = load(file)) {
                is Loaded.Record -> loaded.record
                // The file with this name is not a readable v1 record. It is
                // never overwritten and it cannot be compared, so there is no
                // receipt and nothing is written.
                Loaded.Undecodable ->
                    return AdmissionResult.Storage("the file for this admissionId is not a readable v1 record")
                Loaded.Absent -> null
            }
        }
        // The pending count is only needed once the request is known to be new.
        val pending = if (existing == null) names.count { isPendingRecord(it) } else 0
        return when (AdmissionPolicy.decide(candidate, existing, pending, names.size)) {
            AdmissionDecision.DUPLICATE -> AdmissionResult.Duplicate(receipt(existing ?: candidate))
            AdmissionDecision.CONFLICT -> AdmissionResult.Conflict
            AdmissionDecision.CAPACITY -> AdmissionResult.Capacity
            AdmissionDecision.INVALID -> AdmissionResult.Invalid
            AdmissionDecision.ADMITTED -> try {
                write(candidate)
                AdmissionResult.Admitted(receipt(candidate))
            } catch (failure: AdmissionException.Storage) {
                AdmissionResult.Storage(failure.message ?: "write failed")
            }
        }
    }

    // ------------------------------------------------------------------ reading

    @Synchronized
    fun record(admissionId: String): AdmissionRecord? {
        if (!AdmissionCodec.isValidAdmissionId(admissionId)) return null
        return (load(recordFile(admissionId)) as? Loaded.Record)?.record
    }

    /** Every readable v1 record, ordered by (`admittedAtMs`, `admissionId`). */
    @Synchronized
    fun records(): List<AdmissionRecord> =
        listNames().orEmpty()
            .filter { it.endsWith(SUFFIX) && !it.startsWith(".") }
            .mapNotNull { (load(File(directory, it)) as? Loaded.Record)?.record }
            .sortedWith(compareBy<AdmissionRecord> { it.admittedAtMs }.thenBy { it.admissionId })

    /** The record whose `downstreamId` (outbox `rpcId` or Bot nonce) is [downstreamId], if any. */
    @Synchronized
    fun recordForDownstreamId(downstreamId: String): AdmissionRecord? =
        records().firstOrNull { it.downstreamId == downstreamId }

    /** Every entry of the directory of any kind: the number the 2048 bound is checked against. */
    @Synchronized
    fun directoryEntryCount(): Int = listNames().orEmpty().size

    /**
     * The records the next pass would dispatch, in order, at most 16. A record
     * for which [isWaiting] is true is skipped and does not count toward the 16.
     */
    @Synchronized
    fun dispatchable(isWaiting: (AdmissionRecord) -> Boolean = { false }): List<AdmissionRecord> =
        AdmissionPolicy.dispatchOrder(records(), nowMs(), isWaiting)

    // -------------------------------------------------------------- transitions

    /** `admitted → dispatching`. Call it, and let it return, before the downstream write. */
    @Synchronized
    @Throws(AdmissionException::class)
    fun markDispatching(admissionId: String): AdmissionRecord =
        transition(admissionId, AdmissionStage.DISPATCHING) { record, _ ->
            record.copy(stage = AdmissionStage.DISPATCHING)
        }

    /** `dispatching → linked`: the downstream owner durably holds `downstreamId`. Removes `text`. */
    @Synchronized
    @Throws(AdmissionException::class)
    fun markLinked(admissionId: String): AdmissionRecord =
        transition(admissionId, AdmissionStage.LINKED) { record, now ->
            record.copy(
                stage = AdmissionStage.LINKED,
                text = null,
                lastError = null,
                nextAttemptAtMs = null,
                linkedAtMs = now,
            )
        }

    /**
     * The same live sender saw the downstream write fail definitely:
     * `dispatching → admitted` with one more attempt and the backoff, or
     * `dispatching → failed` (`retry_exhausted`) when that would exceed 12.
     * Waiting for an execution condition is not an attempt: do not call this.
     */
    @Synchronized
    @Throws(AdmissionException::class)
    fun retryLater(admissionId: String, lastError: String): AdmissionRecord {
        requireCode(lastError)
        val current = record(admissionId) ?: throw AdmissionException.UnknownRecord()
        if (!AdmissionPolicy.allows(current.stage, AdmissionStage.ADMITTED)) {
            throw AdmissionException.IllegalTransition(current.stage, AdmissionStage.ADMITTED)
        }
        return when (val retry = AdmissionPolicy.retry(current.attempts, nowMs())) {
            AdmissionRetry.Exhausted -> fail(admissionId, AdmissionPolicy.RETRY_EXHAUSTED)
            is AdmissionRetry.Again -> {
                val updated = current.copy(
                    stage = AdmissionStage.ADMITTED,
                    attempts = retry.attempts,
                    lastError = lastError,
                    nextAttemptAtMs = retry.nextAttemptAtMs,
                )
                write(updated)
                updated
            }
        }
    }

    /**
     * `admitted → failed`, `dispatching → failed` (the owner refused definitely:
     * `target_missing`, `not_authorized`) or `linked → failed` (the owner reports
     * that the work started by `downstreamId` failed or was cancelled).
     */
    @Synchronized
    @Throws(AdmissionException::class)
    fun fail(admissionId: String, reason: String): AdmissionRecord =
        settle(admissionId, AdmissionStage.FAILED, reason)

    /** `linked → completed`, on the downstream owner's own terminal evidence. */
    @Synchronized
    @Throws(AdmissionException::class)
    fun complete(admissionId: String): AdmissionRecord = settle(admissionId, AdmissionStage.COMPLETED, null)

    /** `admitted → cancelled`: withdrawn, target deleted, or the `account:` principal signed out. */
    @Synchronized
    @Throws(AdmissionException::class)
    fun cancel(admissionId: String, reason: String? = null): AdmissionRecord =
        settle(admissionId, AdmissionStage.CANCELLED, reason)

    /** `linked → unknown`: no terminal report within 14 days, or the owner can no longer attribute it. */
    @Synchronized
    @Throws(AdmissionException::class)
    fun markUnknown(admissionId: String, reason: String? = null): AdmissionRecord =
        settle(admissionId, AdmissionStage.UNKNOWN, reason)

    /** `admitted → expired`, only once the clock has reached `expiresAtMs`. */
    @Synchronized
    @Throws(AdmissionException::class)
    fun expire(admissionId: String): AdmissionRecord =
        transition(admissionId, AdmissionStage.EXPIRED) { record, now ->
            if (now < record.expiresAtMs) throw AdmissionException.NotExpired()
            settled(record, AdmissionStage.EXPIRED, AdmissionPolicy.EXPIRED, now)
        }

    private fun settle(admissionId: String, stage: AdmissionStage, reason: String?): AdmissionRecord {
        reason?.let(::requireCode)
        return transition(admissionId, stage) { record, now -> settled(record, stage, reason, now) }
    }

    /** `text` leaves in the same write that leaves the pending stages. */
    private fun settled(record: AdmissionRecord, stage: AdmissionStage, reason: String?, now: Long) =
        record.copy(
            stage = stage,
            text = null,
            lastError = null,
            nextAttemptAtMs = null,
            settledAtMs = now,
            reason = reason,
        )

    private fun transition(
        admissionId: String,
        next: AdmissionStage,
        change: (AdmissionRecord, Long) -> AdmissionRecord,
    ): AdmissionRecord {
        val current = record(admissionId) ?: throw AdmissionException.UnknownRecord()
        if (!AdmissionPolicy.allows(current.stage, next)) {
            throw AdmissionException.IllegalTransition(current.stage, next)
        }
        val updated = change(current, nowMs())
        write(updated)
        return updated
    }

    private fun requireCode(value: String) {
        if (!AdmissionCodec.isValidCode(value)) throw AdmissionException.InvalidCode(value)
    }

    // -------------------------------------------------------------------- sweep

    /**
     * Runs at open and before each pass. `admitted` records past `expiresAtMs`
     * become `expired`; a `linked` record 14 days after admission becomes
     * `unknown`; a terminal record is deleted once
     * `now ≥ max(expiresAtMs, settledAtMs + 24 h)`. Pending and `linked` records
     * are never deleted, and a file that is not a v1 record is never touched.
     */
    @Synchronized
    fun sweep(): AdmissionSweepReport {
        val now = nowMs()
        val expired = ArrayList<String>()
        val unknown = ArrayList<String>()
        val deleted = ArrayList<String>()
        val failed = ArrayList<String>()
        for (record in records()) {
            try {
                when (AdmissionPolicy.sweep(record, now)) {
                    AdmissionSweepAction.KEEP -> Unit
                    AdmissionSweepAction.EXPIRE -> {
                        write(settled(record, AdmissionStage.EXPIRED, AdmissionPolicy.EXPIRED, now))
                        expired.add(record.admissionId)
                    }
                    AdmissionSweepAction.UNKNOWN -> {
                        write(settled(record, AdmissionStage.UNKNOWN, null, now))
                        unknown.add(record.admissionId)
                    }
                    AdmissionSweepAction.DELETE -> {
                        try {
                            files.deleteDurably(recordFile(record.admissionId))
                        } catch (failure: IOException) {
                            throw AdmissionException.Storage(failure.message ?: "delete failed", failure)
                        }
                        deleted.add(record.admissionId)
                    }
                }
            } catch (_: AdmissionException.Storage) {
                failed.add(record.admissionId)
            }
        }
        return AdmissionSweepReport(expired, unknown, deleted, failed)
    }

    // ----------------------------------------------------------------- dispatch

    /**
     * One sequential pass: sweep, then at most 16 records in FIFO order. A
     * record whose owner answers [AdmissionPrecheck.Wait] is skipped, is not an
     * attempt, and does not count toward the 16.
     *
     * For an `admitted` record the pass re-checks expiry and asks
     * [AdmissionDispatcher.precheck]; only on [AdmissionPrecheck.Proceed] is the
     * record made `dispatching` (durably) and then delivered. A `dispatching`
     * record found here was left by an earlier pass or process: it has no proof
     * either way and is resolved by repeating the downstream write with the same
     * `downstreamId`, never by expiring or cancelling it.
     *
     * A storage failure of the journal itself stops the pass by throwing; the
     * record it was working on keeps its last durable stage.
     */
    @Synchronized
    @Throws(AdmissionException::class)
    fun runDispatchPass(dispatcher: AdmissionDispatcher): AdmissionPassReport {
        val swept = sweep()
        val linked = ArrayList<String>()
        val retried = ArrayList<String>()
        val failed = ArrayList<String>()
        val cancelled = ArrayList<String>()
        val expired = ArrayList<String>()
        val waiting = ArrayList<String>()
        val unresolved = ArrayList<String>()
        // Waiting records are skipped without using the pass, so the limit counts
        // the records this pass actually acts on.
        var used = 0
        for (candidate in AdmissionPolicy.ready(records(), nowMs())) {
            if (used >= AdmissionPolicy.PASS_LIMIT) break
            val id = candidate.admissionId
            var current = record(id) ?: continue
            if (!current.stage.isPending) continue
            val check = dispatcher.precheck(current)
            if (check == AdmissionPrecheck.Wait) {
                waiting.add(id)
                continue
            }
            used += 1
            if (current.stage == AdmissionStage.ADMITTED) {
                if (nowMs() >= current.expiresAtMs) {
                    expire(id)
                    expired.add(id)
                    continue
                }
                if (check is AdmissionPrecheck.Cancel) {
                    cancel(id, check.reason)
                    cancelled.add(id)
                    continue
                }
                current = markDispatching(id)
            }
            when (val delivery = dispatcher.deliver(current)) {
                AdmissionDelivery.Linked -> {
                    markLinked(id)
                    linked.add(id)
                }
                is AdmissionDelivery.Retry -> {
                    val after = retryLater(id, delivery.lastError)
                    if (after.stage == AdmissionStage.FAILED) failed.add(id) else retried.add(id)
                }
                is AdmissionDelivery.Refused -> {
                    fail(id, delivery.reason)
                    failed.add(id)
                }
                AdmissionDelivery.Unresolved -> unresolved.add(id)
            }
        }
        return AdmissionPassReport(swept, linked, retried, failed, cancelled, expired, waiting, unresolved)
    }

    // ------------------------------------------------------------------ storage

    private sealed interface Loaded {
        data class Record(val record: AdmissionRecord) : Loaded

        data object Undecodable : Loaded

        data object Absent : Loaded
    }

    private fun recordFile(admissionId: String): File = File(directory, admissionId + SUFFIX)

    /** Null when the directory exists but cannot be listed; empty when it does not exist yet. */
    private fun listNames(): List<String>? {
        if (!directory.exists()) return emptyList()
        return directory.list()?.toList()
    }

    private fun isPendingRecord(name: String): Boolean {
        if (!name.endsWith(SUFFIX) || name.startsWith(".")) return false
        return (load(File(directory, name)) as? Loaded.Record)?.record?.stage?.isPending == true
    }

    /** A record is a file that decodes as v1 and whose name is its own `admissionId`. */
    private fun load(file: File): Loaded {
        val text = try {
            if (!file.exists()) return Loaded.Absent
            if (!file.isFile) return Loaded.Undecodable
            file.readText(Charsets.UTF_8)
        } catch (_: IOException) {
            return Loaded.Undecodable
        }
        val record = try {
            AdmissionCodec.decode(text)
        } catch (_: AdmissionInvalidRecordException) {
            return Loaded.Undecodable
        }
        return if (record.admissionId + SUFFIX == file.name) Loaded.Record(record) else Loaded.Undecodable
    }

    private fun write(record: AdmissionRecord) {
        val bytes = try {
            AdmissionCodec.encode(record).toByteArray(Charsets.UTF_8)
        } catch (failure: AdmissionInvalidRecordException) {
            throw AdmissionException.Storage(failure.message ?: "record is invalid", failure)
        }
        try {
            files.writeAtomically(recordFile(record.admissionId), bytes)
        } catch (failure: IOException) {
            throw AdmissionException.Storage(failure.message ?: "write failed", failure)
        }
    }

    private fun receipt(record: AdmissionRecord) =
        AdmissionReceipt(record.admissionId, record.downstreamId, record.stage)

    companion object {
        const val DIRECTORY_NAME: String = "admissions"
        private const val SUFFIX: String = ".json"
    }
}
