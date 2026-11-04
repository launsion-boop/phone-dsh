// API_RES head parsing: channel.md §3.8's status range, not a fabricated value.
// SPDX-License-Identifier: MIT
package com.phonedsh.dsh.host

import com.phonedsh.agentcore.JsonNumber
import com.phonedsh.agentcore.JsonObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class HostApiFramesTest {
    private fun fields(status: String): JsonObject = JsonObject(
        linkedMapOf(
            "head" to JsonObject(
                linkedMapOf(
                    "status" to JsonNumber(status),
                    "headers" to JsonObject(emptyMap()),
                ),
            ),
        ),
    )

    @Test
    fun `a head carries its HTTP status and lowercase headers`() {
        val parsed = HostApiFrames.head(
            JsonObject(
                linkedMapOf(
                    "head" to JsonObject(
                        linkedMapOf(
                            "status" to JsonNumber("200"),
                            "headers" to JsonObject(linkedMapOf("Content-Type" to com.phonedsh.agentcore.JsonString("application/json"))),
                        ),
                    ),
                ),
            ),
        )
        assertEquals(200, parsed?.status)
        assertEquals("application/json", parsed?.headers?.get("content-type"))
    }

    @Test
    fun `a status outside the HTTP range is not a head`() {
        for (status in listOf("0", "99", "600", "-1")) {
            assertNull("status $status must not parse as a head", HostApiFrames.head(fields(status)))
        }
    }

    @Test
    fun `an overflowing status must not wrap into a valid HTTP code`() {
        // 2^32 + 200 narrows to 200 if the Long is converted before the range
        // check. The decoder must reject it as a malformed head.
        assertNull(
            "an overflowing status must not become 200",
            HostApiFrames.head(fields("4294967496")),
        )
    }

    @Test(expected = IllegalArgumentException::class)
    fun `HostApiHead refuses the invented status zero`() {
        HostApiHead(status = 0, headers = emptyMap())
    }

    @Test
    fun `the boundary statuses are accepted`() {
        assertEquals(100, HostApiHead(100, emptyMap()).status)
        assertEquals(599, HostApiHead(599, emptyMap()).status)
        assertTrue(HostApiFrames.head(fields("599")) != null)
    }
}
