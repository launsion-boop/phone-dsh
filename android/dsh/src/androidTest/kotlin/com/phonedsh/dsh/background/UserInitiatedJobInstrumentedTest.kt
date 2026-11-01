// phone-dsh — :dsh / androidTest: the Android 14+ UIDT channel.
// SPDX-License-Identifier: MIT
//
// Evidence produced on the device (API 34+ only; below that the class reports the
// skip explicitly instead of pretending):
//   * the JobInfo really is user-initiated and carries the payload estimate;
//   * the real JobScheduler accepts it (TurnStartResult.UserInitiatedJobScheduled);
//   * the job really starts and its own notification is visible in
//     NotificationManager.activeNotifications;
//   * the shared stop entry point ends the job.

package com.phonedsh.dsh.background

import android.app.Notification
import android.app.NotificationManager
import android.app.job.JobScheduler
import android.content.Context
import android.os.Build
import androidx.test.core.app.ActivityScenario
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class UserInitiatedJobInstrumentedTest {
    private lateinit var context: Context
    private lateinit var notificationManager: NotificationManager
    private var scenario: ActivityScenario<BackgroundTestActivity>? = null

    @Before
    fun setUp() {
        context = ApplicationProvider.getApplicationContext()
        notificationManager = context.getSystemService(NotificationManager::class.java)
        resetBackgroundState(context)
        grantNotificationPermission(context)
        TurnNotifications.ensureChannels(context)
        scenario = launchVisibleTestApp()
        await("notification capability visible") {
            TurnBackground.capability(context).progressVisible
        }
        if (Build.VERSION.SDK_INT >= TurnChannel.USER_INITIATED_JOB_MIN_SDK) {
            assertEquals(TurnChannel.USER_INITIATED_JOB, TurnBackground.channel(context))
        }
    }

    @After
    fun tearDown() {
        TurnBackground.stop(context, TurnRuntime.StopReason.USER_STOPPED)
        context.getSystemService(JobScheduler::class.java)?.cancel(TurnJobScheduler.JOB_ID)
        scenario?.close()
        notificationManager.cancelAll()
        InterruptedTurnStore(context).complete()
        TombstoneScheduler.cancel(context)
    }

    @Test
    fun userInitiatedJobIsBuiltScheduledAndPostsItsOwnProgressNotification() {
        // `assumeTrue`, not an early `return`: a returned test is recorded as a pass
        // with zero assertions, which reads as evidence on the dashboard while proving
        // nothing. A skip is honest; a green no-op is not.
        assumeTrue(
            "UIDT needs API ${TurnChannel.USER_INITIATED_JOB_MIN_SDK}+; this image is " +
                "API ${Build.VERSION.SDK_INT}",
            Build.VERSION.SDK_INT >= TurnChannel.USER_INITIATED_JOB_MIN_SDK,
        )
        val request = TurnRequest(
            epoch = 51L,
            step = 1,
            totalSteps = 4,
            estimatedDownloadBytes = 3L * 1024L * 1024L,
            estimatedUploadBytes = 512L * 1024L,
        )
        val scheduler = TurnJobScheduler(context)
        val info = scheduler.buildJobInfo(request)
        assertTrue("JobInfo must be user-initiated", info.isUserInitiated)
        assertEquals(3L * 1024L * 1024L, info.estimatedNetworkDownloadBytes)
        assertEquals(512L * 1024L, info.estimatedNetworkUploadBytes)
        assertEquals(51L, info.extras.getLong(TurnRequest.EXTRA_EPOCH))
        assertNotNull("UIDT must carry a network constraint for its estimate", info.requiredNetwork)

        val result = scheduler.schedule(request, appVisible = true)
        assertEquals(
            TurnStartResult.UserInitiatedJobScheduled(TurnJobScheduler.JOB_ID),
            result,
        )

        await("UIDT job started", timeoutMs = 30_000L) {
            TurnRuntime.snapshot().backend == TurnRuntime.Backend.USER_INITIATED_JOB
        }
        await("UIDT notification posted", timeoutMs = 30_000L) {
            notificationManager.activeById(TurnNotifications.PROGRESS_NOTIFICATION_ID) != null
        }
        val posted = notificationManager.activeById(TurnNotifications.PROGRESS_NOTIFICATION_ID)
        assertNotNull("the job notification must be active", posted)
        val notification = posted!!.notification
        assertTrue(
            "job notification must be ongoing",
            notification.flags and Notification.FLAG_ONGOING_EVENT != 0,
        )
        val text = notification.extras.getCharSequence(Notification.EXTRA_TEXT)?.toString().orEmpty()
        assertTrue("job notification must say what is happening: '$text'", text.contains("后台"))
        assertEquals(
            "最后检查点：第 1 步",
            notification.extras.getCharSequence(Notification.EXTRA_SUB_TEXT)?.toString(),
        )

        assertTrue(
            "the notification stop entry point must stop the UIDT job",
            TurnBackground.stop(context, TurnRuntime.StopReason.USER_STOPPED),
        )
        await("UIDT job finished") {
            TurnRuntime.snapshot().phase == TurnRuntime.Phase.STOPPED
        }
        assertFalse(TurnRuntime.snapshot().admissionOpen)
    }
}
