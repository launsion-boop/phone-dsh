// D1-c tests — capabilities, open/resume requests and last_seq semantics.
// SPDX-License-Identifier: MIT
package com.phonedsh.agentcore

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class HarnessSessionTest {
    @Test
    fun capabilitiesDecodeTheDshRemoteGoldenAndIgnoreUnknownMembers() {
        val json = """
            {
              "cancel": true,
              "steer": true,
              "resume": "native",
              "permission": "native",
              "client_tools": "none",
              "tool_visibility": true,
              "runs_while_app_suspended": true,
              "future_capability_member": { "hint": 1 }
            }
        """.trimIndent()

        val capabilities = HarnessJson.decodeCapabilities(json)

        assertTrue(capabilities.cancel)
        assertTrue(capabilities.steer)
        assertEquals(HarnessCapabilities.Resume.NATIVE, capabilities.resume)
        assertEquals(HarnessCapabilities.Permission.NATIVE, capabilities.permission)
        assertEquals(HarnessCapabilities.ClientTools.NONE, capabilities.clientTools)
        assertTrue(capabilities.toolVisibility)
        // The wire value is `true`, so decoding must keep it: the decoder reports
        // what the backend said, it does not second-guess it. The dishonest thing
        // was the *constructor default*, which is now false until platform facts
        // are supplied — see BackgroundExecutionTest.
        assertTrue(capabilities.runsWhileAppSuspended)
    }

    @Test
    fun capabilitiesRequireAllSevenMembersOnTheWire() {
        val missingSteer = """
            {
              "cancel": true,
              "resume": "native",
              "permission": "none",
              "client_tools": "none",
              "tool_visibility": true,
              "runs_while_app_suspended": false
            }
        """.trimIndent()

        val failure = assertThrows(HarnessDecodingException::class.java) {
            HarnessJson.decodeCapabilities(missingSteer)
        }

        assertEquals("capabilities", failure.path)
        assertEquals(HarnessErrorCode.INVALID_RESPONSE, failure.code)
    }

    @Test
    fun sessionRequestDecodesTheThreeTransportVariants() {
        val json = """
            {
              "preset": "default",
              "workspace": "/dsh/home/workspaces/main",
              "instructions": "Answer in the language the user wrote in.",
              "client_tools": [
                {
                  "name": "phone-tools-http",
                  "transport": {
                    "type": "streamable_http",
                    "url": "http://127.0.0.1:9/mcp",
                    "headers": { "Authorization": "Bearer token" }
                  },
                  "allowed_tools": ["send_sms"]
                },
                {
                  "name": "phone-tools-relay",
                  "transport": { "type": "relay", "relay_id": "relay-1" }
                },
                {
                  "name": "phone-tools-embedded",
                  "transport": { "type": "in_process", "name": "phone-tools" }
                }
              ],
              "metadata": { "origin": "app", "device_id": "esp32-8c4f1a" }
            }
        """.trimIndent()

        val request = HarnessJson.decodeSessionRequest(json)

        assertNull("an absent session_id opens a new session", request.sessionId)
        assertEquals("default", request.preset)
        assertEquals(3, request.clientTools.size)
        assertEquals(
            McpTransport.StreamableHttp(
                url = "http://127.0.0.1:9/mcp",
                headers = mapOf("Authorization" to "Bearer token"),
            ),
            request.clientTools[0].transport,
        )
        assertEquals(McpTransport.Relay("relay-1"), request.clientTools[1].transport)
        assertEquals(McpTransport.InProcess("phone-tools"), request.clientTools[2].transport)
        assertEquals(listOf("send_sms"), request.clientTools[0].allowedTools)
        assertEquals(mapOf("origin" to "app", "device_id" to "esp32-8c4f1a"), request.metadata)
    }

    @Test
    fun emptySessionRequestIsValidAndResumeIsSignalledOnlyBySessionId() {
        val request = HarnessJson.decodeSessionRequest("{}")

        assertNull(request.sessionId)
        assertNull(request.preset)
        assertNull(request.workspace)
        assertNull(request.instructions)
        assertTrue(request.clientTools.isEmpty())
        assertTrue(request.metadata.isEmpty())

        val resume = HarnessJson.decodeSessionRequest("""{"session_id":"sess-2f7c"}""")
        assertEquals("sess-2f7c", resume.sessionId)
    }

    @Test
    fun sessionDecodesReportedLastSeqOrAbsenceOfIt() {
        val resumed = HarnessJson.decodeSession("""{"id":"sess-2f7c","capabilities":$CAPABILITIES,"last_seq":8}""")
        assertEquals("sess-2f7c", resumed.id)
        assertEquals(8L, resumed.lastSeq)

        // The DSH remote returns last_seq nil even when it resumes a session.
        val notReported = HarnessJson.decodeSession("""{"id":"sess-2f7c","capabilities":$CAPABILITIES}""")
        assertNull(notReported.lastSeq)
    }

    /**
     * `last_seq` is "what the backend reported at open time", not a cursor.
     * A session opened with `last_seq = 8` must not make `events` skip anything:
     * the caller's cursor starts at `null` (from the beginning of retention).
     */
    @Test
    fun lastSeqIsNotUsedAsTheResumeCursor() {
        val harness = FakeHarness(
            wire = listOf(
                WireLine.Json(assistantMessage(seq = 0)),
                WireLine.Json(assistantMessage(seq = 1)),
                WireLine.Json(assistantMessage(seq = 2)),
            ),
            reportedLastSeq = 8,
        )
        val session = runSuspendValue {
            harness.openSession(HarnessSessionRequest(sessionId = "sess-2f7c"))
        }
        assertEquals(8L, session.lastSeq)

        val seqs = ArrayList<Long?>()
        harness.events(session.id, afterSeq = null).collectBlocking { event ->
            seqs += event.seq
        }

        assertEquals(listOf(0L, 1L, 2L), seqs)
    }

    private fun assistantMessage(seq: Long): String =
        """{"session_id":"s","seq":$seq,"time_ms":$seq,"kind":"assistant_message","text":"e$seq"}"""

    private companion object {
        private const val CAPABILITIES =
            """{"cancel":true,"steer":true,"resume":"native","permission":"native","client_tools":"none","tool_visibility":true,"runs_while_app_suspended":true}"""
    }
}
