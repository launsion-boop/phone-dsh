// Shared host-JVM fixtures for the build-seal lane.
// SPDX-License-Identifier: MIT
//
// A fake `/proc` that forgets a pid once it is signalled, and a fake `kill` that
// records what it was asked to do. Kept out of the test classes so the runtime
// suite and the reaper suite drive the same behaviour instead of two copies that
// drift.

package com.phonedsh.platform.android

/** A mutable `/proc`; a killed pid disappears from it. */
internal class FakeProc(entries: List<ProcEntry>) : ProcTable {
    val alive = entries.associateBy { it.pid }.toMutableMap()

    override fun entries(): List<ProcEntry> = alive.values.toList()
}

/**
 * A fake `kill(2)`.
 *
 * @param proc the table the signal acts on.
 * @param refusesToDie pids that stay alive whatever is sent (the unkillable case).
 */
internal class FakeSignals(
    private val proc: FakeProc,
    private val refusesToDie: Set<Int> = emptySet(),
) : SignalSender {
    val sent = mutableListOf<Pair<Int, Int>>()

    override fun send(pid: Int, signal: Int) {
        sent.add(pid to signal)
        if (pid < 0) {
            // A group kill reaches every member of that group.
            val group = -pid
            proc.alive.values.removeIf { it.pgrp == group }
            return
        }
        if (pid in refusesToDie) return
        proc.alive.remove(pid)
    }
}
