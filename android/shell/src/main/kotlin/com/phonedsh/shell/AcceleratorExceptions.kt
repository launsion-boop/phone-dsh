// The typed failures of the :shell accelerator binding.
// SPDX-License-Identifier: MIT

package com.phonedsh.shell

/**
 * Thrown when the native library or an accelerator in it is not available.
 *
 * The binding never degrades to an empty [AcceleratorResult]: a caller either
 * gets the Rust command's answer or this exception. It mirrors the
 * `PDSHShellError.notLinked` case of the iOS shell, so a missing library is
 * visible instead of looking like a command that matched nothing.
 *
 * @property accelerator the unavailable accelerator name, or `null` when the
 *   whole library is unavailable.
 * @param cause the `System.loadLibrary` failure or the capability-JSON failure,
 *   or `null` when the binding was constructed without a recorded cause.
 */
class AcceleratorUnavailable(
    val accelerator: String? = null,
    cause: Throwable? = null,
) : RuntimeException(
    buildString {
        if (accelerator == null) {
            append("libpdsh_jni is unavailable")
        } else {
            append("accelerator \"")
            append(accelerator)
            append("\" is not available in libpdsh_jni")
        }
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

/**
 * A coded native refusal of one run.
 *
 * The Rust bridge renders every failure as `"<CODE>: <detail>"`; this class is
 * that message split into its two parts. The code is kept verbatim even when it
 * is not one of the constants below, so a newer Rust table is not lost.
 *
 * @property code the stable `SHELL_*` code.
 * @property detail the human-readable remainder; it never contains an `argv`
 *   element, a `cwd` or file contents.
 */
class AcceleratorException(
    val code: String,
    val detail: String,
    cause: Throwable? = null,
) : RuntimeException("$code: $detail", cause) {
    companion object {
        /** The JNI arguments cannot describe a run (`shell::CODE_INPUT_INVALID`). */
        const val CODE_INPUT_INVALID: String = "SHELL_INPUT_INVALID"

        /** `pdsh_run` refused the request or the worker could not start. */
        const val CODE_START_FAILED: String = "SHELL_START_FAILED"
    }
}

/**
 * A Rust panic that crossed the JNI boundary as a Java exception.
 *
 * A panic must never abort the Android process and must never be reported as a
 * normal exit; the Rust entry point catches it and the message starts with
 * `PDSH_JNI_PANIC`.
 *
 * @property operation the native entry point that panicked.
 * @property detail the panic payload.
 * @param cause the Java `RuntimeException` the native layer threw.
 */
class AcceleratorPanicException(
    val operation: String,
    val detail: String,
    cause: Throwable?,
) : RuntimeException("PDSH_JNI_PANIC: $operation: $detail", cause)
