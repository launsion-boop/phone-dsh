// SPDX-License-Identifier: MIT
package com.phonedsh.bot.mcp

import com.phonedsh.agentcore.JsonArray
import com.phonedsh.agentcore.JsonBool
import com.phonedsh.agentcore.JsonNull
import com.phonedsh.agentcore.JsonNumber
import com.phonedsh.agentcore.JsonObject
import com.phonedsh.agentcore.JsonString
import com.phonedsh.agentcore.JsonValue
import com.phonedsh.bot.BotJson
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Handler boundaries not carried by a fixture case, plus the phone card defaults. */
class BotMCPHandlerEdgeCasesTests {
    @Test
    fun initializeHasExactlyTheFrozenShape() = runBlocking {
        val harness = MCPHarness()
        val reply = harness.handler.rpc(
            method = "initialize",
            params = BotJson.objectOf("protocolVersion" to JsonString("2025-03-26")),
            id = JsonNumber("1"),
        )
        val result = reply.members["result"] as JsonObject
        assertEquals(
            setOf("protocolVersion", "capabilities", "serverInfo"),
            result.members.keys,
        )
        assertEquals(JsonString("2025-03-26"), result.members["protocolVersion"])
        assertEquals(
            BotJson.objectOf("tools" to JsonObject(emptyMap())),
            result.members["capabilities"],
        )
        assertEquals(
            BotJson.objectOf(
                "name" to JsonString("phone"),
                "version" to JsonString("1.0.0"),
            ),
            result.members["serverInfo"],
        )
    }

    @Test
    fun initializeDropsAnEmptyNativeInstructionsString() = runBlocking {
        val emptyNative = FixtureNativeForwarder(
            BotJson.objectOf(
                "instructions" to JsonString(""),
                "tools" to JsonArray(emptyList()),
            ),
        )
        val harness = MCPHarness(native = emptyNative)
        val reply = harness.handler.rpc(
            method = "initialize",
            params = JsonObject(emptyMap()),
            id = JsonNumber("1"),
        )
        val result = reply.members["result"] as JsonObject
        assertNull(result.members["instructions"])
    }

    @Test
    fun callerHeaderIsCaseInsensitiveTrimmedAndUnknownFallsBackToStatic() = runBlocking {
        val harness = MCPHarness()
        harness.tokenPort.sessions["gb-restricted"] = MCPTestSupport.principal(
            botId = "restricted",
            sessionId = "gb-restricted",
        )
        val restricted = harness.handler.rpc(
            method = "tools/list",
            id = JsonNumber("1"),
            headers = mapOf("X-PDSH-Bot-Session" to " gb-restricted "),
        )
        assertEquals(21, MCPTestSupport.toolNames(restricted).size)
        assertFalse(MCPTestSupport.toolNames(restricted).contains("CreateTeammate"))

        val unknown = harness.handler.rpc(
            method = "tools/list",
            id = JsonNumber("2"),
            headers = mapOf(BotMCPProtocol.CALLER_SESSION_HEADER to "gb-unknown"),
        )
        assertEquals(22, MCPTestSupport.toolNames(unknown).size)
        assertTrue(MCPTestSupport.toolNames(unknown).contains("CreateTeammate"))

        val empty = harness.handler.rpc(
            method = "tools/list",
            id = JsonNumber("3"),
            headers = mapOf(BotMCPProtocol.CALLER_SESSION_HEADER to "   "),
        )
        assertEquals(22, MCPTestSupport.toolNames(empty).size)
    }

    @Test
    fun notificationsAreNeverForwardedToNative() = runBlocking {
        val native = FixtureNativeForwarder(
            BotJson.objectOf(
                "instructions" to JsonString(""),
                "tools" to JsonArray(emptyList()),
            ),
        )
        val harness = MCPHarness(native = native)
        val notification = BotJson.objectOf(
            "jsonrpc" to JsonString("2.0"),
            "method" to JsonString("notifications/initialized"),
        )
        val result = harness.handler.dispatch(notification)
        assertEquals(202, result.status)
        assertTrue(result.emptyBody)
        assertTrue(native.seenMethods.isEmpty())
    }

