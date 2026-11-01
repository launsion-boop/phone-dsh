// The `jaq` accelerator: a delegating binding, no filter logic of its own.
// SPDX-License-Identifier: MIT

package com.phonedsh.shell

/**
 * The `jaq` accelerator (`exec.md` §3), implemented by `pdsh-jaq` in Rust.
 *
 * The jq-compatible language surface comes from `jaq-core`, `jaq-std` and
 * `jaq-json`; input files are read through the sandboxed VFS. Supported argv is
 * `jaq [OPTIONS] FILTER [FILE ...]` (`-r`, `-c`, `-s`, `-e`, `-n`, `--arg`,
 * `--argjson`, `--tab`, `--indent`).
 *
 * Exit codes are jq's: 0 success, 1 `-e` with a false/null (or missing) last
 * output, 2 usage, 3 compile, 4 `-e` with no output, 5 runtime or input.
 *
 * **No stdin.** An exec request with `stdin.mode = pipe` is refused by the exec
 * bridge (`exec.md` §3: an in-process accelerator has no stdin pipe), and the C
 * ABI has no stdin parameter, so a `jaq` call must name input files or pass
 * `-n`. Without either, `pdsh-jaq` falls back to the process's inherited
 * standard input, which is not a stream this host can fill; callers should
 * refuse that shape before it reaches the accelerator.
 *
 * @param shell the native binding; the no-argument constructor uses the process
 *   singleton, and the internal one exists for the binding tests.
 */
class JaqAccelerator internal constructor(shell: NativeShellBinding) :
    Accelerator by NativeAccelerator(shell, NAME) {

    /** The shared process binding. */
    constructor() : this(NativeShell.binding)

    companion object {
        /** The accelerator name; also `argv[0]`. */
        const val NAME: String = "jaq"

        /**
         * Whether [argv] would make `pdsh-jaq` read the process's standard
         * input, i.e. `jaq FILTER` with neither a file operand nor `-n`.
         *
         * The exec adapter refuses exactly this shape: the C ABI has no stdin
         * channel, and letting the command read the host process's inherited
         * standard input turns "the Worker meant to filter some input" into a
         * convincing empty result (or a blocking read on a JVM host).
         *
         * The jq option grammar is parsed by the Rust `pdsh-jaq` parser through
         * JNI; Kotlin has no second copy of it. A usage error is not a stdin
         * read: the command exits 2 before opening anything.
         *
         * @throws AcceleratorUnavailable the native library or the capability
         *   JSON is not available.
         */
        fun readsProcessStdin(argv: List<String>): Boolean = NativeShell.jaqReadsStdin(argv)
    }
}
