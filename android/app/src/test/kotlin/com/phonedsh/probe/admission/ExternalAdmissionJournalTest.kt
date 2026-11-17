// SPDX-License-Identifier: MIT
// The Android end of the frozen external admission contract
// (spec/host/v1/external-admission.md, revision external-admission-v1): the
// REAL journal, codec and policy are driven through every section of the
// shared vectors in spec/host/v1/fixtures/external-admission-v1.json and
// through the five goldens. Records named `existing` in a vector are real files
// in the journal's directory; the capacity counts are real files too.
//
// Host JVM evidence only: no device, no power loss.
package com.phonedsh.probe.admission

import com.phonedsh.agentcore.JsonNumber
import com.phonedsh.agentcore.JsonObject
import com.phonedsh.agentcore.JsonString
import com.phonedsh.agentcore.JsonValue
import com.phonedsh.probe.outbox.SpecSchema
import com.phonedsh.probe.outbox.array
import com.phonedsh.probe.outbox.bool
import com.phonedsh.probe.outbox.child
import com.phonedsh.probe.outbox.long
import com.phonedsh.probe.outbox.objects
import com.phonedsh.probe.outbox.string
import com.phonedsh.probe.outbox.with
import com.phonedsh.probe.outbox.without
import com.phonedsh.probe.outbox.HostSpec
import java.nio.file.Files
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Before
import org.junit.Test

class ExternalAdmissionJournalTest {
    private lateinit var sandbox: AdmissionSandbox
    private val fixture = AdmissionSpec.fixture
    private val schema = AdmissionSpec.schema

    @Before
    fun setUp() {
        sandbox = AdmissionSandbox(Files.createTempDirectory("admissions").toFile())
    }

    @After
    fun tearDown() {
        sandbox.root.deleteRecursively()
    }

    private fun source(value: JsonObject) =
        AdmissionSource(AdmissionSourceKind.fromWire(value.string("kind"))!!, value.string("id"))

    private fun assertSchemaValid(label: String, value: JsonValue) =
        assertEquals(label, emptyList<String>(), SpecSchema.validate(schema, value))

    private fun stored(admissionId: String): JsonValue = JsonValue.parse(sandbox.file(admissionId).readText())

    // ------------------------------------------------------- revision and limits

    @Test
    fun `the fixture is the frozen revision and its limits are the implemented limits`() {
        assertEquals("external-admission-v1.1", fixture.string("revision"))
        val limits = fixture.child("limits")
        val implemented = mapOf(
            "maxTextBytes" to AdmissionPolicy.MAX_TEXT_BYTES.toLong(),
            "minTtlMs" to AdmissionPolicy.MIN_TTL_MS,
            "maxTtlMs" to AdmissionPolicy.MAX_TTL_MS,
            "maxPending" to AdmissionPolicy.MAX_PENDING.toLong(),
            "maxEntries" to AdmissionPolicy.MAX_ENTRIES.toLong(),
            "maxAttempts" to AdmissionPolicy.MAX_ATTEMPTS.toLong(),
            "tombstoneMs" to AdmissionPolicy.TOMBSTONE_MS,
            "linkedTimeoutMs" to AdmissionPolicy.LINKED_TIMEOUT_MS,
            "passLimit" to AdmissionPolicy.PASS_LIMIT.toLong(),
        )
        assertEquals(implemented.keys, limits.members.keys)
        for ((name, value) in implemented) assertEquals(name, limits.long(name), value)
    }

    // ---------------------------------------------------------- ids and content

    @Test
    fun `ids - the journal files a request under the fixture admissionId`() {
        val cases = fixture.objects("ids")
        assertTrue(cases.size >= 4)
        cases.forEachIndexed { index, case ->
            val expected = case.string("admissionId")
            val from = source(case.child("source"))
            assertEquals(expected, AdmissionPolicy.admissionId(case.string("principal"), from, case.string("sourceRequestId")))
            val result = sandbox.journal(TestClock()).admit(
                AdmissionSpec.request(
                    requestId = case.string("sourceRequestId"),
                    principal = case.string("principal"),
                    source = from,
                    downstreamId = AdmissionSpec.uuid(index),
                ),
            )
            assertEquals(expected, (result as AdmissionResult.Admitted).receipt.admissionId)
            assertTrue(sandbox.file(expected).isFile)
            assertEquals(expected, (stored(expected) as JsonObject).string("admissionId"))
        }
        assertEquals(cases.map { it.string("admissionId") }.toSet().size, sandbox.directory.list()!!.size)
    }

