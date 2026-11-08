// SPDX-License-Identifier: MIT
package com.phonedsh.domain.connector.ble

import java.nio.ByteBuffer
import java.nio.charset.CharacterCodingException
import java.nio.charset.CodingErrorAction
import java.util.UUID

private const val SIG_BASE = "-0000-1000-8000-00805F9B34FB"
private fun sig(short: String): UUID = UUID.fromString("0000$short$SIG_BASE")

/** A standard-profile read or command that the peer data does not satisfy. */
class StandardBleFailure(message: String) : Exception(message)

/**
 * The allowlist of SIG service/characteristic pairs of `spec/device/v1/android-standard-gatt.md`,
 * mirroring Swift `StandardBLEProfile`; not a generic GATT reader or writer.
 * Both ends decode `spec/device/v1/golden/standard-gatt-decode.jsonl`.
 */
enum class StandardBleProfile(service: String, characteristic: String, val unit: String) {
    BATTERY("180F", "2A19", "%"),
    TEMPERATURE("181A", "2A6E", "°C"),
    HUMIDITY("181A", "2A6F", "%"),
    MANUFACTURER("180A", "2A29", ""),
    MODEL("180A", "2A24", ""),
    ALERT("1802", "2A06", ""),
    ;

    val service: UUID = sig(service)
    val characteristic: UUID = sig(characteristic)

    /** The wire name shared with iOS (`StandardBLEProfile.rawValue`). */
    val rawValue: String get() = name.lowercase()

    fun decode(data: ByteArray): String = when (this) {
        BATTERY -> {
            if (data.size != 1 || (data[0].toInt() and 0xFF) > 100) throw StandardBleFailure("Invalid Battery Level")
            (data[0].toInt() and 0xFF).toString()
        }
        TEMPERATURE, HUMIDITY -> {
            if (data.size != 2) throw StandardBleFailure("Invalid environmental measurement length")
            val raw = (data[0].toInt() and 0xFF) or ((data[1].toInt() and 0xFF) shl 8)
            if (this == TEMPERATURE) {
                val signed = raw.toShort().toInt()
                if (raw == 0x8000 || signed < -27315) throw StandardBleFailure("Temperature unavailable or out of range")
                (signed.toDouble() / 100).toString()
            } else {
                if (raw > 10000) throw StandardBleFailure("Humidity unavailable or out of range")
                (raw.toDouble() / 100).toString()
            }
        }
        MANUFACTURER, MODEL -> {
            if (data.isEmpty() || data.size > 512) throw StandardBleFailure("Invalid device information")
            val text = try {
                Charsets.UTF_8.newDecoder()
                    .onMalformedInput(CodingErrorAction.REPORT)
                    .onUnmappableCharacter(CodingErrorAction.REPORT)
                    .decode(ByteBuffer.wrap(data)).toString()
            } catch (_: CharacterCodingException) {
                throw StandardBleFailure("Invalid device information")
            }
            if (text.contains('\u0000')) throw StandardBleFailure("Invalid device information")
            text
        }
        ALERT -> throw StandardBleFailure("Immediate Alert is write-only")
    }

    companion object {
        fun alertCommand(level: Int): ByteArray {
            if (level !in 0..2) throw StandardBleFailure("Alert level must be 0, 1 or 2")
            return byteArrayOf(level.toByte())
        }

        /** The profiles a discovered service/characteristic pair satisfies. */
        fun matching(service: UUID, characteristic: UUID): StandardBleProfile? =
            entries.firstOrNull { it.service == service && it.characteristic == characteristic }

        const val ALERT_SUBMITTED: String =
            "submitted_unconfirmed: Immediate Alert has no application acknowledgement; inspect device before repeating."
    }
}
