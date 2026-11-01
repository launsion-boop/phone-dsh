// The accelerator contract of the :shell module: one read-only command.
// SPDX-License-Identifier: MIT
// The same shape the Rust pdsh-ffi registry already dispatches on.

package com.phonedsh.shell

/**
 * One read-only accelerator (exec.md §3) backed by the Rust pdsh-shell library.
 *
 * An implementation never contains command logic. [run] hands the argv to the
 * `pdsh-ffi` registry through JNI and returns what the command produced. The
 * Rust registry is the only implementation of `rg` and `jaq` in this repository,
 * so a Kotlin re-implementation must not be written here: it would be a second
 * implementation that silently diverges from the one the Swift host runs.
 *
 * The accelerators the module implements are [RgAccelerator] and [JaqAccelerator];
 * [ShellAccelerators.detect] is the one place that decides which of them this
 * process can actually execute.
 */
interface Accelerator {
    /** The accelerator name; also the required `argv[0]` (`rg`, `jaq`). */
    val name: String

    /**
     * Whether [run] can execute right now: the native library loaded, its
     * capability JSON parsed, and [name] is in that JSON.
     *
     * `false` never means "no output": [run] throws [AcceleratorUnavailable]
     * instead of returning an empty [AcceleratorResult].
     */
    val available: Boolean

    /**
     * Runs one invocation and returns its exit code and two output streams.
     *
     * The blocking native call runs on `Dispatchers.IO`; the caller's thread is
     * not the one a search runs on.
     *
     * **Cancel is event-level, not execution-level.** This call starts and joins
     * one `pdsh_run`, and the C ABI exposes no cancellation handle to it, so an
     * EXEC_CTL `cancel` (or a cancelled coroutine) only stops the *stream of
     * events*; the Rust worker keeps reading until it finishes or its
     * `timeoutMs` expires. Truly interrupting an execution needs a
     * start/cancel/join trio of JNI entry points (the iOS shell has one); it is
     * a known limitation of this lane, not a behavior callers may assume.
     *
     * @throws IllegalArgumentException [request] cannot be dispatched: `argv`
     *   does not start with [name], the `cwd` is not absolute, a mount is
     *   invalid, or a limit is negative. This is a caller bug, not a command
     *   failure.
     * @throws AcceleratorUnavailable the native library, or this accelerator in
     *   it, is not available; no command ran.
     * @throws AcceleratorException the native layer refused the run;
     *   [AcceleratorException.code] is the stable `SHELL_*` code.
     * @throws AcceleratorPanicException a Rust panic crossed the bridge as a
     *   Java exception instead of aborting the process.
     */
    suspend fun run(request: AcceleratorRequest): AcceleratorResult
}

/**
 * One guest-to-host mount of the accelerator sandbox.
 *
 * The guest side must be under [GUEST_ROOT] and the host side must be an
 * absolute path to an existing directory when [Accelerator.run] is called: the
 * Rust `MountTable` canonicalizes every host root and refuses a missing one, so
 * this type keeps the guest half checkable in Kotlin and leaves the host half to
 * the native call.
 *
 * @property guestPath the absolute guest path, for example [WORKSPACE].
 * @property hostPath the existing host directory that guest path maps to.
 */
data class AcceleratorMount(
    val guestPath: String,
    val hostPath: String,
) {
    init {
        require(guestPath == GUEST_ROOT || guestPath.startsWith("$GUEST_ROOT/")) {
            "a mount guest path must be $GUEST_ROOT or below it"
        }
        require(hostPath.startsWith("/")) {
            "a mount host path must be absolute"
        }
    }

    companion object {
        /** The guest root of the pdsh VFS (`pdsh_core::GUEST_ROOT`). */
        const val GUEST_ROOT: String = "/dsh"

        /** The standard workspace mount (`pdsh_core::WORKSPACE_GUEST`). */
        const val WORKSPACE: String = "/dsh/workspace"

        /** The standard home mount (`pdsh_core::HOME_GUEST`). */
        const val HOME: String = "/dsh/home"
    }
}

/**
 * Resource limits of one run (the `XzLimits` struct of the C ABI).
 *
 * The defaults repeat `pdsh_core::Limits::default`; `NativeShellTest` pins them
 * to the capability JSON the linked library reports, so a change on the Rust
 * side fails a test instead of leaving two sets of numbers.
 *
 * @property timeoutMs wall-clock deadline in milliseconds; `0` means none.
 * @property maxOutputBytes captured bytes per stream (stdout and stderr are
 *   counted separately); the Rust sink truncates a longer stream in the middle.
 * @property maxFiles maximum number of files one command may open.
 * @property maxFileBytes maximum size in bytes of one file a command may read.
 */
