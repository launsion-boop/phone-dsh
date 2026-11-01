// The live binding against the real `libpdsh_jni`: caps honesty and defaults.
// SPDX-License-Identifier: MIT

package com.phonedsh.shell

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

class NativeShellTest {
    @Before
    fun requireNativeLibrary() {
        assertTrue(
            "libpdsh_jni must load for this module's tests; failure=${NativeShell.failure}",
            NativeShell.available,
        )
    }

    @Test
    fun the_linked_registry_is_read_not_guessed() {
        val caps = NativeShell.caps
        assertNotNull(caps)
        assertEquals(caps, NativeShell.caps)
        assertFalse(NativeShell.version.isNullOrEmpty())
        assertEquals(NativeShell.version, caps!!.version)

        // The library advertises more than this module implements. That is the
        // reason ShellAccelerators.detect intersects instead of republishing.
        for (name in listOf("rg", "jaq", "ts-parse", "ts-query")) {
            assertTrue("the linked registry must advertise $name", caps.says(name))
        }

        // No host tool bridge is supplied by this binding, so the FFI must not
        // advertise the commands that cannot answer `call_tool`.
        assertFalse(caps.says("phone"))
        assertFalse(caps.says("ctx"))
    }

    @Test
    fun kotlin_limit_defaults_match_the_linked_library() {
        assertEquals(NativeShell.caps!!.limits, AcceleratorLimits())
        assertEquals(30_000L, AcceleratorLimits.DEFAULT_TIMEOUT_MS)
        assertEquals(1_048_576L, AcceleratorLimits.DEFAULT_MAX_OUTPUT_BYTES)
        assertEquals(10_000L, AcceleratorLimits.DEFAULT_MAX_FILES)
        assertEquals(15L * 1024L * 1024L, AcceleratorLimits.DEFAULT_MAX_FILE_BYTES)
    }

    @Test
    fun detect_returns_the_implemented_accelerators_in_a_stable_order() {
        TemporaryWorkspace().use { workspace ->
            val detected = ShellAccelerators.detect(workspace.mounts)
            assertEquals(listOf("rg", "jaq"), detected.map { it.name })
            assertTrue(detected.all { it.available })
        }
    }

    @Test
    fun detect_returns_nothing_without_a_mount() {
        assertTrue(ShellAccelerators.detect(emptyList()).isEmpty())
    }

    @Test
    fun the_no_argument_constructors_share_the_process_binding() {
        assertEquals("rg", RgAccelerator().name)
        assertEquals("jaq", JaqAccelerator().name)
        assertTrue(RgAccelerator().available)
        assertTrue(JaqAccelerator().available)
    }
}