    @Test
    fun aSecondToolsCallWithTheSameArgumentsIsUnattributed() = runBlocking {
        val harness = MCPHarness()
        val args = BotJson.objectOf("query" to JsonString("x"))
        harness.attribution.register(
            "once",
            "RecallMemory",
            args,
            MCPTestSupport.principal(),
        )
        val params = BotJson.objectOf(
            "name" to JsonString("RecallMemory"),
            "arguments" to args,
        )
        val first = harness.handler.rpc("tools/call", params, JsonString("once"))
        assertNull((first.members["result"] as JsonObject).members["isError"])
        val second = harness.handler.rpc("tools/call", params, JsonString("once"))
        val result = second.members["result"] as JsonObject
        assertEquals(JsonBool(true), result.members["isError"])
        val error = (result.members["structuredContent"] as JsonObject).members["error"] as JsonObject
        assertEquals("unattributed", (error.members["code"] as JsonString).value)
    }

    @Test
    fun catalogEncodingFailureIsToolCatalogEncodingFailed() = runBlocking {
        val failing = BotMCPToolCatalogProvider { throw IllegalStateException("boom") }
        val harness = MCPHarness(catalogProvider = failing)
        val reply = harness.handler.rpc("tools/list", id = JsonString("list"))
        val error = reply.members["error"] as JsonObject
        assertEquals(
            JsonNumber("-32603"),
            error.members["code"],
        )
        assertEquals(
            JsonString(BotMCPProtocol.MESSAGE_TOOL_CATALOG_ENCODING),
            error.members["message"],
        )
    }

    @Test
    fun unknownToolEncodingFallbackIsInvalidParams() = runBlocking {
        val throwingEncoder: (BotMCPCallResult) -> JsonValue = {
            throw IllegalStateException("cannot encode")
        }
        val harness = MCPHarness(resultEncoder = throwingEncoder)
        val reply = harness.handler.rpc(
            method = "tools/call",
            params = BotJson.objectOf(
                "name" to JsonString("nope"),
                "arguments" to JsonObject(emptyMap()),
            ),
            id = JsonString("unknown"),
        )
        val error = reply.members["error"] as JsonObject
        assertEquals(JsonNumber("-32602"), error.members["code"])
        assertEquals(JsonString("unknown tool: nope"), error.members["message"])
    }

    @Test
    fun cardFacadeFixesThePhoneDocumentDefaults() = runBlocking {
        val noHeading = executeCard(
            "show_document",
            BotJson.objectOf("content" to JsonString("plain prose")),
        )
        assertEquals(JsonString("文档"), card(noHeading).members["title"])
        assertEquals(JsonString("Markdown"), card(noHeading).members["docTypeLabel"])

        val table = executeCard(
            "show_document",
            BotJson.objectOf(
                "path" to JsonString("/tmp/books.csv"),
                "kind" to JsonString("table"),
            ),
        )
        assertEquals(JsonString("表格"), card(table).members["docTypeLabel"])

        val pdf = executeCard(
            "show_document",
            BotJson.objectOf("path" to JsonString("/tmp/report.PDF")),
        )
        assertEquals(JsonString("PDF"), card(pdf).members["docTypeLabel"])
    }

    @Test
    fun cardFacadeUsesTheFrozenPercentAndTocAndLinkSentences() = runBlocking {
        val percent = executeCard(
            "show_progress",
            BotJson.objectOf(
                "title" to JsonString("Build"),
                "percent" to JsonNumber("1.5"),
            ),
        )
        assertEquals(JsonBool(true), percent.members["isError"])
        assertEquals(
            JsonString("percent 必须在 0…100。"),
            error(percent).members["message"],
        )
        val toc = executeCard(
            "show_document",
            BotJson.objectOf(
                "content" to JsonString("# x"),
                "toc" to JsonArray(listOf(JsonString("   "))),
            ),
        )
        assertEquals(JsonString("toc 必须是字符串数组。"), error(toc).members["message"])
        val links = executeCard(
            "show_link",
            BotJson.objectOf("links" to JsonString("not-an-array")),
        )
        assertEquals(
            JsonString("show_link 最多 4 个 links。"),
            error(links).members["message"],
        )
    }


