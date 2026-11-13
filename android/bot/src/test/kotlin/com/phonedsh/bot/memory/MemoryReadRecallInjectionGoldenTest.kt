// SPDX-License-Identifier: MIT
package com.phonedsh.bot.memory

import com.phonedsh.agentcore.JsonArray
import com.phonedsh.agentcore.JsonBool
import com.phonedsh.agentcore.JsonNumber
import com.phonedsh.agentcore.JsonObject
import com.phonedsh.bot.BotJsonException
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

/** Drives `memory-read.json`, `memory-recall.json` and `memory-injection.json`. */
class MemoryReadRecallInjectionGoldenTest {
    private val readFixture = MemoryVectors.golden("memory-read")
    private val recallFixture = MemoryVectors.golden("memory-recall")
    private val injectionFixture = MemoryVectors.golden("memory-injection")

    private fun seedReadState(store: BotMemoryDocumentStore) {
        val state = MemoryVectors.objectAt(readFixture, "state")
        for (document in MemoryVectors.objects(state, "documents")) {
            val path = MemoryVectors.requireString(document, "path")
            seedDocument(
                store, path,
                MemoryVectors.requireString(document, "content"),
                MemoryVectors.requireLong(document, "version").toInt(),
                evidence = (document.members["evidence"] as? JsonArray)?.values
                    ?.map { (it as com.phonedsh.agentcore.JsonString).value } ?: emptyList(),
                updatedAtMs = MemoryVectors.requireLong(document, "updated_at_ms"),
            )
        }
        val history = (state.members["history"] as? JsonObject)?.members ?: emptyMap()
        val livePaths = MemoryVectors.objects(state, "documents")
            .map { MemoryVectors.requireString(it, "path") }
            .toSet()
        for ((path, entries) in history) {
            if (path in livePaths) continue
            for (entry in (entries as JsonArray).values.map { it as JsonObject }.sortedBy {
                MemoryVectors.requireLong(it, "version")
            }) {
                val version = MemoryVectors.requireLong(entry, "version").toInt()
                val deleted = (entry.members["deleted"] as? JsonBool)?.value == true
                val outcome = store.write(
                    BotMemoryStoreWriteRequest(
                        action = if (deleted) BotMemoryAction.DELETE else BotMemoryAction.WRITE,
                        path = path,
                        content = if (deleted) null else MemoryVectors.string(entry, "content").orEmpty(),
                        expectedVersion = version - 1,
                        author = CHAT_AUTHOR,
                        evidence = emptyList(),
                        trust = null,
                        source = null,
                        atMs = 1_760_000_000_000 + version,
                    ),
                )
                if (outcome !is BotMemoryStoreWriteOutcome.Written &&
                    outcome !is BotMemoryStoreWriteOutcome.Deleted
                ) {
                    throw AssertionError("seed history $path#$version failed: $outcome")
                }
            }
        }
    }

