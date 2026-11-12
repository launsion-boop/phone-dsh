// SPDX-License-Identifier: MIT
package com.phonedsh.bot.projection

import com.phonedsh.agentcore.JsonArray
import com.phonedsh.agentcore.JsonBool
import com.phonedsh.agentcore.JsonNull
import com.phonedsh.agentcore.JsonNumber
import com.phonedsh.agentcore.JsonObject
import com.phonedsh.agentcore.JsonString
import com.phonedsh.agentcore.JsonValue
import com.phonedsh.bot.GoldenFixture
import com.phonedsh.bot.rows.BotDisplayContract
import com.phonedsh.bot.rows.BotRow
import com.phonedsh.bot.rows.BotRowBatch
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Drives the real JSONL decoder, row projector, history and streaming limiter
 * with `spec/bot/v1/golden/projection.phone.json`, read from disk. No expected
 * value is copied into Kotlin.
 */
class BotProjectionGoldenTest {
    private val fixture: JsonObject by lazy { GoldenFixture.rawObject("projection.phone") }

    private fun objectList(value: JsonValue?, vararg path: String): List<JsonObject> =
        GoldenFixture.objects(value, *path).map { it as JsonObject }

    @Test
    fun everyDshMappingVectorProjectsThroughTheRealProjector() {
        val cases = objectList(fixture, "valid", "dshMapping")
        assertTrue("projection.valid.dshMapping must not be empty", cases.isNotEmpty())
        for (vector in cases) {
            val label = GoldenFixture.requireString(vector, "name")
            val projected = project(vector)
            assertSnapshot(projected, GoldenFixture.objectValue(vector, "expected"), label)
        }
        println("projection.dshMapping: ${cases.size} cases")
    }

    @Test
    fun everyUiMappingVectorProjectsThroughTheRealProjector() {
        val cases = objectList(fixture, "valid", "uiMapping")
        assertTrue("projection.valid.uiMapping must not be empty", cases.isNotEmpty())
        for (vector in cases) {
            val label = GoldenFixture.requireString(vector, "name")
            val projected = project(vector)
            assertSnapshot(projected, GoldenFixture.objectValue(vector, "expected"), label)
        }
        println("projection.uiMapping: ${cases.size} cases")
    }

    @Test
    fun everyInvalidRecordProducesTheFrozenDiagnostics() {
        val cases = objectList(fixture, "invalid")
        assertTrue("projection.invalid must not be empty", cases.isNotEmpty())
        for (vector in cases) {
            val label = GoldenFixture.requireString(vector, "name")
            val parsed = BotSessionLogParser.parseJsonl(recordsText(vector))
            val expected = GoldenFixture.objectValue(vector, "expected")
            val expectedSeqs = GoldenFixture.objects(expected, "eventSeqs").map {
                (it as JsonNumber).asLongOrNull() ?: error("$label: eventSeq must be an integer")
            }
            assertEquals("$label: event seqs", expectedSeqs, parsed.records.map { it.seq })
            val expectedSkipped = objectList(expected, "skipped")
            assertEquals("$label: skipped count", expectedSkipped.size, parsed.skipped.size)
            for ((index, skip) in expectedSkipped.withIndex()) {
                val actual = parsed.skipped[index]
                assertEquals("$label: skipped[$index].lineNumber",
                    GoldenFixture.requireLong(skip, "lineNumber"), actual.lineNumber.toLong())
                val expectedSeq = GoldenFixture.at(skip, "seq")
                if (expectedSeq is JsonNull) {
                    assertNull("$label: skipped[$index].seq", actual.seq)
                } else {
                    assertEquals("$label: skipped[$index].seq",
                        GoldenFixture.requireLong(skip, "seq"), actual.seq)
                }
            }
        }
        println("projection.invalid: ${cases.size} cases")
    }

