// phone-dsh — :platform-android unit test: the proot command and environment.
// SPDX-License-Identifier: MIT
//
// These are the facts the recon's device probe depended on: the exact argv
// (including `--kill-on-exit`, `-r`, the one host workspace bind and `-w`), the
// environment that makes Termux proot load its loader and libtalloc, and the
// probe's availability answer when a binary is absent. The OS launcher itself
// is instrumented-test territory; this suite deliberately calls no android.*.

package com.phonedsh.platform.android

import java.nio.file.Files
import java.nio.file.Path
import java.nio.file.attribute.PosixFilePermissions
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ProotRuntimeTest {
    private fun fixture(): Pair<Path, Path> {
        val lib = Files.createTempDirectory("pdsh-proot-lib")
        val tmp = Files.createTempDirectory("pdsh-proot-tmp")
        return lib to tmp
    }

    @Test
    fun command_carries_the_pinned_flags_bind_and_guest_argv() {
        val (lib, tmp) = fixture()
        val runtime = ProotRuntime(lib, tmp)
        val plan = runtime.plan(
            rootfs = Path.of("/data/ubuntu/rootfs/24.04.5"),
            hostWorkspace = Path.of("/data/ubuntu/workspace"),
            cwd = "/dsh/workspace",
            argv = listOf("uname", "-a"),
        )
        assertEquals(
            listOf(
                lib.resolve("libproot.so").toString(),
                "--kill-on-exit",
                "-0",
                "-r",
                "/data/ubuntu/rootfs/24.04.5",
                "-b",
                "/data/ubuntu/workspace:/dsh/workspace",
                "-w",
                "/dsh/workspace",
                "uname",
                "-a",
            ),
            plan.command,
        )
        assertEquals(tmp, plan.workingDirectory)
    }

    @Test
    fun environment_is_the_proot_stack_plus_a_clean_guest_env() {
        val (lib, tmp) = fixture()
        val plan = ProotRuntime(lib, tmp).plan(
            rootfs = Path.of("/data/rootfs"),
            hostWorkspace = Path.of("/data/workspace"),
            cwd = "/dsh/workspace",
            argv = listOf("true"),
        )
        assertEquals(lib.resolve("libproot_loader.so").toString(), plan.environment["PROOT_LOADER"])
        assertEquals(lib.toString(), plan.environment["LD_LIBRARY_PATH"])
        assertEquals(tmp.toString(), plan.environment["PROOT_TMP_DIR"])
        assertEquals("1", plan.environment["PROOT_NO_SECCOMP"])
        assertEquals("/root", plan.environment["HOME"])
        assertEquals("C.UTF-8", plan.environment["LANG"])
        assertEquals("xterm-256color", plan.environment["TERM"])
        assertEquals("/tmp", plan.environment["TMPDIR"])
        assertTrue(plan.environment.getValue("PATH").contains("/usr/bin"))
        // The app's own environment is the launcher's to clear; the plan must
        // carry no host credential or tool-call variable.
        assertTrue(plan.environment.keys.none { it.startsWith("PDSH_") })
    }

    @Test
    fun availability_requires_all_four_binaries_and_an_executable_proot() {
        val (lib, tmp) = fixture()
        val runtime = ProotRuntime(lib, tmp)
        assertFalse(runtime.isAvailable())
        assertEquals("proot_missing", runtime.unavailableReason())

        for (name in listOf(
            ProotRuntime.PROOT,
            ProotRuntime.LOADER,
            ProotRuntime.TALLOC,
            ProotRuntime.SHMEM,
        )) {
            Files.write(lib.resolve(name), byteArrayOf(0x7f, 'E'.code.toByte(), 'L'.code.toByte(), 'F'.code.toByte()))
        }
        Files.setPosixFilePermissions(
            lib.resolve(ProotRuntime.PROOT),
            PosixFilePermissions.fromString("rwxr-xr-x"),
        )
        assertTrue(runtime.isAvailable())
        assertNull(runtime.unavailableReason())

        Files.setPosixFilePermissions(
            lib.resolve(ProotRuntime.PROOT),
            PosixFilePermissions.fromString("rw-r--r--"),
        )
        assertFalse(runtime.isAvailable())
        assertEquals("proot_not_executable", runtime.unavailableReason())
    }
}
