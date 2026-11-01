// Encoding of a DeviceManifest as pdsh-device-caps/1 JSON.
// SPDX-License-Identifier: MIT
//
// A hand-written writer, not a JSON library: the module adds no dependency for
// one document, and the encoder is the place where the schema's member names
// and ordering are spelled. The output is deterministic (root order = schema
// order, capability order = declaration order), which keeps goldens and test
// failures readable.
//
// This writer is the *closed* side of the contract: the schema's root
// `additionalProperties: false` is what it promises to obey, so it emits only
// the six root members. The decoder is DeviceManifestDecoder and is deliberately
// more tolerant (unknown members are ignored, per host/v1 README §2 D5);
// DeviceManifest.parse's KDoc explains why the two directions differ.

package com.phonedsh.domain.device

/** The wire encoder of [DeviceManifest]. */
internal object DeviceManifestJson {
    fun encode(manifest: DeviceManifest): String = buildString(512) {
        append('{')
        appendString("schema")
        append(':')
        appendJson(manifest.schema)
        append(',')
        appendString("device_id")
        append(':')
        appendJson(manifest.deviceId)
        append(',')
        appendString("protocol")
        append(':')
        appendJson(
            linkedMapOf(
                "id" to manifest.protocol.id,
                "version" to manifest.protocol.version,
            ),
        )
        append(',')
        appendString("capabilities")
        append(':')
        append('{')
        var firstCapability = true
        manifest.capabilities.forEach { (name, value) ->
            if (!firstCapability) append(',')
            firstCapability = false
            appendString(name)
            append(':')
            appendJson(value.members)
        }
        append('}')
        append(',')
        appendString("limits")
        append(':')
        append('{')
        appendString("max_frame_bytes")
        append(':')
        appendJson(manifest.limits.maxFrameBytes)
        manifest.limits.textBytes?.let { bytes ->
            append(',')
            appendString("text_bytes")
            append(':')
            appendJson(bytes)
        }
        manifest.limits.audioKbps?.let { kbps ->
            append(',')
            appendString("audio_kbps")
            append(':')
            appendJson(kbps)
        }
        append('}')
        append(',')
        appendString("auth")
        append(':')
        appendJson(
            linkedMapOf(
                "pairing" to manifest.auth.pairing.wireName,
                "replay" to manifest.auth.replay,
            ),
        )
        append('}')
    }

    private fun StringBuilder.appendJson(value: Any?) {
        when (value) {
            is String -> appendString(value)
            is Int, is Long, is Boolean -> append(value.toString())
            is List<*> -> {
                append('[')
                value.forEachIndexed { index, element ->
                    if (index > 0) append(',')
                    appendJson(element)
                }
                append(']')
            }

            is Map<*, *> -> {
                append('{')
                var first = true
                value.forEach { (name, element) ->
                    if (!first) append(',')
                    first = false
                    appendString(name as String)
                    append(':')
                    appendJson(element)
                }
                append('}')
            }

            else -> throw IllegalArgumentException(
                "cannot encode ${value?.let { it::class.simpleName }}; " +
                    "only String, numbers, Booleans, lists and string-keyed maps are allowed",
            )
        }
    }

    private fun StringBuilder.appendString(value: String) {
        append('"')
        value.forEach { character ->
            when (character) {
                '"' -> append("\\\"")
                '\\' -> append("\\\\")
                '\n' -> append("\\n")
                '\r' -> append("\\r")
                '\t' -> append("\\t")
                '\b' -> append("\\b")
                '\u000C' -> append("\\f")
                else -> if (character < ' ') {
                    append("\\u")
                    append(character.code.toString(16).padStart(4, '0'))
                } else {
                    append(character)
                }
            }
        }
        append('"')
    }
}
