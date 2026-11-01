// `:shell` must fail honestly: a missing library or unreadable caps JSON
// SPDX-License-Identifier: MIT
// is not an empty search result.

package com.phonedsh.shell

import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class NativeShellBindingTest {
    /** A loader that succeeds without touching the real native library. */
    private val noLoad: () -> Unit = {}

    /** Calls that must never be reached; reaching one fails the test. */
    private object UnreachableCalls : NativeShellCalls {
        override fun capsJson(hasToolBridge: Boolean): String = unreachable()

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
        ): ByteArray = unreachable()

        override fun jaqReadsStdin(argv: Array<String>): Boolean = unreachable()

        override fun panicForTest(message: String): String = unreachable()

        private fun unreachable(): Nothing =
            throw AssertionError("the native side must not be called when the binding is unavailable")
    }

    /** A loadable binding whose capability JSON is [capsJson]. */
    private class FakeCalls(private val capsJson: String) : NativeShellCalls {
        override fun capsJson(hasToolBridge: Boolean): String = capsJson

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
        ): ByteArray = throw AssertionError("no accelerator advertises a run here")

        override fun jaqReadsStdin(argv: Array<String>): Boolean =
            throw AssertionError("not used")

        override fun panicForTest(message: String): String = throw AssertionError("not used")
    }

    private fun caps(vararg names: String): String =
        """{"accelerators":[${names.joinToString(",") { "\"$it\"" }}],"version":"0.1.0",
           "limits":{"timeout":30000,"max_output_bytes":1048576,
                     "max_files":10000,"max_file_bytes":15728640}}"""

    @Test
    fun a_failed_load_is_an_honest_stub() {
        val binding = NativeShellBinding(
            load = { throw UnsatisfiedLinkError("no libpdsh_jni for this ABI") },
            calls = UnreachableCalls,
        )
        assertFalse(binding.available)
        assertTrue(binding.failure is UnsatisfiedLinkError)
        assertNull(binding.caps)
        assertNull(binding.version)

        TemporaryWorkspace().use { workspace ->
            val error = assertThrows(AcceleratorUnavailable::class.java) {
                runBlocking { RgAccelerator(binding).run(workspace.request("rg", "--version")) }
            }
            assertTrue(error.cause is UnsatisfiedLinkError)
            assertTrue(ShellAccelerators.detect(workspace.mounts, binding).isEmpty())
        }
    }

    @Test
    fun an_unreadable_capability_json_is_not_an_empty_registry() {
        val binding = NativeShellBinding(load = noLoad, calls = FakeCalls("{not the caps shape"))
        assertFalse(binding.available)
        assertNotNull(binding.failure)
        assertFalse(binding.failure is UnsatisfiedLinkError)

        TemporaryWorkspace().use { workspace ->
            assertThrows(AcceleratorUnavailable::class.java) {
                runBlocking { RgAccelerator(binding).run(workspace.request("rg", "--version")) }
            }
            assertTrue(
                "an unverifiable registry must not produce a tool",
                ShellAccelerators.detect(workspace.mounts, binding).isEmpty(),
            )
        }
    }

    @Test
    fun a_parsed_registry_without_jaq_advertises_only_rg() {
        val binding = NativeShellBinding(load = noLoad, calls = FakeCalls(caps("rg")))
        assertTrue(binding.available)
        assertTrue(RgAccelerator(binding).available)
        assertFalse(JaqAccelerator(binding).available)

        TemporaryWorkspace().use { workspace ->
            assertEqualsNames(listOf("rg"), ShellAccelerators.detect(workspace.mounts, binding))
            assertThrows(AcceleratorUnavailable::class.java) {
                runBlocking { JaqAccelerator(binding).run(workspace.request("jaq", "-n", ".")) }
            }
        }
    }

    @Test
    fun no_mount_means_no_advertised_accelerator_even_when_the_library_can_run_them() {
        val binding = NativeShellBinding(load = noLoad, calls = FakeCalls(caps("jaq", "rg")))
        assertTrue(binding.available)
        assertTrue(
            "pdsh-ffi rejects every run without a mount, so nothing may be advertised",
            ShellAccelerators.detect(emptyList(), binding).isEmpty(),
        )
    }

    private fun assertEqualsNames(expected: List<String>, actual: List<Accelerator>) {
        org.junit.Assert.assertEquals(expected, actual.map { it.name })
    }
}
