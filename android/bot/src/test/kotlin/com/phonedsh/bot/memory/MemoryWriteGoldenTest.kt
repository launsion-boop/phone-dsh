// SPDX-License-Identifier: MIT
package com.phonedsh.bot.memory

import com.phonedsh.agentcore.JsonArray
import com.phonedsh.agentcore.JsonObject
import com.phonedsh.bot.BotJson
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

/**
 * Drives every `memory-write.json` case through `BotMemory.write` and a real
 * SQLite event log. Author/source/trust/expectations all come from the golden.
 */
class MemoryWriteGoldenTest {
    private val fixture = MemoryVectors.golden("memory-write")

    private fun records(): Map<String, BotMemoryEvidenceRecord> {
        val raw = MemoryVectors.objectAt(fixture, "records")
        return raw.members.mapValues { (_, value) ->
            val members = value as JsonObject
            val botId = MemoryVectors.requireString(members, "botId")
            BotMemoryEvidenceRecord.fromJson(BotJson.canonical(value), botId)
        }
    }

    private fun seedState(store: BotMemoryDocumentStore, state: JsonObject) {
        val history = (state.members["history"] as? JsonObject)?.members ?: emptyMap()
        val seen = HashSet<String>()
        for (document in MemoryVectors.objects(state, "documents")) {
            val path = MemoryVectors.requireString(document, "path")
            if (seen.contains(path)) continue
            val entries = (history[path] as? JsonArray)?.values.orEmpty()
            if (entries.isNotEmpty()) {
                seedHistoryEntries(store, path, entries.map { it as JsonObject })
                seen += path
                continue
            }
            val content = MemoryVectors.requireString(document, "content")
            val version = MemoryVectors.long(document, "version")?.toInt() ?: 1
            seedDocument(store, path, content, version)
            seen += path
        }
        for ((path, entries) in history) {
            if (seen.contains(path)) continue
            seedHistoryEntries(store, path, (entries as JsonArray).values.map { it as JsonObject })
            seen += path
        }
    }

