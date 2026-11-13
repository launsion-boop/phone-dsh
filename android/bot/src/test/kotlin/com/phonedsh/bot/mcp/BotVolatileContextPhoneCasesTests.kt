// SPDX-License-Identifier: MIT
package com.phonedsh.bot.mcp

import com.phonedsh.agentcore.JsonArray
import com.phonedsh.agentcore.JsonBool
import com.phonedsh.agentcore.JsonNumber
import com.phonedsh.agentcore.JsonObject
import com.phonedsh.agentcore.JsonString
import com.phonedsh.agentcore.JsonValue
import com.phonedsh.bot.GoldenFixture
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

/**
 * D13 volatile contract: `assemblyCases` drive the real
 * `BotDomainVolatileContextProvider` and `producerCases` drive the real
 * `BotVolatileContextProducer`; memory and routine rendering are the B2/B3
 * ports with in-test fakes.
 */
class BotVolatileContextPhoneCasesTests {
    private val vector: JsonObject = GoldenFixture.rawObject("volatile-context.phone")

    @Test
    fun fixtureMetadataKeepsTheUpstreamCases() {
        assertEquals("volatile-context.phone", (vector.members["vector"] as JsonString).value)
        assertEquals("volatile-context.json", (vector.members["upstream"] as JsonString).value)
        assertTrue((vector.members["assemblyCases"] as JsonArray).values.isNotEmpty())
        assertTrue((vector.members["producerCases"] as JsonArray).values.isNotEmpty())
        val merged = GoldenFixture.mergedObject("volatile-context")
        assertTrue(merged.members.containsKey("valid"))
        assertTrue(merged.members.containsKey("invalid"))
    }

    @Test
    fun everyAssemblyCaseDrivesTheRealDomainProvider() = runBlocking {
        for ((index, raw) in (vector.members["assemblyCases"] as JsonArray).values.withIndex()) {
            val case = raw as JsonObject
            val name = (case.members["name"] as JsonString).value
            runAssembly(case, "assembly[$index] $name")
        }
    }

    @Test
    fun everyProducerCaseDrivesTheRealProducer() = runBlocking {
        for ((index, raw) in (vector.members["producerCases"] as JsonArray).values.withIndex()) {
            val case = raw as JsonObject
            val name = (case.members["name"] as JsonString).value
            runProducer(case, "producer[$index] $name")
        }
    }

    private suspend fun runAssembly(case: JsonObject, label: String) {
        val input = case.members["input"] as JsonObject
        val expect = case.members["expect"] as JsonObject
        val botId = (input.members["botId"] as JsonString).value
        val sessionId = (input.members["sessionId"] as JsonString).value
        val kind = BotMCPPrincipalKind.fromWire((input.members["kind"] as JsonString).value)
            ?: BotMCPPrincipalKind.CHAT
        val language = (input.members["language"] as? JsonString)?.value ?: "zh"
        val memory = FakeMemoryLookup()
        for (doc in (input.members["memory"] as? JsonArray)?.values ?: emptyList()) {
            val fields = (doc as JsonObject).members
            memory.seed(
                (fields["path"] as JsonString).value,
                (fields["content"] as JsonString).value,
            )
        }
        val routines = FakeRoutineLookup()
        for (routine in (input.members["routines"] as? JsonArray)?.values ?: emptyList()) {
            val fields = (routine as JsonObject).members
            routines.seed(
                (fields["title"] as JsonString).value,
                (fields["prompt"] as JsonString).value,
                (fields["schedule"] as JsonString).value,
            )
        }
        val teammates = ((input.members["teammates"] as? JsonArray)?.values ?: emptyList())
            .map { value ->
                val fields = (value as JsonObject).members
                BotTeammateSummary(
                    id = (fields["id"] as? JsonString)?.value ?: "",
                    name = (fields["name"] as? JsonString)?.value ?: "",
                    description = (fields["description"] as? JsonString)?.value ?: "",
                    isMain = (fields["isMain"] as? JsonBool)?.value ?: false,
                )
            }
        val personaText = (input.members["persona"] as? JsonString)?.value
        val descriptionText = (input.members["description"] as? JsonString)?.value
        val teammatesClosure: (suspend (String) -> List<BotTeammateSummary>)? =
            if (teammates.isNotEmpty()) {
                { _: String -> teammates }
            } else {
                null
            }
        val descriptionClosure: (suspend (String) -> String?)? =
            if (descriptionText != null) {
                { _: String -> descriptionText }
            } else {
                null
            }
        val provider = BotDomainVolatileContextProvider(
            memory = memory,
            routines = routines,
            persona = if (personaText != null) {
                { _, _, _ -> personaText }
            } else {
                null
            },
            teammates = teammatesClosure,
            botDescription = descriptionClosure,
            now = { 1_000L },
            language = language,
        )
        val blocks = provider.snapshot(botId, sessionId, kind)

        (expect.members["persona"] as? JsonString)?.value?.let {
            assertEquals(label, it, blocks.persona)
        }
        if ((expect.members["variantAbsent"] as? JsonBool)?.value == true) {
            assertNull(label, blocks.variant)
        }
        (expect.members["variantContains"] as? JsonString)?.value?.let {
            assertTrue("$label: variant missing $it", blocks.variant?.contains(it) == true)
        }
        for (value in (expect.members["memoryContains"] as? JsonArray)?.values ?: emptyList()) {
            val text = (value as JsonString).value
            assertTrue("$label: memory missing $text", blocks.memory?.contains(text) == true)
        }
        val automation = blocks.automation ?: ""
        for (value in (expect.members["automationContains"] as? JsonArray)?.values ?: emptyList()) {
            val text = (value as JsonString).value
            assertTrue("$label: automation missing $text", automation.contains(text))
        }
        for (value in (expect.members["automationAbsent"] as? JsonArray)?.values ?: emptyList()) {
            val text = (value as JsonString).value
            assertFalse("$label: automation unexpectedly contains $text", automation.contains(text))
        }
        (expect.members["automationScalarsMax"] as? JsonNumber)?.asLongOrNull()?.let {
            assertTrue("$label: automation over $it", BotMCPScalars.length(automation) <= it)
        }
        val teammateBlock = teammatesBlock(automation)
        (expect.members["teammatesLineCount"] as? JsonNumber)?.asLongOrNull()?.let { expected ->
            val count = teammateBlock.split('\n').count { it.startsWith("- ") }
            assertEquals("$label: teammate line count", expected.toInt(), count)
        }
        (expect.members["teammatesScalarsMax"] as? JsonNumber)?.asLongOrNull()?.let {
            assertTrue(
                "$label: teammate block over $it",
                BotMCPScalars.length(teammateBlock) <= it,
            )
        }
    }

