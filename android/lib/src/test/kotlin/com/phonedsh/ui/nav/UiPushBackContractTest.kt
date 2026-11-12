// Shared push-back golden, driven through the real PushBackState machine.
// SPDX-License-Identifier: MIT
package com.phonedsh.ui.nav

import com.phonedsh.agentcore.JsonArray
import com.phonedsh.agentcore.JsonBool
import com.phonedsh.agentcore.JsonNumber
import com.phonedsh.agentcore.JsonObject
import com.phonedsh.agentcore.JsonString
import com.phonedsh.ui.SpecFixtures
import org.junit.Assert.assertEquals
import org.junit.Assert.assertSame
import org.junit.Test

/**
 * `spec/ui/v1/golden/push-back.golden.json` is the shared fixture; no case is
 * copied into Kotlin. Every row is applied to [PushBackState] and all four
 * outputs (depth, overlay set, bar visibility, exit) are compared.
 */
class UiPushBackContractTest {
    private val golden: JsonObject by lazy {
        SpecFixtures.repoJson("spec/ui/v1/golden/push-back.golden.json")
    }

    @Test
    fun `every push-back golden case matches the real state machine`() {
        val cases = (golden["cases"] as JsonArray).values.map { it as JsonObject }
        assertEquals("the golden must carry all eleven sequences", 11, cases.size)

        cases.forEach { case ->
            val id = case.text("id")
            val before = stateFor(case)
            val action = case.text("action")
            val result = when (action) {
                "push" -> PushBackResult(before.push(), exited = false)
                "back" -> before.back()
                "predictive-cancel" -> {
                    assertSame(
                        "$id: progress must not change state",
                        before,
                        before.predictiveProgress(0.5f),
                    )
                    PushBackResult(before.predictiveCancel(), exited = false)
                }
                else -> error("$id: unknown action '$action'")
            }

            assertEquals("$id: selected tab", HomeTab.TASKS, result.state.selectedTab)
            assertEquals("$id: depthAfter", case.number("depthAfter").toInt(), result.state.depth)
            assertEquals("$id: overlayAfter", case.text("overlayAfter"), result.state.overlaySpec())
            assertEquals("$id: barVisible", case.bool("barVisible"), result.state.tabBarVisible)
            assertEquals("$id: exited", case.bool("exited"), result.exited)
        }
    }

    private fun stateFor(case: JsonObject): PushBackState {
        val depth = case.number("depth").toInt()
        val overlays = when (val spec = case.text("overlay")) {
            "none" -> emptyList()
            else -> spec.split(",").map { name ->
                PushOverlay.entries.single { it.spec == name.trim() }
            }
        }
        return PushBackState(
            selectedTab = HomeTab.TASKS,
            stackDepths = if (depth == 0) emptyMap() else mapOf(HomeTab.TASKS to depth),
            overlays = overlays,
            keyboardVisible = case.bool("keyboard"),
        )
    }

    private fun PushBackState.overlaySpec(): String =
        overlays.joinToString(",") { it.spec }.ifEmpty { "none" }

    private fun JsonObject.text(key: String): String = (this[key] as JsonString).value

    private fun JsonObject.number(key: String): Double = (this[key] as JsonNumber).raw.toDouble()

    private fun JsonObject.bool(key: String): Boolean = (this[key] as JsonBool).value
}