    @Test
    fun everyHistoryStepMatchesTheFrozenBatches() {
        val cases = objectList(fixture, "valid", "history")
        assertTrue("projection.valid.history must not be empty", cases.isNotEmpty())
        var steps = 0
        for (vector in cases) {
            val label = GoldenFixture.requireString(vector, "name")
            val history = BotRowHistory()
            for ((index, step) in objectList(vector, "steps").withIndex()) {
                val where = "$label[$index]"
                val rebuild = GoldenFixture.at(step, "rebuild") as? JsonObject
                if (rebuild != null) {
                    val batch = history.rebuild(
                        botID = "main",
                        sessionID = GoldenFixture.string(rebuild, "sessionID") ?: "gb-main",
                        sessionEvents = parse(recordsText(rebuild)).records,
                        uiEvents = events(GoldenFixture.at(rebuild, "uiEvents")),
                    )
                    assertBatch(batch, GoldenFixture.objectValue(step, "expectBatch"), where)
                    steps++
                } else if (GoldenFixture.at(step, "watchAfter") != null) {
                    val cursor = GoldenFixture.requireLong(step, "watchAfter")
                    assertBatch(history.watch(cursor), GoldenFixture.objectValue(step, "expectBatch"), where)
                    steps++
                } else {
                    throw AssertionError("$where: unknown history step")
                }
            }
        }
        println("projection.history: ${cases.size} cases / $steps steps")
    }

    @Test
    fun everyStreamingStepMatchesTheFrozenLimiterState() {
        val cases = objectList(fixture, "valid", "streaming")
        assertTrue("projection.valid.streaming must not be empty", cases.isNotEmpty())
        var steps = 0
        for (vector in cases) {
            val label = GoldenFixture.requireString(vector, "name")
            val limiter = BotStreamingRowLimiter()
            for ((index, step) in objectList(vector, "steps").withIndex()) {
                val where = "$label[$index]"
                val submit = GoldenFixture.at(step, "submit") as? JsonObject
                if (submit != null) {
                    val now = double(submit, "now")
                    val emitted = limiter.submit(row(GoldenFixture.at(submit, "row")), now)
                    val expectedEmitted = GoldenFixture.at(step, "expectEmitted")
                    if (expectedEmitted is JsonNull) {
                        assertNull("$where: expected no emission", emitted)
                    } else {
                        assertEquals("$where: emitted", canonicalRow(row(expectedEmitted)),
                            canonicalRow(emitted))
                    }
                    if (GoldenFixture.at(step, "expectFlush") != null) {
                        assertEquals("$where: inline flush",
                            rows(GoldenFixture.at(step, "expectFlush")).map(::canonicalRow),
                            limiter.flush(now).map(::canonicalRow))
                    }
                    steps++
                } else if (GoldenFixture.at(step, "flush") != null) {
                    val flush = GoldenFixture.objectValue(step, "flush")
                    assertEquals("$where: flush",
                        rows(GoldenFixture.at(step, "expectRows")).map(::canonicalRow),
                        limiter.flush(double(flush, "now")).map(::canonicalRow))
                    steps++
                } else {
                    val state = GoldenFixture.objectValue(step, "state")
                    GoldenFixture.long(state, "pendingCount")?.let {
                        assertEquals("$where: pendingCount", it.toInt(), limiter.pendingCount())
                    }
                    GoldenFixture.long(state, "rowCount")?.let {
                        assertEquals("$where: rowCount", it.toInt(), limiter.rows().size)
                    }
                    val next = GoldenFixture.at(state, "nextFlushAt")
                    if (next is JsonNull) {
                        assertNull("$where: nextFlushAt", limiter.nextFlushAt())
                    } else if (next is JsonNumber) {
                        assertEquals("$where: nextFlushAt", next.raw.toDouble(), limiter.nextFlushAt()!!, 1e-9)
                    }
                    steps++
                }
            }
        }
        println("projection.streaming: ${cases.size} cases / $steps steps")
    }

    // MARK: - Projection

    private fun project(vector: JsonObject): BotRowProjectionSnapshot {
        val epochs = objectList(vector, "epochs")
        if (epochs.isNotEmpty()) {
            val parsed = epochs.map { epoch ->
                val sessionID = GoldenFixture.requireString(epoch, "sessionID")
                val result = parse(recordsText(epoch))
                assertEquals("$sessionID must not skip records", 0, result.skipped.size)
                BotSessionEpochProjection(sessionID, result.records)
            }
            return BotSessionLogProjector().project(
                botID = "main",
                epochs = parsed,
                uiEvents = events(GoldenFixture.at(vector, "uiEvents")),
                heldRequestNonces = stringMap(GoldenFixture.at(vector, "heldRequestNonces")),
            )
        }
        val sessionID = GoldenFixture.string(vector, "sessionID") ?: "gb-main"
        val result = parse(recordsText(vector))
        assertEquals("${GoldenFixture.string(vector, "name")}: skipped records",
            0, result.skipped.size)
        return BotSessionLogProjector().project(
            botID = "main",
            sessionID = sessionID,
            sessionEvents = result.records,
            uiEvents = events(GoldenFixture.at(vector, "uiEvents")),
            heldRequestNonces = stringMap(GoldenFixture.at(vector, "heldRequestNonces")),
        )
    }

