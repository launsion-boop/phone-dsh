// The thin JNI binding to the Rust read-only accelerators.
// SPDX-License-Identifier: MIT
// It goes through `pdsh-ffi` via `pdsh-jni`; no accelerator logic lives here.

package com.phonedsh.shell

/**
 * The native half of the read-only accelerators.
 *
 * The Rust crate `pdsh-jni` exports the symbols
 * `Java_com_phonedsh_shell_NativeShell_<name>Native`; the class name is fixed so
 * the exported names do not depend on Kotlin compilation details. The methods are
 * a thin wrapper over the single unified C ABI `pdsh-ffi` already publishes for
 * the Swift host (`shell/include/xzshell.h`): one `pdsh_run` per invocation, with
 * `argv[0]` selecting `rg` / `jaq` / ... from the linked registry. No command
 * logic is re-implemented on this side.
 *
 * When `System.loadLibrary("pdsh_jni")` failed, [available] is `false`, [failure]
 * records why, and a run throws [AcceleratorUnavailable] instead of returning an
 * empty result. The same is true when the library loaded but its capability JSON
 * could not be read: an unverifiable accelerator is not advertised or run.
 *
 * The native calls are intentionally private: callers use [RgAccelerator],
 * [JaqAccelerator] or [ShellAccelerators], which are the only places that expose
 * the typed failures [AcceleratorException] and [AcceleratorPanicException]. The
 * one exception is [panicForTest], which the test suite uses to prove the panic
 * boundary; it is `internal` and always panics.
 *
 * On Android release builds R8 must keep the native method names: they are
 * resolved by `System.loadLibrary` at runtime, not through a Java call site.
 * `android/shell/consumer-rules.pro` ships the rule with the AAR.
 */
object NativeShell {
    /** Name passed to `System.loadLibrary`; resolves to `libpdsh_jni.so`/`.dylib`. */
    private const val LIBRARY_NAME = "pdsh_jni"

    internal val binding: NativeShellBinding = NativeShellBinding(
        load = { System.loadLibrary(LIBRARY_NAME) },
        calls = JniCalls,
    )

    /** Whether the native library loaded and its capability JSON is readable. */
    val available: Boolean
        get() = binding.available

    /** The load or capability failure, or `null` when [available]. */
    val failure: Throwable?
        get() = binding.failure

    /** The decoded capability object, or `null` when it could not be read. */
    val caps: NativeShellCaps?
        get() = binding.caps

    /** The linked registry's version, or `null` when [caps] is unavailable. */
    val version: String?
        get() = binding.version

    /**
     * Runs one invocation through the native bridge.
     *
     * @throws AcceleratorUnavailable the library or the capability JSON is not
     *   available.
     * @throws AcceleratorException the native layer refused the run.
     * @throws AcceleratorPanicException a Rust panic crossed the bridge.
     */
    internal fun run(request: AcceleratorRequest): AcceleratorResult = binding.run(request)

    /** Test-only panic hook: always panics inside the Rust entry point. */
    internal fun panicForTest(message: String): String = binding.panicForTest(message)

    /**
     * Whether [argv] is a `jaq` invocation that would read the process's
     * standard input (no file operand, no `-n`).
     *
     * The argv grammar is parsed by `pdsh-jaq` through this JNI entry, so there
     * is no Kotlin copy of the jq option table. See [JaqAccelerator.readsProcessStdin].
     */
    internal fun jaqReadsStdin(argv: List<String>): Boolean = binding.jaqReadsStdin(argv)

    private external fun capsJsonNative(hasToolBridge: Boolean): String

    private external fun runNative(
        argv: Array<String>,
        cwd: String,
        envNames: Array<String>,
        envValues: Array<String>,
        mountGuests: Array<String>,
        mountHosts: Array<String>,
        timeoutMs: Long,
        maxOutputBytes: Long,
        maxFiles: Long,
        maxFileBytes: Long,
    ): ByteArray

    private external fun jaqReadsStdinNative(argv: Array<String>): Boolean

    private external fun panicForTestNative(message: String): String

    private object JniCalls : NativeShellCalls {
        override fun capsJson(hasToolBridge: Boolean): String =
            NativeShell.capsJsonNative(hasToolBridge)

        override fun run(
            argv: Array<String>,
            cwd: String,
            envNames: Array<String>,
            envValues: Array<String>,
            mountGuests: Array<String>,
            mountHosts: Array<String>,
            timeoutMs: Long,
            maxOutputBytes: Long,
            maxFiles: Long,
            maxFileBytes: Long,
        ): ByteArray = NativeShell.runNative(
            argv,
            cwd,
            envNames,
            envValues,
            mountGuests,
            mountHosts,
            timeoutMs,
            maxOutputBytes,
            maxFiles,
            maxFileBytes,
        )

        override fun jaqReadsStdin(argv: Array<String>): Boolean =
            NativeShell.jaqReadsStdinNative(argv)

        override fun panicForTest(message: String): String =
            NativeShell.panicForTestNative(message)
    }
}

/**
 * The native operations behind [NativeShell], split out so the load-failure and
 * capability-failure branches can be tested without a second JVM or class
 * loader.
 */
internal interface NativeShellCalls {
    fun capsJson(hasToolBridge: Boolean): String

    fun run(
        argv: Array<String>,
        cwd: String,
        envNames: Array<String>,
        envValues: Array<String>,
        mountGuests: Array<String>,
        mountHosts: Array<String>,
        timeoutMs: Long,
        maxOutputBytes: Long,
        maxFiles: Long,
        maxFileBytes: Long,
    ): ByteArray

