// The Rust panic boundary, proven from Kotlin.
// SPDX-License-Identifier: MIT
// A caught panic must be a typed Java exception, and the process must stay
// usable afterwards.

package com.phonedsh.shell

import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

class NativeShellPanicTest {
    @Before
    fun requireNativeLibrary() {
        assertTrue(
            "libpdsh_jni must load for this module's tests; failure=${NativeShell.failure}",
            NativeShell.available,
        )
    }

    @Test
    fun a_rust_panic_arrives_as_a_typed_java_exception() {
        val error = assertThrows(AcceleratorPanicException::class.java) {
            NativeShell.panicForTest("boom")
        }
        assertEquals("panicForTest", error.operation)
        assertTrue(error.detail.contains("boom"))
        assertNotNull(error.cause)
    }

    @Test
    fun the_binding_still_runs_after_a_caught_panic() {
        assertThrows(AcceleratorPanicException::class.java) { NativeShell.panicForTest("boom") }
        TemporaryWorkspace().use { workspace ->
            val result = runBlocking { RgAccelerator().run(workspace.request("rg", "--version")) }
            assertEquals(0, result.exitCode)
            assertTrue(result.stdoutText().startsWith("rg "))
        }
    }
}
