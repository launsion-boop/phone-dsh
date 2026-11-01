// phone-dsh — :dsh / androidTest: the API 26–33 dataSync fallback, measured on API 33.
// SPDX-License-Identifier: MIT
//
// WHY THIS CLASS EXISTS
// On API 34+ TurnChannel.select returns UIDT, so UserInitiatedJobInstrumentedTest is
// the primary-channel probe there. But on an API 35 image the fallback branch
// (DATA_SYNC_FOREGROUND_SERVICE) can never be selected, and TurnChannelTest only
// passes 33 as a parameter to a pure function. API 33 is the only hosted image on
// which the real platform falls through to UIDT's absence, so this class measures
// that fallback on the device:
//
//   1. the selector, evaluated on the device's own SDK_INT, returns the foreground
//      service and never UIDT (the JVM test hands 33 in as an argument; this does
//      not);
//   2. UIDT is absent, not merely unchosen: JobInfo.Builder.setUserInitiated
//      (API 34) does not exist in the runtime framework classes (reflection);
//   3. a real startForegroundService through TurnBackground.start /
//      TurnJobScheduler.schedule opens a real foreground record, asserted from
//      `dumpsys activity services` (isForeground, foregroundId, foregroundNoti,
//      FLAG_FOREGROUND_SERVICE, startForegroundCount).
//
// THE ONE THING API 33 CANNOT HAND BACK is the *runtime* FGS type bitmask. AOSP
// android-13 ServiceRecord.dump() prints isForeground/foregroundId/foregroundNoti
// only, and ServiceRecordProto has no type field; `types=%08X` first appears in
// android-14. dataSyncTypeEvidence() therefore asserts what this image can prove
// (declared type + the platform accepting the promotion under its own
// subset-of-manifest validation) and prints PDSH_API33_FGS_TYPE_READBACK_BLOCKED
// instead of inventing a readback. The lane report labels it exactly the same way.
//
// On any API other than 33 every test here is skipped with an explicit reason.

package com.phonedsh.dsh.background

