// A Rust panic that reached Java: always a bug, never a wire answer.
// SPDX-License-Identifier: MIT

package com.phonedsh.wire

/**
 * A Rust panic caught at the JNI boundary and rethrown as a Java exception.
 *
 * The native entry points wrap their work in `catch_unwind`, so this exception
 * (rather than a JVM abort) is the observable outcome of a codec bug. It is
 * deliberately distinct from [WireException]: a panic is not a `channel.md` §10
 * error and must not be handled as one.
 *
 * @property operation the native entry point that panicked.
 * @property detail the panic payload.
 * @param cause the native `RuntimeException`.
 */
class WirePanicException(
    val operation: String,
    val detail: String,
    cause: Throwable? = null,
) : RuntimeException("pdsh-jni panicked in $operation: $detail", cause)
