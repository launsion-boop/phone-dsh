// SPDX-License-Identifier: MIT
// phone-dsh — :net / com.phonedsh.cloudtasks: one pull → admit → ack pass.
//
// cloud-tasks.md §7 on Android. The coordinator owns no timer and no thread:
// the app calls [CloudTaskCoordinator.runPass] when it becomes active and after
// sign-in, and the pass itself repeats while a pull returned work. It never
// starts the engine; an admitted task is the admission journal's to dispatch.
//
// "Now" of the expiry check is the pull answer's `server_time_ms`; the local
// clock is used only when the answer has none.
//
// For each pulled task, in the contract's order: at least 1000 ms left (else
// ack `expired`), the private key for `key_id` (else `rejected/key_unknown`),
// open with the §3 AAD (else `rejected/decrypt_failed`), the target exists
// (else `rejected/target_missing`), then admit. `admitted`/`duplicate` ack
// `admitted` with the record's admission id; `invalid`/`conflict` ack
// `rejected`; `capacity`/`storage` and an unreadable key store send no ack, so
// the lease expires and the cloud redelivers. An ack is built only after the
// admission call returned.
//
// The admission journal (spec/host/v1/external-admission.md) is not a
// dependency of this module: it arrives as [CloudTaskAdmitter] and
// [CloudTaskTerminalSource].

package com.phonedsh.cloudtasks

import java.io.IOException

/** What §7 hands to the admission journal for one task. `toString` never prints the text. */
class CloudTaskAdmissionRequest(
    /** `source = {kind: "cloud-task", id: deviceId}`. */
    val deviceId: String,
    /** `sourceRequestId`. */
    val taskId: String,
    /** `target.id` is the `sessionId` / `botId`. */
    val target: CloudTaskTarget,
    /** The opened plaintext. */
    val text: String,
    val expiresAtMs: Long,
) {
    override fun toString(): String = "CloudTaskAdmissionRequest($taskId)"

    companion object {
        const val SOURCE_KIND: String = "cloud-task"

        /** `principal = "account:" + <signed-in user id>`. */
        fun principal(userId: String): String = "account:$userId"
    }
}

enum class CloudTaskAdmissionResult { ADMITTED, DUPLICATE, INVALID, CONFLICT, CAPACITY, STORAGE }

/** The journal's answer; [admissionId] is required for `ADMITTED` and `DUPLICATE`. */
class CloudTaskAdmission(val result: CloudTaskAdmissionResult, val admissionId: String? = null)

/**
 * Writes one task into the admission journal and returns only after the write
 * returned. The implementation adds the principal (`account:<user id>`) and a
 * fresh `downstreamId`. Throwing is treated like `STORAGE`: no ack.
 */
fun interface CloudTaskAdmitter {
    fun admit(request: CloudTaskAdmissionRequest): CloudTaskAdmission
}

/** Whether the task's target (DSH session or Bot) exists on this phone now. */
fun interface CloudTaskTargetCheck {
    fun exists(target: CloudTaskTarget): Boolean
}

/**
 * One admitted task whose admission record reached a terminal stage. [stage]
 * and [reason] are the record's own values (`completed`, `failed`, `unknown`,
 * `expired`, `cancelled`; any reason or none): `CloudTaskWire.terminalAck` maps
 * them, so no record is left un-acked for a reason this end does not know.
 */
class CloudTaskTerminal(
    /** The record's `sourceRequestId`. */
    val taskId: String,
    val admissionId: String,
    val stage: String,
    val reason: String? = null,
)

/** Admission records of this device that reached a terminal stage and are not settled with the cloud yet. */
interface CloudTaskTerminalSource {
    /** At most [limit] unsettled terminal records whose source is `cloud-task` / [deviceId], oldest first. */
    fun pending(deviceId: String, limit: Int): List<CloudTaskTerminal>

    /**
     * The cloud holds a final answer for [taskId] ([cloudState] is its state
     * after the call), so the record is not offered again. Until this is called
     * the terminal ack is re-sent on every pass.
     */
    fun settled(taskId: String, cloudState: CloudTaskState)

    object None : CloudTaskTerminalSource {
        override fun pending(deviceId: String, limit: Int): List<CloudTaskTerminal> = emptyList()

