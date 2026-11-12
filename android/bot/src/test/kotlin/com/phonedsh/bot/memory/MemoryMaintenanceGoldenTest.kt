// SPDX-License-Identifier: MIT
package com.phonedsh.bot.memory

import com.phonedsh.agentcore.JsonArray
import com.phonedsh.agentcore.JsonNumber
import com.phonedsh.agentcore.JsonObject
import com.phonedsh.agentcore.JsonString
import com.phonedsh.bot.BotJsonException
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

/** Drives `memory-maintenance.json` and the real batch/rollback event lifecycle. */
class MemoryMaintenanceGoldenTest {
    private val fixture = MemoryVectors.golden("memory-maintenance")

    @Test
    fun everyValidStartBatchAndRollbackRoundTripsAndMatchesTheSchema() {
        val start = BotMemoryMaintenanceStart.fromJson(
            MemoryVectors.objectAt(fixture, "valid", "start"),
        )
        assertEquals(MemoryVectors.canonical(MemoryVectors.objectAt(fixture, "valid", "start")),
            MemoryVectors.canonical(start.toJson()))
        MemoryVectors.assertMatchesSchema("memory-maintenance-start", start.toJson())

        for (name in listOf("committed", "cancelled", "rolledBack")) {
            val value = MemoryVectors.objectAt(fixture, "valid", name)
            val batch = BotMemoryMaintenanceBatch.fromJson(value)
            assertEquals(
                "valid.$name",
                MemoryVectors.canonical(value),
                MemoryVectors.canonical(batch.toJson()),
            )
            MemoryVectors.assertMatchesSchema("memory-maintenance", batch.toJson())
        }
        val rollbackValue = MemoryVectors.objectAt(fixture, "valid", "rollback")
        val rollback = BotMemoryMaintenanceRollback.fromJson(rollbackValue)
        assertEquals(
            MemoryVectors.canonical(rollbackValue),
            MemoryVectors.canonical(rollback.toJson()),
        )
        MemoryVectors.assertMatchesSchema("memory-maintenance-rollback", rollback.toJson())
    }

    @Test
    fun everyInvalidMaintenanceShapeIsRejected() {
        val invalid = MemoryVectors.objectAt(fixture, "invalid")
        for ((name, value) in invalid.members) {
            try {
                when {
                    name.startsWith("start") -> BotMemoryMaintenanceStart.fromJson(value)
                    name.startsWith("finished") -> BotMemoryMaintenanceBatch.fromJson(value)
                    else -> BotMemoryMaintenanceRollback.fromJson(value)
                }
                fail("invalid.$name was accepted")
            } catch (_: BotJsonException) {
                // expected
            }
        }
    }

    @Test
    fun everyCheckCaseReturnsTheGoldenFailureCode() {
        for ((index, case) in MemoryVectors.objects(fixture, "checkCases").withIndex()) {
            val name = MemoryVectors.requireString(case, "name")
            val records = LinkedHashMap<String, BotMemoryMaintenanceCheckRecord>()
            val recordsObject = (case.members["records"] as? JsonObject)?.members ?: emptyMap()
            for ((reference, recordValue) in recordsObject) {
                val record = recordValue as JsonObject
                records[reference] = BotMemoryMaintenanceCheckRecord(
                    botId = MemoryVectors.requireString(record, "botId"),
                    trust = BotMemoryTrust.parse(MemoryVectors.string(record, "trust")),
                    text = MemoryVectors.string(record, "text").orEmpty(),
                )
            }
            val documents = MemoryVectors.objects(case, "documents").map { document ->
                BotMemoryMaintenanceCheckDocument(
                    path = MemoryVectors.requireString(document, "path"),
                    content = MemoryVectors.requireString(document, "content"),
                    evidence = (document.members["evidence"] as? JsonArray)?.values
                        ?.map { (it as JsonString).value } ?: emptyList(),
                )
            }
            val indexOverrides = LinkedHashMap<String, Int>()
            (case.members["indexOverrides"] as? JsonObject)?.members?.forEach { (path, value) ->
                indexOverrides[path] = (value as JsonNumber).asLongOrNull()!!.toInt()
            }
            val input = BotMemoryMaintenanceCheckInput(
                botId = MemoryVectors.requireString(case, "botId"),
                isMainBot = (case.members["isMainBot"] as? com.phonedsh.agentcore.JsonBool)?.value ?: true,
                documents = documents,
                records = records,
                changedDocuments = MemoryVectors.long(case, "changedDocuments")?.toInt() ?: 0,
                changedScalars = MemoryVectors.long(case, "changedScalars")?.toInt() ?: 0,
                indexOverrides = indexOverrides,
            )
            assertEquals(
                "checkCases[$index] $name",
                MemoryVectors.string(case, "expected"),
                BotMemoryMaintenanceChecker.checkCode(input),
            )
        }
    }

