// SPDX-License-Identifier: MIT
package com.phonedsh.ui.bot.state

import com.phonedsh.agentcore.JsonObject
import com.phonedsh.agentcore.JsonString
import org.junit.Assert.assertEquals
import org.junit.Test
import org.junit.runner.RunWith
import org.junit.runners.Parameterized

/**
 * Every `golden/ui-state-vectors.json` case: the real [BotUiStateDerivation]
 * derives the whole expected object, which is compared canonically.
 */
@RunWith(Parameterized::class)
class BotUiStateVectorTest(
    private val case: JsonObject,
    private val caseID: String,
) {
    @Test
    fun derivesExpectedState() {
        val input = BotUiStateFixtures.uiStateInput(case["input"]!!)
        val derived = BotUiStateDerivation.derive(input)
        var expected = case["expected"] as JsonObject
        var actual = derived.toJson()
        // Round-1 vectors predate §4.7: they carry the already-resolved
        // `pageFishState` and do not freeze a top-level fishState. The round-2
        // vectors do. Keep one harness for both so the integrator can rerun the
        // same suite once the spec merge lands; only the legacy projection field
        // is omitted from the round-1 comparison, every other derivation is
        // still compared exactly.
        if (expected["fishState"] == null) {
            expected = withoutHeaderFishState(expected)
            actual = withoutHeaderFishState(actual)
        } else {
            assertEquals(
                "fishState for '$caseID'",
                (expected["fishState"] as JsonString).value,
                derived.fishState.wire,
            )
        }
        input.pendingApprovalCount?.let { declared ->
            assertEquals(
                "input.pendingApprovalCount for '$caseID' must be the derived count",
                BotCounts.pendingApprovals(
                    BotUiStateDerivation.visibleRows(input.rows), input.actionStates),
                declared,
            )
        }
        BotUiStateFixtures.assertJsonEquals(
            "ui-state vector '$caseID' (${(case["source"] as? JsonString)?.value})",
            expected,
            actual,
        )
    }

    private fun withoutHeaderFishState(state: JsonObject): JsonObject {
        val header = (state["header"] as JsonObject).members - "fishState"
        val members = LinkedHashMap(state.members)
        members["header"] = JsonObject(header)
        members.remove("fishState")
        return JsonObject(members)
    }

    companion object {
        @JvmStatic
        @Parameterized.Parameters(name = "{1}")
        fun cases(): List<Array<Any>> =
            BotUiStateFixtures.cases("ui-state-vectors.json").map {
                arrayOf<Any>(it, (it["id"] as JsonString).value)
            }
    }
}
