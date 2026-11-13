// SPDX-License-Identifier: MIT
package com.phonedsh.bot.mcp

import com.phonedsh.agentcore.JsonArray
import com.phonedsh.agentcore.JsonNull
import com.phonedsh.agentcore.JsonNumber
import com.phonedsh.agentcore.JsonObject
import com.phonedsh.agentcore.JsonString
import com.phonedsh.agentcore.JsonValue
import com.phonedsh.bot.BotJson
import com.phonedsh.bot.GoldenFixture
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

/**
 * D13 JSON-RPC contract: every `transport: single|batch|notification` case
 * from `mcp-rpc-cases.phone.json` drives the real `BotMCPHandler`, the real
 * catalog built from the two tool-catalog vectors and the real dispatcher.
 * The `transport: http` cases belong to B5b's listener (§11) and are counted
 * at the end so the fixture cannot silently lose them.
 */
class BotMCPRPCCasesTests {
    private val vector: JsonObject = GoldenFixture.rawObject("mcp-rpc-cases.phone")

    @Test
    fun fixtureMetadataMatchesTheFrozenProtocolConstants() {
        assertEquals("mcp-rpc-cases.phone", (vector.members["vector"] as JsonString).value)
        assertEquals(JsonArray(emptyList()), vector.members["upstream"])
        assertEquals(
            JsonNumber(BotMCPProtocol.MAXIMUM_BODY_BYTES.toString()),
            vector.members["maximumBodyBytes"],
        )
        val versions = (vector.members["protocolVersions"] as JsonArray).values
            .map { (it as JsonString).value }
        assertEquals(BotMCPProtocol.PROTOCOL_VERSIONS, versions)
        assertTrue((vector.members["valid"] as JsonArray).values.isNotEmpty())
        assertTrue((vector.members["invalid"] as JsonArray).values.isNotEmpty())
    }

    @Test
    fun everyValidSingleCaseDrivesTheRealHandler() = runBlocking {
        val native = vector.members["native"] as JsonObject
        for ((index, raw) in (vector.members["valid"] as JsonArray).values.withIndex()) {
            val case = raw as JsonObject
            val name = (case.members["name"] as JsonString).value
            val label = "valid[$index] $name"
            when ((case.members["transport"] as JsonString).value) {
                "single" -> runSingle(case, label, native)
                else -> Unit
            }
        }
    }

    @Test
    fun everyValidBatchAndNotificationCaseDrivesTheDispatcher() = runBlocking {
        val native = vector.members["native"] as JsonObject
        for ((index, raw) in (vector.members["valid"] as JsonArray).values.withIndex()) {
            val case = raw as JsonObject
            val name = (case.members["name"] as JsonString).value
            val label = "valid[$index] $name"
            when ((case.members["transport"] as JsonString).value) {
                "batch" -> runBatch(case, label, native)
                "notification" -> runNotification(case, label, native)
                else -> Unit
            }
        }
    }

    @Test
    fun invalidSingleAndBatchCasesMatchTheFrozenErrors() = runBlocking {
        for ((index, raw) in (vector.members["invalid"] as JsonArray).values.withIndex()) {
            val case = raw as JsonObject
            val name = (case.members["name"] as JsonString).value
            val label = "invalid[$index] $name"
            when ((case.members["transport"] as JsonString).value) {
                "single" -> runInvalidSingle(case, label)
                "batch" -> runInvalidBatch(case, label)
                else -> Unit
            }
        }
    }

    @Test
    fun theHttpCasesStayWithB5bAndAreNotSilentlyDropped() {
        val http = (vector.members["invalid"] as JsonArray).values
            .map { it as JsonObject }
            .filter { (it.members["transport"] as JsonString).value == "http" }
        assertEquals(12, http.size)
        for (case in http) {
            val httpCase = case.members["http"] as JsonObject
            val expect = case.members["expect"] as JsonObject
            assertNotNull((case.members["name"] as JsonString).value)
            assertNotNull((httpCase.members["path"] as? JsonString)?.value ?: "/mcp")
            assertNotNull(expect.members["status"])
        }
    }

    // ------------------------------------------------------------------
    // single / batch / notification
    // ------------------------------------------------------------------

