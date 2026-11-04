// Host-JVM tests for the process-tree reaper's decision making.
// SPDX-License-Identifier: MIT
//
// A fake `/proc` plus a fake `kill` is enough to prove the part that matters:
// the group is signalled before the pids, the app's own group is refused, a
// residual same-UID process is reported *and* killed, and a survivor that does
// not die is reported as unkillable instead of being counted as clean.
//
// The device suite (`BuildSealReaperDeviceTest`) proves the real `/proc` and the
// real `Os.kill`, including a background fork that outlives its parent.

package com.phonedsh.platform.android

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class BuildSealReaperTest {

    private val uid = 10_207
    private val selfPid = 3_790
    private val selfPgrp = 3_790

    private fun reaper(proc: FakeProc, signals: FakeSignals): ProcessTreeReaper = ProcessTreeReaper(
        uid = uid,
        selfPid = selfPid,
        selfPgrp = selfPgrp,
        table = proc,
        signal = signals,
    )

    private fun entry(pid: Int, ppid: Int, pgrp: Int, uid: Int = 10_207) =
        ProcEntry(pid = pid, ppid = ppid, pgrp = pgrp, uid = uid, name = "probe-$pid")

    @Test
    fun theGroupIsKilledBeforeTheIndividualPids() {
        val proc = FakeProc(
            listOf(
                entry(pid = 5_000, ppid = selfPid, pgrp = 5_000),
                entry(pid = 5_001, ppid = 5_000, pgrp = 5_000),
                entry(pid = 5_002, ppid = 5_001, pgrp = 5_000),
            ),
        )
        val signals = FakeSignals(proc)

        val report = reaper(proc, signals).harvest(listOf(5_000))

        assertEquals("the group kill comes first", -5_000 to 9, signals.sent.first())
        assertEquals(
            "then the tree by pid",
            listOf(5_000 to 9, 5_001 to 9, 5_002 to 9),
            signals.sent.drop(1),
        )
        assertEquals(listOf(5_000, 5_001, 5_002), report.tree)
        assertEquals(listOf(5_000), report.groups)
        assertTrue("nothing survived", report.clean)
    }

    @Test
    fun theAppsOwnGroupIsNeverSignalled() {
        // A child that ProcessBuilder left in this app's group: kill(-pgrp)
        // would kill the app, so the reaper must refuse and use the pid.
        val proc = FakeProc(listOf(entry(pid = 6_000, ppid = selfPid, pgrp = selfPgrp)))
        val signals = FakeSignals(proc)

        val report = reaper(proc, signals).harvest(listOf(6_000))

        assertTrue("no negative pid may be signalled", signals.sent.none { it.first < 0 })
        assertEquals(listOf(selfPgrp), report.skippedGroups)
        assertEquals(listOf(6_000 to 9), signals.sent)
    }

    @Test
    fun aResidualSameUidProcessIsReportedAndKilled() {
        val proc = FakeProc(
            listOf(
                entry(pid = 5_000, ppid = selfPid, pgrp = 5_000),
                // A stranger: not in the tree, same uid.
                entry(pid = 7_000, ppid = 1, pgrp = 7_000),
                // A different app: never touched.
                entry(pid = 7_100, ppid = 1, pgrp = 7_100, uid = 10_999),
            ),
        )
        val signals = FakeSignals(proc)

        val report = reaper(proc, signals).harvest(listOf(5_000))

        assertEquals("the stranger must be reported", listOf(7_000), report.survivors)
        assertEquals("and killed", listOf(7_000), report.killedSurvivors)
        assertTrue("then the report is clean", report.clean)
        assertTrue("another app's process must be untouched", proc.alive.containsKey(7_100))
    }

    @Test
    fun aSurvivorThatDoesNotDieIsReportedAsUnkillable() {
        val proc = FakeProc(
            listOf(
                entry(pid = 5_000, ppid = selfPid, pgrp = 5_000),
                entry(pid = 7_000, ppid = 1, pgrp = 7_000),
            ),
        )
        val signals = FakeSignals(proc, refusesToDie = setOf(7_000))

        val report = reaper(proc, signals).harvest(listOf(5_000))

        assertEquals(listOf(7_000), report.survivors)
        assertEquals("a survivor that is still there is not clean", listOf(7_000), report.unkillable)
        assertFalse(report.clean)
    }

    @Test
    fun aKnownGroupIsKilledEvenWhenTheRootPidIsGone() {
        // What a close usually sees: `sh -c 'make &'` exited, so /proc/<pid> is
        // gone, but the background fork is still in the group it was given.
        val proc = FakeProc(listOf(entry(pid = 8_000, ppid = 1, pgrp = 5_000)))
        val signals = FakeSignals(proc)

        val report = reaper(proc, signals).harvest(listOf(5_000), knownGroups = listOf(5_000))

        assertEquals("the orphaned group must be killed first", -5_000 to 9, signals.sent.first())
        assertTrue("and the fossil pid is not signalled as a group", report.groups == listOf(5_000))
        assertTrue("the fork is gone", proc.alive.isEmpty())
    }

    @Test
    fun aPidThatAlreadyVanishedIsNotAnError() {
        val proc = FakeProc(listOf(entry(pid = 5_000, ppid = selfPid, pgrp = 5_000)))
        var calls = 0
        val vanished = SignalSender { _, _ ->
            calls += 1
            if (calls == 1) throw java.io.IOException("No such process")
        }

        val report = ProcessTreeReaper(
            uid = uid,
            selfPid = selfPid,
            selfPgrp = selfPgrp,
            table = proc,
            signal = vanished,
        ).harvest(listOf(5_000))

        assertTrue(
            "ESRCH is the expected race, not a failure worth reporting: ${report.errors}",
            report.errors.isEmpty(),
        )
    }

    @Test
    fun aRealTreeWalkingFailureIsReportedButNotThrown() {
        val broken = ProcTable { throw IllegalStateException("no /proc here") }
        val report = ProcessTreeReaper(
            uid = uid,
            selfPid = selfPid,
            selfPgrp = selfPgrp,
            table = broken,
            signal = SignalSender { _, _ -> },
        ).harvest(listOf(5_000))

        assertTrue("a reap failure must be a report, not a throw", report.errors.isNotEmpty())
    }
}
