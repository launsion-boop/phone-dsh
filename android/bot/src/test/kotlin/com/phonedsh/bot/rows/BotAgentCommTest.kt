// SPDX-License-Identifier: MIT
package com.phonedsh.bot.rows

import com.phonedsh.agentcore.JsonArray
import com.phonedsh.agentcore.JsonNumber
import com.phonedsh.agentcore.JsonObject
import com.phonedsh.agentcore.JsonString
import com.phonedsh.bot.GoldenFixture
import com.phonedsh.bot.store.BotDomainStore
import com.phonedsh.bot.store.SqliteJdbcDriver
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.nio.file.Files
import java.nio.file.Path

/**
 * Unit/conformance coverage for `spec/bot/v1/golden/team-cases.phone.json`
 * `rowCases` plus the frozen identity rules of `team.md` §2.5, §2.9, §2.10.
 */
class BotAgentCommTest {
    private fun fixture(): JsonObject = GoldenFixture.rawObject("team-cases.phone")

    private fun objectValue(value: com.phonedsh.agentcore.JsonValue?): JsonObject =
        value as? JsonObject ?: JsonObject(emptyMap())

    @Test
    fun rowCasesProduceTheFrozenEventData() {
        for (caseValue in (fixture().members["rowCases"] as JsonArray).values) {
            val caseSpec = objectValue(caseValue)
            val name = (caseSpec.members["name"] as JsonString).value
            val record = BotTeamAgentCommRecord.fromJson(caseSpec.members["record"])
                ?: throw AssertionError("$name: record did not decode")
            assertEquals(
                "$name: eventData",
                caseSpec.members["eventData"],
                record.eventData(),
            )
            assertEquals(
                "$name: record round-trip",
                caseSpec.members["record"],
                record.toJson(),
            )
        }
    }

    @Test
    fun outboundIdentityUsesTheFrozenNulJoinedSha256() {
        val root = fixture()
        val now = (root.members["nowMilliseconds"] as JsonNumber).asLongOrNull()!!
        val seq = now * 1_000
        val outbound = (root.members["rowCases"] as JsonArray).values
            .map(::objectValue)
            .map { objectValue(it.members["record"]) }
            .first { (it.members["direction"] as JsonString).value == "outbound" }
        val rowID = BotAgentCommIdentity.outboundRowID(
            senderAgentID = (outbound.members["botID"] as JsonString).value,
            targetID = objectValue(outbound.members["toAgent"]).members["id"]!!.let {
                (it as JsonString).value
            },
            requestID = (outbound.members["requestID"] as JsonString).value,
            seq = seq,
        )
        assertEquals((outbound.members["rowID"] as JsonString).value, rowID)
        assertEquals(
            (outbound.members["threadID"] as JsonString).value,
            BotAgentCommIdentity.threadID(rowID, seq),
        )
    }

    @Test
    fun sequenceAddsTheCounterToTheScaledClock() {
        val sequence = BotAgentCommSequence(now = { 1_700_000_000_000L })
        assertEquals(1_700_000_000_000_000L, sequence.next())
        assertEquals(1_700_000_000_000_001L, sequence.next())
        assertEquals(1_700_000_000_000_002L, sequence.next())
    }

    @Test
    fun turnRowAllocatesTheCollisionSuffix() {
        assertEquals("t3u", BotAgentCommIdentity.turnRowID(3))
        assertEquals("t3u2", BotAgentCommIdentity.turnRowID(3, setOf("t3u")))
        assertEquals("t3u3", BotAgentCommIdentity.turnRowID(3, setOf("t3u", "t3u2")))
        assertEquals("t0u", BotAgentCommIdentity.turnRowID(-4))
    }

    @Test
    fun agentCommOmitsNullMembers() {
        val comm = BotAgentComm(
            direction = BotAgentCommDirection.INBOUND,
            fromAgentId = "bot-b",
            fromAgentName = "Bee",
            replyText = "hi",
            requestId = "agent:call-1",
            threadId = "thread-1",
        )
        val json = comm.toJson()
        assertTrue(json.members.containsKey("direction"))
        assertFalse(json.members.containsKey("targetId"))
        assertFalse(json.members.containsKey("hop"))
        assertEquals(
            "inbound",
            (json.members["direction"] as JsonString).value,
        )
    }