    private fun seedHistoryEntries(store: BotMemoryDocumentStore, path: String, entries: List<JsonObject>) {
        for (entry in entries.sortedBy {
            (it.members["version"] as com.phonedsh.agentcore.JsonNumber).asLongOrNull()?.toInt() ?: 0
        }) {
            val version = (entry.members["version"] as com.phonedsh.agentcore.JsonNumber)
                .asLongOrNull()!!.toInt()
            val deleted = (entry.members["deleted"] as? com.phonedsh.agentcore.JsonBool)?.value == true
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

    @Test
    fun everyWriteCaseMatchesTheGoldenAndWritesOneEventOnSuccess() {
        val cases = MemoryVectors.objects(fixture, "cases")
        assertTrue("memory-write.cases must not be empty", cases.isNotEmpty())
        for ((index, case) in cases.withIndex()) {
            val name = MemoryVectors.requireString(case, "name")
            MemoryHarness().use { harness ->
                val state = MemoryVectors.objectAt(case, "state")
                seedState(harness.store, state)
                val requestJson = MemoryVectors.objectAt(case, "request")
                val request = BotMemoryWriteRequest.fromJson(requestJson)
                MemoryVectors.assertMatchesSchema("memory-write-request", request.toJson())

                val author = MemoryVectors.objectAt(case, "author")
                val authorKind = BotMemoryAuthorKind.parse(
                    MemoryVectors.requireString(author, "kind"),
                )!!
                val sourceKind = BotMemorySourceKind.parse(
                    MemoryVectors.requireString(case, "sourceKind"),
                )!!
                val trust = BotMemoryTrust.parse(MemoryVectors.string(case, "trust"))
                val currentTurn = if (request.evidence.contains(BotMemoryEvidence.CURRENT_USER_TURN)) {
                    records().entries.first { (_, record) ->
                        record.botId == "bot-a" &&
                            record.kind == BotMemoryEvidenceRecord.Kind.SESSION &&
                            record.type == "user/message" &&
                            BotMemoryEvidence.isUserStatementRpc(record.rpcId)
                    }.key
                } else {
                    null
                }
                val memory = BotMemory(
                    store = harness.store,
                    botId = "bot-a",
                    now = { 1_760_000_000_000 },
                    prepareIndexes = false,
                )
                val before = harness.domain.headCommitSeq()
                val result = memory.write(
                    request,
                    writeContext(
                        botId = "bot-a",
                        sessionId = MemoryVectors.string(author, "session_id"),
                        authorKind = authorKind,
                        sourceKind = sourceKind,
                        trust = trust,
                        currentUserTurnReference = currentTurn,
                    ),
                )
                MemoryVectors.assertMatchesSchema("memory-write-result", result.toJson())
                val expect = MemoryVectors.objectAt(case, "expect")
                val expectedOk = (expect.members["ok"] as com.phonedsh.agentcore.JsonBool).value
                assertEquals("cases[$index] $name ok", expectedOk, result.ok)
                if (!expectedOk) {
                    assertTrue("cases[$index] $name must be a failure", result is BotMemoryWriteResult.Failure)
                    val failure = result as BotMemoryWriteResult.Failure
                    assertEquals(
                        "cases[$index] $name code",
                        MemoryVectors.requireString(expect, "code"),
                        failure.code,
                    )
                    MemoryVectors.long(expect, "current_version")?.let {
                        assertEquals(it.toInt(), failure.currentVersion)
                    }
                    assertEquals(
                        MemoryVectors.long(expect, "actual")?.toInt(),
                        failure.actual,
                    )
                    assertEquals(
                        MemoryVectors.long(expect, "limit")?.toInt(),
                        failure.limit,
                    )
                    assertEquals(
                        "cases[$index] $name must not write an event",
                        before,
                        harness.domain.headCommitSeq(),
                    )
                } else {
                    assertTrue("cases[$index] $name must be a success", result is BotMemoryWriteResult.Success)
                    val success = result as BotMemoryWriteResult.Success
                    assertEquals(
                        MemoryVectors.requireString(expect, "path"),
                        success.path,
                    )
                    assertEquals(
                        MemoryVectors.requireString(expect, "scope"),
                        success.scope.wire,
                    )
                    assertEquals(
                        MemoryVectors.requireLong(expect, "version").toInt(),
                        success.version,
                    )
                    MemoryVectors.long(expect, "replaced")?.let {
                        assertEquals(it.toInt(), success.replaced)
                    }
                    assertTrue(
                        "cases[$index] $name must append an event",
                        harness.domain.headCommitSeq() > before,
                    )
                    if (request.evidence.contains(BotMemoryEvidence.CURRENT_USER_TURN)) {
                        val stored = harness.store.document(success.path)!!
                        assertEquals(
                            listOf("record://session/gb-main#3"),
                            stored.evidence,
                        )
                    }
                }
            }
        }
    }

    @Test
    fun moveWritesTheDestinationAndTombstonesTheSourceInOneBatch() {
        MemoryHarness().use { harness ->
            seedDocument(harness.store, "agent/notes/a.md", "move me", 1)
            val memory = BotMemory(
                store = harness.store,
                botId = "bot-a",
                now = { 1_760_000_000_000 },
                prepareIndexes = false,
            )
            val result = memory.write(
                BotMemoryWriteRequest(
                    action = BotMemoryAction.MOVE,
                    path = "agent/notes/a.md",
                    to = "agent/notes/b.md",
                    expectedVersion = 1,
                ),
                writeContext(trust = BotMemoryTrust.ASSISTANT),
            )
            assertTrue("move must succeed", result is BotMemoryWriteResult.Success)
            val success = result as BotMemoryWriteResult.Success
            assertEquals("agent/notes/b.md", success.path)
            assertEquals(1, success.version)
            assertEquals("move me", harness.store.document("agent/notes/b.md")?.content)
            assertNull(harness.store.document("agent/notes/a.md"))
            val tombstone = harness.store.versions("agent/notes/a.md").last()
            assertTrue(tombstone.deleted)
            assertEquals("move", tombstone.deletionReason)
            val read = memory.read("agent/notes/a.md", tombstone.version)
            assertTrue(read is BotMemoryReadResult.Document)
            val json = (read as BotMemoryReadResult.Document).toJson()
            assertEquals(
                "forget",
                (json.members["deletion_reason"] as com.phonedsh.agentcore.JsonString).value,
            )
            MemoryVectors.assertMatchesSchema("memory-read-result", json)
        }
    }

    @Test
    fun malformedEvidenceFailsTheWriteWithoutAnEvent() {
        MemoryHarness().use { harness ->
            val memory = BotMemory(
                store = harness.store,
                botId = "bot-a",
                now = { 1_760_000_000_000 },
                prepareIndexes = false,
            )
            val before = harness.domain.headCommitSeq()
            val result = memory.write(
                BotMemoryWriteRequest(
                    action = BotMemoryAction.WRITE,
                    path = "agent/notes/a.md",
                    content = "x",
                    expectedVersion = 0,
                    evidence = listOf("record://session/gb-main"),
                ),
                writeContext(trust = BotMemoryTrust.ASSISTANT),
            )
            assertTrue(result is BotMemoryWriteResult.Failure)
            assertEquals("memory-evidence-invalid", (result as BotMemoryWriteResult.Failure).code)
            assertEquals(before, harness.domain.headCommitSeq())
            MemoryVectors.assertMatchesSchema("memory-write-result", result.toJson())
        }
    }

    @Test
    fun evidenceCasesDeriveTheFrozenTrustTable() {
        val evidenceCases = MemoryVectors.objectAt(fixture, "evidenceCases")
        val allRecords = records()
        for ((index, case) in MemoryVectors.objects(evidenceCases, "valid").withIndex()) {
            val name = MemoryVectors.requireString(case, "name")
            val refs = (case.members["evidence"]?.let { it } ?: case.members["refs"])
                ?.let { (it as JsonArray).values.map { value -> (value as com.phonedsh.agentcore.JsonString).value } }
                ?: emptyList()
            val turn = MemoryVectors.string(case, "turn") ?: "user-turn"
            val sourceKind = if (turn == "user-turn") {
                BotMemorySourceKind.USER_TURN
            } else {
                BotMemorySourceKind.HIDDEN_WAKE
            }
            val trust = BotMemoryEvidence.deriveTrust(
                records = allRecords,
                references = refs,
                callerBotId = "bot-a",
                currentUserTurnReference = MemoryVectors.string(case, "currentUserTurn"),
                sourceKind = sourceKind,
            )
            assertEquals("evidence.valid[$index] $name trust", MemoryVectors.requireString(case, "trust"), trust.wire)
            assertEquals(
                "evidence.valid[$index] $name boundary",
                (case.members["userBoundary"] as com.phonedsh.agentcore.JsonBool).value,
                trust == BotMemoryTrust.USER,
            )
        }
        for ((index, case) in MemoryVectors.objects(evidenceCases, "invalid").withIndex()) {
            val refs = (case.members["refs"] as JsonArray).values
                .map { (it as com.phonedsh.agentcore.JsonString).value }
            val turn = MemoryVectors.string(case, "turn") ?: "user-turn"
            val sourceKind = if (turn == "user-turn") {
                BotMemorySourceKind.USER_TURN
            } else {
                BotMemorySourceKind.HIDDEN_WAKE
            }
            try {
                BotMemoryEvidence.deriveTrust(
                    records = allRecords,
                    references = refs,
                    callerBotId = "bot-a",
                    currentUserTurnReference = MemoryVectors.string(case, "currentUserTurn"),
                    sourceKind = sourceKind,
                )
                fail("evidence.invalid[$index] was accepted")
            } catch (error: BotMemoryEvidenceException) {
                assertEquals(
                    "evidence.invalid[$index] code",
                    MemoryVectors.requireString(case, "error"),
                    error.code,
                )
            }
        }
    }

    @Test
    fun boundaryCasesMatchTheSourceAndEvidenceRules() {
        for ((index, case) in MemoryVectors.objects(fixture, "boundaryCases").withIndex()) {
            val sourceKind = BotMemorySourceKind.parse(
                MemoryVectors.requireString(case, "sourceKind"),
            )!!
            val authorKind = when (sourceKind) {
                BotMemorySourceKind.TASK -> BotMemoryAuthorKind.TASK
                BotMemorySourceKind.ROUTINE -> BotMemoryAuthorKind.ROUTINE
                BotMemorySourceKind.MAINTENANCE -> BotMemoryAuthorKind.MAINTAINER
                else -> BotMemoryAuthorKind.CHAT
            }
            val path = MemoryVectors.requireString(case, "path")
            val author = BotMemoryAuthor(
                botId = "bot-a",
                sessionId = MemoryVectors.string(case, "sessionId"),
                kind = authorKind,
            )
            val permission = BotMemoryPath.scopeDenial(author, path)
            val boundary = BotMemoryPath.userBoundaryError(
                sourceKind = sourceKind,
                trust = BotMemoryTrust.parse(MemoryVectors.string(case, "trust")),
                path = path,
                authorKind = authorKind,
            )
            val actual = permission ?: boundary
            val expected = if ((case.members["ok"] as com.phonedsh.agentcore.JsonBool).value) {
                null
            } else {
                MemoryVectors.requireString(case, "error")
            }
            assertEquals("boundaryCases[$index] ${MemoryVectors.string(case, "name")}", expected, actual)
        }
    }

    @Test
    fun visibilityCasesFilterAgentPathsByBotAndShareUserPaths() {
        for (case in MemoryVectors.objects(fixture, "visibilityCases")) {
            MemoryHarness().use { harness ->
                val documents = MemoryVectors.objects(case, "documents")
                for (document in documents) {
                    val path = MemoryVectors.requireString(document, "path")
                    seedDocument(harness.store, path, "content", 1)
                }
                val reader = MemoryVectors.requireString(case, "reader")
                val visible = harness.storeFor(reader).documents()
                    .map { it.path }
                    .filter { path -> documents.any { MemoryVectors.requireString(it, "path") == path } }
                    .sorted()
                val expected = (case.members["visible"] as JsonArray).values
                    .map { (it as com.phonedsh.agentcore.JsonString).value }
                    .sorted()
                assertEquals(
                    "visibility ${MemoryVectors.string(case, "name")}",
                    expected,
                    visible,
                )
            }
        }
    }

    @Test
    fun reservedCurrentTurnValueRequiresARealUserTurn() {
        val records = records()
        val userRef = records.entries.first { (_, record) ->
            record.type == "user/message" && record.rpcId == "bot-1"
        }.key
        assertEquals(
            listOf(userRef),
            BotMemoryEvidence.resolveForWrite(
                listOf(BotMemoryEvidence.CURRENT_USER_TURN),
                BotMemorySourceKind.USER_TURN,
                userRef,
            ),
        )
        for (source in listOf(BotMemorySourceKind.HIDDEN_WAKE, BotMemorySourceKind.MAINTENANCE)) {
            try {
                BotMemoryEvidence.resolveForWrite(
                    listOf(BotMemoryEvidence.CURRENT_USER_TURN), source, userRef,
                )
                fail("current-user-turn must be invalid in $source")
            } catch (_: BotMemoryEvidenceException) {
                // expected
            }
        }
        assertNull(BotMemoryEvidence.parse("current-user-turn"))
    }
}
