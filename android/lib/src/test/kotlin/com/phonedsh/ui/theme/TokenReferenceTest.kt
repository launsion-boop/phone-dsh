// Token discipline: the six signature surfaces read `spec/ui/v1/tokens.json`,
// SPDX-License-Identifier: MIT
// and nothing else.
//
// The test reads the spec file itself (never a copy) and asserts three things:
//  1. every token name a component references exists in `tokens.json`;
//  2. each component's declared inventory equals the spec's own
//     `signatureSurfaces.<id>.tokens` list — a missing or extra token fails;
//  3. the generated `UiTokenData` is byte-for-byte in sync with the spec, so a
//     stale build generator cannot drift from the single source.
package com.phonedsh.ui.theme

import com.phonedsh.agentcore.JsonArray
import com.phonedsh.agentcore.JsonBool
import com.phonedsh.agentcore.JsonNull
import com.phonedsh.agentcore.JsonNumber
import com.phonedsh.agentcore.JsonObject
import com.phonedsh.agentcore.JsonString
import com.phonedsh.ui.SpecFixtures
import com.phonedsh.ui.surfaces
import com.phonedsh.ui.text
import com.phonedsh.ui.tokenNames
import com.phonedsh.ui.surface.ApprovalCardTokens
import com.phonedsh.ui.surface.BubbleTokens
import com.phonedsh.ui.surface.ComposerTokens
import com.phonedsh.ui.surface.FailLoudBannerTokens
import com.phonedsh.ui.surface.ThinkingPillTokens
import com.phonedsh.ui.surface.ToolRowTokens
import com.phonedsh.ui.theme.generated.UiTokenData
import com.phonedsh.ui.theme.generated.UiTypeScale
import androidx.compose.ui.graphics.Color
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class TokenReferenceTest {
    @Test
    fun `the spec declares exactly the six signature surfaces`() {
        val ids = SpecFixtures.surfaces().map { it.id }.sorted()
        assertEquals(
            listOf("approvalCard", "bubble", "composer", "failLoudBanner", "thinkingPill", "toolRow"),
            ids,
        )
        assertEquals("every signature surface has a component", ids.size, inventories().size)
    }

    @Test
    fun `every token a component references exists in tokens json`() {
        val known = SpecFixtures.tokenNames()
        inventories().forEach { inventory ->
            (inventory.declared + inventory.gaps).forEach { reference ->
                assertTrue(
                    "${inventory.id}: '$reference' is not a token in spec/ui/v1/tokens.json",
                    reference in known,
                )
            }
        }
    }

    @Test
    fun `each component inventory equals the spec surface token list`() {
        val declaredBySpec = SpecFixtures.surfaces().associate { it.id to it.tokens.toSet() }
        inventories().forEach { inventory ->
            assertEquals(
                "${inventory.id}: component inventory must match signatureSurfaces.${inventory.id}.tokens",
                declaredBySpec.getValue(inventory.id),
                inventory.declared.toSet(),
            )
        }
    }

    @Test
    fun `documented gaps are small and named`() {
        // A gap is a token the component needs but the spec's surface list does not
        // declare. It is reviewed, never silent: keep the list explicit.
        val gaps = inventories().filter { it.gaps.isNotEmpty() }.associate { it.id to it.gaps.toSet() }
        // Empty today: the two gaps these surfaces used to carry (the primary ink and
        // the internal control gap) are declared by the spec now. The test stays so a
        // future gap has to be written down here rather than added silently.
        assertEquals(emptyMap<String, Set<String>>(), gaps)
    }

    @Test
    fun `generated token data is in sync with the spec`() {
        val tokens = SpecFixtures.tokens
        assertEquals("token names", SpecFixtures.tokenNames(), UiTokenData.allNames)

        val colors = tokens["colors"] as JsonObject
        assertEquals("colour tokens", colors.members.keys.map { "colors.$it" }.toSet(), UiTokenData.colors.keys)
        colors.members.forEach { (key, raw) ->
            val entry = raw as JsonObject
            val generated = UiTokenData.colors.getValue("colors.$key")
            assertEquals("colors.$key light", argb(entry, "light"), generated.light)
            assertEquals("colors.$key dark", argb(entry, "dark"), generated.dark)
            assertEquals("colors.$key unmeasured", generated.light == null || generated.dark == null, generated.unmeasured)
        }

        val styles = (tokens["typography"] as JsonObject)["styles"] as JsonObject
        styles.members.forEach { (key, raw) ->
            val entry = raw as JsonObject
            val generated = UiTokenData.types.getValue("typography.$key")
            assertEquals("typography.$key size", number(entry, "baseSize").toFloat(), generated.baseSize, 0f)
            assertEquals("typography.$key weight", number(entry, "weight").toInt(), generated.weight)
            assertEquals("typography.$key mono", (entry["mono"] as JsonBool).value, generated.mono)
        }

        for (family in listOf("spacing", "radius", "stroke")) {
            val json = tokens[family] as JsonObject
            val generated = when (family) {
                "spacing" -> UiTokenData.spacing
                "radius" -> UiTokenData.radius
                else -> UiTokenData.stroke
            }
            assertEquals(
                "$family tokens",
                json.members.keys.map { "$family.$it" }.toSet(),
                generated.keys,
            )
            json.members.forEach { (key, raw) ->
                assertEquals("$family.$key", (raw as JsonNumber).raw.toFloat(), generated.getValue("$family.$key").value, 0f)
            }
        }

        val motion = tokens["motion"] as JsonObject
        motion.members.forEach { (key, raw) ->
            val entry = raw as JsonObject
            val generated = UiTokenData.motion.getValue("motion.$key")
            assertEquals("motion.$key duration", number(entry, "durationMs").toInt(), generated.durationMs)
            assertEquals("motion.$key curve", entry.text("curve"), generated.curve)
            assertEquals("motion.$key repeat", entry.text("repeat"), generated.repeat)
        }

        val geometry = tokens["geometry"] as JsonObject
        geometry.members.forEach { (key, raw) ->
            val entry = raw as JsonObject
            val generated = UiTokenData.geometry.getValue("geometry.$key")
            assertEquals("geometry.$key value", number(entry, "value").toFloat(), generated.value, 0f)
            assertEquals("geometry.$key unit", entry.text("unit"), generated.unit)
            assertEquals("geometry.$key scalesWith", entry.text("scalesWith"), generated.scalesWith)
        }

        SpecFixtures.surfaces().forEach { surface ->
            assertEquals(
                "signatureSurfaces.${surface.id}.tokens",
                surface.tokens,
                UiTokenData.surfaces.single { it.id == surface.id }.tokens,
            )
        }
    }

    @Test
    fun `geometry units and font-scale contract are honoured`() {
        val geometry = SpecFixtures.tokens["geometry"] as JsonObject
        val typography = SpecFixtures.tokenNames().filter { it.startsWith("typography.") }.toSet()
        geometry.members.forEach { (key, raw) ->
            val entry = raw as JsonObject
            val unit = entry.text("unit")
            assertTrue("geometry.$key unit '$unit'", unit == "pt" || unit == "screenRatio")
            val scalesWith = entry["scalesWith"]
            assertTrue(
                "geometry.$key scalesWith must be null or a typography token",
                scalesWith == null || scalesWith is JsonNull || (
                    scalesWith is JsonString && "typography.${scalesWith.value}" in typography
                    ),
            )
        }
        // `typography.scale` says the platform scale is the only multiplier; Android
        // implements it by emitting `sp`, so the driver name must stay `font-scale`.
        assertEquals("system", (SpecFixtures.tokens["typography"] as JsonObject)
            .let { (it["scale"] as JsonObject).text("mode") })
        assertEquals("font-scale", UiTypeScale.ANDROID_DRIVER)
    }

    @Test
    fun `the resolved theme reads the generated values`() {
        val light = UiTokens.resolve(dark = false)
        val dark = UiTokens.resolve(dark = true)
        assertEquals(Color(0xFF3964FE), light.colors.accent)
        assertEquals(Color(0xFF679EFE), dark.colors.accent)
        assertEquals(Color(0xFF2F5BFF), light.colors.ctaOverride)
        assertEquals(Color(0xFF2F5BFF), dark.colors.ctaOverride)
        assertEquals(22f, light.radius.bubble.value, 0f)
        assertEquals(0.4f, light.geometry.cardAreaMaxHeightRatio, 0f)
        // `colors.background` cannot be measured (a dynamic system colour): it must
        // stay unspecified rather than become an invented fill.
        assertTrue(light.colors.backgroundUnmeasured)
        assertTrue(light.motion.shimmerRepeat)
        assertEquals("easeOut", light.motion.disclosureCurve)
    }

    private fun inventories(): List<Inventory> = listOf(
        Inventory("bubble", BubbleTokens.refs, emptyList()),
        Inventory("toolRow", ToolRowTokens.refs, emptyList()),
        Inventory("thinkingPill", ThinkingPillTokens.refs, emptyList()),
        Inventory("approvalCard", ApprovalCardTokens.declared, ApprovalCardTokens.gaps),
        Inventory("composer", ComposerTokens.declared, ComposerTokens.gaps),
        Inventory("failLoudBanner", FailLoudBannerTokens.refs, emptyList()),
    )

    private fun argb(entry: JsonObject, key: String): Long? {
        val hex = (entry[key] as? JsonString)?.value ?: return null
        return ("FF" + hex.removePrefix("#")).toLong(16)
    }

    private fun number(entry: JsonObject, key: String): Double =
        (entry[key] as JsonNumber).raw.toDouble()

    private data class Inventory(val id: String, val declared: List<String>, val gaps: List<String>)
}
