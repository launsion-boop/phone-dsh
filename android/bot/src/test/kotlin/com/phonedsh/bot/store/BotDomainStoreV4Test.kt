// SPDX-License-Identifier: MIT
package com.phonedsh.bot.store

import com.phonedsh.agentcore.JsonObject
import com.phonedsh.agentcore.JsonString
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import java.nio.file.Files
import java.nio.file.Path

/**
 * P25 schema v4: a fresh store creates the event log plus
 * `bot_pending_actions`; a v3 file gains the table without losing rows; a
 * newer file is refused before any write. The DDL is the shared contract in
 * `spec/bot/v1/store.md`; no expected schema text is copied here.
 */
class BotDomainStoreV4Test {
    @Test
    fun freshStoreCreatesPendingActionsAtVersion4() {
        withTempDatabase { path ->
            BotDomainStore(SqliteJdbcDriver(path), clock = { 1_000 }).use { store ->
                assertEquals(BotStoreSchema.CURRENT_VERSION, store.driver.userVersion())
                assertEquals(
                    "one bot_pending_actions table",
                    listOf("bot_pending_actions"),
                    store.driver.query(
                        "SELECT name FROM sqlite_master " +
                            "WHERE type = 'table' AND name = 'bot_pending_actions'",
                    ).map { it.text("name") },
                )
                val columns = store.driver.query("PRAGMA table_info(bot_pending_actions)")
                assertEquals(
                    listOf("bot_id", "nonce", "payload", "created_at_ms", "attempts"),
                    columns.map { it.text("name") },
                )
                assertEquals(
                    listOf("TEXT", "TEXT", "BLOB", "INTEGER", "INTEGER"),
                    columns.map { it.text("type") },
                )
                assertEquals(
                    "every column is NOT NULL",
                    listOf(1L, 1L, 1L, 1L, 1L),
                    columns.map { it.integer("notnull") },
                )
                assertEquals(
                    "only attempts has a default",
                    listOf(null, null, null, null, "1"),
                    columns.map { it.text("dflt_value") },
                )
                assertEquals(
                    "PRIMARY KEY(bot_id, nonce)",
                    listOf(1L, 2L, 0L, 0L, 0L),
                    columns.map { it.integer("pk") },
                )

                val payload = byteArrayOf(1, 2, 3)
                store.driver.execute(
                    "INSERT INTO bot_pending_actions(bot_id, nonce, payload, created_at_ms) " +
                        "VALUES (?, ?, ?, ?)",
                    listOf(
                        SqlValue.Text("main"), SqlValue.Text("nonce-1"),
                        SqlValue.Blob(payload), SqlValue.Integer(1_700_000_000_000),
                    ),
                )
                val stored = store.driver.query(
                    "SELECT payload, created_at_ms, attempts FROM bot_pending_actions " +
                        "WHERE bot_id = 'main' AND nonce = 'nonce-1'",
                ).single()
                assertArrayEquals(payload, stored.blob("payload"))
                assertEquals(1_700_000_000_000L, stored.integer("created_at_ms"))
                assertEquals("attempts defaults to 1", 1L, stored.integer("attempts"))

                try {
                    store.driver.execute(
                        "INSERT INTO bot_pending_actions(bot_id, nonce, payload, created_at_ms) " +
                            "VALUES (?, ?, ?, ?)",
                        listOf(
                            SqlValue.Text("main"), SqlValue.Text("nonce-1"),
                            SqlValue.Blob(byteArrayOf(9)), SqlValue.Integer(1_700_000_000_001),
                        ),
                    )
                    fail("the (bot_id, nonce) primary key must reject a duplicate")
                } catch (expected: Exception) {
                    assertTrue(
                        "duplicate rejection should be a constraint failure: ${expected.message}",
                        expected.message.orEmpty().contains("UNIQUE", ignoreCase = true) ||
                            expected.message.orEmpty().contains("constraint", ignoreCase = true),
                    )
                }
            }

            // Reopening a v4 store is a no-op: same version, same rows.
            BotDomainStore(SqliteJdbcDriver(path), clock = { 1_000 }).use { reopened ->
                assertEquals(4, reopened.driver.userVersion())
                assertEquals(
                    1L,
                    reopened.driver.query(
                        "SELECT COUNT(*) AS n FROM bot_pending_actions",
                    ).single().integer("n"),
                )
            }
        }
    }

