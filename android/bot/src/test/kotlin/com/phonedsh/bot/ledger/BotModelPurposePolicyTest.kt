// SPDX-License-Identifier: MIT
package com.phonedsh.bot.ledger

import com.phonedsh.agentcore.JsonArray
import com.phonedsh.agentcore.JsonNumber
import com.phonedsh.agentcore.JsonObject
import com.phonedsh.agentcore.JsonString
import com.phonedsh.agentcore.JsonValue
import com.phonedsh.bot.BotJson
import com.phonedsh.bot.GoldenFixture
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

/**
 * Drives `model-purpose-policy.json` through the real policy codec and checks
 * the code-only tier/error rules against the Swift reference. The shared
 * golden still has eight rows; `frozen` adds the phone-only
 * `memory-maintenance` row required by `llm-ledger.phone.json`.
 */
class BotModelPurposePolicyTest {
    @Test
    fun goldenRowsMatchTheFrozenPolicyAndEveryDefault() {
        val fixture = GoldenFixture.rawObject("model-purpose-policy")
        val valid = GoldenFixture.objectValue(fixture, "valid")
        val golden = BotModelPurposePolicy.fromJson(valid)

        assertEquals(8, golden.purposes.size)
        assertEquals(
            listOf(BotModelPurpose.FRONT_TURN, BotModelPurpose.WORKER_TURN),
            golden.largeModelPurposes,
        )
        assertEquals(BotJson.canonical(valid), BotJson.canonical(golden.toJson()))

        val frozen = BotModelPurposePolicy.frozen
        assertEquals(BotModelPurpose.entries.size, frozen.purposes.size)
        assertEquals(9, frozen.purposes.size)
        assertEquals(
            listOf(BotModelPurpose.FRONT_TURN, BotModelPurpose.WORKER_TURN),
            frozen.largeModelPurposes,
        )
        for (row in golden.purposes) {
            assertEquals(
                "frozen row for ${row.purpose.wire}",
                row,
                frozen.purposes.firstOrNull { it.purpose == row.purpose },
            )
        }
        val maintenance = frozen.purposes.first { it.purpose == BotModelPurpose.MEMORY_MAINTENANCE }
        assertEquals(
            BotModelPurposeDefaults(
                model = BotModelPurposePolicy.SMALL_MODEL,
                maxTokens = 4_096,
                temperature = 0.0,
            ),
            maintenance.defaults,
        )

        for (purpose in BotModelPurpose.entries) {
            assertEquals(
                "largeModelAllowed ${purpose.wire}",
                purpose.largeModelAllowed,
                BotModelPurposePolicy.allowsLargeModel(purpose),
            )
            assertEquals(
                "frozen defaults ${purpose.wire}",
                BotModelPurposePolicy.defaults(purpose),
                frozen.purposes.first { it.purpose == purpose }.defaults,
            )
            if (purpose.largeModelAllowed) {
                assertEquals(
                    " deepseek-v4-pro ",
                    "deepseek-v4-pro",
                    BotModelPurposePolicy.assertModelAllowed(purpose, " deepseek-v4-pro "),
                )
                // Large purposes are not restricted to the allowlist; only the
                // non-large gate requires a known small model.
                assertEquals(
                    "vendor-unknown",
                    BotModelPurposePolicy.assertModelAllowed(purpose, "vendor-unknown"),
                )
            } else {
                assertEquals(
                    "deepseek-flash",
                    BotModelPurposePolicy.assertModelAllowed(purpose, " deepseek-flash "),
                )
                for (model in listOf(
                    "deepseek-v4-pro", "deepseek-chat", "vendor/opus-latest", "unknown-model",
                )) {
                    val error = assertPolicyFailure(purpose, model)
                    assertEquals("EPURPOSE_MODEL_DENIED", error.code)
                    assertEquals(purpose, error.purpose)
                    assertEquals(model, error.model)
                }
            }
        }
        println("model-purpose-policy: valid=1 rows=${golden.purposes.size} frozen=${frozen.purposes.size}")
    }

    @Test
    fun invalidVectorFailsClosedAndEmptyModelNeedsTheRequiredCode() {
        val fixture = GoldenFixture.rawObject("model-purpose-policy")
        val invalid = GoldenFixture.objects(fixture, "invalid")
        assertTrue("model-purpose-policy.invalid must not be empty", invalid.isNotEmpty())
        for (case in invalid) {
            val purposeText = GoldenFixture.requireString(case, "purpose")
            val model = GoldenFixture.requireString(case, "model")
            val code = GoldenFixture.requireString(case, "code")
            val purpose = BotModelPurpose.parse(purposeText)
                ?: throw AssertionError("invalid vector has unknown purpose $purposeText")
            val error = assertPolicyFailure(purpose, model)
            assertEquals(code, error.code)
            assertEquals(purpose, error.purpose)
            assertEquals(model, error.model)
        }
        val required = assertPolicyFailure(BotModelPurpose.FRONT_TURN, " ")
        assertEquals("EPURPOSE_MODEL_REQUIRED", required.code)
        assertEquals(" ", required.model)
        println("model-purpose-policy: invalid=${invalid.size} + empty-model")
    }