    @Test
    fun cardFinalIsValidatedBeforeToolSpecificFields() = runBlocking {
        val links = executeCard(
            "show_link",
            BotJson.objectOf(
                "links" to JsonArray(
                    (1..5).map { JsonString("https://example.test/$it") },
                ),
                "final" to JsonString("yes"),
            ),
        )
        assertEquals(JsonString("final 必须是 boolean。"), error(links).members["message"])
        val progress = executeCard(
            "show_progress",
            BotJson.objectOf(
                "title" to JsonString("Build"),
                "percent" to JsonNumber("101"),
                "final" to JsonString("yes"),
            ),
        )
        assertEquals(JsonString("final 必须是 boolean。"), error(progress).members["message"])
    }

    @Test
    fun doneProgressForcesOneHundredPercent() = runBlocking {
        val result = executeCard(
            "show_progress",
            BotJson.objectOf(
                "title" to JsonString("Build"),
                "state" to JsonString("done"),
                "percent" to JsonNumber("10"),
            ),
        )
        assertEquals(JsonNumber("100"), card(result).members["percent"])
    }

    @Test
    fun volatileToolUsesTheProducerRevisionAndCrossSessionRule() = runBlocking {
        val harness = MCPHarness()
        val principal = MCPTestSupport.principal()
        val args = BotJson.objectOf("sessionId" to JsonString("gb-main"))
        harness.attribution.register("volatile-1", "BotVolatileContext", args, principal)
        val first = harness.handler.rpc(
            "tools/call",
            BotJson.objectOf(
                "name" to JsonString("BotVolatileContext"),
                "arguments" to args,
            ),
            JsonString("volatile-1"),
        )
        val firstStructured = (first.members["result"] as JsonObject).members["structuredContent"]
            as JsonObject
        assertEquals(JsonNumber("1"), firstStructured.members["schemaVersion"])
        assertEquals(JsonNumber("1"), firstStructured.members["revision"])

        harness.attribution.register("volatile-2", "BotVolatileContext", args, principal)
        val second = harness.handler.rpc(
            "tools/call",
            BotJson.objectOf(
                "name" to JsonString("BotVolatileContext"),
                "arguments" to args,
            ),
            JsonString("volatile-2"),
        )
        val secondStructured = (second.members["result"] as JsonObject).members["structuredContent"]
            as JsonObject
        assertEquals(JsonNumber("2"), secondStructured.members["revision"])

        val crossArgs = BotJson.objectOf("sessionId" to JsonString("gb-other"))
        harness.attribution.register("volatile-cross", "BotVolatileContext", crossArgs, principal)
        val cross = harness.handler.rpc(
            "tools/call",
            BotJson.objectOf(
                "name" to JsonString("BotVolatileContext"),
                "arguments" to crossArgs,
            ),
            JsonString("volatile-cross"),
        )
        val crossError = error(cross.members["result"] as JsonObject)
        assertEquals(JsonString("cross_session_read_denied"), crossError.members["code"])
    }


    @Test
    fun emptyVolatileProviderReturnsEmptyBlocksAndConsumesRevision() = runBlocking {
        val producer = BotVolatileContextProducer(
            BotVolatileContextProviding { _, _, _ -> BotVolatileBlocks(memory = "") },
        )
        val principal = MCPTestSupport.principal()
        val snapshot = producer.snapshot(
            BotJson.objectOf("sessionId" to JsonString("gb-main")),
            principal,
        )
        assertEquals(JsonNumber("1"), snapshot.toJson().members["revision"])
        assertTrue(
            (snapshot.toJson().members["blocks"] as JsonObject).members.isEmpty(),
        )
        assertEquals(1, producer.currentRevision)
    }

    // ------------------------------------------------------------------

    private suspend fun executeCard(tool: String, args: JsonObject): JsonObject {
        val harness = MCPHarness()
        harness.attribution.register("edge-$tool", tool, args, MCPTestSupport.principal())
        val reply = harness.handler.rpc(
            "tools/call",
            BotJson.objectOf("name" to JsonString(tool), "arguments" to args),
            JsonString("edge-$tool"),
        )
        return reply.members["result"] as JsonObject
    }

    private fun card(result: JsonObject): JsonObject {
        val structured = result.members["structuredContent"] as JsonObject
        return structured.members["card"] as JsonObject
    }

    private fun error(result: JsonObject): JsonObject {
        val structured = result.members["structuredContent"] as JsonObject
        return structured.members["error"] as JsonObject
    }
}
