// SPDX-License-Identifier: MIT
// The read-back fed from the engine's own authority (spec/host/v1/README.md
// section 10, "Outcome unknown"): one `session/follow` snapshot supplies the
// inbox projection and the history cursor, and `session/page` walks back from
// that cursor. The source is scripted; the resolution is the real one.
package com.phonedsh.probe.outbox

import com.phonedsh.agentcore.JsonObject
import com.phonedsh.agentcore.JsonValue
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class SendOutboxHistoryReaderTest {
    private val entry = SendOutboxEntry(
        rpcId = "3f2a1c4e-5b6d-4e8f-9a0b-1c2d3e4f5a6b",
        sessionId = "worker-1",
        text = "hello",
        createdAtMs = 1_794_700_000_000L,
        state = SendOutboxState.OUTCOME_UNKNOWN,
        attempts = 1,
    )

    private fun json(text: String) = JsonValue.parse(text)

    private fun snapshot(cursor: String, inbox: String? = """{"next-turn":[],"next-step":[]}""") = json(
        if (inbox == null) """{"type":"snapshot","cursor":$cursor}"""
        else """{"type":"snapshot","cursor":$cursor,"projections":{"kind":"sequenced","values":{"inbox":$inbox}}}""",
    ) as JsonObject

    private fun userMessage(seq: Int, rpcId: String) =
        """{"event":{"seq":$seq,"type":"user/message","data":{"source":{"kind":"user","rpcId":"$rpcId"}}}}"""

    private class Source(
        private val snapshot: () -> JsonObject,
        private val pages: (Long?) -> JsonValue,
    ) : SessionHistorySource {
        val calls = ArrayList<String>()

        override suspend fun followSnapshot(sessionId: String): JsonObject {
            calls += "follow:$sessionId"
            return snapshot()
        }

        override suspend fun page(sessionId: String, throughSeq: Long, beforeSeq: Long?): JsonValue {
            calls += "page:$sessionId:$throughSeq:${beforeSeq ?: "-"}"
            return pages(beforeSeq)
        }
    }

    private fun read(source: Source) = runBlocking { SendOutboxHistoryReader.readBack(entry, source) }

    @Test
    fun `a user message with the rpcId in an older page is journaled and every page reads through the snapshot cursor`() {
        val source = Source({ snapshot("90") }) { before ->
            if (before == null) json("""{"records":[${userMessage(80, "other")}],"hasMore":true}""")
            else json("""{"records":[${userMessage(40, entry.rpcId)}],"hasMore":false}""")
        }
        assertEquals(SendOutboxReadBack.JOURNALED, read(source))
        assertEquals(listOf("follow:worker-1", "page:worker-1:90:-", "page:worker-1:90:80"), source.calls)
    }

    @Test
    fun `a prompt held in the snapshot inbox is held without reading history further`() {
        val inbox = """{"next-turn":[{"source":{"kind":"user","rpcId":"${entry.rpcId}"}}],"next-step":[]}"""
        val source = Source({ snapshot("5", inbox) }) { json("""{"records":[],"hasMore":false}""") }
        assertEquals(SendOutboxReadBack.HELD, read(source))
    }

    @Test
    fun `an empty history and an empty inbox from one snapshot prove absence`() {
        val empty = Source({ snapshot("-1") }) { throw AssertionError("an empty history has no page") }
        assertEquals(SendOutboxReadBack.ABSENT, read(empty))
        assertEquals(listOf("follow:worker-1"), empty.calls)

        val walked = Source({ snapshot("7") }) { json("""{"records":[${userMessage(3, "other")}],"hasMore":false}""") }
        assertEquals(SendOutboxReadBack.ABSENT, read(walked))
    }

    @Test
    fun `a snapshot without the inbox projection or with an unreadable cursor proves nothing`() {
        val page = """{"records":[],"hasMore":false}"""
        assertEquals(SendOutboxReadBack.INCONCLUSIVE, read(Source({ snapshot("7", inbox = null) }) { json(page) }))
        for (cursor in listOf("1.5", "-2", "\"7\"")) {
            val source = Source({ snapshot(cursor) }) { json(page) }
            assertEquals(cursor, SendOutboxReadBack.INCONCLUSIVE, read(source))
            assertTrue(source.calls.none { it.startsWith("page:") })
        }
    }

    @Test
    fun `a failed follow or page read is inconclusive and never looks like absence`() {
        val noFollow = Source({ throw IllegalStateException("channel closed") }) { json("{}") }
        assertEquals(SendOutboxReadBack.INCONCLUSIVE, read(noFollow))
        val noPage = Source({ snapshot("7") }) { throw IllegalStateException("session/page failed") }
        assertEquals(SendOutboxReadBack.INCONCLUSIVE, read(noPage))
        val laterPage = Source({ snapshot("90") }) { before ->
            if (before == null) json("""{"records":[${userMessage(80, "other")}],"hasMore":true}""")
            else throw IllegalStateException("session/page failed")
        }
        assertEquals(SendOutboxReadBack.INCONCLUSIVE, read(laterPage))
    }
}
