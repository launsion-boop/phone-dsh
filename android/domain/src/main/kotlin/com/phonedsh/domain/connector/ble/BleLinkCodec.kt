// SPDX-License-Identifier: MIT
package com.phonedsh.domain.connector.ble

/**
 * Byte codec for the ordinary PDSH Link Tools Profile v1.
 *
 * This target-only codec does not establish a GATT connection, negotiate the
 * device-task profile, authenticate a peer, or grant access to any tool.
 */
internal object BleLinkCodec {
    const val MAX_ENVELOPE = 512
    const val MAX_BODY = 505
    private const val MAX_ATT_VALUE = 244
    private const val MIN_ATT_VALUE = 20
    private const val TOOLS_CAPABILITY = 1L shl 20
    private const val APP_TOOLS = 1 shl 10

    /** Byte-for-byte frame value; callers cannot mutate the stored payload. */
    class Frame(val opcode: Int, val requestId: Int, body: ByteArray) {
        private val bytes = body.copyOf()
        val body: ByteArray get() = bytes.copyOf()

        init {
            require(opcode in 0..255) { "invalid Link opcode" }
            require(requestId in 0..65535) { "invalid Link request ID" }
            require(bytes.size <= MAX_BODY) { "Link payload exceeds 505 bytes" }
        }

        fun encode(): ByteArray {
            val result = ByteArray(bytes.size + 7)
            result[0] = opcode.toByte()
            putU16(result, 1, requestId)
            putU16(result, 3, bytes.size)
            bytes.copyInto(result, destinationOffset = 5)
            putU16(result, result.size - 2, crc16(result, result.size - 2))
            return result
        }

        /** `writeLimit` is the ATT characteristic value budget (ATT MTU minus 3). */
        fun segments(writeLimit: Int): List<ByteArray> {
            require(writeLimit >= MIN_ATT_VALUE) { "Link ATT write budget too small" }
            val encoded = encode()
            val size = minOf(writeLimit, MAX_ATT_VALUE) - 1
            return (encoded.indices step size).map { offset ->
                val end = minOf(offset + size, encoded.size)
                val flags = (if (offset == 0) 2 else 0) or (if (end == encoded.size) 1 else 0)
                ByteArray(end - offset + 1).also { segment ->
                    segment[0] = flags.toByte()
                    encoded.copyInto(segment, destinationOffset = 1, startIndex = offset, endIndex = end)
                }
            }
        }

        override fun equals(other: Any?): Boolean =
            other is Frame && opcode == other.opcode && requestId == other.requestId && bytes.contentEquals(other.bytes)

        override fun hashCode(): Int = 31 * (31 * opcode + requestId) + bytes.contentHashCode()
    }

    fun decode(encoded: ByteArray): Frame {
        require(encoded.size in 7..MAX_ENVELOPE) { "invalid Link frame size" }
        val bodyLength = u16(encoded, 3)
        require(bodyLength == encoded.size - 7) { "invalid Link payload length" }
        require(crc16(encoded, encoded.size - 2) == u16(encoded, encoded.size - 2)) { "invalid Link CRC" }
        return Frame(u8(encoded[0]), u16(encoded, 1), encoded.copyOfRange(5, encoded.size - 2))
    }

    /** Encoded HELLO payload for ordinary tools, without the target task capability. */
    fun hello(): ByteArray = byteArrayOf(0x02, 0x01, APP_TOOLS.toByte(), (APP_TOOLS ushr 8).toByte(), 0, 0)

    data class Peer(val version: Int, val capabilities: Long, val bootId: Long, val supportsTools: Boolean)

    /** Decode HELLO_ACK body only; successful ordinary Link is independent of tool support. */
    fun decodeHelloAck(body: ByteArray): Peer {
        require(body.size >= 25 && u8(body[0]) == 0 && (u16(body, 1) ushr 8) == 1 && u16(body, 23) >= 512) {
            "unsupported Link HELLO_ACK"
        }
        val capabilities = u32(body, 3)
        val tools = (capabilities and TOOLS_CAPABILITY) != 0L && body.size >= 33 &&
            body[25] == 'P'.code.toByte() && body[26] == 'D'.code.toByte() &&
            body[27] == 'S'.code.toByte() && body[28] == 'H'.code.toByte() &&
            u16(body, 29) == 1 && u16(body, 31) == 4096
        return Peer(u16(body, 1), capabilities, u32(body, 19), tools)
    }

    /**
     * One in-progress ATT message. A new FIRST discards an incomplete prior
     * message, as in the existing C and Swift endpoints. Errors clear state.
     * The final frame still undergoes its complete length and CRC checks.
     */
    class Reassembler {
        private val buffer = ByteArray(MAX_ENVELOPE)
        private var length = 0
        private var active = false

        fun reset() {
            length = 0
            active = false
        }

        fun push(segment: ByteArray): Frame? {
            if (segment.size !in 2..MAX_ATT_VALUE || (u8(segment[0]) and 0xfc) != 0) {
                reset()
                throw IllegalArgumentException("invalid Link segment")
            }
            val flags = u8(segment[0])
            if ((flags and 2) != 0) {
                length = 0
                active = true
            }
            if (!active || segment.size - 1 > MAX_ENVELOPE - length) {
                reset()
                throw IllegalArgumentException("invalid Link segment sequence")
            }
            segment.copyInto(buffer, destinationOffset = length, startIndex = 1)
            length += segment.size - 1
            if ((flags and 1) == 0) return null
            val encoded = buffer.copyOf(length)
            reset()
            return decode(encoded)
        }
    }

    /** CRC-16/CCITT-FALSE, with no reflection and no final xor. */
    private fun crc16(bytes: ByteArray, length: Int): Int {
        var crc = 0xffff
        for (i in 0 until length) {
            crc = crc xor (u8(bytes[i]) shl 8)
            repeat(8) {
                crc = if ((crc and 0x8000) != 0) (crc shl 1) xor 0x1021 else crc shl 1
                crc = crc and 0xffff
            }
        }
        return crc
    }

    private fun u8(value: Byte): Int = value.toInt() and 0xff
    private fun u16(bytes: ByteArray, offset: Int): Int = u8(bytes[offset]) or (u8(bytes[offset + 1]) shl 8)
    private fun u32(bytes: ByteArray, offset: Int): Long =
        (u16(bytes, offset).toLong() or (u16(bytes, offset + 2).toLong() shl 16))

    private fun putU16(bytes: ByteArray, offset: Int, value: Int) {
        bytes[offset] = value.toByte()
        bytes[offset + 1] = (value ushr 8).toByte()
    }
}
