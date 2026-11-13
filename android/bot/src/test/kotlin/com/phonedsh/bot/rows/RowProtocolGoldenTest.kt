// SPDX-License-Identifier: MIT
package com.phonedsh.bot.rows

import com.phonedsh.agentcore.JsonObject
import com.phonedsh.agentcore.JsonValue
import com.phonedsh.bot.GoldenFixture
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

/**
 * Drives the real `BotRow`/`BotRowBatch`/`BotUserAction`/`BotActionResult`
 * codecs with `row-protocol.json` plus its `row-protocol.phone.json` overlay
 * read from disk. No expected value is copied into Kotlin.
 */
class RowProtocolGoldenTest {
    @Test
    fun sharedRowAndBatchVectorsRoundTrip() {
        val fixture = GoldenFixture.mergedObject("row-protocol")
        val valid = GoldenFixture.objectValue(fixture, "valid")
        var rows = 0
        for (key in listOf("row", "widgetRow")) {
            val expected = GoldenFixture.objectValue(valid, key)
            val row = BotRow.fromJson(expected)
            assertEquals("$key round-trip", GoldenFixture.canonical(expected),
                GoldenFixture.canonical(row.toJson()))
            assertEquals("$key decode/encode/decode", row, BotRow.fromJson(row.toJson()))
            rows++
        }
        assertTrue("row-protocol must carry row vectors", rows > 0)

        val batchObject = GoldenFixture.objectValue(valid, "batch")
        val batch = BotRowBatch.fromJson(batchObject)
        assertEquals("batch round-trip", GoldenFixture.canonical(batchObject),
            GoldenFixture.canonical(batch.toJson()))
        assertEquals("batch decode/encode/decode", batch, BotRowBatch.fromJson(batch.toJson()))
    }

    @Test
    fun sharedActionResultVectorRoundTrips() {
        val fixture = GoldenFixture.mergedObject("row-protocol")
        val valid = GoldenFixture.objectValue(fixture, "valid")
        val expected = GoldenFixture.objectValue(valid, "result")
        val result = BotActionResult.fromJson(expected)
        assertEquals(GoldenFixture.canonical(expected), GoldenFixture.canonical(result.toJson()))
        assertEquals(result, BotActionResult.fromJson(result.toJson()))
    }

    @Test
    fun everyValidUserActionVectorRoundTripsThroughTheRealCodec() {
        val fixture = GoldenFixture.mergedObject("row-protocol")
        val valid = GoldenFixture.objectValue(fixture, "valid")
        val actionKeys = listOf("action", "cardAnswer", "chatWithAttachments", "chatAttachmentOnly")
        for (key in actionKeys) {
            val expected = GoldenFixture.objectValue(valid, key)
            val action = BotUserAction.fromJson(expected)
            assertEquals("$key round-trip", GoldenFixture.canonical(expected),
                GoldenFixture.canonical(action.toJson()))
            assertEquals("$key decode/encode/decode", action, BotUserAction.fromJson(action.toJson()))
        }
        // The phone overlay's two attachment cases must carry the merged array.
        val withAttachments = BotUserAction.fromJson(
            GoldenFixture.objectValue(valid, "chatWithAttachments"))
        assertEquals(2, withAttachments.attachments?.size)
        val attachmentOnly = BotUserAction.fromJson(
            GoldenFixture.objectValue(valid, "chatAttachmentOnly"))
        assertEquals("", attachmentOnly.text)
        assertEquals(1, attachmentOnly.attachments?.size)
    }

    @Test
    fun everyInvalidProtocolResultIsProducedByTheRealAdmissionRules() {
        val fixture = GoldenFixture.mergedObject("row-protocol")
        val invalid = GoldenFixture.objects(fixture, "invalid")
        assertTrue("row-protocol.invalid must not be empty", invalid.isNotEmpty())
        for ((index, vector) in invalid.withIndex()) {
            val expected = GoldenFixture.objectValue(vector, "result")
            val expectedResult = BotActionResult.fromJson(expected)
            val action = BotUserAction.fromJson(vector)
            val nonceEventID = if (expectedResult is BotActionResult.Duplicate) {
                expectedResult.eventID
            } else {
                null
            }
            val actual = BotUserActionValidation.resolve(action, nonceEventID)
            assertNotNull("invalid[$index] decoded but was not rejected", actual)
            assertEquals("invalid[$index] status", expectedResult.status, actual!!.status)
            if (expectedResult is BotActionResult.Stale) {
                assertEquals("invalid[$index] reason", expectedResult.reasonOrNull, actual.reasonOrNull)
            }
        }
    }

