// The capability JSON is a fact of the linked library, parsed once.
// SPDX-License-Identifier: MIT
// It is not a list of constants guessed on the Kotlin side.

package com.phonedsh.shell

import org.json.JSONException
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class NativeShellCapsTest {
    /** The shape `pdsh_core::Caps::json` emits. */
    private val shipped = """
        {"accelerators":["jaq","jq","rg","ts-parse","ts-query"],"version":"0.1.0",
         "limits":{"timeout":30000,"max_output_bytes":1048576,
                   "max_files":10000,"max_file_bytes":15728640}}
    """.trimIndent()

    @Test
    fun parse_reads_the_names_version_and_limits() {
        val caps = NativeShellCaps.parse(shipped)
        assertEquals("0.1.0", caps.version)
        assertEquals(listOf("jaq", "jq", "rg", "ts-parse", "ts-query"), caps.accelerators)
        assertEquals(30_000L, caps.limits.timeoutMs)
        assertEquals(1_048_576L, caps.limits.maxOutputBytes)
        assertEquals(10_000L, caps.limits.maxFiles)
        assertEquals(15L * 1024L * 1024L, caps.limits.maxFileBytes)
        assertTrue(caps.says("rg"))
        assertTrue(caps.says("jaq"))
        assertFalse(caps.says("phone"))
        assertFalse(caps.says("ctx"))
    }

    @Test
    fun parse_rejects_a_payload_that_is_not_the_documented_shape() {
        assertThrows(JSONException::class.java) { NativeShellCaps.parse("{}") }
        assertThrows(JSONException::class.java) { NativeShellCaps.parse("not json") }
        assertThrows(JSONException::class.java) {
            NativeShellCaps.parse("""{"accelerators":["rg"],"version":"0.1.0"}""")
        }
    }

    @Test
    fun a_negative_advertised_limit_is_refused_instead_of_wrapped() {
        assertThrows(IllegalArgumentException::class.java) {
            NativeShellCaps.parse(
                """{"accelerators":["rg"],"version":"0.1.0",
                   "limits":{"timeout":-1,"max_output_bytes":1,"max_files":1,"max_file_bytes":1}}""",
            )
        }
    }
}
