// Which of the 23 rows can really raise a system request, and what the page does
// with that answer.
// SPDX-License-Identifier: MIT
//
// The lane's rule is one sentence long — **a capability with no raisable system
// request must not offer 请求** — and it has two halves that a JVM test can hold:
//
//  1. the decision table (`requestablePermissions` / `phoneGrantRoutes`) is a pure
//     function of the host readings, so every branch is asserted here against a fixed
//     snapshot instead of against an emulator;
//  2. the page is a pure function of its facts, so the *rendered* action of each row
//     is asserted for the same snapshots. That second half is what proves the fake
//     controls are gone: before this lane a row with no status fell back to
//     `NotDetermined`, whose `canRequest` is true, so 16 of the 23 rows opened the
//     confirmation for a dialog that could never appear.
package com.phonedsh.probe

import com.phonedsh.domain.device.AndroidHostPermissions
import com.phonedsh.domain.device.HostPermissionReadings
import com.phonedsh.ui.page.PhoneCapability
import com.phonedsh.ui.page.PhoneCapabilityAction
import com.phonedsh.ui.page.PhoneCapabilityStatus
import com.phonedsh.ui.page.PhoneGrantRoute
import com.phonedsh.ui.page.PhonePermissionsScreenState
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class PhonePermissionRequestsTest {
    // -----------------------------------------------------------------------
    // This build's shape: one declared runtime permission
    // -----------------------------------------------------------------------

    @Test
    fun onlyTheOneDeclaredRuntimePermissionIsRequestable() {
        // The merged manifest really declares POST_NOTIFICATIONS (through :dsh's
        // progress-notification channel) and none of the page's other runtime
        // permissions; the platform answers DENIED without a dialog for every one of
        // those, so they must not be armed.
        val readings = readings(
            sdkInt = 35,
            declared = setOf(
                AndroidHostPermissions.POST_NOTIFICATIONS,
                "android.permission.FOREGROUND_SERVICE",
                "android.permission.INTERNET",
            ),
            granted = setOf("android.permission.FOREGROUND_SERVICE", "android.permission.INTERNET"),
        )
        val routes = phoneGrantRoutes(readings)

        // Every row has an answer: no capability is left to the page's fallback.
        assertEquals(PhoneCapability.matrix.toSet(), routes.keys)
        assertEquals(
            listOf(PhoneCapability.NOTIFICATIONS),
            routes.filterValues { it == PhoneGrantRoute.REQUEST }.keys.toList(),
        )
        // DND access is special access, and its only switch is the settings app's.
        assertEquals(
            listOf(PhoneCapability.FOCUS),
            routes.filterValues { it == PhoneGrantRoute.SYSTEM_SETTINGS }.keys.toList(),
        )
        // 通讯录 has a runtime permission in the platform, but this APK declares none:
        // a 请求 there would open nothing, so the row says NONE (no control) rather
        // than arming a dialog the system drops.
        assertEquals(PhoneGrantRoute.NONE, routes[PhoneCapability.CONTACTS])
        assertEquals(PhoneGrantRoute.NONE, routes[PhoneCapability.CAMERA])
        assertEquals(PhoneGrantRoute.NONE, routes[PhoneCapability.LOCATION_ALWAYS])
        // The four with no Android mechanism at all.
        listOf(
            PhoneCapability.REMINDERS,
            PhoneCapability.LIVE_ACTIVITY,
            PhoneCapability.SHORTCUTS,
            PhoneCapability.HOMEKIT,
        ).forEach { capability ->
            assertEquals(capability.id, PhoneGrantRoute.NONE, routes[capability])
        }
    }

    @Test
    fun theRequestedPermissionMatchesTheRowsMechanism() {
        val declared = allRuntimePermissions()
        val readings = readings(sdkInt = 35, declared = declared, granted = declared)

        assertEquals(
            listOf(AndroidHostPermissions.READ_CONTACTS),
            requestablePermissions(PhoneCapability.CONTACTS, readings),
        )
        assertEquals(
            listOf(AndroidHostPermissions.READ_MEDIA_IMAGES),
            requestablePermissions(PhoneCapability.PHOTOS, readings),
        )
        // One microphone grant serves both rows.
        assertEquals(
            listOf(AndroidHostPermissions.RECORD_AUDIO),
            requestablePermissions(PhoneCapability.SPEECH, readings),
        )
        // Android 12+ needs precise and approximate in the same request, or the
        // platform drops it.
        assertEquals(
            listOf(
                AndroidHostPermissions.ACCESS_FINE_LOCATION,
                AndroidHostPermissions.ACCESS_COARSE_LOCATION,
            ),
            requestablePermissions(PhoneCapability.LOCATION, readings),
        )
        // No runtime permission at all: a request set here would be a lie.
        listOf(
            PhoneCapability.REMINDERS,
            PhoneCapability.HEALTH,
            PhoneCapability.LOCAL_NETWORK,
            PhoneCapability.BIOMETRICS,
            PhoneCapability.FOCUS,
            PhoneCapability.LIVE_ACTIVITY,
            PhoneCapability.SHORTCUTS,
            PhoneCapability.FILES_FOLDER,
            PhoneCapability.CLIPBOARD,
            PhoneCapability.DEVICE,
            PhoneCapability.HOMEKIT,
            PhoneCapability.MUSIC,
        ).forEach { capability ->
            assertTrue(
                "${capability.title} has no runtime permission to request",
                requestablePermissions(capability, readings).isEmpty(),
            )
        }
    }

    @Test
    fun aManifestThatDeclaresTheRuntimePermissionsTurnsThoseRowsIntoRequests() {
        // The same table, one manifest change later: nothing in the app has to be
        // edited for 通讯录/相机/定位 to become requestable — the table reads the
        // merged manifest, it does not hardcode a decision.
        val declared = allRuntimePermissions()
        val routes = phoneGrantRoutes(readings(sdkInt = 35, declared = declared))

        listOf(
            PhoneCapability.CONTACTS,
            PhoneCapability.CALENDAR,
            PhoneCapability.PHOTOS,
            PhoneCapability.CAMERA,
            PhoneCapability.MICROPHONE,
            PhoneCapability.SPEECH,
            PhoneCapability.LOCATION,
            PhoneCapability.MOTION,
            PhoneCapability.BLUETOOTH,
            PhoneCapability.NOTIFICATIONS,
        ).forEach { capability ->
            assertEquals(capability.id, PhoneGrantRoute.REQUEST, routes[capability])
        }
        // Background location is the two-step case: from targetSdk 30 the platform
        // raises no dialog for it, so the settings page is the only route — even with
        // the permission declared.
        assertEquals(PhoneGrantRoute.SYSTEM_SETTINGS, routes[PhoneCapability.LOCATION_ALWAYS])
        assertEquals(PhoneGrantRoute.NONE, routes[PhoneCapability.FILES_FOLDER])
        assertEquals(PhoneGrantRoute.NONE, routes[PhoneCapability.MUSIC])
    }

    @Test
    fun theApiLevelDecidesWhichPermissionExists() {
        // Below 33 there is no POST_NOTIFICATIONS runtime permission: the app-op is the
        // whole story and only the settings app changes it.
        val pre33 = readings(sdkInt = 32, declared = setOf(AndroidHostPermissions.POST_NOTIFICATIONS))
        assertTrue(requestablePermissions(PhoneCapability.NOTIFICATIONS, pre33).isEmpty())
        assertEquals(
            PhoneGrantRoute.SYSTEM_SETTINGS,
            phoneGrantRoutes(pre33)[PhoneCapability.NOTIFICATIONS],
        )

        // Below 31 the Bluetooth row is a normal permission (install-granted, no
        // prompt) and ACTIVITY_RECOGNITION does not exist below 29.
        val pre31 = readings(
            sdkInt = 30,
            declared = setOf(
                AndroidHostPermissions.BLUETOOTH,
                AndroidHostPermissions.ACTIVITY_RECOGNITION,
            ),
        )
        assertTrue(requestablePermissions(PhoneCapability.BLUETOOTH, pre31).isEmpty())
        assertTrue(requestablePermissions(PhoneCapability.MOTION, pre31).isNotEmpty())

        val pre29 = readings(sdkInt = 28, declared = setOf(AndroidHostPermissions.ACTIVITY_RECOGNITION))
        assertTrue(requestablePermissions(PhoneCapability.MOTION, pre29).isEmpty())
    }

    @Test
    fun backgroundLocationIsTwoStepOnAndroid10AndSettingsOnlyAfterIt() {
        val declared = setOf(
            AndroidHostPermissions.ACCESS_FINE_LOCATION,
            AndroidHostPermissions.ACCESS_COARSE_LOCATION,
            AndroidHostPermissions.ACCESS_BACKGROUND_LOCATION,
        )
        // API 29: requestable, but only once the foreground grant exists.
        val foregroundMissing = readings(sdkInt = 29, declared = declared)
        assertTrue(
            requestablePermissions(PhoneCapability.LOCATION_ALWAYS, foregroundMissing).isEmpty(),
        )
        val foregroundGranted = readings(
            sdkInt = 29,
            declared = declared,
            granted = setOf(
                AndroidHostPermissions.ACCESS_FINE_LOCATION,
                AndroidHostPermissions.ACCESS_COARSE_LOCATION,
            ),
        )
        assertEquals(
            listOf(AndroidHostPermissions.ACCESS_BACKGROUND_LOCATION),
            requestablePermissions(PhoneCapability.LOCATION_ALWAYS, foregroundGranted),
        )
        // API 30+: the platform shows no dialog, whatever the grants are.
        val modern = readings(
            sdkInt = 30,
            declared = declared,
            granted = declared - AndroidHostPermissions.ACCESS_BACKGROUND_LOCATION,
        )
        assertTrue(requestablePermissions(PhoneCapability.LOCATION_ALWAYS, modern).isEmpty())
        assertEquals(PhoneGrantRoute.SYSTEM_SETTINGS, phoneGrantRoutes(modern)[PhoneCapability.LOCATION_ALWAYS])
    }

    // -----------------------------------------------------------------------
    // What the page then renders: the fake controls this lane removes
    // -----------------------------------------------------------------------

    @Test
    fun aRowWithNoRequestPathIsNotArmed() {
        // This is the regression the lane exists for. Every one of these rows used to
        // fall back to `NotDetermined` (its `canRequest` is true) and open the
        // confirmation dialog on tap, while 继续 did nothing at all.
        val facts = phonePermissionsFacts(
            readings(
                sdkInt = 35,
                declared = setOf(AndroidHostPermissions.POST_NOTIFICATIONS),
                notificationsEnabled = true,
            ),
        )
        val rows = PhonePermissionsScreenState.from(facts).groups.flatMap { it.rows }
            .associateBy { it.capability }

        listOf(
            PhoneCapability.CONTACTS,
            PhoneCapability.CALENDAR,
            PhoneCapability.HEALTH,
            PhoneCapability.PHOTOS,
            PhoneCapability.CAMERA,
            PhoneCapability.MICROPHONE,
            PhoneCapability.SPEECH,
            PhoneCapability.LOCATION,
            PhoneCapability.MOTION,
            PhoneCapability.BLUETOOTH,
            PhoneCapability.LOCAL_NETWORK,
            PhoneCapability.FILES_FOLDER,
            PhoneCapability.CLIPBOARD,
            PhoneCapability.LOCATION_ALWAYS,
            PhoneCapability.MUSIC,
        ).forEach { capability ->
            assertEquals(
                "${capability.title} must not offer 请求 without a raisable request",
                PhoneCapabilityAction.BLOCKED,
                rows.getValue(capability).action,
            )
            assertFalse(rows.getValue(capability).showsOpenSettings)
        }

        // 专注模式 has no request dialog at all, but the settings app does hold the
        // switch — so that row is the settings gesture, never 请求.
        val focus = rows.getValue(PhoneCapability.FOCUS)
        assertEquals(PhoneCapabilityAction.OPEN_SETTINGS, focus.action)
        assertTrue(focus.showsOpenSettings)
        assertNull("未请求 prints no status line on the baseline", focus.statusLabel)

        // 通知 is the one row a dialog can be raised for in this build.
        assertEquals(PhoneCapabilityAction.REQUEST, rows.getValue(PhoneCapability.NOTIFICATIONS).action)
        // The four the platform cannot provide stay 当前设备不可用 and refuse input.
        listOf(
            PhoneCapability.REMINDERS,
            PhoneCapability.LIVE_ACTIVITY,
            PhoneCapability.SHORTCUTS,
            PhoneCapability.HOMEKIT,
        ).forEach { capability ->
            val row = rows.getValue(capability)
            assertEquals(capability.id, PhoneCapabilityAction.BLOCKED, row.action)
            assertTrue("${capability.title} dims as unavailable", row.blocked)
            assertFalse("${capability.title} must not show 去系统设置", row.showsOpenSettings)
        }
        // 面容确认 is not a system grant at all: the row is the app's own one-shot
        // confirmation, which is neither 请求 nor 去系统设置.
        assertEquals(
            PhoneCapabilityAction.CONFIRM_BIOMETRIC,
            rows.getValue(PhoneCapability.BIOMETRICS).action,
        )
        assertFalse(rows.getValue(PhoneCapability.BIOMETRICS).showsOpenSettings)
        // 设备状态 needs no grant and stays 常开/ALWAYS_ON.
        assertEquals(PhoneCapabilityAction.ALWAYS_ON, rows.getValue(PhoneCapability.DEVICE).action)
    }

    @Test
    fun anAnsweredRefusalTurnsTheRowDeniedAndMovesItToSettings() {
        val readings = readings(
            sdkInt = 35,
            declared = setOf(AndroidHostPermissions.POST_NOTIFICATIONS),
        )
        val asked = setOf(AndroidHostPermissions.POST_NOTIFICATIONS)
        val facts = phonePermissionsFacts(readings, asked = asked)

        assertEquals(PhoneCapabilityStatus.Denied, facts.statuses?.get(PhoneCapability.NOTIFICATIONS))
        val row = PhonePermissionsScreenState.from(facts).groups.flatMap { it.rows }
            .first { it.capability == PhoneCapability.NOTIFICATIONS }
        assertEquals("已拒绝", row.statusLabel)
        // The platform would answer a second request with DENIED and no dialog: the
        // row must not offer one. 不再询问 and the second denial both land here.
        assertEquals(PhoneCapabilityAction.OPEN_SETTINGS, row.action)
        assertTrue(row.showsOpenSettings)

        // Never asked is the only state that may still say 未请求 …
        val unasked = phonePermissionsFacts(readings)
        assertEquals(
            PhoneCapabilityStatus.NotDetermined,
            unasked.statuses?.get(PhoneCapability.NOTIFICATIONS),
        )
        assertEquals(
            PhoneCapabilityAction.REQUEST,
            PhonePermissionsScreenState.from(unasked).groups.flatMap { it.rows }
                .first { it.capability == PhoneCapability.NOTIFICATIONS }.action,
        )
    }

    @Test
    fun aGrantedRowIsEnabledAndAnInFlightRowIsDisarmed() {
        val granted = readings(
            sdkInt = 35,
            declared = setOf(AndroidHostPermissions.POST_NOTIFICATIONS),
            granted = setOf(AndroidHostPermissions.POST_NOTIFICATIONS),
            notificationsEnabled = true,
        )
        val facts = phonePermissionsFacts(granted)
        assertEquals(
            PhoneCapabilityStatus.Authorized,
            facts.statuses?.get(PhoneCapability.NOTIFICATIONS),
        )
        val grantedRow = PhonePermissionsScreenState.from(facts).groups.flatMap { it.rows }
            .first { it.capability == PhoneCapability.NOTIFICATIONS }
        assertEquals(PhoneCapabilityAction.ENABLE, grantedRow.action)

        // While the platform dialog is up, the row is disarmed rather than left with
        // an armed request that would launch a second prompt.
        val inFlight = phonePermissionsFacts(granted, inFlight = PhoneCapability.NOTIFICATIONS)
        val inFlightRow = PhonePermissionsScreenState.from(inFlight).groups.flatMap { it.rows }
            .first { it.capability == PhoneCapability.NOTIFICATIONS }
        assertEquals(PhoneCapabilityAction.BLOCKED, inFlightRow.action)
        assertTrue(inFlightRow.requesting)
    }

    @Test
    fun theSettingsHandoffKnowsWhichPageHoldsTheGrant() {
        // 专注模式's switch is the DND-access page; a runtime permission's is this
        // app's own details page. The page passes the capability precisely so this is
        // decidable — sending a DND row to app settings would be a dead end, because
        // that page does not contain the switch.
        assertEquals(
            "android.settings.NOTIFICATION_POLICY_ACCESS_SETTINGS",
            phonePermissionSettingsAction(PhoneCapability.FOCUS),
        )
        listOf(
            PhoneCapability.CONTACTS,
            PhoneCapability.NOTIFICATIONS,
            PhoneCapability.LOCATION_ALWAYS,
            PhoneCapability.CAMERA,
        ).forEach { capability ->
            assertEquals(
                capability.id,
                "android.settings.APPLICATION_DETAILS_SETTINGS",
                phonePermissionSettingsAction(capability),
            )
        }
    }

    // -----------------------------------------------------------------------
    // Fixtures
    // -----------------------------------------------------------------------

    private fun allRuntimePermissions(): Set<String> = setOf(
        AndroidHostPermissions.READ_CONTACTS,
        AndroidHostPermissions.READ_CALENDAR,
        AndroidHostPermissions.READ_MEDIA_IMAGES,
        AndroidHostPermissions.READ_EXTERNAL_STORAGE,
        AndroidHostPermissions.CAMERA,
        AndroidHostPermissions.RECORD_AUDIO,
        AndroidHostPermissions.ACCESS_FINE_LOCATION,
        AndroidHostPermissions.ACCESS_COARSE_LOCATION,
        AndroidHostPermissions.ACCESS_BACKGROUND_LOCATION,
        AndroidHostPermissions.ACTIVITY_RECOGNITION,
        AndroidHostPermissions.BLUETOOTH_SCAN,
        AndroidHostPermissions.POST_NOTIFICATIONS,
    )

    private fun readings(
        sdkInt: Int,
        declared: Set<String> = emptySet(),
        granted: Set<String> = emptySet(),
        policyDenied: Set<String> = emptySet(),
        notificationsEnabled: Boolean? = null,
        dndAccess: Boolean = false,
        camera: Boolean = true,
        microphone: Boolean = true,
        location: Boolean = true,
        bluetooth: Boolean = true,
        biometric: Boolean = true,
        deviceSecure: Boolean? = true,
        stepCounter: Boolean? = true,
        speech: Boolean? = true,
    ): HostPermissionReadings = HostPermissionReadings(
        sdkInt = sdkInt,
        declaredPermissions = declared,
        grantedPermissions = granted,
        policyDeniedPermissions = policyDenied,
        notificationsEnabled = notificationsEnabled,
        notificationPolicyAccessGranted = dndAccess,
        cameraPresent = camera,
        microphonePresent = microphone,
        locationPresent = location,
        bluetoothPresent = bluetooth,
        biometricHardwarePresent = biometric,
        deviceSecure = deviceSecure,
        stepCounterPresent = stepCounter,
        speechRecognitionAvailable = speech,
    )

}
