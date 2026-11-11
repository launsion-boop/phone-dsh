// Shared drawer gesture golden, read from the repository at test time.
// SPDX-License-Identifier: MIT
package com.phonedsh.ui.nav

import com.phonedsh.agentcore.JsonArray
import com.phonedsh.agentcore.JsonBool
import com.phonedsh.agentcore.JsonNumber
import com.phonedsh.agentcore.JsonObject
import com.phonedsh.agentcore.JsonString
import com.phonedsh.ui.SpecFixtures
import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * `spec/ui/v1/golden/drawer-gesture.golden.json` is the shared fixture; no case
 * is copied into Kotlin. Every group runs through the same pure state machine
 * the drawer uses.
 */
class DrawerGestureGoldenTest {
    private val golden: JsonObject by lazy {
        SpecFixtures.repoJson("spec/ui/v1/golden/drawer-gesture.golden.json")
    }

    @Test
    fun `every release case matches the shared golden`() {
        cases("release").forEach { case ->
            val expected = when (case.text("result")) {
                "close" -> DrawerRelease.Close
                "settle" -> DrawerRelease.Settle
                else -> error("${case.text("id")}: unknown release result '${case.text("result")}'")
            }
            assertEquals(
                "${case.text("id")}: release(${case.number("dx")}, ${case.number("velocity")})",
                expected,
                DrawerGesture.release(case.number("dx").toFloat(), case.number("velocity").toFloat()),
            )
        }
    }

    @Test
    fun `every follow case matches the shared golden`() {
        cases("follow").forEach { case ->
            val previous = 0f
            val offset = DrawerGesture.followOffset(
                case.number("dx").toFloat(),
                case.number("dy").toFloat(),
                previous,
            )
            assertEquals("${case.text("id")}: offset", case.number("offset").toFloat(), offset, 0f)
            if (!case.bool("follows")) {
                assertEquals("${case.text("id")}: a non-following move keeps the previous offset", previous, offset, 0f)
            }
        }
    }

    @Test
    fun `every minimum distance case matches the shared golden`() {
        cases("minimumDistance").forEach { case ->
            assertEquals(
                "${case.text("id")}: hasStarted(${case.number("distance")})",
                case.bool("drag"),
                DrawerGesture.hasStarted(case.number("distance").toFloat()),
            )
        }
    }

    @Test
    fun `every scrim case matches the shared golden`() {
        cases("scrim").forEach { case ->
            // Float math on the token values; 1e-6 is far below one visible alpha
            // step and still fails a formula drift (old golden spread is 0.07+).
            assertEquals(
                "${case.text("id")}: scrimAlpha(${case.number("offset")})",
                case.number("opacity"),
                DrawerGesture.scrimAlpha(case.number("offset").toFloat()).toDouble(),
                1e-6,
            )
        }
    }

    private fun cases(group: String): List<JsonObject> =
        (golden[group] as JsonArray).values.map { it as JsonObject }

    private fun JsonObject.text(key: String): String =
        (this[key] as JsonString).value

    private fun JsonObject.number(key: String): Double =
        (this[key] as JsonNumber).raw.toDouble()

    private fun JsonObject.bool(key: String): Boolean =
        (this[key] as JsonBool).value
}