    @Test
    fun rollbackCasesCheckBatchIdentityAndVersionPremises() {
        val valid = MemoryVectors.objectAt(fixture, "valid")
        for ((index, case) in MemoryVectors.objects(fixture, "rollbackCases").withIndex()) {
            val batchName = MemoryVectors.requireString(case, "batch")
            val batch = BotMemoryMaintenanceBatch.fromJson(MemoryVectors.objectAt(valid, batchName))
            val rollback = BotMemoryMaintenanceRollback.fromJson(
                MemoryVectors.objectAt(case, "rollback"),
            )
            assertEquals(
                "rollbackCases[$index] ${MemoryVectors.string(case, "name")}",
                MemoryVectors.string(case, "expected"),
                BotMemoryMaintenanceChecker.rollbackConflict(batch, rollback),
            )
        }
    }

    @Test
    fun failedCheckRollsBackTheWholeBatchAndRestoresTheBeforeVersion() {
        MemoryHarness().use { harness ->
            seedDocument(harness.store, "agent/profile.md", "base", 1)
            val memory = harness.memoryFor("bot-a")
            val batches = BotMemoryMaintenanceBatchStore(
                eventLog = harness.eventLog,
                memory = memory,
                botId = "bot-a",
                now = { 1_760_000_000_000 },
            )
            val batchId = "mm-0123456789abcdef0123456789abcdef"
            batches.begin(start(batchId))
            val write = memory.write(
                BotMemoryWriteRequest(
                    action = BotMemoryAction.WRITE,
                    path = "agent/profile.md",
                    content = "这里是一段被扩写得很长很长的转述，远超原始记录，说明没有完成抽象。",
                    expectedVersion = 1,
                    evidence = listOf("record://event/77"),
                ),
                writeContext(
                    trust = BotMemoryTrust.ASSISTANT,
                    batchId = batchId,
                ),
            )
            assertTrue("write must succeed before the check", write.ok)
            val checkInput = BotMemoryMaintenanceCheckInput(
                botId = "bot-a",
                records = mapOf(
                    "record://event/77" to BotMemoryMaintenanceCheckRecord(
                        botId = "bot-a",
                        trust = BotMemoryTrust.ASSISTANT,
                        text = "短原文。",
                    ),
                ),
            )
            val batch = batches.evaluateAndFinish(
                batchId = batchId,
                trigger = BotMemoryMaintenanceTrigger.CONTRADICTION,
                startedAtMs = 1_760_000_000_000,
                maintainerSessionId = maintainerSession,
                turnStatus = "completed",
                checkInput = checkInput,
                budget = BotMemoryMaintenanceBudget(32_000, 96_000, tokensUsed = 1_234),
            )
            assertEquals(BotMemoryMaintenanceStatus.ROLLED_BACK, batch.status)
            assertEquals(
                BotMemoryMaintenanceFailureCode.DOCUMENT_LONGER_THAN_EVIDENCE.wire,
                batch.failureCode,
            )
            assertEquals(1, batch.changes.size)
            assertTrue(batch.checks.documentsNotLongerThanEvidence == false)
            assertEquals(false, batch.notification)
            MemoryVectors.assertMatchesSchema("memory-maintenance", batch.toJson())

            val live = memory.read("agent/profile.md") as BotMemoryReadResult.Document
            assertEquals("base", live.version.content)
            assertEquals(3, live.version.version)
            val first = memory.read("agent/profile.md", 1) as BotMemoryReadResult.Document
            assertEquals("base", first.version.content)
            assertEquals(false, first.version.deleted)
            assertTrue(batches.lastBatch()!!.status == BotMemoryMaintenanceStatus.ROLLED_BACK)
            val rolledBack = batches.batches()
            assertEquals(1, rolledBack.size)
            assertTrue(
                harness.domain.events(0, 100).any { it.type == "memory.maintenance_rolled_back" },
            )
        }
    }