    fun jaqReadsStdin(argv: Array<String>): Boolean

    fun panicForTest(message: String): String
}

/**
 * Loads the native library once, reads the capability JSON once, and routes
 * every call through one availability check.
 *
 * The capability read is lazy, for two reasons: the `System.loadLibrary` call
 * must not also invoke a native method of the `NativeShell` singleton while that
 * singleton is still being initialised, and a caller that only inspects whether
 * the library loads should not pay for a JNI round trip.
 *
 * Every call is also the one place where the native exception ABI is mapped:
 * `"CODE: detail"` with a `SHELL_*` code becomes [AcceleratorException],
 * `"PDSH_JNI_PANIC: <operation>: <detail>"` becomes [AcceleratorPanicException],
 * and [AcceleratorUnavailable] or anything else is rethrown unchanged.
 *
 * @param load performs `System.loadLibrary` (or any throwing loader).
 * @param calls the native implementations; never invoked when [available] is
 *   false, which is what makes the stub honest.
 */
internal class NativeShellBinding(
    load: () -> Unit,
    private val calls: NativeShellCalls,
) {
    private val loadFailure: Throwable?

    init {
        var cause: Throwable? = null
        try {
            load()
        } catch (error: Throwable) {
            cause = error
        }
        loadFailure = cause
    }

    private val capsAttempt: CapsAttempt by lazy { readCaps() }

    /** Whether the library loaded and its capability JSON parsed. */
    val available: Boolean
        get() = loadFailure == null && capsAttempt.caps != null

    /** The load failure, else the capability failure, else `null`. */
    val failure: Throwable?
        get() = loadFailure ?: capsAttempt.failure

    /** The capability object; `null` when the load failed. */
    val caps: NativeShellCaps?
        get() = if (loadFailure == null) capsAttempt.caps else null

    /** The linked registry's version; `null` when [caps] is unavailable. */
    val version: String?
        get() = caps?.version

    /**
     * Runs one invocation and decodes the native result frame.
     *
     * @throws AcceleratorUnavailable the library or the capability JSON is not
     *   available.
     */
    fun run(request: AcceleratorRequest): AcceleratorResult = guarded {
        translate("run") {
            val names = ArrayList<String>(request.env.size)
            val values = ArrayList<String>(request.env.size)
            for ((name, value) in request.env) {
                names.add(name)
                values.add(value)
            }
            val guests = request.mounts.map { mount -> mount.guestPath }
            val hosts = request.mounts.map { mount -> mount.hostPath }
            ShellFrame.decode(
                calls.run(
                    argv = request.argv.toTypedArray(),
                    cwd = request.cwd,
                    envNames = names.toTypedArray(),
                    envValues = values.toTypedArray(),
                    mountGuests = guests.toTypedArray(),
                    mountHosts = hosts.toTypedArray(),
                    timeoutMs = request.limits.timeoutMs,
                    maxOutputBytes = request.limits.maxOutputBytes,
                    maxFiles = request.limits.maxFiles,
                    maxFileBytes = request.limits.maxFileBytes,
                ),
            )
        }
    }

    /**
     * Whether one `jaq` argv would read the process's standard input.
     *
     * @throws AcceleratorUnavailable the library or the capability JSON is not
     *   available.
     */
    fun jaqReadsStdin(argv: List<String>): Boolean = guarded {
        translate("jaqReadsStdin") { calls.jaqReadsStdin(argv.toTypedArray()) }
    }

    /**
     * Calls the test-only panic hook; the throw path is the point of the test.
     *
     * @throws AcceleratorPanicException always.
     */
    fun panicForTest(message: String): String = guarded {
        translate("panicForTest") { calls.panicForTest(message) }
    }

    private fun readCaps(): CapsAttempt =
        try {
            CapsAttempt(
                caps = NativeShellCaps.parse(calls.capsJson(hasToolBridge = false)),
                failure = null,
            )
        } catch (error: Exception) {
            // A JSON failure or a JNI RuntimeException means the advertised set
            // cannot be verified; report it instead of guessing one.
            CapsAttempt(caps = null, failure = error)
        }

    private inline fun <T> guarded(block: () -> T): T {
        if (!available) {
            throw AcceleratorUnavailable(cause = failure)
        }
        return block()
    }

    private fun <T> translate(operation: String, body: () -> T): T =
        try {
            body()
        } catch (error: RuntimeException) {
            throw translateError(operation, error)
        }

    private fun translateError(operation: String, error: RuntimeException): RuntimeException {
        val message = error.message ?: return error
        if (message.startsWith(PANIC_PREFIX)) {
            val rest = message.removePrefix(PANIC_PREFIX)
            val separator = rest.indexOf(": ")
            val detail = if (separator >= 0) rest.substring(separator + 2) else rest
            return AcceleratorPanicException(operation, detail, error)
        }
        val separator = message.indexOf(": ")
        if (separator <= 0) {
            return error
        }
        val code = message.substring(0, separator)
        if (!CODE_PATTERN.matches(code)) {
            return error
        }
        return AcceleratorException(code, message.substring(separator + 2), error)
    }

    private data class CapsAttempt(
        val caps: NativeShellCaps?,
        val failure: Throwable?,
    )

    private companion object {
        const val PANIC_PREFIX = "PDSH_JNI_PANIC: "
        val CODE_PATTERN = Regex("[A-Z][A-Z0-9_]*")
    }
}
