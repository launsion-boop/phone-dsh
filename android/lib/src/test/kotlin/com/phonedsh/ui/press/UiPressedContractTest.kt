// Shared pressed-state golden, read from the repository at test time.
// SPDX-License-Identifier: MIT
//
// Every row of spec/ui/v1/golden/pressed-states.golden.json runs through the
// real PressedStyle table the Compose modifiers use; no case is copied here.
package com.phonedsh.ui.press

import com.phonedsh.agentcore.JsonArray
import com.phonedsh.agentcore.JsonNumber
import com.phonedsh.agentcore.JsonObject
import com.phonedsh.agentcore.JsonString
import com.phonedsh.ui.SpecFixtures
import com.phonedsh.ui.theme.generated.UiTokenData
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class UiPressedContractTest {
    private val golden: JsonObject by lazy {
        SpecFixtures.repoJson("spec/ui/v1/golden/pressed-states.golden.json")
    }

    @Test
    fun `every golden row matches the pure pressed table`() {
        val rows = (golden["rows"] as JsonArray).values.map { it as JsonObject }
        assertEquals("the golden owns one row per pressed surface", PressedSurface.entries.size, rows.size)

        val seen = mutableSetOf<String>()
        rows.forEach { row ->
            val id = row.text("id")
            seen += id
            val surface = PressedSurface.fromId(id)

            val rest = PressedStyle.valuesFor(surface, PressedState.Rest)
            assertEquals("$id: rest", row.number("rest"), rest.rest, 0f)
            assertEquals("$id: pressed", row.number("pressed"), rest.pressed, 0f)
            assertEquals("$id: scale", row.number("scale"), rest.scale, 0f)
            assertEquals("$id: rest alpha", rest.rest, rest.alpha, 0f)

            val expectedDisabled = (row["disabled"] as? JsonNumber)?.raw?.toFloat()
            if (expectedDisabled == null) {
                assertNull("$id: disabled row", rest.disabled)
            } else {
                assertEquals("$id: disabled row", expectedDisabled, rest.disabled!!, 0f)
            }

            val pressed = PressedStyle.valuesFor(surface, PressedState.Pressed)
            assertEquals("$id: pressed alpha", row.number("pressed"), pressed.alpha, 0f)
            assertEquals("$id: background stays opaque while pressed", 1f, pressed.backgroundAlpha, 0f)

            // Rule 6: disabled never takes the pressed alpha. For the primary
            // button the table's disabled value is the background fill, while
            // the content remains at rest opacity (rule 3).
            val disabled = PressedStyle.valuesFor(surface, PressedState.Disabled)
            assertEquals("$id: disabled content alpha", row.number("rest"), disabled.alpha, 0f)
            assertEquals(
                "$id: disabled background alpha",
                expectedDisabled ?: 1f,
                disabled.backgroundAlpha,
                0f,
            )
        }
        assertEquals("the golden must cover every pressed surface", PressedSurface.entries.map { it.id }.toSet(), seen)
    }

    @Test
    fun `scale is the generated no-scale token, not a local constant`() {
        val generatedScale = UiTokenData.pressed.scale
        PressedSurface.entries.forEach { surface ->
            val values = PressedStyle.valuesFor(surface, PressedState.Rest)
            assertEquals("${surface.id}: scale reads interaction.pressed.scale", generatedScale, values.scale, 0f)
            assertEquals("${surface.id}: §6 rule 5 never scales", 1f, values.scale, 0f)
        }
    }

    @Test
    fun `golden header identifies the interaction pressed source`() {
        assertEquals("pressed-states", golden.text("kind"))
        assertEquals(1, golden.number("version").toInt())
        assertEquals("tokens.json#interaction.pressed", golden.text("source"))
    }

    private fun JsonObject.text(key: String): String = (this[key] as JsonString).value

    private fun JsonObject.number(key: String): Float = (this[key] as JsonNumber).raw.toFloat()
}