    @Test
    fun `content - the journal stores the fixture digest of the text`() {
        fixture.objects("content").forEachIndexed { index, case ->
            assertEquals(case.string("contentSha256"), AdmissionPolicy.contentSha256(case.string("text")))
            val result = sandbox.journal(TestClock()).admit(
                AdmissionSpec.request(requestId = "content-$index", text = case.string("text"), downstreamId = AdmissionSpec.uuid(index)),
            ) as AdmissionResult.Admitted
            val record = sandbox.journal(TestClock()).record(result.receipt.admissionId)!!
            assertEquals(case.string("contentSha256"), record.contentSha256)
            assertEquals(case.string("text"), record.text)
        }
    }

    // ------------------------------------------------------------------ records

    @Test
    fun `records valid - each decodes re-encodes and is read from its file by the journal`() {
        val cases = fixture.child("records").objects("valid")
        assertTrue(cases.isNotEmpty())
        for (case in cases) {
            val id = case.string("id")
            val raw = case.child("record")
            assertSchemaValid(id, raw)
            val record = AdmissionCodec.decode(raw)
            assertEquals(id, raw, JsonValue.parse(AdmissionCodec.encode(record)))
            sandbox.reset()
            sandbox.seedRaw(record.admissionId, raw)
            val before = sandbox.snapshot()
            val journal = sandbox.journal(TestClock(record.admittedAtMs))
            assertEquals(id, record, journal.record(record.admissionId))
            assertEquals(id, listOf(record), journal.records())
            assertEquals(id, before, sandbox.snapshot())
        }
    }

    @Test
    fun `records invalid - each is rejected by its own rule and its file is left untouched`() {
        val kinds = HashSet<String>()
        for (case in fixture.child("records").objects("invalid")) {
            val id = case.string("id")
            val raw = case.child("record")
            val by = case.string("by")
            kinds.add(by)
            val expected = when (by) {
                "schema" -> {
                    assertTrue("$id must be schema-invalid", SpecSchema.validate(schema, raw).isNotEmpty())
                    AdmissionInvalidReason.SCHEMA
                }
                "identity" -> {
                    assertSchemaValid(id, raw)
                    AdmissionInvalidReason.IDENTITY
                }
                else -> throw AssertionError("unknown invalid kind in $id")
            }
            try {
                AdmissionCodec.decode(raw)
                fail("$id decoded")
            } catch (rejected: AdmissionInvalidRecordException) {
                assertEquals(id, expected, rejected.reason)
            }
            // As a file: not a record, never dispatched, never swept, still counted.
            sandbox.reset()
            val name = (raw["admissionId"] as JsonString).value.lowercase()
            sandbox.seedRaw(name, raw)
            val before = sandbox.snapshot()
            val clock = TestClock(AdmissionSpec.T0 + 400 * AdmissionSpec.DAY)
            val journal = sandbox.journal(clock)
            assertNull(id, journal.record(name))
            assertTrue(id, journal.records().isEmpty())
            assertTrue(id, journal.dispatchable().isEmpty())
            journal.sweep()
            assertEquals(id, 1, journal.directoryEntryCount())
            assertEquals(id, before, sandbox.snapshot())
        }
        assertEquals(setOf("schema", "identity"), kinds)
    }

