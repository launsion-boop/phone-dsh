// The background lane's fact mapping, asserted row by row.
// SPDX-License-Identifier: MIT
//
// `HostBackground` reads the platform; the *decision* about what the runtime page
// and the settings page may say lives in the pure functions this file exercises.
// The cases below are the ones the page can actually be in:
//
//   * a normal install: the merged manifest has every component, notifications are
//     granted, so the fact is YES — the answer the old hard-coded `FactState.NO`
//     could never produce;
//   * each of the three ways the notification link can be degraded;
//   * an APK whose merge dropped the components, on both sides of the Android 14
//     line, where UIDT does not exist yet;
//   * every API level 26..35 with nothing declared, which must never be YES.
//
// The last test reads `:dsh`'s manifest: the components live there, and a lane
// that removes them would leave this app calling a surface the APK does not have.
// That is the failure the old manifest comment claimed, so it deserves a guard.
package com.phonedsh.probe

import com.phonedsh.dsh.background.NotificationCapability
import com.phonedsh.dsh.background.TurnStartResult
import com.phonedsh.ui.page.FactState
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

class HostBackgroundTest {
    // -----------------------------------------------------------------------
    // The fact: YES only when every precondition was measured true
    // -----------------------------------------------------------------------

    @Test
    fun aNormalInstallOnApi35ReportsTheWindowAsUsable() {
        val fact = backgroundWindowFact(
            declaration = declared(),
            capability = granted(),
            sdkInt = 35,
        )

        assertEquals(FactState.YES, fact.state)
        assertNull(fact.detail)
    }

    @Test
    fun belowApi34TheForegroundServiceIsTheOnlyChannel() {
        // UIDT does not exist before API 34, so a job service alone cannot open a
        // window; the same declaration becomes usable one API level later.
        val noService = declared().copy(foregroundService = false, dataSyncType = false)

        assertEquals(
            FactState.NO,
            backgroundWindowFact(noService, granted(), sdkInt = 33).state,
        )
        assertEquals(
            FactState.YES,
            backgroundWindowFact(noService, granted(), sdkInt = 34).state,
        )
    }

    @Test
    fun aMissingUserInitiatedJobStillFallsBackToTheForegroundService() {
        val noJobService = declared().copy(jobService = false, userInitiatedPermission = false)

        assertEquals(FactState.YES, backgroundWindowFact(noJobService, granted(), 35).state)
        // The same gap below API 34 changes nothing: the service was the channel.
        assertEquals(FactState.YES, backgroundWindowFact(noJobService, granted(), 33).state)
    }

    // -----------------------------------------------------------------------
    // The notification link is the first gate, and its reason is specific
    // -----------------------------------------------------------------------

    @Test
    fun deniedRuntimePermissionIsNoAndNamesThePermission() {
        val fact = backgroundWindowFact(
            declaration = declared(),
            capability = capability(
                runtime = NotificationCapability.RuntimePermission.DENIED,
            ),
            sdkInt = 35,
        )

        assertEquals(FactState.NO, fact.state)
        assertNotNull(fact.detail)
        assertTrue(fact.detail!!.contains("POST_NOTIFICATIONS"))
        // The detail must not blame the manifest: the components are all there.
        assertTrue(!fact.detail!!.contains("缺少后台组件"))
    }

    @Test
    fun appLevelNotificationsOffIsNo() {
        val fact = backgroundWindowFact(
            declared(),
            capability(notificationsEnabled = false),
            35,
        )

        assertEquals(FactState.NO, fact.state)
        assertTrue(fact.detail!!.contains("应用通知被关闭"))
    }

    @Test
    fun aBlockedProgressChannelIsNo() {
        val fact = backgroundWindowFact(
            declared(),
            capability(progressChannelBlocked = true),
            35,
        )

        assertEquals(FactState.NO, fact.state)
        assertTrue(fact.detail!!.contains("通知频道"))
    }

    // -----------------------------------------------------------------------
    // The regression: an empty APK is NO on every API level, never a promise
    // -----------------------------------------------------------------------

    @Test
    fun nothingDeclaredIsNoOnEveryApiLevel() {
        val empty = BackgroundDeclaration()
        for (sdkInt in 26..35) {
            val fact = backgroundWindowFact(empty, granted(), sdkInt)
            assertEquals("sdk $sdkInt", FactState.NO, fact.state)
            assertNotNull("sdk $sdkInt", fact.detail)
            assertTrue(
                "sdk $sdkInt: ${fact.detail}",
                fact.detail!!.startsWith("APK 缺少后台组件："),
            )
        }
    }