        override fun settled(taskId: String, cloudState: CloudTaskState) = Unit
    }
}

enum class CloudTaskPassStatus {
    /** The pass ran to its end (possibly with nothing to do). */
    COMPLETED,

    /** The feature is off: nothing was sent. */
    DISABLED,

    /** Another pass is running; it will run once more for this trigger. */
    BUSY,

    /** No usable access token (signed out): nothing was sent. */
    NO_CREDENTIAL,

    /** This cloud has no phone task routes (404). Not retried until the hold-off passed. */
    UNAVAILABLE,

    /** No answer from the cloud. */
    UNREACHABLE,

    /** The cloud refused a call; see [CloudTaskPassReport.refusedCode]. */
    REFUSED,

    /** An answer was not the contract's. */
    PROTOCOL_ERROR,

    /** The key store cannot be read or written now (for example before first unlock). */
    KEY_STORE_UNAVAILABLE,

    /** The stored device id is not a `dev-<uuid>`. */
    NO_DEVICE_ID,
}

data class CloudTaskPassReport(
    val status: CloudTaskPassStatus,
    val refusedStatus: Int? = null,
    val refusedCode: String? = null,
    /** Tasks returned by pulls in this pass. */
    val pulled: Int = 0,
    /** Admission ids the journal reported `ADMITTED` (new records) in this pass. */
    val admittedIds: List<String> = emptyList(),
    /** Acks the cloud accepted (first or duplicate). */
    val acksAccepted: Int = 0,
    /** Tasks left without an ack for a transient reason; the cloud redelivers them. */
    val deferred: Int = 0,
    /** Pull elements that did not decode: acked `rejected/invalid` when they had a task id, else skipped. */
    val undecodable: Int = 0,
    /** Terminal records settled with the cloud. */
    val terminalsSettled: Int = 0,
)

