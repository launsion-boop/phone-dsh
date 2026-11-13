// SPDX-License-Identifier: MIT
package com.phonedsh.bot.mcp

import com.phonedsh.agentcore.JsonArray
import com.phonedsh.agentcore.JsonBool
import com.phonedsh.agentcore.JsonNull
import com.phonedsh.agentcore.JsonObject
import com.phonedsh.agentcore.JsonString
import com.phonedsh.agentcore.JsonValue
import com.phonedsh.bot.BotJson
import com.phonedsh.bot.GoldenFixture
import com.phonedsh.bot.cards.BotCardPayloadException
import com.phonedsh.bot.cards.BotCardPayloads
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

/**
 * Card tools through the real MCP handler: the untouched `card-payload.json`
 * and `card-payload.phone.json` cases, the fixed ask_user/show_next_steps
 * text, `final` stripping/suppression and the P1 fail-closed rule.
 */
class BotMCPCardToolsTests {
    private val upstream: JsonObject = GoldenFixture.rawObject("card-payload")
    private val phone: JsonObject = GoldenFixture.rawObject("card-payload.phone")

    @Test
    fun everyUpstreamValidP0CardMatchesTheGoldenThroughTheHandler() = runBlocking {
        for ((index, raw) in (upstream.members["valid"] as JsonArray).values.withIndex()) {
            val case = raw as JsonObject
            val tool = (case.members["tool"] as JsonString).value
            val args = case.members["args"] as JsonObject
            if (tool !in BotToolCatalog.CARD_TOOL_NAMES) {
                assertP1Unknown(tool, args, "upstream valid[$index] $tool")
                continue
            }
            val result = executeCard(tool, args)
            val stripped = if (tool == "ask_user" || tool == "show_next_steps") {
                stripIds(result)
            } else {
                result
            }
            MCPTestSupport.assertSubset(
                case.members["result"],
                stripped.members["structuredContent"],
                "upstream valid[$index] $tool",
            )
        }
    }

    @Test
    fun everyPhoneValidCardMatchesTheGoldenThroughTheHandler() = runBlocking {
        for ((index, raw) in (phone.members["valid"] as JsonArray).values.withIndex()) {
            val case = raw as JsonObject
            val tool = (case.members["tool"] as JsonString).value
            val args = case.members["args"] as JsonObject
            val result = executeCard(tool, args)
            assertEquals(
                "phone valid[$index] $tool",
                BotJson.canonical(case.members["result"]!!),
                BotJson.canonical(result.members["structuredContent"]!!),
            )
            assertNull("$tool must strip final", cardOf(result).members["final"])
        }
    }

    @Test
    fun everyInvalidCardCaseFailsClosedWithTheGoldenSentence() = runBlocking {
        for ((index, raw) in phone.members["invalid"]!!.let { (it as JsonArray).values }.withIndex()) {
            val case = raw as JsonObject
            val tool = (case.members["tool"] as JsonString).value
            val args = case.members["args"] as JsonObject
            val expected = ((case.members["result"] as JsonObject).members["error"] as JsonString).value
            if (tool !in BotToolCatalog.CARD_TOOL_NAMES) {
                assertP1Unknown(tool, args, "phone invalid[$index] $tool")
                continue
            }
            val result = executeCard(tool, args)
            assertEquals(
                "phone invalid[$index] $tool",
                JsonBool(true),
                result.members["isError"],
            )
            assertEquals(
                "phone invalid[$index] $tool",
                "invalid_arguments",
                (errorOf(result).members["code"] as JsonString).value,
            )
            assertEquals(
                "phone invalid[$index] $tool",
                expected,
                (errorOf(result).members["message"] as JsonString).value,
            )
        }
    }

