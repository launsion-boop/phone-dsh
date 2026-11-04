// The Android readings behind the phone-capability matrix.
// SPDX-License-Identifier: MIT
//
// The 23 capabilities the phone-permissions page draws are iOS's vocabulary. Most
// of them have no Android authorization at all, so the honest reading surface is
// not "the 23 statuses" but the five things Android really reports:
//
//  * which runtime permissions this app's **merged** manifest declares
//    (`GET_PERMISSIONS`) and which of them the platform currently grants
//    (`checkSelfPermission`). A permission the app never declares is *not* denied
//    by the user: the OS simply reports no grant state for it, and that difference
//    is what keeps [HostPermissionReadings.declaredPermissions] separate from
//    [HostPermissionReadings.grantedPermissions];
//  * which of those an active device admin has explicitly denied
//    (`DevicePolicyManager.getPermissionGrantState`), Android's analogue of iOS's
//    parental-control restriction. No admin means no restriction — a measurement,
//    not a default;
//  * the notification app-op (`areNotificationsEnabled()`), the OS's own answer to
//    "may this app notify now". The `POST_NOTIFICATIONS` runtime permission only
//    exists from API 33, but the app-op exists on every level, so this reading is
//    what keeps the 通知 row honest below 33;
//  * notification-policy (DND) access, the grant behind reading focus state;
//  * hardware/service presence: camera, microphone, location, a Bluetooth adapter,
//    biometric hardware plus a secure lock screen (a biometric prompt needs one),
//    a step counter, and a speech-recognition service.
//
// What is *not* here, and why: Health Connect's presence. It is the one capability
// in the page's matrix whose module an ordinary app cannot see — `getPackageInfo`
// and `getPermissionInfo` are both filtered by package visibility on Android 11+
// (measured on the android-35 emulator: `pm list permissions` from the shell shows
// `android.permission.health.READ_EXERCISE_ROUTE`, while the same lookup from the app
// answers NameNotFound), and this app declares no `<queries>` element. Reporting
// "installed" or "absent" from that reading would be a guess, so the phone-permission
// host leaves the 健康 row unread instead.
//
// What this file deliberately does *not* do is turn those readings into the page's
// seven statuses. `Unavailable` in particular means "this device/OS has no such
// capability" (`PhonePermissionsPage.kt:347`), which a *missing manifest
// declaration* does not prove — the device may have three cameras while the app
// asks for none. That mapping lives in `:app` (`HostPhonePermissions.kt`), the one
// module where both vocabularies are visible, and it keeps "not declared" as "no
// status" instead of borrowing a status that would be false.
//
// Every read here is cheap and synchronous (permission/feature/package lookups and
// two notification service calls); like the rest of the capability SPI it is a
// query, not a subscription.

package com.phonedsh.domain.device

import android.app.KeyguardManager
import android.app.NotificationManager
import android.app.admin.DevicePolicyManager
import android.bluetooth.BluetoothManager
import android.content.Context
import android.content.pm.PackageManager
import android.hardware.Sensor
import android.hardware.SensorManager
import android.speech.SpeechRecognizer

/**
 * One reading of the Android state behind the page's 23 phone capabilities.
 *
 * A `null` member means the reading could not be taken (the platform service was
 * missing or refused). It is never turned into "absent": only a `false` reading is
 * evidence of absence, exactly like [AndroidPlatformFacts.totalMemoryBytes]'s
 * `null`-is-unknown rule.
 *
 * @property sdkInt the API level the reads below were taken against; the caller
 *   uses it for the permission-model questions (`POST_NOTIFICATIONS` from 33,
 *   `BLUETOOTH_SCAN` from 31, `READ_MEDIA_IMAGES` from 33, background location
 *   from 29, `ACTIVITY_RECOGNITION` from 29).
 * @property declaredPermissions the runtime and normal permissions this app's
 *   merged manifest requests, exactly as `PackageManager` reports them.
 * @property grantedPermissions the subset of [declaredPermissions] the platform
 *   grants this app right now. Never includes an undeclared permission: asking
 *   about one would answer PERMISSION_DENIED for something that was never asked
 *   for, which is the permission-model equivalent of a fabricated version string.
 * @property policyDeniedPermissions the declared permissions an active device
 *   admin has set to `PERMISSION_GRANT_STATE_DENIED`.
 * @property notificationsEnabled `NotificationManager.areNotificationsEnabled()`:
 *   the app-op behind "may this app post notifications now".
 * @property notificationPolicyAccessGranted whether the app may read/change the
 *   system interruption filter (DND), the grant behind the 专注模式 row.
 * @property cameraPresent `FEATURE_CAMERA_ANY`.
 * @property microphonePresent `FEATURE_MICROPHONE`.
 * @property locationPresent `FEATURE_LOCATION`.
 * @property bluetoothPresent the Bluetooth feature plus a non-null adapter. A
 *   SecurityException on the adapter read (API 31+ without `BLUETOOTH_CONNECT`)
 *   falls back to the feature flag, because an unreadable adapter is not evidence
 *   of absence.
 * @property biometricHardwarePresent fingerprint, face or iris hardware.
 * @property deviceSecure `KeyguardManager.isDeviceSecure`; `null` when the service
 *   is missing. A biometric confirmation cannot run on a device without one.
 * @property stepCounterPresent a `TYPE_STEP_COUNTER`/`TYPE_STEP_DETECTOR` sensor.
 * @property speechRecognitionAvailable `SpeechRecognizer.isRecognitionAvailable`:
 *   whether a recognition service is installed at all.
 */
