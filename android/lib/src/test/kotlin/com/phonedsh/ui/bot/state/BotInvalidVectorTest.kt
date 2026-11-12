// SPDX-License-Identifier: MIT
package com.phonedsh.ui.bot.state

import com.phonedsh.agentcore.JsonObject
import com.phonedsh.agentcore.JsonString
import com.phonedsh.agentcore.JsonValue
import com.phonedsh.bot.BotJsonException
import com.phonedsh.bot.rows.BotUserAction
import com.phonedsh.bot.rows.BotUserActionValidation
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import org.junit.runner.RunWith
import org.junit.runners.Parameterized

/**
 * Every `golden/invalid-vectors.json` value is rejected by the real decoder or
 * rule named by its `validator`, with no local fallback path.
 */
@RunWith(Parameterized::class)
class BotInvalidVectorTest(
    private val case: JsonObject,
    private val caseID: String,
) {
    @Test
    fun rejectsInvalidValue() {
        val value = case["value"]!!
        when (val validator = case.string("validator")) {
            "schema:row" -> assertThrows(BotJsonException::class.java) {
                BotUIRowCodec.fromJson(value)
            }
            "schema:presentation" -> assertThrows(BotJsonException::class.java) {
                BotRuntimePresentation.fromJson(value)
            }
            "schema:info" -> assertThrows(BotJsonException::class.java) {
                BotInfoSnapshot.fromJson(value)
            }
            "schema:drawer-intent" -> assertThrows(BotJsonException::class.java) {
                BotDrawerIntent.fromJson(value)
            }
            "schema:info-intent" -> assertThrows(BotJsonException::class.java) {
                BotInfoIntent.fromJson(value)
            }
            "schema:appearance-intent" -> assertThrows(BotJsonException::class.java) {
                BotAppearanceIntent.fromJson(value)
            }
            "schema:deep-link" -> assertThrows(BotJsonException::class.java) {
                BotDeepLink.fromJson(value)
            }
            "schema:roster-entry" -> assertThrows(BotJsonException::class.java) {
                BotRosterEntry.fromJson(value)
            }
            "rule:user-action" -> assertUserActionRejected(value)
            "rule:action-retry" -> {
                val members = (value as JsonObject).members
                val action = BotActionIntentKind.fromWire(
                    JsonSupport.requiredString(members, "action", "actionRetry.action"))
                val cardKind = BotUICardKind.fromWire(
                    JsonSupport.requiredString(members, "cardKind", "actionRetry.cardKind"))
                val state = JsonSupport.string(members["state"])?.let {
                    when (it) {
                        "pending" -> BotActionState.Pending
                        "accepted" -> BotActionState.Accepted
                        "failed" -> BotActionState.Failed("")
                        else -> error("unknown action-retry state: $it")
                    }
                }
                assertTrue(
                    "case '$caseID' was accepted",
                    !BotActionRetryPolicy.isRetryable(action, cardKind, state),
                )
            }
            "rule:name-cap" -> assertNotNull(
                "case '$caseID' was accepted",
                BotNameValidation.problem((value as JsonString).value),
            )
            "rule:deep-link" -> assertNull(
                "case '$caseID' was accepted",
                BotDeepLink.parse((value as JsonString).value),
            )
            "rule:approval-renderability", "rule:card-parse" -> {
                val row = BotUiStateFixtures.rowForBody(value as JsonObject)
                assertNull("case '$caseID' parsed", BotUICardContent.parse(row))
            }
            else -> fail("unknown validator '$validator' for case '$caseID'")
        }
    }

    private fun assertUserActionRejected(value: JsonValue) {
        var rejected = false
        try {
            val action = BotUserAction.fromJson(value)
            rejected = BotUserActionValidation.validate(action) != null
        } catch (_: BotJsonException) {
            rejected = true
        }
        assertTrue("case '$caseID' was accepted", rejected)
    }

    companion object {
        @JvmStatic
        @Parameterized.Parameters(name = "{1}")
        fun cases(): List<Array<Any>> =
            BotUiStateFixtures.cases("invalid-vectors.json").map {
                arrayOf<Any>(it, (it["id"] as JsonString).value)
            }
    }
}

private fun JsonObject.string(key: String): String = (this[key] as JsonString).value
