// phone-dsh — :net / com.phonedsh.adb: ADB packets and shell_v2 frames.
// SPDX-License-Identifier: MIT
//
// Kotlin end of `Sources/PhoneDSHADB/ADBProtocol.swift` (P05 native MCP,
// `spec/v1/native-mcp.md`). The ADB wire format is the device's, not ours: a
// 24-byte little-endian header (command, arg0, arg1, length, byte-sum checksum,
// command xor 0xffffffff) followed by the payload, and shell_v2 frames
// (`[kind][u32 length][bytes]`) that may straddle any number of WRTE packets.
// Limits match the Swift end exactly: a 1 MiB packet payload, a 1 MiB shell
// frame and the caller's aggregate output limit.

package com.phonedsh.adb

import java.io.ByteArrayOutputStream

/** A user-presentable ADB failure; [message] never carries key material. */
public class AdbFailure(message: String) : Exception(message)

internal fun ByteArray.le32(offset: Int): Long =
    (0 until 4).fold(0L) { acc, i -> acc or ((this[offset + i].toLong() and 0xFF) shl (8 * i)) }

internal fun ByteArrayOutputStream.appendLe(value: Long) {
    for (i in 0 until 4) write(((value ushr (8 * i)) and 0xFF).toInt())
}

internal class AdbPacket(
    val command: Long,
    val arg0: Long = 0,
    val arg1: Long = 0,
    val payload: ByteArray = ByteArray(0),
) {
    val checksum: Long get() = payload.fold(0L) { acc, b -> (acc + (b.toLong() and 0xFF)) and MASK }

    fun encoded(): ByteArray {
        val out = ByteArrayOutputStream(HEADER + payload.size)
        for (word in longArrayOf(command, arg0, arg1, payload.size.toLong(), checksum, command xor MASK)) {
            out.appendLe(word)
        }
        out.write(payload)
        return out.toByteArray()
    }

    override fun equals(other: Any?): Boolean = other is AdbPacket && other.command == command &&
        other.arg0 == arg0 && other.arg1 == arg1 && other.payload.contentEquals(payload)

    override fun hashCode(): Int = (command * 31 + arg0 * 7 + arg1).toInt() * 31 + payload.contentHashCode()

    companion object {
        const val CONNECT: Long = 0x4e584e43
        const val AUTH: Long = 0x48545541
        const val OPEN: Long = 0x4e45504f
        const val OKAY: Long = 0x59414b4f
        const val WRITE: Long = 0x45545257
        const val CLOSE: Long = 0x45534c43
        const val TLS: Long = 0x534c5453
        const val HEADER: Int = 24
        const val MAX_PAYLOAD: Int = 1_048_576
        const val MASK: Long = 0xFFFF_FFFFL

        fun read(transport: AdbTransport): AdbPacket {
            val header = transport.read(HEADER)
            if (header.size != HEADER || header.le32(20) != (header.le32(0) xor MASK)) {
                throw AdbFailure("Invalid ADB packet header")
            }
            val count = header.le32(12)
            if (count > MAX_PAYLOAD) throw AdbFailure("ADB packet exceeds size limit")
            val data = if (count == 0L) ByteArray(0) else transport.read(count.toInt())
            val packet = AdbPacket(header.le32(0), header.le32(4), header.le32(8), data)
            if (data.size.toLong() != count || packet.checksum != header.le32(16)) {
                throw AdbFailure("Invalid ADB payload checksum")
            }
            return packet
        }
    }
}

/** One finished Android shell command. */
public class AdbShellResult(
    public val stdout: ByteArray = ByteArray(0),
    public val stderr: ByteArray = ByteArray(0),
    public val exitCode: Int = 0,
) {
    override fun equals(other: Any?): Boolean = other is AdbShellResult && other.exitCode == exitCode &&
        other.stdout.contentEquals(stdout) && other.stderr.contentEquals(stderr)

    override fun hashCode(): Int = (stdout.contentHashCode() * 31 + stderr.contentHashCode()) * 31 + exitCode
}

/** shell_v2 frames can straddle any number of ADB WRTE packets. */
internal class AdbShellDecoder(private val limit: Int) {
    private var pending = ByteArray(0)
    private val stdout = ByteArrayOutputStream()
    private val stderr = ByteArrayOutputStream()
    private var exitCode = 0
    var exited: Boolean = false
        private set

    fun append(bytes: ByteArray) {
        pending += bytes
        while (pending.size >= 5) {
            if (exited) throw AdbFailure("Data after ADB shell exit")
            val size = pending.le32(1)
            if (size > minOf(limit, AdbPacket.MAX_PAYLOAD).toLong()) throw AdbFailure("Android output exceeds size limit")
            if (pending.size < size + 5) return
            val kind = pending[0].toInt() and 0xFF
            val data = pending.copyOfRange(5, 5 + size.toInt())
            pending = pending.copyOfRange(5 + size.toInt(), pending.size)
            when (kind) {
                1 -> stdout.write(data)
                2 -> stderr.write(data)
                3 -> {
                    if (size != 1L) throw AdbFailure("Invalid ADB shell exit frame")
                    exitCode = data[0].toInt() and 0xFF
                    exited = true
                }
                else -> throw AdbFailure("Unexpected ADB shell frame")
            }
            if (stdout.size() + stderr.size() > limit) throw AdbFailure("Android output exceeds size limit")
        }
    }

    fun finish(): AdbShellResult {
        if (!exited || pending.isNotEmpty()) {
            throw AdbFailure("Android shell disconnected before reporting exit; command outcome unknown")
        }
        return AdbShellResult(stdout.toByteArray(), stderr.toByteArray(), exitCode)
    }
}
