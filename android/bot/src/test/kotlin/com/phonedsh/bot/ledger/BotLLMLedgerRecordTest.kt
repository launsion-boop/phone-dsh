// SPDX-License-Identifier: MIT
package com.phonedsh.bot.ledger

import com.phonedsh.agentcore.JsonNull
import com.phonedsh.agentcore.JsonNumber
import com.phonedsh.agentcore.JsonObject
import com.phonedsh.agentcore.JsonString
import com.phonedsh.agentcore.JsonValue
import com.phonedsh.bot.BotJson
import com.phonedsh.bot.GoldenFixture
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

/**
 * Drives `llm-ledger.json` and `llm-ledger.phone.json` through the real Kotlin
 * record codec. Each file is read on its own: the phone file is a delta vector,
 * not an overlay of the upstream object.
 */
class BotLLMLedgerRecordTest {
    @Test
    fun upstreamGoldenRoundTripsAndExercisesBothInvalidRules() {
        val fixture = GoldenFixture.rawObject("llm-ledger")
        val valid = GoldenFixture.objectValue(fixture, "valid")
        val record = BotLLMLedgerRecord.fromJson(valid)

        assertEquals("front-turn", record.purpose.wire)
        assertEquals(100L, record.inputTokens)
        assertEquals(20L, record.outputTokens)
        assertEquals(40L, record.cacheReadTokens)
        assertEquals(10L, record.cacheWriteTokens)
        assertEquals(40.0 / 150.0, record.cacheHitRatio, 0.0)
        assertEquals(125L, record.ttftMs)
        assertEquals(900L, record.durationMs)
        assertEquals("ok", record.status)
        assertNull(record.errorKind)

        val encoded = record.toJson()
        assertEquals("all 14 required members plus ttftMs", 15, encoded.members.size)
        assertEquals(
            setOf(
                "ts", "botId", "sessionId", "purpose", "model", "provider",
                "inputTokens", "outputTokens", "cacheReadTokens", "cacheWriteTokens",
                "cacheHitRatio", "ttftMs", "durationMs", "status", "errorKind",
            ),
            encoded.members.keys,
        )
        assertEquals(BotJson.canonical(valid), BotJson.canonical(encoded))

        // ttftMs is optional, but an explicit null is not the same as omission.
        val withoutTtft = valid.without("ttftMs").with("durationMs", JsonNull)
        val noTiming = BotLLMLedgerRecord.fromJson(withoutTtft)
        assertNull(noTiming.ttftMs)
        assertNull(noTiming.durationMs)
        val noTimingEncoded = noTiming.toJson()
        assertFalse(noTimingEncoded.members.containsKey("ttftMs"))
        assertEquals(JsonNull, noTimingEncoded.members["durationMs"])
        assertEquals(BotJson.canonical(withoutTtft), BotJson.canonical(noTimingEncoded))
        assertField("ttftMs") {
            BotLLMLedgerRecord.fromJson(valid.with("ttftMs", JsonNull))
        }

        val invalid = GoldenFixture.objects(fixture, "invalid")
        assertTrue("llm-ledger.invalid must not be empty", invalid.isNotEmpty())
        for (case in invalid) {
            val field = GoldenFixture.requireString(case, "field")
            val rule = GoldenFixture.requireString(case, "rule")
            when (field) {
                "cacheHitRatio" -> {
                    assertEquals("cacheRead/(input+cacheRead+cacheWrite)", rule)
                    assertField("cacheHitRatio") {
                        BotLLMLedgerRecord.fromJson(
                            valid.with("cacheHitRatio", JsonNumber("0.5")),
                        )
                    }
                }
                "ttftMs" -> {
                    assertEquals("omit_when_unavailable", rule)
                    assertField("ttftMs") {
                        BotLLMLedgerRecord.fromJson(valid.with("ttftMs", JsonNumber("-1")))
                    }
                }
                else -> fail("unhandled llm-ledger invalid rule for $field")
            }
        }
        println("llm-ledger: valid=1 invalid=${invalid.size}")
    }

    @Test
    fun phoneGoldenCarriesTheAdditiveMaintenancePurpose() {
        val fixture = GoldenFixture.rawObject("llm-ledger.phone")
        val valid = GoldenFixture.objectValue(fixture, "valid")
        val record = BotLLMLedgerRecord.fromJson(valid)

        assertEquals(BotModelPurpose.MEMORY_MAINTENANCE, record.purpose)
        assertEquals("memory-maintenance", record.purpose.wire)
        assertEquals(2_000L, record.cacheReadTokens)
        assertEquals(0L, record.cacheWriteTokens)
        assertEquals(0.2, record.cacheHitRatio, 0.0)
        assertEquals(BotJson.canonical(valid), BotJson.canonical(record.toJson()))
        assertEquals(
            BotModelPurposeDefaults(
                model = BotModelPurposePolicy.SMALL_MODEL,
                maxTokens = 4_096,
                temperature = 0.0,
            ),
            BotModelPurposePolicy.defaults(record.purpose),
        )

        val invalid = GoldenFixture.objects(fixture, "invalid")
        assertTrue("llm-ledger.phone.invalid must not be empty", invalid.isNotEmpty())
        for (case in invalid) {
            val field = GoldenFixture.requireString(case, "field")
            val rule = GoldenFixture.requireString(case, "rule")
            assertEquals("cacheHitRatio", field)
            assertEquals("cacheRead/(input+cacheRead+cacheWrite)", rule)
            assertField("cacheHitRatio") {
                BotLLMLedgerRecord.fromJson(
                    valid.with("cacheHitRatio", JsonNumber("0.1")),
                )
            }
        }
        println("llm-ledger.phone: valid=1 invalid=${invalid.size}")
    }

