// phone-dsh — :dsh / com.phonedsh.dsh.background: what the notification link can do.
// SPDX-License-Identifier: MIT
//
// Whitelist `platform.post-notifications-degraded` (emulator-probe):
// POST_NOTIFICATIONS is a runtime permission from Android 13. If it is denied,
// the foreground-service notification is invisible and UIDT's "progress visible"
// premise does not hold, so UIDT must not be used; the conversation downgrades to
// a foreground-only turn and the interruption is reported on the next app open.
// The degradation has to be visible in the API, never silent.
// Mechanism named by the whitelist: NotificationManagerCompat.areNotificationsEnabled.

package com.phonedsh.dsh.background

import android.app.NotificationManager
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import androidx.core.app.NotificationManagerCompat

/**
 * The notification link's current capacity, probed from the platform.
 *
 * This is the API surface the UI must read before promising background
 * execution: [progressVisible] is the single predicate that decides whether a
 * background channel may be opened at all ([TurnChannel.select]).
 */
data class NotificationCapability(
    val runtimePermission: RuntimePermission,
    val notificationsEnabled: Boolean,
    val progressChannelBlocked: Boolean,
) {
    /**
     * [DENIED] also covers "not asked yet": both mean "the notification would not
     * be visible now", which is the only question the background layer asks. The
     * UI is the place that distinguishes "ask the user" from "the user said no".
     */
    enum class RuntimePermission { NOT_REQUIRED, GRANTED, DENIED }

    enum class DegradedReason {
        /** Android 13+ runtime permission is not granted. */
        RUNTIME_PERMISSION_DENIED,

        /** App-level notifications are switched off (system settings or policy). */
        NOTIFICATIONS_DISABLED,

        /** The progress channel itself is set to "off" by the user. */
        CHANNEL_BLOCKED,
    }

    /** True only when a running-turn notification would actually be shown. */
    val progressVisible: Boolean
        get() = runtimePermission != RuntimePermission.DENIED &&
            notificationsEnabled &&
            !progressChannelBlocked

    val degradedReason: DegradedReason?
        get() = when {
            runtimePermission == RuntimePermission.DENIED -> DegradedReason.RUNTIME_PERMISSION_DENIED
            !notificationsEnabled -> DegradedReason.NOTIFICATIONS_DISABLED
            progressChannelBlocked -> DegradedReason.CHANNEL_BLOCKED
            else -> null
        }

    companion object {
        const val POST_NOTIFICATIONS: String = "android.permission.POST_NOTIFICATIONS"

        /**
         * Probes the real system state. Does not create the channel: a missing
         * channel is "not blocked", and [TurnNotifications.ensureChannels] creates
         * it when a channel is actually opened.
         */
        fun probe(
            context: Context,
            progressChannelId: String = TurnNotifications.PROGRESS_CHANNEL_ID,
        ): NotificationCapability {
            val runtime = if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) {
                RuntimePermission.NOT_REQUIRED
            } else if (context.checkSelfPermission(POST_NOTIFICATIONS) ==
                PackageManager.PERMISSION_GRANTED
            ) {
                RuntimePermission.GRANTED
            } else {
                RuntimePermission.DENIED
            }
            val channelBlocked = context.getSystemService(NotificationManager::class.java)
                ?.getNotificationChannel(progressChannelId)
                ?.importance == NotificationManager.IMPORTANCE_NONE
            return NotificationCapability(
                runtimePermission = runtime,
                notificationsEnabled = NotificationManagerCompat.from(context).areNotificationsEnabled(),
                progressChannelBlocked = channelBlocked,
            )
        }
    }
}
