// The 23 telephone-capability rows, asserted one by one.
// SPDX-License-Identifier: MIT
//
// This is the lane's contract test: `AndroidHostPermissions` reads the platform, but
// the *decision* about what each of the page's 23 rows may say lives in
// `HostPhonePermissions.kt`. So each case below feeds a fixed set of readings and
// asserts the whole matrix — which row carries which status, and what the page then
// prints — instead of spot-checking one capability.
//
// The four profiles are the ones that matter:
//   * this app's real shape: it declares `POST_NOTIFICATIONS` (through the merged
//     WorkManager manifest) and no other runtime permission, so almost every row is
//     unread and the page prints no line for it;
//   * a device without the hardware/services: every prerequisite read is false, and
//     the rows really do say 当前设备不可用;
//   * a hypothetical host that declares and holds every permission: the permission
//     rows turn 已允许, which is what proves the mapping is not stuck on 未知;
//   * the three denial states Android can express: a disabled notification app-op
//     (已拒绝), a device-admin denial (受系统限制), and a *partial* photo grant that
//     must NOT become 部分允许（N）.
package com.phonedsh.probe

import com.phonedsh.domain.device.AndroidHostPermissions
import com.phonedsh.domain.device.HostPermissionReadings
import com.phonedsh.ui.UiStrings
import com.phonedsh.ui.page.PhoneCapability
import com.phonedsh.ui.page.PhoneCapabilityStatus
import com.phonedsh.ui.page.PhonePermissionsFacts
import com.phonedsh.ui.page.PhonePermissionsScreenState
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class HostPhonePermissionsTest {
    // -----------------------------------------------------------------------
    // The matrix, row by row
    // -----------------------------------------------------------------------

    @Test
    fun thisAppsOwnShapeReportsOnlyWhatItCanDefend() {
        // What the merged manifest really declares: POST_NOTIFICATIONS comes from the
        // WorkManager AAR, FOREGROUND_SERVICE is a normal permission granted at
        // install, and no other runtime permission is declared at all.
        val facts = facts(
            readings(
                sdkInt = 35,
                declared = setOf(
                    AndroidHostPermissions.POST_NOTIFICATIONS,
                    "android.permission.FOREGROUND_SERVICE",
                    "android.permission.INTERNET",
                ),
                granted = setOf(
                    "android.permission.FOREGROUND_SERVICE",
                    "android.permission.INTERNET",
                ),
                notificationsEnabled = false,
            ),
        )

        assertEquals(
            listOf(
                // 通讯录 / 日历: READ_CONTACTS / READ_CALENDAR are not declared, so the
                // platform reports no grant state to read; the device has the data.
                Row(PhoneCapability.CONTACTS, null, null),
                Row(PhoneCapability.CALENDAR, null, null),
                // Android has no reminders framework at all.
                Row(PhoneCapability.REMINDERS, PhoneCapabilityStatus.Unavailable, UNAVAILABLE),
                // Health Connect: this app declares none of its per-type permissions,
                // and the module's presence is not readable without a `<queries>`
                // element, so the row reports nothing (see the mapping's comment).
                Row(PhoneCapability.HEALTH, null, null),
                Row(PhoneCapability.PHOTOS, null, null),
                Row(PhoneCapability.CAMERA, null, null),
                Row(PhoneCapability.MICROPHONE, null, null),
                Row(PhoneCapability.SPEECH, null, null),
                Row(PhoneCapability.LOCATION, null, null),
                Row(PhoneCapability.MOTION, null, null),
                Row(PhoneCapability.BLUETOOTH, null, null),
                // Android has no local-network authorization to read, and the page
                // prints its own 未验证 · 点击测试 for a notDetermined 本地网络 row — a
                // label this host does not back with a test (see the finding below).
                Row(PhoneCapability.LOCAL_NETWORK, null, LOCAL_NETWORK_UNVERIFIED),
                // Declared, never granted, and this host never asks: 未请求 — which the
                // page renders as no line at all, not as 未知 and not as 已拒绝.
                Row(PhoneCapability.NOTIFICATIONS, PhoneCapabilityStatus.NotDetermined, null),
                // No DND access, so the interruption filter cannot be read.
                Row(PhoneCapability.BIOMETRICS, null, null),
                Row(PhoneCapability.FOCUS, PhoneCapabilityStatus.NotDetermined, null),
                Row(PhoneCapability.LIVE_ACTIVITY, PhoneCapabilityStatus.Unavailable, UNAVAILABLE),
                Row(PhoneCapability.SHORTCUTS, PhoneCapabilityStatus.Unavailable, UNAVAILABLE),
                // SAF grants a folder per URI, and no tree has been picked.
                Row(PhoneCapability.FILES_FOLDER, null, null),
                Row(PhoneCapability.CLIPBOARD, null, null),
                // Always on, no permission: the page prints 常开 for it anyway.
                Row(PhoneCapability.DEVICE, PhoneCapabilityStatus.Authorized, ALWAYS_ON),
                Row(PhoneCapability.LOCATION_ALWAYS, null, null),
                Row(PhoneCapability.HOMEKIT, PhoneCapabilityStatus.Unavailable, UNAVAILABLE),
                Row(PhoneCapability.MUSIC, null, null),
            ),
            rowsOf(facts),
        )
    }

    @Test
    fun aDeviceWithoutTheHardwareSaysUnavailable() {
        val facts = facts(
            readings(
                sdkInt = 33,
                camera = false,
                microphone = false,
                location = false,
                bluetooth = false,
                biometric = false,
                deviceSecure = false,
                stepCounter = false,
                speech = false,
            ),
        )

        assertEquals(
            listOf(
                Row(PhoneCapability.CONTACTS, null, null),
                Row(PhoneCapability.CALENDAR, null, null),
                Row(PhoneCapability.REMINDERS, PhoneCapabilityStatus.Unavailable, UNAVAILABLE),
                Row(PhoneCapability.HEALTH, null, null),
                Row(PhoneCapability.PHOTOS, null, null),
                Row(PhoneCapability.CAMERA, PhoneCapabilityStatus.Unavailable, UNAVAILABLE),
                Row(PhoneCapability.MICROPHONE, PhoneCapabilityStatus.Unavailable, UNAVAILABLE),
                Row(PhoneCapability.SPEECH, PhoneCapabilityStatus.Unavailable, UNAVAILABLE),
                Row(PhoneCapability.LOCATION, PhoneCapabilityStatus.Unavailable, UNAVAILABLE),
                Row(PhoneCapability.MOTION, PhoneCapabilityStatus.Unavailable, UNAVAILABLE),
                Row(PhoneCapability.BLUETOOTH, PhoneCapabilityStatus.Unavailable, UNAVAILABLE),
                Row(PhoneCapability.LOCAL_NETWORK, null, LOCAL_NETWORK_UNVERIFIED),
                // API 33: the permission exists and is not declared, so nothing is read.
                Row(PhoneCapability.NOTIFICATIONS, null, null),
                Row(PhoneCapability.BIOMETRICS, PhoneCapabilityStatus.Unavailable, UNAVAILABLE),
                Row(PhoneCapability.FOCUS, PhoneCapabilityStatus.NotDetermined, null),
                Row(PhoneCapability.LIVE_ACTIVITY, PhoneCapabilityStatus.Unavailable, UNAVAILABLE),
                Row(PhoneCapability.SHORTCUTS, PhoneCapabilityStatus.Unavailable, UNAVAILABLE),
                Row(PhoneCapability.FILES_FOLDER, null, null),
                Row(PhoneCapability.CLIPBOARD, null, null),
                Row(PhoneCapability.DEVICE, PhoneCapabilityStatus.Authorized, ALWAYS_ON),
                Row(PhoneCapability.LOCATION_ALWAYS, PhoneCapabilityStatus.Unavailable, UNAVAILABLE),
                Row(PhoneCapability.HOMEKIT, PhoneCapabilityStatus.Unavailable, UNAVAILABLE),
                Row(PhoneCapability.MUSIC, null, null),
            ),
            rowsOf(facts),
        )
    }

    @Test
    fun aHostThatDeclaresAndHoldsEverythingReportsAuthorized() {
        val all = setOf(
            AndroidHostPermissions.READ_CONTACTS,
            AndroidHostPermissions.READ_CALENDAR,
            AndroidHostPermissions.READ_MEDIA_IMAGES,
            AndroidHostPermissions.CAMERA,
            AndroidHostPermissions.RECORD_AUDIO,
            AndroidHostPermissions.ACCESS_FINE_LOCATION,
            AndroidHostPermissions.ACCESS_COARSE_LOCATION,
            AndroidHostPermissions.ACCESS_BACKGROUND_LOCATION,
            AndroidHostPermissions.ACTIVITY_RECOGNITION,
            AndroidHostPermissions.BLUETOOTH_SCAN,
            AndroidHostPermissions.POST_NOTIFICATIONS,
        )
        val facts = facts(
            readings(
                sdkInt = 35,
                declared = all,
                granted = all,
                notificationsEnabled = true,
                dndAccess = true,
            ),
        )

        assertEquals(
            listOf(
                Row(PhoneCapability.CONTACTS, PhoneCapabilityStatus.Authorized, AUTHORIZED),
                Row(PhoneCapability.CALENDAR, PhoneCapabilityStatus.Authorized, AUTHORIZED),
                Row(PhoneCapability.REMINDERS, PhoneCapabilityStatus.Unavailable, UNAVAILABLE),
                Row(PhoneCapability.HEALTH, null, null),
                Row(PhoneCapability.PHOTOS, PhoneCapabilityStatus.Authorized, AUTHORIZED),
                Row(PhoneCapability.CAMERA, PhoneCapabilityStatus.Authorized, AUTHORIZED),
                Row(PhoneCapability.MICROPHONE, PhoneCapabilityStatus.Authorized, AUTHORIZED),
                Row(PhoneCapability.SPEECH, PhoneCapabilityStatus.Authorized, AUTHORIZED),
                Row(PhoneCapability.LOCATION, PhoneCapabilityStatus.Authorized, AUTHORIZED),
                Row(PhoneCapability.MOTION, PhoneCapabilityStatus.Authorized, AUTHORIZED),
                Row(PhoneCapability.BLUETOOTH, PhoneCapabilityStatus.Authorized, AUTHORIZED),
                Row(PhoneCapability.LOCAL_NETWORK, null, LOCAL_NETWORK_UNVERIFIED),
                Row(PhoneCapability.NOTIFICATIONS, PhoneCapabilityStatus.Authorized, AUTHORIZED),
                // Still not an OS authorization on Android: the app's own switch.
                Row(PhoneCapability.BIOMETRICS, null, null),
                Row(PhoneCapability.FOCUS, PhoneCapabilityStatus.Authorized, AUTHORIZED),
                Row(PhoneCapability.LIVE_ACTIVITY, PhoneCapabilityStatus.Unavailable, UNAVAILABLE),
                Row(PhoneCapability.SHORTCUTS, PhoneCapabilityStatus.Unavailable, UNAVAILABLE),
                Row(PhoneCapability.FILES_FOLDER, null, null),
                Row(PhoneCapability.CLIPBOARD, null, null),
                Row(PhoneCapability.DEVICE, PhoneCapabilityStatus.Authorized, ALWAYS_ON),
                Row(PhoneCapability.LOCATION_ALWAYS, PhoneCapabilityStatus.Authorized, AUTHORIZED),
                Row(PhoneCapability.HOMEKIT, PhoneCapabilityStatus.Unavailable, UNAVAILABLE),
                Row(PhoneCapability.MUSIC, null, null),
            ),
            rowsOf(facts),
        )
    }

    // -----------------------------------------------------------------------
    // The three denial states Android really reports
    // -----------------------------------------------------------------------

    @Test
    fun aGrantedPermissionWithNotificationsSwitchedOffIsDenied() {
        val facts = facts(
            readings(
                sdkInt = 35,
                declared = setOf(AndroidHostPermissions.POST_NOTIFICATIONS),
                granted = setOf(AndroidHostPermissions.POST_NOTIFICATIONS),
                notificationsEnabled = false,
            ),
        )

        assertEquals(PhoneCapabilityStatus.Denied, facts.statuses?.get(PhoneCapability.NOTIFICATIONS))
        val row = rowState(facts, PhoneCapability.NOTIFICATIONS)
        assertEquals(UiStrings.PHONE_PERMISSIONS_STATUS_DENIED, row.statusLabel)
        // 已拒绝 is the one state whose only repair is the system settings app.
        assertTrue(row.showsOpenSettings)
    }

    @Test
    fun aDeviceAdminDenialIsRestricted() {
        val facts = facts(
            readings(
                sdkInt = 35,
                declared = setOf(AndroidHostPermissions.CAMERA),
                policyDenied = setOf(AndroidHostPermissions.CAMERA),
            ),
        )

        assertEquals(PhoneCapabilityStatus.Restricted, facts.statuses?.get(PhoneCapability.CAMERA))
        val row = rowState(facts, PhoneCapability.CAMERA)
        assertEquals(UiStrings.PHONE_PERMISSIONS_STATUS_RESTRICTED, row.statusLabel)
        // 受系统限制 blocks interaction: the app cannot fix it.
        assertTrue(row.blocked)
    }

    @Test
    fun aPartialPhotoGrantIsNotFabricatedAsLimited() {
        // Android 14's READ_MEDIA_VISUAL_USER_SELECTED is a real partial grant, but the
        // platform reports no count. 部分允许（N） would need an invented N, so this
        // host reports no photos status instead — and never `Limited`.
        val facts = facts(
            readings(
                sdkInt = 34,
                declared = setOf("android.permission.READ_MEDIA_VISUAL_USER_SELECTED"),
                granted = setOf("android.permission.READ_MEDIA_VISUAL_USER_SELECTED"),
            ),
        )

        assertNull(facts.statuses?.get(PhoneCapability.PHOTOS))
        assertFalse(rowState(facts, PhoneCapability.PHOTOS).status is PhoneCapabilityStatus.Limited)
    }

    // -----------------------------------------------------------------------
    // What the page prints, and the one thing it cannot be told
    // -----------------------------------------------------------------------

    @Test
    fun anUnreadRowPrintsNoLineWhileAWholeUnreadMapPrintsUnknown() {
        // The facts' map cannot hold a null value, and the page turns a missing entry
        // into `NotDetermined` (`PhonePermissionsPage.kt:604`), for which it prints no
        // status line. That is the host's only way to say "I read nothing here" while
        // it reports other rows; 未知 is reserved for a *whole* map of `null`.
        val sparse = facts(readings(sdkInt = 35))
        assertNull(sparse.statuses?.get(PhoneCapability.CAMERA))
        assertNull(rowState(sparse, PhoneCapability.CAMERA).statusLabel)

        val unread = PhonePermissionsScreenState.from(PhonePermissionsFacts())
        assertEquals(false, unread.statusesKnown)
        val labels = unread.groups.flatMap { it.rows }.associate { it.capability to it.statusLabel }
        labels.forEach { (capability, label) ->
            assertEquals(
                if (capability == PhoneCapability.DEVICE) ALWAYS_ON else UiStrings.UNKNOWN,
                label,
            )
        }
    }

    @Test
    fun theHostReportsNoAuditAndNoEnabledCapability() {
        val facts = facts(readings(sdkInt = 35))

        // No capability-use audit exists on this host: `null`, never an empty list.
        assertNull(facts.audit)
        assertNull(PhonePermissionsScreenState.from(facts).audit)
        // Nothing is enabled because nothing turns a capability on here, and no
        // request is in flight because this build never calls `requestPermissions`.
        assertTrue(facts.enabled.isEmpty())
        assertNull(facts.requesting)
        // The map itself is reported: this host *did* read, unlike a host that did not.
        assertTrue(facts.statuses != null)
        assertTrue(PhonePermissionsScreenState.from(facts).statusesKnown)
    }

    @Test
    fun anUnreadLocalNetworkRowStillPrintsThePagesClickTestLabel() {
        // The one row where the page's notDetermined fallback is *visible*: it
        // special-cases 本地网络 (`PhonePermissionsPage.kt:641`) and prints
        // 未验证 · 点击测试 for a status the host never reported. The host cannot
        // suppress it without inventing a different status for the row (Android has no
        // local-network authorization at all), so this test pins the over-promise
        // instead of hiding it: the label promises a test this host does not perform.
        val facts = facts(readings(sdkInt = 35))

        assertNull(facts.statuses?.get(PhoneCapability.LOCAL_NETWORK))
        assertEquals(
            UiStrings.PHONE_PERMISSIONS_STATUS_LOCAL_NETWORK_UNVERIFIED,
            rowState(facts, PhoneCapability.LOCAL_NETWORK).statusLabel,
        )
    }

    // -----------------------------------------------------------------------
    // Fixtures
    // -----------------------------------------------------------------------

    /** One expected row: what the host reports, and the line the page prints for it. */
    private data class Row(
        val capability: PhoneCapability,
        val status: PhoneCapabilityStatus?,
        val label: String?,
    )

    private fun rowsOf(facts: PhonePermissionsFacts): List<Row> {
        val state = PhonePermissionsScreenState.from(facts)
        val rendered = state.groups
            .flatMap { it.rows }
            .associate { row -> row.capability to row.statusLabel }
        return PhoneCapability.matrix.map { capability ->
            Row(capability, facts.statuses?.get(capability), rendered[capability])
        }
    }

    private fun rowState(
        facts: PhonePermissionsFacts,
        capability: PhoneCapability,
    ) = PhonePermissionsScreenState.from(facts).groups
        .flatMap { it.rows }
        .first { it.capability == capability }

    private fun facts(readings: HostPermissionReadings): PhonePermissionsFacts =
        phonePermissionsFacts(readings)

    /**
     * A reading set with every prerequisite present by default, so a case only has to
     * state the parameters it is about.
     */
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
    ): HostPermissionReadings {
        return HostPermissionReadings(
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

    private companion object {
        private val UNAVAILABLE: String = UiStrings.PHONE_PERMISSIONS_STATUS_UNAVAILABLE
        private val AUTHORIZED: String = UiStrings.PHONE_PERMISSIONS_STATUS_AUTHORIZED
        private val ALWAYS_ON: String = UiStrings.PHONE_PERMISSIONS_STATUS_ALWAYS_ON
        private val LOCAL_NETWORK_UNVERIFIED: String =
            UiStrings.PHONE_PERMISSIONS_STATUS_LOCAL_NETWORK_UNVERIFIED
    }
}
