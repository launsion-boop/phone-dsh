// Fixtures for the connector seam tests, and only for them.
// SPDX-License-Identifier: MIT
//
// The fixtures are deliberately boring values: a plausible ESP32 that speaks a
// `devicews` protocol and a manifest that declares two capabilities. Nothing here
// is measured — the measured-facts fixture lives in LocalDeviceManifestTest, where
// it is the subject rather than the background.

package com.phonedsh.domain.connector

import com.phonedsh.domain.device.CapabilityValue
import com.phonedsh.domain.device.DeviceAuth
import com.phonedsh.domain.device.DeviceLimits
import com.phonedsh.domain.device.DeviceManifest
import com.phonedsh.domain.device.DeviceProtocol

/** Fixed endpoints and manifests for the connector suites. */
internal object ConnectorFixtures {
    /** A device that answers. The address syntax belongs to the `devicews` protocol. */
    val ENDPOINT: Endpoint = Endpoint("devicews", "wss://device.invalid:443/channel")

    /** A second device, on a protocol whose address is not URL-shaped. */
    val SECOND_ENDPOINT: Endpoint = Endpoint("open-adapter", "ble:A4:C1:38:00:00:01")

    /** An endpoint no fixture registers. */
    val UNKNOWN_ENDPOINT: Endpoint = Endpoint("devicews", "wss://nowhere.invalid:443/channel")

    /** A manifest declaring two capabilities. */
    fun manifest(deviceId: String = "esp32-8c4f01"): DeviceManifest = DeviceManifest(
        deviceId = deviceId,
        protocol = DeviceProtocol("devicews", "1.0"),
        capabilities = linkedMapOf(
            "audio.tts" to CapabilityValue.of("codec" to "opus", "rate" to 24_000),
            "render.pixel" to CapabilityValue.of("w" to 64, "h" to 64, "format" to "rgb565"),
        ),
        limits = DeviceLimits(maxFrameBytes = 65_536, audioKbps = 32),
        auth = DeviceAuth(DeviceAuth.Pairing.BLE_PASSKEY),
    )

    /** A manifest declaring nothing: the `empty` projection case. */
    fun silentManifest(deviceId: String = "esp32-quiet"): DeviceManifest = DeviceManifest(
        deviceId = deviceId,
        protocol = DeviceProtocol("devicews", "1.0"),
        capabilities = emptyMap(),
        limits = DeviceLimits(maxFrameBytes = 1_024),
        auth = DeviceAuth(DeviceAuth.Pairing.CODE),
    )

    /** The device a successful connect reports. */
    fun device(
        endpoint: Endpoint = ENDPOINT,
        manifest: DeviceManifest = manifest(),
    ): ConnectedDevice = ConnectedDevice(endpoint, manifest)

    /** A failure that a live link produces when it dies. */
    fun lost(): ConnectorFailure = ConnectorFailure.TransportLost("socket closed")
}
