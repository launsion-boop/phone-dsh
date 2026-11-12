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
import com.phonedsh.bot.GoldenFixture
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * D13 P0 tool contracts: every valid/invalid/denial/unknown case from
 * `tool-call-cases.phone.json` runs through the real `BotMCPHandler`, the real
 * card builder and the real volatile producer. Memory, routines, tasks,
 * approval and the UI are host ports with in-test fakes; the MCP argument
 * validation and the `BotMCPCallResult` envelope are the production code.
 */
class BotMCPToolCallCasesTests {
    private val vector: JsonObject = GoldenFixture.rawObject("tool-call-cases.phone")

    @Test
    fun fixtureMetadataCoversEveryP0Tool() {
        assertEquals("tool-call-cases.phone", (vector.members["vector"] as JsonString).value)
        assertEquals(JsonArray(emptyList()), vector.members["upstream"])
        val tools = (vector.members["tools"] as JsonArray).values.map { (it as JsonString).value }
        assertEquals(BotToolCatalog.P0_NAMES, tools)
        val valid = (vector.members["valid"] as JsonArray).values.map { it as JsonObject }
        val invalid = (vector.members["invalid"] as JsonArray).values.map { it as JsonObject }
        val denials = (vector.members["denials"] as JsonArray).values.map { it as JsonObject }
        assertEquals(tools.toSet(), valid.map { (it.members["tool"] as JsonString).value }.toSet())
        assertEquals(tools.toSet(), denials.map { (it.members["tool"] as JsonString).value }.toSet())
        for (tool in tools) {
            if (tool == "ListRoutines") continue
            assertTrue(
                "missing invalid case for $tool",
                invalid.any { (it.members["tool"] as JsonString).value == tool },
            )
        }
        assertTrue((vector.members["unknown"] as JsonArray).values.isNotEmpty())
    }

    @Test
    fun everyValidInvalidDenialAndUnknownCaseRunsThroughTheRealHandler() = runBlocking {
        for ((index, raw) in (vector.members["valid"] as JsonArray).values.withIndex()) {
            runCase(raw as JsonObject, "valid[$index]", deny = false)
        }
        for ((index, raw) in (vector.members["invalid"] as JsonArray).values.withIndex()) {
            runCase(raw as JsonObject, "invalid[$index]", deny = false)
        }
        for ((index, raw) in (vector.members["denials"] as JsonArray).values.withIndex()) {
            runCase(raw as JsonObject, "denials[$index]", deny = true)
        }
        for ((index, raw) in (vector.members["unknown"] as JsonArray).values.withIndex()) {
            runCase(raw as JsonObject, "unknown[$index]", deny = false)
        }
    }

