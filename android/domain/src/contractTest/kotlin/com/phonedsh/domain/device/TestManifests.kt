// Fixtures shared by the schema test and the instrumented device test.
// SPDX-License-Identifier: MIT
//
// `everyCapability` is intentionally built from the schema's `required`
// members for every vocabulary entry, provisional ones included: it is the input
// that lets `DeviceCapabilitiesSchemaTest` prove the Kotlin names and the schema
// names are the same words, not merely similar ones.

package com.phonedsh.domain.device

/** Test manifests for the device-capability contract. */
object TestManifests {
    /** A manifest that declares every capability of the schema vocabulary once. */
    fun everyCapability(): DeviceManifest = DeviceManifest(
        deviceId = "test-device-1",
        protocol = DeviceProtocol("testws", "1.0"),
        capabilities = linkedMapOf(
            "audio.tts" to CapabilityValue.of("codec" to "opus", "rate" to 24_000),
            "audio.asr" to CapabilityValue.of("rate" to 48_000),
            "audio.mic.stream" to CapabilityValue.of(
                "codec" to "opus",
                "rate" to 16_000,
                "frame_ms" to 20,
                "max_minutes" to 120,
            ),
            "display.text" to CapabilityValue.of("max_chars" to 512),
            "light.effect" to CapabilityValue.of("effects" to listOf("breathe", "doa")),
            "speaker.volume" to CapabilityValue.of("range" to listOf(0, 100)),
            "control.gpio" to CapabilityValue.of("pins" to listOf(4, 5)),
            "call.ble" to CapabilityValue.of("uplink" to "call_up", "codec" to "opus"),
            "call.hfp" to CapabilityValue.of("profile" to "HF", "codec" to "msbc"),
            "call.uac" to CapabilityValue.of("telephony" to "hid", "codec" to "usb"),
            "render.light" to CapabilityValue.of("effects" to listOf("breathe")),
            "render.pixel" to CapabilityValue.of(
                "w" to 64,
                "h" to 64,
                "format" to "rgb565",
                "fps" to 20,
            ),
            "render.epaper" to CapabilityValue.of(
                "w" to 250,
                "h" to 122,
                "format" to "mono1",
                "refresh" to "partial",
            ),
            "render.screen" to CapabilityValue.of(
                "w" to 1280,
                "h" to 720,
                "formats" to listOf("png", "html"),
            ),
            "vehicle.*" to CapabilityValue.of("granted_by" to "oem"),
        ),
        limits = DeviceLimits(maxFrameBytes = 65_536, textBytes = 2_048, audioKbps = 32),
        auth = DeviceAuth(DeviceAuth.Pairing.BLE_PASSKEY),
    )

    /** A plausible manifest for the local Android host (declared, not measured). */
    fun localAndroid(): DeviceManifest = DeviceManifest(
        deviceId = "android-local-1",
        protocol = DeviceProtocol("local-host", "1.0"),
        capabilities = linkedMapOf(
            "display.text" to CapabilityValue.of("max_chars" to 512),
            "render.screen" to CapabilityValue.of(
                "w" to 1080,
                "h" to 2400,
                "formats" to listOf("argb8888"),
            ),
        ),
        limits = DeviceLimits(maxFrameBytes = 65_536),
        auth = DeviceAuth(DeviceAuth.Pairing.CODE),
    )
}
