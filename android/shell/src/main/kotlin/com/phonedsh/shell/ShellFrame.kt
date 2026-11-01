// The binary result frame the Rust bridge returns for one completed run.
// SPDX-License-Identifier: MIT

package com.phonedsh.shell

import java.nio.ByteBuffer
import java.nio.ByteOrder

/**
 * Decodes the frame `NativeShell.runNative` returns.
 *
 * The layout is fixed by `pdsh-jni`'s `shell` module:
 *
 * ```text
 * offset 0  4 bytes  exit code, big-endian i32
 * offset 4  4 bytes  stdout length, big-endian u32
 * offset 8  N bytes  stdout
 * offset 8+N         stderr (the rest of the frame)
 * ```
 *
 * The frame is binary rather than base64-in-JSON on purpose: both streams are
 * already bounded by `maxOutputBytes`, and the callers need the bytes rather
 * than an encoding of them. A malformed frame is a defect of the native side,
 * not a command result, so it throws [IllegalStateException].
 */
internal object ShellFrame {
    /** Bytes of the fixed frame header. */
    const val HEADER_BYTES: Int = 8

    /**
     * Decodes one frame.
     *
     * @throws IllegalStateException the frame is shorter than [HEADER_BYTES] or
     *   claims more stdout bytes than it carries.
     */
    fun decode(frame: ByteArray): AcceleratorResult {
        check(frame.size >= HEADER_BYTES) {
            "libpdsh_jni returned ${frame.size} bytes, shorter than the $HEADER_BYTES-byte header"
        }
        val buffer = ByteBuffer.wrap(frame).order(ByteOrder.BIG_ENDIAN)
        val exitCode = buffer.int
        val stdoutLength = buffer.int
        check(stdoutLength >= 0 && stdoutLength <= frame.size - HEADER_BYTES) {
            "libpdsh_jni returned a $stdoutLength-byte stdout claim in a ${frame.size}-byte frame"
        }
        val stdoutEnd = HEADER_BYTES + stdoutLength
        return AcceleratorResult(
            exitCode = exitCode,
            stdout = frame.copyOfRange(HEADER_BYTES, stdoutEnd),
            stderr = frame.copyOfRange(stdoutEnd, frame.size),
        )
    }
}