    @Test
    fun `the five goldens decode re-encode and validate`() {
        val stages = HashSet<AdmissionStage>()
        for (name in AdmissionSpec.GOLDENS) {
            val instance = HostSpec.goldenInstance(name)
            assertSchemaValid(name, instance)
            val record = AdmissionCodec.decode(instance)
            stages.add(record.stage)
            val encoded = JsonValue.parse(AdmissionCodec.encode(record))
            assertEquals(name, instance, encoded)
            assertEquals(name, record.stage.isPending, record.text != null)
            assertEquals(name, record.stage.isTerminal, record.settledAtMs != null)
        }
        assertEquals(
            setOf(
                AdmissionStage.ADMITTED, AdmissionStage.DISPATCHING, AdmissionStage.LINKED,
                AdmissionStage.COMPLETED, AdmissionStage.EXPIRED,
            ),
            stages,
        )
        val bot = AdmissionCodec.decode(HostSpec.goldenInstance("admission-record-dispatching-retry.json"))
        assertEquals(AdmissionTarget.Bot("bot-7f3a"), bot.target)
        assertEquals(2, bot.attempts)
        assertEquals("downstream_unavailable", bot.lastError)
    }

    // -------------------------------------------------------------------- admit

    @Test
    fun `admit - every decision vector through the real journal over real files`() {
        val seen = HashSet<String>()
        var undecodable = 0
        for (case in fixture.objects("admit")) {
            val id = case.string("id")
            val now = case.long("now")
            val expected = case.string("result")
            seen.add(expected)
            sandbox.reset()

            val existing = (case["existing"]?.let { case.objects("existing") }).orEmpty()
            for (record in existing) sandbox.seedRaw(record.string("admissionId"), record)
            val pendingSeeded = existing.count { it.string("stage") in setOf("admitted", "dispatching") }
            val pendingWanted = (case["pendingCount"] as? JsonNumber)?.asLongOrNull()?.toInt() ?: pendingSeeded
            for (index in pendingSeeded until pendingWanted) {
                sandbox.seed(AdmissionSpec.recordIn(AdmissionStage.ADMITTED, requestId = "filler-$index", admittedAtMs = now))
            }
            // The rest of the directory bound is made of files that are not records at all.
            val entriesWanted = (case["directoryEntries"] as? JsonNumber)?.asLongOrNull()?.toInt() ?: 0
            var filler = 0
            while (sandbox.directory.list().orEmpty().size < entriesWanted) {
                sandbox.seedBytes("not-a-record-${filler++}.bin", "x")
            }
            if (case["directoryEntries"] != null) assertEquals(id, entriesWanted, sandbox.directory.list()!!.size)
            var requestJson = case.child("request")
            (requestJson["textRepeat"] as? JsonObject)?.let { repeat ->
                val text = repeat.string("unit").repeat(repeat.long("count").toInt())
                requestJson = requestJson.without("textRepeat").with("text" to JsonString(text))
            }
            val request = AdmissionCodec.decodeRequest(requestJson)
            // v1.1: a real file under the request's own id that is not a v1 record.
            if ((case["undecodableOwnFile"] as? com.phonedsh.agentcore.JsonBool)?.value == true) {
                undecodable++
                val ownId = AdmissionPolicy.admissionId(
                    requestJson.string("principal"),
                    source(requestJson.child("source")),
                    requestJson.string("sourceRequestId"),
                )
                val wanted = (case["directoryEntries"] as? JsonNumber)?.asLongOrNull()?.toInt()
                if (wanted != null) assertTrue(java.io.File(sandbox.directory, "not-a-record-0.bin").delete())
                sandbox.seedBytes("$ownId.json", "{\"v\":2,\"admissionId\":\"$ownId\"}")
                if (wanted != null) assertEquals(id, wanted, sandbox.directory.list()!!.size)
            }
            val before = sandbox.snapshot()

            val journal = sandbox.journal(TestClock(now))
            assertEquals("$id: opening must not change what an earlier process left", before, sandbox.snapshot())
            val result = if (request == null) AdmissionResult.Invalid else journal.admit(request)
            assertEquals(id, expected, result.name())

            when (result) {
                is AdmissionResult.Admitted -> {
                    val receipt = result.receipt
                    assertEquals(id, requestJson.string("downstreamId"), receipt.downstreamId)
                    assertEquals(id, AdmissionStage.ADMITTED, receipt.stage)
                    assertEquals(id, before.size + 1, sandbox.directory.list()!!.size)
                    val raw = stored(receipt.admissionId)
                    assertSchemaValid(id, raw)
                    val record = sandbox.journal(TestClock(now)).record(receipt.admissionId)!!
                    assertEquals(id, AdmissionStage.ADMITTED, record.stage)
                    assertEquals(id, 0, record.attempts)
                    assertEquals(id, now, record.admittedAtMs)
                    assertEquals(id, requestJson.string("text"), record.text)
                    assertEquals(id, requestJson.long("expiresAtMs"), record.expiresAtMs)
                    assertEquals(id, request!!.target, record.target)
                    assertEquals(id, AdmissionPolicy.contentSha256(requestJson.string("text")), record.contentSha256)
                }
                is AdmissionResult.Duplicate -> {
                    val original = existing.single { it.string("admissionId") == result.receipt.admissionId }
                    assertEquals(id, original.string("downstreamId"), result.receipt.downstreamId)
                    assertEquals(id, original.string("stage"), result.receipt.stage.wire)
                    assertEquals("$id: nothing is written for a duplicate", before, sandbox.snapshot())
                }
                else -> assertEquals("$id: nothing is written for $expected", before, sandbox.snapshot())
            }
        }
        assertEquals(setOf("admitted", "duplicate", "conflict", "capacity", "invalid", "storage"), seen)
        assertEquals(3, undecodable)
    }

