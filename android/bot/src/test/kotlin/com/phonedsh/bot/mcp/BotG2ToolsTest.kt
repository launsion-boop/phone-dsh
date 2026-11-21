// SPDX-License-Identifier: MIT
package com.phonedsh.bot.mcp

import com.phonedsh.agentcore.JsonArray
import com.phonedsh.agentcore.JsonBool
import com.phonedsh.agentcore.JsonNumber
import com.phonedsh.agentcore.JsonObject
import com.phonedsh.agentcore.JsonString
import com.phonedsh.agentcore.JsonValue
import com.phonedsh.bot.BotJson
import com.phonedsh.bot.GoldenFixture
import com.phonedsh.bot.authz.BotToolEffectClassifier
import com.phonedsh.bot.authz.BotToolMutability
import com.phonedsh.bot.authz.BotToolPolicy
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.nio.file.Files

/**
 * G-2 tools (spec/bot/v2): the advertised definitions are the frozen spec
 * files, and the host-side checks fail closed exactly like the Swift runtime.
 */
class BotG2ToolsTest {
    private fun spec(path: String): JsonObject =
        JsonValue.parse(Files.readString(GoldenFixture.repoRoot.resolve(path))) as JsonObject

    @Test
    fun recordFeedbackDefinitionIsTheFrozenSpecFile() {
        val frozen = spec("spec/bot/v2/record-feedback-tool.json").members
        val definition = BotToolCatalog.RECORD_FEEDBACK_DEFINITION
        assertEquals(BotJson.string(frozen["name"]), definition.name)
        assertEquals(BotJson.string(frozen["description"]), definition.description)
        assertEquals(BotJson.canonical(frozen["inputSchema"]!!), BotJson.canonical(definition.inputSchema))
    }

    @Test
    fun decisionContextDefinitionIsTheFrozenRequestBranch() {
        val oneOf = (spec("spec/bot/v2/decision-internal-tool.schema.json").members["oneOf"] as JsonArray).values
        val request = oneOf.first() as JsonObject
        assertEquals(
            BotJson.canonical(request),
            BotJson.canonical(BotToolCatalog.DECISION_CONTEXT_DEFINITION.inputSchema),
        )
    }

    @Test
    fun decisionContextIsListedOnlyInTheStaticWorkerList() {
        val catalog = MCPTestSupport.catalog()
        assertTrue(catalog.definitions(null).any { it.name == "BotDecisionContext" })
        assertFalse(catalog.definitions("main").any { it.name == "BotDecisionContext" })
        assertTrue(catalog.definitions("main").any { it.name == "RecordFeedback" })
    }

    @Test
    fun recordFeedbackEffectAsksAndKeepsUserWordsOutOfTheResource() {
        val effect = BotToolEffectClassifier.effect(
            "mcp__phone__RecordFeedback",
            BotJson.objectOf(
                "action" to JsonString("correct"),
                "target" to BotJson.objectOf("kind" to JsonString("memory"), "id" to JsonString("user/x.md")),
            ),
        )
        assertEquals(BotToolPolicy.ASK, effect.policy)
        assertEquals(BotToolMutability.WRITE, effect.mutability)
        assertTrue(effect.known)
        assertEquals("feedback", effect.execution)
        assertFalse(effect.resource.contains("user/x.md"))
    }

    // -- RecordFeedback --------------------------------------------------

    private class RecordingFeedback : BotFeedbackPort {
        val requests = ArrayList<BotFeedbackRequest>()
        override suspend fun record(request: BotFeedbackRequest): JsonValue {
            requests += request
            return BotJson.objectOf("ok" to JsonBool(true), "accepted" to JsonBool(true))
        }
    }

    private fun runtime(
        attribution: FakeAttribution,
        feedback: BotFeedbackPort? = null,
        decision: BotDecisionContextPort? = null,
    ) = BotMCPToolRuntime(
        catalogProvider = MCPTestSupport.catalog(),
        attribution = attribution,
        feedback = feedback,
        decisionContext = decision,
    )

    private val feedbackArgs: JsonObject = BotJson.objectOf(
        "action" to JsonString("correct"),
        "target" to BotJson.objectOf(
            "kind" to JsonString("memory"),
            "id" to JsonString("  user/x.md "),
            "version" to JsonNumber("3"),
        ),
        "disputed_refs" to JsonArray(listOf(JsonString("record://event/7"))),
    )

    @Test
    fun recordFeedbackWithoutAStoreIsUnavailable() = runBlocking {
        val attribution = FakeAttribution()
        attribution.register("c1", "RecordFeedback", feedbackArgs, MCPTestSupport.principal())
        val result = runtime(attribution).execute("RecordFeedback", feedbackArgs)
        assertEquals("unavailable", MCPTestSupport.errorCode(result))
    }

    @Test
    fun recordFeedbackRefusesANonUserPrincipal() = runBlocking {
        val attribution = FakeAttribution()
        val store = RecordingFeedback()
        attribution.register("c1", "RecordFeedback", feedbackArgs, MCPTestSupport.principal(kind = "task"))
        val result = runtime(attribution, feedback = store).execute("RecordFeedback", feedbackArgs)
        assertEquals("permission_denied", MCPTestSupport.errorCode(result))
        assertTrue(store.requests.isEmpty())
    }

