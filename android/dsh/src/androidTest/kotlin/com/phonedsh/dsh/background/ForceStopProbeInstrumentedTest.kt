// phone-dsh — :dsh / androidTest: the zero-callback force-stop probe.
// SPDX-License-Identifier: MIT
//
// This class is a two-run manual probe, not part of the Gradle suite: a force-stop
// kills the instrumentation process, so the two halves have to be separate
// `am instrument` invocations. Both halves skip unless their phase argument is
// supplied, which keeps `connectedDebugAndroidTest` green and honest.
//
// What it proves (plan §7.9 rows "进程被杀" and "Task Manager Stop / OEM
// force-stop"):
//   phase start  : a real foreground service starts, the durable marker is written;
//   host         : `adb shell am force-stop <pkg>` kills the process with zero
//                  callbacks;
//   phase verify : a fresh process still reads epoch 61/step 3 with no invented
//                  reason, and the tombstone worker turns it into guidance.
//
// Run:
//   adb shell am instrument -w -e pdsh.phase start \
//       -e class '...ForceStopProbeInstrumentedTest#startTurnThenWaitForForceStop' \
//       com.phonedsh.dsh.test/androidx.test.runner.AndroidJUnitRunner &
//   adb shell am force-stop com.phonedsh.dsh.test
//   adb shell am instrument -w -e pdsh.phase verify \
//       -e class '...ForceStopProbeInstrumentedTest#nextOpenReadsTheInterruptedTurn' \
//       com.phonedsh.dsh.test/androidx.test.runner.AndroidJUnitRunner

package com.phonedsh.dsh.background

import android.app.NotificationManager
import android.content.Context
import android.os.SystemClock
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class ForceStopProbeInstrumentedTest {
    private val phase: String? = InstrumentationRegistry.getArguments().getString(PHASE_ARG)

    @Test
    fun startTurnThenWaitForForceStop() {
        assumeTrue("manual probe: pass -e $PHASE_ARG start", phase == "start")
        val context = ApplicationProvider.getApplicationContext<Context>()
        grantNotificationPermission(context)
        TurnNotifications.ensureChannels(context)
        TurnBackground.stop(context, TurnRuntime.StopReason.USER_STOPPED)
        InterruptedTurnStore(context).complete()
        val scenario = launchVisibleTestApp()

        TurnForegroundService.start(context, TurnRequest(epoch = 61L, step = 3, totalSteps = 7))
        await("durable marker written") {
            InterruptedTurnStore(context).interrupted()?.epoch == 61L
        }
        await("foreground service running") { TurnRuntime.snapshot().isRunning }
        System.out.println("PDSH_FORCE_STOP_READY epoch=61 step=3")
        // Keep the process alive until the host force-stops it. The instrumentation
        // dies with the process; that is the point of the probe.
        SystemClock.sleep(120_000L)
        scenario.close()
    }

    @Test
    fun nextOpenReadsTheInterruptedTurn() {
        assumeTrue("manual probe: pass -e $PHASE_ARG verify", phase == "verify")
        val context = ApplicationProvider.getApplicationContext<Context>()
        val notificationManager = context.getSystemService(NotificationManager::class.java)
        grantNotificationPermission(context)
        TurnNotifications.ensureChannels(context)

        val marker = InterruptedTurnStore(context).interrupted()
        assertNotNull("the durable marker must survive force-stop", marker)
        assertEquals(61L, marker!!.epoch)
        assertEquals(3, marker.step)
        assertNull(
            "force-stop is zero-callback: the marker must not invent a stop reason",
            marker.reason,
        )
        assertFalse("a fresh process must not be in a running state", TurnRuntime.snapshot().isRunning)

        assertTrue(
            "WorkManager must be able to turn the surviving marker into guidance",
            TombstoneScheduler.enqueue(context, delayMs = 0L),
        )
        await("tombstone notification after force-stop", timeoutMs = 60_000L) {
            notificationManager.activeById(TurnNotifications.TOMBSTONE_NOTIFICATION_ID) != null
        }
        val text = notificationManager.textOf(TurnNotifications.TOMBSTONE_NOTIFICATION_ID)
        assertTrue("guidance must name the checkpoint, text='$text'", text.contains("检查点"))
        assertTrue("guidance must not promise resume, text='$text'", text.contains("不会自动续跑"))
        assertTrue(
            "the marker must be marked reported",
            InterruptedTurnStore(context).interrupted()?.reported == true,
        )

        notificationManager.cancelAll()
        InterruptedTurnStore(context).complete()
        TombstoneScheduler.cancel(context)
    }

    private companion object {
        const val PHASE_ARG = "pdsh.phase"
    }
}
