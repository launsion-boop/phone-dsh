// Contract tests for the shared FakePlatform fixture.
// SPDX-License-Identifier: MIT
//
// Upper layers will build their JVM tests on this class, so its own behaviour
// (clock, signal ordering, Notifier recording) is pinned here before it leaks
// into :controller or :dsh tests.

package com.phonedsh.platform.testing

import com.phonedsh.platform.AppForeground
import com.phonedsh.platform.Battery
import com.phonedsh.platform.EngineHostState
import com.phonedsh.platform.LifecycleSignal
import com.phonedsh.platform.LifecycleSnapshot
import com.phonedsh.platform.NetworkPath
import com.phonedsh.platform.NotificationAction
import com.phonedsh.platform.NotifierAvailability
import com.phonedsh.platform.ScenePhase
import com.phonedsh.platform.SecureLookup
import com.phonedsh.platform.SecurityLevel
import com.phonedsh.platform.ThermalPressure
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.take
import kotlinx.coroutines.flow.toList
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test

class FakePlatformTest {
    private val fake = FakePlatform()

    @After
    fun tearDown() {
        fake.close()
    }

    @Test
    fun advancingTheClockMovesWallAndMonotonicTimeTogether() {
        val clock = FakePlatform(nowMillis = 1_700_000_000_000L, monotonicMillis = 5_000L)
        try {
            clock.advanceBy(2_500L)
            assertEquals(1_700_000_002_500L, clock.nowMillis())
            assertEquals(7_500L, clock.monotonicMillis())
        } finally {
            clock.close()
        }
    }

    @Test
    fun aWallClockJumpDoesNotMoveMonotonicTime() {
        fake.advanceBy(2_500L)
        fake.setNowMillis(42L)

        assertEquals(42L, fake.nowMillis())
        assertEquals(2_500L, fake.monotonicMillis())
    }

    @Test
    fun signalsAreDeliveredInEmissionOrder() = runBlocking {
        val seen = mutableListOf<LifecycleSignal>()
        val collector = launch(Dispatchers.Unconfined) {
            fake.events.take(6).toList(seen)
        }
        val signals = listOf<LifecycleSignal>(
            ScenePhase(ScenePhase.Phase.ACTIVE),
            ThermalPressure(ThermalPressure.Pressure.FAIR),
            Battery(percent = 37, charging = false, lowPower = false),
            NetworkPath(available = false, expensive = true),
            AppForeground(foreground = true),
        )
        signals.forEach(fake::emit)
        collector.join()

        assertEquals(listOf<LifecycleSignal>(LifecycleSnapshot(emptyList())) + signals, seen)
        assertEquals(signals, fake.emittedSignals)
    }

    @Test
    fun theFirstFrameAfterSubscriptionIsTheCurrentValueSnapshot() = runBlocking {
        fake.emit(ScenePhase(ScenePhase.Phase.ACTIVE))
        fake.emit(Battery(percent = 10, charging = false, lowPower = true))
        fake.emit(ScenePhase(ScenePhase.Phase.INACTIVE))

        val first = fake.events.first()

        assertEquals(
            LifecycleSnapshot(
                listOf(
                    ScenePhase(ScenePhase.Phase.INACTIVE),
                    Battery(percent = 10, charging = false, lowPower = true),
                ),
            ),
            first,
        )
    }

    @Test
    fun anEmptyStateStillStartsWithAnEmptySnapshot() = runBlocking {
        assertEquals(LifecycleSnapshot(emptyList()), fake.events.first())
    }

    @Test
    fun notifierReportsItsConfiguredAvailability() {
        assertEquals(NotifierAvailability.ENABLED, fake.availability)
        fake.notifierAvailability = NotifierAvailability.DISABLED
        assertEquals(NotifierAvailability.DISABLED, fake.availability)
    }

    @Test
    fun notifierRecordsCallsAndCanPressTheStopAction() {
        var stops = 0
        val stop = NotificationAction("Stop") { stops += 1 }

        fake.notify(7, "Turn running", "step 2 of 5", ongoing = true, action = stop)
        fake.notify(8, "Turn complete", "5 steps", ongoing = false, action = null)
        fake.cancel(7)

        assertEquals(listOf(7, 8), fake.notifications.map { it.id })
        assertEquals("Turn running", fake.notifications[0].title)
        assertEquals("step 2 of 5", fake.notifications[0].body)
        assertTrue(fake.notifications[0].ongoing)
        assertSame(stop, fake.notifications[0].action)
        assertFalse(fake.notifications[1].ongoing)
        assertNull(fake.notifications[1].action)
        assertEquals(listOf(7), fake.cancelledIds)

        assertTrue(fake.performAction(7))
        assertEquals(1, stops)
        assertFalse("a notification without an action reports no press", fake.performAction(8))
        assertEquals(1, stops)
    }

    @Test
    fun secureStoreReturnsFoundWithADefensiveCopy() = runBlocking {
        fake.securityLevel = SecurityLevel.SOFTWARE
        assertEquals(SecurityLevel.SOFTWARE, fake.level)

        val token = byteArrayOf(1, 2, 3)
        fake.put("reclaim-token", token)
        token[0] = 99

        val found = fake.get("reclaim-token")
        assertTrue(found is SecureLookup.Found)
        assertArrayEquals(byteArrayOf(1, 2, 3), (found as SecureLookup.Found).value)
        assertEquals(setOf("reclaim-token"), fake.storedKeys())

        fake.delete("reclaim-token")
        assertEquals(SecureLookup.Absent, fake.get("reclaim-token"))
        assertTrue(fake.storedKeys().isEmpty())
    }

    @Test
    fun secureStoreReturnsAbsentForAMissingKey() = runBlocking {
        assertEquals(SecureLookup.Absent, fake.get("reclaim-token"))
    }

    @Test
    fun secureStoreDistinguishesUnreadableFromAbsent() = runBlocking {
        fake.put("reclaim-token", byteArrayOf(7, 8, 9))
        fake.markUnreadable("reclaim-token")

        val lookup = fake.get("reclaim-token")
        assertTrue(lookup is SecureLookup.Unreadable)
        assertEquals("key-invalidated", (lookup as SecureLookup.Unreadable).reason)
        // The core fail-closed assertion: a key that exists but cannot be read
        // must not be mistaken for a key that does not exist (plan §11-R11).
        assertNotEquals(SecureLookup.Absent, lookup)

        fake.markReadable("reclaim-token")
        assertTrue(fake.get("reclaim-token") is SecureLookup.Found)
    }

    @Test
    fun engineHostIsAvailableThroughDelegation() {
        val running = EngineHostState.Running("http://127.0.0.1:41234", 41234)
        fake.engine.setState(running)
        assertEquals(running, fake.state.value)

        fake.start()
        fake.start()
        assertEquals(2, fake.engine.startCount)

        fake.stop()
        assertEquals(1, fake.engine.stopCount)
        assertEquals(EngineHostState.Stopped, fake.state.value)
    }
}
