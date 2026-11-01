// The local host as a discovered device: measured facts to manifest and back.
// SPDX-License-Identifier: MIT
//
// This suite answers one question the capability SPI could not: given what the
// runtime measured about *this* phone, what `pdsh-device-caps/1` document does the
// host publish about itself, and does its own decoder accept it?
//
// The measured facts below are a captured Pixel-class reading rather than a
// convenience literal: SDK 34, three ABIs in the order the platform reports them,
// a 1080x2400 panel at 420 dpi, the Play-Store WebView provider, and the
// foreground-service permission set of an app that declared media playback and
// connected-device but not data sync. They are the same values the instrumented
// suite reads from the running device, which is what makes this a round trip over a
// realistic manifest and not over a fixture that no device would produce.
//
// One case deliberately asserts a refusal owned by another type: the plain
// DeviceManifest constructor accepts a capability value missing a schema-required
// member, and only the decoder object to it. That gap is why LocalDeviceManifest
// validates; whether the constructor should close it is reported as an open
// question, not decided here.

package com.phonedsh.domain.connector

import com.phonedsh.domain.device.AndroidPlatformFacts
import com.phonedsh.domain.device.CapabilityValue
import com.phonedsh.domain.device.DeviceAuth
import com.phonedsh.domain.device.DeviceLimits
import com.phonedsh.domain.device.DeviceManifest
import com.phonedsh.domain.device.DeviceManifestException
import com.phonedsh.domain.device.DeviceManifestFailure
import com.phonedsh.domain.device.DeviceProtocol
import com.phonedsh.domain.device.DisplayFacts
import com.phonedsh.domain.device.ForegroundServiceFacts
import com.phonedsh.domain.device.LocalDeviceIdentity
import com.phonedsh.domain.device.LocalDeviceManifest
import com.phonedsh.domain.device.WebViewFacts
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class LocalDeviceManifestTest {
    /** A captured reading of a Pixel-class device at the moment the manifest was built. */
    private val measured: AndroidPlatformFacts = AndroidPlatformFacts(
        sdkInt = 34,
        supportedAbis = listOf("arm64-v8a", "armeabi-v7a", "armeabi"),
        display = DisplayFacts(
            widthPx = 1_080,
            heightPx = 2_400,
            densityDpi = 420,
            density = 2.625f,
        ),
        webView = WebViewFacts("com.google.android.webview", "131.0.6778.135"),
        foregroundService = ForegroundServiceFacts(
            basePermissionGranted = true,
            notificationPermissionGranted = true,
            microphoneTypeGranted = true,
            connectedDeviceTypeGranted = true,
            dataSyncTypeGranted = false,
            mediaPlaybackTypeGranted = true,
        ),
        totalMemoryBytes = 7_984_627_712L,
    )

    private val identity: LocalDeviceIdentity = LocalDeviceIdentity(
        deviceId = "android-local-1",
        protocol = DeviceProtocol("local-host", "1.0"),
        limits = DeviceLimits(maxFrameBytes = 65_536, textBytes = 2_048, audioKbps = 32),
        pairing = DeviceAuth.Pairing.CODE,
    )

    /** What the composition root declares this host can do. */
    private fun declared(): Map<String, CapabilityValue> = linkedMapOf(
        "display.text" to CapabilityValue.of("max_chars" to 512),
        "render.screen" to CapabilityValue.of("formats" to listOf("argb8888")),
        "audio.tts" to CapabilityValue.of("codec" to "opus", "rate" to 24_000),
    )

    @Test
    fun aMeasuredLocalManifestSurvivesItsOwnDecoderRoundTrip() {
        val manifest = LocalDeviceManifest.of(identity, declared(), measured)

        val reparsed = DeviceManifest.parse(manifest.toJson())

        assertEquals("android-local-1", reparsed.deviceId)
        assertEquals(identity.protocol, reparsed.protocol)
        assertEquals(identity.limits, reparsed.limits)
        assertEquals(DeviceAuth.Pairing.CODE, reparsed.auth.pairing)
        assertEquals(DeviceAuth.REPLAY_COUNTER_TTL, reparsed.auth.replay)
        assertEquals(declared().keys, reparsed.capabilities.keys)

        assertEquals(512, reparsed.capabilities.getValue("display.text").int("max_chars"))
        assertEquals("opus", reparsed.capabilities.getValue("audio.tts").string("codec"))
        assertEquals(24_000, reparsed.capabilities.getValue("audio.tts").int("rate"))

        // The screen target's pixel size is the measurement, and it survives the
        // round trip as the same number the platform reported.
        val screen = reparsed.capabilities.getValue("render.screen")
        assertEquals(measured.display.widthPx, screen.int("w"))
        assertEquals(measured.display.heightPx, screen.int("h"))
        assertEquals(listOf("argb8888"), screen.stringList("formats"))

        // Encode -> decode -> encode is stable, which is what makes the published
        // document a closed, deterministic target rather than "whatever came back".
        assertEquals(manifest.toJson(), reparsed.toJson())
    }

    @Test
    fun aDeclaredScreenSizeWinsOverTheMeasurement() {
        val manifest = LocalDeviceManifest.of(
            identity,
            linkedMapOf(
                "render.screen" to CapabilityValue.of(
                    "w" to 720,
                    "h" to 1_280,
                    "formats" to listOf("argb8888"),
                ),
            ),
            measured,
        )

        val screen = manifest.capabilities.getValue("render.screen")
        assertEquals(720, screen.int("w"))
        assertEquals(1_280, screen.int("h"))
    }

    @Test
    fun onlyTheScreenTargetTakesItsSizeFromTheMeasurement() {
        val manifest = LocalDeviceManifest.of(
            identity,
            linkedMapOf(
                "render.pixel" to CapabilityValue.of(
                    "w" to 64,
                    "h" to 64,
                    "format" to "rgb565",
                ),
                "render.screen" to CapabilityValue.of("formats" to listOf("argb8888")),
            ),
            measured,
        )

        // A display measurement says nothing about a pixel matrix, so the declared
        // 64x64 stays 64x64 even though the panel is 1080x2400.
        val pixel = manifest.capabilities.getValue("render.pixel")
        assertEquals(64, pixel.int("w"))
        assertEquals(64, pixel.int("h"))
        assertEquals("rgb565", pixel.string("format"))
        assertEquals(1_080, manifest.capabilities.getValue("render.screen").int("w"))
    }

    @Test
    fun aScreenTargetWithoutAMeasuredDisplayIsRefused() {
        val unmeasured = measured.copy(display = DisplayFacts(0, 0, 420, 2.625f))

        val thrown = assertThrows(IllegalArgumentException::class.java) {
            LocalDeviceManifest.of(identity, declared(), unmeasured)
        }
        assertTrue(thrown.message!!.contains("needs a measured display"))

        // The refusal is scoped to the screen target: a host that measured no
        // display may still publish the capabilities that no display backs.
        val textOnly = LocalDeviceManifest.of(
            identity,
            linkedMapOf("display.text" to CapabilityValue.of("max_chars" to 512)),
            unmeasured,
        )
        assertEquals(setOf("display.text"), textOnly.capabilities.keys)
    }

    @Test
    fun anIncompleteStandardCapabilityIsRefusedBeforeItIsEncoded() {
        val incomplete = linkedMapOf(
            "audio.tts" to CapabilityValue.of("codec" to "opus"),
        )

        val thrown = assertThrows(IllegalArgumentException::class.java) {
            LocalDeviceManifest.of(identity, incomplete, measured)
        }

        assertTrue(thrown.message!!.contains("\"audio.tts\""))
        assertTrue(thrown.message!!.contains("rate"))
    }

    @Test
    fun vendorAndVehicleCapabilitiesPassThroughUnchecked() {
        val manifest = LocalDeviceManifest.of(
            identity,
            linkedMapOf(
                "vendor.acme.mode" to CapabilityValue.of("mode" to "on"),
                "vehicle.speed" to CapabilityValue.of("granted_by" to "oem"),
            ),
            measured,
        )

        assertEquals(setOf("vendor.acme.mode", "vehicle.speed"), manifest.capabilities.keys)
        assertEquals(
            "oem",
            manifest.capabilities.getValue("vehicle.speed").string("granted_by"),
        )
        assertEquals(
            setOf("vendor.acme.mode", "vehicle.speed"),
            DeviceManifest.parse(manifest.toJson()).capabilities.keys,
        )
    }

    @Test
    fun thePlainConstructorAcceptsWhatTheDecoderWouldRefuse() {
        // The reason LocalDeviceManifest validates at all: the manifest value checks
        // names, ranges and the vehicle rule, but not a vocabulary entry's required
        // members, so this document is constructible and unreadable.
        val incomplete = DeviceManifest(
            deviceId = "android-local-1",
            protocol = DeviceProtocol("local-host", "1.0"),
            capabilities = linkedMapOf("audio.tts" to CapabilityValue.of("codec" to "opus")),
            limits = DeviceLimits(maxFrameBytes = 65_536),
            auth = DeviceAuth(DeviceAuth.Pairing.CODE),
        )

        val thrown = assertThrows(DeviceManifestException::class.java) {
            DeviceManifest.parse(incomplete.toJson())
        }

        assertEquals(DeviceManifestFailure.MISSING_MEMBER, thrown.failure)
        assertTrue(thrown.message!!.contains("capabilities.audio.tts.rate"))
    }
}