    @Test
    fun committedBatchCanBeRolledBackFromTheMemoryPage() {
        MemoryHarness().use { harness ->
            seedDocument(harness.store, "agent/profile.md", "base", 1)
            val memory = harness.memoryFor("bot-a")
            val batches = BotMemoryMaintenanceBatchStore(
                eventLog = harness.eventLog,
                memory = memory,
                botId = "bot-a",
                now = { 1_760_000_000_000 },
            )
            val batchId = "mm-fedcba9876543210fedcba9876543210"
            batches.begin(start(batchId, BotMemoryMaintenanceTrigger.MANUAL))
            val write = memory.write(
                BotMemoryWriteRequest(
                    action = BotMemoryAction.WRITE,
                    path = "agent/profile.md",
                    content = "kept",
                    expectedVersion = 1,
                ),
                writeContext(trust = BotMemoryTrust.ASSISTANT, batchId = batchId),
            )
            assertTrue(write.ok)
            val batch = batches.evaluateAndFinish(
                batchId = batchId,
                trigger = BotMemoryMaintenanceTrigger.MANUAL,
                startedAtMs = 1_760_000_000_000,
                maintainerSessionId = maintainerSession,
                turnStatus = "completed",
                checkInput = BotMemoryMaintenanceCheckInput(botId = "bot-a"),
                budget = BotMemoryMaintenanceBudget(32_000, 96_000, tokensUsed = 100),
            )
            assertEquals(BotMemoryMaintenanceStatus.COMMITTED, batch.status)
            assertNull(batch.failureCode)
            assertEquals("kept", (memory.read("agent/profile.md") as BotMemoryReadResult.Document).version.content)

            val rollback = batches.rollback(batchId)!!
            assertEquals(
                listOf(BotMemoryMaintenanceRestore("agent/profile.md", 2, 3)),
                rollback.restored,
            )
            assertTrue(rollback.conflicts.isEmpty())
            MemoryVectors.assertMatchesSchema("memory-maintenance-rollback", rollback.toJson())
            val restored = memory.read("agent/profile.md") as BotMemoryReadResult.Document
            assertEquals("base", restored.version.content)
            assertEquals(3, restored.version.version)
        }
    }

    @Test
    fun rollbackOfADocumentCreatedInTheBatchRecordsADeletionVersion() {
        MemoryHarness().use { harness ->
            val memory = harness.memoryFor("bot-a")
            val batches = BotMemoryMaintenanceBatchStore(
                eventLog = harness.eventLog,
                memory = memory,
                botId = "bot-a",
                now = { 1_760_000_000_000 },
            )
            val batchId = "mm-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
            batches.begin(start(batchId))
            val write = memory.write(
                BotMemoryWriteRequest(
                    action = BotMemoryAction.WRITE,
                    path = "agent/new.md",
                    content = "这里是一段被扩写得很长很长的转述，远超原始记录。",
                    expectedVersion = 0,
                    evidence = listOf("record://event/77"),
                ),
                writeContext(trust = BotMemoryTrust.ASSISTANT, batchId = batchId),
            )
            assertTrue(write.ok)
            val batch = batches.evaluateAndFinish(
                batchId = batchId,
                trigger = BotMemoryMaintenanceTrigger.CONTRADICTION,
                startedAtMs = 1_760_000_000_000,
                maintainerSessionId = maintainerSession,
                turnStatus = "completed",
                checkInput = BotMemoryMaintenanceCheckInput(
                    botId = "bot-a",
                    records = mapOf(
                        "record://event/77" to BotMemoryMaintenanceCheckRecord(
                            "bot-a", BotMemoryTrust.ASSISTANT, "短。",
                        ),
                    ),
                ),
                budget = BotMemoryMaintenanceBudget(32_000, 96_000),
            )
            assertEquals(BotMemoryMaintenanceStatus.ROLLED_BACK, batch.status)
            val rollback = batches.lastRollback(batchId)!!
            assertEquals(1, rollback.restored.size)
            assertEquals(1, rollback.restored[0].fromVersion)
            assertEquals(2, rollback.restored[0].toVersion)
            assertTrue(rollback.restored[0].toVersion >= 1)
            val deleted = memory.read("agent/new.md", 2) as BotMemoryReadResult.Document
            assertTrue(deleted.version.deleted)
            assertTrue(memory.read("agent/new.md") is BotMemoryReadResult.Failure)
        }
    }

