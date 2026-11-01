// The honest failure of the JNI binding when `libpdsh_jni` is not loadable.
// SPDX-License-Identifier: MIT

package com.phonedsh.wire

/**
 * Thrown by every [NativeWire] entry point when `libpdsh_jni` could not be
 * loaded (missing `.so` for this ABI, a broken dependency, or a non-unwinding
 * native build).
 *
 * The binding never degrades to an empty result: a caller either gets the Rust
 * codec's answer or this exception. It mirrors the `notLinked` semantics of the
 * iOS shell, so a missing native library is visible instead of silent.
 *
 * @param cause the `System.loadLibrary` failure, or `null` when the binding was
 *   constructed without a recorded cause.
 */
class WireUnavailable(cause: Throwable?) : RuntimeException(
    buildString {
        append("libpdsh_jni is unavailable")
        if (cause != null) {
            append(": ")
            append(cause.javaClass.name)
            cause.message?.let { message ->
                append(": ")
                append(message)
            }
        }
    },
    cause,
)
