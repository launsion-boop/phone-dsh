// Host-JVM tests: the two clock readings come from injected lambdas.
// SPDX-License-Identifier: MIT

package com.phonedsh.platform.android

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class AndroidClockTest {

    @Test
    fun bothReadingsComeFromTheInjectedSources() {
        val clock = AndroidClock(
            wall = { 1_700_000_000_123L },
            monotonic = { 4_242L },
        )

        assertEquals(1_700_000_000_123L, clock.nowMillis())
        assertEquals(4_242L, clock.monotonicMillis())
    }

    @Test
    fun theMonotonicReadingFollowsItsSourceInsteadOfTheWallClock() {
        var monotonic = 0L
        val clock = AndroidClock(wall = { 1L }, monotonic = { monotonic })

        monotonic = 10L
        assertEquals(10L, clock.monotonicMillis())
        assertEquals("a wall-clock jump must not move the monotonic source", 1L, clock.nowMillis())

        monotonic = 20L
        assertEquals(20L, clock.monotonicMillis())
    }

    @Test
    fun theDefaultWallSourceIsTheSystemClock() {
        // System.currentTimeMillis() is real on a host JVM; only the monotonic
        // default (SystemClock) is device-only, so it is never called here.
        val clock = AndroidClock(monotonic = { 0L })

        assertTrue("the wall clock default did not read the system time", clock.nowMillis() > 1_600_000_000_000L)
    }
}
