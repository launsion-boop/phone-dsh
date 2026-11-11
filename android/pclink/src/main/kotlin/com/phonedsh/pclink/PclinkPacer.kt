// SPDX-License-Identifier: MIT
// Sender-side pacing for established `e2e` frames (§3.8, `pclink-v1.5`).
//
// The relay's pair bucket is a drop boundary, not a queue: a sender that emits a
// bulk result faster than the pair rate loses a frame, and a lost `e2e` frame
// breaks the receiver's contiguous `seq` (§5.4). The phone therefore acquires
// local tokens before writing an application frame. This type is the pure token
// bucket; the relay client's single send writer is its only caller, so a wait
// never lets a later `seq` overtake an earlier one and a frame is never dropped,
// coalesced or split.
//
// The clock is monotonic (`System.nanoTime`), not wall time: a clock jump must
// neither overdraw nor stall the bucket. Tests pass explicit nanoseconds.
package com.phonedsh.pclink

/**
 * One local token bucket with the relay's full-bucket single-frame overdraft
 * (§3.8, §3.5). Not thread-safe: a connection has exactly one send writer.
 */
class PclinkPacer(
    val rateBytesPerSecond: Double = PclinkLimits.SEND_RATE_BYTES_PER_SECOND,
    val burstBytes: Double = PclinkLimits.SEND_BURST_BYTES,
    private val clockNanos: () -> Long = System::nanoTime,
) {
    init {
        require(rateBytesPerSecond > 0 && burstBytes > 0) {
            "pacing values must be positive"
        }
    }

    private var tokens: Double = burstBytes
    private var lastRefillNanos: Long? = null

    /** Current balance; negative only after an approved overdraft. */
    val availableTokens: Double get() = tokens

    /**
     * Refill at [nowNanos], clamped to [burstBytes]. A negative balance
     * (approved overdraft) recovers at the configured rate; the clamp only
     * applies above the burst, so paying back the debt is not lost.
     */
    fun refill(nowNanos: Long = clockNanos()) {
        val last = lastRefillNanos
        if (last == null) {
            lastRefillNanos = nowNanos
            return
        }
        if (nowNanos > last) {
            tokens = minOf(burstBytes, tokens + (nowNanos - last) / 1_000_000_000.0 * rateBytesPerSecond)
            lastRefillNanos = nowNanos
        }
    }

    /**
     * Nanoseconds to wait before [bytes] may be written; does not consume
     * tokens. A frame larger than the burst waits for a full bucket and then
     * overdraws (§3.8), exactly like the relay's single-frame rule.
     */
    fun delayBeforeSending(bytes: Int, nowNanos: Long = clockNanos()): Long {
        refill(nowNanos)
        val cost = maxOf(0, bytes).toDouble()
        if (cost <= tokens + TOLERANCE) return 0
        if (cost > burstBytes && tokens >= burstBytes - TOLERANCE) return 0
        val required = if (cost > burstBytes) burstBytes else cost
        val seconds = (required - tokens) / rateBytesPerSecond
        if (seconds <= 0) return 0
        return maxOf(1L, Math.ceil(seconds * 1_000_000_000.0).toLong())
    }

    /** Charge one approved frame; may go negative only after an overdraft. */
    fun consume(bytes: Int, nowNanos: Long = clockNanos()) {
        refill(nowNanos)
        tokens -= maxOf(0, bytes).toDouble()
    }

    companion object {
        /** 0.9 MiB/s: margin under the relay's 1 MiB/s pair rate. */
        const val REFERENCE_RATE_BYTES_PER_SECOND: Double = PclinkLimits.SEND_RATE_BYTES_PER_SECOND

        /** 3.5 MiB: margin under the relay's 4 MiB pair burst. */
        const val REFERENCE_BURST_BYTES: Double = PclinkLimits.SEND_BURST_BYTES

        private const val TOLERANCE = 1e-9
    }
}
