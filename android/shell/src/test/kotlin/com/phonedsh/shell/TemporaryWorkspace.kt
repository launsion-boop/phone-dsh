// Test fixtures: a throwaway host directory mounted as /dsh/workspace.
// SPDX-License-Identifier: MIT

package com.phonedsh.shell

import java.io.Closeable
import java.nio.file.Files
import java.nio.file.Path

/**
 * A temporary host directory mounted at [AcceleratorMount.WORKSPACE].
 *
 * Every native test needs a real directory: `pdsh-ffi` canonicalizes the host
 * root and refuses a missing one, so a fake path would turn every run into a
 * start failure.
 */
internal class TemporaryWorkspace : Closeable {
    val root: Path = Files.createTempDirectory("pdsh-shell-test-")

    /** The one mount every request in these tests uses. */
    val mounts: List<AcceleratorMount> =
        listOf(AcceleratorMount(AcceleratorMount.WORKSPACE, root.toString()))

    /** Writes [text] to [name] below the workspace root. */
    fun write(name: String, text: String): Path {
        val path = root.resolve(name)
        path.toFile().writeText(text)
        return path
    }

    /** A request with this workspace's mount and the guest cwd at its root. */
    fun request(
        vararg argv: String,
        limits: AcceleratorLimits = AcceleratorLimits(),
    ): AcceleratorRequest = AcceleratorRequest(
        argv = argv.toList(),
        cwd = AcceleratorMount.WORKSPACE,
        mounts = mounts,
        limits = limits,
    )

    override fun close() {
        root.toFile().deleteRecursively()
    }
}