    @Test
    fun rollbackConflictIsReportedAndTheOtherBatchDocumentsStillRestore() {
        MemoryHarness().use { harness ->
            seedDocument(harness.store, "agent/one.md", "one-base", 1)
            seedDocument(harness.store, "agent/two.md", "two-base", 1)
            val memory = harness.memoryFor("bot-a")
            val batches = BotMemoryMaintenanceBatchStore(
                eventLog = harness.eventLog,
                memory = memory,
                botId = "bot-a",
                now = { 1_760_000_000_000 },
            )
            val batchId = "mm-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
            batches.begin(start(batchId))
            assertTrue(memory.write(
                BotMemoryWriteRequest(
                    action = BotMemoryAction.WRITE,
                    path = "agent/one.md",
                    content = "one-batch",
                    expectedVersion = 1,
                ),
                writeContext(trust = BotMemoryTrust.ASSISTANT, batchId = batchId),
            ).ok)
            assertTrue(memory.write(
                BotMemoryWriteRequest(
                    action = BotMemoryAction.WRITE,
                    path = "agent/two.md",
                    content = "two-batch",
                    expectedVersion = 1,
                ),
                writeContext(trust = BotMemoryTrust.ASSISTANT, batchId = batchId),
            ).ok)
            // A later writer changes one path after the batch; the rollback
            // must not overwrite it.
            assertTrue(memory.write(
                BotMemoryWriteRequest(
                    action = BotMemoryAction.WRITE,
                    path = "agent/one.md",
                    content = "one-later",
                    expectedVersion = 2,
                ),
                writeContext(trust = BotMemoryTrust.ASSISTANT),
            ).ok)
            val batch = batches.evaluateAndFinish(
                batchId = batchId,
                trigger = BotMemoryMaintenanceTrigger.MANUAL,
                startedAtMs = 1_760_000_000_000,
                maintainerSessionId = maintainerSession,
                turnStatus = "completed",
                checkInput = BotMemoryMaintenanceCheckInput(
                    botId = "bot-a",
                    documents = listOf(
                        BotMemoryMaintenanceCheckDocument(
                            "agent/three.md",
                            "这里是一段被扩写得很长很长的转述，远超原始记录。",
                            listOf("record://event/77"),
                        ),
                    ),
                    records = mapOf(
                        "record://event/77" to BotMemoryMaintenanceCheckRecord(
                            "bot-a", BotMemoryTrust.ASSISTANT, "短。",
                        ),
                    ),
                ),
                budget = BotMemoryMaintenanceBudget(32_000, 96_000),
            )
            assertEquals(BotMemoryMaintenanceStatus.ROLLBACK_FAILED, batch.status)
            assertEquals(
                BotMemoryMaintenanceFailureCode.DOCUMENT_LONGER_THAN_EVIDENCE.wire,
                batch.failureCode,
            )
            val rollback = batches.lastRollback(batchId)!!
            assertEquals(listOf("agent/one.md"), rollback.conflicts)
            assertEquals(listOf("agent/two.md"), rollback.restored.map { it.path })
            assertEquals("one-later", (memory.read("agent/one.md") as BotMemoryReadResult.Document).version.content)
            assertEquals("two-base", (memory.read("agent/two.md") as BotMemoryReadResult.Document).version.content)
        }
    }

