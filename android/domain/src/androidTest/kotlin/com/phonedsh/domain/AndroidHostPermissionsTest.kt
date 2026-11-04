// Instrumented evidence for the phone-permission readings.
// SPDX-License-Identifier: MIT
//
// The host suite (`:app`'s `HostPhonePermissionsTest`) proves the row-by-row mapping
// from a fixed reading set. This test proves the *readings* are the running device's
// and not a default: every assertion compares `AndroidHostPermissions`' answer with a
// second, independent read of the same OS fact, so a stubbed value would have to be
// stubbed twice in agreement.
//
// It deliberately asserts nothing about *which* permissions this test app declares:
// the readings are compared with the platform's own answer, so the test passes on a
// bare test APK and on the demo app's merged manifest alike.
package com.phonedsh.domain.device

import android.app.NotificationManager
import android.app.admin.DevicePolicyManager
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class AndroidHostPermissionsTest {
    private val context: Context = ApplicationProvider.getApplicationContext()

    private fun read(): HostPermissionReadings =
        AndroidHostPermissions(context, AndroidDeviceCapabilities.platformFacts(context)).read()

    @Test
    fun theApiLevelIsTheRunningDevices() {
        assertEquals(Build.VERSION.SDK_INT, read().sdkInt)
        assertEquals(
            AndroidDeviceCapabilities.platformFacts(context).sdkInt,
            read().sdkInt,
        )
    }

    @Test
    fun declaredPermissionsAreTheMergedManifests() {
        val expected = declaredPermissions()
        assertEquals(expected, read().declaredPermissions)
        // The page's 通知 row is about this permission: it must be part of the list
        // whenever the app that asks for it declares it, and never invented when it
        // does not.
        assertEquals(
            AndroidHostPermissions.POST_NOTIFICATIONS in expected,
            read().declares(AndroidHostPermissions.POST_NOTIFICATIONS),
        )
    }

    @Test
    fun grantedPermissionsAreExactlyThePlatformsGrantedOnes() {
        val readings = read()
        // A granted permission is always declared (the data class refuses otherwise).
        assertTrue(readings.declaredPermissions.containsAll(readings.grantedPermissions))
        readings.declaredPermissions.forEach { permission ->
            assertEquals(
                "grant state reported for $permission",
                context.checkSelfPermission(permission) == PackageManager.PERMISSION_GRANTED,
                readings.granted(permission),
            )
        }
    }

    @Test
    fun hardwarePresenceMatchesThePackageManager() {
        val readings = read()
        val manager = context.packageManager

        assertEquals(manager.hasSystemFeature(PackageManager.FEATURE_CAMERA_ANY), readings.cameraPresent)
        assertEquals(manager.hasSystemFeature(PackageManager.FEATURE_MICROPHONE), readings.microphonePresent)
        assertEquals(manager.hasSystemFeature(PackageManager.FEATURE_LOCATION), readings.locationPresent)
        assertEquals(
            listOf(
                PackageManager.FEATURE_FINGERPRINT,
                PackageManager.FEATURE_FACE,
                PackageManager.FEATURE_IRIS,
            ).any(manager::hasSystemFeature),
            readings.biometricHardwarePresent,
        )
    }

    @Test
    fun theNotificationAppOpIsTheManagersAnswer() {
        val manager = context.getSystemService(NotificationManager::class.java)
        val readings = read()
        assertEquals(manager.areNotificationsEnabled(), readings.notificationsEnabled)
        assertEquals(manager.isNotificationPolicyAccessGranted, readings.notificationPolicyAccessGranted)
    }

    @Test
    fun noDeviceAdminMeansNoPolicyDenial() {
        val manager = context.getSystemService(Context.DEVICE_POLICY_SERVICE) as DevicePolicyManager
        val admins = manager.activeAdmins
        val readings = read()
        // The reader only reports a policy denial for a declared permission an active
        // admin denies; a device with no admin (every emulator, and this probe's target)
        // therefore reports none, rather than a default.
        if (admins.isNullOrEmpty()) {
            assertTrue(readings.policyDeniedPermissions.isEmpty())
        }
        assertTrue(readings.declaredPermissions.containsAll(readings.policyDeniedPermissions))
    }

    @Suppress("DEPRECATION") // the flags-free overload predates API 33
    private fun declaredPermissions(): Set<String> =
        context.packageManager
            .getPackageInfo(context.packageName, PackageManager.GET_PERMISSIONS)
            .requestedPermissions
            ?.toSet()
            ?: emptySet()
}
