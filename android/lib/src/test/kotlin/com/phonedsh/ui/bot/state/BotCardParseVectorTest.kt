// SPDX-License-Identifier: MIT
package com.phonedsh.ui.bot.state

import com.phonedsh.agentcore.JsonArray
import com.phonedsh.agentcore.JsonBool
import com.phonedsh.agentcore.JsonObject
import com.phonedsh.agentcore.JsonString
import com.phonedsh.agentcore.JsonValue
import com.phonedsh.bot.BotJson
import org.junit.Test
import org.junit.runner.RunWith
import org.junit.runners.Parameterized

/**
 * Every `golden/card-parse-vectors.json` case: the real row/card decoders and
 * renderer produce `{renderable, surface, copyText, kind?, choices/steps/
 * checklist/links?}` exactly.
 */
@RunWith(Parameterized::class)
class BotCardParseVectorTest(
    private val case: JsonObject,
    private val caseID: String,
) {
    @Test
    fun parsesExpectedCard() {
        val row = BotUIRowCodec.fromJson(case["row"]!!)
        val parsed = BotUICardContent.parse(row)
        val actual = LinkedHashMap<String, JsonValue>()
        actual["renderable"] = JsonBool(BotUIRendering.isRenderable(row))
        actual["surface"] = JsonString(BotUIRendering.surface(row))
        actual["copyText"] = JsonString(BotUIRendering.copyText(row))
        if (parsed != null) {
            actual["kind"] = JsonString(parsed.kind.wire)
            when (parsed.kind) {
                BotUICardKind.QUESTION -> actual["choices"] =
                    JsonArray(parsed.choices.map { it.toJson() })
                BotUICardKind.STEPS -> actual["steps"] =
                    JsonArray(parsed.steps.map { it.toJson() })
                BotUICardKind.CHECKLIST -> actual["checklist"] =
                    JsonArray(parsed.checklist.map { it.toJson() })
                BotUICardKind.LINK -> actual["links"] =
                    JsonArray(parsed.links.map { it.toJson() })
                else -> Unit
            }
        }
        BotUiStateFixtures.assertJsonEquals(
            "card-parse vector '$caseID' (${(case["source"] as? JsonString)?.value})",
            case["expected"]!!,
            JsonObject(actual),
        )
    }

    companion object {
        @JvmStatic
        @Parameterized.Parameters(name = "{1}")
        fun cases(): List<Array<Any>> =
            BotUiStateFixtures.cases("card-parse-vectors.json").map {
                arrayOf<Any>(it, (it["id"] as JsonString).value)
            }
    }
}