    @Test
    fun `admit - a missing downstreamId is minted once as a lowercase UUIDv4 and never changes`() {
        val journal = sandbox.journal(TestClock(), newUuid = { "5b6d3f2a-1c4e-4e8f-9a0b-1c2d3e4f5a6b" })
        val first = journal.admit(AdmissionSpec.request(downstreamId = null)) as AdmissionResult.Admitted
        assertEquals("5b6d3f2a-1c4e-4e8f-9a0b-1c2d3e4f5a6b", first.receipt.downstreamId)
        // A redelivery with a different freshly minted id still returns the admitted one.
        val again = sandbox.journal(TestClock(), newUuid = { AdmissionSpec.uuid(99) })
            .admit(AdmissionSpec.request(downstreamId = null)) as AdmissionResult.Duplicate
        assertEquals(first.receipt, again.receipt)
    }

    @Test
    fun `admit - a failed write is storage with no receipt and no record`() {
        val failing = object : com.phonedsh.probe.outbox.DurableFileStore() {
            override fun writeAtomically(target: java.io.File, bytes: ByteArray): Unit = throw java.io.IOException("disk full")
        }
        val result = sandbox.journal(TestClock(), failing).admit(AdmissionSpec.request())
        assertTrue(result is AdmissionResult.Storage)
        assertTrue(sandbox.journal(TestClock()).records().isEmpty())
    }

    // -------------------------------------------------------------- transitions