    @Test
    fun everyReadCaseMatchesTheGolden() {
        MemoryHarness().use { harness ->
            seedReadState(harness.store)
            val memory = BotMemory(harness.store, "bot-a", now = { 1_760_000_000_000 })
            for ((index, case) in MemoryVectors.objects(readFixture, "cases").withIndex()) {
                val name = MemoryVectors.requireString(case, "name")
                val request = MemoryVectors.objectAt(case, "request")
                val path = MemoryVectors.requireString(request, "path")
                val version = MemoryVectors.long(request, "version")?.toInt()
                val actual = memory.read(path, version)
                val expect = MemoryVectors.objectAt(case, "expect")
                val expectedOk = MemoryVectors.bool(expect, "ok")!!
                assertEquals("read[$index] $name ok", expectedOk, !actual.isFailure)
                if (expectedOk) {
                    val kind = MemoryVectors.requireString(expect, "kind")
                    if (kind == "document") {
                        assertTrue("read[$index] $name document", actual is BotMemoryReadResult.Document)
                        val document = (actual as BotMemoryReadResult.Document).version
                        MemoryVectors.long(expect, "version")?.let {
                            assertEquals("read[$index] $name version", it.toInt(), document.version)
                        }
                        MemoryVectors.string(expect, "contentContains")?.let {
                            assertTrue("read[$index] $name content", document.content.contains(it))
                        }
                        MemoryVectors.string(expect, "contentExcludes")?.let {
                            assertFalse("read[$index] $name content", document.content.contains(it))
                        }
                        MemoryVectors.bool(expect, "deleted")?.let {
                            assertEquals("read[$index] $name deleted", it, document.deleted)
                        }
                        MemoryVectors.assertMatchesSchema(
                            "memory-read-result",
                            (actual as BotMemoryReadResult.Document).toJson(),
                        )
                    } else {
                        assertTrue("read[$index] $name directory", actual is BotMemoryReadResult.Directory)
                        val directory = actual as BotMemoryReadResult.Directory
                        val expectedEntries = (expect.members["entries"] as JsonArray).values
                            .map { (it as com.phonedsh.agentcore.JsonString).value }
                        assertEquals(
                            "read[$index] $name entries",
                            expectedEntries,
                            directory.entries.map { it.path },
                        )
                        for (entry in directory.entries) {
                            assertTrue("entry path", entry.path.endsWith("/" + entry.name))
                            if (entry.kind == BotMemoryDirectoryEntry.Kind.DOCUMENT) {
                                assertTrue("document entry version", entry.version != null)
                            }
                        }
                        MemoryVectors.assertMatchesSchema(
                            "memory-read-result",
                            directory.toJson(),
                        )
                    }
                } else {
                    assertTrue("read[$index] $name failure", actual is BotMemoryReadResult.Failure)
                    assertEquals(
                        "read[$index] $name code",
                        MemoryVectors.requireString(expect, "code"),
                        (actual as BotMemoryReadResult.Failure).code,
                    )
                    MemoryVectors.assertMatchesSchema("memory-read-result", actual.toJson())
                }
            }
            val missing = memory.read("agent/notes/missing.md")
            assertTrue(missing.isFailure)
            assertEquals("memory-not-found", (missing as BotMemoryReadResult.Failure).code)
            val invalid = memory.read("shared/profile.md")
            assertTrue(invalid.isFailure)
            assertEquals("memory-path-invalid", (invalid as BotMemoryReadResult.Failure).code)
        }
    }

    @Test
    fun everyReadFailureCaseUsesTheFrozenCode() {
        MemoryHarness().use { harness ->
            seedReadState(harness.store)
            val memory = BotMemory(harness.store, "bot-a", now = { 1_760_000_000_000 })
            for (case in MemoryVectors.objects(readFixture, "cases")) {
                val expect = MemoryVectors.objectAt(case, "expect")
                if (MemoryVectors.bool(expect, "ok") == true) continue
                val request = MemoryVectors.objectAt(case, "request")
                val result = memory.read(
                    MemoryVectors.requireString(request, "path"),
                    MemoryVectors.long(request, "version")?.toInt(),
                )
                assertTrue(result.isFailure)
                assertEquals(
                    MemoryVectors.requireString(expect, "code"),
                    (result as BotMemoryReadResult.Failure).code,
                )
                MemoryVectors.assertMatchesSchema("memory-read-result", result.toJson())
            }
        }
    }

