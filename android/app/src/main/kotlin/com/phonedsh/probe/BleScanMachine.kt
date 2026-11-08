// SPDX-License-Identifier: MIT
package com.phonedsh.probe

import com.phonedsh.domain.connector.ble.*
import java.util.UUID
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/** Events and state transitions are serialized by the Android main thread. */
internal interface BleScanPlatform {
    interface Callback {
        fun result(key: Any, name: String?, rssi: Int)
        fun failed()
    }
    fun supported(): Boolean
    fun enabled(): Boolean
    fun permitted(): Boolean
    fun requestPermission(key: String)
    /** Calls completion on the main thread after start returns on a serial worker. */
    fun start(callback: Callback, completion: (Boolean) -> Unit)
    fun stop(callback: Callback, completion: (Boolean) -> Unit)
    fun now(): Long
    fun timeout(action: () -> Unit): () -> Unit
}

/** One instance per app process; quarantine and in-flight start survive activities. */
internal class BleScanMachine(private val platform: BleScanPlatform) {
    private val mutable = MutableStateFlow(BleScanSnapshot())
    val state: StateFlow<BleScanSnapshot> = mutable.asStateFlow()
    var onChange: (BleScanSnapshot) -> Unit = {}
    var dispatch: (() -> Unit) -> Unit = { it() }
    private var generation = 0L
    private var permissionKey: String? = null
    private var permissionOwner: Long? = null
    private var ownerLive: () -> Boolean = { true }
    private var active: BleScanPlatform.Callback? = null
    private var startInFlight = false
    private var stopInFlight = false
    private var finishingPhase = BleScanPhase.STOPPED
    private var finishingFailure: BleScanFailure? = null
    private var quarantined = false
    // Preserve the platform and callback for the lifetime of this process.
    private var quarantineCallback: BleScanPlatform.Callback? = null
    private var cancelTimer: (() -> Unit)? = null
    private var deadlineMs: Long? = null
    private val keys = LinkedHashMap<Any, Int>()

    fun start(requestPermission: (String) -> Unit = platform::requestPermission, live: () -> Boolean = { true }) {
        if (quarantined || active != null || startInFlight || stopInFlight || state.value.phase == BleScanPhase.REQUESTING_PERMISSION) return
        ownerLive = live
        generation++
        keys.clear()
        publish(BleScanPhase.IDLE, emptyList())
        if (!ownerLive()) return
        if (permissionKey != null) { publish(BleScanPhase.PERMISSION_PENDING); return }
        try {
            if (!platform.supported()) { publish(BleScanPhase.UNSUPPORTED); return }
            if (!platform.enabled()) { publish(BleScanPhase.BLUETOOTH_OFF); return }
            if (!platform.permitted()) {
                val key = "pdsh-ble-" + UUID.randomUUID().toString()
                permissionKey = key; permissionOwner = generation
                publish(BleScanPhase.REQUESTING_PERMISSION)
                if (!ownerLive()) { permissionKey = null; permissionOwner = null; return }
                try { requestPermission(key) } catch (_: RuntimeException) {
                    permissionKey = null; permissionOwner = null
                    publish(BleScanPhase.FAILED, failure = BleScanFailure.START_FAILED)
                }
                return
            }
            if (ownerLive()) begin(generation)
        } catch (_: RuntimeException) {
            publish(BleScanPhase.FAILED, failure = BleScanFailure.START_FAILED)
        }
    }

    fun pendingPermissionKey(): String? = permissionKey

    /** Unknown/restored keys are consumed without assigning them a new owner. */
    fun permissionResult(key: String) {
        if (permissionKey != key) return
        val owner = permissionOwner
        permissionKey = null; permissionOwner = null
        if (owner != generation || state.value.phase != BleScanPhase.REQUESTING_PERMISSION) {
            publish(BleScanPhase.STOPPED)
            return
        }
        if (!ownerLive()) { publish(BleScanPhase.STOPPED); return }
        try {
            if (!platform.permitted()) { publish(BleScanPhase.PERMISSION_DENIED); return }
            if (!platform.supported()) { publish(BleScanPhase.UNSUPPORTED); return }
            if (!platform.enabled()) { publish(BleScanPhase.BLUETOOTH_OFF); return }
            if (ownerLive()) begin(generation)
        } catch (_: RuntimeException) { publish(BleScanPhase.FAILED, failure = BleScanFailure.START_FAILED) }
    }

