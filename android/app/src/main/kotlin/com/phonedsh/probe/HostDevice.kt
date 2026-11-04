// SPDX-License-Identifier: MIT
package com.phonedsh.probe

import com.phonedsh.ui.nav.PdshActionAvailabilities
import com.phonedsh.ui.nav.PdshActionAvailability
import com.phonedsh.ui.nav.PdshActionKey
import com.phonedsh.ui.nav.PdshUnavailableReason
import com.phonedsh.ui.nav.PdshDeviceFacts

/**
 * Device connector facts for this Android host. The app can measure its own
 * Android platform and permissions, but it does not install a production remote
 * DeviceConnector: the only connector implementation in this candidate is the
 * in-memory test double. Keep the device catalog unread and report connection
 * actions unavailable until a real connector is installed.
 */
internal fun hostDeviceFacts(): PdshDeviceFacts = PdshDeviceFacts(
    devices = null,
    canConnect = false,
)

internal fun hostDeviceActionAvailability(): PdshActionAvailabilities = PdshActionAvailabilities(
    byAction = mapOf(
        PdshActionKey.DEVICE_CONNECT to PdshActionAvailability.Unavailable(PdshUnavailableReason.NOT_IMPLEMENTED),
        PdshActionKey.DEVICE_SESSION to PdshActionAvailability.Unavailable(PdshUnavailableReason.NOT_IMPLEMENTED),
    ),
)
