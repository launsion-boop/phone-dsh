// SPDX-License-Identifier: MIT
// `session/prompt` submission through the C4 transport seam: the exact DSH
// argument shape, a fresh requestId per submission, and the rejected/failed
// paths. No prompt text is logged or stored in the runner.
package com.phonedsh.probe.pc

import com.phonedsh.agentcore.JsonArray
import com.phonedsh.agentcore.JsonBool
import com.phonedsh.agentcore.JsonObject
import com.phonedsh.agentcore.JsonString
import com.phonedsh.pclink.PclinkError
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class PcChatTurnRunnerTest {
    @Test
    fun `accepted prompt sends the DSH request shape and a fresh id`() = runBlocking {
        val transport = ScriptedDshCall()
        var nextId = 0
        val runner = PcChatTurnRunner(transport, newRequestId = { "request-${++nextId}" })

        val first = runner.submit("session-1", "hello PC") as PcTurnOutcome.Accepted
        val second = runner.submit("session-1", "hello PC") as PcTurnOutcome.Accepted

        assertEquals("request-1", first.requestId)
        assertEquals("request-2", second.requestId)
        assertNotEquals(first.requestId, second.requestId)

        val (endpoint, argsValue) = transport.calls.first()
        assertEquals(PcChatTurnRunner.ENDPOINT, endpoint)
        val args = argsValue as JsonObject
        val request = args["request"] as JsonObject
        assertEquals(JsonString("request-1"), request["requestId"])
        assertEquals(JsonString("session-1"), request["sessionId"])
        assertEquals(JsonString(PcChatTurnRunner.MODE_QUEUE), request["mode"])
        val content = (request["content"] as JsonArray).values.single() as JsonObject
        assertEquals(JsonString("text"), content["type"])
        assertEquals(JsonString("hello PC"), content["text"])
        assertEquals(2, transport.calls.size)
    }

    @Test
    fun `accepted false is a rejected outcome, not a silent success`() = runBlocking {
        val transport = ScriptedDshCall().apply {
            handler = { _, _ -> JsonObject(linkedMapOf("accepted" to JsonBool(false))) }
        }
        val runner = PcChatTurnRunner(transport)
        val outcome = runner.submit("session-1", "hello")
        assertTrue(outcome is PcTurnOutcome.Rejected)
    }

    @Test
    fun `a transport failure is propagated unchanged`() = runBlocking {
        val transport = ScriptedDshCall().apply {
            handler = { _, _ -> throw PclinkError.PeerOffline() }
        }
        val runner = PcChatTurnRunner(transport)
        val error = assertThrows(PclinkError.PeerOffline::class.java) {
            runBlocking { runner.submit("session-1", "hello") }
        }
        assertEquals("peer_offline", error.code)
    }

    @Test
    fun `blank input never becomes a request`() {
        val transport = ScriptedDshCall()
        val runner = PcChatTurnRunner(transport)
        assertThrows(IllegalArgumentException::class.java) {
            runBlocking { runner.submit("", "hello") }
        }
        assertThrows(IllegalArgumentException::class.java) {
            runBlocking { runner.submit("session-1", "") }
        }
        assertTrue(transport.calls.isEmpty())
    }
}