    @Test
    fun modelTiersMatchTheFrozenClassifier() {
        val cases = mapOf(
            "deepseek-flash" to BotModelTier.SMALL,
            " deepseek-flash-2026 " to BotModelTier.SMALL,
            "deepseek-flashx" to BotModelTier.UNKNOWN,
            "deepseek-v4-pro" to BotModelTier.LARGE,
            "deepseek-pro" to BotModelTier.LARGE,
            "deepseek-reasoner" to BotModelTier.LARGE,
            "deepseek-chat" to BotModelTier.LARGE,
            "my-opus-model" to BotModelTier.LARGE,
            "vendor/opus-latest" to BotModelTier.LARGE,
            "unknown-model" to BotModelTier.UNKNOWN,
            "" to BotModelTier.UNKNOWN,
            "   " to BotModelTier.UNKNOWN,
        )
        for ((model, tier) in cases) {
            assertEquals("tier for '$model'", tier, BotModelPurposePolicy.modelTier(model))
        }
    }

    @Test
    fun everyPurposeMapsToItsPrincipalKind() {
        val expected = linkedMapOf(
            "front-turn" to "chat",
            "worker-turn" to "task",
            "triage" to "chat",
            "memory-extract" to "chat",
            "reflect" to "chat",
            "compact" to "chat",
            "watchdog" to "watchdog",
            "completion-check" to "chat",
            "memory-maintenance" to "maintainer",
        )
        assertEquals(expected.keys.toList(), BotModelPurpose.entries.map { it.wire })
        for (purpose in BotModelPurpose.entries) {
            assertEquals(expected.getValue(purpose.wire), purpose.principalKind)
        }
        assertFalse(BotModelPurpose.TRIAGE.largeModelAllowed)
        assertTrue(BotModelPurpose.FRONT_TURN.largeModelAllowed)
    }

    @Test
    fun policyDecodeRejectsUnknownOrIncompleteRows() {
        val valid = GoldenFixture.objectValue(GoldenFixture.rawObject("model-purpose-policy"), "valid")

        assertPolicyField("purposes[0].purpose") {
            BotModelPurposePolicy.fromJson(valid.withFirstPurpose("purpose", JsonString("bogus")))
        }
        assertPolicyField("purposes[0].costUsd") {
            BotModelPurposePolicy.fromJson(valid.withFirstPurpose("costUsd", JsonNumber("1")))
        }
        assertPolicyField("purposes[0].defaults.costUsd") {
            val defaults = (valid.members["purposes"] as JsonArray).values.first()
                .let { (it as JsonObject).members.getValue("defaults") as JsonObject }
            val members = LinkedHashMap(defaults.members)
            members["costUsd"] = JsonNumber("1")
            BotModelPurposePolicy.fromJson(
                valid.withFirstPurpose("defaults", JsonObject(members)),
            )
        }
        assertPolicyField("largeModelPurposes[0]") {
            val purposes = (valid.members["purposes"] as JsonArray)
            val large = JsonArray(listOf(JsonString("triage"), JsonString("worker-turn")))
            BotModelPurposePolicy.fromJson(
                JsonObject(
                    linkedMapOf(
                        "purposes" to purposes,
                        "largeModelPurposes" to large,
                    ),
                ),
            )
        }
        assertPolicyField("purposes") {
            BotModelPurposePolicy.fromJson(
                JsonObject(
                    linkedMapOf(
                        "purposes" to JsonArray(emptyList()),
                        "largeModelPurposes" to valid.members.getValue("largeModelPurposes"),
                    ),
                ),
            )
        }
        assertPolicyField("policy.costUsd") {
            val members = LinkedHashMap(valid.members)
            members["costUsd"] = JsonNumber("1")
            BotModelPurposePolicy.fromJson(JsonObject(members))
        }
    }

    private fun assertPolicyFailure(
        purpose: BotModelPurpose,
        model: String,
    ): BotModelPurposeException {
        val error = try {
            BotModelPurposePolicy.assertModelAllowed(purpose, model)
            null
        } catch (failure: BotModelPurposeException) {
            failure
        }
        assertNotNull("expected EPURPOSE failure for $purpose / $model", error)
        return error!!
    }

    private fun assertPolicyField(expected: String, block: () -> Unit): BotLLMLedgerException {
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

private fun JsonObject.withFirstPurpose(key: String, value: JsonValue): JsonObject {
    val purposes = (members["purposes"] as JsonArray).values.toMutableList()
    val row = purposes.first() as JsonObject
    val changed = LinkedHashMap(row.members)
    changed[key] = value
    purposes[0] = JsonObject(changed)
    return JsonObject(
        linkedMapOf(
            "purposes" to JsonArray(purposes),
            "largeModelPurposes" to members.getValue("largeModelPurposes"),
        ),
    )
}
