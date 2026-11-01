// The one place that decides which accelerators this process can execute.
// SPDX-License-Identifier: MIT

package com.phonedsh.shell

/**
 * The exec/1 accelerator set this module can honestly contribute.
 *
 * [detect] is deliberately the only factory the host wiring should use: it
 * answers the subset of [RgAccelerator] and [JaqAccelerator] that the loaded
 * library actually advertises, and answers nothing when there is no mount. That
 * second rule is not cosmetic: `pdsh-ffi` rejects every run without a mount, so
 * an accelerator advertised without one could never execute and the HELLO would
 * be a lie. The rule mirrors the iOS `PDSHShellProvider`, which publishes no
 * accelerator name when its mount list is empty.
 *
 * The names are never a Kotlin constant list of "supported" commands: they come
 * from the capability JSON of the linked library, so a library without `rg` (or
 * a broken load) cannot produce a tool that does not run.
 */
object ShellAccelerators {
    /**
     * The accelerators this process can execute with [mounts].
     *
     * @param mounts the guest-to-host mounts the exec adapter will pass with
     *   every request. An empty list answers an empty list.
     * @return the available accelerators, in a stable order (`rg`, then `jaq`).
     */
    fun detect(mounts: List<AcceleratorMount>): List<Accelerator> =
        detect(mounts, NativeShell.binding)

    /**
     * The testable form: [detect] against an explicit binding.
     *
     * @param mounts the mounts the exec adapter will pass.
     * @param binding the native binding, normally [NativeShell.binding].
     */
    internal fun detect(
        mounts: List<AcceleratorMount>,
        binding: NativeShellBinding,
    ): List<Accelerator> {
        if (mounts.isEmpty()) {
            return emptyList()
        }
        val accelerators: List<Accelerator> = listOf(
            RgAccelerator(binding),
            JaqAccelerator(binding),
        )
        return accelerators.filter { it.available }
    }
}
