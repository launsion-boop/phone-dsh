// Instrumented evidence for the Android DeviceCapabilities implementation.
// SPDX-License-Identifier: MIT
//
// The host suite proves the manifest model against the schema; this test proves
// the measured half is the running device and not a default. Every assertion
// compares two independent reads of the same OS fact, so a stubbed value would
// have to be stubbed twice in agreement — and the permission cases compare with
// the API-gating rule (a per-type permission that does not exist yet is null,
// never false).

package com.phonedsh.domain.device

import android.app.ActivityManager
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.webkit.WebView
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class AndroidDeviceCapabilitiesTest {
    private val context: Context = ApplicationProvider.getApplicationContext()

    @Test
    fun platformFactsMatchTheRunningDevice() {
        val facts = AndroidDeviceCapabilities(context, TestManifests.localAndroid())
            .snapshot()
            .platform

        assertEquals(Build.VERSION.SDK_INT, facts.sdkInt)
        assertEquals(Build.SUPPORTED_ABIS.toList(), facts.supportedAbis)
        assertTrue(facts.supportedAbis.isNotEmpty())

        val metrics = context.resources.displayMetrics
        assertEquals(metrics.widthPixels, facts.display.widthPx)
        assertEquals(metrics.heightPixels, facts.display.heightPx)
        assertEquals(metrics.densityDpi, facts.display.densityDpi)
        assertEquals(metrics.density, facts.display.density, 0.0f)
        assertTrue(facts.display.densityDpi > 0)

        val manager = context.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
        val info = ActivityManager.MemoryInfo()
        manager.getMemoryInfo(info)
        assertEquals(info.totalMem, facts.totalMemoryBytes)
        assertTrue(facts.totalMemoryBytes!! > 0L)
    }

    @Test
    fun webViewFactsReflectTheInstalledProvider() {
        val facts = AndroidDeviceCapabilities(context, TestManifests.localAndroid())
            .snapshot()
            .platform
        val provider = WebView.getCurrentWebViewPackage()

        assertEquals(provider?.packageName, facts.webView.providerPackage)
        if (provider == null) {
            assertNull(facts.webView.versionName)
        } else {
            assertNotNull(facts.webView.versionName)
            assertTrue(facts.webView.versionName!!.isNotBlank())
        }
    }

    @Test
    fun foregroundServiceFactsFollowThePermissionModel() {
        val facts = AndroidDeviceCapabilities(context, TestManifests.localAndroid())
            .snapshot()
            .platform
            .foregroundService

        assertEquals(granted("android.permission.FOREGROUND_SERVICE"), facts.basePermissionGranted)

        if (Build.VERSION.SDK_INT >= 33) {
            assertEquals(
                granted("android.permission.POST_NOTIFICATIONS"),
                facts.notificationPermissionGranted,
            )
        } else {
            assertNull(facts.notificationPermissionGranted)
        }

        if (Build.VERSION.SDK_INT >= 34) {
            assertEquals(
                granted("android.permission.FOREGROUND_SERVICE_MICROPHONE"),
                facts.microphoneTypeGranted,
            )
            assertEquals(
                granted("android.permission.FOREGROUND_SERVICE_CONNECTED_DEVICE"),
                facts.connectedDeviceTypeGranted,
            )
            assertEquals(
                granted("android.permission.FOREGROUND_SERVICE_DATA_SYNC"),
                facts.dataSyncTypeGranted,
            )
            assertEquals(
                granted("android.permission.FOREGROUND_SERVICE_MEDIA_PLAYBACK"),
                facts.mediaPlaybackTypeGranted,
            )
        } else {
            assertNull(facts.microphoneTypeGranted)
            assertNull(facts.connectedDeviceTypeGranted)
            assertNull(facts.dataSyncTypeGranted)
            assertNull(facts.mediaPlaybackTypeGranted)
        }
    }

    @Test
    fun theDeclaredManifestIsCarriedAndEncodedForTheWire() {
        val manifest = TestManifests.everyCapability()
        val snapshot = AndroidDeviceCapabilities(context, manifest).snapshot()

        assertEquals(manifest.deviceId, snapshot.manifest.deviceId)
        assertEquals("pdsh-device-caps/1", snapshot.manifest.schema)

        val document = JSONObject(snapshot.manifest.toJson())
        assertEquals("pdsh-device-caps/1", document.getString("schema"))
        assertEquals(manifest.deviceId, document.getString("device_id"))
        assertEquals("testws", document.getJSONObject("protocol").getString("id"))
        assertEquals(65_536, document.getJSONObject("limits").getInt("max_frame_bytes"))
        assertEquals(
            "counter+ttl",
            document.getJSONObject("auth").getString("replay"),
        )
        assertEquals(15, document.getJSONObject("capabilities").length())
    }

    private fun granted(permission: String): Boolean =
        context.checkSelfPermission(permission) == PackageManager.PERMISSION_GRANTED
}