data class HostPermissionReadings(
    val sdkInt: Int,
    val declaredPermissions: Set<String>,
    val grantedPermissions: Set<String>,
    val policyDeniedPermissions: Set<String>,
    val notificationsEnabled: Boolean?,
    val notificationPolicyAccessGranted: Boolean,
    val cameraPresent: Boolean,
    val microphonePresent: Boolean,
    val locationPresent: Boolean,
    val bluetoothPresent: Boolean,
    val biometricHardwarePresent: Boolean,
    val deviceSecure: Boolean?,
    val stepCounterPresent: Boolean?,
    val speechRecognitionAvailable: Boolean?,
) {
    init {
        require(sdkInt > 0) { "sdkInt must be positive, was $sdkInt" }
        require(grantedPermissions.all(declaredPermissions::contains)) {
            "a granted permission must also be declared: " +
                (grantedPermissions - declaredPermissions)
        }
        require(policyDeniedPermissions.all(declaredPermissions::contains)) {
            "a policy-denied permission must also be declared: " +
                (policyDeniedPermissions - declaredPermissions)
        }
    }

    /** True when this app's merged manifest declares [permission]. */
    fun declares(permission: String): Boolean = permission in declaredPermissions

    /** True when [permission] is declared **and** currently granted. */
    fun granted(permission: String): Boolean = permission in grantedPermissions

    /** True when a device admin has explicitly denied [permission]. */
    fun policyDenied(permission: String): Boolean = permission in policyDeniedPermissions
}

/**
 * Reads [HostPermissionReadings] from the running device.
 *
 * @param context any context; only the application context is retained.
 * @param platform the measured platform half from [AndroidDeviceCapabilities].
 *   The API level the permission model is read against comes from there, so the two
 *   readers describe the same moment instead of racing two API-level reads. The
 *   `POST_NOTIFICATIONS` grant is read as part of this snapshot's manifest walk; the
 *   platform half reports the same permission as
 *   `ForegroundServiceFacts.notificationPermissionGranted`.
 */