    @Test
    fun v3UserVersionWithoutTablesSelfHealsAtVersion4() {
        // The pre-v4 open re-ran the idempotent v3 DDL for `user_version=3`.
        // Keep that self-heal: a fixture/rollback file may carry the version
        // without the tables, and it must still open at v4.
        withTempDatabase { path ->
            SqliteJdbcDriver(path).use { driver ->
                assertEquals(
                    "the fixture must start without schema objects",
                    0,
                    driver.query("SELECT name FROM sqlite_master WHERE type = 'table'").size,
                )
                driver.setUserVersion(3)
            }

            BotDomainStore(SqliteJdbcDriver(path), clock = { 1_000 }).use { store ->
                assertEquals(4, store.driver.userVersion())
                val objects = store.driver.query(
                    "SELECT type, name FROM sqlite_master WHERE name NOT LIKE 'sqlite_autoindex_%'",
                )
                assertEquals(
                    "the full v3 table set plus the v4 table",
                    setOf(
                        "bot_event_headers", "bot_event_payloads", "bot_effects",
                        "bot_effect_inbox", "bot_user_action_nonces", "bot_pending_actions",
                    ),
                    objects.filter { it.text("type") == "table" }.map { it.text("name") }.toSet(),
                )
                assertEquals(
                    setOf(
                        "bot_event_headers_reject_update", "bot_event_headers_reject_delete",
                        "bot_event_payloads_erase_only", "bot_event_payloads_reject_delete",
                    ),
                    objects.filter { it.text("type") == "trigger" }.map { it.text("name") }.toSet(),
                )
                assertEquals(
                    "the bot_events compatibility view",
                    setOf("bot_events"),
                    objects.filter { it.text("type") == "view" }.map { it.text("name") }.toSet(),
                )
                assertEquals(
                    setOf("bot_effects_lease_candidates", "bot_effect_inbox_lookup"),
                    objects.filter { it.text("type") == "index" }.map { it.text("name") }.toSet(),
                )
                assertEquals(1L, store.append(durableEvent("healed")))
                assertEquals("healed", store.event("healed")?.eventId)
            }
        }
    }

    @Test
    fun v3FixtureGainsPendingActionsAndKeepsEventsAndNonces() {
        withTempDatabase { path ->
            val event = durableEvent("v3-event")
            val data = BotEventCodec.encodeData(event.data)
            SqliteJdbcDriver(path).use { driver ->
                for (statement in BotStoreSchema.V3_STATEMENTS) driver.execute(statement)
                insertV3Event(driver, event, sequence = 1, data = data)
                driver.execute(
                    "INSERT INTO bot_user_action_nonces(bot_id, nonce, event_id, created_commit_seq) " +
                        "VALUES (?, ?, ?, ?)",
                    listOf(
                        SqlValue.Text("main"), SqlValue.Text("nonce-v3"),
                        SqlValue.Text("v3-event"), SqlValue.Integer(1),
                    ),
                )
                driver.setUserVersion(3)
                assertTrue(
                    "the v3 fixture must not already contain the v4 table",
                    driver.query(
                        "SELECT name FROM sqlite_master " +
                            "WHERE type = 'table' AND name = 'bot_pending_actions'",
                    ).isEmpty(),
                )
            }

            BotDomainStore(SqliteJdbcDriver(path), clock = { 1_000 }).use { store ->
                assertEquals(4, store.driver.userVersion())
                assertEquals(1L, store.headCommitSeq())
                assertEquals("v3-event", store.event("v3-event")?.eventId)
                assertEquals("v3-event", store.eventID("main", "nonce-v3"))
                assertArrayEquals(
                    data,
                    store.driver.query(
                        "SELECT payload FROM bot_event_payloads WHERE commit_seq = 1",
                    ).single().blob("payload"),
                )
                assertEquals(
                    1,
                    store.driver.query(
                        "SELECT name FROM sqlite_master " +
                            "WHERE type = 'table' AND name = 'bot_pending_actions'",
                    ).size,
                )
            }

            // A second open must not lose rows or churn the schema.
            BotDomainStore(SqliteJdbcDriver(path), clock = { 1_000 }).use { reopened ->
                assertEquals(4, reopened.driver.userVersion())
                assertEquals(1L, reopened.headCommitSeq())
                assertEquals(
                    1,
                    reopened.driver.query(
                        "SELECT name FROM sqlite_master WHERE name = 'bot_pending_actions'",
                    ).size,
                )
            }
        }
    }

