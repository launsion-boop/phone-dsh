// `rg` through the real Rust registry: search, exit codes and budgets.
// SPDX-License-Identifier: MIT
// No Kotlin search logic exists to test here.

package com.phonedsh.shell

import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

class RgAcceleratorTest {
    @Before
    fun requireNativeLibrary() {
        assertTrue(
            "libpdsh_jni must load for this module's tests; failure=${NativeShell.failure}",
            NativeShell.available,
        )
    }

    @Test
    fun rg_finds_a_match_with_the_file_and_line_number() {
        TemporaryWorkspace().use { workspace ->
            workspace.write("a.txt", "hello\nworld\n")
            val result = runBlocking { RgAccelerator().run(workspace.request("rg", "-n", "hello")) }
            assertEquals(0, result.exitCode)
            assertTrue(result.stdoutText().contains("a.txt:1:hello"))
            assertEquals(0, result.stderr.size)
        }
    }

    @Test
    fun rg_reports_no_match_as_exit_one_without_output() {
        TemporaryWorkspace().use { workspace ->
            workspace.write("a.txt", "hello\n")
            val result = runBlocking { RgAccelerator().run(workspace.request("rg", "absent")) }
            assertEquals(1, result.exitCode)
            assertEquals(0, result.stdout.size)
        }
    }

    @Test
    fun rg_reports_a_usage_error_as_exit_two_and_stderr() {
        TemporaryWorkspace().use { workspace ->
            val result = runBlocking {
                RgAccelerator().run(workspace.request("rg", "--not-a-real-flag"))
            }
            assertEquals(2, result.exitCode)
            assertTrue(result.stderrText().contains("rg:"))
        }
    }

    @Test
    fun rg_can_list_files_before_searching() {
        TemporaryWorkspace().use { workspace ->
            workspace.write("a.txt", "x\n")
            workspace.write("b.md", "y\n")
            val result = runBlocking {
                RgAccelerator().run(workspace.request("rg", "--files", "-g", "*.txt"))
            }
            assertEquals(0, result.exitCode)
            assertEquals("a.txt\n", result.stdoutText())
        }
    }

    @Test
    fun the_output_budget_truncates_instead_of_growing_the_frame() {
        TemporaryWorkspace().use { workspace ->
            workspace.write("a.txt", "x".repeat(4096))
            val result = runBlocking {
                RgAccelerator().run(
                    workspace.request("rg", "x", limits = AcceleratorLimits(maxOutputBytes = 64)),
                )
            }
            assertEquals(0, result.exitCode)
            assertTrue(result.stdoutText().contains("pdsh-shell truncated"))
            assertTrue(result.stdout.size < 256)
        }
    }

    @Test
    fun argv_zero_must_name_the_accelerator() {
        TemporaryWorkspace().use { workspace ->
            assertThrows(IllegalArgumentException::class.java) {
                runBlocking { RgAccelerator().run(workspace.request("jaq", ".", "a.json")) }
            }
        }
    }

    @Test
    fun a_request_without_a_mount_does_not_compile_into_a_run() {
        assertThrows(IllegalArgumentException::class.java) {
            AcceleratorRequest(
                argv = listOf("rg", "x"),
                cwd = AcceleratorMount.WORKSPACE,
                mounts = emptyList(),
            )
        }
    }

    @Test
    fun a_relative_cwd_is_refused_before_the_native_call() {
        TemporaryWorkspace().use { workspace ->
            assertThrows(IllegalArgumentException::class.java) {
                AcceleratorRequest(argv = listOf("rg", "x"), cwd = "workspace", mounts = workspace.mounts)
            }
        }
    }

    @Test
    fun a_missing_mount_host_is_a_coded_native_failure() {
        val request = AcceleratorRequest(
            argv = listOf("rg", "--version"),
            cwd = AcceleratorMount.WORKSPACE,
            mounts = listOf(
                AcceleratorMount(AcceleratorMount.WORKSPACE, "/definitely/not/here/pdsh-shell"),
            ),
        )
        val error = assertThrows(AcceleratorException::class.java) {
            runBlocking { RgAccelerator().run(request) }
        }
        assertEquals(AcceleratorException.CODE_START_FAILED, error.code)
    }

    @Test
    fun the_environment_and_a_second_mount_are_marshalled_without_disturbing_the_run() {
        TemporaryWorkspace().use { workspace ->
            val home = workspace.root.resolve("home")
            java.nio.file.Files.createDirectories(home)
            val request = AcceleratorRequest(
                argv = listOf("rg", "--version"),
                cwd = AcceleratorMount.WORKSPACE,
                mounts = workspace.mounts + AcceleratorMount(AcceleratorMount.HOME, home.toString()),
                env = mapOf("PDSH_TEST" to "1"),
            )
            val result = runBlocking { RgAccelerator().run(request) }
            assertEquals(0, result.exitCode)
            assertTrue(result.stdoutText().startsWith("rg "))
        }
    }

    @Test
    fun an_environment_name_containing_equals_is_refused_before_the_native_call() {
        TemporaryWorkspace().use { workspace ->
            assertThrows(IllegalArgumentException::class.java) {
                AcceleratorRequest(
                    argv = listOf("rg", "x"),
                    cwd = AcceleratorMount.WORKSPACE,
                    mounts = workspace.mounts,
                    env = mapOf("BAD=KEY" to "v"),
                )
            }
        }
    }

    @Test
    fun a_nul_in_an_argument_is_the_coded_input_failure() {
        TemporaryWorkspace().use { workspace ->
            val request = AcceleratorRequest(
                argv = listOf("rg", "a\u0000b"),
                cwd = AcceleratorMount.WORKSPACE,
                mounts = workspace.mounts,
            )
            val error = assertThrows(AcceleratorException::class.java) {
                runBlocking { RgAccelerator().run(request) }
            }
            assertEquals(AcceleratorException.CODE_INPUT_INVALID, error.code)
        }
    }
}
