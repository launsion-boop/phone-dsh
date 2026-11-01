// The `rg` accelerator: a delegating binding, no search logic of its own.
// SPDX-License-Identifier: MIT

package com.phonedsh.shell

/**
 * The `rg` accelerator (`exec.md` §3), implemented by `pdsh-rg` in Rust.
 *
 * Supported argv is the Rust `rg` subset: `rg [OPTIONS] PATTERN [PATH ...]`,
 * `rg -e PATTERN ...`, and `rg --files [OPTIONS] [PATH ...]`; `--json` prints
 * ripgrep-style JSON lines. Every path is read through the sandboxed VFS, so a
 * request can only read the host directories it mounted.
 *
 * Exit codes are ripgrep's: 0 when something matched, 1 when nothing matched, 2
 * on a usage or search error.
 *
 * @param shell the native binding; the no-argument constructor uses the process
 *   singleton, and the internal one exists for the binding tests.
 */
class RgAccelerator internal constructor(shell: NativeShellBinding) :
    Accelerator by NativeAccelerator(shell, NAME) {

    /** The shared process binding. */
    constructor() : this(NativeShell.binding)

    companion object {
        /** The accelerator name; also `argv[0]`. */
        const val NAME: String = "rg"
    }
}
