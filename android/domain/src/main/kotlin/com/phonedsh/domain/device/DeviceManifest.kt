// The pdsh-device-caps/1 manifest as a typed Kotlin value.
// SPDX-License-Identifier: MIT
//
// Field names are copied from spec/host/v1/schema/device-capabilities.schema.json
// and the encoding spells them with the schema's own lower_snake_case names
// (`device_id`, `max_frame_bytes`, `text_bytes`, `audio_kbps`), not the
// camelCase spellings the design drafts used. `DeviceCapabilitySchemaTest` reads
// the schema and pins every name, pattern and enum, so a rename on either side
// fails the build.
//
// The manifest is data the host *consumes* from a device (or declares about
// itself). It is deliberately not derived from OS permissions: a granted
// RECORD_AUDIO says nothing about a codec/rate/frame_ms contract, and inventing
// those values would turn an unanswered question into a capability claim.
//
// Encoding and decoding deliberately differ in strictness: the schema's root
// `additionalProperties: false` binds what this host writes, while the decoder
// ignores unknown members because host/v1 README §2 D5 requires the reading side
// to accept any legal JSON. DeviceManifest.parse's KDoc owns that explanation;
// the decoder itself is DeviceManifestDecoder.

package com.phonedsh.domain.device

/**
 * One `pdsh-device-caps/1` manifest.
 *
 * Construction validates everything the schema constrains at this level: the
 * `device_id` pattern, the protocol version shape, capability names (exact
 * vocabulary, `vehicle.` prefix or `vendor.<name>.*`) and the limits/auth
 * ranges. A malformed manifest fails where it is built, never at the wire.
 *
 * @param deviceId the stable device identity; the schema pattern rejects
 *   whitespace and the empty string.
 * @param protocol the transport protocol and its `MAJOR.MINOR` version.
 * @param capabilities only the capabilities the device actually declares; an
 *   undeclared capability is unavailable by definition.
 * @param limits the session limits; `max_frame_bytes` is mandatory and bounded
 *   at 64 KiB by the schema.
 * @param auth how the device is paired and how replay is prevented.
 */
class DeviceManifest(
    deviceId: String,
    protocol: DeviceProtocol,
    capabilities: Map<String, CapabilityValue>,
    limits: DeviceLimits,
    auth: DeviceAuth,
) {
    /** The schema tag; always [SCHEMA]. */
    val schema: String
        get() = SCHEMA

    val deviceId: String = deviceId
    val protocol: DeviceProtocol = protocol
    val capabilities: Map<String, CapabilityValue> = LinkedHashMap<String, CapabilityValue>(capabilities.size).apply {
        capabilities.forEach { (name, value) ->
            require(DeviceCapability.isDeclaredName(name)) {
                "unknown capability name \"$name\": a device capability must be declared by " +
                    "device-capabilities.schema.json, live under vehicle.*, or live under vendor.<name>.*"
            }
            if (DeviceCapability.isVehicle(name)) {
                // The schema's vehicle.* value requires granted_by; vehicle access
                // exists only when the vendor granted it (device-connector §4.5).
                require(value.string("granted_by")?.isNotBlank() == true) {
                    "vehicle capability \"$name\" requires the schema's granted_by member"
                }
            }
            put(name, value)
        }
    }
    val limits: DeviceLimits = limits
    val auth: DeviceAuth = auth

    init {
        require(DEVICE_ID_PATTERN.matches(deviceId)) {
            "device_id \"$deviceId\" does not match the schema pattern $DEVICE_ID_PATTERN"
        }
    }

    /** Whether the schema marks [capability] (or its `vehicle.` prefix) provisional. */
    fun isProvisional(capability: String): Boolean = DeviceCapability.isProvisional(capability)

    /** Encodes the manifest as the `pdsh-device-caps/1` JSON document. */
    fun toJson(): String = DeviceManifestJson.encode(this)

    override fun toString(): String =
        "DeviceManifest(deviceId=$deviceId, capabilities=${capabilities.keys})"

    companion object {
        /** The schema's `schema` const. */
        const val SCHEMA: String = "pdsh-device-caps/1"

        /** The schema's `device_id` pattern, copied verbatim. */
        internal val DEVICE_ID_PATTERN = Regex("^[A-Za-z0-9][A-Za-z0-9:._-]{0,127}$")

        /**
         * Decodes one `pdsh-device-caps/1` document.
         *
         * **The closed root and the tolerant decoder are not in conflict.** The
         * schema sets `additionalProperties: false` at the root and under
         * `protocol`, `limits` and `auth`, but that rule binds the *encoder*: it
         * is the promise that [toJson] never emits a member the schema does not
         * name, which is what keeps a written manifest a closed document. This
         * decoder is deliberately looser and ignores unknown members wherever
         * they appear — root, `protocol`, a capability value, `limits`, `auth` —
         * because host/v1 README §2 D5 requires the decoding side to accept any
         * legal JSON. A peer (or a newer revision of this host) may add a member,
         * and refusing a document whose meaning we fully understand would make
         * this host unable to read its own future. The accepted cost is stated
         * rather than hidden: an unknown member does not survive a
         * decode/re-encode round trip.
         *
         * Tolerance covers names only. A *known* member is checked against the
         * schema: a wrong JSON type is [DeviceManifestFailure.WRONG_TYPE], a
         * value outside a pattern, length, range, enum or const is
         * [DeviceManifestFailure.OUT_OF_RANGE], and an absent required member is
         * [DeviceManifestFailure.MISSING_MEMBER] — never a default and never a
         * partially filled manifest.
         *
         * Capability values follow the schema's own split. A vocabulary entry
         * keeps exactly the value members the schema declares for it (an extra
         * member is dropped); a `vehicle.<name>` or `vendor.<name>.*` value is
         * passed through with every member intact, nested objects included,
         * because the schema calls vendor values unparsed and requires
         * `granted_by` for vehicle. A capability *name* this revision does not
         * know is dropped, not rejected: the schema allows additional names and
         * defines "not declared" as unavailable.
         *
         * Non-canonical JSON is accepted, as D5 requires of a decoder: members
         * may arrive in any order, and a duplicate member name keeps its last
         * value.
         *
         * @throws DeviceManifestException for every refusal; its
         *   [DeviceManifestFailure] is the stable reason.
         */
        fun parse(json: String): DeviceManifest = DeviceManifestDecoder.decode(json)

        /**
         * Parses [json], or returns `null` when it is not a JSON document.
         *
         * The `null` is narrow on purpose: it covers exactly
         * [DeviceManifestFailure.MALFORMED_JSON] — an empty string, a fragment,
         * a document followed by trailing bytes. A well-formed JSON document
         * that is missing a required member or carries a type or value the
         * schema forbids is *broken*, not *absent*, and still throws. `null`
         * must not become the answer to "the device sent nonsense", because the
         * caller would lose the reason and the manifest would look unimplemented
         * rather than wrong.
         */
        fun parseOrNull(json: String): DeviceManifest? = DeviceManifestDecoder.decodeOrNull(json)
    }
}