    private suspend fun runProducer(case: JsonObject, label: String) {
        val principalObject = case.members["principal"] as JsonObject
        val principal = MCPTestSupport.principal(
            botId = (principalObject.members["botId"] as JsonString).value,
            sessionId = (principalObject.members["sessionId"] as JsonString).value,
            kind = (principalObject.members["kind"] as JsonString).value,
        )
        val request = case.members["request"] ?: JsonObject(emptyMap())
        val providerObject = case.members["provider"] as JsonObject
        val blocks = BotVolatileBlocks(
            variant = (providerObject.members["variant"] as? JsonString)?.value,
            persona = (providerObject.members["persona"] as? JsonString)?.value,
            memory = (providerObject.members["memory"] as? JsonString)?.value,
            automation = (providerObject.members["automation"] as? JsonString)?.value,
        )
        val sequence = (case.members["sequence"] as? JsonArray)?.values
            ?.map { (it as JsonString).value }
            ?: emptyList()
        val failOn = sequence.withIndex()
            .filter { it.value == "fail" }
            .map { it.index + 1 }
            .toSet()
        val delayMs = ((case.members["delayNs"] as? JsonNumber)?.asLongOrNull() ?: 0L) / 1_000_000L
        val provider = SequencingVolatileProvider(blocks, delayMs, failOn)
        val timeout = (case.members["timeout"] as? JsonNumber)?.let {
            it.raw.toDoubleOrNull()
        } ?: BotVolatileContextProducer.DEFAULT_TIMEOUT_SECONDS
        val producer = BotVolatileContextProducer(provider, timeout)
        val expect = case.members["expect"] as JsonObject
        val expectedError = (expect.members["error"] as? JsonString)?.value

        if (sequence.size > 1) {
            assertEquals(label, "unavailable", expectedError)
            val first = producer.snapshot(request, principal)
            assertNotNull(label, first.blocks.memory)
            try {
                producer.snapshot(request, principal)
                fail("$label: failed provider must not return a stale snapshot")
            } catch (error: BotMCPToolException) {
                assertEquals(label, "unavailable", error.code)
            }
            return
        }
        if (expectedError != null) {
            try {
                producer.snapshot(request, principal)
                fail("$label: expected $expectedError but the snapshot succeeded")
            } catch (error: BotMCPToolException) {
                assertEquals(label, expectedError, error.code)
            }
            return
        }
        val snapshot = producer.snapshot(request, principal)
        expect.members["response"]?.let {
            MCPTestSupport.assertSubset(
                it,
                snapshot.toJson(),
                "$label.response",
            )
        } ?: fail("$label: expected a response expectation")
    }

    private fun teammatesBlock(automation: String): String {
        val start = automation.indexOf("<teammates>")
        if (start < 0) return ""
        val end = automation.indexOf("</teammates>", start)
        if (end < 0) return ""
        return automation.substring(start, end + "</teammates>".length)
    }

    private class SequencingVolatileProvider(
        private val blocks: BotVolatileBlocks,
        private val delayMs: Long,
        private val failOnCalls: Set<Int>,
    ) : BotVolatileContextProviding {
        private var calls = 0

        override suspend fun snapshot(
            botId: String,
            sessionId: String,
            kind: BotMCPPrincipalKind,
        ): BotVolatileBlocks {
            calls += 1
            if (delayMs > 0) delay(delayMs)
            if (calls in failOnCalls) {
                throw BotMCPToolException("unavailable", "provider failed")
            }
            return blocks
        }
    }
}
