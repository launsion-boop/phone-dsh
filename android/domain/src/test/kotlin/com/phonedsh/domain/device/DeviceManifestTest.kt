// The manifest value and its wire encoder.
// SPDX-License-Identifier: MIT

package com.phonedsh.domain.device

import com.phonedsh.domain.testing.MiniJson
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class DeviceManifestTest {
    @Test
    fun theEncodedRootUsesTheSchemaMemberNames() {
        val document = MiniJson.parseObject(TestManifests.everyCapability().toJson())

        assertEquals(
            setOf("schema", "device_id", "protocol", "capabilities", "limits", "auth"),
            document.keys,
        )
        assertEquals("pdsh-device-caps/1", document["schema"])
        assertEquals("test-device-1", document["device_id"])

        val protocol = document["protocol"] as Map<*, *>
        assertEquals(setOf("id", "version"), protocol.keys)
        assertEquals("testws", protocol["id"])
        assertEquals("1.0", protocol["version"])

        val limits = document["limits"] as Map<*, *>
        assertEquals(setOf("max_frame_bytes", "text_bytes", "audio_kbps"), limits.keys)
        assertEquals(65_536L, limits["max_frame_bytes"])
        assertEquals(2_048L, limits["text_bytes"])
        assertEquals(32L, limits["audio_kbps"])

        val auth = document["auth"] as Map<*, *>
        assertEquals(setOf("pairing", "replay"), auth.keys)
        assertEquals("ble-passkey", auth["pairing"])
        assertEquals("counter+ttl", auth["replay"])
    }

    @Test
    fun optionalLimitMembersAreOmittedWhenAbsent() {
        val manifest = DeviceManifest(
            deviceId = "d-1",
            protocol = DeviceProtocol("p", "1.0"),
            capabilities = emptyMap(),
            limits = DeviceLimits(maxFrameBytes = 1_024),
            auth = DeviceAuth(DeviceAuth.Pairing.CODE),
        )

        val limits = MiniJson.parseObject(manifest.toJson())["limits"] as Map<*, *>
        assertEquals(setOf("max_frame_bytes"), limits.keys)
    }

    @Test
    fun stringsAreEscapedAndSurviveARoundTrip() {
        val label = "a\"b\\c\n\t🙂"
        val manifest = DeviceManifest(
            deviceId = "d-1",
            protocol = DeviceProtocol("p", "1.0"),
            capabilities = mapOf(
                "vendor.acme.led" to CapabilityValue.of("label" to label, "count" to 3),
            ),
            limits = DeviceLimits(maxFrameBytes = 1_024),
            auth = DeviceAuth(DeviceAuth.Pairing.CODE),
        )

        val document = MiniJson.parseObject(manifest.toJson())
        val vendor = (document["capabilities"] as Map<*, *>)["vendor.acme.led"] as Map<*, *>
        assertEquals(label, vendor["label"])
        assertEquals(3L, vendor["count"])
    }

    @Test
    fun capabilityValueAccessorsKeepTheirTypes() {
        val value = CapabilityValue.of(
            "codec" to "opus",
            "rate" to 16_000,
            "effects" to listOf("breathe", "doa"),
            "range" to listOf(0, 100),
            "mono" to true,
        )

        assertEquals("opus", value.string("codec"))
        assertEquals(16_000, value.int("rate"))
        assertEquals(listOf("breathe", "doa"), value.stringList("effects"))
        assertEquals(listOf(0, 100), value.intList("range"))
        assertTrue(value.members.containsKey("mono"))
        assertEquals(null, value.string("rate"))
    }

    @Test
    fun unknownCapabilityNamesAreRejected() {
        assertThrows(IllegalArgumentException::class.java) {
            manifestWith(capabilities = mapOf("memory.read" to CapabilityValue.of("x" to 1)))
        }
        assertThrows(IllegalArgumentException::class.java) {
            manifestWith(capabilities = mapOf("Audio.TTS" to CapabilityValue.of("x" to 1)))
        }
    }

    @Test
    fun vendorAndVehicleCapabilitiesAreAccepted() {
        val manifest = manifestWith(
            capabilities = mapOf(
                "vendor.acme.led" to CapabilityValue.of("effects" to listOf("solid")),
                "vehicle.speed" to CapabilityValue.of("granted_by" to "oem"),
            ),
        )

        val capabilities = MiniJson.parseObject(manifest.toJson())["capabilities"] as Map<*, *>
        assertEquals(setOf("vendor.acme.led", "vehicle.speed"), capabilities.keys)
        assertTrue(manifest.isProvisional("vehicle.speed"))
        assertTrue(!manifest.isProvisional("vendor.acme.led"))
    }

    @Test
    fun vehicleCapabilitiesRequireTheVendorGrant() {
        assertThrows(IllegalArgumentException::class.java) {
            manifestWith(capabilities = mapOf("vehicle.speed" to CapabilityValue.of("kmh" to 60)))
        }
        assertThrows(IllegalArgumentException::class.java) {
            manifestWith(capabilities = mapOf("vehicle.speed" to CapabilityValue.of("granted_by" to 7)))
        }
        assertThrows(IllegalArgumentException::class.java) {
            manifestWith(capabilities = mapOf("vehicle.speed" to CapabilityValue.of("granted_by" to "")))
        }
        manifestWith(capabilities = mapOf("vehicle.speed" to CapabilityValue.of("granted_by" to "oem")))
    }

    @Test
    fun theDeviceIdPatternIsValidated() {
        assertThrows(IllegalArgumentException::class.java) { manifestWith(deviceId = "") }
        assertThrows(IllegalArgumentException::class.java) { manifestWith(deviceId = "bad id") }
        assertThrows(IllegalArgumentException::class.java) { manifestWith(deviceId = "-leading") }
        assertThrows(IllegalArgumentException::class.java) { manifestWith(deviceId = "a".repeat(129)) }

        // The schema's own examples and the allowed punctuation must pass.
        manifestWith(deviceId = "esp32-8c4f1a")
        manifestWith(deviceId = "a:b.c_d-e")
        manifestWith(deviceId = "a".repeat(128))
    }

    @Test
    fun theProtocolVersionIsMajorDotMinor() {
        assertThrows(IllegalArgumentException::class.java) {
            manifestWith(protocol = DeviceProtocol("p", "1"))
        }
        assertThrows(IllegalArgumentException::class.java) {
            manifestWith(protocol = DeviceProtocol("p", "1.0.0"))
        }
        assertThrows(IllegalArgumentException::class.java) {
            manifestWith(protocol = DeviceProtocol("p", "v1.0"))
        }
        assertThrows(IllegalArgumentException::class.java) {
            manifestWith(protocol = DeviceProtocol("", "1.0"))
        }
        manifestWith(protocol = DeviceProtocol("devicews", "2.1"))
    }

    @Test
    fun limitsAreBoundedLikeTheSchema() {
        assertThrows(IllegalArgumentException::class.java) { DeviceLimits(maxFrameBytes = 0) }
        assertThrows(IllegalArgumentException::class.java) { DeviceLimits(maxFrameBytes = 65_537) }
        assertThrows(IllegalArgumentException::class.java) {
            DeviceLimits(maxFrameBytes = 1, textBytes = 0)
        }
        assertThrows(IllegalArgumentException::class.java) {
            DeviceLimits(maxFrameBytes = 1, audioKbps = -1)
        }
        DeviceLimits(maxFrameBytes = 65_536)
    }

    @Test
    fun replayProtectionIsTheSchemaConst() {
        assertThrows(IllegalArgumentException::class.java) {
            DeviceAuth(DeviceAuth.Pairing.CODE, replay = "timestamp")
        }
    }

    @Test
    fun capabilityValuesRejectNestedAndUnsupportedTypes() {
        assertThrows(IllegalArgumentException::class.java) {
            CapabilityValue.of("nested" to mapOf("a" to 1))
        }
        assertThrows(IllegalArgumentException::class.java) {
            CapabilityValue.of("nested" to listOf(mapOf("a" to 1)))
        }
        assertThrows(IllegalArgumentException::class.java) {
            CapabilityValue.of("float" to 1.5f)
        }
        assertThrows(IllegalArgumentException::class.java) {
            CapabilityValue.of("duplicate" to 1, "duplicate" to 2)
        }
    }

    private fun manifestWith(
        deviceId: String = "d-1",
        protocol: DeviceProtocol = DeviceProtocol("p", "1.0"),
        capabilities: Map<String, CapabilityValue> = emptyMap(),
    ): DeviceManifest = DeviceManifest(
        deviceId = deviceId,
        protocol = protocol,
        capabilities = capabilities,
        limits = DeviceLimits(maxFrameBytes = 1_024),
        auth = DeviceAuth(DeviceAuth.Pairing.CODE),
    )
}
