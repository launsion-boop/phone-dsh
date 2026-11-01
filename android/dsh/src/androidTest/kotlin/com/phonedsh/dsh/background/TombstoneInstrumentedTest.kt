// phone-dsh — :dsh / androidTest: the dead-process tombstone and the boot guidance.
// SPDX-License-Identifier: MIT
//
// Evidence produced on the device:
//   * a real WorkManager enqueue survives in WorkManager's database and its
//     WorkInfo is visible (ENQUEUED/RUNNING -> SUCCEEDED);
//   * the worker posts exactly one guidance notification and opens no background
//     window (it must never resume the turn, plan §7.4-3);
//   * the boot receiver's path posts guidance and starts nothing. Its
//     BOOT_COMPLETED wiring is asserted directly here; whether the platform
//     delivers the protected broadcast is Android behaviour, not this test's
//     claim, and is marked "未验证" in the lane report.

package com.phonedsh.dsh.background

import android.app.NotificationManager
import android.content.Context
import android.content.Intent
import android.os.Build
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.work.WorkInfo
import androidx.work.WorkManager
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import java.util.concurrent.TimeUnit

@RunWith(AndroidJUnit4::class)
class TombstoneInstrumentedTest {
    private lateinit var context: Context
    private lateinit var notificationManager: NotificationManager
    private lateinit var workManager: WorkManager

    @Before
    fun setUp() {
        context = ApplicationProvider.getApplicationContext()
        notificationManager = context.getSystemService(NotificationManager::class.java)
        workManager = WorkManager.getInstance(context)
        resetBackgroundState(context)
        grantNotificationPermission(context)
        TurnNotifications.ensureChannels(context)
        await("notification capability visible") {
            TurnBackground.capability(context).progressVisible
        }
    }

    @After
    fun tearDown() {
        TurnBackground.stop(context, TurnRuntime.StopReason.USER_STOPPED)
        TombstoneScheduler.cancel(context)
        InterruptedTurnStore(context).complete()
        notificationManager.cancelAll()
    }

    @Test
    fun tombstoneWorkIsEnqueuedVisibleAndOnlyNotifies() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) {
            System.out.println("TOMBSTONE_NO_PERMISSION_MODEL: API ${Build.VERSION.SDK_INT}")
            return
        }
        // The process-death state: the marker was written at turn start and the
        // turn never closed (simulated by writing the marker directly here).
        val store = InterruptedTurnStore(context)
        store.begin(epoch = 61L, step = 4, totalSteps = 9)
        store.noteInterruption(TurnRuntime.StopReason.SERVICE_STOPPED)
        val beforeIds = workInfos().map { it.id }.toSet()

        assertTrue("WorkManager refused to enqueue the tombstone", TombstoneScheduler.enqueue(context, delayMs = 0L))
        await("tombstone WorkInfo visible", timeoutMs = 20_000L) {
            workInfos().any { it.id !in beforeIds }
        }
        val newWork = workInfos().first { it.id !in beforeIds }
        assertTrue(
            "a fresh tombstone must be enqueued/running/succeeded, was ${newWork.state}",
            newWork.state == WorkInfo.State.ENQUEUED ||
                newWork.state == WorkInfo.State.RUNNING ||
                newWork.state == WorkInfo.State.SUCCEEDED,
        )

        await("tombstone worker finished", timeoutMs = 60_000L) {
            workInfos().first { it.id == newWork.id }.state == WorkInfo.State.SUCCEEDED
        }
        await("tombstone notification posted") {
            notificationManager.activeById(TurnNotifications.TOMBSTONE_NOTIFICATION_ID) != null
        }
        val text = notificationManager.textOf(TurnNotifications.TOMBSTONE_NOTIFICATION_ID)
        assertTrue("tombstone must guide the user, text='$text'", text.contains("检查点"))
        assertTrue("tombstone must not promise automatic resume, text='$text'", text.contains("不会自动续跑"))
        assertFalse(
            "the tombstone must not open a background window",
            TurnRuntime.snapshot().isRunning,
        )
        assertNull(
            "the tombstone must not post a foreground-service notification",
            notificationManager.activeById(TurnNotifications.PROGRESS_NOTIFICATION_ID),
        )
        val marker = store.interrupted()
        assertNotNull("the durable marker must survive for the next-open banner", marker)
        assertEquals(4, marker!!.step)
        assertTrue("the marker must be marked reported", marker.reported)
    }

    @Test
    fun bootReceiverPostsGuidanceAndStartsNothing() {
        val store = InterruptedTurnStore(context)
        store.begin(epoch = 71L, step = 2, totalSteps = 3)
        store.noteInterruption(TurnRuntime.StopReason.SERVICE_STOPPED)

        BootReceiver().onReceive(context, Intent(Intent.ACTION_BOOT_COMPLETED))

        // NotificationManager.notify is asynchronous: the notification becomes
        // visible on the manager's own thread, so await it instead of racing it.
        await("boot guidance posted") {
            notificationManager.activeById(TurnNotifications.BOOT_NOTIFICATION_ID) != null
        }
        val posted = notificationManager.activeById(TurnNotifications.BOOT_NOTIFICATION_ID)
        assertNotNull("boot guidance must be posted", posted)
        val text = notificationManager.textOf(TurnNotifications.BOOT_NOTIFICATION_ID)
        assertTrue("boot guidance must name the checkpoint, text='$text'", text.contains("检查点"))
        assertTrue("boot guidance must not promise resume, text='$text'", text.contains("不会自动续跑"))
        assertFalse(
            "BootReceiver must never open a background window (plan §7.4-3)",
            TurnRuntime.snapshot().isRunning,
        )
        assertNull(
            "BootReceiver must not post a foreground-service notification",
            notificationManager.activeById(TurnNotifications.PROGRESS_NOTIFICATION_ID),
        )
    }

    @Test
    fun packageScopedBootBroadcastIsNotTreatedAsAReboot() {
        // WorkManager 2.10's ForceStopRunnable re-broadcasts ACTION_BOOT_COMPLETED
        // scoped to the app's own package; measured on the API 35 emulator. If the
        // receiver treated that as a reboot it would post "设备已重启" on a force-stop
        // recovery that never rebooted, and swallow the tombstone report.
        val store = InterruptedTurnStore(context)
        store.begin(epoch = 72L, step = 1, totalSteps = 2)
        store.noteInterruption(TurnRuntime.StopReason.SERVICE_STOPPED)
        notificationManager.cancelAll()

        BootReceiver().onReceive(
            context,
            Intent(Intent.ACTION_BOOT_COMPLETED).setPackage(context.packageName),
        )

        // A short settle window: the correct behaviour is "nothing was posted".
        Thread.sleep(750L)
        assertNull(
            "a package-scoped BOOT_COMPLETED must not produce reboot guidance",
            notificationManager.activeById(TurnNotifications.BOOT_NOTIFICATION_ID),
        )
        assertEquals(
            "the marker must stay unreported so the tombstone/next-open path reports it",
            false,
            store.interrupted()?.reported,
        )
    }

    private fun workInfos(): List<WorkInfo> =
        workManager.getWorkInfosForUniqueWork(TombstoneScheduler.UNIQUE_WORK_NAME)
            .get(15, TimeUnit.SECONDS)
}
