// Host-JVM tests for the tripwire's bookkeeping.
// SPDX-License-Identifier: MIT
//
// The `FileObserver` itself is device-only (the device suite proves inotify
// fires and that a chmod is what it reports). What is testable here is the part
// that decides what counts as an access: the per-job window, the seal's own
// chmod being excused, the excuse expiring, and the cap.

package com.phonedsh.platform.android

import java.nio.file.Path
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class BuildSealTripwireTest {

    private var clock: Long = 1_700_000_000_000L
    private val sessions: Path = Path.of("/dsh/home/sessions")

    private fun tripwire(maxEvents: Int = BuildSealTripwire.MAX_EVENTS): BuildSealTripwire =
        BuildSealTripwire(nowMs = { clock }, maxEvents = maxEvents)

    @Test
    fun aChmodOnARootIsRecorded() {
        val tripwire = tripwire()
        tripwire.begin()
        tripwire.record("sessions", BuildSealTripwire.IN_ATTRIB)
        val report = tripwire.end()

        assertTrue("a chmod during the job is an access", report.observed)
        assertEquals(1, report.events.size)
        assertEquals(AccessKind.ATTRIB, report.events.single().kind)
        assertEquals("sessions", report.events.single().name)
        assertEquals(0, report.excused)
    }

    @Test
    fun anOpenIsRecordedToo() {
        val tripwire = tripwire()
        tripwire.begin()
        tripwire.record("storages", BuildSealTripwire.IN_OPEN)
        val report = tripwire.end()
        assertEquals(AccessKind.OPEN, report.events.single().kind)
    }

    @Test
    fun eventsOutsideTheWindowAreNotAttributed() {
        val tripwire = tripwire()
        tripwire.record("sessions", BuildSealTripwire.IN_ATTRIB)
        tripwire.begin()
        tripwire.record("sessions", BuildSealTripwire.IN_ATTRIB)
        val report = tripwire.end()
        assertEquals("only the in-window event counts", 1, report.events.size)

        tripwire.record("sessions", BuildSealTripwire.IN_ATTRIB)
        val after = tripwire.end()
        assertFalse("a closed window records nothing", after.observed)
        assertEquals(0, after.events.size)
    }

    @Test
    fun theSealsOwnChmodsAreExcused() {
        val tripwire = tripwire()
        tripwire.begin()
        // The seal announces both roots, then inotify delivers both IN_ATTRIB.
        tripwire.selfModeChange(sessions)
        tripwire.selfModeChange(Path.of("/dsh/home/storages"))
        tripwire.record("sessions", BuildSealTripwire.IN_ATTRIB)
        tripwire.record("storages", BuildSealTripwire.IN_ATTRIB)
        val report = tripwire.end()

        assertFalse("the seal's own chmod is not an access", report.observed)
        assertEquals(2, report.excused)
        assertEquals(0, report.events.size)
    }

    @Test
    fun aGuestChmodIsNotExcusedByAnEarlierSelfAnnouncementForAnotherRoot() {
        val tripwire = tripwire()
        tripwire.begin()
        tripwire.selfModeChange(sessions)
        // The seal's own event and the guest's arrive in cause order.
        tripwire.record("sessions", BuildSealTripwire.IN_ATTRIB)
        tripwire.record("storages", BuildSealTripwire.IN_ATTRIB)
        val report = tripwire.end()

        assertTrue("the second chmod is a real access", report.observed)
        assertEquals(1, report.excused)
        assertEquals("storages", report.events.single().name)
    }

    @Test
    fun anExcuseThatNeverArrivesExpires() {
        val tripwire = tripwire()
        tripwire.begin()
        tripwire.selfModeChange(sessions)
        clock += BuildSealTripwire.EXCUSE_WINDOW_MS + 1
        tripwire.record("sessions", BuildSealTripwire.IN_ATTRIB)
        val report = tripwire.end()

        assertTrue("an expired announcement must not swallow a real event", report.observed)
        assertEquals(0, report.excused)
    }

    @Test
    fun theEventListIsBoundedAndCountsWhatItDropped() {
        val tripwire = tripwire(maxEvents = 3)
        tripwire.begin()
        repeat(5) { tripwire.record("sessions", BuildSealTripwire.IN_ATTRIB) }
        val report = tripwire.end()

        assertEquals("the cap must hold", 3, report.events.size)
        assertEquals(2, report.dropped)
        assertTrue(report.observed)
    }

    @Test
    fun masksDecodeIntoTheTwoKindsTheDesignReasonsAbout() {
        assertEquals(AccessKind.ATTRIB, BuildSealTripwire.kindOf(BuildSealTripwire.IN_ATTRIB))
        assertEquals(AccessKind.OPEN, BuildSealTripwire.kindOf(BuildSealTripwire.IN_OPEN))
        assertEquals(
            "a combined mask names the deliberate act",
            AccessKind.ATTRIB,
            BuildSealTripwire.kindOf(BuildSealTripwire.IN_ATTRIB or BuildSealTripwire.IN_OPEN),
        )
        assertEquals(AccessKind.OTHER, BuildSealTripwire.kindOf(0x00000002))
        assertEquals(
            "the watch subscribes to exactly the two events",
            BuildSealTripwire.IN_ATTRIB or BuildSealTripwire.IN_OPEN,
            BuildSealTripwire.WATCH_MASK,
        )
    }
}