class CloudTaskCoordinator(
    private val client: CloudTaskClient,
    private val preferences: CloudTaskPreferences,
    private val keys: CloudTaskKeyStore,
    private val targets: CloudTaskTargetCheck,
    private val admitter: CloudTaskAdmitter,
    private val terminals: CloudTaskTerminalSource = CloudTaskTerminalSource.None,
    /** `app_version` of the registration, 1–32 characters. */
    private val appVersion: String,
    private val clock: () -> Long = System::currentTimeMillis,
    /** Upper bound of pull rounds in one pass. */
    private val maxRounds: Int = 8,
    /** After a 404 route answer, passes send nothing for this long. */
    private val unavailableHoldMs: Long = 10 * 60 * 1000L,
    private val newKeyPair: () -> CloudTaskKeyPair = { CloudTaskCrypto.generateKeyPair() },
    private val newKeyId: () -> String = { CloudTaskIdentity.newKeyId() },
    private val fcmToken: () -> String? = { null },
) {
    private val flightLock = Any()
    private var running = false
    private var again = false

    /** Serialises a pass against [disable] and [deleteRegistration]. */
    private val workLock = Any()

    // In-memory only, all under workLock.
    private var registeredKeyId: String? = null
    private var registeredFcmToken: String? = null
    private var unsupportedFcmToken: String? = null
    private var lastKeyId: String? = null
    private var unsentRecord: CloudTaskKeyRecord? = null
    private val previousKeyIds = LinkedHashSet<String>()
    private var unavailableUntilMs = Long.MIN_VALUE

    val isEnabled: Boolean get() = CloudTaskIdentity.isEnabled(preferences)

    /** Turns the feature on. Sends nothing; the next [runPass] registers and pulls. */
    fun enable() {
        preferences.putBoolean(CloudTaskIdentity.ENABLED_KEY, true)
        synchronized(workLock) { unavailableUntilMs = Long.MIN_VALUE }
    }

    /**
     * Turns the feature off and deletes the registration (§7). The flag is
     * written first, so no pass registers or pulls afterwards. The returned
     * reply is the DELETE's; when it is not `Ok` the registration may still
     * exist and [deleteRegistration] can be called again.
     */
    fun disable(): CloudTaskReply<Unit> {
        preferences.putBoolean(CloudTaskIdentity.ENABLED_KEY, false)
        return deleteRegistration()
    }

    /**
     * `DELETE /v1/phone/devices/{device_id}`: on sign-out (call it while the
     * access token still works) and when the feature is turned off. Sends
     * nothing when this install never had a device id.
     */
    fun deleteRegistration(): CloudTaskReply<Unit> = synchronized(workLock) {
        if (preferences.string(CloudTaskIdentity.DEVICE_ID_KEY) == null) return CloudTaskReply.Ok(Unit)
        val deviceId = CloudTaskIdentity.deviceId(preferences) ?: return CloudTaskReply.ProtocolError
        registeredKeyId?.let { lastKeyId = it }
        registeredKeyId = null
        client.deleteDevice(deviceId)
    }

    /**
     * One pass: register if needed, send terminal acks, then pull → admit →
     * ack while work is returned. Blocking; call it on an IO thread. A call
     * while a pass is running returns [CloudTaskPassStatus.BUSY] and makes the
     * running pass go round once more.
     */
    fun runPass(): CloudTaskPassReport {
        if (Thread.currentThread().isInterrupted) throw InterruptedException()
        synchronized(flightLock) {
            if (running) {
                again = true
                return CloudTaskPassReport(CloudTaskPassStatus.BUSY)
            }
            running = true
            again = false
        }
        var report: CloudTaskPassReport
        var repeats = 0
        try {
            while (true) {
                report = synchronized(workLock) { pass() }
                synchronized(flightLock) {
                    if (again && report.status == CloudTaskPassStatus.COMPLETED && repeats < MAX_REPEATS) {
                        again = false
                        repeats++
                    } else {
                        running = false
                        again = false
                        return report
                    }
                }
            }
        } catch (failure: Throwable) {
            synchronized(flightLock) {
                running = false
                again = false
            }
            throw failure
        }
    }

    // ---- one pass (under workLock)

    private class Tally {
        var pulled = 0
        val admittedIds = ArrayList<String>()
        var acksAccepted = 0
        var deferred = 0
        var undecodable = 0
        var terminalsSettled = 0

        fun report(status: CloudTaskPassStatus, refused: CloudTaskReply.Refused? = null) = CloudTaskPassReport(
            status = status,
            refusedStatus = refused?.status,
            refusedCode = refused?.code,
            pulled = pulled,
            admittedIds = admittedIds.toList(),
            acksAccepted = acksAccepted,
            deferred = deferred,
            undecodable = undecodable,
            terminalsSettled = terminalsSettled,
        )
    }

    private fun pass(): CloudTaskPassReport {
        val tally = Tally()
        if (!isEnabled) return tally.report(CloudTaskPassStatus.DISABLED)
        if (clock() < unavailableUntilMs) return tally.report(CloudTaskPassStatus.UNAVAILABLE)
        val deviceId = CloudTaskIdentity.deviceId(preferences)
            ?: return tally.report(CloudTaskPassStatus.NO_DEVICE_ID)

        if (Thread.currentThread().isInterrupted) throw InterruptedException()
        ensureRegistered(deviceId, tally)?.let { return it }
        if (Thread.currentThread().isInterrupted) throw InterruptedException()
        sendTerminals(deviceId, tally)?.let { return it }

        var drained = false
        var reRegistered = false
        var round = 0
        while (round < maxRounds) {
            if (Thread.currentThread().isInterrupted) throw InterruptedException()
            if (!isEnabled) return tally.report(CloudTaskPassStatus.DISABLED)
            var pulledAtMs = clock()
            val tasks = when (val reply = client.pull(deviceId, CloudTaskWire.MAX_PULL, LEASE_SECONDS, 0)) {
                is CloudTaskReply.Ok -> {
                    pulledAtMs = reply.value.serverTimeMs ?: clock()
                    reply.value.elements
                }
                is CloudTaskReply.Refused -> {
                    // The cloud no longer knows this device (removed elsewhere, or another account).
                    if (reply.status == 404 && reply.code == "not_found" && !reRegistered) {
                        reRegistered = true
                        registeredKeyId?.let { lastKeyId = it }
                        registeredKeyId = null
                        ensureRegistered(deviceId, tally)?.let { return it }
                        continue
                    }
                    return failure(reply, tally)
                }
                else -> return failure(reply, tally)
            }
            round++
            if (tasks.isEmpty()) {
                drained = true
                break
            }
            tally.pulled += tasks.size

            val acks = ArrayList<CloudTaskAck>()
            val fresh = ArrayList<String>()
            var deferred = 0
            for (element in tasks) {
                if (Thread.currentThread().isInterrupted) throw InterruptedException()
                val task = when (element) {
                    is CloudTaskPullElement.Task -> element.task
                    is CloudTaskPullElement.Undecodable -> {
                        // §5: a valid task id is acked `rejected/invalid`; without one there is nothing to ack.
                        tally.undecodable++
                        element.taskId?.let { acks += CloudTaskAck.Rejected(it, CloudTaskRejectReason.INVALID) }
                        continue
                    }
                }
                when (val decision = decide(deviceId, task, pulledAtMs)) {
                    is Decision.Ack -> {
                        acks += decision.ack
                        if (decision.newlyAdmitted) fresh += (decision.ack as CloudTaskAck.Admitted).admissionId
                    }
                    Decision.Defer -> deferred++
                }
            }
            // The journal already holds these records whatever happens to the ack.
            tally.admittedIds += fresh
            tally.deferred += deferred
            for (chunk in acks.chunked(CloudTaskWire.MAX_ACKS)) {
                if (Thread.currentThread().isInterrupted) throw InterruptedException()
                when (val reply = client.ack(deviceId, chunk)) {
                    is CloudTaskReply.Ok -> tally.acksAccepted += reply.value.results.count { it.accepted }
                    else -> return failure(reply, tally)
                }
            }
            // A transient refusal (journal full, store locked) will not clear inside this pass.
            if (deferred > 0) break
        }
        if (drained) prunePreviousKeys()
        return tally.report(CloudTaskPassStatus.COMPLETED)
    }

    private sealed interface Decision {
        class Ack(val ack: CloudTaskAck, val newlyAdmitted: Boolean = false) : Decision

        data object Defer : Decision
    }

    /** §7 for one task. */
    private fun decide(deviceId: String, task: CloudTaskPulled, nowMs: Long): Decision {
        if (task.expiresAtMs - nowMs < CloudTaskWire.MIN_REMAINING_MS) {
            return Decision.Ack(CloudTaskAck.Expired(task.taskId))
        }
        val stored = try {
            keys.load(task.keyId)
        } catch (_: IOException) {
            return Decision.Defer
        }
        val record = stored?.let { CloudTaskIdentity.decodeRecord(task.keyId, it) }
            ?: return Decision.Ack(CloudTaskAck.Rejected(task.taskId, CloudTaskRejectReason.KEY_UNKNOWN))

        val aad = CloudTaskCrypto.aad(deviceId, task.keyId, task.requestId, task.target, task.expiresAtMs)
        // Bytes that open but are not 1–16384 bytes of valid UTF-8 are not a task text (§7).
        val opened = try {
            CloudTaskCrypto.openText(record.pair, task.sealed, aad)
        } catch (_: CloudTaskOpenException) {
            null
        }
        val text = opened
            ?: return Decision.Ack(CloudTaskAck.Rejected(task.taskId, CloudTaskRejectReason.DECRYPT_FAILED))

        val exists = try {
            targets.exists(task.target)
        } catch (_: Exception) {
            return Decision.Defer
        }
        if (!exists) return Decision.Ack(CloudTaskAck.Rejected(task.taskId, CloudTaskRejectReason.TARGET_MISSING))

        val admission = try {
            admitter.admit(CloudTaskAdmissionRequest(deviceId, task.taskId, task.target, text, task.expiresAtMs))
        } catch (_: Exception) {
            return Decision.Defer
        }
        return when (admission.result) {
            CloudTaskAdmissionResult.ADMITTED, CloudTaskAdmissionResult.DUPLICATE -> {
                val admissionId = admission.admissionId?.takeIf(CloudTaskWire::isAdmissionId)
                    ?: return Decision.Defer
                Decision.Ack(
                    CloudTaskAck.Admitted(task.taskId, admissionId),
                    newlyAdmitted = admission.result == CloudTaskAdmissionResult.ADMITTED,
                )
            }
            CloudTaskAdmissionResult.INVALID ->
                Decision.Ack(CloudTaskAck.Rejected(task.taskId, CloudTaskRejectReason.INVALID))
            CloudTaskAdmissionResult.CONFLICT ->
                Decision.Ack(CloudTaskAck.Rejected(task.taskId, CloudTaskRejectReason.CONFLICT))
            CloudTaskAdmissionResult.CAPACITY, CloudTaskAdmissionResult.STORAGE -> Decision.Defer
        }
    }

    // ---- registration (§2)

    /**
     * Makes sure the cloud holds this device with a key whose private half is
     * in the key store. Once per process (and again after `404 not_found`):
     * read the device list, reuse the registered key when its record is here,
     * otherwise create one, save it, then `PUT`. Returns a report on failure.
     */
    private fun ensureRegistered(deviceId: String, tally: Tally): CloudTaskPassReport? {
        val wantedToken = fcmToken()?.takeIf(CloudTaskWire::isFcmToken)
        var effectiveToken = wantedToken?.takeUnless { it == unsupportedFcmToken }
        if (registeredKeyId != null && registeredFcmToken == effectiveToken) return null
        val mine = when (val reply = client.listDevices()) {
            is CloudTaskReply.Ok -> reply.value.devices.firstOrNull { it.deviceId == deviceId }
            else -> return failure(reply, tally)
        }
        var record = unsentRecord
        try {
            if (record == null && mine != null) {
                record = keys.load(mine.key.keyId)
                    ?.let { CloudTaskIdentity.decodeRecord(mine.key.keyId, it) }
                    ?.takeIf { it.pair.publicKey.contentEquals(mine.key.publicKey) }
            }
            if (record == null) {
                record = lastKeyId?.let { id -> keys.load(id)?.let { CloudTaskIdentity.decodeRecord(id, it) } }
            }
            if (record == null) {
                val created = CloudTaskKeyRecord(newKeyId(), newKeyPair(), clock())
                // Saved before it is registered: the cloud must never hold a key this phone lost.
                keys.save(created.keyId, CloudTaskIdentity.encodeRecord(created))
                record = created
            }
        } catch (_: IOException) {
            return tally.report(CloudTaskPassStatus.KEY_STORE_UNAVAILABLE)
        }
        unsentRecord = record
        fun register(key: CloudTaskPublicKey): CloudTaskReply<CloudTaskDeviceAck> {
            val reply = client.registerDevice(deviceId, appVersion, key, effectiveToken)
            if (effectiveToken != null && reply is CloudTaskReply.Refused &&
                reply.status == 400 && reply.code == "invalid_request"
            ) {
                val legacy = client.registerDevice(deviceId, appVersion, key)
                if (legacy is CloudTaskReply.Ok) {
                    unsupportedFcmToken = effectiveToken
                    effectiveToken = null
                }
                return legacy
            }
            return reply
        }
        var reply = register(record.public)
        if (reply is CloudTaskReply.Refused && reply.status == 409 && reply.code == "key_mismatch") {
            // §2: the cloud holds another key under this `key_id`. A `key_id` names one key, so
            // create a new key with a new id and register again — once; a second refusal is reported.
            val replaced = record.keyId
            val created = CloudTaskKeyRecord(newKeyId(), newKeyPair(), clock())
            try {
                keys.save(created.keyId, CloudTaskIdentity.encodeRecord(created))
            } catch (_: IOException) {
                return tally.report(CloudTaskPassStatus.KEY_STORE_UNAVAILABLE)
            }
            previousKeyIds += replaced
            record = created
            unsentRecord = created
            reply = register(created.public)
        }
        return when (reply) {
            is CloudTaskReply.Ok -> {
                // Tasks sealed to a replaced key are rejected by the cloud (`key_replaced`);
                // its record stays until a pull came back empty.
                if (mine != null && mine.key.keyId != record.keyId) previousKeyIds += mine.key.keyId
                lastKeyId?.let { if (it != record.keyId) previousKeyIds += it }
                registeredKeyId = record.keyId
                registeredFcmToken = effectiveToken
                lastKeyId = record.keyId
                unsentRecord = null
                null
            }
            else -> failure(reply, tally)
        }
    }

    /** No pending task names a previous key any more: drop those records. */
    private fun prunePreviousKeys() {
        val current = registeredKeyId ?: return
        val iterator = previousKeyIds.iterator()
        while (iterator.hasNext()) {
            val keyId = iterator.next()
            if (keyId == current) {
                iterator.remove()
                continue
            }
            try {
                keys.delete(keyId)
                iterator.remove()
            } catch (_: IOException) {
                // Kept for the next drained pass.
            }
        }
    }

    // ---- terminal acks (§6, §7)

    private fun sendTerminals(deviceId: String, tally: Tally): CloudTaskPassReport? {
        if (Thread.currentThread().isInterrupted) throw InterruptedException()
        repeat(MAX_TERMINAL_BATCHES) {
            val offered = try {
                terminals.pending(deviceId, CloudTaskWire.MAX_ACKS)
            } catch (_: Exception) {
                emptyList()
            }
            val batch = offered.take(CloudTaskWire.MAX_ACKS).filter { terminalAck(it) != null }.distinctBy { it.taskId }
            if (batch.isEmpty()) return null
            val settledBefore = tally.terminalsSettled

            val results = when (val reply = client.ack(deviceId, batch.map { terminalAck(it)!! })) {
                is CloudTaskReply.Ok -> reply.value.results
                else -> return failure(reply, tally)
            }
            // `pending` after a terminal ack: the cloud never saw the `admitted` ack. Send it, then repeat.
            val unseen = ArrayList<CloudTaskTerminal>()
            batch.forEachIndexed { index, terminal ->
                if (!settle(results[index], tally) && results[index].state == CloudTaskState.PENDING) unseen += terminal
            }
            if (unseen.isNotEmpty()) {
                when (val reply = client.ack(deviceId, unseen.map { CloudTaskAck.Admitted(it.taskId, it.admissionId) })) {
                    is CloudTaskReply.Ok -> Unit
                    else -> return failure(reply, tally)
                }
                when (val reply = client.ack(deviceId, unseen.map { terminalAck(it)!! })) {
                    is CloudTaskReply.Ok -> reply.value.results.forEach { settle(it, tally) }
                    else -> return failure(reply, tally)
                }
            }
            // Nothing settled (for example every ack `not_found`): the same records would come back.
            if (offered.size < CloudTaskWire.MAX_ACKS || tally.terminalsSettled == settledBefore) return null
        }
        return null
    }

    /** True when the cloud's answer is final for this task and the record was told so. */
    private fun settle(result: CloudTaskAckResult, tally: Tally): Boolean {
        // Accepted (first or duplicate), or first-wins elsewhere: it will never change. `not_found`
        // is not final (§5): it is also the answer while this device is not registered to the
        // caller, so the record is kept and sent again on a later pass.
        val final = result.accepted || result.state !in
            setOf(CloudTaskState.PENDING, CloudTaskState.ADMITTED, CloudTaskState.NOT_FOUND)
        if (!final) return false
        try {
            terminals.settled(result.taskId, result.state)
            tally.terminalsSettled++
        } catch (_: Exception) {
            // Offered again on the next pass.
        }
        if (result.accepted) tally.acksAccepted++
        return true
    }

    private fun terminalAck(terminal: CloudTaskTerminal): CloudTaskAck? {
        if (!CloudTaskWire.isOpaqueId(terminal.taskId) || !CloudTaskWire.isAdmissionId(terminal.admissionId)) return null
        return CloudTaskWire.terminalAck(terminal.taskId, terminal.stage, terminal.reason)
    }

    // ---- failures

    private fun failure(reply: CloudTaskReply<*>, tally: Tally): CloudTaskPassReport = when (reply) {
        is CloudTaskReply.Refused -> tally.report(CloudTaskPassStatus.REFUSED, reply)
        CloudTaskReply.RouteMissing -> {
            unavailableUntilMs = clock() + unavailableHoldMs
            tally.report(CloudTaskPassStatus.UNAVAILABLE)
        }
        CloudTaskReply.NoCredential -> tally.report(CloudTaskPassStatus.NO_CREDENTIAL)
        CloudTaskReply.Unreachable -> tally.report(CloudTaskPassStatus.UNREACHABLE)
        CloudTaskReply.ProtocolError, is CloudTaskReply.Ok -> tally.report(CloudTaskPassStatus.PROTOCOL_ERROR)
    }

    private companion object {
        const val LEASE_SECONDS = 300
        const val MAX_REPEATS = 2
        const val MAX_TERMINAL_BATCHES = 4
    }
}
