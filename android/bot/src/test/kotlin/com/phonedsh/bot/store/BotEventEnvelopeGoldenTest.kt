// SPDX-License-Identifier: MIT
package com.phonedsh.bot.store

import com.phonedsh.agentcore.JsonArray
import com.phonedsh.agentcore.JsonObject
import com.phonedsh.bot.GoldenFixture
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Drives the merged `event-envelope.json` + `event-envelope.phone.json`
 * vectors through the real Kotlin envelope codec. The upstream `valid` object
 * and the overlay's four case arrays all run; the overlay is merged by
 * [GoldenFixture] exactly as the shared loader does.
 */
class BotEventEnvelopeGoldenTest {
    @Test
    fun everyMergedEnvelopeVectorUsesTheRealCodec() {
        val fixture = GoldenFixture.mergedObject("event-envelope")
        var valid = 0
        var invalid = 0

        val upstreamValid = GoldenFixture.at(fixture, "valid", "event")
            ?: throw AssertionError("event-envelope.valid.event missing")
        val upstreamValidation = GoldenFixture.at(fixture, "valid", "validation")
        val expectedValid = GoldenFixture.bool(upstreamValidation, "valid") ?: true
        val event = BotEvent.fromJson(upstreamValid)
        if (expectedValid) {
            BotEventCodec.validate(event, BotEventCodec.Mode.STORED)
            val reencoded = BotEventCodec.encodeCanonical(event.toJson())
            assertEquals(
                "event-envelope valid round-trip",
                event,
                BotEventCodec.decode(reencoded, BotEventCodec.Mode.STORED),
            )
            valid += 1
        } else {
            invalid += 1
        }

        for (vector in GoldenFixture.objects(fixture, "validCases")) {
            val vectorEvent = BotEvent.fromJson(
                GoldenFixture.at(vector, "event")
                    ?: throw AssertionError("validCases event missing"),
            )
            BotEventCodec.validate(vectorEvent, BotEventCodec.Mode.STORED)
            val data = BotEventCodec.encodeData(vectorEvent.data)
            assertEquals(
                "validCases payload round-trip",
                vectorEvent.data,
                BotEventCodec.decodeData(data),
            )
            valid += 1
        }
        for (vector in GoldenFixture.objects(fixture, "ephemeralValidCases")) {
            val vectorEvent = BotEvent.fromJson(
                GoldenFixture.at(vector, "event")
                    ?: throw AssertionError("ephemeralValidCases event missing"),
            )
            BotEventCodec.validate(vectorEvent, BotEventCodec.Mode.STORED)
            valid += 1
        }

        for (vector in GoldenFixture.objects(fixture, "invalid")) {
            assertEnvelopeError(vector as? JsonObject ?: throw AssertionError("invalid vector is not an object"), BotEventCodec.Mode.STORED)
            invalid += 1
        }
        for (vector in GoldenFixture.objects(fixture, "invalidCases")) {
            assertEnvelopeError(vector as? JsonObject ?: throw AssertionError("invalid vector is not an object"), BotEventCodec.Mode.STORED)
            invalid += 1
        }
        for (vector in GoldenFixture.objects(fixture, "ephemeralInvalidCases")) {
            assertEnvelopeError(vector as? JsonObject ?: throw AssertionError("invalid vector is not an object"), BotEventCodec.Mode.STORED)
            invalid += 1
        }

        println("event-envelope: valid=$valid invalid=$invalid")
        assertTrue("event-envelope must carry valid cases", valid > 0)
        assertTrue("event-envelope must carry invalid cases", invalid > 0)
    }

    private fun assertEnvelopeError(vector: JsonObject, mode: BotEventCodec.Mode) {
        val validation = GoldenFixture.at(vector, "validation")
        val expected = GoldenFixture.objects(validation, "errors").firstOrNull()
            ?: throw AssertionError("invalid vector has no expected error")
        val code = GoldenFixture.requireString(expected, "code")
        val vectorEvent = BotEvent.fromJson(
            GoldenFixture.at(vector, "event") ?: throw AssertionError("invalid vector has no event"),
        )
        val actual = try {
            BotEventCodec.validate(vectorEvent, mode)
            null
        } catch (error: BotStoreException) {
            error.code
        }
        assertEquals("invalid envelope ${GoldenFixture.string(vector, "name")}", code, actual)
    }
}
