// `jaq` through the real Rust registry: filters, exit codes and stdin.
// SPDX-License-Identifier: MIT

package com.phonedsh.shell

import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

class JaqAcceleratorTest {
    @Before
    fun requireNativeLibrary() {
        assertTrue(
            "libpdsh_jni must load for this module's tests; failure=${NativeShell.failure}",
            NativeShell.available,
        )
    }

    @Test
    fun jaq_filters_a_file_from_the_mount() {
        TemporaryWorkspace().use { workspace ->
            workspace.write("data.json", """{"a":1,"b":2}""")
            val result = runBlocking {
                JaqAccelerator().run(workspace.request("jaq", ".a", "data.json"))
            }
            assertEquals(0, result.exitCode)
            assertEquals("1\n", result.stdoutText())
            assertEquals(0, result.stderr.size)
        }
    }

    @Test
    fun jaq_compact_output_is_one_value_per_line() {
        TemporaryWorkspace().use { workspace ->
            workspace.write("data.json", """{"a":1,"b":2}""")
            val result = runBlocking {
                JaqAccelerator().run(workspace.request("jaq", "-c", ".", "data.json"))
            }
            assertEquals(0, result.exitCode)
            assertEquals("""{"a":1,"b":2}""" + "\n", result.stdoutText())
        }
    }

    @Test
    fun jaq_null_input_does_not_read_stdin() {
        TemporaryWorkspace().use { workspace ->
            val result = runBlocking {
                JaqAccelerator().run(workspace.request("jaq", "-n", "."))
            }
            assertEquals(0, result.exitCode)
            assertEquals("null\n", result.stdoutText())
        }
    }

    @Test
    fun a_filter_compile_error_is_exit_three_with_stderr() {
        TemporaryWorkspace().use { workspace ->
            workspace.write("data.json", "1")
            val result = runBlocking {
                JaqAccelerator().run(workspace.request("jaq", "(", "data.json"))
            }
            assertEquals(3, result.exitCode)
            assertTrue(result.stderrText().contains("jaq:"))
        }
    }

    @Test
    fun a_missing_input_file_is_a_runtime_error_after_the_other_files() {
        TemporaryWorkspace().use { workspace ->
            workspace.write("data.json", "1")
            val result = runBlocking {
                JaqAccelerator().run(workspace.request("jaq", ".", "data.json", "missing.json"))
            }
            // The readable file is filtered first, then the missing one fails.
            assertEquals(5, result.exitCode)
            assertTrue(result.stdoutText().contains("1"))
            assertTrue(result.stderrText().contains("missing.json"))
        }
    }

    @Test
    fun reads_process_stdin_detects_the_shape_the_c_abi_cannot_serve() {
        assertTrue(JaqAccelerator.readsProcessStdin(listOf("jaq", ".")))
        assertTrue(
            JaqAccelerator.readsProcessStdin(listOf("jaq", "--arg", "name", "value", ".")),
        )
        // Grouped short flags: a naive `contains("-n")` would call this a stdin read.
        assertFalse(JaqAccelerator.readsProcessStdin(listOf("jaq", "-rn", ".")))
        assertFalse(JaqAccelerator.readsProcessStdin(listOf("jaq", "-n", ".")))
        assertFalse(JaqAccelerator.readsProcessStdin(listOf("jaq", ".", "data.json")))
        assertFalse(JaqAccelerator.readsProcessStdin(listOf("jaq", "--help")))
        // A usage error exits 2 before any read.
        assertFalse(JaqAccelerator.readsProcessStdin(listOf("jaq", "--nonsense", ".")))
    }

    @Test
    fun argv_zero_must_name_the_accelerator() {
        TemporaryWorkspace().use { workspace ->
            assertThrows(IllegalArgumentException::class.java) {
                runBlocking { JaqAccelerator().run(workspace.request("rg", "x")) }
            }
        }
    }
}
