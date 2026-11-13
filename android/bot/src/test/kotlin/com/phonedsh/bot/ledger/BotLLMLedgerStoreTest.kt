// SPDX-License-Identifier: MIT
package com.phonedsh.bot.ledger

import com.phonedsh.agentcore.JsonNull
import com.phonedsh.agentcore.JsonObject
import com.phonedsh.agentcore.JsonString
import com.phonedsh.bot.BotJson
import com.phonedsh.bot.GoldenFixture
import com.phonedsh.bot.store.BotDomainStore
import com.phonedsh.bot.store.BotEvent
import com.phonedsh.bot.store.BotEventCodec
import com.phonedsh.bot.store.BotEventOrigin
import com.phonedsh.bot.store.BotPrincipal
import com.phonedsh.bot.store.BotStoreException
import com.phonedsh.bot.store.SqliteJdbcDriver
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import java.io.File
import java.nio.file.Files

/** Real `BotDomainStore` + sqlite-jdbc: append, reopen, replay, idempotency. */
class BotLLMLedgerStoreTest {
    @Test
    fun appendWritesOneDurableEventAndSurvivesReopen() {
        withStore { file, store ->
            val record = goldenRecord("llm-ledger")
            val ledger = BotLLMLedger(store) { "ledger.usage_recorded:test-step-1" }

            assertEquals(1L, ledger.append(record))
            assertEquals("same event id is an idempotent no-op", 1L, ledger.append(record))
            assertEquals(1L, store.headCommitSeq())

            val events = store.events(0, 10)
            assertEquals(1, events.size)
            val event = events.single()
            assertEquals(BotLLMLedger.EVENT_TYPE, event.type)
            assertEquals("ledger.usage_recorded:test-step-1", event.eventId)
            assertEquals(1_760_000_000_000L, event.time)
            assertEquals(BotEventOrigin.Local("runtime"), event.origin)
            assertEquals("trace:ledger.usage_recorded:test-step-1", event.traceId)
            assertEquals(
                BotPrincipal(
                    botId = "main",
                    sessionId = "gb-main",
                    kind = "chat",
                    capabilities = emptyList(),
                ),
                event.principal,
            )
            assertNull(event.causationId)
            assertEquals("gb-main", event.correlationId)
            assertEquals(
                BotJson.canonical(record.toJson()),
                BotJson.canonical(event.data),
            )
            assertTrue(BotEventCodec.isDurable(BotLLMLedger.EVENT_TYPE))
            assertFalse(BotEventCodec.isEphemeral(BotLLMLedger.EVENT_TYPE))

            val reopened = BotDomainStore(
                SqliteJdbcDriver(file.absolutePath),
                clock = { 2_000 },
            )
            try {
                val reopenedLedger = BotLLMLedger(reopened) {
                    "ledger.usage_recorded:test-step-1"
                }
                assertEquals("reopen keeps the idempotency key", 1L, reopenedLedger.append(record))
                val second = BotLLMLedgerRecord(
                    ts = record.ts,
                    botId = record.botId,
                    sessionId = record.sessionId,
                    purpose = BotModelPurpose.WORKER_TURN,
                    model = record.model,
                    provider = record.provider,
                    inputTokens = 1,
                    outputTokens = 2,
                    cacheReadTokens = 3,
                    cacheWriteTokens = 4,
                    ttftMs = null,
                    durationMs = null,
                    status = "error",
                    errorKind = "timeout",
                )
                val secondLedger = BotLLMLedger(reopened) {
                    "ledger.usage_recorded:test-step-2"
                }
                assertEquals(2L, secondLedger.append(second))
                assertEquals(listOf(record, second), reopenedLedger.records())
                assertEquals(listOf(record), reopenedLedger.records(limit = 1))
                assertEquals(listOf(second), reopenedLedger.records(after = 1))
                assertEquals(listOf(second), reopenedLedger.records(after = 1, limit = 1))
                assertEquals(2L, reopened.headCommitSeq())
                reopened.verifyIntegrity()
            } finally {
                reopened.close()
            }
        }
    }

    @Test
    fun everyPurposeUsesItsFrozenPrincipalKind() {
        withStore { _, store ->
            var counter = 0
            val ledger = BotLLMLedger(store) { "ledger.usage_recorded:test-${counter++}" }
            val base = goldenRecord("llm-ledger")
            val purposes = BotModelPurpose.entries
            for (purpose in purposes) {
                ledger.append(base.copy(purpose = purpose))
            }

            val events = store.events(0, 20)
            assertEquals(purposes.size, events.size)
            for ((index, purpose) in purposes.withIndex()) {
                assertEquals(BotLLMLedger.EVENT_TYPE, events[index].type)
                assertEquals(
                    "principal kind for ${purpose.wire}",
                    purpose.principalKind,
                    events[index].principal.kind,
                )
                assertEquals("main", events[index].principal.botId)
                assertEquals("gb-main", events[index].principal.sessionId)

                val data = events[index].data as JsonObject
                assertEquals(purpose.wire, (data.members["purpose"] as JsonString).value)
            }
            assertEquals(purposes, ledger.records().map { it.purpose })
            store.verifyIntegrity()
        }
    }