    @Test
    fun everyPhoneInvalidActionVectorIsRejectedAtTheDecoderOrValidator() {
        val fixture = GoldenFixture.mergedObject("row-protocol")
        val cases = GoldenFixture.objects(fixture, "invalidActions")
        assertTrue("row-protocol.invalidActions must not be empty", cases.isNotEmpty())
        for ((index, vector) in cases.withIndex()) {
            val reason = GoldenFixture.requireString(vector, "reason")
            val actionValue = GoldenFixture.at(vector, "action")
                ?: throw AssertionError("invalidActions[$index] has no action")
            val expectedDecoderMessage = when (reason) {
                "card_answer_text_forbidden" -> "must not contain text"
                "card_answer_custom_text_forbidden" -> "must not contain customText"
                "attachments_only_for_chat" -> "only chat actions may carry attachments"
                else -> null
            }
            val decoded = try {
                BotUserAction.fromJson(actionValue)
            } catch (error: Exception) {
                if (expectedDecoderMessage == null) {
                    throw AssertionError("invalidActions[$index] must decode so the validator rejects it")
                }
                assertTrue("invalidActions[$index] ($reason) wrong decoder error: ${error.message}",
                    error.message.orEmpty().contains(expectedDecoderMessage))
                continue
            }
            val result = BotUserActionValidation.validate(decoded)
            assertNotNull("invalidActions[$index] ($reason) decoded but was not rejected", result)
            assertTrue("invalidActions[$index] ($reason) must be rejected, got $result",
                result is BotActionResult.Rejected)
            assertEquals("invalidActions[$index] reason class", "attachments_exceed_max_count", reason)
        }
    }

    @Test
    fun everyDisplayProjectionVectorUsesTheRealProjector() {
        val fixture = GoldenFixture.mergedObject("row-projection")
        val valid = GoldenFixture.objects(fixture, "valid")
        assertTrue("row-projection.valid must not be empty", valid.isNotEmpty())
        for ((index, vector) in valid.withIndex()) {
            val input = (GoldenFixture.at(vector, "input") as? JsonObject)?.members
                ?: throw AssertionError("valid[$index].input is not an object")
            val actual = BotDisplayContract.project(input, BotDisplayProfile.UPSTREAM_REFERENCE)
            assertEquals("valid[$index] surface", GoldenFixture.string(vector, "surface"), actual.surface)
            assertEquals("valid[$index] renderable", GoldenFixture.bool(vector, "renderable"),
                actual.renderable)
            assertEquals("valid[$index] wire.kind", GoldenFixture.string(vector, "wire", "kind"),
                actual.wire.kind)
            assertEquals("valid[$index] wire.type", GoldenFixture.string(vector, "wire", "type"),
                actual.wire.type)
            assertEquals("valid[$index] wire.role", GoldenFixture.string(vector, "wire", "role"),
                actual.wire.role)
        }

        val invalid = GoldenFixture.objects(fixture, "invalid")
        assertTrue("row-projection.invalid must not be empty", invalid.isNotEmpty())
        for ((index, vector) in invalid.withIndex()) {
            val input = (GoldenFixture.at(vector, "input") as? JsonObject)?.members
                ?: throw AssertionError("invalid[$index].input is not an object")
            val actual = BotDisplayContract.project(input, BotDisplayProfile.UPSTREAM_REFERENCE)
            assertEquals("invalid[$index] surface", GoldenFixture.string(vector, "surface"), actual.surface)
            assertEquals("invalid[$index] renderable", GoldenFixture.bool(vector, "renderable"),
                actual.renderable)
        }
    }

    @Test
    fun phoneAttachmentProjectionVectorUsesTheRealProjector() {
        val fixture = GoldenFixture.mergedObject("row-protocol")
        val projections = GoldenFixture.objects(fixture, "projection")
        assertTrue("row-protocol.projection must not be empty", projections.isNotEmpty())
        for ((index, vector) in projections.withIndex()) {
            val input = (GoldenFixture.at(vector, "input") as? JsonObject)?.members
                ?: throw AssertionError("projection[$index].input is not an object")
            assertNotNull("projection[$index] must carry attachments", input["attachments"])
            val actual = BotDisplayContract.project(input, BotDisplayProfile.UPSTREAM_REFERENCE)
            assertEquals("projection[$index] surface", GoldenFixture.string(vector, "surface"),
                actual.surface)
            assertEquals("projection[$index] renderable", GoldenFixture.bool(vector, "renderable"),
                actual.renderable)
            assertEquals("projection[$index] wire.kind", GoldenFixture.string(vector, "wire", "kind"),
                actual.wire.kind)
            assertEquals("projection[$index] wire.type", GoldenFixture.string(vector, "wire", "type"),
                actual.wire.type)
            assertEquals("projection[$index] wire.role", GoldenFixture.string(vector, "wire", "role"),
                actual.wire.role)
        }
    }

    @Test
    fun p1CardsStayProtocolVisibleButNotPhoneRenderable() {
        val fixture = GoldenFixture.mergedObject("row-projection")
        for (vector in GoldenFixture.objects(fixture, "valid")) {
            val input = (GoldenFixture.at(vector, "input") as? JsonObject)?.members ?: continue
            val cardType = (input["cardType"] as? com.phonedsh.agentcore.JsonString)?.value ?: continue
            val p1 = BotWidgetCardType.P1_CARD_TYPES.firstOrNull { it.wire == cardType } ?: continue
            assertTrue("$cardType must be upstream-renderable",
                BotDisplayContract.project(input, BotDisplayProfile.UPSTREAM_REFERENCE).renderable)
            val phone = BotDisplayContract.project(input, BotDisplayProfile.PHONE_P0)
            assertTrue("$p1 must not be phone-renderable", !phone.renderable)
            assertEquals(BotDisplayContract.HIDDEN, phone.surface)
        }
    }
}