    private suspend fun runSingle(case: JsonObject, label: String, native: JsonObject) {
        val harness = harness(native)
        val request = case.members["request"] as JsonObject
        var headers = emptyMap<String, String>()
        val caller = case.members["caller"] as? JsonObject
        if (caller != null) {
            val principal = principalFrom(caller)
            harness.tokenPort.sessions[principal.sessionId] = principal
            val sessionId = (caller.members["sessionId"] as JsonString).value
            headers = headers + (BotMCPProtocol.CALLER_SESSION_HEADER to sessionId)
            val registration = case.members["registration"] as? JsonObject
            if (registration != null) {
                harness.attribution.register(
                    callId = (registration.members["callId"] as JsonString).value,
                    tool = (registration.members["tool"] as JsonString).value,
                    arguments = registration.members["arguments"] ?: JsonObject(emptyMap()),
                    principal = principal,
                )
            }
        }
        val extraHeaders = case.members["headers"] as? JsonObject
        if (extraHeaders != null) {
            headers = headers + extraHeaders.members.mapValues { (it.value as JsonString).value }
        }
        val reply = harness.handler.rpc(
            method = (request.members["method"] as JsonString).value,
            params = request.members["params"] ?: JsonObject(emptyMap()),
            id = request.members["id"] ?: JsonNull,
            headers = headers,
        )
        val expect = case.members["expect"] as JsonObject
        val error = expect.members["error"]
        if (error != null) {
            val expectedCode = (error as JsonObject).members["code"] as JsonNumber
            val actualError = reply.members["error"] as JsonObject
            assertEquals(label, expectedCode, actualError.members["code"])
            return
        }
        val toolList = expect.members["toolList"]
        if (toolList != null) {
            MCPTestSupport.assertToolList(reply, toolList, label)
        }
        val expectedResult = expect.members["result"]
        if (expectedResult != null) {
            val actualResult = reply.members["result"]
            assertNotNull("$label: missing result: $reply", actualResult)
            MCPTestSupport.assertSubset(expectedResult, actualResult, label)
            val flags = (expect.members["flags"] as? JsonObject)?.members ?: emptyMap()
            if ((flags["isErrorAbsent"] as? com.phonedsh.agentcore.JsonBool)?.value == true) {
                assertNull("$label: success must omit isError", (actualResult as JsonObject).members["isError"])
            }
            if ((flags["contentTextJSON"] as? com.phonedsh.agentcore.JsonBool)?.value == true) {
                val resultObject = actualResult as JsonObject
                val content = (resultObject.members["content"] as JsonArray).values
                val text = ((content.first() as JsonObject).members["text"] as JsonString).value
                assertEquals(
                    label,
                    BotJson.canonical(resultObject.members["structuredContent"]!!),
                    BotJson.canonical(JsonValue.parse(text)),
                )
            }
        }
    }

    private suspend fun runBatch(case: JsonObject, label: String, native: JsonObject) {
        val harness = harness(native)
        val messages = JsonArray((case.members["messages"] as JsonArray).values)
        val response = harness.handler.dispatch(messages)
        val expect = case.members["expect"] as JsonObject
        assertEquals(
            label,
            (expect.members["status"] as JsonNumber).asLongOrNull()!!.toInt(),
            response.status,
        )
        if ((expect.members["empty"] as? com.phonedsh.agentcore.JsonBool)?.value == true) {
            assertTrue("$label: expected an empty body", response.emptyBody)
            return
        }
        val replies = (response.body as JsonArray).values
        assertEquals(
            label,
            (expect.members["replyCount"] as JsonNumber).asLongOrNull()!!.toInt(),
            replies.size,
        )
        (expect.members["ids"] as? JsonArray)?.values?.let { ids ->
            assertEquals(
                label,
                ids.map { (it as JsonNumber).asLongOrNull()!!.toInt() },
                replies.map {
                    ((it as JsonObject).members["id"] as JsonNumber).asLongOrNull()!!.toInt()
                },
            )
        }
        (expect.members["firstResult"] as? JsonObject)?.let { first ->
            MCPTestSupport.assertSubset(
                first,
                (replies.first() as JsonObject).members["result"],
                "$label.firstResult",
            )
        }
    }

    private suspend fun runNotification(case: JsonObject, label: String, native: JsonObject) {
        val harness = harness(native)
        val message = case.members["message"] as JsonObject
        val response = harness.handler.dispatch(message)
        val expect = case.members["expect"] as JsonObject
        assertEquals(
            label,
            (expect.members["status"] as JsonNumber).asLongOrNull()!!.toInt(),
            response.status,
        )
        assertTrue("$label: notification-only must have an empty body", response.emptyBody)
    }

    private suspend fun runInvalidSingle(case: JsonObject, label: String) {
        val harness = harness(vector.members["native"] as JsonObject)
        val request = case.members["request"] as JsonObject
        val reply = harness.handler.rpc(
            method = (request.members["method"] as JsonString).value,
            params = request.members["params"] ?: JsonObject(emptyMap()),
            id = request.members["id"] ?: JsonNull,
        )
        val expect = case.members["expect"] as JsonObject
        val expectedError = expect.members["error"] as JsonObject
        val actualError = reply.members["error"] as JsonObject
        assertEquals(label, expectedError.members["code"], actualError.members["code"])
        (expectedError.members["message"] as? JsonString)?.value?.let { message ->
            assertEquals(label, message, (actualError.members["message"] as JsonString).value)
        }
    }

    private suspend fun runInvalidBatch(case: JsonObject, label: String) {
        val harness = harness(vector.members["native"] as JsonObject)
        val messages = JsonArray((case.members["messages"] as JsonArray).values)
        val response = harness.handler.dispatch(messages)
        val expect = case.members["expect"] as JsonObject
        assertEquals(
            label,
            (expect.members["status"] as JsonNumber).asLongOrNull()!!.toInt(),
            response.status,
        )
        val error = (expect.members["error"] as? JsonString)?.value
        if (error != null) {
            assertEquals(
                label,
                error,
                ((response.body as JsonObject).members["error"] as JsonString).value,
            )
        }
    }

    // ------------------------------------------------------------------
    // helpers
    // ------------------------------------------------------------------

    private fun harness(native: JsonObject): MCPHarness = MCPHarness(
        native = FixtureNativeForwarder(native),
    )

    private fun principalFrom(caller: JsonObject): BotMCPPrincipal = MCPTestSupport.principal(
        botId = (caller.members["botId"] as JsonString).value,
        sessionId = (caller.members["sessionId"] as JsonString).value,
        kind = (caller.members["kind"] as? JsonString)?.value ?: "chat",
    )
}
