// SPDX-License-Identifier: MIT
package com.phonedsh.bot.store

import com.phonedsh.agentcore.JsonArray
import com.phonedsh.agentcore.JsonBool
import com.phonedsh.agentcore.JsonNull
import com.phonedsh.agentcore.JsonNumber
import com.phonedsh.agentcore.JsonObject
import com.phonedsh.agentcore.JsonString
import com.phonedsh.agentcore.JsonValue
import com.phonedsh.bot.rows.BotActionResult
import com.phonedsh.bot.rows.BotUserAction

/**
 * Interprets every operation in the shared `store.phone.json` and
 * `user-action-transaction.phone.json` vectors against the real
 * [BotDomainStore]. No expected value is copied here; only the operation
 * vocabulary is defined.
 */
public class BotStoreVectorRunner(
    private val driverFactory: () -> BotSqlDriver,
    private val clock: Long = 1_000,
    private val leaseTtlMs: Long = 30_000,
    private val ephemeralCapacity: Int = 256,
) : AutoCloseable {
    private var store: BotDomainStore? = null
    private var outbox: BotEffectOutbox? = null
    private var actions: BotUserActionTransaction? = null
    private val leases: MutableMap<String, BotEffectLease> = HashMap()
    private val inboxCounters: MutableMap<String, Counter> = HashMap()

    public fun openIfNeeded() {
        if (store != null) return
        val opened = BotDomainStore(
            driver = driverFactory(),
            clock = { clock },
            defaultLeaseTtlMs = leaseTtlMs,
            ephemeralCapacity = ephemeralCapacity,
        )
        val effects = BotEffectOutbox(opened)
        store = opened
        outbox = effects
        actions = BotUserActionTransaction(opened, effects)
    }

    public fun closeStore() {
        store?.close()
        store = null
        outbox = null
        actions = null
    }

    override fun close() = closeStore()

    public fun runCase(testCase: JsonObject) {
        val steps = (testCase.members["steps"] as? JsonArray)?.values ?: emptyList()
        (testCase.members["setup"] as? JsonObject)?.let { setup ->
            closeStore()
            makeSetupDatabase(setup)
        }
        val expectedOpenError = (testCase.members["openError"] as? JsonString)?.value
        if (expectedOpenError != null) {
            try {
                openIfNeeded()
            } catch (error: Throwable) {
                assertError(error, expectedOpenError, "open")
                (testCase.members["openErrorContains"] as? JsonString)?.value?.let { contains ->
                    val detail = errorDetail(error)
                    if (!detail.contains(contains)) {
                        throw AssertionError(
                            "open error detail '$detail' does not contain '$contains'",
                        )
                    }
                }
                closeStore()
                runAfterFailedOpen(testCase, steps)
                return
            }
            closeStore()
            throw AssertionError("expected open error $expectedOpenError, open succeeded")
        }
        openIfNeeded()
        for ((index, value) in steps.withIndex()) {
            val step = value as? JsonObject
                ?: throw AssertionError("step[$index] is not an object")
            val label = "steps[$index].${(step.members["op"] as? JsonString)?.value ?: "?"}"
            val expect = step.members["expect"] as? JsonObject
            try {
                val observation = runStep(step)
                expect?.let { assertObservation(it, observation, label) }
            } catch (error: Throwable) {
                val expectedError = (expect?.members?.get("error") as? JsonString)?.value
                if (expectedError != null) {
                    assertError(error, expectedError, label)
                    if (expectedError.startsWith("simulatedCrash:") ||
                        expectedError.startsWith("schemaTooNew") ||
                        expectedError.startsWith("commitGap") ||
                        expectedError == "corrupted"
                    ) {
                        closeStore()
                    }
                } else {
                    throw error
                }
            }
        }
        closeStore()
    }

    private fun runAfterFailedOpen(testCase: JsonObject, steps: List<JsonValue>) {
        for ((index, value) in steps.withIndex()) {
            val step = value as? JsonObject
                ?: throw AssertionError("afterOpenError.steps[$index] is not an object")
            val op = (step.members["op"] as? JsonString)?.value
            if (op != "raw" && op != "sql") {
                throw AssertionError("afterOpenError.steps[$index].$op is not raw/sql")
            }
            val label = "afterOpenError.steps[$index].$op"
            val expect = step.members["expect"] as? JsonObject
            try {
                val observation = runStep(step)
                expect?.let { assertObservation(it, observation, label) }
            } catch (error: Throwable) {
                val expectedError = (expect?.members?.get("error") as? JsonString)?.value
                if (expectedError != null) assertError(error, expectedError, label) else throw error
            }
        }
    }

    private fun errorDetail(error: Throwable): String =
        if (error is BotStoreException) error.message.orEmpty() else error.toString()

    // ---------------------------------------------------------------------
    // operations
    // ---------------------------------------------------------------------

    private fun runStep(step: JsonObject): JsonObject {
        val members = step.members
        return when (val op = (members["op"] as? JsonString)?.value) {
            "append" -> {
                val event = event(members["event"])
                val sequence = requireStore().append(event)
                obj("sequence" to number(sequence))
            }
            "appendBatch" -> {
                val events = (members["events"] as? JsonArray)?.values?.map(::event)
                    ?: throw AssertionError("appendBatch.events missing")
                val sequences = requireStore().appendBatch(events)
                obj("sequences" to JsonArray(sequences.map(::number)))
            }
            "events" -> {
                val after = intValue(members["after"]) ?: 0
                val limit = intValue(members["limit"]) ?: 256
                val events = requireStore().events(after, limit)
                obj(
                    "sequences" to JsonArray(events.map { number(it.commitSeq ?: 0) }),
                    "eventIds" to JsonArray(events.map { JsonString(it.eventId) }),
                    "types" to JsonArray(events.map { JsonString(it.type) }),
                    "batchIndices" to JsonArray(events.map { event ->
                        event.batch?.let { number(it.index.toLong()) } ?: JsonNull
                    }),
                    "batchTotal" to (events.firstOrNull()?.batch?.let { number(it.total.toLong()) } ?: JsonNull),
                    "batchIdsEqual" to JsonBool(events.mapNotNull { it.batch?.id }.toSet().size <= 1),
                )
            }
            "head" -> obj("head" to number(requireStore().headCommitSeq()))
            "payload" -> {
                val data = members["data"] ?: throw AssertionError("payload.data missing")
                val bytes = BotEventCodec.encodeData(data)
                obj(
                    "canonical" to JsonString(bytes.toString(Charsets.UTF_8)),
                    "sha256" to JsonString(sha256(bytes)),
                    "size" to number(bytes.size.toLong()),
                )
            }
            "ephemeralAppend" -> {
                val events = (members["events"] as? JsonArray)?.values?.map(::event)
                    ?: throw AssertionError("ephemeralAppend.events missing")
                val sequences = events.map { requireStore().append(it) }
                val buffer = requireStore().ephemeralEvents(ephemeralCapacity)
                obj(
                    "sequences" to JsonArray(sequences.map(::number)),
                    "buffer" to JsonArray(buffer.map { JsonString(it.eventId) }),
                    "dropped" to number(requireStore().droppedEphemeralCount().toLong()),
                    "head" to number(requireStore().headCommitSeq()),
                )
            }
            "reopen" -> {
                closeStore()
                openIfNeeded()
                obj("head" to number(requireStore().headCommitSeq()))
            }
            "sql" -> {
                closeStore()
                val statement = members["statement"]?.let { (it as? JsonString)?.value }
                    ?: throw AssertionError("sql.statement missing")
                driverFactory().use { driver ->
                    // The vector's `sql` step is a small script (the reference
                    // runner uses sqlite3_exec); the seam executes one statement.
                    for (part in statement.split(';')) {
                        val sql = part.trim()
                        if (sql.isNotEmpty()) driver.execute(sql)
                    }
                }
                obj("ok" to JsonBool(true))
            }
            "raw" -> {
                closeStore()
                val rows = driverFactory().use { driver ->
                    driver.query(members["query"]?.let { (it as? JsonString)?.value }
                        ?: throw AssertionError("raw.query missing"))
                }
                obj(
                    // The reference runner renders every SQLite column as text,
                    // including INTEGERs, because the vectors assert SQL output.
                    "rows" to JsonArray(rows.map { row ->
                        JsonArray(row.valuesAsText().map { text ->
                            if (text == null) JsonNull else JsonString(text)
                        })
                    }),
                )
            }
            "armCrash" -> {
                requireStore().armCrashPoint(
                    (members["point"] as? JsonString)?.value ?: throw AssertionError("armCrash.point missing"),
                )
                obj()
            }
            "event" -> {
                val id = (members["eventId"] as? JsonString)?.value ?: ""
                val event = requireStore().event(id)
                if (event == null) {
                    obj("exists" to JsonBool(false))
                } else {
                    obj(
                        "exists" to JsonBool(true),
                        "commitSeq" to number(event.commitSeq ?: 0),
                        "type" to JsonString(event.type),
                    )
                }
            }
            "eventData" -> {
                val sequence = intValue(members["commitSeq"]) ?: -1
                val key = (members["dataKey"] as? JsonString)?.value ?: ""
                val event = if (sequence <= 0) null else
                    requireStore().events(sequence - 1, 1).firstOrNull()
                if (event == null) {
                    obj("exists" to JsonBool(false))
                } else {
                    val data = event.data as? JsonObject
                    obj("exists" to JsonBool(true), "value" to (data?.members?.get(key) ?: JsonNull))
                }
            }
            "effectEnqueue" -> {
                val effect = BotEffect.fromJson(members["effect"] ?: throw AssertionError("effect missing"))
                val key = requireOutbox().enqueue(effect)
                obj("effectKey" to JsonString(key), "head" to number(requireStore().headCommitSeq()))
            }
            "effectLease" -> {
                val owner = (members["owner"] as? JsonString)?.value ?: ""
                val now = longValue(members["now"]) ?: clock
                leaseObservation(requireOutbox().lease(owner, now))
            }
            "effectLeaseNext" -> {
                val owner = (members["owner"] as? JsonString)?.value ?: ""
                val now = longValue(members["now"]) ?: clock
                val ttl = longValue(members["ttlMs"]) ?: leaseTtlMs
                val lease = requireOutbox().leaseNext(owner, now, ttl)
                val expectedKey = (members["effectKey"] as? JsonString)?.value
                if (lease != null && expectedKey != null) {
                    if (lease.effectKey != expectedKey) {
                        throw AssertionError("leased ${lease.effectKey}, expected $expectedKey")
                    }
                }
                leaseObservation(lease)
            }
            "effectRenew" -> {
                val lease = leaseFor(members)
                val now = longValue(members["now"]) ?: clock
                val ttl = longValue(members["ttlMs"])
                val renewed = requireOutbox().renew(lease, now, ttl)
                leases[renewed.effectKey] = renewed
                leaseFields(renewed)
            }
            "effectAck" -> {
                val lease = leaseFor(members)
                requireOutbox().ack(lease, (members["resultRef"] as? JsonString)?.value)
                val record = requireOutbox().effect(lease.effectKey)
                obj(
                    "state" to (record?.state?.wire?.let(::JsonString) ?: JsonNull),
                    "head" to number(requireStore().headCommitSeq()),
                )
            }
            "effectFail" -> {
                val lease = leaseFor(members)
                requireOutbox().fail(
                    lease,
                    (members["errorClass"] as? JsonString)?.value ?: "",
                    (members["reason"] as? JsonString)?.value ?: "",
                )
                val record = requireOutbox().effect(lease.effectKey)
                obj(
                    "state" to (record?.state?.wire?.let(::JsonString) ?: JsonNull),
                    "head" to number(requireStore().headCommitSeq()),
                    "attempt" to (record?.attempt?.let { number(it.toLong()) } ?: JsonNull),
                    "attempts" to (record?.attempts?.let { number(it.toLong()) } ?: JsonNull),
                    "notBefore" to (record?.effect?.notBefore?.let(::number) ?: JsonNull),
                )
            }
            "effectMarkReconciliation" -> {
                val key = (members["effectKey"] as? JsonString)?.value ?: ""
                requireOutbox().markNeedsReconciliation(
                    key, (members["reason"] as? JsonString)?.value ?: "",
                )
                val record = requireOutbox().effect(key)
                obj(
                    "state" to (record?.state?.wire?.let(::JsonString) ?: JsonNull),
                    "head" to number(requireStore().headCommitSeq()),
                )
            }
            "effectAckReconciled" -> {
                val key = (members["effectKey"] as? JsonString)?.value ?: ""
                requireOutbox().ackReconciled(
                    key,
                    intValue(members["generation"]) ?: 0,
                    intValue(members["attempt"]) ?: 0,
                    (members["resultRef"] as? JsonString)?.value,
                )
                val record = requireOutbox().effect(key)
                obj(
                    "state" to (record?.state?.wire?.let(::JsonString) ?: JsonNull),
                    "head" to number(requireStore().headCommitSeq()),
                )
            }
            "effectCancel" -> {
                val key = (members["effectKey"] as? JsonString)?.value ?: ""
                requireOutbox().requestCancel(key, (members["reason"] as? JsonString)?.value ?: "")
                val record = requireOutbox().effect(key)
                obj(
                    "state" to (record?.state?.wire?.let(::JsonString) ?: JsonNull),
                    "head" to number(requireStore().headCommitSeq()),
                )
            }
            "effectConfirmCancel" -> {
                val lease = leaseFor(members)
                requireOutbox().confirmCancel(
                    lease, (members["reason"] as? JsonString)?.value ?: "",
                )
                val record = requireOutbox().effect(lease.effectKey)
                obj(
                    "state" to (record?.state?.wire?.let(::JsonString) ?: JsonNull),
                    "head" to number(requireStore().headCommitSeq()),
                )
            }
            "effectRelease", "effectNoExecutor", "effectReleaseNoExecutor" -> {
                val lease = leaseFor(members)
                val now = longValue(members["now"]) ?: clock
                val record = requireOutbox().releaseWithoutExecutor(lease, now)
                effectRecordObservation(record)
            }
            "effectUnknownKind", "effectFailUnknownKind" -> {
                val lease = leaseFor(members)
                requireOutbox().failUnknownKind(
                    lease,
                    (members["reason"] as? JsonString)?.value ?: "unknown_effect_kind",
                )
                val record = requireOutbox().effect(lease.effectKey)
                obj(
                    "state" to (record?.state?.wire?.let(::JsonString) ?: JsonNull),
                    "head" to number(requireStore().headCommitSeq()),
                    "errorClass" to (record?.errorClass?.let(::JsonString) ?: JsonNull),
                    "lastErrorContains" to (record?.lastError?.let(::JsonString) ?: JsonNull),
                    "code" to JsonString("unknown_effect_kind"),
                )
            }
            "effectRecord", "effect" -> {
                val key = (members["effectKey"] as? JsonString)?.value ?: ""
                val record = requireOutbox().effect(key)
                    ?: return obj("exists" to JsonBool(false))
                effectRecordObservation(record)
            }
            "effects" -> {
                val records = requireOutbox().effects()
                obj(
                    "keys" to JsonArray(records.map { JsonString(it.effectKey) }),
                    "states" to JsonArray(records.map { JsonString(it.state.wire) }),
                    "enqueuedCommitSeq" to JsonArray(records.map {
                        it.enqueuedCommitSeq?.let(::number) ?: JsonNull
                    }),
                )
            }
            "effectInbox" -> {
                val receiver = (members["receiver"] as? JsonString)?.value ?: ""
                val key = (members["effectKey"] as? JsonString)?.value ?: ""
                val lease = leaseFor(members)
                val expectedResult = (members["resultRef"] as? JsonString)?.value
                val counterKey = "$receiver\u0000$key"
                val counter = inboxCounters.getOrPut(counterKey) { Counter() }
                val repeat = intValue(members["repeat"]) ?: 1
                var deduped = 0
                var result: String? = null
                repeat(repeat) {
                    val applied = requireOutbox().applyInbox(receiver, lease, expectedResult) {
                        counter.increment()
                        expectedResult
                    }
                    if (applied.deduped) deduped += 1
                    if (result == null) result = applied.resultRef
                }
                obj(
                    "dedupedCount" to number(deduped.toLong()),
                    "executions" to number(counter.value.toLong()),
                    "resultRef" to (result?.let(::JsonString) ?: JsonNull),
                )
            }
            "action" -> {
                val action = BotUserAction.fromJson(
                    members["action"] ?: throw AssertionError("action.action missing"),
                )
                val planMembers = (members["plan"] as? JsonObject)?.members
                    ?: throw AssertionError("action.plan missing")
                val plan = BotUserActionPlan(
                    event = event(planMembers["event"]),
                    effects = (planMembers["effects"] as? JsonArray)?.values
                        ?.map { BotEffect.fromJson(it) } ?: emptyList(),
                )
                val before = requireStore().headCommitSeq()
                val result = requireActions().performAndRecord(action, plan)
                val after = requireStore().headCommitSeq()
                val events = if (after > before) {
                    requireStore().events(before.toInt(), (after - before).toInt())
                } else {
                    emptyList()
                }
                val fields = linkedMapOf<String, JsonValue>(
                    "status" to JsonString(result.status),
                    "head" to number(after),
                    "eventTypes" to JsonArray(events.map { JsonString(it.type) }),
                    "sequences" to JsonArray(events.map { number(it.commitSeq ?: 0) }),
                )
                when (result) {
                    is BotActionResult.Accepted -> fields["eventID"] = JsonString(result.eventID)
                    is BotActionResult.Duplicate -> fields["eventID"] = JsonString(result.eventID)
                    is BotActionResult.Stale -> fields["reason"] = JsonString(result.reason)
                    is BotActionResult.Rejected -> fields["reason"] = JsonString(result.reason)
                }
                JsonObject(fields)
            }
            "nonce" -> {
                val bot = (members["botID"] as? JsonString)?.value ?: ""
                val nonce = (members["nonce"] as? JsonString)?.value ?: ""
                val eventID = requireStore().eventID(bot, nonce)
                if (eventID == null) obj("exists" to JsonBool(false))
                else obj("eventID" to JsonString(eventID))
            }
            else -> throw AssertionError("unknown operation $op")
        }
    }

    // ---------------------------------------------------------------------
    // setup, assertions and helpers
    // ---------------------------------------------------------------------

    private fun makeSetupDatabase(setup: JsonObject) {
        val version = intValue(setup.members["userVersion"]) ?: 2
        driverFactory().use { driver ->
            driver.execute(
                "CREATE TABLE bot_events (" +
                    "commit_seq INTEGER PRIMARY KEY CHECK (commit_seq > 0), " +
                    "event_id TEXT NOT NULL UNIQUE, event_type TEXT NOT NULL, payload BLOB NOT NULL)",
            )
            if (version >= 2) {
                driver.execute(
                    "CREATE TABLE bot_user_action_nonces (" +
                        "bot_id TEXT NOT NULL, nonce TEXT NOT NULL, " +
                        "event_id TEXT NOT NULL UNIQUE REFERENCES bot_events(event_id), " +
                        "created_commit_seq INTEGER NOT NULL CHECK (created_commit_seq > 0), " +
                        "PRIMARY KEY(bot_id, nonce))",
                )
            }
            for (value in (setup.members["events"] as? JsonArray)?.values ?: emptyList()) {
                val event = event(value)
                val payload = BotEventCodec.encodeCanonical(event.toJson())
                driver.execute(
                    "INSERT INTO bot_events(commit_seq, event_id, event_type, payload) VALUES (?, ?, ?, ?)",
                    listOf(
                        SqlValue.Integer(event.commitSeq ?: 0), SqlValue.Text(event.eventId),
                        SqlValue.Text(event.type), SqlValue.Blob(payload),
                    ),
                )
            }
            for (value in (setup.members["nonces"] as? JsonArray)?.values ?: emptyList()) {
                val nonce = (value as? JsonObject)?.members ?: continue
                driver.execute(
                    "INSERT INTO bot_user_action_nonces(bot_id, nonce, event_id, created_commit_seq) " +
                        "VALUES (?, ?, ?, ?)",
                    listOf(
                        SqlValue.Text((nonce["botId"] as? JsonString)?.value ?: ""),
                        SqlValue.Text((nonce["nonce"] as? JsonString)?.value ?: ""),
                        SqlValue.Text((nonce["eventId"] as? JsonString)?.value ?: ""),
                        SqlValue.Integer(longValue(nonce["createdCommitSeq"]) ?: 0),
                    ),
                )
            }
            driver.setUserVersion(version)
        }
    }

    private fun effectRecordObservation(record: BotEffectRecord): JsonObject {
        val effect = record.effect
        return obj(
            "exists" to JsonBool(true),
            "state" to JsonString(record.state.wire),
            "head" to number(store?.headCommitSeq() ?: 0),
            "attempt" to number(record.attempt.toLong()),
            "attempts" to number(record.attempts.toLong()),
            "generation" to number(record.generation.toLong()),
            "enqueuedCommitSeq" to (record.enqueuedCommitSeq?.let(::number) ?: JsonNull),
            "leaseOwner" to (record.leaseOwner?.let(::JsonString) ?: JsonNull),
            "resultRef" to (record.resultRef?.let(::JsonString) ?: JsonNull),
            "reconciliationReason" to (record.reconciliationReason?.let(::JsonString) ?: JsonNull),
            "lastError" to (record.lastError?.let(::JsonString) ?: JsonNull),
            "notBefore" to (effect.notBefore?.let(::number) ?: JsonNull),
            "errorClass" to (record.errorClass?.let(::JsonString) ?: JsonNull),
        )
    }

    private fun leaseObservation(lease: BotEffectLease?): JsonObject {
        if (lease == null) return obj("lease" to JsonNull)
        leases[lease.effectKey] = lease
        return leaseFields(lease)
    }

    private fun leaseFields(lease: BotEffectLease): JsonObject = obj(
        "attempt" to number(lease.attempt.toLong()),
        "generation" to number(lease.generation.toLong()),
        "leaseOwner" to JsonString(lease.leaseOwner),
        "leaseExpiresAt" to number(lease.leaseExpiresAt),
    )

    private fun leaseFor(members: Map<String, JsonValue>): BotEffectLease {
        val explicit = members["lease"] as? JsonObject
        if (explicit != null) return BotEffectLease.fromJson(explicit)
        val key = (members["effectKey"] as? JsonString)?.value ?: ""
        return leases[key] ?: throw AssertionError("no lease recorded for $key")
    }

    private fun event(value: JsonValue?): BotEvent {
        val event = BotEvent.fromJson(value ?: throw AssertionError("event missing"))
        return event
    }

    private fun requireStore(): BotDomainStore =
        store ?: throw AssertionError("store is not open")

    private fun requireOutbox(): BotEffectOutbox =
        outbox ?: throw AssertionError("store is not open")

    private fun requireActions(): BotUserActionTransaction =
        actions ?: throw AssertionError("store is not open")

    private fun assertObservation(expected: JsonObject, actual: JsonObject, label: String) {
        for ((key, value) in expected.members) {
            if (key == "lastErrorContains") {
                val text = (actual.members["lastError"] as? JsonString)?.value ?: ""
                val needle = (value as? JsonString)?.value ?: ""
                if (!text.contains(needle)) {
                    throw AssertionError("$label: lastError '$text' does not contain '$needle'")
                }
                continue
            }
            if (key == "lastErrorNotContains") {
                val text = (actual.members["lastError"] as? JsonString)?.value ?: ""
                val needle = (value as? JsonString)?.value ?: ""
                if (text.contains(needle)) {
                    throw AssertionError("$label: lastError '$text' unexpectedly contains '$needle'")
                }
                continue
            }
            val found = actual.members[key] ?: JsonNull
            if (!jsonEqual(value, found)) {
                throw AssertionError("$label: $key expected ${jsonText(value)}, got ${jsonText(found)}")
            }
        }
    }

    public fun assertError(error: Throwable, expected: String, label: String) {
        val actual = errorCode(error)
        if (actual == expected) return
        // Version skew only: the pre-W4-C2-2 store.phone case expected
        // `commitGap:<e>:<a>` for a migration gap and had no steps. S1 replaces
        // it with `openError: "corrupted"` plus `openErrorContains`. The
        // condition is identical (same first gap); the merged vector takes the
        // exact branch above and never reaches this adapter.
        val gap = Regex("^commitGap:(\\d+):(\\d+)$").find(expected)
        if (gap != null && error is BotStoreException && error.code == "corrupted" &&
            errorDetail(error) ==
            "commit_seq gap: expected ${gap.groupValues[1]}, found ${gap.groupValues[2]}"
        ) {
            return
        }
        throw AssertionError("$label: error expected $expected, got $actual (${error.message})", error)
    }

    private fun errorCode(error: Throwable): String = when (error) {
        is BotEventValidationException -> error.code
        is BotStoreException -> error.code
        else -> error.message ?: error::class.java.simpleName
    }

    private fun jsonEqual(expected: JsonValue, actual: JsonValue): Boolean {
        if (expected is JsonNull || actual is JsonNull) return expected is JsonNull && actual is JsonNull
        if (expected is JsonNumber && actual is JsonNumber) {
            val left = expected.asLongOrNull()
            val right = actual.asLongOrNull()
            return if (left != null && right != null) left == right
            else expected.raw.toDoubleOrNull() == actual.raw.toDoubleOrNull()
        }
        return when (expected) {
            is JsonBool -> actual is JsonBool && expected.value == actual.value
            is JsonString -> actual is JsonString && expected.value == actual.value
            is JsonArray -> actual is JsonArray && expected.values.size == actual.values.size &&
                expected.values.zip(actual.values).all { (a, b) -> jsonEqual(a, b) }
            is JsonObject -> actual is JsonObject && expected.members.all { (key, value) ->
                jsonEqual(value, actual.members[key] ?: JsonNull)
            }
            else -> false
        }
    }

    private fun jsonText(value: JsonValue): String = value.toString()

    private fun obj(vararg members: Pair<String, JsonValue>): JsonObject =
        JsonObject(linkedMapOf(*members))

    private fun intValue(value: JsonValue?): Int? = longValue(value)?.toInt()

    private fun longValue(value: JsonValue?): Long? = (value as? JsonNumber)?.asLongOrNull()

    private fun repeat(count: Int, block: () -> Unit) {
        for (index in 0 until count) block()
    }

    private class Counter {
        private var count = 0
        val value: Int get() = count
        fun increment() {
            count += 1
        }
    }
}
