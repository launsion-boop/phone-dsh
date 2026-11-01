// A deterministic Clock for the domain-store contract.
// SPDX-License-Identifier: MIT
//
// The store clamps `updated_at` to `max(clock, last + 1)`, so the interesting
// inputs are a clock that moves backwards and a clock that has not advanced
// since the previous write. The queue returns the scripted readings in order and
// then repeats the last one.

package com.phonedsh.domain

import com.phonedsh.platform.Clock

/** A [Clock] driven by a script of wall-clock readings. */
class FakeClock(vararg stamps: Long) : Clock {
    private val pending = stamps.toMutableList()
    private var current = pending.lastOrNull() ?: 0L

    override fun nowMillis(): Long {
        if (pending.isEmpty()) return current
        current = pending.removeAt(0)
        return current
    }

    /** The domain store never measures durations; this is the last wall reading. */
    override fun monotonicMillis(): Long = current
}
