// Instrumented evidence for the snapshot-first stream contract.
// SPDX-License-Identifier: MIT
//
// The contract is: the first element every collector receives is exactly one
// LifecycleSnapshot with the current values, and later elements are increments
// (LifecycleSignals' KDoc). A JVM test cannot prove it because the readings come
// from BatteryManager, PowerManager and ConnectivityManager on a real device.

package com.phonedsh.platform.android

import android.content.Context
import android.os.PowerManager
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.phonedsh.platform.AppForeground
import com.phonedsh.platform.Battery
import com.phonedsh.platform.LifecycleSnapshot
import com.phonedsh.platform.NetworkPath
import com.phonedsh.platform.ScenePhase
import com.phonedsh.platform.ThermalPressure
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class AndroidLifecycleSignalsTest {

    private lateinit var context: Context

    @Before
    fun setUp() {
        context = ApplicationProvider.getApplicationContext()
    }

    @Test
    fun theFirstFrameAfterSubscriptionIsTheSnapshot() = runBlocking {
        val signals = AndroidLifecycleSignals(context)

        val first = withTimeout(10_000L) { signals.events.first() }

        assertTrue(
            "the first frame was ${first::class.java.simpleName}, not a LifecycleSnapshot",
            first is LifecycleSnapshot,
        )
        val snapshot = first as LifecycleSnapshot
        assertTrue("the snapshot must carry the signals it could read", snapshot.signals.isNotEmpty())
        assertTrue("a snapshot cannot nest a snapshot", snapshot.signals.none { it is LifecycleSnapshot })
        assertEquals(
            "at most one value per signal kind",
            snapshot.signals.size,
            snapshot.signals.distinctBy { it::class.java }.size,
        )
        // Printed so the receipt names the actual first frame.
        println("lifecycle first frame = ${snapshot.signals}")
    }

    @Test
    fun everySubscriptionReceivesItsOwnSnapshotFirst() = runBlocking {
        val signals = AndroidLifecycleSignals(context)

        repeat(3) { index ->
            val frame = withTimeout(10_000L) { signals.events.first() }
            assertTrue("subscription $index started with $frame", frame is LifecycleSnapshot)
        }
    }

    @Test
    fun theSnapshotCarriesTheReadingsAvailableWithoutAnActivity() = runBlocking {
        val signals = AndroidLifecycleSignals(context)
        val snapshot = withTimeout(10_000L) { signals.events.first() } as LifecycleSnapshot
        val kinds = snapshot.signals.map { it::class.java.simpleName }
        println("lifecycle snapshot kinds = $kinds")

        assertTrue(
            "battery is readable from the sticky ACTION_BATTERY_CHANGED broadcast",
            snapshot.signals.any { it is Battery },
        )
        assertTrue(
            "thermal is readable through PowerManager on API 29+",
            snapshot.signals.any { it is ThermalPressure },
        )
        assertTrue(
            "network is readable with ACCESS_NETWORK_STATE",
            snapshot.signals.any { it is NetworkPath },
        )

        // `lowPower` is a reading of the OS power-save mode, not a derived
        // policy: it must agree with PowerManager on this device.
        val battery = snapshot.signals.filterIsInstance<Battery>().single()
        val powerSave = context.getSystemService(PowerManager::class.java)?.isPowerSaveMode ?: false
        assertEquals(
            "Battery.lowPower must be PowerManager.isPowerSaveMode",
            powerSave,
            battery.lowPower,
        )
    }

    @Test
    fun anUnobservedForegroundReadingIsAbsentInsteadOfDefaulted() = runBlocking {
        // Precondition: no Activity is resumed in the instrumentation process,
        // so the adapter has no Activity callback to learn from. The contract is
        // "absent", not a fabricated `AppForeground(false)` / `ScenePhase(BACKGROUND)`:
        // unknown and known-false are different inputs to the host state machine.
        val signals = AndroidLifecycleSignals(context)

        val snapshot = withTimeout(10_000L) { signals.events.first() } as LifecycleSnapshot
        val kinds = snapshot.signals.map { it::class.java.simpleName }
        println("snapshot before any activity callback = $kinds")

        assertTrue(
            "AppForeground was fabricated before any Activity callback: $kinds",
            snapshot.signals.none { it is AppForeground },
        )
        assertTrue(
            "ScenePhase was fabricated before any Activity callback: $kinds",
            snapshot.signals.none { it is ScenePhase },
        )
        assertTrue(
            "the readings that are readable must still be present: $kinds",
            snapshot.signals.isNotEmpty(),
        )
    }
}