    @Test
    fun `transitions - the full 8 by 8 table through the real journal`() {
        val cases = fixture.objects("transitions")
        val pairs = HashSet<Pair<String, String>>()
        for (case in cases) {
            val from = AdmissionStage.fromWire(case.string("from"))!!
            val to = AdmissionStage.fromWire(case.string("to"))!!
            val allowed = case.bool("allowed")
            val label = "${from.wire} → ${to.wire}"
            pairs.add(from.wire to to.wire)
            assertEquals(label, allowed, AdmissionPolicy.allows(from, to))

            sandbox.reset()
            val seeded = AdmissionSpec.recordIn(from)
            sandbox.seed(seeded)
            val before = sandbox.snapshot()
            val clock = TestClock()
            val journal = sandbox.journal(clock)
            assertEquals("$label: opening changed the seed", before, sandbox.snapshot())
            // The expiry edge exists only once the clock has reached expiresAtMs.
            if (to == AdmissionStage.EXPIRED) clock.now = seeded.expiresAtMs
            val settleAt = clock.now
            try {
                val moved = move(journal, seeded.admissionId, to)
                assertTrue("$label was allowed", allowed)
                assertEquals(label, to, moved.stage)
                val raw = stored(seeded.admissionId)
                assertSchemaValid(label, raw)
                val reread = sandbox.journal(clock).record(seeded.admissionId)!!
                assertEquals(label, moved, reread)
                assertEquals("$label: text leaves with the pending stages", to.isPending, reread.text != null)
                assertEquals(label, seeded.downstreamId, reread.downstreamId)
                assertEquals(label, seeded.target, reread.target)
                assertEquals(label, seeded.contentSha256, reread.contentSha256)
                if (to.isTerminal) assertEquals(label, settleAt, reread.settledAtMs)
                if (to == AdmissionStage.LINKED) assertEquals(label, settleAt, reread.linkedAtMs)
            } catch (refused: AdmissionException.IllegalTransition) {
                assertFalse("$label was refused", allowed)
                assertEquals(label, from, refused.from)
                assertEquals(label, to, refused.to)
                assertEquals("$label: a refused edge writes nothing", before, sandbox.snapshot())
            }
        }
        assertEquals(64, cases.size)
        assertEquals(64, pairs.size)
        val stages = AdmissionStage.entries.map { it.wire }
        assertEquals(stages.flatMap { a -> stages.map { b -> a to b } }.toSet(), pairs)
    }

    @Test
    fun `the expiry edge is closed before expiresAtMs and a reason must be a short code`() {
        val seeded = AdmissionSpec.recordIn(AdmissionStage.ADMITTED)
        sandbox.seed(seeded)
        val clock = TestClock(seeded.expiresAtMs - 1)
        val journal = sandbox.journal(clock)
        val before = sandbox.snapshot()
        try {
            journal.expire(seeded.admissionId)
            fail("expired early")
        } catch (_: AdmissionException.NotExpired) {
            assertEquals(before, sandbox.snapshot())
        }
        try {
            journal.fail(seeded.admissionId, "Target Missing!")
            fail("accepted free text as a reason")
        } catch (_: AdmissionException.InvalidCode) {
            assertEquals(before, sandbox.snapshot())
        }
        try {
            journal.markDispatching("0".repeat(64))
            fail("moved a record that does not exist")
        } catch (_: AdmissionException.UnknownRecord) {
            assertEquals(before, sandbox.snapshot())
        }
        clock.now = seeded.expiresAtMs
        val expired = journal.expire(seeded.admissionId)
        assertEquals("expired", expired.reason)
        assertEquals(seeded.expiresAtMs, expired.settledAtMs)
    }

    private fun move(journal: ExternalAdmissionJournal, id: String, to: AdmissionStage): AdmissionRecord = when (to) {
        AdmissionStage.ADMITTED -> journal.retryLater(id, "downstream_unavailable")
        AdmissionStage.DISPATCHING -> journal.markDispatching(id)
        AdmissionStage.LINKED -> journal.markLinked(id)
        AdmissionStage.COMPLETED -> journal.complete(id)
        AdmissionStage.FAILED -> journal.fail(id, "target_missing")
        AdmissionStage.EXPIRED -> journal.expire(id)
        AdmissionStage.CANCELLED -> journal.cancel(id, "withdrawn")
        AdmissionStage.UNKNOWN -> journal.markUnknown(id)
    }

    // -------------------------------------------------------------------- retry

