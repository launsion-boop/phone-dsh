// SPDX-License-Identifier: MIT
package com.phonedsh.bot.memory

import com.phonedsh.agentcore.JsonArray
import com.phonedsh.agentcore.JsonObject
import com.phonedsh.agentcore.JsonString
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Drives `memory-erasure.json` through the planner and a real SQLite erasure. */
class MemoryErasureGoldenTest {
    private val fixture = MemoryVectors.golden("memory-erasure")

    @Test
    fun everyErasureCaseMatchesTheGoldenPlan() {
        for ((index, case) in MemoryVectors.objects(fixture, "cases").withIndex()) {
            val name = MemoryVectors.requireString(case, "name")
            val target = MemoryVectors.objectAt(case, "target")
            val scope = BotMemoryScope.parse(MemoryVectors.string(target, "scope"))
            val path = MemoryVectors.string(target, "path")
            val documents = MemoryVectors.objects(case, "state", "documents").map { document ->
                BotMemoryErasureStateDocument(
                    path = MemoryVectors.requireString(document, "path"),
                    scope = BotMemoryScope.parse(MemoryVectors.requireString(document, "scope"))!!,
                    botId = MemoryVectors.requireString(document, "botId"),
                    live = MemoryVectors.bool(document, "live") ?: false,
                    versions = MemoryVectors.objects(document, "versions").map { version ->
                        BotMemoryErasureVersion(
                            version = MemoryVectors.requireLong(version, "version").toInt(),
                            content = MemoryVectors.string(version, "content").orEmpty(),
                            deleted = MemoryVectors.bool(version, "deleted") ?: false,
                        )
                    },
                    evidence = (document.members["evidence"] as? JsonArray)?.values
                        ?.map { (it as JsonString).value } ?: emptyList(),
                )
            }
            val events = MemoryVectors.objects(case, "state", "events").map { event ->
                BotMemoryErasureStateEvent(
                    seq = MemoryVectors.requireLong(event, "seq"),
                    type = MemoryVectors.requireString(event, "type"),
                    botId = MemoryVectors.string(event, "botId"),
                    path = MemoryVectors.string(event, "path"),
                    text = MemoryVectors.string(event, "text"),
                    refs = (event.members["refs"] as? JsonArray)?.values
                        ?.map { (it as JsonString).value } ?: emptyList(),
                )
            }
            val result = BotMemoryErasurePlanner.plan(
                BotMemoryErasureTarget(scope, path),
                MemoryVectors.requireString(case, "botID"),
                documents,
                events,
            )
            assertNull("cases[$index] $name: ${result.error}", result.error)
            val plan = result.plan!!
            val expect = MemoryVectors.objectAt(case, "expect")
            assertEquals("cases[$index] $name ok", MemoryVectors.bool(expect, "ok"), true)
            assertEquals("cases[$index] $name scope", MemoryVectors.requireString(expect, "scope"), plan.scope.wire)
            assertEquals(
                "cases[$index] $name paths",
                (expect.members["paths"] as JsonArray).values.map { (it as JsonString).value },
                plan.paths,
            )
            assertEquals(
                "cases[$index] $name removedDocuments",
                MemoryVectors.requireLong(expect, "removedDocuments").toInt(),
                plan.removedDocuments,
            )
            assertEquals(
                "cases[$index] $name removedVersions",
                MemoryVectors.requireLong(expect, "removedVersions").toInt(),
                plan.removedVersions,
            )
            assertEquals(
                "cases[$index] $name erasedEvents",
                (expect.members["erasedEvents"] as JsonArray).values
                    .map { (it as com.phonedsh.agentcore.JsonNumber).asLongOrNull()!! },
                plan.erasedEvents,
            )
            assertEquals(
                "cases[$index] $name survivingPaths",
                (expect.members["survivingPaths"] as JsonArray).values.map { (it as JsonString).value },
                plan.survivingPaths,
            )
            assertEquals(
                "cases[$index] $name uncoveredRecords",
                (expect.members["uncoveredRecords"] as JsonArray).values.map { (it as JsonString).value },
                plan.uncoveredRecords,
            )
            assertEquals(
                "cases[$index] $name legacyFactIDs",
                (expect.members["legacyFactIDs"] as JsonArray).values.map { (it as JsonString).value },
                plan.legacyFactIds,
            )
            for (range in plan.memoryVersions) {
                assertTrue(BotMemoryPath.parse(range.path) != null)
                assertTrue(range.versions.isNotEmpty())
            }
        }
    }

