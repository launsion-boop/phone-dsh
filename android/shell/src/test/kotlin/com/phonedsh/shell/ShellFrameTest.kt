// The frame decoder the native bridge feeds; malformed frames must fail loud.
// SPDX-License-Identifier: MIT

package com.phonedsh.shell

import java.nio.ByteBuffer
import java.nio.ByteOrder
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class ShellFrameTest {
    private fun frame(exitCode: Int, stdout: ByteArray, stderr: ByteArray): ByteArray =
        ByteBuffer.allocate(ShellFrame.HEADER_BYTES + stdout.size + stderr.size)
            .order(ByteOrder.BIG_ENDIAN)
            .putInt(exitCode)
            .putInt(stdout.size)
            .put(stdout)
            .put(stderr)
            .array()

    @Test
    fun decode_splits_the_exit_code_and_both_streams() {
        val result = ShellFrame.decode(frame(2, "match\n".toByteArray(), "rg: bad\n".toByteArray()))
        assertEquals(2, result.exitCode)
        assertEquals("match\n", result.stdoutText())
        assertEquals("rg: bad\n", result.stderrText())
    }

    @Test
    fun decode_accepts_empty_streams_and_a_header_only_frame() {
        val result = ShellFrame.decode(frame(0, ByteArray(0), ByteArray(0)))
        assertEquals(0, result.exitCode)
        assertEquals(0, result.stdout.size)
        assertEquals(0, result.stderr.size)
        assertEquals(ShellFrame.HEADER_BYTES, frame(0, ByteArray(0), ByteArray(0)).size)
    }

    @Test
    fun decode_keeps_binary_bytes_verbatim() {
        val stdout = byteArrayOf(0, -1, -128, 127, 10)
        val stderr = byteArrayOf(0, 1, 2)
        val result = ShellFrame.decode(frame(130, stdout, stderr))
        assertArrayEquals(stdout, result.stdout)
        assertArrayEquals(stderr, result.stderr)
        assertEquals(130, result.exitCode)
    }

    @Test
    fun a_frame_shorter_than_the_header_is_a_native_defect() {
        val error = assertThrows(IllegalStateException::class.java) {
            ShellFrame.decode(ByteArray(ShellFrame.HEADER_BYTES - 1))
        }
        assertTrue(error.message!!.contains("shorter"))
    }

    @Test
    fun a_stdout_length_past_the_frame_is_a_native_defect() {
        val frame = ByteBuffer.allocate(ShellFrame.HEADER_BYTES)
            .order(ByteOrder.BIG_ENDIAN)
            .putInt(0)
            .putInt(9)
            .array()
        val error = assertThrows(IllegalStateException::class.java) { ShellFrame.decode(frame) }
        assertTrue(error.message!!.contains("stdout claim"))
    }

    @Test
    fun a_negative_stdout_length_is_a_native_defect() {
        val frame = ByteBuffer.allocate(ShellFrame.HEADER_BYTES + 1)
            .order(ByteOrder.BIG_ENDIAN)
            .putInt(0)
            .putInt(-1)
            .put(0)
            .array()
        assertThrows(IllegalStateException::class.java) { ShellFrame.decode(frame) }
    }
}
