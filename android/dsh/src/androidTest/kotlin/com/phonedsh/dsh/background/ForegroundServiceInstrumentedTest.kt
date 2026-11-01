// phone-dsh — :dsh / androidTest: the dataSync foreground-service channel.
// SPDX-License-Identifier: MIT
//
// Evidence produced on the device:
//   1. the service reaches foreground and its notification really exists in
//      NotificationManager.activeNotifications (not a mock);
//   2. the notification carries the graceful stop action, and sending that
//      PendingIntent closes admission and removes the notification;
//   3. the degraded branch (POST_NOTIFICATIONS denied -> FOREGROUND_ONLY, no
//      background window) is asserted by an assumption-guarded test: revoking a
//      runtime permission kills the app process, so the Gradle suite cannot flip it
//      in place. The test runs for real after `pm revoke` (see the lane report);
//      in the normal suite it is skipped, never faked.

package com.phonedsh.dsh.background

import android.app.Notification
import android.app.NotificationManager
import android.content.Context
import androidx.test.core.app.ActivityScenario
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class ForegroundServiceInstrumentedTest {
    private lateinit var context: Context
    private lateinit var notificationManager: NotificationManager
    private var scenario: ActivityScenario<BackgroundTestActivity>? = null

    @Before
    fun setUp() {
        context = ApplicationProvider.getApplicationContext()
        notificationManager = context.getSystemService(NotificationManager::class.java)
        resetBackgroundState(context)
        TurnNotifications.ensureChannels(context)
        scenario = launchVisibleTestApp()
        await("clean runtime") { !TurnRuntime.snapshot().isRunning }
    }

    @After
    fun tearDown() {
        TurnBackground.stop(context, TurnRuntime.StopReason.USER_STOPPED)
        scenario?.close()
        notificationManager.cancelAll()
        InterruptedTurnStore(context).complete()
        TombstoneScheduler.cancel(context)
    }

    @Test
    fun foregroundServicePostsOngoingProgressNotificationWithStopAction() {
        ensureNotificationsVisible()
        val request = TurnRequest(epoch = 41L, step = 2, totalSteps = 5)
        assertTrue("foreground service refused to start", TurnForegroundService.start(context, request))
        await("foreground service running") {
            val state = TurnRuntime.snapshot()
            state.isRunning && state.backend == TurnRuntime.Backend.FOREGROUND_SERVICE
        }
        assertTrue("admission must be open while the window is valid", TurnRuntime.snapshot().admissionOpen)

        await("progress notification posted") {
            notificationManager.activeById(TurnNotifications.PROGRESS_NOTIFICATION_ID) != null
        }
        val posted = notificationManager.activeById(TurnNotifications.PROGRESS_NOTIFICATION_ID)
        assertNotNull("progress notification must be active", posted)
        val notification = posted!!.notification
        assertNotEquals(
            "a running turn notification must be ongoing",
            0,
            notification.flags and Notification.FLAG_ONGOING_EVENT,
        )
        val action = notification.actions?.singleOrNull()
        assertNotNull("running notification must carry exactly one action", action)
        assertEquals(TurnNotifications.STOP_ACTION_LABEL, action!!.title.toString())

        val text = notification.extras.getCharSequence(Notification.EXTRA_TEXT)?.toString().orEmpty()
        assertTrue("notification text must say what is happening: '$text'", text.contains("后台"))
        assertFalse(
            "must not claim durability the notification cannot deliver: '$text'",
            text.contains("正在保护你的数据"),
        )
        assertEquals(
            "the step comes from the caller, never fabricated",
            "最后检查点：第 2 步",
            notification.extras.getCharSequence(Notification.EXTRA_SUB_TEXT)?.toString(),
        )
        // The durable marker was written too: this is what the tombstone reads.
        val marker = InterruptedTurnStore(context).interrupted()
        assertNotNull("turn start must leave a durable marker", marker)
        assertEquals(41L, marker!!.epoch)
        assertEquals(2, marker.step)
    }

    @Test
    fun stopActionOnNotificationClosesAdmissionAndRemovesNotification() {
        ensureNotificationsVisible()
        TurnForegroundService.start(context, TurnRequest(epoch = 42L, step = 1))
        await("progress notification posted") {
            notificationManager.activeById(TurnNotifications.PROGRESS_NOTIFICATION_ID) != null
        }
        val stopIntent = notificationManager.activeById(TurnNotifications.PROGRESS_NOTIFICATION_ID)
            ?.notification?.actions?.singleOrNull()?.actionIntent
        assertNotNull("stop action has no PendingIntent", stopIntent)

        stopIntent!!.send()

        await("stop action stopped the turn") {
            val state = TurnRuntime.snapshot()
            state.phase == TurnRuntime.Phase.STOPPED &&
                state.stopReason == TurnRuntime.StopReason.USER_STOPPED
        }
        assertFalse("admission must be closed after a stop", TurnRuntime.snapshot().admissionOpen)
        await("running notification removed") {
            notificationManager.activeById(TurnNotifications.PROGRESS_NOTIFICATION_ID) == null
        }
        assertNull(
            "a user stop removes the durable marker: it must not be reported as an interruption",
            InterruptedTurnStore(context).interrupted(),
        )
    }

    @Test
    fun removingTheTaskStopsTheServiceAndLeavesTheMarker() {
        ensureNotificationsVisible()
        TurnForegroundService.start(context, TurnRequest(epoch = 44L, step = 1))
        await("foreground service running") { TurnRuntime.snapshot().isRunning }
        await("progress notification posted") {
            notificationManager.activeById(TurnNotifications.PROGRESS_NOTIFICATION_ID) != null
        }

        scenario!!.onActivity { it.finishAndRemoveTask() }

        // android:stopWithTask="true" (manifest): removing the task is a
        // zero-ambiguity user action, and the platform stops the window.
        await("task removal stopped the service") { !TurnRuntime.snapshot().isRunning }
        val marker = InterruptedTurnStore(context).interrupted()
        assertNotNull("a task removal must leave the next-open marker", marker)
        assertEquals(44L, marker!!.epoch)
    }

    @Test
    fun runtimePermissionDeniedSelectsForegroundOnlyAndOpensNoWindow() {
        val capability = TurnBackground.capability(context)
        assumeTrue(
            "requires POST_NOTIFICATIONS denied at process start (revoking kills the " +
                "instrumentation process): adb shell pm revoke " +
                "${context.packageName} android.permission.POST_NOTIFICATIONS",
            capability.runtimePermission == NotificationCapability.RuntimePermission.DENIED,
        )
        assertFalse(capability.progressVisible)
        assertEquals(
            NotificationCapability.DegradedReason.RUNTIME_PERMISSION_DENIED,
            capability.degradedReason,
        )
        assertEquals(TurnChannel.FOREGROUND_ONLY, TurnBackground.channel(context))

        val result = TurnBackground.start(
            context,
            TurnRequest(epoch = 43L, step = 0),
            appVisible = true,
        )
        assertTrue("expected foreground-only, got $result", result is TurnStartResult.ForegroundOnly)
        assertEquals(
            TurnStartResult.ForegroundOnlyReason.NOTIFICATIONS_UNAVAILABLE,
            (result as TurnStartResult.ForegroundOnly).reason,
        )
        assertFalse(
            "no background window may be opened without a visible notification",
            TurnRuntime.snapshot().isRunning,
        )
        assertNull(
            "no foreground-service notification may be posted",
            notificationManager.activeById(TurnNotifications.PROGRESS_NOTIFICATION_ID),
        )

        // With the notification link degraded, an interruption cannot be announced
        // now, so it must be queued for the next app open instead of being lost
        // (whitelist platform.post-notifications-degraded, plan §7.4-4).
        val store = InterruptedTurnStore(context)
        store.begin(epoch = 43L, step = 2, totalSteps = 5)
        store.noteInterruption(TurnRuntime.StopReason.SERVICE_STOPPED)
        assertTrue(TombstoneScheduler.enqueue(context, delayMs = 0L))
        await("interruption queued for next open", timeoutMs = 60_000L) {
            TurnBackground.pendingReport(context)?.epoch == 43L
        }
        assertEquals(2, TurnBackground.pendingReport(context)?.step)
        assertNull(
            "no tombstone notification may be posted while the link is degraded",
            notificationManager.activeById(TurnNotifications.TOMBSTONE_NOTIFICATION_ID),
        )
        TurnBackground.consumePendingReport(context)
        store.complete()
        TombstoneScheduler.cancel(context)
    }

    private fun ensureNotificationsVisible() {
        grantNotificationPermission(context)
        await("notification capability visible") {
            TurnBackground.capability(context).progressVisible
        }
    }
}