    @Test
    fun tokenBudgetOverageRollsTheBatchBackWithoutModelInvolvement() {
        MemoryHarness().use { harness ->
            seedDocument(harness.store, "agent/note.md", "base", 1)
            val memory = harness.memoryFor("bot-a")
            val batches = BotMemoryMaintenanceBatchStore(
                eventLog = harness.eventLog,
                memory = memory,
                botId = "bot-a",
                now = { 1_760_000_000_000 },
            )
            val batchId = "mm-cccccccccccccccccccccccccccccccc"
            batches.begin(start(batchId))
            assertTrue(memory.write(
                BotMemoryWriteRequest(
                    action = BotMemoryAction.WRITE,
                    path = "agent/note.md",
                    content = "changed",
                    expectedVersion = 1,
                ),
                writeContext(trust = BotMemoryTrust.ASSISTANT, batchId = batchId),
            ).ok)
            val batch = batches.evaluateAndFinish(
                batchId = batchId,
                trigger = BotMemoryMaintenanceTrigger.MANUAL,
                startedAtMs = 1_760_000_000_000,
                maintainerSessionId = maintainerSession,
                turnStatus = "completed",
                checkInput = BotMemoryMaintenanceCheckInput(botId = "bot-a"),
                budget = BotMemoryMaintenanceBudget(10, 20, tokensUsed = 11),
            )
            assertEquals(BotMemoryMaintenanceStatus.ROLLED_BACK, batch.status)
            assertEquals(BotMemoryMaintenanceFailureCode.BUDGET_EXCEEDED.wire, batch.failureCode)
            assertEquals("base", (memory.read("agent/note.md") as BotMemoryReadResult.Document).version.content)
        }
    }

    @Test
    fun triggerAndCandidateSelectionFollowTheFrozenCaps() {
        MemoryHarness().use { harness ->
            for (i in 1..41) {
                harness.append(
                    type = "memory.document_written",
                    eventId = "synthetic-$i",
                    data = JsonObject(
                        mapOf(
                            "path" to JsonString("agent/notes/$i.md"),
                            "scope" to JsonString("agent"),
                            "version" to JsonNumber("1"),
                        ),
                    ),
                )
            }
            val documents = emptyList<BotMemoryDocument>()
            assertEquals(
                BotMemoryMaintenanceTrigger.WRITES,
                BotMemoryMaintenancePlanner.trigger(harness.domain.events(0, 100), documents),
            )
            harness.append(
                type = "memory.review_requested",
                eventId = "review-1",
                data = JsonObject(
                    mapOf(
                        "path" to JsonString("user/profile.md"),
                        "scope" to JsonString("user"),
                        "version" to JsonNumber("1"),
                        "evidence" to JsonArray(emptyList()),
                    ),
                ),
            )
            assertEquals(
                BotMemoryMaintenanceTrigger.CONTRADICTION,
                BotMemoryMaintenancePlanner.trigger(harness.domain.events(0, 100), documents),
            )
            seedDocument(harness.store, "agent/INDEX.md", "x".repeat(1_350), 1)
            val indexDocuments = harness.store.documents()
            assertEquals(
                BotMemoryMaintenanceTrigger.CONTRADICTION,
                BotMemoryMaintenancePlanner.trigger(harness.domain.events(0, 100), indexDocuments),
            )
            val candidates = BotMemoryMaintenancePlanner.candidates(
                harness.domain.events(0, 100), indexDocuments, isMainBot = false,
            )
            assertTrue(candidates.size <= BotMemoryMaintenancePlanner.MAXIMUM_CANDIDATES)
            assertTrue(candidates.any { it.reasons.contains(BotMemoryMaintenanceCandidateReason.INDEX) })
            assertTrue(candidates.none { BotMemoryPath.scopeOf(it.path) == BotMemoryScope.USER })
        }
    }

    private fun start(
        batchId: String,
        trigger: BotMemoryMaintenanceTrigger = BotMemoryMaintenanceTrigger.INDEX,
    ): BotMemoryMaintenanceStart = BotMemoryMaintenanceStart(
        batchId = batchId,
        botId = "bot-a",
        trigger = trigger,
        startedAtMs = 1_760_000_000_000,
        maintainerSessionId = maintainerSession,
        candidates = emptyList(),
        budget = BotMemoryMaintenanceStartBudget(32_000, 96_000),
    )

    private companion object {
        const val maintainerSession = "gb-maintainer-0123456789abcdef0123456789abcdef"
    }
}