    @Test
    fun durableAgentCommEventCarriesTheFrozenEnvelope() {
        val row = BotTeamAgentCommRecord(
            rowID = "agent-outbound-phone-1",
            botID = "bot-a",
            direction = BotAgentCommDirection.OUTBOUND,
            role = "assistant",
            text = "hello from bot-a",
            threadID = "agent-outbound-phone-1@7:agent-comm",
            requestID = "agent:call-1",
            toAgent = BotAgentRef("bot-b", "Bee", "agent"),
            delivery = "now",
            hop = 1,
        )
        val path = Files.createTempFile("pdsh-agent-comm-", ".sqlite")
        val store = BotDomainStore(SqliteJdbcDriver(path.toString()))
        try {
            store.append(row.toEvent(time = 1_760_000_000_000L))
            val event = store.events(0, 10).single()
            assertEquals("agent.comm", event.type)
            assertEquals("agent.comm:agent-outbound-phone-1", event.eventId)
            assertEquals(
                "agent-comm:agent-outbound-phone-1@7:agent-comm",
                event.traceId,
            )
            assertEquals("agent:call-1", event.correlationId)
            assertEquals("team", event.principal.kind)
            assertEquals("bot-a", event.principal.botId)
            assertNull(event.principal.sessionId)
            assertEquals(
                "comm-service",
                (event.origin as com.phonedsh.bot.store.BotEventOrigin.Local).source,
            )
            assertEquals(row.eventData(), event.data)
        } finally {
            store.close()
            Files.deleteIfExists(path)
            Files.deleteIfExists(Path.of("$path-wal"))
            Files.deleteIfExists(Path.of("$path-shm"))
        }
    }

    @Test
    fun heldReplyCapsAtOneThousandTwoHundredCharactersAndHasNoHandOff() {
        val value = "长".repeat(3_000)
        val item = BotAgentCommHeld.replyItem(
            id = "held-test-00000000",
            fromAgent = BotAgentRef("bot-b", "Bee"),
            originalTitle = "Question",
            replyText = value,
            requestId = "agent:call-1",
            threadId = "thread-1",
            createdAt = 1_700_000_000_000L,
        )
        assertEquals("agent-held", item.kind)
        assertEquals("回复：Question", item.title)
        assertEquals("reply:agent:call-1", item.requestId)
        assertEquals(1_200, item.text.length)
        assertEquals("thread-1", item.threadId)
        assertEquals("bot-b", item.fromAgentId)
        assertEquals("Bee", item.fromAgentName)
    }

    @Test
    fun createTeammateTruncationNeverSplitsASurrogatePair() {
        // 299 'a' characters plus an astral emoji: the 300-unit boundary would
        // split the surrogate pair, so the emoji must be dropped entirely.
        val value = "a".repeat(299) + "\uD83D\uDE00" + "b"
        val truncated = BotAgentCommText.truncateUtf16(value, 300)
        assertEquals(299, truncated.length)
        assertFalse(truncated.contains("\uD83D"))
        assertEquals("a".repeat(299), truncated)
    }

    @Test
    fun heldIDUsesBase36AndEightLowercaseHex() {
        val id = BotAgentCommHeld.heldID(1_700_000_000_000L, "ABCDEF12")
        assertTrue(Regex("^held-[0-9a-z]+-[0-9a-f]{8}$").matches(id))
        assertTrue(id.endsWith("-abcdef12"))
    }

    @Test
    fun eventDataReaderAcceptsNewAndLegacyRows() {
        val root = fixture()
        for (caseValue in (root.members["rowCases"] as JsonArray).values) {
            val caseSpec = objectValue(caseValue)
            val record = BotTeamAgentCommRecord.fromJson(caseSpec.members["record"])!!
            val decoded = BotTeamAgentCommRecord.fromEventData(
                caseSpec.members["eventData"],
                botID = record.botID,
            ) ?: throw AssertionError("event data did not decode")
            assertEquals(record, decoded)
        }
        val envelope = GoldenFixture.rawObject("event-envelope.phone")
        val legacyCase = (envelope.members["validCases"] as JsonArray).values
            .map(::objectValue)
            .first {
                ((it.members["name"] as? JsonString)?.value) == "agent-comm-outbound"
            }
        val event = objectValue(legacyCase.members["event"])
        val decoded = BotTeamAgentCommRecord.fromEventData(
            event.members["data"],
            botID = "bot-a",
        ) ?: throw AssertionError("legacy event data did not decode")
        assertEquals("agent-outbound-phone-1", decoded.rowID)
        assertEquals(BotAgentCommDirection.OUTBOUND, decoded.direction)
        assertEquals("hello from bot-a", decoded.text)
        assertEquals("agent:call-1", decoded.requestID)
        assertEquals("agent-outbound-phone-1@7:agent-comm", decoded.threadID)
        assertEquals("now", decoded.delivery)
        assertEquals(1, decoded.hop)
        assertEquals("bot-b", decoded.toAgent?.id)
        assertNull(decoded.fromAgent)
    }
}
