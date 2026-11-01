// The device-capability SPI: one snapshot of what the host knows about a device.
// SPDX-License-Identifier: MIT
//
// Two different things are read at different times, and the SPI keeps them
// apart on purpose:
//
//  * [DeviceCapabilitySnapshot.manifest] is the `pdsh-device-caps/1` contract
//    from spec/host/v1. It is *declared* — by a paired device, or by the
//    composition root for the local host — because codec/rate/frame/auth are
//    negotiated protocol facts, not OS facts. This module never invents one
//    from a permission.
//  * [DeviceCapabilitySnapshot.platform] is *measured*: the Android runtime
//    facts the host's degradation decisions need (density, ABI, SDK, WebView
//    provider, foreground-service permission state, memory ceiling). These are
//    not part of the device vocabulary; they are the host-side inputs behind
//    `spec/platform`'s `budgettier-memory`, `engine.webview-version` and
//    `background.*` entries, and they stay out of the manifest document.
//
// Keeping the split explicit is the honesty rule of the P6 gate: a capability
// bit is true only when something actually proved it.

package com.phonedsh.domain.device

/**
 * The platform's read-only view of device capabilities.
 *
 * Callers read one [snapshot] instead of five accessors so the manifest and the
 * platform facts describe the same moment. Implementations must be cheap and
 * side-effect free; this is a query, not a subscription (live signals such as
 * scene phase are `com.phonedsh.platform.LifecycleSignals`, not this SPI).
 */
interface DeviceCapabilities {
    /** Reads one consistent snapshot of the declared manifest and measured facts. */
    fun snapshot(): DeviceCapabilitySnapshot
}

/** One reading of the device capability surface. */
data class DeviceCapabilitySnapshot(
    val manifest: DeviceManifest,
    val platform: AndroidPlatformFacts,
)

/**
 * Measured Android runtime facts.
 *
 * @property sdkInt `Build.VERSION.SDK_INT`.
 * @property supportedAbis `Build.SUPPORTED_ABIS` in platform order (the first
 *   entry is the preferred ABI).
 * @property display the current display metrics.
 * @property webView the installed WebView provider, or a null provider when
 *   none is installed/disabled — the honest "renderer missing" reading, never a
 *   fabricated version.
 * @property foregroundService which foreground-service permissions the app has.
 * @property totalMemoryBytes `ActivityManager.MemoryInfo.totalMem`, the input
 *   `spec/platform`'s budgettier-memory entry maps to a tier. `null` when the
 *   system service or the reading is unavailable; the caller must treat that as
 *   unknown, not as the 8 GiB default.
 */
data class AndroidPlatformFacts(
    val sdkInt: Int,
    val supportedAbis: List<String>,
    val display: DisplayFacts,
    val webView: WebViewFacts,
    val foregroundService: ForegroundServiceFacts,
    val totalMemoryBytes: Long?,
) {
    init {
        require(sdkInt > 0) { "sdkInt must be positive, was $sdkInt" }
        require(supportedAbis.isNotEmpty()) { "supportedAbis must not be empty" }
        require(totalMemoryBytes == null || totalMemoryBytes > 0) {
            "totalMemoryBytes must be positive when present, was $totalMemoryBytes"
        }
    }
}

/** Screen facts: pixel size, density and the scaled density factor. */
data class DisplayFacts(
    val widthPx: Int,
    val heightPx: Int,
    val densityDpi: Int,
    val density: Float,
) {
    init {
        require(widthPx >= 0 && heightPx >= 0) {
            "display size must be non-negative, was ${widthPx}x$heightPx"
        }
        require(densityDpi > 0) { "densityDpi must be positive, was $densityDpi" }
        require(density > 0f) { "density must be positive, was $density" }
    }
}

/**
 * The installed WebView provider.
 *
 * A missing provider is represented by `null` for both members; a provider with
 * an unreadable package version keeps [providerPackage] and a `null`
 * [versionName]. Neither case is an error and neither may be replaced by a
 * guessed Chromium version (plan R4/R15: the version is telemetry, not a gate).
 */
data class WebViewFacts(
    val providerPackage: String?,
    val versionName: String?,
) {
    init {
        require(providerPackage == null || providerPackage.isNotBlank()) {
            "a WebView provider package must be non-blank when present"
        }
        require(versionName == null || versionName.isNotBlank()) {
            "a WebView version must be non-blank when present"
        }
    }
}

/**
 * Foreground-service permission state.
 *
 * A `null` type member means "not applicable on this API level" (the per-type
 * permissions exist from API 34) and must not be read as denied. This is the
 * input the plan's promise tiers need: `FOREGROUND_SERVICE_MICROPHONE` absent
 * on the app, or `POST_NOTIFICATIONS` denied, narrows what the host may claim
 * (plan §7.4-4, §7.9; whitelist `platform.post-notifications-degraded`).
 */
data class ForegroundServiceFacts(
    val basePermissionGranted: Boolean,
    val notificationPermissionGranted: Boolean?,
    val microphoneTypeGranted: Boolean?,
    val connectedDeviceTypeGranted: Boolean?,
    val dataSyncTypeGranted: Boolean?,
    val mediaPlaybackTypeGranted: Boolean?,
)
