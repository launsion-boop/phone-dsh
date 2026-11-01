// The capability vocabulary of the device manifest, with the provisional marks.
// SPDX-License-Identifier: MIT
//
// spec/host/v1/schema/device-capabilities.schema.json is the sole authority for
// these names (host/v1 README §2.3: member names are lower_snake_case; an
// unknown capability means "not supported"). The enum mirrors the schema's
// `capabilities` property names one-for-one and carries each entry's value
// members; `DeviceCapabilitySchemaTest` reads the schema and fails if this list,
// a member list or the provisional marks drift.
//
// A capability with no instance under `spec/host/v1/golden/device-*.json` is
// marked `provisional: true` there and `provisional = true` here, and the test
// asserts the two sets are equal. The marker says "the word exists but no golden
// proves its shape yet"; it does not say "supported".

package com.phonedsh.domain.device

/**
 * One capability name of `pdsh-device-caps/1`, with its value members.
 *
 * The member lists are the schema's `properties` and `required` for this entry.
 * The decoder keeps exactly [required] plus [optional] from a decoded value, so
 * an unknown member of a standard capability is dropped rather than rejected
 * (host/v1 README §2 D5); [DeviceManifest.parse] documents that asymmetry.
 *
 * @property wireName the exact schema property name. The last entry is
 *   `vehicle.*`, schema notation for the whole `vehicle.` prefix, so
 *   [isPrefix] is true for it.
 * @property provisional whether the schema marks the capability provisional.
 * @property required the value members the schema requires for this name.
 * @property optional the value members the schema declares but does not
 *   require; empty when the value has no optional member.
 */
enum class DeviceCapability(
    val wireName: String,
    val provisional: Boolean,
    val required: Set<String>,
    val optional: Set<String> = emptySet(),
) {
    AUDIO_TTS("audio.tts", provisional = false, required = setOf("codec", "rate")),
    AUDIO_ASR("audio.asr", provisional = false, required = setOf("rate")),
    AUDIO_MIC_STREAM(
        "audio.mic.stream",
        provisional = false,
        required = setOf("codec", "rate", "frame_ms"),
        optional = setOf("max_minutes"),
    ),
    DISPLAY_TEXT("display.text", provisional = false, required = setOf("max_chars")),
    LIGHT_EFFECT("light.effect", provisional = false, required = setOf("effects")),
    SPEAKER_VOLUME("speaker.volume", provisional = false, required = setOf("range")),
    CONTROL_GPIO("control.gpio", provisional = false, required = setOf("pins")),
    CALL_BLE("call.ble", provisional = false, required = setOf("uplink", "codec")),
    CALL_HFP("call.hfp", provisional = true, required = setOf("profile", "codec")),
    CALL_UAC("call.uac", provisional = true, required = setOf("telephony", "codec")),
    RENDER_LIGHT("render.light", provisional = true, required = setOf("effects")),
    RENDER_PIXEL(
        "render.pixel",
        provisional = false,
        required = setOf("w", "h", "format"),
        optional = setOf("fps"),
    ),
    RENDER_EPAPER(
        "render.epaper",
        provisional = true,
        required = setOf("w", "h", "format"),
        optional = setOf("refresh"),
    ),
    RENDER_SCREEN("render.screen", provisional = true, required = setOf("w", "h", "formats")),
    VEHICLE("vehicle.*", provisional = true, required = setOf("granted_by")),
    ;

    /** Every value member the schema declares: [required] plus [optional]. */
    val members: Set<String> = required + optional

    /** True for `vehicle.*`, the schema's only prefix entry. */
    val isPrefix: Boolean
        get() = wireName.endsWith(".*")

    companion object {
        private val byWireName: Map<String, DeviceCapability> =
            entries.associateBy { it.wireName }

        /**
         * Matches `vendor.<name>.*` (schema/host_check.py's open namespace).
         * Vendor values are passed through unparsed, so they carry no
         * provisional mark of their own.
         */
        private val VENDOR_CAPABILITY =
            Regex("^vendor\\.[A-Za-z0-9_-]+(?:\\.[A-Za-z0-9_-]+)+$")

        /** The six entries the schema marks provisional, in declaration order. */
        val provisional: List<DeviceCapability> = entries.filter { it.provisional }

        /** The exact vocabulary entry for [name], or `null` (prefixes excluded). */
        fun exact(name: String): DeviceCapability? = byWireName[name]

        /**
         * Whether [name] may appear in a manifest's capability map: an exact
         * vocabulary entry, a concrete `vehicle.` capability (the schema's
         * `vehicle.*` entry), or a vendor extension.
         */
        fun isDeclaredName(name: String): Boolean =
            byWireName.containsKey(name) ||
                name.startsWith(VEHICLE_PREFIX) ||
                VENDOR_CAPABILITY.matches(name)

        /**
         * Whether [name] carries the schema's provisional mark. A concrete
         * `vehicle.speed` inherits the mark of the `vehicle.*` entry; a vendor
         * extension is opaque and never marked.
         */
        fun isProvisional(name: String): Boolean =
            byWireName[name]?.provisional == true || name.startsWith(VEHICLE_PREFIX)

        /** Whether [name] is a vendor extension (`vendor.<name>.*`). */
        fun isVendorExtension(name: String): Boolean = VENDOR_CAPABILITY.matches(name)

        /** Whether [name] is covered by the schema's `vehicle.*` entry. */
        fun isVehicle(name: String): Boolean = name.startsWith(VEHICLE_PREFIX)

        /** The prefix of the schema's `vehicle.*` entry. */
        const val VEHICLE_PREFIX = "vehicle."
    }
}
