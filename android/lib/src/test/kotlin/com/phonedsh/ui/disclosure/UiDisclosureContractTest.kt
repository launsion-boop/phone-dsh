// Shared disclosure motion golden, read from the repository at test time.
// SPDX-License-Identifier: MIT
package com.phonedsh.ui.disclosure

import com.phonedsh.agentcore.JsonArray
import com.phonedsh.agentcore.JsonNumber
import com.phonedsh.agentcore.JsonObject
import com.phonedsh.agentcore.JsonString
import com.phonedsh.ui.SpecFixtures
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * `spec/ui/v1/golden/disclosure-motion.golden.json` is the shared fixture; no
 * case is copied into Kotlin. Every row runs through the same resolver the
 * disclosure composables use.
 */
class UiDisclosureContractTest {
    private val golden: JsonObject by lazy {
        SpecFixtures.repoJson("spec/ui/v1/golden/disclosure-motion.golden.json")
    }

    @Test
    fun `golden header matches the generated disclosure contract`() {
        assertEquals("disclosure-motion", golden.text("kind"))
        assertEquals("tokens.json#interaction.disclosure", golden.text("source"))
        assertEquals(
            com.phonedsh.ui.theme.generated.UiTokenData.disclosure.reducedMotion.spec,
            golden.text("reducedMotion"),
        )
    }

    @Test
    fun `every golden row resolves through DisclosureMotion`() {
        val rows = (golden["rows"] as JsonArray).values.map { it as JsonObject }
        assertEquals("one golden row per DisclosureKind", DisclosureKind.values().size, rows.size)
        assertEquals(
            "golden row ids and DisclosureKind ids are the same set",
            DisclosureKind.values().map { it.id }.toSet(),
            rows.map { it.text("id") }.toSet(),
        )

        rows.forEach { row ->
            val id = row.text("id")
            val kind = DisclosureKind.values().firstOrNull { it.id == id }
                ?: error("golden row '$id' has no DisclosureKind")

            val animated = DisclosureMotion.specFor(kind, reducedMotion = false)
            assertEquals("$id: kind", kind, animated.kind)
            assertEquals("$id: motion name", row.text("motion"), animated.motion)
            assertEquals("$id: duration", row.number("durationMs").toInt(), animated.durationMs)
            assertEquals("$id: curve", row.text("curve"), animated.curve)
            assertFalse("$id: the golden row is the animated motion", animated.snap)

            val snapped = DisclosureMotion.specFor(kind, reducedMotion = true)
            assertEquals("$id: snap keeps the kind", kind, snapped.kind)
            assertEquals("$id: snap keeps the motion name", animated.motion, snapped.motion)
            assertEquals("$id: snap keeps the curve name", animated.curve, snapped.curve)
            assertEquals("$id: snap has no duration", 0, snapped.durationMs)
            assertTrue("$id: reduced motion snaps", snapped.snap)
        }
    }

    private fun JsonObject.text(key: String): String = (this[key] as JsonString).value

    private fun JsonObject.number(key: String): Double = (this[key] as JsonNumber).raw.toDouble()
}