    @Test
    fun everyInvalidErasureTargetIsRejected() {
        for ((index, case) in MemoryVectors.objects(fixture, "invalid").withIndex()) {
            val target = MemoryVectors.objectAt(case, "target")
            val result = BotMemoryErasurePlanner.plan(
                BotMemoryErasureTarget(
                    scope = BotMemoryScope.parse(MemoryVectors.string(target, "scope")),
                    path = MemoryVectors.string(target, "path"),
                ),
                MemoryVectors.requireString(case, "botID"),
                emptyList(),
                emptyList(),
            )
            assertNull("invalid[$index] plan", result.plan)
            assertEquals(
                "invalid[$index] ${MemoryVectors.string(case, "name")}",
                MemoryVectors.requireString(case, "error"),
                result.error,
            )
        }
    }

    @Test
    fun physicalEraseClearsEveryVersionAndDerivedCopiesButKeepsOtherDocuments() {
        val case = MemoryVectors.objects(fixture, "cases")
            .first { MemoryVectors.string(it, "name") == "single-document-all-versions-and-derived-copies" }
        val target = MemoryVectors.objectAt(case, "target")
        val secretPath = MemoryVectors.requireString(target, "path")
        val documents = MemoryVectors.objects(case, "state", "documents")
        val secretDocument = documents.first { MemoryVectors.requireString(it, "path") == secretPath }
        val secretVersions = MemoryVectors.objects(secretDocument, "versions")
        val secretEvidence = (secretDocument.members["evidence"] as JsonArray).values
            .map { (it as JsonString).value }
        val keepDocument = documents.first { MemoryVectors.requireString(it, "path") != secretPath }
        val keepPath = MemoryVectors.requireString(keepDocument, "path")
        val keepContent = MemoryVectors.requireString(
            MemoryVectors.objects(keepDocument, "versions").first(), "content",
        )
        val expect = MemoryVectors.objectAt(case, "expect")
        val expectedErased = (expect.members["erasedEvents"] as JsonArray).values
            .map { (it as com.phonedsh.agentcore.JsonNumber).asLongOrNull()!! }
        val expectedPaths = (expect.members["paths"] as JsonArray).values
            .map { (it as JsonString).value }

        MemoryHarness().use { harness ->
            for ((index, version) in secretVersions.withIndex()) {
                writeDocumentVersion(
                    harness.store,
                    secretPath,
                    MemoryVectors.requireString(version, "content"),
                    index,
                    evidence = secretEvidence,
                    atMs = 1_760_000_000_001 + index,
                )
            }
            writeDocumentVersion(harness.store, keepPath, keepContent, 0, atMs = 1_760_000_000_003)
            val events = MemoryVectors.objects(case, "state", "events")
            for (event in events) {
                when (MemoryVectors.requireString(event, "type")) {
                    "conversation.user_message" -> harness.append(
                        type = "conversation.user_message",
                        eventId = "copy-1",
                        data = JsonObject(
                            mapOf("text" to JsonString(MemoryVectors.requireString(event, "text"))),
                        ),
                    )
                    "redaction.applied" -> harness.append(
                        type = "redaction.applied",
                        eventId = "redaction-1",
                        data = JsonObject(
                            mapOf(
                                "refs" to JsonArray(
                                    (event.members["refs"] as JsonArray).values.map { it },
                                ),
                            ),
                        ),
                    )
                    "ui.notice" -> harness.append(
                        type = "ui.notice",
                        eventId = "notice-1",
                        data = JsonObject(
                            mapOf("text" to JsonString(MemoryVectors.requireString(event, "text"))),
                        ),
                    )
                }
            }
            val committed = harness.domain.events(0, 100)
            assertEquals(
                (0 until committed.size).map { (it + 1).toLong() },
                committed.map { it.commitSeq },
            )

            val outcome = harness.store.erase(
                path = secretPath,
                author = BotMemoryAuthor("bot-a", null, BotMemoryAuthorKind.UI),
                atMs = 1_760_000_000_000,
            )
            assertTrue("erase must succeed", outcome.ok)
            assertEquals(BotMemoryScope.AGENT, outcome.scope)
            assertEquals(expectedPaths, outcome.paths)
            assertEquals(
                MemoryVectors.requireLong(expect, "removedDocuments").toInt(),
                outcome.removedDocuments,
            )
            assertEquals(
                MemoryVectors.requireLong(expect, "removedVersions").toInt(),
                outcome.removedVersions,
            )
            assertEquals(expectedErased, outcome.erasedEventSequences)
            assertEquals(expectedErased.size, outcome.erasedEvents)
            assertEquals(
                (expect.members["uncoveredRecords"] as JsonArray).values
                    .map { (it as JsonString).value },
                outcome.uncoveredRecords,
            )
            val erasureEventSeq = MemoryVectors.requireLong(case, "state", "erasureEventSeq")
            assertEquals("record://event/$erasureEventSeq", outcome.erasureRecord)

            val eventsAfter = harness.domain.events(0, 100)
            for (sequence in expectedErased) {
                val event = eventsAfter.first { it.commitSeq == sequence }
                val data = event.data as JsonObject
                assertEquals("event $sequence payload must be erased", true,
                    (data.members["\$erased"] as com.phonedsh.agentcore.JsonBool)?.value)
            }
            val keep = eventsAfter.first { it.eventId == "notice-1" }
            assertEquals("unrelated", (keep.data as JsonObject).members["text"]?.let {
                (it as JsonString).value
            })
            assertEquals(keepContent, harness.store.document(keepPath)?.content)
            assertNull(harness.store.document(secretPath))
            assertTrue(harness.store.versions(secretPath).isEmpty())

            val erasure = eventsAfter.first { it.type == "erasure" }
            val data = erasure.data as JsonObject
            val schema = MemoryVectors.v1Schema("erasure-event")
            val required = (schema.members["required"] as JsonArray).values
                .map { (it as JsonString).value }
            for (key in required) {
                assertTrue("erasure event is missing $key", data.members.containsKey(key))
            }
            assertEquals("1", (schema.members["properties"] as JsonObject)
                .members["schemaVersion"]?.let {
                    ((it as JsonObject).members["const"] as com.phonedsh.agentcore.JsonNumber).raw
                })
            assertEquals("user", (data.members["requestedBy"] as JsonString).value)
            assertEquals("memory-document-erase", (data.members["reason"] as JsonString).value)
            assertEquals(
                expectedPaths,
                (data.members["targets"] as JsonArray).values.map {
                    ((it as JsonObject).members["path"] as JsonString).value
                },
            )
            assertEquals(
                secretVersions.map { MemoryVectors.requireLong(it, "version") },
                (data.members["memoryVersions"] as JsonArray).values.flatMap {
                    ((it as JsonObject).members["versions"] as JsonArray).values.map { version ->
                        (version as com.phonedsh.agentcore.JsonNumber).asLongOrNull()!!
                    }
                },
            )
            assertEquals(
                expectedErased,
                (data.members["erasedEvents"] as JsonArray).values.map {
                    ((it as JsonObject).members["record"] as JsonString).value
                        .removePrefix("record://event/").toLong()
                },
            )
            assertEquals(
                outcome.uncoveredRecords,
                (data.members["uncoveredRecords"] as JsonArray).values.map {
                    ((it as JsonObject).members["record"] as JsonString).value
                },
            )

            // A fresh store replays the tombstones and must not resurrect any
            // version of the erased document.
            val reopened = harness.storeFor("bot-a")
            assertNull(reopened.document(secretPath))
            assertTrue(reopened.versions(secretPath).isEmpty())
            assertEquals(keepContent, reopened.document(keepPath)?.content)

            val head = harness.domain.headCommitSeq()
            val second = harness.store.erase(
                path = secretPath,
                author = BotMemoryAuthor("bot-a", null, BotMemoryAuthorKind.UI),
                atMs = 1_760_000_000_001,
            )
            assertFalse(second.ok)
            assertEquals("memory-not-found", second.error)
            assertEquals("a repeated erase must not write a second erasure event", head,
                harness.domain.headCommitSeq())
        }
    }