    @Test
    fun `retry - every vector through a real dispatching record`() {
        val results = HashSet<String>()
        for (case in fixture.objects("retry")) {
            val attempts = case.long("attempts").toInt()
            val now = case.long("now")
            val expected = case.child("result")
            results.add(expected.string("stage"))
            when (val outcome = AdmissionPolicy.retry(attempts, now)) {
                is AdmissionRetry.Again -> {
                    assertEquals("admitted", expected.string("stage"))
                    assertEquals(expected.long("attempts").toInt(), outcome.attempts)
                    assertEquals(expected.long("nextAttemptAtMs"), outcome.nextAttemptAtMs)
                }
                AdmissionRetry.Exhausted -> {
                    assertEquals("failed", expected.string("stage"))
                    assertEquals(AdmissionPolicy.RETRY_EXHAUSTED, expected.string("reason"))
                }
            }

            sandbox.reset()
            val seeded = AdmissionSpec.recordIn(AdmissionStage.DISPATCHING, attempts = attempts, admittedAtMs = now - 5_000)
            sandbox.seed(seeded)
            val journal = sandbox.journal(TestClock(now))
            val after = journal.retryLater(seeded.admissionId, "downstream_unavailable")
            assertSchemaValid("retry after $attempts", stored(seeded.admissionId))
            assertEquals(expected.string("stage"), after.stage.wire)
            if (after.stage == AdmissionStage.ADMITTED) {
                assertEquals(expected.long("attempts").toInt(), after.attempts)
                assertEquals(expected.long("nextAttemptAtMs"), after.nextAttemptAtMs)
                assertEquals("downstream_unavailable", after.lastError)
                assertEquals(seeded.text, after.text)
                // Not dispatched again before the backoff has passed, and exactly at it.
                assertTrue(journal.dispatchable().isEmpty())
                val later = sandbox.journal(TestClock(after.nextAttemptAtMs!!))
                assertEquals(listOf(seeded.admissionId), later.dispatchable().map { it.admissionId })
            } else {
                assertEquals(expected.string("reason"), after.reason)
                assertEquals(attempts, after.attempts)
                assertNull(after.text)
                assertEquals(now, after.settledAtMs)
            }
            assertEquals(seeded.downstreamId, after.downstreamId)
        }
        assertEquals(setOf("admitted", "failed"), results)
    }

    // -------------------------------------------------------------------- sweep

    @Test
    fun `sweep - every vector at open and again on an explicit sweep`() {
        val actions = HashSet<String>()
        for (case in fixture.objects("sweep")) {
            val id = case.string("id")
            val now = case.long("now")
            val raw = case.child("record")
            val action = case.string("action")
            actions.add(action)
            assertSchemaValid(id, raw)
            val record = AdmissionCodec.decode(raw)
            assertEquals(id, action, AdmissionPolicy.sweep(record, now).name.lowercase())

            sandbox.reset()
            sandbox.seedRaw(record.admissionId, raw)
            val before = sandbox.snapshot()
            val journal = sandbox.journal(TestClock(now))
            val report = journal.openSweep
            val after = journal.record(record.admissionId)
            when (action) {
                "keep" -> {
                    assertEquals(id, AdmissionSweepReport(), report)
                    assertEquals(id, before, sandbox.snapshot())
                }
                "expire" -> {
                    assertEquals(id, listOf(record.admissionId), report.expired)
                    assertEquals(id, AdmissionStage.EXPIRED, after!!.stage)
                    assertEquals(id, now, after.settledAtMs)
                    assertEquals(id, "expired", after.reason)
                    assertNull(id, after.text)
                    assertSchemaValid(id, stored(record.admissionId))
                }
                "unknown" -> {
                    assertEquals(id, listOf(record.admissionId), report.unknown)
                    assertEquals(id, AdmissionStage.UNKNOWN, after!!.stage)
                    assertEquals(id, now, after.settledAtMs)
                    assertEquals(id, record.linkedAtMs, after.linkedAtMs)
                    assertSchemaValid(id, stored(record.admissionId))
                }
                "delete" -> {
                    assertEquals(id, listOf(record.admissionId), report.deleted)
                    assertNull(id, after)
                    assertFalse(id, sandbox.file(record.admissionId).exists())
                }
                else -> fail("unknown sweep action $action in $id")
            }
            // A second sweep at the same instant finds nothing more to do.
            val settled = sandbox.snapshot()
            assertEquals(id, AdmissionSweepReport(), journal.sweep())
            assertEquals(id, settled, sandbox.snapshot())
        }
        assertEquals(setOf("keep", "expire", "delete", "unknown"), actions)
    }

    // -------------------------------------------------------------------- order

