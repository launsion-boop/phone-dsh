// SPDX-License-Identifier: MIT
package com.phonedsh.bot.wake

import com.phonedsh.agentcore.JsonNull
import com.phonedsh.agentcore.JsonObject
import com.phonedsh.agentcore.JsonString
import com.phonedsh.bot.GoldenFixture
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * `spec/bot/v1/golden/turn-origin.phone.json`: the prefix table, the
 * `hidden`/`held`/`memorySource` derivations, and every invalid boundary case
 * (empty, bare prefix, whitespace-only payload, case shift, embedded prefix).
 */
class BotTurnOriginTest {
    private fun rpcIdOf(case: JsonObject): String? = when (val value = case.members["rpcId"]) {
        null, is JsonNull -> null
        is JsonString -> value.value
        else -> throw AssertionError("rpcId must be a string")
    }

    @Test
    fun everyVectorRowMatchesTheGolden() {
        val golden = GoldenFixture.rawObject("turn-origin.phone")
        assertEquals("turn-origin.phone", (golden.members["vector"] as JsonString).value)
        val valid = (golden.members["valid"] as com.phonedsh.agentcore.JsonArray).values
        val invalid = (golden.members["invalid"] as com.phonedsh.agentcore.JsonArray).values
        assertEquals(9, valid.size)
        assertEquals(32, invalid.size)

        fun assertRows(rows: List<com.phonedsh.agentcore.JsonValue>, prefix: String) {
            for (raw in rows) {
                val case = raw as JsonObject
                val name = (case.members["name"] as JsonString).value
                val origin = BotTurnOrigin.parse(rpcIdOf(case))
                assertEquals("$prefix/$name origin", (case.members["origin"] as JsonString).value, origin.kind.rawValue)
                assertEquals(
                    "$prefix/$name hidden",
                    (case.members["hidden"] as com.phonedsh.agentcore.JsonBool).value,
                    origin.hidden,
                )
                assertEquals(
                    "$prefix/$name held",
                    (case.members["held"] as com.phonedsh.agentcore.JsonBool).value,
                    origin.held,
                )
                assertEquals(
                    "$prefix/$name memorySource",
                    (case.members["memorySource"] as JsonString).value,
                    origin.memorySource.rawValue,
                )
            }
        }
        assertRows(valid, "valid")
        assertRows(invalid, "invalid")
    }

    @Test
    fun theKnownRowsProduceTheirDistinctDerivations() {
        assertEquals(BotTurnOriginKind.USER, BotTurnOrigin.parse("bot-abc").kind)
        assertEquals(BotTurnOriginKind.HELD, BotTurnOrigin.parse("held:d").kind)
        assertEquals(BotTurnOriginKind.AGENT, BotTurnOrigin.parse("agent:c").kind)
        assertEquals(BotTurnOriginKind.ROUTINE, BotTurnOrigin.parse("routine:run-1").kind)
        assertEquals(BotTurnOriginKind.TASK, BotTurnOrigin.parse("task-turn:t").kind)
        assertEquals(BotTurnOriginKind.TASK_WAKE, BotTurnOrigin.parse("task-settled:t").kind)
        assertEquals(BotTurnOriginKind.TASK_WAKE, BotTurnOrigin.parse("task-interrupted:t").kind)
        assertTrue(BotTurnOrigin.parse("routine:run-1").hidden)
        assertTrue(BotTurnOrigin.parse("task-turn:t").hidden)
        assertFalse(BotTurnOrigin.parse("held:d").hidden)
        assertTrue(BotTurnOrigin.parse("held:d").held)
        assertEquals(BotMemorySourceKind.USER_TURN, BotTurnOrigin.parse("bot-abc").memorySource)
        assertEquals(
            BotMemorySourceKind.HIDDEN_WAKE,
            BotTurnOrigin.parse("task-settled:t").memorySource,
        )
    }

    @Test
    fun sourceResolutionNeverTreatsMissingSourceAsHidden() {
        assertEquals(BotTurnOriginKind.UNKNOWN, BotTurnOrigin.from(null as Map<String, com.phonedsh.agentcore.JsonValue>?).kind)
        assertEquals(
            BotTurnOriginKind.UNKNOWN,
            BotTurnOrigin.from(JsonObject(emptyMap())).kind,
        )
        assertEquals(
            BotTurnOriginKind.ROUTINE,
            BotTurnOrigin.from(JsonObject(mapOf("rpcId" to JsonString("routine:r")))).kind,
        )
        assertEquals(
            BotTurnOriginKind.UNKNOWN,
            BotTurnOrigin.from(JsonObject(mapOf("rpcId" to JsonNull))).kind,
        )
    }

    @Test
    fun hostMintedRequestIdsUseTheFrozenPrefixes() {
        assertEquals("user-action:n1", BotTurnOrigin.userActionRequestId("n1"))
        assertEquals("card-answer:n1", BotTurnOrigin.cardAnswerRequestId("n1"))
        assertEquals("bot-abc", BotTurnOrigin.visibleRequestId("ABC"))
        assertEquals("held:digest", BotTurnOrigin.heldRequestId("digest"))
        assertEquals("agent:call", BotTurnOrigin.agentRequestId("call"))
        assertEquals("routine:run-1", BotTurnOrigin.routineRequestId("run-1"))
        assertEquals("task-turn:t", BotTurnOrigin.taskTurnRequestId("t"))
        assertEquals("task-settled:t", BotTurnOrigin.taskSettledRequestId("t"))
        assertEquals("task-interrupted:t", BotTurnOrigin.taskInterruptedRequestId("t"))
        assertEquals("n1", BotTurnOrigin.userActionNonce("user-action:n1"))
        assertNull(BotTurnOrigin.userActionNonce("user-action:"))
        assertNull(BotTurnOrigin.userActionNonce("routine:r"))
        assertNull(BotTurnOrigin.userActionNonce(null))
    }

    @Test
    fun authorityDescribesItsApprovalSource() {
        assertEquals(
            "由其他 Bot 的消息（agent:c）触发",
            BotTurnAuthority("agent:c", null, "s", BotTurnOriginKind.AGENT, false, null)
                .approvalSourceDescription,
        )
        assertEquals(
            "由带 held 块的回合触发",
            BotTurnAuthority(null, null, "s", BotTurnOriginKind.HELD, false).approvalSourceDescription,
        )
        assertEquals(
            "由用户回合触发",
            BotTurnAuthority(null, null, "s", BotTurnOriginKind.USER, true).approvalSourceDescription,
        )
    }
}