    @Test
    fun requiredNullMembersStayExplicitAndInvalidAppendsWriteNothing() {
        withStore { _, store ->
            val ledger = BotLLMLedger(store) { "ledger.usage_recorded:test-nulls" }
            val minimal = BotLLMLedgerRecord(
                ts = "2025-10-09T08:53:20.000Z",
                botId = null,
                sessionId = null,
                purpose = BotModelPurpose.TRIAGE,
                model = null,
                provider = null,
                inputTokens = 0,
                outputTokens = 0,
                cacheReadTokens = 0,
                cacheWriteTokens = 0,
                ttftMs = null,
                durationMs = null,
                status = "ok",
                errorKind = null,
            )
            assertEquals(0.0, minimal.cacheHitRatio, 0.0)
            assertEquals(1L, ledger.append(minimal))
            val data = store.events(0, 1).single().data as JsonObject
            assertEquals(14, data.members.size)
            for (key in listOf("botId", "sessionId", "model", "provider", "durationMs", "errorKind")) {
                assertEquals("$key must be explicit null", JsonNull, data.members[key])
            }
            assertFalse(data.members.containsKey("ttftMs"))

            val badRatio = minimal.copy(cacheHitRatio = 0.5)
            assertEquals("cacheHitRatio", assertLedgerField { ledger.append(badRatio) })
            assertEquals("ts", assertLedgerField { ledger.append(minimal.copy(ts = "short")) })
            assertEquals(
                "ts",
                assertLedgerField {
                    ledger.append(minimal.copy(ts = "2025-10-09T08:53:20.000"))
                },
            )
            assertEquals(1L, store.headCommitSeq())

            val error = try {
                ledger.records(limit = 0)
                null
            } catch (failure: BotStoreException) {
                failure
            }
            assertEquals("invalidCursor", error?.code)
        }
    }

    @Test
    fun phoneMaintenanceRecordIsDurableUnderTheMaintainerPrincipal() {
        withStore { _, store ->
            val record = goldenRecord("llm-ledger.phone")
            val ledger = BotLLMLedger(store) { "ledger.usage_recorded:maintenance" }

            assertEquals(1L, ledger.append(record))
            val event = store.events(0, 1).single()
            assertEquals("maintainer", event.principal.kind)
            assertEquals("bot-a", event.principal.botId)
            assertEquals(
                "gb-maintainer-0123456789abcdef0123456789abcdef",
                event.principal.sessionId,
            )
            assertEquals(
                "memory-maintenance",
                ((event.data as JsonObject).members["purpose"] as JsonString).value,
            )
            assertEquals(listOf(record), ledger.records())
        }
    }

    @Test
    fun replaySkipsOtherDurableEventsAndPaginates() {
        withStore { _, store ->
            val base = goldenRecord("llm-ledger")
            val first = BotLLMLedger(store) { "ledger.usage_recorded:first" }
            val second = BotLLMLedger(store) { "ledger.usage_recorded:second" }

            assertEquals(1L, store.append(nonLedgerEvent("runtime:1")))
            assertEquals(2L, first.append(base))
            assertEquals(3L, store.append(nonLedgerEvent("runtime:2")))
            val secondRecord = base.copy(purpose = BotModelPurpose.WORKER_TURN)
            assertEquals(4L, second.append(secondRecord))

            assertEquals(listOf(base, secondRecord), first.records())
            assertEquals(listOf(secondRecord), first.records(after = 2))
            assertEquals(listOf(base), first.records(limit = 1))
            assertEquals(4L, store.headCommitSeq())
            store.verifyIntegrity()
        }
    }

    private fun nonLedgerEvent(eventId: String): BotEvent = BotEvent(
        schemaVersion = BotEventCodec.CURRENT_SCHEMA_VERSION,
        type = "runtime.started",
        eventId = eventId,
        commitSeq = null,
        time = 1_000,
        origin = BotEventOrigin.Local("runtime"),
        traceId = "trace:$eventId",
        principal = BotPrincipal(
            botId = null,
            sessionId = null,
            kind = "chat",
            capabilities = emptyList(),
        ),
        causationId = null,
        correlationId = null,
        data = JsonObject(emptyMap()),
    )

    private fun goldenRecord(name: String): BotLLMLedgerRecord =
        BotLLMLedgerRecord.fromJson(
            GoldenFixture.objectValue(GoldenFixture.rawObject(name), "valid"),
        )

    private fun assertLedgerField(block: () -> Unit): String {
        val error = try {
            block()
            null
        } catch (failure: BotLLMLedgerException) {
            failure
        }
        if (error == null) fail("expected BotLLMLedgerException")
        return error!!.field
    }

    private fun withStore(block: (File, BotDomainStore) -> Unit) {
        val directory = Files.createTempDirectory("bot-ledger").toFile()
        val file = File(directory, "domain.sqlite")
        try {
            val store = BotDomainStore(SqliteJdbcDriver(file.absolutePath), clock = { 1_000 })
            try {
                block(file, store)
            } finally {
                store.close()
            }
        } finally {
            directory.deleteRecursively()
        }
    }
}
