// phone-dsh — :dsh unit test: channel selection is a pure function of SDK + capability.
// SPDX-License-Identifier: MIT
//
// The Android 14 boundary is the one thing an API 35 emulator cannot exercise at
// runtime, so the selection is written as a pure function and pinned here: below
// 34 the dataSync foreground service is the only channel, from 34 UIDT is primary,
// and an invisible notification link forces foreground-only everywhere.

package com.phonedsh.dsh.background

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class TurnChannelTest {
    private fun capability(
        permission: NotificationCapability.RuntimePermission =
            NotificationCapability.RuntimePermission.GRANTED,
        notificationsEnabled: Boolean = true,
        channelBlocked: Boolean = false,
    ) = NotificationCapability(
        runtimePermission = permission,
        notificationsEnabled = notificationsEnabled,
        progressChannelBlocked = channelBlocked,
    )

    @Test
    fun uidtIsPrimaryFromApi34AndDataSyncFgsIsTheOnlyChannelBelowIt() {
        assertEquals(
            TurnChannel.DATA_SYNC_FOREGROUND_SERVICE,
            TurnChannel.select(sdkInt = 26, capability = capability()),
        )
        assertEquals(
            TurnChannel.DATA_SYNC_FOREGROUND_SERVICE,
            TurnChannel.select(sdkInt = 33, capability = capability()),
        )
        assertEquals(
            TurnChannel.USER_INITIATED_JOB,
            TurnChannel.select(sdkInt = 34, capability = capability()),
        )
        assertEquals(
            TurnChannel.USER_INITIATED_JOB,
            TurnChannel.select(sdkInt = 35, capability = capability()),
        )
    }

    @Test
    fun deniedRuntimePermissionForcesForegroundOnlyOnEveryApi() {
        val denied = capability(permission = NotificationCapability.RuntimePermission.DENIED)
        for (sdk in 26..35) {
            assertEquals(
                "sdk $sdk must not open either background channel",
                TurnChannel.FOREGROUND_ONLY,
                TurnChannel.select(sdkInt = sdk, capability = denied),
            )
        }
    }

    @Test
    fun appLevelOrChannelLevelSwitchAlsoForcesForegroundOnly() {
        val appOff = capability(notificationsEnabled = false)
        assertEquals(TurnChannel.FOREGROUND_ONLY, TurnChannel.select(35, appOff))
        assertEquals(
            NotificationCapability.DegradedReason.NOTIFICATIONS_DISABLED,
            appOff.degradedReason,
        )

        val channelOff = capability(channelBlocked = true)
        assertEquals(TurnChannel.FOREGROUND_ONLY, TurnChannel.select(35, channelOff))
        assertEquals(
            NotificationCapability.DegradedReason.CHANNEL_BLOCKED,
            channelOff.degradedReason,
        )
    }

    @Test
    fun belowAndroid13NotificationsNeedNoRuntimePermission() {
        val preTiramisu = capability(
            permission = NotificationCapability.RuntimePermission.NOT_REQUIRED,
        )
        assertEquals(TurnChannel.DATA_SYNC_FOREGROUND_SERVICE, TurnChannel.select(30, preTiramisu))
        assertNull(preTiramisu.degradedReason)
    }
}