    private suspend fun runCase(case: JsonObject, prefix: String, deny: Boolean) {
        val name = (case.members["name"] as JsonString).value
        val label = "$prefix $name"
        val tool = (case.members["tool"] as JsonString).value
        val setup = case.members["setup"] as JsonObject
        val principal = MCPTestSupport.principal(
            botId = (setup.members["botId"] as JsonString).value,
            sessionId = (setup.members["sessionId"] as JsonString).value,
            kind = (setup.members["kind"] as? JsonString)?.value ?: "chat",
            capabilities = (setup.members["capabilities"] as? JsonArray)?.values
                ?.map { (it as JsonString).value }?.toSet() ?: emptySet(),
        )
        val harness = makeHarness(deny, tool)
        for (doc in (setup.members["seedMemory"] as? JsonArray)?.values ?: emptyList()) {
            val fields = (doc as JsonObject).members
            harness.memory.seed(
                (fields["path"] as JsonString).value,
                (fields["content"] as JsonString).value,
            )
        }
        for (routine in (setup.members["seedRoutines"] as? JsonArray)?.values ?: emptyList()) {
            val fields = (routine as JsonObject).members
            harness.routines.seed(
                (fields["title"] as JsonString).value,
                (fields["prompt"] as JsonString).value,
                (fields["schedule"] as JsonString).value,
            )
        }
        val turn = (setup.members["turn"] as? JsonString)?.value
        var arguments = case.members["arguments"] ?: JsonObject(emptyMap())
        if ((case.members["createTask"] as? JsonBool)?.value == true) {
            val seedArguments = BotJson.objectOf(
                "task_title" to JsonString("Seed"),
                "task_description" to JsonString("seed task"),
                "async" to JsonBool(true),
            )
            harness.attribution.register("seed-task", "Task", seedArguments, principal)
            val seed = harness.handler.rpc(
                method = "tools/call",
                params = BotJson.objectOf(
                    "name" to JsonString("Task"),
                    "arguments" to seedArguments,
                ),
                id = JsonString("seed-task"),
            )
            val seedResult = seed.members["result"] as JsonObject
            val structured = seedResult.members["structuredContent"] as JsonObject
            val taskId = (structured.members["task_id"] as JsonString).value
            arguments = substitutingTaskId(arguments, taskId)
        }
        if ((case.members["skipRegistration"] as? JsonBool)?.value != true) {
            val callId = "case-$name"
            harness.attribution.register(
                callId = callId,
                tool = tool,
                arguments = arguments,
                principal = principal,
                isUserTurn = turn != "hidden",
                hiddenTurn = turn == "hidden",
            )
        }
        val request = BotJson.objectOf(
            "name" to JsonString(tool),
            "arguments" to arguments,
        )
        val reply = harness.handler.rpc(
            method = "tools/call",
            params = request,
            id = JsonString("case-$name"),
        )
        val expect = case.members["expect"] as JsonObject
        if ((case.members["layer"] as? JsonString)?.value == "rpc") {
            val error = reply.members["error"] as? JsonObject
            assertNotNull("$label: expected a JSON-RPC error", error)
            assertEquals(
                label,
                (expect.members["rpcError"] as JsonNumber).asLongOrNull()!!.toInt(),
                (error!!.members["code"] as JsonNumber).asLongOrNull()!!.toInt(),
            )
            (expect.members["message"] as? JsonString)?.value?.let {
                assertEquals(label, it, (error.members["message"] as JsonString).value)
            }
            return
        }
        val result = reply.members["result"] as? JsonObject
            ?: throw AssertionError("$label: missing result: $reply")
        assertResult(label, result, expect)
    }

    private fun makeHarness(deny: Boolean, tool: String): MCPHarness {
        val base = MCPTestSupport.catalog()
        val provider = BotMCPToolCatalogProvider { caller ->
            base.definitions(caller).filterNot {
                deny && caller == "restricted" && it.name == tool
            }
        }
        return MCPHarness(catalog = base, catalogProvider = provider)
    }

    private fun assertResult(label: String, result: JsonObject, expect: JsonObject) {
        val expectedError = (expect.members["isError"] as? JsonBool)?.value == true
        if (expectedError) {
            assertEquals("$label: expected isError true", JsonBool(true), result.members["isError"])
            val code = (expect.members["errorCode"] as? JsonString)?.value
            assertNotNull("$label: missing errorCode", code)
            val structured = result.members["structuredContent"] as JsonObject
            val error = structured.members["error"] as JsonObject
            assertEquals(label, code, (error.members["code"] as JsonString).value)
            (expect.members["messageContains"] as? JsonString)?.value?.let { contains ->
                val message = (error.members["message"] as JsonString).value
                assertTrue(
                    "$label: message $message does not contain $contains",
                    message.contains(contains),
                )
            }
        } else {
            assertNull(
                "$label: success must omit isError; result=$result",
                result.members["isError"],
            )
        }
        val structured = expect.members["structured"]
        if (structured != null) {
            MCPTestSupport.assertSubset(
                structured,
                result.members["structuredContent"],
                "$label.structured",
            )
        }
    }

    private fun substitutingTaskId(value: JsonValue, taskId: String): JsonValue = when (value) {
        is JsonString -> if (value.value == "\$taskId") JsonString(taskId) else value
        is JsonArray -> JsonArray(value.values.map { substitutingTaskId(it, taskId) })
        is JsonObject -> JsonObject(
            value.members.mapValues { substitutingTaskId(it.value, taskId) },
        )
        else -> value
    }
}