    private fun assertSnapshot(
        actual: BotRowProjectionSnapshot,
        expected: JsonObject,
        label: String,
    ) {
        assertEquals("$label: cursor", GoldenFixture.requireLong(expected, "cursor"), actual.cursor)
        assertEquals("$label: rows", rows(GoldenFixture.at(expected, "rows")).map(::canonicalRow),
            actual.rows.map(::canonicalRow))
        assertEquals("$label: tombstones",
            rows(GoldenFixture.at(expected, "tombstones")).map(::canonicalRow),
            actual.tombstones.map(::canonicalRow))

        val expectedNonces = GoldenFixture.at(expected, "chatActionNonces") as? JsonObject
        if (expectedNonces != null) {
            val actualNonces = LinkedHashMap<String, String>()
            for (row in actual.rows) row.chatActionNonce?.let { actualNonces[row.id] = it }
            assertEquals("$label: chatActionNonces",
                expectedNonces.members.mapValues { (it.value as JsonString).value }, actualNonces)
        }

        val displays = GoldenFixture.at(expected, "display") as? JsonObject
        if (displays != null) {
            assertEquals("$label: display covers the live rows",
                displays.members.keys, actual.rows.map { it.id }.toSet())
            for (row in actual.rows) {
                val expectedDisplay = (displays.members[row.id] as? JsonObject)
                    ?: throw AssertionError("$label: missing display for ${row.id}")
                val projection = BotDisplayContract.project(row)
                assertEquals("$label: ${row.id} surface",
                    GoldenFixture.requireString(expectedDisplay, "surface"), projection.surface)
                assertEquals("$label: ${row.id} renderable",
                    GoldenFixture.requireBool(expectedDisplay, "renderable"), projection.renderable)
                assertEquals("$label: ${row.id} wire.kind",
                    GoldenFixture.requireString(expectedDisplay, "wire", "kind"), projection.wire.kind)
                assertEquals("$label: ${row.id} wire.type",
                    GoldenFixture.requireString(expectedDisplay, "wire", "type"), projection.wire.type)
            }
        }
    }

    private fun assertBatch(actual: BotRowBatch, expected: JsonObject, label: String) {
        assertEquals("$label: cursor", GoldenFixture.requireLong(expected, "cursor"), actual.cursor)
        assertEquals("$label: deletes",
            GoldenFixture.objects(expected, "deletes").map { (it as JsonString).value }, actual.deletes)
        assertEquals("$label: reset", GoldenFixture.requireBool(expected, "reset"), actual.reset)
        assertEquals("$label: rows", rows(GoldenFixture.at(expected, "rows")).map(::canonicalRow),
            actual.rows.map(::canonicalRow))
    }

    // MARK: - Decoding helpers

    private fun parse(text: String): BotSessionLogParseResult =
        BotSessionLogParser.parseJsonl(text)

    private fun recordsText(value: JsonObject): String {
        val records = GoldenFixture.objects(value, "records").map { (it as JsonString).value }
        return records.joinToString("\n")
    }

    private fun events(value: JsonValue?): List<BotProjectionEvent> =
        (value as? JsonArray)?.values?.map { BotProjectionEvent.fromJson(it) } ?: emptyList()

    private fun row(value: JsonValue?): BotRow {
        assertNotNull("expected row value", value)
        return BotRow.fromJson(value!!)
    }

    private fun rows(value: JsonValue?): List<BotRow> =
        (value as? JsonArray)?.values?.map { BotRow.fromJson(it) } ?: emptyList()

    private fun canonicalRow(row: BotRow?): String {
        assertNotNull("row must exist", row)
        return GoldenFixture.canonical(row!!.toJson())
    }

    private fun double(value: JsonObject, key: String): Double {
        val number = GoldenFixture.at(value, key) as? JsonNumber
            ?: throw AssertionError("missing number at $key")
        return number.raw.toDouble()
    }

    private fun stringMap(value: JsonValue?): Map<String, String> {
        val members = (value as? JsonObject)?.members ?: return emptyMap()
        return members.mapValues { (it.value as JsonString).value }
    }
}