import android.app.Notification
import android.app.NotificationManager
import android.app.job.JobInfo
import android.content.ComponentName
import android.content.Context
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.ParcelFileDescriptor
import android.util.Log
import androidx.test.core.app.ActivityScenario
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class Api33FallbackInstrumentedTest {
    private lateinit var context: Context
    private lateinit var notificationManager: NotificationManager
    private var scenario: ActivityScenario<BackgroundTestActivity>? = null

    @Before
    fun setUp() {
        assumeTrue(
            "API $FALLBACK_API fallback probe: a UIDT image (34+) cannot reach this branch",
            Build.VERSION.SDK_INT == FALLBACK_API,
        )
        context = ApplicationProvider.getApplicationContext()
        notificationManager = context.getSystemService(NotificationManager::class.java)
        resetBackgroundState(context)
        grantNotificationPermission(context)
        TurnNotifications.ensureChannels(context)
        scenario = launchVisibleTestApp()
        await("notification capability visible") {
            TurnBackground.capability(context).progressVisible
        }
    }

    @After
    fun tearDown() {
        // JUnit 4 runs @After even when @Before threw the assumption violation, so a
        // skip on API 34+ must not touch the lateinit fields that setUp never reached:
        // an UninitializedPropertyAccessException here would turn the honest skip into
        // an error in the other lane's API 35 suite.
        if (!this::context.isInitialized) return
        TurnBackground.stop(context, TurnRuntime.StopReason.USER_STOPPED)
        scenario?.close()
        notificationManager.cancelAll()
        InterruptedTurnStore(context).complete()
        TombstoneScheduler.cancel(context)
    }

    @Test
    fun deviceSelectorReturnsTheForegroundServiceAndUidtDoesNotExistHere() {
        val capability = TurnBackground.capability(context)
        assertTrue("the probe needs a visible notification link", capability.progressVisible)

        assertEquals(
            "the device's own SDK_INT must land on the dataSync fallback",
            TurnChannel.DATA_SYNC_FOREGROUND_SERVICE,
            TurnChannel.select(Build.VERSION.SDK_INT, capability),
        )
        assertEquals(
            "TurnChannel.current is the production call site",
            TurnChannel.DATA_SYNC_FOREGROUND_SERVICE,
            TurnChannel.current(capability),
        )
        assertEquals(
            "the public facade the UI reads must agree",
            TurnChannel.DATA_SYNC_FOREGROUND_SERVICE,
            TurnBackground.channel(context),
        )
        assertNotEquals(
            "UIDT must never be the channel on API $FALLBACK_API",
            TurnChannel.USER_INITIATED_JOB,
            TurnBackground.channel(context),
        )

        // Boundary pin with the same pure function, evaluated here (not on the JVM):
        // one level below UIDT is the fallback, the UIDT level itself is UIDT.
        assertEquals(
            TurnChannel.DATA_SYNC_FOREGROUND_SERVICE,
            TurnChannel.select(TurnChannel.USER_INITIATED_JOB_MIN_SDK - 1, capability),
        )
        assertEquals(
            TurnChannel.USER_INITIATED_JOB,
            TurnChannel.select(TurnChannel.USER_INITIATED_JOB_MIN_SDK, capability),
        )

        // UIDT is not "not chosen": the API does not exist in this framework, so
        // TurnJobScheduler.buildJobInfo (@RequiresApi(34)) cannot run here at all.
        val uidtMethod = runCatching {
            JobInfo.Builder::class.java
                .getMethod("setUserInitiated", Boolean::class.javaPrimitiveType)
        }.getOrNull()
        assertNull(
            "JobInfo.Builder.setUserInitiated must be absent on API $FALLBACK_API; " +
                "finding it would mean the UIDT branch is reachable here",
            uidtMethod,
        )
    }

    @Test
    fun realStartForegroundServiceOpensADataSyncWindowSeenByDumpsys() {
        val request = TurnRequest(epoch = 81L, step = 3, totalSteps = 6)
        val result = TurnBackground.start(context, request, appVisible = true)
        assertEquals(
            "on API $FALLBACK_API the production entry point must open the FGS fallback",
            TurnStartResult.DataSyncForegroundServiceStarted,
            result,
        )
        await("foreground service running") {
            val state = TurnRuntime.snapshot()
            state.isRunning && state.backend == TurnRuntime.Backend.FOREGROUND_SERVICE
        }
        await("progress notification posted") {
            notificationManager.activeById(TurnNotifications.PROGRESS_NOTIFICATION_ID) != null
        }

        val declaredType = context.packageManager.getServiceInfo(
            ComponentName(context, TurnForegroundService::class.java),
            0,
        ).foregroundServiceType
        assertEquals(
            "the installed package must declare exactly the dataSync type",
            ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC,
            declaredType,
        )

        val dump = shellCommand("dumpsys activity services ${context.packageName}")
        val record = serviceRecord(dump, TurnForegroundService::class.java.simpleName)
        Log.i(TAG, "dumpsys record for the dataSync window on API $FALLBACK_API:\n$record")
        System.out.println("PDSH_API33_FGS_DUMPSYS:\n$record")

        assertTrue(
            "dumpsys must report the service as foreground:\n$record",
            record.contains("isForeground=true"),
        )
        assertTrue(
            "the foreground notification id must be the turn notification:\n$record",
            record.contains("foregroundId=${TurnNotifications.PROGRESS_NOTIFICATION_ID}"),
        )
        assertTrue(
            "the foreground notification must be on the turn channel:\n$record",
            record.contains(
                "foregroundNoti=Notification(channel=${TurnNotifications.PROGRESS_CHANNEL_ID}",
            ),
        )
        val flags = Regex("""flags=0x([0-9a-fA-F]+)""").find(record)
        assertTrue("no notification flags in:\n$record", flags != null)
        assertTrue(
            "the notification must carry FLAG_FOREGROUND_SERVICE:\n$record",
            (flags!!.groupValues[1].toInt(16) and Notification.FLAG_FOREGROUND_SERVICE) != 0,
        )
        val promotions = Regex("""startForegroundCount=(\d+)""").find(record)
        assertTrue("no startForegroundCount in:\n$record", promotions != null)
        assertTrue(
            "the platform must have recorded the promotion:\n$record",
            promotions!!.groupValues[1].toInt() >= 1,
        )

        dataSyncTypeEvidence(record)
    }

    /**
     * The runtime FGS type, to the exact extent API 33 can prove it.
     *
     * If the dump exposes the type (AOSP android-14 prints `types=%08X`), the value
     * is asserted to be dataSync exactly. On API 33 there is no such field, so the
     * test proves the type through the platform's own validation instead of
     * inventing a readback:
     *   * `ServiceInfo.foregroundServiceType` read from the installed package is
     *     dataSync (asserted by the caller);
     *   * AOSP android-13 ActiveServices.setServiceForegroundInnerLocked throws
     *     IllegalArgumentException unless the requested type is a subset of the
     *     manifest type, and TurnForegroundService requests dataSync;
     *   * the promotion was accepted (isForeground=true, startForegroundCount>=1),
     *     so the type the platform recorded is the only non-zero type that passes
     *     this declaration.
     * A readback of the stored int is impossible on this image: neither
     * ServiceRecord.dump nor ServiceRecordProto carries the runtime type.
     */
    private fun dataSyncTypeEvidence(record: String) {
        val hex = Regex("""(?:foregroundServiceType|types)\s*=\s*(?:0x)?([0-9a-fA-F]{1,8})""")
            .find(record)
            ?.groupValues
            ?.get(1)
        if (hex == null) {
            System.out.println(
                "PDSH_API33_FGS_TYPE_READBACK_BLOCKED: API ${Build.VERSION.SDK_INT} " +
                    "ServiceRecord dump carries no foreground-service type field",
            )
            return
        }
        assertEquals(
            "a dump that exposes the runtime type must report dataSync (0x1)",
            ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC,
            hex.toInt(16),
        )
    }

    private fun shellCommand(command: String): String {
        val fd = InstrumentationRegistry.getInstrumentation()
            .uiAutomation
            .executeShellCommand(command)
        return ParcelFileDescriptor.AutoCloseInputStream(fd)
            .use { it.readBytes().toString(Charsets.UTF_8) }
    }

    /** `dumpsys activity services` prints one `* ServiceRecord{...}` block per service. */
    private fun serviceRecord(dump: String, serviceClass: String): String {
        val marker = "* ServiceRecord{"
        return dump.split(marker)
            .firstOrNull { it.contains(serviceClass) }
            ?.let { marker + it }
            ?: throw AssertionError(
                "no ServiceRecord for $serviceClass in `dumpsys activity services`:\n$dump",
            )
    }

    private companion object {
        const val FALLBACK_API: Int = 33
        const val TAG: String = "PDSHApi33Fallback"
    }
}