    @Test
    fun askUserAndShowNextStepsUseTheFixedSentencesAndEndTheTurn() = runBlocking {
        val harness = MCPHarness()
        val ask = executeCard(
            "ask_user",
            BotJson.objectOf(
                "question" to JsonString("继续吗？"),
                "options" to JsonArray(
                    listOf(
                        BotJson.objectOf("label" to JsonString("继续")),
                        BotJson.objectOf("label" to JsonString("停止")),
                    ),
                ),
            ),
            harness,
        )
        assertEquals(
            BotMCPToolRuntime.ASK_USER_TEXT,
            firstText(ask),
        )
        val next = executeCard(
            "show_next_steps",
            BotJson.objectOf(
                "steps" to JsonArray(listOf(JsonString("A"), JsonString("B"))),
            ),
            harness,
        )
        assertEquals(BotMCPToolRuntime.SHOW_NEXT_STEPS_TEXT, firstText(next))
        val principal = MCPTestSupport.principal()
        harness.attribution.register(
            "suppressed-send",
            "SendToUser",
            BotJson.objectOf("message" to JsonString("after a card")),
            principal,
        )
        val reply = harness.handler.rpc(
            method = "tools/call",
            params = BotJson.objectOf(
                "name" to JsonString("SendToUser"),
                "arguments" to BotJson.objectOf("message" to JsonString("after a card")),
            ),
            id = JsonString("suppressed-send"),
        )
        val result = reply.members["result"] as JsonObject
        assertEquals(JsonBool(true), result.members["isError"])
        assertEquals(
            "invalid_arguments",
            (errorOf(result).members["code"] as JsonString).value,
        )
        assertEquals(
            BotMCPToolRuntime.SEND_TO_USER_SUPPRESSED_MESSAGE,
            (errorOf(result).members["message"] as JsonString).value,
        )
    }

    @Test
    fun finalFalseDoesNotSuppressButFinalTrueDoes() = runBlocking {
        val harness = MCPHarness()
        val principal = MCPTestSupport.principal()
        val args = BotJson.objectOf(
            "title" to JsonString("Build"),
            "final" to JsonBool(false),
        )
        harness.attribution.register("card-false", "show_progress", args, principal)
        val first = cardReply(harness, "show_progress", args, "card-false")
        assertEquals(JsonBool(false), JsonBool(cardOf(first).members.containsKey("final")))
        // final:false leaves the turn able to send a message.
        val sendArgs = BotJson.objectOf("message" to JsonString("still allowed"))
        harness.attribution.register("send-false", "SendToUser", sendArgs, principal)
        val sent = harness.handler.rpc(
            method = "tools/call",
            params = BotJson.objectOf(
                "name" to JsonString("SendToUser"),
                "arguments" to sendArgs,
            ),
            id = JsonString("send-false"),
        )
        assertNull((sent.members["result"] as JsonObject).members["isError"])

        val finalHarness = MCPHarness()
        val finalArgs = BotJson.objectOf(
            "title" to JsonString("Build"),
            "final" to JsonBool(true),
        )
        finalHarness.attribution.register("card-true", "show_progress", finalArgs, principal)
        cardReply(finalHarness, "show_progress", finalArgs, "card-true")
        val blockedArgs = BotJson.objectOf("message" to JsonString("too late"))
        finalHarness.attribution.register("send-true", "SendToUser", blockedArgs, principal)
        val blocked = finalHarness.handler.rpc(
            method = "tools/call",
            params = BotJson.objectOf(
                "name" to JsonString("SendToUser"),
                "arguments" to blockedArgs,
            ),
            id = JsonString("send-true"),
        )
        assertEquals(
            BotMCPToolRuntime.SEND_TO_USER_SUPPRESSED_MESSAGE,
            (errorOf(blocked.members["result"] as JsonObject).members["message"] as JsonString).value,
        )
    }

    @Test
    fun aSuccessfulCardWritesTheDurableEventWithoutTheFinalFlag() = runBlocking {
        val harness = MCPHarness()
        val args = BotJson.objectOf(
            "title" to JsonString("Build"),
            "final" to JsonBool(true),
        )
        harness.attribution.register("card-event", "show_progress", args, MCPTestSupport.principal())
        cardReply(harness, "show_progress", args, "card-event")
        val event = harness.events.events.last { it.type == "card.presented" }
        val data = event.data as JsonObject
        assertEquals("show_progress", (data.members["tool"] as JsonString).value)
        assertEquals("card-event", (data.members["callId"] as JsonString).value)
        assertTrue((data.members["id"] as JsonString).value.startsWith("card-"))
        assertNotNull(data.members["card"])
        assertNull((data.members["card"] as JsonObject).members["final"])
    }

