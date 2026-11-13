// SPDX-License-Identifier: MIT
package com.phonedsh.bot.memory

import com.phonedsh.agentcore.JsonObject
import com.phonedsh.bot.BotJsonException
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

/** Drives `memory-legacy-fact.json` and `memory-migration.json` through the real migrator. */
class MemoryMigrationGoldenTest {
    private val legacyFixture = MemoryVectors.golden("memory-legacy-fact")
    private val migrationFixture = MemoryVectors.golden("memory-migration")

    @Test
    fun legacyFactCodecAcceptsValidInputAndRejectsTheFrozenInvalidShapes() {
        val valid = MemoryVectors.objects(legacyFixture, "valid")
        assertTrue(valid.isNotEmpty())
        for ((index, value) in valid.withIndex()) {
            val fact = BotMemoryLegacyFact.fromJson(value)
            assertEquals("legacy.valid[$index]", MemoryVectors.string(value, "fact_id"), fact.factId)
            assertTrue(fact.text.isNotEmpty())
            MemoryVectors.assertMatchesSchema("memory-legacy-fact", fact.toJson())
        }
        for ((index, entry) in MemoryVectors.objects(legacyFixture, "invalid").withIndex()) {
            try {
                BotMemoryLegacyFact.fromJson(entry.members["fact"])
                fail("legacy.invalid[$index] ${MemoryVectors.string(entry, "reason")} was accepted")
            } catch (_: BotJsonException) {
                // expected
            }
        }
    }

    @Test
    fun migrationProducesTheGoldenDocumentsForEveryBot() {
        MemoryHarness().use { harness ->
            seedLegacyFacts(harness)
            val expected = MemoryVectors.objectAt(migrationFixture, "expected")
            for (bot in (migrationFixture.members["bots"] as com.phonedsh.agentcore.JsonArray).values) {
                val botId = (bot as com.phonedsh.agentcore.JsonString).value
                val store = harness.storeFor(botId)
                val memory = BotMemory(store, botId, now = { 1_760_000_000_000 })
                val documents = memory.documents()
                val expectedBot = MemoryVectors.objectAt(expected, botId)
                val expectedDocuments = MemoryVectors.objectAt(expectedBot, "documents")
                val actualMap = documents.associate { it.path to it.content }
                val expectedMap = expectedDocuments.members.mapValues {
                    (it.value as com.phonedsh.agentcore.JsonString).value
                }
                assertEquals("migration[$botId] documents", expectedMap, actualMap)

                val expectedEvidence = MemoryVectors.objectAt(expectedBot, "evidence")
                for ((path, refs) in expectedEvidence.members) {
                    val document = documents.firstOrNull { it.path == path }
                        ?: throw AssertionError("migration[$botId] missing $path")
                    assertEquals(
                        "migration[$botId] evidence $path",
                        (refs as com.phonedsh.agentcore.JsonArray).values
                            .map { (it as com.phonedsh.agentcore.JsonString).value },
                        document.evidence,
                    )
                }
                for ((path, content) in expectedMap) {
                    assertTrue(
                        "migration[$botId] path $path",
                        BotMemoryPath.parse(path) != null,
                    )
                    if (path.endsWith("INDEX.md")) {
                        assertTrue(
                            "migration[$botId] index $path",
                            BotMemoryText.scalarCount(content) <= BotMemoryLimits.INDEX,
                        )
                    }
                }
            }
        }
    }

    @Test
    fun everyFactTextSurvivesAndAgentDocumentsStayPrivate() {
        MemoryHarness().use { harness ->
            seedLegacyFacts(harness)
            val facts = MemoryVectors.objects(migrationFixture, "facts")
            val mainDocs = BotMemory(harness.storeFor("main"), "main", now = { 1L })
                .documents().associate { it.path to it.content }
            val botBDocs = BotMemory(harness.storeFor("bot-b"), "bot-b", now = { 2L })
                .documents().associate { it.path to it.content }

            for (fact in facts) {
                val owner = MemoryVectors.requireString(fact, "owner")
                val scope = MemoryVectors.requireString(fact, "scope")
                val text = MemoryVectors.requireString(fact, "text")
                if (scope == "user" || owner == "main") {
                    assertTrue(
                        "main must retain $text",
                        mainDocs.values.any { it.contains(text) },
                    )
                }
                if (scope == "user" || owner == "bot-b") {
                    assertTrue(
                        "bot-b must retain $text",
                        botBDocs.values.any { it.contains(text) },
                    )
                }
            }
            for (fact in facts) {
                if (MemoryVectors.requireString(fact, "owner") != "main") continue
                if (MemoryVectors.requireString(fact, "scope") != "agent") continue
                val text = MemoryVectors.requireString(fact, "text")
                assertFalse(
                    "bot-b must not see $text",
                    botBDocs.values.any { it.contains(text) },
                )
            }
        }
    }

    @Test
    fun secondMigrationRunWritesNoEvent() {
        MemoryHarness().use { harness ->
            seedLegacyFacts(harness)
            BotMemory(harness.storeFor("main"), "main", now = { 1_760_000_000_000 })
                .documents()
            val before = harness.domain.headCommitSeq()
            BotMemory(harness.storeFor("main"), "main", now = { 1_760_000_000_001 })
                .documents()
            assertEquals("a second migration run must not append events", before, harness.domain.headCommitSeq())
        }
    }

    private fun seedLegacyFacts(harness: MemoryHarness) {
        for ((index, fact) in MemoryVectors.objects(migrationFixture, "facts").withIndex()) {
            val parsed = BotMemoryLegacyFact.fromJson(fact)
            val owner = MemoryVectors.requireString(fact, "owner")
            harness.append(
                type = "memory.written",
                eventId = "legacy-$index-${parsed.factId}",
                data = parsed.toJson(),
                botId = if (owner == "shared") "main" else owner,
                sessionId = "gb-main",
                time = parsed.learnedAtMs,
            )
        }
    }
}
