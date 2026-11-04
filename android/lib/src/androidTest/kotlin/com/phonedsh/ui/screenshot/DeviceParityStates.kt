// The device-connector captures: android-only states, at the 402 x 874 @3 viewport.
// SPDX-License-Identifier: MIT
//
// Provenance: iOS PR #13 shipped these three pages **without** baseline screenshots
// (`docs/receipts/ios-baseline-screens/` holds 27 states and none of them is a device
// page). So there is nothing to diff against, and this registry says so instead of
// pretending: each entry names its iOS counterpart as absent.
//
// Why it is a sibling of `ParityState` and not part of it: that enum is keyed by an iOS
// file and `android/tools/screenshot-capture.sh`'s `check_parity_registry()` asserts it
// is *exactly* 27 rows whose `iosFile` values match the iOS directory both ways. An
// android-only state added there would fail that gate. This file is the same registry
// shape for states that have no baseline, written to `device-registry.txt` next to
// `parity-registry.txt`, so the names are visible to a comparison tool without
// corrupting the 27-state contract.
//
// Names follow the same rule as the parity registry: `<kind>-<ios state id>`, with the
// id here being the page the lane built.
package com.phonedsh.ui.screenshot

/** iOS shipped no baseline for the three device-connector pages. */
private const val NO_IOS_BASELINE: String = "(none: iOS PR #13 ships no baseline for this page)"

/** The registry file this lane writes; it is not the 27-state parity registry. */
private const val DEVICE_REGISTRY_FILE: String = "device-registry.txt"

/**
 * One device-connector capture.
 *
 * @property androidName the PNG name inside the parity capture directory.
 * @property iosFile the iOS baseline file; `(none)` — no baseline exists for these pages.
 * @property screen the page this state renders.
 * @property owner the lane that keeps the state faithful.
 * @property status the capture state.
 * @property note what the state contains.
 */
enum class DeviceParityState(
    val androidName: String,
    val iosFile: String,
    val screen: String,
    val owner: String,
    val status: DeviceParityStatus,
    val note: String,
) {
    PAGE_DEVICE_CONNECTION(
        androidName = "page-device-connection",
        iosFile = NO_IOS_BASELINE,
        screen = "NativeDeviceConnectionPage",
        owner = "L5 device-connector lane",
        status = DeviceParityStatus.CAPTURED,
        note = "one published device + the connector source row + both transport rows at 未提供",
    ),
    PAGE_DEVICE_SESSION(
        androidName = "page-device-session",
        iosFile = NO_IOS_BASELINE,
        screen = "NativeDeviceSessionPage",
        owner = "L5 device-connector lane",
        status = DeviceParityStatus.CAPTURED,
        note = "durable window + live tail merged, 读取更早消息 visible (hasMore), read-only footer",
    ),
    PAGE_DEVICE_SESSION_EARLIER(
        androidName = "page-device-session-earlier",
        iosFile = NO_IOS_BASELINE,
        screen = "NativeDeviceSessionPage",
        owner = "L5 device-connector lane",
        status = DeviceParityStatus.CAPTURED,
        note = "short window: 读取更早消息 on screen because the device answered hasMore = true",
    ),
    PAGE_SESSION_ARTIFACTS(
        androidName = "page-session-artifacts",
        iosFile = NO_IOS_BASELINE,
        screen = "SessionArtifactsPage",
        owner = "L5 device-connector lane",
        status = DeviceParityStatus.CAPTURED,
        note = "本 session (one attributed) + 未归属 (one unclaimed) sections",
    ),
    ;

    /** The registry line, in the same six-field shape `parity-registry.txt` uses. */
    fun registryLine(): String =
        listOf(androidName, iosFile, status.id, owner, screen, note).joinToString("|")

    companion object {
        /**
         * The registry file this lane writes.
         *
         * Read at call time, never from an enum constant's constructor: Kotlin
         * initialises the constants before the companion, so a constant cannot be an
         * argument here. The value itself is the file-level private above.
         */
        const val REGISTRY_FILE: String = DEVICE_REGISTRY_FILE
    }
}

/** Whether an android-only capture exists yet. */
enum class DeviceParityStatus(val id: String) {
    /** Captured on a device at the parity viewport. */
    CAPTURED("captured"),

    /** Registered, not captured yet. */
    PENDING("pending"),
}
