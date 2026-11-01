// The host-side DeviceCapabilities test: fake facts + the wire manifest.
// SPDX-License-Identifier: MIT

package com.phonedsh.domain.device

import com.phonedsh.domain.testing.MiniJson
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class FakeDeviceCapabilitiesTest {
    @Test
    fun theSnapshotIsStableAcrossReads() {
        val fake = FakeDeviceCapabilities()

        val first = fake.snapshot()
        val second = fake.snapshot()

        assertEquals(2, fake.reads)
        assertEquals(first, second)
        assertTrue(first === second)
    }

    @Test
    fun theFakeReportsTheMeasuredFactsItWasGiven() {
        val facts = FakeDeviceCapabilities().snapshot().platform

        assertEquals(35, facts.sdkInt)
        assertEquals(listOf("arm64-v8a", "armeabi-v7a"), facts.supportedAbis)
        assertEquals(420, facts.display.densityDpi)
        assertEquals(2.625f, facts.display.density, 0.0f)
        assertEquals("com.google.android.webview", facts.webView.providerPackage)
        assertTrue(facts.foregroundService.basePermissionGranted)
        assertEquals(8L * 1024L * 1024L * 1024L, facts.totalMemoryBytes)
    }

    @Test
    fun theFakeCarriesTheDeclaredManifestVerbatim() {
        val fake = FakeDeviceCapabilities(TestManifests.everyCapability())
        val manifest = fake.snapshot().manifest

        assertEquals("test-device-1", manifest.deviceId)
        assertEquals("pdsh-device-caps/1", manifest.schema)
        val document = MiniJson.parseObject(manifest.toJson())
        assertEquals(
            setOf("schema", "device_id", "protocol", "capabilities", "limits", "auth"),
            document.keys,
        )
    }
}
