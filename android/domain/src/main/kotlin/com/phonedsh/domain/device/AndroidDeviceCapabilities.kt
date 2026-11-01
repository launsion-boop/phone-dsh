// The Android implementation of the DeviceCapabilities SPI: framework reads only.
// SPDX-License-Identifier: MIT
//
// What can be measured is measured here and reported honestly:
//
//  * WebView provider — a missing/disabled provider is `null`, never a guessed
//    Chromium version. The plan keeps versionName as telemetry; feature
//    detection (`WebViewFeature.isFeatureSupported`) belongs to `:engine`, and
//    this SPI does not turn a version into a gate (plan R4/R15, whitelist
//    `platform.webview-version`).
//  * Foreground-service permissions — the library declares none (see the
//    manifest): it reports what the composition root's app declared. A per-type
//    permission that does not exist below API 34 is `null`, not `false`.
//  * Memory ceiling — `MemoryInfo.totalMem`, the input the budget table's tier
//    selection maps to a row (whitelist `platform.budgettier-memory`). The
//    mapping itself is policy above this layer and happens once per boot.
//
// The manifest is *not* synthesized from these facts: a granted microphone
// permission does not prove a codec/rate/frame contract, so the declared
// manifest is passed in by the composition root (or a device connector) and is
// validated by [DeviceManifest] before it ever reaches this class. The one edge
// from a measurement to a published manifest is [asDiscoveredDevice], and it fills
// only the members a measurement answers (a screen target's pixel size), per
// [LocalDeviceManifest].

package com.phonedsh.domain.device

import android.app.ActivityManager
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.webkit.WebView

/**
 * Reads the Android runtime facts behind [DeviceCapabilities].
 *
 * @param context any context; only the application context is retained.
 * @param manifest the declared `pdsh-device-caps/1` manifest of this device.
 *   The constructor validates it; this class adds no capabilities of its own.
 */
class AndroidDeviceCapabilities(
    context: Context,
    private val manifest: DeviceManifest,
) : DeviceCapabilities {
    private val context: Context = context.applicationContext ?: context

    override fun snapshot(): DeviceCapabilitySnapshot =
        DeviceCapabilitySnapshot(
            manifest = manifest,
            platform = AndroidPlatformFacts(
                sdkInt = Build.VERSION.SDK_INT,
                supportedAbis = Build.SUPPORTED_ABIS.toList(),
                display = displayFacts(),
                webView = webViewFacts(),
                foregroundService = foregroundServiceFacts(),
                totalMemoryBytes = totalMemoryBytes(),
            ),
        )

    /**
     * This host's manifest as another host would discover it.
     *
     * The declared capabilities of the composition root's manifest are re-issued
     * under [identity], with the measured display folded into a declared screen
     * target's pixel size. One [snapshot] feeds both halves, so the identity and the
     * measurements describe the same moment.
     *
     * @throws IllegalArgumentException when a declared capability is incomplete or a
     *   screen target is declared with no measured display; see [LocalDeviceManifest.of].
     */
    fun asDiscoveredDevice(identity: LocalDeviceIdentity): DeviceManifest {
        val current = snapshot()
        return LocalDeviceManifest.of(identity, current.manifest.capabilities, current.platform)
    }

    private fun displayFacts(): DisplayFacts {
        val metrics = context.resources.displayMetrics
        return DisplayFacts(
            widthPx = metrics.widthPixels,
            heightPx = metrics.heightPixels,
            densityDpi = metrics.densityDpi,
            density = metrics.density,
        )
    }

    @Suppress("DEPRECATION") // the flags-free getPackageInfo overload predates API 33
    private fun webViewFacts(): WebViewFacts {
        val provider = WebView.getCurrentWebViewPackage() ?: return WebViewFacts(null, null)
        val versionName = try {
            context.packageManager.getPackageInfo(provider.packageName, 0).versionName
        } catch (_: PackageManager.NameNotFoundException) {
            null
        }
        return WebViewFacts(provider.packageName, versionName)
    }

    private fun foregroundServiceFacts(): ForegroundServiceFacts {
        val api = Build.VERSION.SDK_INT
        return ForegroundServiceFacts(
            basePermissionGranted = isGranted(PERMISSION_FOREGROUND_SERVICE),
            notificationPermissionGranted =
                if (api >= 33) isGranted(PERMISSION_POST_NOTIFICATIONS) else null,
            microphoneTypeGranted =
                if (api >= 34) isGranted(PERMISSION_FOREGROUND_SERVICE_MICROPHONE) else null,
            connectedDeviceTypeGranted =
                if (api >= 34) isGranted(PERMISSION_FOREGROUND_SERVICE_CONNECTED_DEVICE) else null,
            dataSyncTypeGranted =
                if (api >= 34) isGranted(PERMISSION_FOREGROUND_SERVICE_DATA_SYNC) else null,
            mediaPlaybackTypeGranted =
                if (api >= 34) isGranted(PERMISSION_FOREGROUND_SERVICE_MEDIA_PLAYBACK) else null,
        )
    }

    private fun isGranted(permission: String): Boolean =
        context.checkSelfPermission(permission) == PackageManager.PERMISSION_GRANTED

    private fun totalMemoryBytes(): Long? {
        val manager = context.getSystemService(Context.ACTIVITY_SERVICE) as? ActivityManager
            ?: return null
        val info = ActivityManager.MemoryInfo()
        manager.getMemoryInfo(info)
        // totalMem is 0 only on a failed/absent reading; that is "unknown", and
        // the caller must not turn it into a tier.
        return if (info.totalMem > 0L) info.totalMem else null
    }

    private companion object {
        // String literals rather than `Manifest.permission.*`: the per-type
        // permissions were added in API 34 and a literal keeps the class honest
        // about calling them only behind the version check above.
        const val PERMISSION_FOREGROUND_SERVICE = "android.permission.FOREGROUND_SERVICE"
        const val PERMISSION_POST_NOTIFICATIONS = "android.permission.POST_NOTIFICATIONS"
        const val PERMISSION_FOREGROUND_SERVICE_MICROPHONE =
            "android.permission.FOREGROUND_SERVICE_MICROPHONE"
        const val PERMISSION_FOREGROUND_SERVICE_CONNECTED_DEVICE =
            "android.permission.FOREGROUND_SERVICE_CONNECTED_DEVICE"
        const val PERMISSION_FOREGROUND_SERVICE_DATA_SYNC =
            "android.permission.FOREGROUND_SERVICE_DATA_SYNC"
        const val PERMISSION_FOREGROUND_SERVICE_MEDIA_PLAYBACK =
            "android.permission.FOREGROUND_SERVICE_MEDIA_PLAYBACK"
    }
}
