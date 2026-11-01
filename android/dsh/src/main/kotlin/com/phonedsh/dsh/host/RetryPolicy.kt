// phone-dsh — :dsh / com.phonedsh.dsh.host: the retry schedule's numbers.
// SPDX-License-Identifier: MIT
//
// budgets.md §2 obliges `Running -> Backoff` to "start the retry schedule" and
// gates `Backoff -> Running` on "Retry-After elapsed". The spec fixes neither
// the schedule nor what a Retry-After is when the entry had no HTTP response,
// so the numbers live here, beside the lane that uses them, instead of being
// spread through the facade as literals:
//
//   * the exponential shape, the 60 s cap, the 20 % downward jitter and the
//     five-attempt reference point are the Swift reference's
//     `ModelGatewayBackoffPolicy` defaults (Sources/PhoneDSHGateway/
//     ModelGateway.swift), so the two ports retry with the same rhythm;
//   * a `Retry-After` hint (an upstream header) wins over the schedule and is
//     clamped to the cap, exactly as the Swift policy does;
//   * §2 has no edge out of `Backoff` for "the retries are used up" and §1 calls
//     the state a healthy wait, so [delayFor] **saturates** at
//     `maximumDelayMillis` after `maximumAttempts` instead of giving up: the
//     schedule keeps proposing one probe per window, forever. Giving up would
//     need a D14 row that does not exist.
//
// Jitter is a randomization of a *duration*, so the lane measures the window
// monotonically (Clock's KDoc: "backoff jitter and elapsed-time telemetry are
// measured monotonically"); the wall clock is used only for the persisted
// `backoff_until_ms` deadline of a boot that restores `Backoff`.

package com.phonedsh.dsh.host

import kotlin.random.Random

/**
 * When the next retry probe may run.
 *
 * @param initialDelayMillis delay before the first probe of an entry.
 * @param multiplier growth factor applied per attempt; values below 1 are
 *   raised to 1 so a schedule can never shrink.
 * @param maximumDelayMillis cap of one window, jitter included.
 * @param jitterFraction fraction randomized *downward* into
 *   `delay·(1−jitter) … delay`; `0` disables jitter (deterministic tests).
 * @param maximumAttempts the attempt at which growth stops; the delay stays at
 *   the cap afterwards. `1` means "always the initial delay".
 */
data class RetryPolicy(
    val initialDelayMillis: Long = 1_000L,
    val multiplier: Int = 2,
    val maximumDelayMillis: Long = 60_000L,
    val jitterFraction: Double = 0.2,
    val maximumAttempts: Int = 5,
) {
    init {
        require(initialDelayMillis >= 0L) {
            "initialDelayMillis must be non-negative, was $initialDelayMillis"
        }
        require(multiplier >= 1) { "multiplier must be at least 1, was $multiplier" }
        require(maximumDelayMillis >= initialDelayMillis) {
            "maximumDelayMillis must be at least initialDelayMillis, was $maximumDelayMillis"
        }
        require(jitterFraction in 0.0..1.0) {
            "jitterFraction must be in 0.0..1.0, was $jitterFraction"
        }
        require(maximumAttempts >= 1) {
            "maximumAttempts must be at least 1, was $maximumAttempts"
        }
    }

    /**
     * Delay before attempt [attempt] (`1` is the first probe of this entry).
     *
     * @param retryAfterMillis an upstream `Retry-After` hint; when present it
     *   wins over the exponential schedule and is clamped to
     *   [maximumDelayMillis]. A `null` hint is the NWPath entry, which has no
     *   HTTP response and therefore no header (see [RetryLane]).
     * @param randomDouble one draw in `[0, 1)`; injected so a test pins the
     *   jitter instead of racing it.
     */
    fun delayFor(
        attempt: Int,
        retryAfterMillis: Long? = null,
        randomDouble: () -> Double = { Random.nextDouble() },
    ): Long {
        val wanted = maxOf(1, attempt)
        if (retryAfterMillis != null) {
            return retryAfterMillis.coerceIn(0L, maximumDelayMillis)
        }
        val steps = minOf(wanted, maximumAttempts) - 1
        var exponential = initialDelayMillis.toDouble()
        repeat(steps) {
            exponential *= multiplier.toDouble()
            if (exponential > maximumDelayMillis.toDouble()) exponential = maximumDelayMillis.toDouble()
        }
        val capped = minOf(maximumDelayMillis.toLong(), exponential.toLong())
        if (jitterFraction <= 0.0) return capped
        val draw = randomDouble().coerceIn(0.0, 1.0)
        val low = 1.0 - jitterFraction
        return (capped * (low + draw * jitterFraction)).toLong().coerceAtLeast(0L)
    }

    companion object {
        /** The default schedule; see the file header for where the numbers come from. */
        val DEFAULT: RetryPolicy = RetryPolicy()
    }
}
