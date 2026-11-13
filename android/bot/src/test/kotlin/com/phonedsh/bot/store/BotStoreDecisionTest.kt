// SPDX-License-Identifier: MIT
package com.phonedsh.bot.store

import com.phonedsh.agentcore.JsonObject
import com.phonedsh.agentcore.JsonString
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import java.nio.file.Files

/** Direct tests for the W4-C2-1/2 decisions and the §5.4 erasure path. */
class BotStoreDecisionTest {
    @Test
    fun knownKindWithoutExecutorReleasesToPendingWithoutAnEvent() {
        withStore { store, outbox, _ ->
            val effect = BotEffect(
                effectKey = "fx-known", kind = "routine-delivery", operation = "routine.deliver",
                target = "delivery-1", canonicalResource = "delivery-1", argsDigest = "args",
                payloadDigest = "payload", logicalKey = "delivery-1", idempotent = true,
                retryPolicy = "network-idempotent", maxAttempts = 5, generation = 1,
                notBefore = 1_000,
            )
            outbox.enqueue(effect)
            val lease = outbox.lease("owner", 1_000)!!
            assertEquals(2L, store.headCommitSeq())
            val released = outbox.releaseWithoutExecutor(lease, 1_000)
            assertEquals(BotEffectState.PENDING, released.state)
            assertEquals(2L, store.headCommitSeq())
            assertEquals(1, released.attempt)
            assertEquals(1, released.attempts)
            assertEquals(1, released.generation)
            assertEquals(2_000L, released.effect.notBefore)
            assertEquals("no registered executor", released.lastError)
            assertEquals(null, released.leaseOwner)
            assertEquals(null, outbox.lease("owner", 1_999))
            val next = outbox.lease("owner", 2_000)!!
            assertEquals(2, next.attempt)
            assertEquals(1, next.generation)
        }
    }

    @Test
    fun kindOutsideTheCatalogueFailsPermanently() {
        withStore { _, outbox, _ ->
            outbox.enqueue(
                BotEffect(
                    effectKey = "fx-unknown", kind = "not-in-catalogue", operation = "notify",
                    target = "row-1", canonicalResource = "row-1", argsDigest = "args",
                    payloadDigest = "payload", logicalKey = "request-1", idempotent = false,
                    retryPolicy = "local-nonidempotent", maxAttempts = 1, generation = 1,
                    notBefore = 1_000,
                ),
            )
            val lease = outbox.lease("owner", 1_000)!!
            outbox.fail(lease, "permanent", "unknown_effect_kind")
            val record = outbox.effect("fx-unknown")!!
            assertEquals(BotEffectState.DEAD_LETTER, record.state)
            assertEquals("permanent", record.errorClass)
            assertTrue(record.lastError.orEmpty().contains("unknown_effect_kind"))
            assertEquals(null, outbox.lease("owner", 2_000))
        }
    }

