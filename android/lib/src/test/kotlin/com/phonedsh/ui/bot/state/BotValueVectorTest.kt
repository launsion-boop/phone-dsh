// SPDX-License-Identifier: MIT
package com.phonedsh.ui.bot.state

import com.phonedsh.agentcore.JsonObject
import com.phonedsh.agentcore.JsonString
import com.phonedsh.bot.BotJson
import org.junit.Assert.assertEquals
import org.junit.Test
import org.junit.runner.RunWith
import org.junit.runners.Parameterized

/**
 * Every `golden/value-vectors.json` value round-trips through the real value
 * codec: decode, encode and canonical-compare with the normative bytes. The
 * two deep-link values are additionally parsed from the frozen URL form.
 */
@RunWith(Parameterized::class)
class BotValueVectorTest(
    private val case: JsonObject,
    private val caseID: String,
) {
    @Test
    fun roundTripsValue() {
        val value = case["value"]!!
        val actual = when (val schema = case.string("schema")) {
            "roster-entry" -> BotRosterEntry.fromJson(value).toJson()
            "roster-runtime-state" -> BotRosterRuntimeState.fromJson(value).toJson()
            "runtime-state" -> BotRuntimeState.fromJson(value).toJson()
            "drawer-intent" -> BotDrawerIntent.fromJson(value).toJson()
            "info-intent" -> BotInfoIntent.fromJson(value).toJson()
            "appearance-intent" -> BotAppearanceIntent.fromJson(value).toJson()
            "deep-link" -> BotDeepLink.fromJson(value).toJson()
            else -> error("unknown value schema '$schema' in case '$caseID'")
        }
        BotUiStateFixtures.assertJsonEquals("value vector '$caseID'", value, actual)

        if (case.string("schema") == "deep-link") {
            val link = BotDeepLink.fromJson(value)
            val kind = if (link.destination is BotDeepLinkDestination.Row) "row" else "routine"
            assertEquals(
                "deep link URL parse for '$caseID'",
                link,
                BotDeepLink.parse("phonedsh://bot/${link.botID}/$kind/${link.destination.id}"),
            )
        }
    }

    companion object {
        @JvmStatic
        @Parameterized.Parameters(name = "{1}")
        fun cases(): List<Array<Any>> =
            BotUiStateFixtures.cases("value-vectors.json").map {
                arrayOf<Any>(it, (it["id"] as JsonString).value)
            }
    }
}

private fun JsonObject.string(key: String): String = (this[key] as JsonString).value
