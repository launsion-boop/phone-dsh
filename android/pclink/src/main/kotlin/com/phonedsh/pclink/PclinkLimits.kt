// SPDX-License-Identifier: MIT
// Frozen PCLink v1 limits and timers (§3.5, §4.6, §5.4, §5.5, §6.2, §10).
package com.phonedsh.pclink

import java.time.Duration

object PclinkLimits {
    // ---- Frame/value/chunk caps (§3.1, §6.1, §6.2) ----------------------
    const val MAX_RELAY_FRAME_BYTES: Int = 16 shl 20 // 16 MiB
    const val MAX_VALUE_BYTES: Int = 8 shl 20 // 8 MiB
    const val CHUNK_THRESHOLD_BYTES: Int = 1 shl 20 // 1 MiB
    const val MAX_CHUNK_CHARACTERS: Int = 1_500_000
    val CHUNK_REASSEMBLY_TIMEOUT: Duration = Duration.ofSeconds(30)

    // ---- Rekey / hard caps (§5.4, §5.5) --------------------------------
    const val SOFT_FRAME_THRESHOLD: Long = 1L shl 19 // 524,288
    const val HARD_FRAME_THRESHOLD: Long = 1L shl 20 // 1,048,576
    const val SOFT_BYTE_THRESHOLD: Long = 1L shl 30 // 1 GiB
    const val HARD_BYTE_THRESHOLD: Long = 1L shl 31 // 2 GiB

    // ---- Sender pacing (§3.8) ------------------------------------------
    // The reference values sit below the relay's 1 MiB/s, 4 MiB pair bucket so
    // relay overhead and handshake frames fit inside the same bucket.
    const val SEND_RATE_BYTES_PER_SECOND: Double = 0.9 * 1024 * 1024
    const val SEND_BURST_BYTES: Double = 3.5 * 1024 * 1024

    // ---- Handshake / pairing (§5.1, §5.2, §4.3, §4.6) ------------------
    val HANDSHAKE_STEP_TIMEOUT: Duration = Duration.ofSeconds(10)
    /** Legacy name: the maximum wait for `pair.confirm` (auto-approved in v1.6). */
    val PAIRING_APPROVAL_TIMEOUT: Duration = Duration.ofSeconds(120)
    val PAIRING_SLOT_LIFETIME: Duration = Duration.ofSeconds(300)
    const val PAIRING_JOIN_LIMIT: Int = 10
    const val PAIRING_SLOTS_PER_CONNECTION: Int = 2
    const val PC_SID_CACHE_LIMIT: Int = 4096
    val PC_SID_CACHE_LIFETIME: Duration = Duration.ofSeconds(300)
    const val PC_PENDING_HANDSHAKE_LIMIT: Int = 64
    val PC_E2E_IDLE_TIMEOUT: Duration = Duration.ofMinutes(15)
    val RELAY_PHONE_IDLE_TIMEOUT: Duration = Duration.ofMinutes(10)
    val RECONNECT_RESET_AFTER: Duration = Duration.ofSeconds(60)
    const val PAIRING_QR_LENGTH_LIMIT: Int = 512
    const val MAX_PAIRING_RECORDS: Int = 1024
    val HEARTBEAT_RANGE: IntRange = 20..30 // seconds
}
