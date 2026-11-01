// What one successful connection produced: the endpoint and its decoded manifest.
// SPDX-License-Identifier: MIT
//
// The manifest member is a [DeviceManifest], never the raw JSON a device sent.
// That is the point of this type: decoding happens once, at the connection edge,
// so every consumer above it (a UI, a grant check, the event router) reads typed
// capabilities and none of them owns a second parser with its own tolerance
// rules. A peer's broken document fails the connection instead of travelling
// further and failing somewhere that cannot report why.
//
// The device id is not duplicated here. It is [DeviceManifest.deviceId], the one
// identity the wire contract fixes (≤128 printable ASCII, stable across
// reconnects and restarts), so a pairing record and a manifest cannot disagree
// about which device is connected.

package com.phonedsh.domain.connector

import com.phonedsh.domain.device.DeviceManifest

/**
 * A live connection and everything the host learned from it.
 *
 * @property endpoint the address that answered.
 * @property manifest the decoded `pdsh-device-caps/1` document. An undeclared
 *   capability is unavailable by definition, so this member is the whole
 *   capability answer — there is no "supported but undeclared" case.
 */
data class ConnectedDevice(
    val endpoint: Endpoint,
    val manifest: DeviceManifest,
) {
    /** The stable device identity, taken from [manifest]. */
    val deviceId: String
        get() = manifest.deviceId
}