    @Test
    fun migrationGapRollsBackAndLeavesTheOldDatabase() {
        val file = Files.createTempFile("bot-store-gap", ".sqlite")
        Files.deleteIfExists(file)
        val eventOne = event("gap-1", 1)
        val eventThree = event("gap-3", 3)
        SqliteJdbcDriver(file.toString()).use { driver ->
            driver.execute(
                "CREATE TABLE bot_events (commit_seq INTEGER PRIMARY KEY CHECK (commit_seq > 0), " +
                    "event_id TEXT NOT NULL UNIQUE, event_type TEXT NOT NULL, payload BLOB NOT NULL)",
            )
            driver.execute(
                "CREATE TABLE bot_user_action_nonces (bot_id TEXT NOT NULL, nonce TEXT NOT NULL, " +
                    "event_id TEXT NOT NULL UNIQUE REFERENCES bot_events(event_id), " +
                    "created_commit_seq INTEGER NOT NULL CHECK (created_commit_seq > 0), " +
                    "PRIMARY KEY(bot_id, nonce))",
            )
            for (event in listOf(eventOne, eventThree)) {
                driver.execute(
                    "INSERT INTO bot_events(commit_seq, event_id, event_type, payload) VALUES (?, ?, ?, ?)",
                    listOf(
                        SqlValue.Integer(event.commitSeq!!), SqlValue.Text(event.eventId),
                        SqlValue.Text(event.type),
                        SqlValue.Blob(BotEventCodec.encodeCanonical(event.toJson())),
                    ),
                )
            }
            driver.setUserVersion(2)
        }
        try {
            BotDomainStore(SqliteJdbcDriver(file.toString()), clock = { 1_000 })
            fail("gapped v2 database must not open")
        } catch (error: BotStoreException) {
            assertEquals("corrupted", error.code)
            assertEquals("commit_seq gap: expected 2, found 3", error.message)
        }
        SqliteJdbcDriver(file.toString()).use { driver ->
            assertEquals(2, driver.userVersion())
            assertEquals(
                "table",
                driver.query("SELECT type FROM sqlite_master WHERE name = 'bot_events'")
                    .first().text("type"),
            )
            assertEquals(2L, driver.query("SELECT COUNT(*) AS n FROM bot_events").first().integer("n"))
        }
        Files.deleteIfExists(file)
    }

    @Test
    fun erasureClearsThePayloadButKeepsTheHeaderAndSentinel() {
        withStore { store, _, _ ->
            val original = event("erase-me", null)
            store.append(original)
            val erasure = BotEvent(
                schemaVersion = 1,
                type = "erasure",
                eventId = "erasure-1",
                commitSeq = null,
                time = 1_000,
                origin = BotEventOrigin.Local("user"),
                traceId = "trace-erasure-1",
                principal = BotPrincipal("main", null, "ipc", emptyList()),
                causationId = null,
                correlationId = null,
                data = JsonObject(mapOf("erasureId" to JsonString("erasure-1"))),
            )
            val targets = store.erasureTargets(listOf(1))
            assertEquals(1, targets.size)
            assertTrue(targets.single().payloadBytes > 0)
            val commit = store.erasePayloads(listOf(1), erasure, 1_500)
            assertEquals(2L, commit.erasureCommitSeq)
            assertEquals(0L, store.erasureTargets(listOf(1)).single().payloadBytes)
            val read = store.event("erase-me")!!
            val data = read.data as JsonObject
            assertEquals(true, (data.members["\$erased"] as? com.phonedsh.agentcore.JsonBool)?.value)
            assertNotNull(data.members["\$erasureCommitSeq"])
            val header = store.driver.query(
                "SELECT payload_digest, payload_size FROM bot_event_headers WHERE commit_seq = 1",
            ).first()
            assertNotNull(header.text("payload_digest"))
            assertNotNull(header.integer("payload_size"))
        }
    }

    private fun event(id: String, sequence: Long?): BotEvent = BotEvent(
        schemaVersion = 1,
        type = "ui.notice",
        eventId = id,
        commitSeq = sequence,
        time = 1_000,
        origin = BotEventOrigin.Local("user"),
        traceId = "trace-$id",
        principal = BotPrincipal("main", null, "ipc", emptyList()),
        causationId = null,
        correlationId = null,
        data = JsonObject(mapOf("text" to JsonString(id))),
    )

    private fun withStore(block: (BotDomainStore, BotEffectOutbox, SqliteJdbcDriver) -> Unit) {
        val file = Files.createTempFile("bot-store-decision", ".sqlite")
        Files.deleteIfExists(file)
        val driver = SqliteJdbcDriver(file.toString())
        val store = BotDomainStore(driver, clock = { 1_000 })
        val outbox = BotEffectOutbox(store)
        try {
            block(store, outbox, driver)
        } finally {
            store.close()
            Files.deleteIfExists(file)
        }
    }
}