    @Test
    fun v2FixtureMigratesThroughV3ToVersion4() {
        withTempDatabase { path ->
            val event = durableEvent("legacy-v2").withCommitSeq(1)
            SqliteJdbcDriver(path).use { driver ->
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
                driver.execute(
                    "INSERT INTO bot_events(commit_seq, event_id, event_type, payload) VALUES (?, ?, ?, ?)",
                    listOf(
                        SqlValue.Integer(1), SqlValue.Text(event.eventId),
                        SqlValue.Text(event.type),
                        SqlValue.Blob(BotEventCodec.encodeCanonical(event.toJson())),
                    ),
                )
                driver.setUserVersion(2)
            }

            BotDomainStore(SqliteJdbcDriver(path), clock = { 1_000 }).use { store ->
                assertEquals("v1/v2 migrations finish at v4", 4, store.driver.userVersion())
                assertEquals(1L, store.headCommitSeq())
                assertEquals("legacy-v2", store.event("legacy-v2")?.eventId)
                assertEquals(
                    1,
                    store.driver.query(
                        "SELECT name FROM sqlite_master WHERE name = 'bot_pending_actions'",
                    ).size,
                )
            }
        }
    }

    @Test
    fun newerUserVersionIsRejectedAndLeavesTheFileUntouched() {
        withTempDatabase { path ->
            BotDomainStore(SqliteJdbcDriver(path), clock = { 1_000 }).use { store ->
                store.append(durableEvent("future-version"))
                store.driver.execute(
                    "INSERT INTO bot_pending_actions(bot_id, nonce, payload, created_at_ms, attempts) " +
                        "VALUES ('main', 'pending-future', X'0102', 1000, 3)",
                )
            }
            val schemaBefore: List<String> = SqliteJdbcDriver(path).use { driver ->
                driver.execute("PRAGMA user_version=5")
                schemaNames(driver)
            }

            try {
                BotDomainStore(SqliteJdbcDriver(path), clock = { 1_000 })
                fail("user_version=5 must be refused")
            } catch (error: BotStoreException) {
                assertEquals("schemaTooNew:5", error.code)
                assertTrue(
                    "detail must name the supported version: ${error.message}",
                    error.message.orEmpty().contains("newer than 4"),
                )
            }

            SqliteJdbcDriver(path).use { driver ->
                assertEquals("the refused open must not change user_version", 5, driver.userVersion())
                assertEquals(
                    "the refused open must not change rows",
                    1L,
                    driver.query("SELECT COUNT(*) AS n FROM bot_event_headers").single().integer("n"),
                )
                assertEquals(
                    1L,
                    driver.query("SELECT COUNT(*) AS n FROM bot_event_payloads").single().integer("n"),
                )
                assertEquals(
                    1L,
                    driver.query("SELECT COUNT(*) AS n FROM bot_pending_actions").single().integer("n"),
                )
                assertEquals(
                    "the refused open must not change the pending-action row",
                    "pending-future",
                    driver.query("SELECT nonce FROM bot_pending_actions").single().text("nonce"),
                )
                assertEquals(
                    "the refused open must not change the schema",
                    schemaBefore,
                    schemaNames(driver),
                )
            }
        }
    }

    private fun schemaNames(driver: BotSqlDriver): List<String> =
        driver.query("SELECT type, name FROM sqlite_master ORDER BY type, name").map {
            "${it.text("type")}:${it.text("name")}"
        }

    private fun insertV3Event(driver: BotSqlDriver, event: BotEvent, sequence: Long, data: ByteArray) {
        driver.execute(
            "INSERT INTO bot_event_headers(commit_seq, event_id, event_type, payload_digest, " +
                "payload_size, header_meta) VALUES (?, ?, ?, ?, ?, ?)",
            listOf(
                SqlValue.Integer(sequence), SqlValue.Text(event.eventId),
                SqlValue.Text(event.type), SqlValue.Text(sha256(data)),
                SqlValue.Integer(data.size.toLong()),
                SqlValue.Blob(BotEventCodec.encodeHeaderMeta(event.withCommitSeq(sequence))),
            ),
        )
        driver.execute(
            "INSERT INTO bot_event_payloads(commit_seq, payload) VALUES (?, ?)",
            listOf(SqlValue.Integer(sequence), SqlValue.Blob(data)),
        )
    }

    private fun durableEvent(id: String): BotEvent = BotEvent(
        schemaVersion = 1,
        type = "ui.notice",
        eventId = id,
        commitSeq = null,
        time = 1_000,
        origin = BotEventOrigin.Local("user"),
        traceId = "trace-$id",
        principal = BotPrincipal("main", null, "ipc", emptyList()),
        causationId = null,
        correlationId = null,
        data = JsonObject(mapOf("text" to JsonString(id))),
    )

    private fun withTempDatabase(block: (String) -> Unit) {
        val file = Files.createTempFile("bot-store-v4", ".sqlite")
        Files.deleteIfExists(file)
        try {
            block(file.toString())
        } finally {
            Files.deleteIfExists(file)
            Files.deleteIfExists(Path.of("${file}-wal"))
            Files.deleteIfExists(Path.of("${file}-shm"))
        }
    }
}