    @Test
    fun theMissingComponentDetailNamesWhatIsMissing() {
        val fact = backgroundWindowFact(BackgroundDeclaration(), granted(), 35)

        // Below 34 the message must not claim a UIDT job is missing: that channel
        // does not exist on the device, so naming it would send the reader looking
        // for a component the platform never asks for.
        val below = backgroundWindowFact(BackgroundDeclaration(), granted(), 33)
        assertTrue(below.detail!!.contains("前台服务"))
        assertTrue(!below.detail!!.contains("UIDT"))
        assertTrue(fact.detail!!.contains("UIDT job 服务"))
        assertTrue(fact.detail!!.contains("RUN_USER_INITIATED_JOBS"))
    }

    // -----------------------------------------------------------------------
    // The settings page's notifications row
    // -----------------------------------------------------------------------

    @Test
    fun theNotificationsRowIsTheSamePredicateTheChannelUses() {
        assertEquals(FactState.YES, notificationFact(granted()))
        assertEquals(
            FactState.NO,
            notificationFact(capability(notificationsEnabled = false)),
        )
        assertEquals(
            FactState.NO,
            notificationFact(capability(progressChannelBlocked = true)),
        )
    }

    // -----------------------------------------------------------------------
    // What the platform answered
    // -----------------------------------------------------------------------

    @Test
    fun everyStartResultHasItsOwnLogLine() {
        assertEquals(
            "uidt_scheduled:8401",
            describeStartResult(TurnStartResult.UserInitiatedJobScheduled(8401)),
        )
        assertEquals(
            "data_sync_foreground_service",
            describeStartResult(TurnStartResult.DataSyncForegroundServiceStarted),
        )
        assertEquals(
            "foreground_only:APP_NOT_VISIBLE",
            describeStartResult(
                TurnStartResult.ForegroundOnly(
                    TurnStartResult.ForegroundOnlyReason.APP_NOT_VISIBLE,
                ),
            ),
        )
    }

    // -----------------------------------------------------------------------
    // The surface this app calls into is still declared by :dsh
    // -----------------------------------------------------------------------

    @Test
    fun dshManifestStillDeclaresEveryBackgroundComponent() {
        val manifest = dshManifest()
        val text = manifest.readText()

        listOf(
            "TurnForegroundService",
            "TurnJobService",
            "TurnStopReceiver",
            "BootReceiver",
        ).forEach { component ->
            assertTrue("$component missing from ${manifest.path}", text.contains(component))
        }
        listOf(
            "android.permission.FOREGROUND_SERVICE",
            "android.permission.FOREGROUND_SERVICE_DATA_SYNC",
            "android.permission.RUN_USER_INITIATED_JOBS",
            "android.permission.POST_NOTIFICATIONS",
            "android.permission.RECEIVE_BOOT_COMPLETED",
        ).forEach { permission ->
            assertTrue("$permission missing from ${manifest.path}", text.contains(permission))
        }
        // The stopWithTask decision belongs to the plan (no invisible window after
        // the task is removed), and it is a property of this declaration.
        assertTrue("stopWithTask missing from ${manifest.path}", text.contains("stopWithTask=\"true\""))
        assertTrue("dataSync type missing from ${manifest.path}", text.contains("dataSync"))
    }

    private fun dshManifest(): File {
        // Unit tests run with the module directory as the working directory; the
        // repo-root spelling is the fallback for a runner that starts higher up.
        val candidates = listOf(
            File("../dsh/src/main/AndroidManifest.xml"),
            File("android/dsh/src/main/AndroidManifest.xml"),
        )
        return candidates.firstOrNull { it.isFile }
            ?: throw AssertionError(
                "cannot find :dsh's manifest from ${File(".").absolutePath}; " +
                    "looked at ${candidates.joinToString { it.absolutePath }}",
            )
    }

    // -----------------------------------------------------------------------
    // Fixtures
    // -----------------------------------------------------------------------

    private fun declared() = BackgroundDeclaration(
        foregroundService = true,
        dataSyncType = true,
        dataSyncPermission = true,
        jobService = true,
        userInitiatedPermission = true,
        stopReceiver = true,
        bootReceiver = true,
    )

    private fun granted() = capability()

    private fun capability(
        runtime: NotificationCapability.RuntimePermission =
            NotificationCapability.RuntimePermission.GRANTED,
        notificationsEnabled: Boolean = true,
        progressChannelBlocked: Boolean = false,
    ) = NotificationCapability(
        runtimePermission = runtime,
        notificationsEnabled = notificationsEnabled,
        progressChannelBlocked = progressChannelBlocked,
    )
}
