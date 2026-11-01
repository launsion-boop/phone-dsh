// Wall and monotonic time over the Android clock sources.
// SPDX-License-Identifier: MIT
//
// The two readings are deliberately separate OS sources: deadlines and
// Retry-After use wall time, while the 20 s drain, backoff jitter and elapsed
// telemetry are measured monotonically (spec/v1/budgets.md §2, §4). On Android
// the monotonic source is `SystemClock.elapsedRealtime()`: it counts across deep
// sleep and is unaffected by the user or the network moving the wall clock.
// `uptimeMillis()` is not used because it stops during deep sleep and would
// under-count a drain that spans a suspended device.
//
// Both sources are injectable lambdas so the same class is exercised on a host
// JVM: `SystemClock` is a device-only stub there, and a fake clock is what the
// deadline tests above this layer need anyway.

package com.phonedsh.platform.android

import android.os.SystemClock
import com.phonedsh.platform.Clock

/**
 * [Clock] backed by `System.currentTimeMillis()` and
 * `SystemClock.elapsedRealtime()`.
 *
 * @param wall Unix epoch milliseconds; defaults to the wall clock.
 * @param monotonic milliseconds since boot including deep sleep; defaults to
 *   [SystemClock.elapsedRealtime].
 */
class AndroidClock(
    private val wall: () -> Long = { System.currentTimeMillis() },
    private val monotonic: () -> Long = { SystemClock.elapsedRealtime() },
) : Clock {
    override fun nowMillis(): Long = wall()

    override fun monotonicMillis(): Long = monotonic()
}
