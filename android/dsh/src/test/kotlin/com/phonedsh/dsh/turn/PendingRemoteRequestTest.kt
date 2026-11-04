package com.phonedsh.dsh.turn

import com.phonedsh.agentcore.JsonObject
import com.phonedsh.agentcore.JsonBool
import com.phonedsh.agentcore.JsonNumber
import com.phonedsh.agentcore.JsonString
import com.phonedsh.agentcore.JsonValue
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class PendingRemoteRequestTest {
    @Test
    fun `mux opens both live event subscription and session follow streams`() {
        val events = remoteEventsOpenFrame()
        assertEquals("open", (events["type"] as JsonString).value)
        assertEquals("events", (events["streamId"] as JsonString).value)
        assertEquals("\$events", (events["endpoint"] as JsonString).value)
        assertEquals(emptyMap<String, com.phonedsh.agentcore.JsonValue>(),
            ((events["payload"] as JsonObject)["args"] as JsonObject).members)

        val follow = sessionFollowOpenFrame("session-1", maxMessages = 17, assistantStream = true)
        assertEquals("session/follow", (follow["endpoint"] as JsonString).value)
        assertEquals("follow", (follow["streamId"] as JsonString).value)
        val request = (((follow["payload"] as JsonObject)["args"] as JsonObject)["request"] as JsonObject)
        assertEquals("session", ((request["address"] as JsonObject)["kind"] as JsonString).value)
        assertEquals("session-1", ((request["address"] as JsonObject)["sessionId"] as JsonString).value)
        assertEquals(17L, (request["maxMessages"] as JsonNumber).asLongOrNull())
        assertEquals(true, (request["assistantStream"] as JsonBool).value)
    }

    @Test
    fun `approval waterfall retains event client request and kind`() {
        val raw = JsonValue.parse(
            """{"type":"waterfall","agentId":"session-1","eventId":"event-7","event":"approval/request","request":{"toolName":"bash","reason":"run command"}}""",
        ) as JsonObject
        val pending = requireNotNull(pendingRemoteRequest(raw, "session-1", "client-2"))
        assertEquals("event-7", pending.eventID)
        assertEquals("client-2", pending.clientID)
        assertEquals("approval/request", pending.eventKind)
        assertEquals("bash", ((pending.request as JsonObject)["toolName"] as JsonString).value)
    }

    @Test
    fun `waterfalls are session scoped and retain unsupported kinds for next listeners`() {
        val question = JsonValue.parse(
            """{"type":"waterfall","agentId":"session-1","eventId":"event-8","event":"user-questions/request","request":{"questions":[]}}""",
        ) as JsonObject
        assertEquals(
            "user-questions/request",
            pendingRemoteRequest(question, "session-1", "client-2")?.eventKind,
        )
        assertNull(pendingRemoteRequest(question, "session-other", "client-2"))
        assertNull(pendingRemoteRequest(question, "session-1", null))
        val unsupported = JsonValue.parse(
            """{"type":"waterfall","agentId":"session-1","eventId":"event-9","event":"other/request","request":{}}""",
        ) as JsonObject
        assertEquals("other/request", pendingRemoteRequest(unsupported, "session-1", "client-2")?.eventKind)
    }
}
