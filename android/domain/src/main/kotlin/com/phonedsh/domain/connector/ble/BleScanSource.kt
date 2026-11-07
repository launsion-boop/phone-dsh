// SPDX-License-Identifier: MIT
package com.phonedsh.domain.connector.ble

import kotlinx.coroutines.flow.StateFlow

/** A transient, unauthenticated BLE advertisement; not a device identity. */
data class BleScanCandidate(val id: String, val name: String, val rssi: Int)

enum class BleScanPhase {
    IDLE, REQUESTING_PERMISSION, PERMISSION_PENDING, STARTING, SCANNING, STOPPING, STOPPED, PERMISSION_DENIED,
    BLUETOOTH_OFF, UNSUPPORTED, FAILED, CLEANUP_REQUIRED,
}

enum class BleScanFailure { START_FAILED, SCAN_FAILED, PERMISSION_REVOKED, STOP_FAILED }

data class BleScanSnapshot(
    val phase: BleScanPhase = BleScanPhase.IDLE,
    val candidates: List<BleScanCandidate> = emptyList(),
    val failure: BleScanFailure? = null,
)

/** Main-thread user actions. Implementations own lifecycle and permission checks. */
interface BleScanSource {
    val state: StateFlow<BleScanSnapshot>
    fun start()
    fun stop()
    /** Invalidates scanning and clears ephemeral candidates on page disposal. */
    fun close()
}
