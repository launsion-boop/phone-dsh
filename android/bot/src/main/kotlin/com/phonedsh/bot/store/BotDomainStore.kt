// SPDX-License-Identifier: MIT
package com.phonedsh.bot.store

import com.phonedsh.agentcore.JsonNumber
import com.phonedsh.agentcore.JsonObject
import com.phonedsh.agentcore.JsonValue
import java.security.MessageDigest
import java.util.UUID

/**
 * The P25 durable store: event log, schema v3, canonical bytes, migration and
 * integrity scanning (`spec/bot/v1/store.md` §1–§8). All SQL lives here; the
 * constructor takes a [BotSqlDriver] so the host JVM and Android can share the
 * exact statements.
 */
public class BotDomainStore(
    internal val driver: BotSqlDriver,
    internal val clock: () -> Long = { System.currentTimeMillis() },
    public val defaultLeaseTtlMs: Long = 30_000,
    private val ephemeralCapacity: Int = 256,
) : AutoCloseable {
    private var closed: Boolean = false
    private var crashPoint: String? = null
    private val ephemeralBuffer: MutableList<BotEvent> = ArrayList()
    private var droppedEphemeral: Int = 0

    init {
        if (ephemeralCapacity <= 0) throw invalidConfiguration("ephemeralCapacity must be positive")
        if (defaultLeaseTtlMs <= 0) throw invalidConfiguration("leaseTtlMs must be positive")
        try {
            open()
        } catch (error: Throwable) {
            runCatching { driver.close() }
            throw error
        }
    }

    // ---------------------------------------------------------------------
    // open, pragmas and migration (§2, §7)
    // ---------------------------------------------------------------------

    private fun open() {
        val version = driver.userVersion()
        if (version > 3) {
            throw BotStoreException("schemaTooNew:$version", "schema version $version is newer than 3")
        }
        applyPragmas()
        when (version) {
            0 -> {
                driver.beginImmediate()
                try {
                    BotStoreSchema.create(driver)
                    driver.setUserVersion(3)
                    driver.commit()
                } catch (error: Throwable) {
                    runCatching { driver.rollback() }
                    throw error
                }
            }
            1, 2 -> migrateToV3(version)
            3 -> inTransaction { BotStoreSchema.create(driver) }
        }
        driver.execute("PRAGMA foreign_keys=ON")
        scanIntegrity()
        closed = false
    }

    private fun applyPragmas() {
        val mode = driver.query("PRAGMA journal_mode=WAL").firstOrNull()?.valuesAsText()?.firstOrNull()
        if (!mode.equals("wal", ignoreCase = true)) {
            throw BotStoreException("sqlite", "journal_mode=WAL was not accepted: $mode")
        }
        driver.execute("PRAGMA synchronous=FULL")
        driver.execute("PRAGMA foreign_keys=ON")
        driver.execute("PRAGMA secure_delete=ON")
        driver.execute("PRAGMA busy_timeout=5000")
    }

    private fun migrateToV3(version: Int) {
        val objectType = driver.query(
            "SELECT type FROM sqlite_master WHERE name = 'bot_events'",
        ).firstOrNull()?.text("type")
        val hasHeaders = driver.query(
            "SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'bot_event_headers'",
        ).isNotEmpty()
        if (objectType == "view" && hasHeaders) {
            // A test/rollback fixture may only lower user_version on an
            // already-split database. The bytes are already in v3 tables.
            inTransaction {
                BotStoreSchema.create(driver)
                validateHeaderContiguity()
                driver.setUserVersion(3)
            }
            return
        }
        if (objectType != "table") {
            throw corrupted("v$version database has no bot_events table to migrate")
        }

        val oldEvents = driver.query(
            "SELECT commit_seq, event_id, event_type, payload FROM bot_events ORDER BY commit_seq ASC",
        )
        val oldNonces = if (version >= 2) {
            driver.query("SELECT bot_id, nonce, event_id, created_commit_seq FROM bot_user_action_nonces")
        } else {
            emptyList()
        }

        driver.execute("PRAGMA foreign_keys=OFF")
        try {
            driver.beginImmediate()
            try {
                // W4-C2-2: validate contiguity inside the migration transaction,
                // before any DROP; a gap rolls back and leaves user_version at
                // its old value.
                var expected = 1L
                for (row in oldEvents) {
                    val sequence = row.integer("commit_seq")
                        ?: throw corrupted("v$version event row has no commit_seq")
                    if (sequence != expected) {
                        throw corrupted("commit_seq gap: expected $expected, found $sequence")
                    }
                    expected += 1
                }
                driver.execute("DROP TRIGGER IF EXISTS bot_events_reject_update")
                driver.execute("DROP TRIGGER IF EXISTS bot_events_reject_delete")
                driver.execute("DROP TABLE IF EXISTS bot_user_action_nonces")
                driver.execute("DROP TABLE IF EXISTS bot_events")
                BotStoreSchema.create(driver)

                for (row in oldEvents) {
                    val sequence = row.integer("commit_seq")
                        ?: throw corrupted("v$version event row has no commit_seq")
                    val eventId = row.text("event_id")
                        ?: throw corrupted("v$version event row has no event_id")
                    val eventType = row.text("event_type")
                        ?: throw corrupted("v$version event row has no event_type")
                    val payload = row.blob("payload")
                        ?: throw corrupted("v$version event row has no payload")
                    val event = try {
                        BotEventCodec.decode(payload, BotEventCodec.Mode.STORED)
                    } catch (error: Exception) {
                        throw corrupted("v$version event payload does not decode at commitSeq $sequence")
                    }
                    if (event.commitSeq != sequence || event.eventId != eventId || event.type != eventType) {
                        throw corrupted("v$version event payload mismatch at commitSeq $sequence")
                    }
                    val data = BotEventCodec.encodeData(event.data)
                    val header = BotEventCodec.encodeHeaderMeta(event)
                    insertHeaderRow(sequence, eventId, eventType, data, header)
                    driver.execute(
                        "INSERT INTO bot_event_payloads(commit_seq, payload) VALUES (?, ?)",
                        listOf(SqlValue.Integer(sequence), SqlValue.Blob(data)),
                    )
                }
                for (nonce in oldNonces) {
                    val botId = nonce.text("bot_id")
                        ?: throw corrupted("v$version nonce row has no bot_id")
                    val nonceValue = nonce.text("nonce")
                        ?: throw corrupted("v$version nonce row has no nonce")
                    val eventId = nonce.text("event_id")
                        ?: throw corrupted("v$version nonce row has no event_id")
                    val created = nonce.integer("created_commit_seq")
                        ?: throw corrupted("v$version nonce row has no created_commit_seq")
                    driver.execute(
                        "INSERT INTO bot_user_action_nonces(bot_id, nonce, event_id, created_commit_seq) " +
                            "VALUES (?, ?, ?, ?)",
                        listOf(
                            SqlValue.Text(botId), SqlValue.Text(nonceValue),
                            SqlValue.Text(eventId), SqlValue.Integer(created),
                        ),
                    )
                }
                driver.setUserVersion(3)
                driver.commit()
            } catch (error: Throwable) {
                runCatching { driver.rollback() }
                throw error
            }
        } finally {
            runCatching { driver.execute("PRAGMA foreign_keys=ON") }
        }
        val foreignKeyErrors = driver.query("PRAGMA foreign_key_check")
        if (foreignKeyErrors.isNotEmpty()) {
            throw corrupted("v3 migration left a foreign key violation")
        }
    }

    private fun validateHeaderContiguity() {
        val rows = driver.query("SELECT commit_seq FROM bot_event_headers ORDER BY commit_seq ASC")
        var expected = 1L
        for (row in rows) {
            val actual = row.integer("commit_seq")
                ?: throw corrupted("bot_event_headers row has no commit_seq")
            if (actual != expected) throw corrupted("commit_seq gap: expected $expected, found $actual")
            expected += 1
        }
    }

    // ---------------------------------------------------------------------
    // events (§4)
    // ---------------------------------------------------------------------

    public fun append(event: BotEvent): Long {
        ensureOpen()
        if (BotEventCodec.isEphemeral(event.type)) {
            BotEventCodec.validate(event, BotEventCodec.Mode.APPEND)
            ephemeralBuffer += event
            if (ephemeralBuffer.size > ephemeralCapacity) {
                ephemeralBuffer.removeAt(0)
                droppedEphemeral += 1
            }
            return 0
        }
        BotEventCodec.validate(event, BotEventCodec.Mode.APPEND)
        return inTransaction {
            existingSequence(event.eventId) ?: run {
                val sequence = headCommitSeqInternal() + 1
                insertEvent(event, sequence)
                sequence
            }
        }
    }

    public fun appendBatch(events: List<BotEvent>): List<Long> {
        ensureOpen()
        if (events.isEmpty()) throw invalidTransition("appendBatch requires at least one event")
        for (event in events) BotEventCodec.validate(event, BotEventCodec.Mode.APPEND)
        if (events.any { BotEventCodec.isEphemeral(it.type) }) {
            throw invalidTransition("a durable batch must not contain an ephemeral event")
        }
        return inTransaction {
            val seen = HashSet<String>()
            for (event in events) {
                if (!seen.add(event.eventId)) {
                    throw invalidTransition("batch repeats eventId ${event.eventId}")
                }
                if (existingSequence(event.eventId) != null) {
                    throw invalidTransition("batch contains committed eventId ${event.eventId}")
                }
            }
            val batched = events.count { it.batch != null }
            if (batched != 0 && batched != events.size) {
                throw invalidTransition("a batch must not mix batched and unbatched events")
            }
            val prepared = when {
                batched == 0 && events.size > 1 -> {
                    val batchId = "batch:${UUID.randomUUID().toString().lowercase()}"
                    events.mapIndexed { index, event ->
                        event.withBatch(BotEventBatch(batchId, index, events.size))
                    }
                }
                batched == events.size && events.isNotEmpty() -> {
                    val first = events.first().batch!!
                    events.forEachIndexed { index, event ->
                        val batch = event.batch!!
                        if (batch.id != first.id || batch.index != index || batch.total != events.size) {
                            throw invalidTransition("invalid batch reference at index $index")
                        }
                    }
                    events
                }
                else -> events
            }
            val start = headCommitSeqInternal()
            val sequences = ArrayList<Long>(prepared.size)
            prepared.forEachIndexed { index, event ->
                val sequence = start + 1 + index
                insertEvent(event, sequence)
                sequences += sequence
            }
            sequences
        }
    }

    public fun headCommitSeq(): Long {
        ensureOpen()
        return headCommitSeqInternal()
    }

    internal fun headCommitSeqInternal(): Long =
        driver.query("SELECT COALESCE(MAX(commit_seq), 0) AS head FROM bot_event_headers")
            .firstOrNull()?.integer("head") ?: 0

    public fun events(after: Int, limit: Int): List<BotEvent> {
        ensureOpen()
        if (after < 0) throw invalidCursor("after must not be negative")
        if (limit <= 0) throw invalidCursor("limit must be positive")
        val head = headCommitSeqInternal()
        if (after.toLong() > head) throw invalidCursor("cursor $after is ahead of head $head")
        val rows = driver.query(
            "SELECT * FROM bot_event_headers WHERE commit_seq > ? ORDER BY commit_seq ASC LIMIT ?",
            listOf(SqlValue.Integer(after.toLong()), SqlValue.Integer(limit.toLong())),
        )
        var expected = after.toLong() + 1
        val result = ArrayList<BotEvent>(rows.size)
        for (row in rows) {
            val sequence = row.integer("commit_seq")
                ?: throw corrupted("bot_event_headers row has no commit_seq")
            if (sequence != expected) throw commitGap(expected, sequence)
            result += decodeStoredRow(row)
            expected += 1
        }
        return result
    }

    public fun event(withId: String): BotEvent? {
        ensureOpen()
        val row = driver.query(
            "SELECT * FROM bot_event_headers WHERE event_id = ?",
            listOf(SqlValue.Text(withId)),
        ).firstOrNull() ?: return null
        return decodeStoredRow(row)
    }

    public fun eventID(botID: String, nonce: String): String? {
        ensureOpen()
        val row = driver.query(
            "SELECT event_id, created_commit_seq FROM bot_user_action_nonces WHERE bot_id = ? AND nonce = ?",
            listOf(SqlValue.Text(botID), SqlValue.Text(nonce)),
        ).firstOrNull() ?: return null
        val eventId = row.text("event_id")
            ?: throw corrupted("invalid bot_user_action_nonces row")
        val created = row.integer("created_commit_seq")
            ?: throw corrupted("invalid bot_user_action_nonces row")
        val header = driver.query(
            "SELECT commit_seq FROM bot_event_headers WHERE event_id = ?",
            listOf(SqlValue.Text(eventId)),
        ).firstOrNull()
        if (header?.integer("commit_seq") != created) {
            throw corrupted("user action nonce does not reference its committed event")
        }
        return eventId
    }

    // ---------------------------------------------------------------------
    // canonical payload and row insertion
    // ---------------------------------------------------------------------

    internal fun insertEvent(event: BotEvent, sequence: Long): Long {
        val stored = event.withCommitSeq(sequence)
        BotEventCodec.validate(stored, BotEventCodec.Mode.STORED)
        val data = BotEventCodec.encodeData(stored.data)
        val header = BotEventCodec.encodeHeaderMeta(stored)
        insertHeaderRow(sequence, stored.eventId, stored.type, data, header)
        driver.execute(
            "INSERT INTO bot_event_payloads(commit_seq, payload) VALUES (?, ?)",
            listOf(SqlValue.Integer(sequence), SqlValue.Blob(data)),
        )
        checkCrashPoint("event-insert")
        return sequence
    }

    internal fun insertHeaderRow(
        sequence: Long,
        eventId: String,
        eventType: String,
        data: ByteArray,
        header: ByteArray,
    ) {
        driver.execute(
            "INSERT INTO bot_event_headers(commit_seq, event_id, event_type, payload_digest, " +
                "payload_size, header_meta) VALUES (?, ?, ?, ?, ?, ?)",
            listOf(
                SqlValue.Integer(sequence), SqlValue.Text(eventId), SqlValue.Text(eventType),
                SqlValue.Text(sha256(data)), SqlValue.Integer(data.size.toLong()),
                SqlValue.Blob(header),
            ),
        )
    }

    internal fun existingSequence(eventId: String): Long? =
        driver.query(
            "SELECT commit_seq FROM bot_event_headers WHERE event_id = ?",
            listOf(SqlValue.Text(eventId)),
        ).firstOrNull()?.integer("commit_seq")

    internal fun decodeStoredRow(row: SqlRow): BotEvent {
        val sequence = row.integer("commit_seq")
            ?: throw corrupted("bot_event_headers row has no commit_seq")
        val eventId = row.text("event_id")
            ?: throw corrupted("bot_event_headers row has no event_id")
        val eventType = row.text("event_type")
            ?: throw corrupted("bot_event_headers row has no event_type")
        val digest = row.text("payload_digest")
            ?: throw corrupted("bot_event_headers row has no payload_digest")
        val size = row.integer("payload_size")
            ?: throw corrupted("bot_event_headers row has no payload_size")
        val headerBytes = row.blob("header_meta")
            ?: throw corrupted("bot_event_headers row has no header_meta")
        val header = try {
            BotEventCodec.decode(headerBytes, BotEventCodec.Mode.STORED)
        } catch (error: Exception) {
            throw corrupted("header_meta does not decode at commit_seq $sequence")
        }
        if (header.commitSeq != sequence || header.eventId != eventId || header.type != eventType) {
            throw corrupted("header_meta does not match columns at commit_seq $sequence")
        }
        val payloadRow = driver.query(
            "SELECT payload, erased_at, erasure_commit_seq FROM bot_event_payloads WHERE commit_seq = ?",
            listOf(SqlValue.Integer(sequence)),
        ).firstOrNull() ?: throw corrupted("event $sequence has no payload row")
        val payload = payloadRow.blob("payload")
        val erasedAt = payloadRow.integer("erased_at")
        val erasureSeq = payloadRow.integer("erasure_commit_seq")
        val data: JsonValue = if (payload != null) {
            if (erasedAt != null || erasureSeq != null) {
                throw corrupted("event $sequence has both payload and erasure markers")
            }
            if (payload.size.toLong() != size) {
                throw corrupted("payload_size mismatch at commit_seq $sequence")
            }
            if (sha256(payload) != digest) {
                throw corrupted("payload_digest mismatch at commit_seq $sequence")
            }
            BotEventCodec.decodeData(payload)
        } else {
            if (erasedAt == null || erasureSeq == null) {
                throw corrupted("event $sequence has neither payload nor erasure markers")
            }
            if (erasureSeq <= sequence) {
                throw corrupted("erasure_commit_seq must be greater than the erased sequence")
            }
            val erasureType = driver.query(
                "SELECT event_type FROM bot_event_headers WHERE commit_seq = ?",
                listOf(SqlValue.Integer(erasureSeq)),
            ).firstOrNull()?.text("event_type")
            if (erasureType != "erasure") {
                throw corrupted("event $sequence names a non-erasure event $erasureSeq")
            }
            JsonObject(
                linkedMapOf(
                    "\$erased" to com.phonedsh.agentcore.JsonBool(true),
                    "\$erasureCommitSeq" to JsonNumber(erasureSeq.toString()),
                ),
            )
        }
        val event = header.withData(data)
        try {
            BotEventCodec.validate(event, BotEventCodec.Mode.STORED)
        } catch (error: BotStoreException) {
            throw corrupted("event $sequence envelope is invalid: ${error.message}")
        }
        return event
    }

    // ---------------------------------------------------------------------
    // erasure (§5.4)
    // ---------------------------------------------------------------------

    public fun erasureTargets(commitSeqs: List<Int>): List<BotEventErasureTarget> {
        ensureOpen()
        val seen = HashSet<Long>()
        val targets = ArrayList<BotEventErasureTarget>()
        for (sequence in commitSeqs.sorted()) {
            if (!seen.add(sequence.toLong())) continue
            if (sequence < 1) throw invalidTransition("commitSeq must be positive")
            val row = driver.query(
                "SELECT h.event_type, h.payload_digest, h.payload_size, p.payload " +
                    "FROM bot_event_headers AS h " +
                    "LEFT JOIN bot_event_payloads AS p ON p.commit_seq = h.commit_seq " +
                    "WHERE h.commit_seq = ?",
                listOf(SqlValue.Integer(sequence.toLong())),
            ).firstOrNull() ?: throw invalidTransition("event $sequence does not exist")
            val type = row.text("event_type") ?: throw corrupted("event $sequence has no type")
            val digest = row.text("payload_digest")
                ?: throw corrupted("event $sequence has no payload_digest")
            val size = row.integer("payload_size")
                ?: throw corrupted("event $sequence has no payload_size")
            val bytes = if (row.blob("payload") == null) 0L else size
            targets += BotEventErasureTarget(sequence.toLong(), type, digest, bytes)
        }
        return targets
    }

    public fun erasePayloads(
        commitSeqs: List<Int>,
        erasureEvent: BotEvent,
        atMS: Long,
    ): BotEventErasureCommit {
        ensureOpen()
        if (erasureEvent.type != "erasure") {
            throw invalidTransition("erasure requires an erasure event")
        }
        if (commitSeqs.isEmpty()) {
            throw invalidTransition("erasure requires at least one payload")
        }
        BotEventCodec.validate(erasureEvent, BotEventCodec.Mode.APPEND)
        if (BotEventCodec.isEphemeral(erasureEvent.type)) {
            throw invalidTransition("erasure must be durable")
        }
        val targets = erasureTargets(commitSeqs)
        val pending = targets.filter { it.payloadBytes > 0 }
        val commit = inTransaction {
            val erasureSequence = headCommitSeqInternal() + 1
            insertEvent(erasureEvent, erasureSequence)
            for (target in pending) {
                driver.execute(
                    "UPDATE bot_event_payloads SET payload = NULL, erased_at = ?, " +
                        "erasure_commit_seq = ? WHERE commit_seq = ? AND payload IS NOT NULL",
                    listOf(
                        SqlValue.Integer(atMS), SqlValue.Integer(erasureSequence),
                        SqlValue.Integer(target.commitSeq),
                    ),
                )
                val row = driver.query(
                    "SELECT payload, erasure_commit_seq FROM bot_event_payloads WHERE commit_seq = ?",
                    listOf(SqlValue.Integer(target.commitSeq)),
                ).firstOrNull()
                if (row == null || row.blob("payload") != null ||
                    row.integer("erasure_commit_seq") != erasureSequence
                ) {
                    throw invalidTransition("event ${target.commitSeq} payload was not erased")
                }
            }
            BotEventErasureCommit(erasureSequence, targets)
        }
        secureEraseStorage()
        return commit
    }

    /** Checkpoint, VACUUM and truncate the WAL after the erasure commit. */
    public fun secureEraseStorage() {
        ensureOpen()
        driver.query("PRAGMA wal_checkpoint(TRUNCATE)")
        driver.execute("PRAGMA secure_delete=ON")
        driver.execute("VACUUM")
        driver.query("PRAGMA wal_checkpoint(TRUNCATE)")
    }

    // ---------------------------------------------------------------------
    // integrity (§8)
    // ---------------------------------------------------------------------

    public fun verifyIntegrity() {
        ensureOpen()
        scanIntegrity()
    }

    private fun scanIntegrity() {
        val quick = driver.query("PRAGMA quick_check")
        if (quick.size != 1) throw corrupted("quick_check must return exactly one row")
        val quickValue = quick.first().valuesAsText().firstOrNull()
        if (!quickValue.equals("ok", ignoreCase = true)) {
            throw corrupted("quick_check failed: $quickValue")
        }
        if (driver.query("PRAGMA foreign_key_check").isNotEmpty()) {
            throw corrupted("foreign_key_check is not empty")
        }

        val rows = driver.query("SELECT * FROM bot_event_headers ORDER BY commit_seq ASC")
        val eventSequences = HashMap<String, Long>()
        val eventBotIds = HashMap<String, String?>()
        var expected = 1L
        for (row in rows) {
            val actual = row.integer("commit_seq")
                ?: throw corrupted("bot_event_headers row has no commit_seq")
            if (actual != expected) throw commitGap(expected, actual)
            val event = decodeStoredRow(row)
            eventSequences[event.eventId] = actual
            eventBotIds[event.eventId] = event.principal.botId
            expected += 1
        }

        val nonceRows = driver.query(
            "SELECT bot_id, nonce, event_id, created_commit_seq FROM bot_user_action_nonces",
        )
        for (nonce in nonceRows) {
            val botId = nonce.text("bot_id")
            val nonceValue = nonce.text("nonce")
            val eventId = nonce.text("event_id")
            val created = nonce.integer("created_commit_seq")
            if (botId.isNullOrEmpty() || nonceValue.isNullOrEmpty() || eventId == null || created == null) {
                throw corrupted("invalid user action nonce row")
            }
            if (eventSequences[eventId] != created || eventBotIds[eventId] != botId) {
                throw corrupted("invalid user action nonce reference")
            }
        }
    }

    // ---------------------------------------------------------------------
    // ephemeral ring (§6.4)
    // ---------------------------------------------------------------------

    public fun ephemeralEvents(limit: Int = 256): List<BotEvent> {
        ensureOpen()
        if (limit < 0) throw invalidCursor("limit must not be negative")
        return ephemeralBuffer.takeLast(minOf(limit, ephemeralBuffer.size))
    }

    public fun droppedEphemeralCount(): Int {
        ensureOpen()
        return droppedEphemeral
    }

    // ---------------------------------------------------------------------
    // transaction, crash hook and close (§8)
    // ---------------------------------------------------------------------

    internal fun <T> inTransaction(block: () -> T): T {
        ensureOpen()
        driver.beginImmediate()
        try {
            val result = block()
            checkCrashPoint("abort-before-commit")
            checkCrashPoint("before-commit")
            driver.commit()
            checkCrashPoint("abort-after-commit")
            return result
        } catch (error: Throwable) {
            runCatching { driver.rollback() }
            throw mapError(error)
        }
    }

    /** Test-only crash hook; `store.md` §8 says the spelling is not contract. */
    public fun armCrashPoint(point: String) {
        crashPoint = point
    }

    internal fun checkCrashPoint(point: String) {
        if (crashPoint != point) return
        crashPoint = null
        if (point.startsWith("abort-")) closeDriverInternal()
        throw BotStoreException("simulatedCrash:$point", "injected crash at $point")
    }

    public fun ensureOpen() {
        if (closed || !driver.isOpen) throw BotStoreException("closed", "store is closed")
    }

    private fun closeDriverInternal() {
        if (!closed) {
            closed = true
            runCatching { driver.close() }
        }
    }

    override fun close() {
        closeDriverInternal()
    }

    private fun mapError(error: Throwable): Throwable {
        if (error is BotStoreException) return error
        val message = error.message.orEmpty()
        if (message.contains("SQLITE_CORRUPT", ignoreCase = true) ||
            message.contains("SQLITE_NOTADB", ignoreCase = true) ||
            message.contains("file is not a database", ignoreCase = true)
        ) {
            return corrupted(message.ifEmpty { "SQLite reported corruption" })
        }
        return if (error is SqlDriverException) {
            BotStoreException("sqlite", message, error)
        } else {
            error
        }
    }
}

public data class BotEventErasureTarget(
    public val commitSeq: Long,
    public val type: String,
    public val digest: String,
    public val payloadBytes: Long,
)

public data class BotEventErasureCommit(
    public val erasureCommitSeq: Long,
    public val erased: List<BotEventErasureTarget>,
)

/** Lowercase hexadecimal SHA-256 (`store.md` §5.3). */
public fun sha256(bytes: ByteArray): String {
    val digest = MessageDigest.getInstance("SHA-256").digest(bytes)
    val out = StringBuilder(digest.size * 2)
    for (byte in digest) out.append("%02x".format(byte))
    return out.toString()
}
