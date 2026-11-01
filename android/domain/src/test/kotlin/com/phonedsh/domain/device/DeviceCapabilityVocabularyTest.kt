// The vocabulary mirror of device-capabilities.schema.json.
// SPDX-License-Identifier: MIT

package com.phonedsh.domain.device

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class DeviceCapabilityVocabularyTest {
    @Test
    fun theVocabularyHasTheFifteenSchemaNames() {
        assertEquals(
            listOf(
                "audio.tts",
                "audio.asr",
                "audio.mic.stream",
                "display.text",
                "light.effect",
                "speaker.volume",
                "control.gpio",
                "call.ble",
                "call.hfp",
                "call.uac",
                "render.light",
                "render.pixel",
                "render.epaper",
                "render.screen",
                "vehicle.*",
            ),
            DeviceCapability.entries.map { it.wireName },
        )
    }

    @Test
    fun theSixProvisionalWordsAreMarked() {
        assertEquals(
            setOf("call.hfp", "call.uac", "render.light", "render.epaper", "render.screen", "vehicle.*"),
            DeviceCapability.provisional.map { it.wireName }.toSet(),
        )
        assertEquals(6, DeviceCapability.provisional.size)
        assertTrue(DeviceCapability.CALL_HFP.provisional)
        assertFalse(DeviceCapability.CALL_BLE.provisional)
    }

    @Test
    fun onlyTheVehicleEntryIsAPrefix() {
        assertTrue(DeviceCapability.VEHICLE.isPrefix)
        assertFalse(DeviceCapability.RENDER_SCREEN.isPrefix)
    }

    @Test
    fun declaredNamesAcceptVocabularyPrefixesAndVendorExtensions() {
        DeviceCapability.entries.forEach { capability ->
            assertTrue(capability.wireName, DeviceCapability.isDeclaredName(capability.wireName))
        }
        assertTrue(DeviceCapability.isDeclaredName("vehicle.speed"))
        assertTrue(DeviceCapability.isDeclaredName("vendor.acme.led"))
        assertTrue(DeviceCapability.isDeclaredName("vendor.acme-v1.led_ring"))

        assertFalse(DeviceCapability.isDeclaredName("memory.read"))
        assertFalse(DeviceCapability.isDeclaredName("audio"))
        assertFalse(DeviceCapability.isDeclaredName("vehicle"))
        assertFalse(DeviceCapability.isDeclaredName("vendor.acme"))
        assertFalse(DeviceCapability.isDeclaredName("Vendor.acme.led"))
        assertFalse(DeviceCapability.isDeclaredName(""))
    }

    @Test
    fun provisionalIsInheritedByConcreteVehicleNamesButNotByVendorNames() {
        assertTrue(DeviceCapability.isProvisional("render.screen"))
        assertTrue(DeviceCapability.isProvisional("vehicle.speed"))
        assertFalse(DeviceCapability.isProvisional("audio.tts"))
        assertFalse(DeviceCapability.isProvisional("vendor.acme.led"))
    }

    @Test
    fun theVehiclePrefixIsRecognised() {
        assertTrue(DeviceCapability.isVehicle("vehicle.speed"))
        assertTrue(DeviceCapability.isVehicle("vehicle.*"))
        assertFalse(DeviceCapability.isVehicle("vendor.acme.led"))
        assertFalse(DeviceCapability.isVehicle("audio.tts"))
    }

    @Test
    fun exactLookupIsCaseSensitiveAndRejectsPrefixes() {
        assertEquals(DeviceCapability.AUDIO_TTS, DeviceCapability.exact("audio.tts"))
        assertNull(DeviceCapability.exact("Audio.TTS"))
        assertNull(DeviceCapability.exact("vehicle.speed"))
    }
}
