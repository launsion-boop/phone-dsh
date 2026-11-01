// The one Kotlin implementation shared by the concrete accelerators.
// SPDX-License-Identifier: MIT

package com.phonedsh.shell

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/**
 * The shared body of [RgAccelerator] and [JaqAccelerator].
 *
 * Both accelerators differ only in the name the Rust registry dispatches on, so
 * the availability check, the `argv[0]` guard and the `Dispatchers.IO` hop live
 * here once. Adding `ts-parse` later is one delegating class and one entry in
 * [ShellAccelerators.detect], not a third implementation of this logic.
 *
 * @param shell the binding that owns the loaded native library.
 * @param name the accelerator name; also the required `argv[0]`.
 */
internal class NativeAccelerator(
    private val shell: NativeShellBinding,
    override val name: String,
) : Accelerator {
    override val available: Boolean
        get() = shell.available && shell.caps?.says(name) == true

    override suspend fun run(request: AcceleratorRequest): AcceleratorResult {
        require(request.argv.first() == name) {
            "argv[0] must be \"$name\" for this accelerator"
        }
        if (!available) {
            // The library may be fine while this one command is not advertised;
            // running it anyway would be exactly the over-claim this module
            // exists to avoid.
            throw AcceleratorUnavailable(accelerator = name, cause = shell.failure)
        }
        return withContext(Dispatchers.IO) { shell.run(request) }
    }
}