    @Test
    fun erasingADocumentAlsoClearsLegacyFactCopiesAndReportsTheirIds() {
        MemoryHarness().use { harness ->
            writeDocumentVersion(
                harness.store, "agent/notes/secret.md", "# Secret\n- LEGACY_COPY_MARKER_9", 0,
            )
            harness.append(
                type = "memory.written",
                eventId = "legacy-fact-copy",
                data = JsonObject(
                    linkedMapOf(
                        "fact_id" to JsonString("fact-copy"),
                        "text" to JsonString("the legacy fact says LEGACY_COPY_MARKER_9"),
                        "learned_at_ms" to com.phonedsh.agentcore.JsonNumber("1760000000000"),
                        "tier" to JsonString("note"),
                        "scope" to JsonString("agent"),
                    ),
                ),
            )
            val outcome = harness.store.erase(
                path = "agent/notes/secret.md",
                author = BotMemoryAuthor("bot-a", null, BotMemoryAuthorKind.UI),
                atMs = 1_760_000_000_000,
            )
            assertTrue(outcome.ok)
            assertEquals(listOf("fact-copy"), outcome.legacyFactIds)
            assertTrue(outcome.erasedEventSequences.contains(2L))
        }
    }

    @Test
    fun agentScopeEraseStaysInsideTheWritingBotAndLeavesUserMemoryAlone() {
        MemoryHarness().use { harness ->
            seedDocument(harness.store, "agent/private.md", "MAIN_AGENT_MARKER_11", 1)
            seedDocument(
                harness.storeFor("bot-b"), "agent/private.md", "OTHER_AGENT_MARKER_22", 1,
                author = BotMemoryAuthor("bot-b", "gb-main-b", BotMemoryAuthorKind.CHAT),
            )
            seedDocument(harness.store, "user/shared.md", "USER_MARKER_33", 1)
            harness.store.erase(
                scope = BotMemoryScope.AGENT,
                author = BotMemoryAuthor("bot-a", null, BotMemoryAuthorKind.UI),
                atMs = 1_760_000_000_000,
            )
            assertNull(harness.store.document("agent/private.md"))
            assertEquals("OTHER_AGENT_MARKER_22",
                harness.storeFor("bot-b").document("agent/private.md")?.content)
            assertEquals("USER_MARKER_33", harness.store.document("user/shared.md")?.content)
        }
    }