/** The `protocol` object: the transport id and its `MAJOR.MINOR` version. */
data class DeviceProtocol(
    val id: String,
    val version: String,
) {
    init {
        require(id.isNotEmpty() && id.length <= 128) {
            "protocol.id must be 1..128 characters, was ${id.length}"
        }
        require(VERSION_PATTERN.matches(version)) {
            "protocol.version \"$version\" must be MAJOR.MINOR, matching $VERSION_PATTERN"
        }
    }

    companion object {
        /** The schema's `protocol.version` pattern, copied verbatim. */
        internal val VERSION_PATTERN = Regex("^[0-9]+\\.[0-9]+$")
    }
}

/**
 * The `limits` object.
 *
 * Only `max_frame_bytes` is required. The schema bounds it at 65536 — the
 * adapter's 64 KiB frame ceiling (device-connector §4.6) — so a larger value is
 * rejected here rather than discovered by the first oversized frame.
 */
data class DeviceLimits(
    val maxFrameBytes: Int,
    val textBytes: Int? = null,
    val audioKbps: Int? = null,
) {
    init {
        require(maxFrameBytes in 1..MAX_FRAME_BYTES) {
            "max_frame_bytes must be 1..$MAX_FRAME_BYTES, was $maxFrameBytes"
        }
        require(textBytes == null || textBytes > 0) { "text_bytes must be positive, was $textBytes" }
        require(audioKbps == null || audioKbps > 0) { "audio_kbps must be positive, was $audioKbps" }
    }

    companion object {
        /** The schema's upper bound for `max_frame_bytes`. */
        const val MAX_FRAME_BYTES: Int = 65_536
    }
}

/**
 * The `auth` object.
 *
 * [replay] is a schema `const`: the device must use monotonically increasing
 * counters plus a TTL, never a bare timestamp (device-adapter-contract §5).
 */
data class DeviceAuth(
    val pairing: Pairing,
    val replay: String = REPLAY_COUNTER_TTL,
) {
    init {
        require(replay == REPLAY_COUNTER_TTL) {
            "auth.replay must be \"$REPLAY_COUNTER_TTL\", was \"$replay\""
        }
    }

    /** The schema's `auth.pairing` enum. */
    enum class Pairing(val wireName: String) {
        CODE("code"),
        BLE_PASSKEY("ble-passkey"),
        CERT("cert"),
    }

    companion object {
        /** The schema's `auth.replay` const. */
        const val REPLAY_COUNTER_TTL: String = "counter+ttl"
    }
}
