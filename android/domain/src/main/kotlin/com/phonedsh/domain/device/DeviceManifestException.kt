// The stable failure codes of the device-manifest decoder.
// SPDX-License-Identifier: MIT
//
// A connector reacts differently to the three kinds of refusal, so they are
// distinct codes rather than one "invalid manifest": the bytes were not JSON at
// all (retry/read the file again), a required member is absent (the peer speaks
// an older or incomplete contract), or a known member carries a type/value the
// schema forbids (the peer is wrong and the manifest cannot be trusted). The
// codes are stable because they may be logged, retried on or quarantined on;
// `WalErrorCode` is the local precedent for a code table that callers match on.

package com.phonedsh.domain.device

/**
 * The failure classes of [DeviceManifest.parse].
 *
 * The [code] values are stable identifiers: an existing entry is never renamed
 * or reused, and new members are appended. The codes are not wire protocol
 * codes — a device never sees one; they are what the host records when it
 * refuses a manifest.
 */
enum class DeviceManifestFailure(val code: String) {
    /**
     * The text is not one well-formed JSON value: bad syntax, trailing bytes,
     * or nesting deeper than the decoder's bound. Nothing was interpreted.
     */
    MALFORMED_JSON("DEVICE_MANIFEST_MALFORMED_JSON"),

    /**
     * The text is JSON but the root is not an object (an array, a string, a
     * number, a boolean or `null`). It is a document, just not a manifest.
     */
    ROOT_NOT_OBJECT("DEVICE_MANIFEST_ROOT_NOT_OBJECT"),

    /**
     * A member the schema requires is absent. Absent is not "default": the
     * decoder never substitutes a value the device did not declare.
     */
    MISSING_MEMBER("DEVICE_MANIFEST_MISSING_MEMBER"),

    /**
     * A known member has the wrong JSON type — for example `device_id` is a
     * number, `capabilities` is an array, or an integer member is fractional.
     */
    WRONG_TYPE("DEVICE_MANIFEST_WRONG_TYPE"),

    /**
     * A known member has the right type but violates the schema's pattern,
     * length, range, enum or const — for example `max_frame_bytes` outside
     * 1..65536, `auth.pairing` outside its enum, or a `protocol.version` that
     * is not `MAJOR.MINOR`.
     */
    OUT_OF_RANGE("DEVICE_MANIFEST_OUT_OF_RANGE"),
}

/**
 * A `pdsh-device-caps/1` document that [DeviceManifest.parse] refused.
 *
 * Every refusal is this type: the decoder never returns a partly filled
 * manifest and never turns a known-member violation into a guessed default.
 * Unknown members are not a refusal at all — they are ignored, per host/v1
 * README §2 D5 (see [DeviceManifest.parse]).
 *
 * @property failure the refusal class, whose [DeviceManifestFailure.code] is
 *   stable.
 * @property detail a human-readable explanation naming the JSON path that was
 *   refused (for example `limits.max_frame_bytes`) and the value found. It
 *   carries no machine-local path.
 * @param cause the throwable this refusal wraps, when there is one.
 */
class DeviceManifestException(
    val failure: DeviceManifestFailure,
    val detail: String,
    cause: Throwable? = null,
) : Exception("${failure.code}: $detail", cause) {
    /** The stable code of [failure], for callers that log or match on it. */
    val code: String
        get() = failure.code
}
