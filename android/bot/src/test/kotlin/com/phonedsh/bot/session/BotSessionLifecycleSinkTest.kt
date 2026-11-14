// SPDX-License-Identifier: MIT
package com.phonedsh.bot.session

import com.phonedsh.agentcore.JsonObject
import com.phonedsh.agentcore.JsonString
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The runtime's durable lifecycle sink is the integration point the Android
 * App uses to write `runtime.started` / `runtime.exited` into the P25 store
 * (`session-lifecycle.md` §4/§7). This test pins the callback timing and the
 * exact event data so a host cannot silently keep the events in memory.
 */
class BotSessionLifecycleSinkTest {
    @Test
    fun startAndErasureSwitchAreHandedToTheDurableSink() {
        val received = ArrayList<BotSessionLifecycleEvent>()
        val transport = RecordingTransport()
        val runtime = BotSessionRuntime(
            transport = transport,
            now = { 1_234L },
            onLifecycleEvent = { received += it },
        )

        val first = runtime.startMainSession()
        assertEquals("gb-main", first)
        assertEquals(listOf("runtime.started"), received.map { it.type })
        assertEquals(
            setOf("sessionId", "botId", "cwd"),
            received.single().data.keys,
        )
        assertEquals(
            "gb-main",
            (received.single().data["sessionId"] as JsonString).value,
        )
        assertEquals(1, runtime.appendedEvents().size)

        val switched = runtime.switchMainSessionForErasure(
            erasureID = "erasure-1",
            erasedRecords = listOf("ref-1"),
        )
        assertEquals(first, switched.old)
        assertEquals(
            listOf("runtime.started", "runtime.exited", "runtime.started"),
            received.map { it.type },
        )
        val exited = received[1]
        assertEquals("session-erased", (exited.data["reason"] as JsonString).value)
        assertEquals(switched.new, (exited.data["replacedBy"] as JsonString).value)
        assertEquals("erasure-1", (exited.data["erasureId"] as JsonString).value)
        assertEquals(
            listOf("ref-1"),
            (exited.data["erasedRecords"] as com.phonedsh.agentcore.JsonArray)
                .values.map { (it as JsonString).value },
        )
        assertEquals(3, runtime.appendedEvents().size)
        assertTrue(transport.created.size >= 2)
    }

    private class RecordingTransport : BotSessionTransport {
        val created = ArrayList<String>()

        override fun call(endpoint: String, args: JsonObject): JsonObject {
            val request = (args["request"] as? JsonObject)?.members ?: emptyMap()
            return when (endpoint) {
                "session/create" -> {
                    val requested = (request["sessionId"] as? JsonString)?.value ?: "missing"
                    created += requested
                    JsonObject(
                        linkedMapOf(
                            "sessionId" to JsonString(requested),
                            "agentPreset" to JsonString(
                                (request["agentPreset"] as? JsonString)?.value ?: "phone-bot"),
                        ),
                    )
                }
                "phone/botClaimSession" -> JsonObject(
                    linkedMapOf("ok" to com.phonedsh.agentcore.JsonBool(true)),
                )
                "workspace/archiveSession", "workspace/unarchiveSession", "session/cancel" ->
                    JsonObject(linkedMapOf("ok" to com.phonedsh.agentcore.JsonBool(true)))
                else -> JsonObject(linkedMapOf("ok" to com.phonedsh.agentcore.JsonBool(true)))
            }
        }

        override fun openFollow(): BotFollowConnection =
            throw UnsupportedOperationException("startMainSession does not open a follow stream")
    }
}
