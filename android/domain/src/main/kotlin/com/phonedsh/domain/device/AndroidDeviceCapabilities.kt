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
//
// The measured half is also reachable on its own, through [platformFacts]: a host
// that has no device manifest to publish (the phone app reading its own permissions,
// say) still has these runtime facts, and requiring a fabricated manifest to read
// them would be a fake declaration in exchange for a real reading. The class stays
// the manifest-bound face of the same measurement, so a caller that *does* publish
// a manifest gets one consistent snapshot of both halves.

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
            platform = platformFacts(context),
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

    companion object {
        /**
         * Reads the measured half of [DeviceCapabilitySnapshot] with no manifest.
         *
         * This is the same measurement [snapshot] folds into its result, exposed for
         * callers whose question is about the device rather than about a published
         * contract: the phone-permission host reads its own notification and
         * foreground-service state through here, so the two never describe different
         * moments. Nothing is defaulted — a missing WebView provider, memory reading
         * or API-gated permission keeps its `null`.
         *
         * @param context any context; only the application context is used.
         */
        fun platformFacts(context: Context): AndroidPlatformFacts {
            val app = context.applicationContext ?: context
            return AndroidPlatformFacts(
                sdkInt = Build.VERSION.SDK_INT,
                supportedAbis = Build.SUPPORTED_ABIS.toList(),
                display = displayFacts(app),
                webView = webViewFacts(app),
                foregroundService = foregroundServiceFacts(app),
                totalMemoryBytes = totalMemoryBytes(app),
            )
        }

        // String literals rather than `Manifest.permission.*`: the per-type
        // permissions were added in API 34 and a literal keeps the class honest
        // about calling them only behind the version check above.
        private const val PERMISSION_FOREGROUND_SERVICE = "android.permission.FOREGROUND_SERVICE"
        private const val PERMISSION_POST_NOTIFICATIONS = "android.permission.POST_NOTIFICATIONS"
        private const val PERMISSION_FOREGROUND_SERVICE_MICROPHONE =
            "android.permission.FOREGROUND_SERVICE_MICROPHONE"
        private const val PERMISSION_FOREGROUND_SERVICE_CONNECTED_DEVICE =
            "android.permission.FOREGROUND_SERVICE_CONNECTED_DEVICE"
        private const val PERMISSION_FOREGROUND_SERVICE_DATA_SYNC =
            "android.permission.FOREGROUND_SERVICE_DATA_SYNC"
        private const val PERMISSION_FOREGROUND_SERVICE_MEDIA_PLAYBACK =
            "android.permission.FOREGROUND_SERVICE_MEDIA_PLAYBACK"

        private fun displayFacts(context: Context): DisplayFacts {
            val metrics = context.resources.displayMetrics
            return DisplayFacts(
                widthPx = metrics.widthPixels,
                heightPx = metrics.heightPixels,
                densityDpi = metrics.densityDpi,
                density = metrics.density,
            )
        }

        @Suppress("DEPRECATION") // the flags-free getPackageInfo overload predates API 33
        private fun webViewFacts(context: Context): WebViewFacts {
            val provider = WebView.getCurrentWebViewPackage() ?: return WebViewFacts(null, null)
            val versionName = try {
                context.packageManager.getPackageInfo(provider.packageName, 0).versionName
            } catch (_: PackageManager.NameNotFoundException) {
                null
            }
            return WebViewFacts(provider.packageName, versionName)
        }

        private fun foregroundServiceFacts(context: Context): ForegroundServiceFacts {
            val api = Build.VERSION.SDK_INT
            return ForegroundServiceFacts(
                basePermissionGranted = isGranted(context, PERMISSION_FOREGROUND_SERVICE),
                notificationPermissionGranted =
                    if (api >= 33) isGranted(context, PERMISSION_POST_NOTIFICATIONS) else null,
                microphoneTypeGranted =
                    if (api >= 34) isGranted(context, PERMISSION_FOREGROUND_SERVICE_MICROPHONE) else null,
                connectedDeviceTypeGranted =
                    if (api >= 34) isGranted(context, PERMISSION_FOREGROUND_SERVICE_CONNECTED_DEVICE) else null,
                dataSyncTypeGranted =
                    if (api >= 34) isGranted(context, PERMISSION_FOREGROUND_SERVICE_DATA_SYNC) else null,
                mediaPlaybackTypeGranted =
                    if (api >= 34) isGranted(context, PERMISSION_FOREGROUND_SERVICE_MEDIA_PLAYBACK) else null,
            )
        }

        private fun isGranted(context: Context, permission: String): Boolean =
            context.checkSelfPermission(permission) == PackageManager.PERMISSION_GRANTED

        private fun totalMemoryBytes(context: Context): Long? {
            val manager = context.getSystemService(Context.ACTIVITY_SERVICE) as? ActivityManager
                ?: return null
            val info = ActivityManager.MemoryInfo()
            manager.getMemoryInfo(info)
            // totalMem is 0 only on a failed/absent reading; that is "unknown", and
            // the caller must not turn it into a tier.
            return if (info.totalMem > 0L) info.totalMem else null
        }
    }
}