    private fun begin(owner: Long) {
        val deadline = platform.now() + 15_000L
        val callback = object : BleScanPlatform.Callback {
            override fun result(key: Any, name: String?, rssi: Int) {
                dispatch { handleResult(key, name, rssi) }
            }
            private fun handleResult(key: Any, name: String?, rssi: Int) {
                if (generation != owner || active !== this || state.value.phase != BleScanPhase.SCANNING) return
                if (!ownerLive()) { finish(BleScanPhase.STOPPED); return }
                if (platform.now() >= deadline) { finish(BleScanPhase.STOPPED); return }
                if (!permissionValid()) { finish(BleScanPhase.FAILED, BleScanFailure.PERMISSION_REVOKED); return }
                val old = state.value.candidates
                val index = keys[key]
                if (index == null && old.size >= 100) return
                val entry = BleScanCandidate(index?.let { old[it].id } ?: UUID.randomUUID().toString(), safeName(name), rssi)
                val updated = old.toMutableList()
                if (index == null) { keys[key] = updated.size; updated.add(entry) } else updated[index] = entry
                publish(BleScanPhase.SCANNING, updated)
            }
            override fun failed() {
                dispatch { handleFailure() }
            }
            private fun handleFailure() {
                if (generation == owner && active === this) {
                    if (!ownerLive() || platform.now() >= deadline) finish(BleScanPhase.STOPPED)
                    else finish(BleScanPhase.FAILED, BleScanFailure.SCAN_FAILED)
                }
            }
        }
        active = callback; startInFlight = true
        publish(BleScanPhase.STARTING)
        if (!ownerLive()) { active = null; startInFlight = false; return }
        deadlineMs = deadline
        cancelTimer = platform.timeout {
            dispatch { if (generation == owner && active === callback) finish(BleScanPhase.STOPPED) }
        }
        val completed: (Boolean) -> Unit = { success ->
            startInFlight = false
            if (!success) {
                cancelTimer?.invoke(); cancelTimer = null
                generation++; active = null; quarantined = true; quarantineCallback = callback
                publish(BleScanPhase.CLEANUP_REQUIRED, failure = BleScanFailure.START_FAILED)
            } else if (generation != owner) {
                finishStop(callback, finishingPhase, finishingFailure)
            } else if (!ownerLive()) {
                finish(BleScanPhase.STOPPED)
            } else if (!permissionValid()) {
                finish(BleScanPhase.FAILED, BleScanFailure.PERMISSION_REVOKED)
            } else if (platform.now() >= deadline) {
                finish(BleScanPhase.STOPPED)
            } else {
                publish(BleScanPhase.SCANNING)
            }
        }
        try { platform.start(callback) { success -> dispatch { completed(success) } } }
        catch (_: RuntimeException) { completed(false) }
    }

    fun stop() {
        if (!quarantined && state.value.phase != BleScanPhase.STOPPING) finish(BleScanPhase.STOPPED)
    }

    fun close() { stop(); keys.clear(); publish(state.value.phase, emptyList(), state.value.failure) }

    /** Called only by the coordinator for the lease that owns these labels. */
    fun discardRetainedCandidates() {
        keys.clear()
        mutable.value = state.value.copy(candidates = emptyList())
    }
    internal fun retainedKeyCount(): Int = keys.size

    /**
     * The platform key behind one retained candidate id, for the coordinator's
     * owning lease only (connect). Never displayed, logged or persisted.
     */
    internal fun platformKey(candidateId: String): Any? {
        val index = state.value.candidates.indexOfFirst { it.id == candidateId }
        if (index < 0) return null
        return keys.entries.firstOrNull { it.value == index }?.key
    }

    /** Reconcile the elapsed-realtime deadline when the host becomes runnable. */
    fun checkDeadline() {
        val deadline = deadlineMs ?: return
        if (active == null) return
        if (!ownerLive()) finish(BleScanPhase.STOPPED)
        else if (!permissionValid()) finish(BleScanPhase.FAILED, BleScanFailure.PERMISSION_REVOKED)
        else if (platform.now() >= deadline) finish(BleScanPhase.STOPPED)
    }

    private fun permissionValid(): Boolean = try { platform.permitted() } catch (_: RuntimeException) { false }

    private fun finish(phase: BleScanPhase, failure: BleScanFailure? = null) {
        generation++
        cancelTimer?.invoke(); cancelTimer = null
        deadlineMs = null
        val callback = active
        if (callback == null) { publish(phase, failure = failure); return }
        finishingPhase = phase; finishingFailure = failure
        if (startInFlight) { publish(BleScanPhase.STOPPING); return }
        finishStop(callback, phase, failure)
    }

    private fun finishStop(callback: BleScanPlatform.Callback, phase: BleScanPhase, failure: BleScanFailure?) {
        active = null
        stopInFlight = true
        publish(BleScanPhase.STOPPING)
        val completed: (Boolean) -> Unit = { success ->
            stopInFlight = false
            if (!success) {
                quarantined = true; quarantineCallback = callback
                publish(BleScanPhase.CLEANUP_REQUIRED, failure = BleScanFailure.STOP_FAILED)
            } else publish(phase, failure = failure)
        }
        try { platform.stop(callback) { success -> dispatch { completed(success) } } }
        catch (_: RuntimeException) { completed(false) }
    }

    private fun publish(phase: BleScanPhase, candidates: List<BleScanCandidate> = state.value.candidates,
                        failure: BleScanFailure? = null) {
        mutable.value = BleScanSnapshot(phase, candidates.toList(), failure)
        onChange(mutable.value)
    }
}

internal fun safeName(value: String?): String {
    if (value.isNullOrEmpty()) return "未命名 BLE 设备"
    val result = StringBuilder()
    var index = 0; var scalars = 0
    while (index < value.length && scalars < 128) {
        val c = value[index++]
        if (c.isHighSurrogate()) {
            if (index < value.length && value[index].isLowSurrogate()) result.append(c).append(value[index++])
            else result.append('\uFFFD')
        } else if (c.isLowSurrogate()) result.append('\uFFFD') else result.append(c)
        scalars++
    }
    return result.toString()
}
