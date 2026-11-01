// phone-dsh — :engine / com.phonedsh.engine: the 16-byte header's type byte, by name.
// SPDX-License-Identifier: MIT
//
// spec/v1/channel.md §2 is the one table of frame types. :engine only *labels*
// frames for the demo screen; it never interprets a payload (the codec above it
// does, in Rust). An unknown byte is a label, not an exception: cutting the
// connection is the codec's decision, not the engine's.

package com.phonedsh.engine

/** Frame type names of `spec/v1/channel.md` §2. */
object FrameType {
    /** Byte offset of `type` in the 16-byte header (`channel.md` §1). */
    const val TYPE_OFFSET: Int = 2

    /** A frame shorter than the type byte carries no label. */
    const val MALFORMED: String = "MALFORMED"

    /** `"HELLO"`, `"VFS_ACK"`, ..., or `"UNKNOWN(0x7E)"`; never throws. */
    fun nameOf(typeByte: Int): String = NAMES[typeByte and 0xFF] ?: unknown(typeByte)

    /** The label of a whole frame, or [MALFORMED] when it has no type byte yet. */
    fun nameOf(frame: ByteArray): String =
        if (frame.size <= TYPE_OFFSET) MALFORMED else nameOf(frame[TYPE_OFFSET].toInt())

    /** Whether [typeByte] is the HELLO frame type (`0x01`). */
    fun isHello(typeByte: Int): Boolean = (typeByte and 0xFF) == HELLO

    /** `"UNKNOWN(0xNN)"`, the shape the demo screen shows for a future frame type. */
    fun unknown(typeByte: Int): String {
        val value = typeByte and 0xFF
        val hex = "0123456789ABCDEF"
        return "UNKNOWN(0x" + hex[value ushr 4] + hex[value and 0x0F] + ")"
    }

    /** `0x01`, `channel.md` §2; both directions. */
    const val HELLO: Int = 0x01

    private val NAMES: Map<Int, String> = mapOf(
        0x01 to "HELLO",
        0x10 to "VFS_MUT",
        0x11 to "VFS_ACK",
        0x12 to "VFS_BARRIER",
        0x13 to "VFS_RESYNC",
        0x20 to "EXEC_REQ",
        0x21 to "EXEC_EVT",
        0x22 to "EXEC_CTL",
        0x30 to "JOURNAL",
        0x31 to "JOURNAL_ACK",
        0x40 to "API_REQ",
        0x41 to "API_RES",
        0x42 to "API_END",
        0x43 to "API_ABORT",
        0x50 to "LIFECYCLE",
        0x60 to "CONSOLE",
        0x70 to "FENCE",
        0x7F to "ERROR",
    )
}