    @Test
    fun p1AndUnknownNamesAreNeverRegisteredOrBuilt() {
        for (name in BotToolCatalog.P1_TARGET_NAMES + listOf("no_such_tool")) {
            try {
                BotCardPayloads.build(name, JsonObject(emptyMap()))
                fail("$name must fail closed")
            } catch (error: BotCardPayloadException) {
                assertEquals("unknown or non-P0 card tool: $name", error.message)
            }
        }
        assertTrue(!BotToolCatalog.isRegistered("show_table"))
    }

    // ------------------------------------------------------------------
    // helpers
    // ------------------------------------------------------------------

    private suspend fun executeCard(
        tool: String,
        args: JsonObject,
        harness: MCPHarness = MCPHarness(),
    ): JsonObject {
        val principal = MCPTestSupport.principal()
        harness.attribution.register("card-$tool", tool, args, principal)
        val reply = harness.handler.rpc(
            method = "tools/call",
            params = BotJson.objectOf(
                "name" to JsonString(tool),
                "arguments" to args,
            ),
            id = JsonString("card-$tool"),
        )
        val error = reply.members["error"]
        if (error != null) throw AssertionError("$tool returned JSON-RPC error: $reply")
        return reply.members["result"] as JsonObject
    }

    private suspend fun cardReply(
        harness: MCPHarness,
        tool: String,
        args: JsonObject,
        callId: String,
    ): JsonObject {
        val reply = harness.handler.rpc(
            method = "tools/call",
            params = BotJson.objectOf(
                "name" to JsonString(tool),
                "arguments" to args,
            ),
            id = JsonString(callId),
        )
        return reply.members["result"] as JsonObject
    }

    private suspend fun assertP1Unknown(tool: String, args: JsonObject, label: String) {
        val harness = MCPHarness()
        val reply = harness.handler.rpc(
            method = "tools/call",
            params = BotJson.objectOf(
                "name" to JsonString(tool),
                "arguments" to args,
            ),
            id = JsonString("p1-$tool"),
        )
        val result = reply.members["result"] as JsonObject
        assertEquals(label, JsonBool(true), result.members["isError"])
        assertEquals(label, "unknown_tool", (errorOf(result).members["code"] as JsonString).value)
    }

    private fun cardOf(result: JsonObject): JsonObject {
        val structured = result.members["structuredContent"] as JsonObject
        return structured.members["card"] as JsonObject
    }

    private fun errorOf(result: JsonObject): JsonObject {
        val structured = result.members["structuredContent"] as JsonObject
        return structured.members["error"] as JsonObject
    }

    private fun firstText(result: JsonObject): String {
        val content = result.members["content"] as JsonArray
        return ((content.values.first() as JsonObject).members["text"] as JsonString).value
    }

    private fun stripIds(result: JsonObject): JsonObject {
        val structured = result.members["structuredContent"] as JsonObject
        val card = structured.members["card"] as JsonObject
        val cardCopy = LinkedHashMap(card.members)
        for (key in listOf("options", "steps")) {
            val values = (cardCopy[key] as? JsonArray)?.values ?: continue
            cardCopy[key] = JsonArray(values.map { value ->
                val fields = LinkedHashMap((value as JsonObject).members)
                fields.remove("id")
                JsonObject(fields)
            })
        }
        val structuredCopy = LinkedHashMap(structured.members)
        structuredCopy["card"] = JsonObject(cardCopy)
        val resultCopy = LinkedHashMap(result.members)
        resultCopy["structuredContent"] = JsonObject(structuredCopy)
        return JsonObject(resultCopy)
    }
}