    @Test
    fun `order - every vector through the policy and through real files and a real pass`() {
        val cases = fixture.objects("order")
        assertTrue(cases.isNotEmpty())
        var sawWaiting = false
        for (case in cases) {
            val id = case.string("id")
            val now = case.long("now")
            val partial = case.objects("records")
            val expected = case.array("dispatch").map { (it as JsonString).value }

            // 1. The pure function, with the vector's own ids.
            val asGiven = partial.map { item ->
                val stage = AdmissionStage.fromWire(item.string("stage"))!!
                AdmissionSpec.recordIn(
                    stage,
                    admittedAtMs = item.long("admittedAtMs"),
                    expiresAtMs = item.long("expiresAtMs"),
                    nextAttemptAtMs = (item["nextAttemptAtMs"] as? JsonNumber)?.asLongOrNull(),
                ).copy(admissionId = item.string("admissionId"))
            }
            val waitingIds = partial
                .filter { (it["waiting"] as? com.phonedsh.agentcore.JsonBool)?.value == true }
                .map { it.string("admissionId") }
                .toSet()
            assertEquals(
                id,
                expected,
                AdmissionPolicy.dispatchOrder(asGiven, now) { it.admissionId in waitingIds }.map { it.admissionId },
            )

            // 2. Real files. A real admissionId is a digest, so the vector's ids are
            // replaced by real ones in the same relative order: the i-th smallest
            // vector id becomes the i-th smallest real id, which keeps every tie-break.
            sandbox.reset()
            val realIds = partial.indices
                .map { AdmissionPolicy.admissionId("local", AdmissionSpec.VOICE, "$id-$it") to "$id-$it" }
                .sortedBy { it.first }
            val rank = partial.map { it.string("admissionId") }.sorted()
            val realIdOf = HashMap<String, String>()
            for (item in partial) {
                val (realId, requestId) = realIds[rank.indexOf(item.string("admissionId"))]
                realIdOf[item.string("admissionId")] = realId
                val next = (item["nextAttemptAtMs"] as? JsonNumber)?.asLongOrNull()
                val record = AdmissionSpec.recordIn(
                    AdmissionStage.fromWire(item.string("stage"))!!,
                    requestId = requestId,
                    admittedAtMs = item.long("admittedAtMs"),
                    expiresAtMs = item.long("expiresAtMs"),
                    attempts = if (next == null) 0 else 1,
                    nextAttemptAtMs = next,
                )
                assertEquals(realId, record.admissionId)
                sandbox.seed(record)
            }
            assertEquals(id, partial.size, rank.toSet().size)
            val journal = sandbox.journal(TestClock(now))
            val expectedReal = expected.map { realIdOf.getValue(it) }
            val waitingReal = waitingIds.map { realIdOf.getValue(it) }.toSet()
            assertEquals(id, expectedReal, journal.dispatchable { it.admissionId in waitingReal }.map { it.admissionId })
            val untouched = waitingReal.associateWith { sandbox.file(it).readText() }

            // 3. A real pass delivers exactly those, in that order, one at a time.
            val delivered = ArrayList<String>()
            val report = journal.runDispatchPass(object : AdmissionDispatcher {
                override fun precheck(record: AdmissionRecord): AdmissionPrecheck =
                    if (record.admissionId in waitingReal) AdmissionPrecheck.Wait else AdmissionPrecheck.Proceed

                override fun deliver(record: AdmissionRecord): AdmissionDelivery {
                    assertEquals(AdmissionStage.DISPATCHING, journal.record(record.admissionId)?.stage)
                    delivered.add(record.admissionId)
                    return AdmissionDelivery.Linked
                }
            })
            assertEquals(id, expectedReal, delivered)
            assertEquals(id, expectedReal, report.linked)
            assertTrue(id, delivered.size <= AdmissionPolicy.PASS_LIMIT)
            // A waiting record is skipped: not an attempt, nothing in its file changes.
            assertEquals(id, untouched, waitingReal.associateWith { sandbox.file(it).readText() })
            if (waitingReal.isNotEmpty()) sawWaiting = true
        }
        assertTrue("the v1.1 waiting vector must be present", sawWaiting)
    }
}
