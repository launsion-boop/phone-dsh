// The `channel.md` §10 error surfaced by the Kotlin binding.
// SPDX-License-Identifier: MIT

package com.phonedsh.wire

/**
 * A wire failure reported by the Rust codec.
 *
 * The native side throws `java.lang.RuntimeException` with the message
 * `"<CODE>: <detail>"`, where `<CODE>` is the `channel.md` §10 string; this
 * class is the typed form of that message. The code vocabulary itself lives in
 * the spec and in `pdsh-wire`, not here.
 *
 * @property code the §10 code, for example `BAD_PAYLOAD` or `BAD_MAGIC`.
 * @property detail the human-readable detail after the code.
 * @param cause the native `RuntimeException`.
 */
class WireException(
    val code: String,
    val detail: String,
    cause: Throwable? = null,
) : RuntimeException("$code: $detail", cause)