    @Test
    fun recallQueriesReturnOnlyTheExpectedLiveDocuments() {
        MemoryHarness().use { harness ->
            for (document in MemoryVectors.objects(recallFixture, "documents")) {
                seedDocument(
                    harness.store,
                    MemoryVectors.requireString(document, "path"),
                    MemoryVectors.requireString(document, "content"),
                    MemoryVectors.requireLong(document, "version").toInt(),
                    evidence = (document.members["evidence"] as? JsonArray)?.values
                        ?.map { (it as com.phonedsh.agentcore.JsonString).value } ?: emptyList(),
                    updatedAtMs = MemoryVectors.requireLong(document, "updated_at_ms"),
                )
            }
            val memory = BotMemory(harness.store, "bot-a", now = { 1_760_000_000_000 })
            for ((index, queryCase) in MemoryVectors.objects(recallFixture, "queries").withIndex()) {
                val name = MemoryVectors.requireString(queryCase, "name")
                val scope = when (MemoryVectors.string(queryCase, "scope")) {
                    "agent" -> BotMemoryScope.AGENT
                    "user" -> BotMemoryScope.USER
                    else -> null
                }
                val hits = memory.recall(
                    MemoryVectors.string(queryCase, "query").orEmpty(),
                    MemoryVectors.requireLong(queryCase, "limit").toInt(),
                    scope,
                )
                val expectedPaths = (queryCase.members["expectedPaths"] as JsonArray).values
                    .map { (it as com.phonedsh.agentcore.JsonString).value }
                assertEquals(
                    "recall[$index] $name paths",
                    expectedPaths,
                    hits.take(expectedPaths.size).map { it.path },
                )
                for (marker in (queryCase.members["snippetContains"] as? JsonArray)?.values.orEmpty()) {
                    val text = (marker as com.phonedsh.agentcore.JsonString).value
                    assertTrue(
                        "recall[$index] $name snippet $text",
                        hits.any { it.snippet.contains(text) },
                    )
                }
                for (hit in hits) {
                    MemoryVectors.assertMatchesSchema("memory-recall", hit.toJson())
                    assertTrue(BotMemoryText.scalarCount(hit.snippet) <= 500)
                    val expectedScore = Math.round(
                        (0.85 * hit.relevance + 0.15 * hit.recency) * 1_000_000.0,
                    ) / 1_000_000.0
                    assertEquals("recall score formula", expectedScore, hit.score, 0.000_002)
                    assertTrue(hit.score in 0.0..1.0)
                }
            }
        }
    }

    @Test
    fun recallHitsRejectTheOldFactShapeAndImportance() {
        for (hit in MemoryVectors.objects(recallFixture, "hits")) {
            assertTrue(MemoryVectors.canonical(hit).isNotEmpty())
            BotMemoryRecallHit.fromJson(hit)
        }
        for (entry in MemoryVectors.objects(recallFixture, "invalid")) {
            try {
                BotMemoryRecallHit.fromJson(entry.members["hit"])
                fail("recall invalid ${MemoryVectors.string(entry, "reason")} was accepted")
            } catch (_: BotJsonException) {
                // expected
            }
        }
    }

    @Test
    fun injectionContainsExactlyTheTwoRootIndexes() {
        MemoryHarness().use { harness ->
            val indexes = MemoryVectors.objectAt(injectionFixture, "indexes")
            for (name in listOf("user", "agent")) {
                val index = MemoryVectors.objectAt(indexes, name)
                seedDocument(
                    harness.store,
                    MemoryVectors.requireString(index, "path"),
                    MemoryVectors.requireString(index, "content"),
                    MemoryVectors.requireLong(index, "version").toInt(),
                )
            }
            val memory = BotMemory(harness.store, "bot-a", now = { 1_760_000_000_000 })
            val injection = memory.injection()
            assertEquals(
                MemoryVectors.requireString(injectionFixture, "valid", "text"),
                injection.text,
            )
            assertEquals(1_500, injection.limits.index)
            assertEquals(4_000, injection.limits.total)
            assertEquals(3, injection.text.split("INDEX.md").size - 1)
            MemoryVectors.assertMatchesSchema("memory-injection", injection.toJson())
        }
    }

    @Test
    fun missingIndexesRenderTheEmptyPlaceholder() {
        MemoryHarness().use { harness ->
            for (scope in BotMemoryScope.roots) {
                val outcome = harness.store.write(
                    BotMemoryStoreWriteRequest(
                        action = BotMemoryAction.WRITE,
                        path = "${scope.wire}/INDEX.md",
                        content = "",
                        expectedVersion = 0,
                        author = BotMemoryAuthor("bot-a", null, BotMemoryAuthorKind.SYSTEM),
                        atMs = 1_760_000_000_000,
                    ),
                )
                assertTrue(outcome is BotMemoryStoreWriteOutcome.Written)
            }
            val memory = BotMemory(harness.store, "bot-a", now = { 1_760_000_000_000 })
            assertEquals(
                MemoryVectors.requireString(injectionFixture, "emptyIndex", "text"),
                memory.injection().text,
            )
        }
    }

    @Test
    fun invalidInjectionShapesAreRejected() {
        for (entry in MemoryVectors.objects(injectionFixture, "invalid")) {
            try {
                BotMemoryInjection.fromJson(entry.members["value"])
                fail("injection invalid ${MemoryVectors.string(entry, "reason")} was accepted")
            } catch (_: BotJsonException) {
                // expected
            }
        }
    }
}
