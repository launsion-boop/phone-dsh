// SPDX-License-Identifier: MIT
package com.phonedsh.bot.mcp

import com.phonedsh.agentcore.JsonArray
import com.phonedsh.agentcore.JsonBool
import com.phonedsh.agentcore.JsonNull
import com.phonedsh.agentcore.JsonNumber
import com.phonedsh.agentcore.JsonObject
import com.phonedsh.agentcore.JsonString
import com.phonedsh.bot.BotJson
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** The frozen result/message/identity shapes of §7 and §8. */
class BotMCPTypesTests {
    @Test
    fun successContentTextIsTheCanonicalStructuredContent() {
        val structured = BotJson.objectOf(
            "z" to JsonString("last"),
            "a" to JsonNumber("1"),
        )
        val result = BotMCPCallResult.success(structured).toJson()
        assertEquals(setOf("content", "structuredContent"), result.members.keys)
        val text = ((result.members["content"] as JsonArray).values.first() as JsonObject)
            .members["text"] as JsonString
        assertEquals("""{"a":1,"z":"last"}""", text.value)
        assertNull(result.members["isError"])
    }

    @Test
    fun failureContentTextEqualsTheErrorMessageAndIsErrorIsTrue() {
        val result = BotMCPCallResult.failure("unknown_tool", "Unknown tool: nope").toJson()
        assertEquals(JsonBool(true), result.members["isError"])
        val block = (result.members["content"] as JsonArray).values.first() as JsonObject
        assertEquals(JsonString("text"), block.members["type"])
        assertEquals(JsonString("Unknown tool: nope"), block.members["text"])
        val structured = result.members["structuredContent"] as JsonObject
        assertEquals(JsonBool(false), structured.members["ok"])
        val error = structured.members["error"] as JsonObject
        assertEquals(JsonString("unknown_tool"), error.members["code"])
        assertEquals(JsonString("Unknown tool: nope"), error.members["message"])
    }

    @Test
    fun idPresentIsARequestEvenWhenNullAndIdAbsentIsANotification() {
        val request = BotMCPMessages.parse(
            BotJson.objectOf(
                "jsonrpc" to JsonString("2.0"),
                "id" to JsonNull,
                "method" to JsonString("ping"),
            ),
        )
        assertTrue(request is BotMCPMessages.Request)
        assertEquals(JsonNull, (request as BotMCPMessages.Request).id)

        val notification = BotMCPMessages.parse(
            BotJson.objectOf(
                "jsonrpc" to JsonString("2.0"),
                "method" to JsonString("notifications/initialized"),
            ),
        )
        assertTrue(notification is BotMCPMessages.Notification)
        assertNull(
            BotMCPMessages.parse(
                BotJson.objectOf("id" to JsonNumber("1"), "method" to JsonNumber("2")),
            ),
        )
    }

    @Test
    fun identityRegistrationParsesTheFrozenBodyShape() {
        val parsed = BotIdentityRegistration.fromJson(
            BotJson.objectOf(
                "runtimeId" to JsonString("phone-worker"),
                "sessionId" to JsonString("gb-main"),
                "callId" to JsonString("call-1"),
                "name" to JsonString("mcp__phone__ListRoutines"),
                "arguments" to JsonObject(emptyMap()),
                "argsDigest" to JsonString("a".repeat(64)),
                "sessionToken" to JsonString("dshg_x"),
            ),
        )
        assertNotNull(parsed)
        assertEquals("phone-worker", parsed!!.runtimeId)
        assertEquals("call-1", parsed.callId)
        assertNull(
            BotIdentityRegistration.fromJson(
                BotJson.objectOf("runtimeId" to JsonString("phone-worker")),
            ),
        )
    }

    @Test
    fun approvalRequestParsesDefaultsAndRequiredMembers() {
        val parsed = BotApprovalRequest.fromJson(
            BotJson.objectOf(
                "sessionId" to JsonString("gb-main"),
                "callId" to JsonString("call-1"),
                "tool" to JsonString("bash"),
                "argsDigest" to JsonString("a".repeat(64)),
                "alwaysScope" to JsonString("none"),
            ),
        )
        assertNotNull(parsed)
        assertEquals("bash", parsed!!.action)
        assertEquals("", parsed.detail)
        assertEquals("", parsed.command)
        assertEquals("tool-call", parsed.askAction)
        assertTrue(parsed.effects.isEmpty())
        assertNull(
            BotApprovalRequest.fromJson(
                BotJson.objectOf(
                    "sessionId" to JsonString("gb-main"),
                    "callId" to JsonString("call-1"),
                    "tool" to JsonString("bash"),
                    "alwaysScope" to JsonString("none"),
                ),
            ),
        )
    }

    @Test
    fun pathHelpersStripOnlyTheMcpServerPrefix() {
        assertEquals("ask_user", bareToolName("mcp__phone__ask_user"))
        assertEquals("c", bareToolName("mcp__a__b__c"))
        assertEquals("ask_user", bareToolName("ask_user"))
        assertEquals("native_echo", bareToolName("native_echo"))
    }

    @Test
    fun listRoutinesIgnoresUnknownMembersPerPcRuling7() = runBlocking {
        val harness = MCPHarness()
        val args = BotJson.objectOf(
            "unknown_member" to JsonString("ignored"),
            "limit" to JsonNumber("999"),
        )
        harness.attribution.register("list-extra", "ListRoutines", args, MCPTestSupport.principal())
        val reply = harness.handler.rpc(
            "tools/call",
            BotJson.objectOf(
                "name" to JsonString("ListRoutines"),
                "arguments" to args,
            ),
            JsonString("list-extra"),
        )
        val result = reply.members["result"] as JsonObject
        assertNull(result.members["isError"])
        val structured = result.members["structuredContent"] as JsonObject
        assertEquals(JsonNumber("0"), structured.members["count"])
    }
}
