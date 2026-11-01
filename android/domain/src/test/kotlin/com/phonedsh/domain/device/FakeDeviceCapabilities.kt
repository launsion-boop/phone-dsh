// The host test double for the DeviceCapabilities SPI.
// SPDX-License-Identifier: MIT
//
// Mirrors `com.phonedsh.platform.testing.FakePlatform`: the SPI must be usable
// from a host JVM with no Android API, and a snapshot is the smallest thing to
// fake. The instrumented AndroidDeviceCapabilitiesTest covers the real reads.

package com.phonedsh.domain.device

/** A [DeviceCapabilities] that returns one fixed snapshot and counts reads. */
class FakeDeviceCapabilities private constructor(
    private val fixed: DeviceCapabilitySnapshot,
) : DeviceCapabilities {
    /** The default fake: the local-host manifest over [fakePlatformFacts]. */
    constructor() : this(snapshot(TestManifests.localAndroid()))

    /** A fake over [manifest] and [fakePlatformFacts]. */
    constructor(manifest: DeviceManifest) : this(snapshot(manifest))

    /** How many times [snapshot] was called; the upper layer must not poll. */
    var reads: Int = 0
        private set

    override fun snapshot(): DeviceCapabilitySnapshot {
        reads += 1
        return fixed
    }

    companion object {
        /** The fake's measured facts; deliberately a plausible API 35 phone. */
        val fakePlatformFacts: AndroidPlatformFacts = AndroidPlatformFacts(
            sdkInt = 35,
            supportedAbis = listOf("arm64-v8a", "armeabi-v7a"),
            display = DisplayFacts(widthPx = 1080, heightPx = 2400, densityDpi = 420, density = 2.625f),
            webView = WebViewFacts(
                providerPackage = "com.google.android.webview",
                versionName = "131.0.6778.135",
            ),
            foregroundService = ForegroundServiceFacts(
                basePermissionGranted = true,
                notificationPermissionGranted = true,
                microphoneTypeGranted = true,
                connectedDeviceTypeGranted = false,
                dataSyncTypeGranted = true,
                mediaPlaybackTypeGranted = false,
            ),
            totalMemoryBytes = 8L * 1024L * 1024L * 1024L,
        )

        /** A snapshot with [manifest] and the fake platform facts. */
        fun snapshot(manifest: DeviceManifest): DeviceCapabilitySnapshot =
            DeviceCapabilitySnapshot(manifest, fakePlatformFacts)
    }
}