    @Test
    fun userScopeEraseCrossesBotsAndClearsSharedDocuments() {
        MemoryHarness().use { harness ->
            seedDocument(harness.store, "user/profile.md", "USER_MARKER_33", 1)
            val botB = harness.storeFor("bot-b")
            assertEquals("USER_MARKER_33", botB.document("user/profile.md")?.content)
            val outcome = botB.erase(
                scope = BotMemoryScope.USER,
                author = BotMemoryAuthor("bot-b", null, BotMemoryAuthorKind.UI),
                atMs = 1_760_000_000_000,
            )
            assertTrue(outcome.ok)
            assertEquals(listOf("user/profile.md"), outcome.paths)
            assertNull(harness.store.document("user/profile.md"))
            assertNull(botB.document("user/profile.md"))
        }
    }

    @Test
    fun sessionEraserReportIsCarriedIntoTheErasureEvent() {
        MemoryHarness().use { harness ->
            seedDocument(
                harness.store, "user/profile.md", "USER_MARKER_33", 1,
                evidence = listOf("record://session/gb-main#3"),
            )
            val outcome = harness.store.erase(
                path = "user/profile.md",
                author = BotMemoryAuthor("bot-a", "gb-main", BotMemoryAuthorKind.UI),
                atMs = 1_760_000_000_000,
                sessionEraser = BotMemorySessionEraser {
                    BotMemorySessionErasureReport(
                        erasedSessionRecords = listOf(
                            JsonObject(
                                mapOf(
                                    "record" to JsonString("record://session/gb-main#3"),
                                    "sessionId" to JsonString("gb-main"),
                                    "seq" to com.phonedsh.agentcore.JsonNumber("3"),
                                ),
                            ),
                        ),
                        uncoveredRecords = listOf(
                            BotMemoryUncoveredRecord(
                                "record://session/gb-main#3",
                                "session-log-session-not-closed",
                            ),
                        ),
                    )
                },
            )
            assertTrue(outcome.ok)
            assertEquals(1, outcome.erasedSessionRecords.size)
            assertEquals(
                listOf("record://session/gb-main#3"),
                outcome.uncoveredRecords,
            )
        }
    }
}
