// This host as the device another host discovers.
// SPDX-License-Identifier: MIT
//
// [AndroidDeviceCapabilities] answers two questions: what did this device declare,
// and what did the runtime measure. It does not answer a third — what document does
// this host publish when it is itself the discovered device — because the manifest it
// holds is handed in by the composition root and nothing turned the measured half into
// a manifest. This file is that missing edge, and it is deliberately thin:
//
//  * Every member no Android API measures stays an input: the device id, the protocol,
//    the limits and the pairing mode. The builder invents none of them. A guessed
//    max_frame_bytes is a contract defect, and a default here would hide it until the
//    first oversized frame.
//  * The two members a display measurement does answer — a screen render target's
//    pixel width and height — are filled from [AndroidPlatformFacts.display] when the
//    declaration omits them. A declaration that states its own size wins, because a
//    host may render into a window smaller than the panel. Nothing else is derived:
//    display metrics say nothing about a pixel matrix, an e-paper panel or an audio
//    codec, so claiming those from a measurement would be the exact dishonesty the
//    capability SPI exists to prevent.
//  * A declared capability that is missing a member the schema requires is refused
//    here rather than encoded. [DeviceManifest] validates names, ranges and the
//    vehicle rule, but not each vocabulary entry's required members, so a manifest
//    built from a partial [CapabilityValue] encodes a document this host's own
//    decoder then refuses with MISSING_MEMBER. Publishing ourselves is the one place
//    where closing that asymmetry costs nothing; whether the constructor should
//    refuse it too is reported as an open question, not decided by this file.

package com.phonedsh.domain.device

/**
 * The declared half of this host's manifest: the members no Android API measures.
 *
 * It is separate from [AndroidPlatformFacts] because the two are known at different
 * times and for different reasons: these are choices (which identity, which protocol,
 * which frame ceiling), the facts are measurements. Keeping them apart is what lets a
 * test publish a manifest with real measurements and no device.
 *
 * @property deviceId the stable identity this host publishes. [DeviceManifest]
 *   applies the schema's pattern to it.
 * @property protocol the transport this host speaks, with its `MAJOR.MINOR` version.
 * @property limits the frame and text ceilings this host will honour.
 * @property pairing how a peer pairs with this host.
 */
data class LocalDeviceIdentity(
    val deviceId: String,
    val protocol: DeviceProtocol,
    val limits: DeviceLimits,
    val pairing: DeviceAuth.Pairing,
)

/**
 * Builds the `pdsh-device-caps/1` manifest this host publishes about itself.
 *
 * No member is defaulted: the measured facts fill only the two members a measurement
 * answers (a screen target's pixel size), and a declaration that states them keeps
 * its own values. The result is a manifest that [DeviceManifest.toJson] encodes and
 * [DeviceManifest.parse] reads back, which is what makes the local host
 * indistinguishable on the wire from a device that declared the same thing.
 */
object LocalDeviceManifest {
    /**
     * Composes this host's manifest.
     *
     * @param identity the declared half; see [LocalDeviceIdentity].
     * @param capabilities exactly what this host declares it can do. An undeclared
     *   capability is unavailable, so a caller must not pass "probably supported"
     *   entries.
     * @param facts the measured platform facts; only the display size is read.
     * @throws IllegalArgumentException when a declared standard capability is missing
     *   a member the schema requires and no measurement answers it, or when a screen
     *   target is declared on a device with no measured display.
     */
    fun of(
        identity: LocalDeviceIdentity,
        capabilities: Map<String, CapabilityValue>,
        facts: AndroidPlatformFacts,
    ): DeviceManifest {
        val resolved = LinkedHashMap<String, CapabilityValue>(capabilities.size)
        capabilities.forEach { (name, value) ->
            resolved[name] = resolve(name, value, facts)
        }
        return DeviceManifest(
            deviceId = identity.deviceId,
            protocol = identity.protocol,
            capabilities = resolved,
            limits = identity.limits,
            auth = DeviceAuth(identity.pairing),
        )
    }

    private fun resolve(
        name: String,
        value: CapabilityValue,
        facts: AndroidPlatformFacts,
    ): CapabilityValue {
        // vehicle.* and vendor.<name>.* are passed through unparsed (the schema's own
        // rule), so they carry no required-member list this builder could check.
        val capability = DeviceCapability.exact(name) ?: return value
        val resolved = if (capability == DeviceCapability.RENDER_SCREEN) {
            screen(name, value, facts)
        } else {
            value
        }
        val missing = capability.required.filterNot(resolved.members::containsKey)
        require(missing.isEmpty()) {
            "declared capability \"$name\" is missing the schema's required member(s) " +
                "$missing; DeviceManifest.parse would refuse the encoded document with " +
                "MISSING_MEMBER"
        }
        return resolved
    }

    /**
     * Fills a screen target's pixel size from the measured display.
     *
     * Only [DeviceCapability.RENDER_SCREEN] gets this treatment: a display measurement
     * describes the screen, not a pixel matrix or an e-paper panel, so the other
     * render capabilities keep whatever their declaration states and are refused when
     * it is incomplete.
     */
    private fun screen(
        name: String,
        value: CapabilityValue,
        facts: AndroidPlatformFacts,
    ): CapabilityValue {
        val display = facts.display
        require(display.widthPx > 0 && display.heightPx > 0) {
            "declared capability \"$name\" needs a measured display, but this device " +
                "reported ${display.widthPx}x${display.heightPx}"
        }
        val members = LinkedHashMap<String, Any>(value.members)
        if (!members.containsKey("w")) members["w"] = display.widthPx
        if (!members.containsKey("h")) members["h"] = display.heightPx
        return CapabilityValue.ofMembers(members)
    }
}
