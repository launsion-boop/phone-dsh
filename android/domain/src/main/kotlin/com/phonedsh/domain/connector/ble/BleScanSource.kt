// SPDX-License-Identifier: MIT
package com.phonedsh.domain.connector.ble

import kotlinx.coroutines.flow.StateFlow

/** A transient, unauthenticated BLE advertisement; not a device identity. */
data class BleScanCandidate(val id: String, val name: String, val rssi: Int) {
    override fun toString(): String = "BleScanCandidate(redacted)"
}

enum class BleScanPhase {
    IDLE, HOST_INACTIVE, BUSY, REQUESTING_PERMISSION, PERMISSION_PENDING, STARTING, SCANNING, STOPPING, STOPPED, PERMISSION_DENIED,
    BLUETOOTH_OFF, UNSUPPORTED, FAILED, CLEANUP_REQUIRED,
}

enum class BleScanFailure { START_FAILED, SCAN_FAILED, PERMISSION_REVOKED, STOP_FAILED }

data class BleScanSnapshot(
    val phase: BleScanPhase = BleScanPhase.IDLE,
    val candidates: List<BleScanCandidate> = emptyList(),
    val failure: BleScanFailure? = null,
) {
    override fun toString(): String = "BleScanSnapshot(phase=$phase, candidates=redacted, failure=$failure)"
}

/** One Activity-owned facade. Host lifecycle methods never act on another host. */
interface BleScanSource {
    fun open(): BleScanSession
    fun hostStarted()
    fun hostStopped()
}

/** One non-reusable page lease; actions and state are scoped to its owner. */
interface BleScanSession {
    val state: StateFlow<BleScanSnapshot>
    fun start()
    fun stop()
    /** Invalidates scanning and clears ephemeral candidates on page disposal. */
    fun close()
}
