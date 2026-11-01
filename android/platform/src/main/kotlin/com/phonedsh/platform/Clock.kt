// Wall and monotonic time as one injectable OS primitive.
// SPDX-License-Identifier: MIT
//
// The host needs two different readings and must never substitute one for the
// other: D14 deadlines and Retry-After use wall time, while the 20 s drain,
// backoff jitter and elapsed-time telemetry are measured monotonically
// (spec/v1/budgets.md §2, §4). Production reads System.currentTimeMillis() and
// SystemClock.elapsedRealtime() inside the Android adapter; no other module is
// allowed to call the OS clock directly, so every deadline is testable on a JVM.

package com.phonedsh.platform

/**
 * The only time source the upper layers may observe.
 *
 * Both readings are milliseconds. Neither is a date, a timezone or a formatted
 * timestamp: formatting and trace normalisation happen above this layer.
 */
interface Clock {
    /**
     * Unix epoch milliseconds.
     *
     * May jump forwards or backwards when the user or the network changes the
     * wall clock; never use it to measure a duration.
     */
    fun nowMillis(): Long

    /**
     * Milliseconds since an arbitrary boot origin.
     *
     * Never goes backwards and is unaffected by wall-clock changes; use it for
     * deadlines, timeouts and any duration that must survive a clock jump.
     */
    fun monotonicMillis(): Long
}