    @Test
    fun recordFeedbackPassesTheParsedRequest() = runBlocking {
        val attribution = FakeAttribution()
        val store = RecordingFeedback()
        attribution.register("c1", "RecordFeedback", feedbackArgs, MCPTestSupport.principal())
        val result = runtime(attribution, feedback = store).execute("RecordFeedback", feedbackArgs)
        assertFalse(result.isError)
        val request = store.requests.single()
        assertEquals("main", request.botId)
        assertEquals("gb-main", request.sessionId)
        assertEquals("c1", request.nonce)
        assertEquals("user/x.md", request.targetId)
        assertEquals(3L, request.targetVersion)
        assertEquals("artifact", request.scope)
        assertTrue(request.disputedOnly)
    }

    @Test
    fun recordFeedbackRejectsAnUnknownAction() = runBlocking {
        val attribution = FakeAttribution()
        val args = BotJson.objectOf(
            "action" to JsonString("like"),
            "target" to BotJson.objectOf("kind" to JsonString("memory"), "id" to JsonString("a")),
        )
        attribution.register("c1", "RecordFeedback", args, MCPTestSupport.principal())
        val result = runtime(attribution, feedback = RecordingFeedback()).execute("RecordFeedback", args)
        assertEquals("invalid_arguments", MCPTestSupport.errorCode(result))
    }

    // -- BotDecisionContext ----------------------------------------------

    private fun decisionArgs(sessionId: String = "gb-main", step: JsonValue = JsonNumber("1")): JsonObject =
        BotJson.objectOf(
            "schema" to JsonString("bot-decision-context-request/v1"),
            "session_id" to JsonString(sessionId),
            "turn_id" to JsonString("gb-main#4"),
            "step" to step,
            "stage" to JsonString("pre_step"),
            "query" to JsonString("天气"),
            "scopes" to JsonArray(listOf(JsonString("user"), JsonString("agent"))),
            "limits" to BotJson.objectOf(
                "max_materials" to JsonNumber("4"),
                "max_characters" to JsonNumber("1200"),
                "max_snippet_characters" to JsonNumber("200"),
                "deadline_ms" to JsonNumber("800"),
            ),
        )

    private class FixedDecision(private val failure: BotDecisionContextException? = null) : BotDecisionContextPort {
        val requests = ArrayList<BotDecisionRequest>()
        override suspend fun materials(request: BotDecisionRequest): JsonValue {
            requests += request
            failure?.let { throw it }
            return BotJson.objectOf("block_id" to JsonString("b1"))
        }
    }

    private fun decisionResult(result: BotMCPCallResult): Map<String, JsonValue> =
        (result.structuredContent as JsonObject).members

    private suspend fun callDecision(
        args: JsonObject,
        port: BotDecisionContextPort?,
        principal: BotMCPPrincipal = MCPTestSupport.principal(),
    ): BotMCPCallResult {
        val attribution = FakeAttribution()
        attribution.register("d1", "BotDecisionContext", args, principal)
        return runtime(attribution, decision = port).execute("mcp__phone__BotDecisionContext", args)
    }

    @Test
    fun decisionContextWithoutAServiceIsMaterialUnavailable() = runBlocking {
        val result = callDecision(decisionArgs(), port = null)
        assertTrue(result.isError)
        val value = decisionResult(result)
        assertEquals("bot-decision-context-result/v1", BotJson.string(value["schema"]))
        assertEquals(JsonBool(false), value["ok"])
        assertEquals("material-unavailable", BotJson.string(value["code"]))
    }

    @Test
    fun decisionContextRefusesAnotherSession() = runBlocking {
        val port = FixedDecision()
        val result = callDecision(decisionArgs(sessionId = "gb-other"), port)
        assertEquals("permission-denied", BotJson.string(decisionResult(result)["code"]))
        assertTrue(port.requests.isEmpty())
    }

    @Test
    fun decisionContextRejectsANonIntegerStep() = runBlocking {
        val result = callDecision(decisionArgs(step = JsonString("1")), FixedDecision())
        assertEquals("invalid-request", BotJson.string(decisionResult(result)["code"]))
    }

    @Test
    fun decisionContextIsAnsweredForAnIdentifiedCallerAndReturnsTheBlock() = runBlocking {
        val port = FixedDecision()
        val result = callDecision(decisionArgs(), port)
        assertFalse(result.isError)
        val value = decisionResult(result)
        assertEquals(JsonBool(true), value["ok"])
        assertEquals("b1", BotJson.string((value["block"] as JsonObject).members["block_id"]))
        val request = port.requests.single()
        assertEquals("main", request.botId)
        assertEquals(listOf("user", "agent"), request.scopes)
        assertNull(request.origin)
    }

    @Test
    fun decisionContextMapsAnUnknownServiceCodeToMaterialUnavailable() = runBlocking {
        val port = FixedDecision(BotDecisionContextException("boom", "x"))
        val result = callDecision(decisionArgs(), port)
        assertEquals("material-unavailable", BotJson.string(decisionResult(result)["code"]))
    }
}