data class AcceleratorLimits(
    val timeoutMs: Long = DEFAULT_TIMEOUT_MS,
    val maxOutputBytes: Long = DEFAULT_MAX_OUTPUT_BYTES,
    val maxFiles: Long = DEFAULT_MAX_FILES,
    val maxFileBytes: Long = DEFAULT_MAX_FILE_BYTES,
) {
    init {
        require(timeoutMs >= 0L) { "timeoutMs must be non-negative" }
        require(maxOutputBytes >= 0L) { "maxOutputBytes must be non-negative" }
        require(maxFiles >= 0L) { "maxFiles must be non-negative" }
        require(maxFileBytes >= 0L) { "maxFileBytes must be non-negative" }
    }

    companion object {
        /** `pdsh_core::DEFAULT_TIMEOUT_MS`. */
        const val DEFAULT_TIMEOUT_MS: Long = 30_000L

        /** `pdsh_core::DEFAULT_MAX_OUTPUT_BYTES`. */
        const val DEFAULT_MAX_OUTPUT_BYTES: Long = 1_048_576L

        /** `pdsh_core::DEFAULT_MAX_FILES`. */
        const val DEFAULT_MAX_FILES: Long = 10_000L

        /** `pdsh_core::DEFAULT_MAX_FILE_BYTES`. */
        const val DEFAULT_MAX_FILE_BYTES: Long = 15L * 1024L * 1024L
    }
}

/**
 * One accelerator invocation, already resolved to guest paths.
 *
 * A request that cannot be dispatched is rejected in the constructor rather than
 * in the native layer: an empty `argv`, an empty element, a relative `cwd`, no
 * mounts, two mounts on one guest path, or an environment name that is empty or
 * contains `=`. No message quotes an `argv` element: a command line can carry a
 * private path, and this exception can end up in a log.
 *
 * @property argv the full argument vector; `argv[0]` must equal the
 *   accelerator's [Accelerator.name].
 * @property cwd the absolute guest working directory.
 * @property mounts guest-to-host mounts; at least one.
 * @property env environment variables with non-null values (`pdsh-ffi` cannot
 *   express "unset", which is the absence of a pair).
 * @property limits the resource budget of this invocation.
 */
data class AcceleratorRequest(
    val argv: List<String>,
    val cwd: String,
    val mounts: List<AcceleratorMount>,
    val env: Map<String, String> = emptyMap(),
    val limits: AcceleratorLimits = AcceleratorLimits(),
) {
    init {
        require(argv.isNotEmpty()) { "argv must name the accelerator" }
        require(argv.none { it.isEmpty() }) { "an argv element must not be empty" }
        require(cwd.startsWith("/")) { "cwd must be an absolute guest path" }
        require(mounts.isNotEmpty()) { "at least one mount is required" }
        require(mounts.map { it.guestPath }.toSet().size == mounts.size) {
            "two mounts must not share one guest path"
        }
        require(env.keys.none { it.isEmpty() || '=' in it }) {
            "an environment name must be non-empty and must not contain '='"
        }
    }
}

/**
 * The completed output of one accelerator run.
 *
 * Exit codes are the accelerator's own (`rg`: 0 match, 1 no match, 2 error;
 * `jaq`: 0, 1, 2, 3, 4, 5), with the pdsh-core codes 70 (panic), 124 (deadline),
 * 130 (cancelled) and 127 (unknown command) possible from the FFI.
 *
 * A regular class, not a data class: [stdout] and [stderr] are byte arrays and
 * value equality would need `contentEquals` anyway.
 *
 * @property exitCode the command's exit code.
 * @property stdout the retained stdout, already truncated to the budget.
 * @property stderr the retained stderr, already truncated to the budget.
 */
class AcceleratorResult(
    val exitCode: Int,
    val stdout: ByteArray,
    val stderr: ByteArray,
) {
    /** [stdout] decoded as UTF-8; for diagnostics and tests, not for binary output. */
    fun stdoutText(): String = String(stdout, Charsets.UTF_8)

    /** [stderr] decoded as UTF-8; for diagnostics and tests. */
    fun stderrText(): String = String(stderr, Charsets.UTF_8)

    override fun toString(): String =
        "AcceleratorResult(exitCode=$exitCode, stdout=${stdout.size} B, stderr=${stderr.size} B)"
}
