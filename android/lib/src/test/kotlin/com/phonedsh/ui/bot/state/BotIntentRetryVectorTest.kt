// SPDX-License-Identifier: MIT
package com.phonedsh.ui.bot.state

import com.phonedsh.agentcore.JsonArray
import com.phonedsh.agentcore.JsonBool
import com.phonedsh.agentcore.JsonNull
import com.phonedsh.agentcore.JsonObject
import com.phonedsh.agentcore.JsonString
import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * `golden/ui-state-vectors.json#intentCases`: the §3.1 retry policy through
 * the real [BotActionRetryPolicy], including the UI-2 failed-dismiss retry.
 *
 * Round-1 vectors have no `intentCases`; the test is a no-op for them and
 * covers every case once the S2 spec merge lands.
 */
class BotIntentRetryVectorTest {
    @Test
    fun retryPolicyMatchesEveryIntentVector() {
        val golden = BotUiStateFixtures.golden("ui-state-vectors.json")
        val raw = golden["intentCases"] ?: return
        val cases = (raw as JsonArray).values.map { it as JsonObject }
        for (case in cases) {
            val caseID = (case["id"] as JsonString).value
            val action = BotActionIntentKind.fromWire(
                (case["action"] as JsonString).value)
            val cardKind = BotUICardKind.fromWire(
                (case["cardKind"] as JsonString).value)
            val state = when (val value = case["state"]) {
                null, is JsonNull -> null
                is JsonString -> when (value.value) {
                    "pending" -> BotActionState.Pending
                    "accepted" -> BotActionState.Accepted
                    "failed" -> BotActionState.Failed("")
                    else -> error("unknown intent state: ${value.value}")
                }
                else -> error("intent state must be a string or null")
            }
            assertEquals(
                "intent case '$caseID'",
                (case["accepted"] as JsonBool).value,
                BotActionRetryPolicy.isRetryable(action, cardKind, state),
            )
        }
    }
}
