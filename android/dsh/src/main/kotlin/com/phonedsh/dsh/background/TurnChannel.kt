// phone-dsh — :dsh / com.phonedsh.dsh.background: which official channel is used.
// SPDX-License-Identifier: MIT
//
// Plan §7.2 selects the official channels once, by platform level:
//   - Android 14+ (API 34): UIDT is the primary channel — user-initiated, system
//     managed wakelock, no App Standby bucket quota.
//   - Android 8.0–13 (API 26–33): UIDT does not exist; dataSync FGS is the only
//     official channel. The fallback is not a degraded mode on those releases.
//   - Notifications not visible: neither channel can keep its progress-visible
//     contract, so the turn stays foreground-only (whitelist
//     `platform.post-notifications-degraded`).
//
// WorkManager is deliberately absent from this enum: it is a tombstone/reporting
// mechanism, never a turn channel (WorkManager is for <10 minute deferrable work;
// plan §7.2).

package com.phonedsh.dsh.background

import android.os.Build

/** The official background channel a turn would use on this device, right now. */
enum class TurnChannel {
    /** Android 14+ user-initiated job (UIDT). */
    USER_INITIATED_JOB,

    /** `dataSync` foreground service: the only channel below Android 14, and the fallback. */
    DATA_SYNC_FOREGROUND_SERVICE,

    /**
     * No background channel: the notification would not be visible, so the turn
     * must run only while the app is in the foreground and interruptions are
     * reported on the next open.
     */
    FOREGROUND_ONLY,
    ;

    companion object {
        /** `JobInfo.Builder.setUserInitiated` landed in Android 14 (API 34). */
        const val USER_INITIATED_JOB_MIN_SDK: Int = Build.VERSION_CODES.UPSIDE_DOWN_CAKE

        /**
         * Pure decision function; [sdkInt] is a parameter so it can be exercised on
         * the JVM and on any emulator image without pretending to be another SDK.
         */
        fun select(sdkInt: Int, capability: NotificationCapability): TurnChannel = when {
            !capability.progressVisible -> FOREGROUND_ONLY
            sdkInt >= USER_INITIATED_JOB_MIN_SDK -> USER_INITIATED_JOB
            else -> DATA_SYNC_FOREGROUND_SERVICE
        }

        fun current(capability: NotificationCapability): TurnChannel =
            select(Build.VERSION.SDK_INT, capability)
    }
}