    @Test
    fun everySchemaMinimumAndRequiredPathFailsClosed() {
        val valid = GoldenFixture.objectValue(GoldenFixture.rawObject("llm-ledger"), "valid")
        val required = listOf(
            "ts", "botId", "sessionId", "purpose", "model", "provider",
            "inputTokens", "outputTokens", "cacheReadTokens", "cacheWriteTokens",
            "cacheHitRatio", "durationMs", "status", "errorKind",
        )
        assertEquals(14, required.size)
        for (key in required) {
            assertField(key) { BotLLMLedgerRecord.fromJson(valid.without(key)) }
        }

        for (key in listOf(
            "inputTokens", "outputTokens", "cacheReadTokens", "cacheWriteTokens",
        )) {
            assertField(key) {
                BotLLMLedgerRecord.fromJson(valid.with(key, JsonNumber("-1")))
            }
        }
        assertField("durationMs") {
            BotLLMLedgerRecord.fromJson(valid.with("durationMs", JsonNumber("-1")))
        }
        assertField("status") {
            BotLLMLedgerRecord.fromJson(valid.with("status", JsonString("")))
        }
        assertField("ts") {
            BotLLMLedgerRecord.fromJson(valid.with("ts", JsonString("2025-10-09T08:53:2Z")))
        }
        assertField("purpose") {
            BotLLMLedgerRecord.fromJson(valid.with("purpose", JsonString("bogus")))
        }
        assertField("cacheHitRatio") {
            BotLLMLedgerRecord.fromJson(valid.with("cacheHitRatio", JsonNumber("1.5")))
        }
        assertField("ts") {
            BotLLMLedgerRecord.fromJson(valid.with("ts", JsonNumber("1760000000000")))
        }
        assertField("botId") {
            BotLLMLedgerRecord.fromJson(valid.with("botId", JsonNumber("1")))
        }
        assertField("inputTokens") {
            BotLLMLedgerRecord.fromJson(valid.with("inputTokens", JsonNumber("1.5")))
        }
        assertField("costUsd") {
            BotLLMLedgerRecord.fromJson(valid.with("costUsd", JsonNumber("1")))
        }

        // The direct constructor also applies the formula and validation.
        val constructed = BotLLMLedgerRecord(
            ts = "2025-10-09T08:53:20.000Z",
            botId = "main",
            sessionId = "gb-main",
            purpose = BotModelPurpose.FRONT_TURN,
            model = "deepseek-flash",
            provider = "deepseek",
            inputTokens = 100,
            outputTokens = 20,
            cacheReadTokens = 40,
            cacheWriteTokens = 10,
            durationMs = null,
        )
        constructed.validate()
        assertEquals(40.0 / 150.0, constructed.cacheHitRatio, 0.0)
    }

    @Test
    fun timestampsUseUtcMillisecondsAndTheEventTimeIsTheSameInstant() {
        val ts = "2025-10-09T08:53:20.000Z"
        assertEquals(1_760_000_000_000L, BotLLMLedgerRecord.eventTimeMillis(ts))
        assertEquals(ts, BotLLMLedgerRecord.timestamp(1_760_000_000_000L))
        assertEquals(
            BotLLMLedgerRecord.eventTimeMillis(ts),
            BotLLMLedgerRecord.eventTimeMillis("2025-10-09T10:53:20+02:00"),
        )
        assertNull(BotLLMLedgerRecord.eventTimeMillis("not-an-iso-8601-instant"))
    }

    private fun assertField(expected: String, block: () -> Unit): BotLLMLedgerException {
        val error = try {
            block()
            null
        } catch (failure: BotLLMLedgerException) {
            failure
        }
        if (error == null) fail("expected BotLLMLedgerException for $expected")
        assertEquals("error field", expected, error!!.field)
        return error
    }
}

private fun JsonObject.with(key: String, value: JsonValue): JsonObject {
    val members = LinkedHashMap(this.members)
    members[key] = value
    return JsonObject(members)
}

private fun JsonObject.without(key: String): JsonObject {
    val members = LinkedHashMap(this.members)
    members.remove(key)
    return JsonObject(members)
}