class AndroidHostPermissions(
    context: Context,
    private val platform: AndroidPlatformFacts,
) {
    private val context: Context = context.applicationContext ?: context

    /** Takes one snapshot of every reading in [HostPermissionReadings]. */
    fun read(): HostPermissionReadings {
        val declared = declaredPermissions()
        return HostPermissionReadings(
            sdkInt = platform.sdkInt,
            declaredPermissions = declared,
            grantedPermissions = declared.filterTo(LinkedHashSet(), ::isGranted),
            policyDeniedPermissions = policyDenied(declared),
            notificationsEnabled = runCatching {
                notificationManager()?.areNotificationsEnabled()
            }.getOrNull(),
            notificationPolicyAccessGranted = runCatching {
                notificationManager()?.isNotificationPolicyAccessGranted == true
            }.getOrDefault(false),
            cameraPresent = hasFeature(PackageManager.FEATURE_CAMERA_ANY),
            microphonePresent = hasFeature(PackageManager.FEATURE_MICROPHONE),
            locationPresent = hasFeature(PackageManager.FEATURE_LOCATION),
            bluetoothPresent = bluetoothPresent(),
            biometricHardwarePresent = BIOMETRIC_FEATURES.any(::hasFeature),
            deviceSecure = runCatching {
                (context.getSystemService(Context.KEYGUARD_SERVICE) as? KeyguardManager)
                    ?.isDeviceSecure
            }.getOrNull(),
            stepCounterPresent = stepCounterPresent(),
            speechRecognitionAvailable = runCatching {
                SpeechRecognizer.isRecognitionAvailable(context)
            }.getOrNull(),
        )
    }

    @Suppress("DEPRECATION") // the flags-free overload predates API 33 and reads the same list
    private fun declaredPermissions(): Set<String> {
        val info = runCatching {
            context.packageManager.getPackageInfo(context.packageName, PackageManager.GET_PERMISSIONS)
        }.getOrNull() ?: return emptySet()
        return info.requestedPermissions?.toSet() ?: emptySet()
    }

    private fun isGranted(permission: String): Boolean =
        context.checkSelfPermission(permission) == PackageManager.PERMISSION_GRANTED

    /**
     * The declared permissions an active admin denies.
     *
     * `getActiveAdmins()` is the only call that lists device admins on every API
     * level this module supports; `getPermissionGrantState` then answers per
     * permission. No admin is no restriction, and an unreadable admin list is
     * reported as no restriction too — both are "nothing denies it", and inventing
     * `Restricted` from a failed read would be the exact over-claim this file
     * refuses.
     */
    @Suppress("DEPRECATION")
    private fun policyDenied(declared: Set<String>): Set<String> {
        if (declared.isEmpty()) return emptySet()
        val manager = context.getSystemService(Context.DEVICE_POLICY_SERVICE)
            as? DevicePolicyManager ?: return emptySet()
        val admins = runCatching { manager.activeAdmins }.getOrNull() ?: return emptySet()
        if (admins.isEmpty()) return emptySet()
        return declared.filterTo(LinkedHashSet()) { permission ->
            admins.any { admin ->
                runCatching {
                    manager.getPermissionGrantState(admin, context.packageName, permission)
                }.getOrNull() == DevicePolicyManager.PERMISSION_GRANT_STATE_DENIED
            }
        }
    }

    private fun notificationManager(): NotificationManager? =
        context.getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager

    private fun hasFeature(feature: String): Boolean = context.packageManager.hasSystemFeature(feature)

    private fun bluetoothPresent(): Boolean {
        if (!hasFeature(PackageManager.FEATURE_BLUETOOTH)) return false
        val adapterPresent = runCatching {
            (context.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager)?.adapter != null
        }.getOrNull()
        // An unreadable adapter (a 31+ SecurityException without BLUETOOTH_CONNECT)
        // keeps the feature flag's answer; only a readable `null` adapter is
        // evidence that the device has no Bluetooth radio.
        return adapterPresent != false
    }

    private fun stepCounterPresent(): Boolean? {
        val sensors = context.getSystemService(Context.SENSOR_SERVICE) as? SensorManager
            ?: return null
        return sensors.getDefaultSensor(Sensor.TYPE_STEP_COUNTER) != null ||
            sensors.getDefaultSensor(Sensor.TYPE_STEP_DETECTOR) != null
    }

    /** The permission strings this reader answers about; the host names none of them again. */
    companion object {
        /** Runtime permission behind 通讯录. */
        const val READ_CONTACTS: String = "android.permission.READ_CONTACTS"

        /** Runtime permission behind 日历. */
        const val READ_CALENDAR: String = "android.permission.READ_CALENDAR"

        /** The photo/video permission from API 33; below that, storage access. */
        const val READ_MEDIA_IMAGES: String = "android.permission.READ_MEDIA_IMAGES"

        /** The storage permission the photo row falls back to below API 33. */
        const val READ_EXTERNAL_STORAGE: String = "android.permission.READ_EXTERNAL_STORAGE"

        /** Permission behind 相机. */
        const val CAMERA: String = "android.permission.CAMERA"

        /** Permission behind 麦克风 and 语音识别. */
        const val RECORD_AUDIO: String = "android.permission.RECORD_AUDIO"

        /** Foreground location permission (either accuracy answers 定位). */
        const val ACCESS_FINE_LOCATION: String = "android.permission.ACCESS_FINE_LOCATION"

        /** Coarse location permission, the other half of 定位. */
        const val ACCESS_COARSE_LOCATION: String = "android.permission.ACCESS_COARSE_LOCATION"

        /** The permission behind 后台定位, from API 29. */
        const val ACCESS_BACKGROUND_LOCATION: String =
            "android.permission.ACCESS_BACKGROUND_LOCATION"

        /** The permission behind 运动与健身, from API 29. */
        const val ACTIVITY_RECOGNITION: String = "android.permission.ACTIVITY_RECOGNITION"

        /** The scan permission from API 31. */
        const val BLUETOOTH_SCAN: String = "android.permission.BLUETOOTH_SCAN"

        /** The pre-31 Bluetooth permission. */
        const val BLUETOOTH: String = "android.permission.BLUETOOTH"

        /** The notification permission from API 33. */
        const val POST_NOTIFICATIONS: String = "android.permission.POST_NOTIFICATIONS"

        /** The namespace Health Connect defines its per-data-type permissions in. */
        private const val HEALTH_PERMISSION_PREFIX: String = "android.permission.health."

        private val BIOMETRIC_FEATURES: List<String> = listOf(
            PackageManager.FEATURE_FINGERPRINT,
            PackageManager.FEATURE_FACE,
            PackageManager.FEATURE_IRIS,
        )
    }
}
