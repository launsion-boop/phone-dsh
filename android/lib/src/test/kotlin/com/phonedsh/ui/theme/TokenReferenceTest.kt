// Token discipline: the six signature surfaces read `spec/ui/v1/tokens.json`,
// SPDX-License-Identifier: MIT
// and nothing else.
//
// The test reads the spec file itself (never a copy) and asserts:
//  1. the canonical generated table is byte-for-byte in sync with the spec,
//     including line heights, alpha channels and semantic roles;
//  2. every token a component references exists (compatibility names resolve
//     through the declared aliases);
//  3. each component's active reads outside the HomeSpec signature equal the
//     explicit `componentCompatibility` declaration for that surface;
//  4. the resolved theme carries the reviewed values, not a second table.
package com.phonedsh.ui.theme

import com.phonedsh.agentcore.JsonArray
import com.phonedsh.agentcore.JsonBool
import com.phonedsh.agentcore.JsonNull
import com.phonedsh.agentcore.JsonNumber
import com.phonedsh.agentcore.JsonObject
import com.phonedsh.agentcore.JsonString
import com.phonedsh.ui.HomeMetrics
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
import androidx.compose.ui.unit.dp
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
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
    fun `active component reads outside the HomeSpec signature are explicit`() {
        val declaredBySpec = SpecFixtures.surfaces().associate { it.id to it.tokens.toSet() }
        val compatibility = componentCompatibility()
        inventories().forEach { inventory ->
            val activeReadSet = (inventory.declared + inventory.gaps).toSet()
            val declaredHomeSpec = declaredBySpec.getValue(inventory.id)
            assertEquals(
                "${inventory.id}: component compatibility roles must be declared once in tokens.json",
                activeReadSet - declaredHomeSpec,
                compatibility[inventory.id].orEmpty(),
            )
            assertTrue(
                "${inventory.id}: HomeSpec contract references must remain real JSON tokens",
                declaredHomeSpec.all { it in SpecFixtures.tokenNames() },
            )
            assertTrue(
                "${inventory.id}: every active read must still be a real JSON token",
                activeReadSet.all { it in SpecFixtures.tokenNames() },
            )
        }
    }

    @Test
    fun `required surface roles cannot disappear behind compatibility declarations`() {
        val signatures = SpecFixtures.surfaces().associate { it.id to it.tokens.toSet() }
        val missing = inventories().mapNotNull { inventory ->
            val active = (inventory.declared + inventory.gaps).toSet()
            val absent = signatures.getValue(inventory.id) - active - verifiedParentRoles(inventory.id)
            if (absent.isEmpty()) null else "${inventory.id}: $absent"
        }
        // Required roles must be consumed by the primitive or a verified live
        // parent. Compatibility declarations never waive a missing role.
        assertTrue("Required source-owned surface roles are missing: $missing", missing.isEmpty())
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
            assertEquals(
                "colors.$key light alpha",
                (entry["lightAlpha"] as? JsonNumber)?.raw?.toFloat() ?: 1f,
                generated.lightAlpha,
                0f,
            )
            assertEquals(
                "colors.$key dark alpha",
                (entry["darkAlpha"] as? JsonNumber)?.raw?.toFloat() ?: 1f,
                generated.darkAlpha,
                0f,
            )
            assertEquals("colors.$key semantic", (entry["semantic"] as? JsonString)?.value, generated.semantic)
        }

        val styles = (tokens["typography"] as JsonObject)["styles"] as JsonObject
        styles.members.forEach { (key, raw) ->
            val entry = raw as JsonObject
            val generated = UiTokenData.types.getValue("typography.$key")
            assertEquals("typography.$key size", number(entry, "baseSize").toFloat(), generated.baseSize, 0f)
            assertEquals("typography.$key weight", number(entry, "weight").toInt(), generated.weight)
            assertEquals("typography.$key mono", (entry["mono"] as JsonBool).value, generated.mono)
            assertEquals(
                "typography.$key lineHeight",
                (entry["lineHeight"] as? JsonNumber)?.raw?.toFloat(),
                generated.lineHeight,
            )
        }

        for (family in listOf("spacing", "radius", "stroke")) {
            val json = tokens[family] as JsonObject
            val generated = when (family) {
                "spacing" -> UiTokenData.spacing
                "radius" -> UiTokenData.radius
                else -> UiTokenData.stroke
            }
            assertEquals("$family tokens", json.members.keys.map { "$family.$it" }.toSet(), generated.keys)
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
                    scalesWith is JsonString && scalesWith.value in typography
                    ),
            )
        }
        assertEquals(
            "system",
            (SpecFixtures.tokens["typography"] as JsonObject).let { (it["scale"] as JsonObject).text("mode") },
        )
        assertEquals("font-scale", UiTypeScale.ANDROID_DRIVER)
    }

    @Test
    fun `the resolved theme reads the generated values`() {
        val light = UiTokens.resolve(dark = false, viewportWidth = 430f.dp)
        val dark = UiTokens.resolve(dark = true, viewportWidth = 430f.dp)
        assertEquals(Color(0xFF1A1A1A), light.colors.accent)
        assertEquals(Color(0xFF679EFE), dark.colors.accent)
        assertEquals(Color(0xFF1A1A1A), light.colors.ctaOverride)
        assertEquals(Color(0xFF679EFE), dark.colors.ctaOverride)
        assertEquals(Color(0xFF191919), light.colors.pageAccent)
        assertEquals(Color(0xFF3A3A3C), dark.colors.pageAccent)
        assertEquals(Color.Unspecified, light.colors.switchOn)
        assertEquals(Color.Unspecified, light.colors.systemLabel)
        assertEquals(Color.Unspecified, dark.colors.systemLabel)
        assertEquals(Color.Unspecified, light.colors.systemSecondary)
        assertEquals(Color(0xFF1A1A1A), light.colors.primary)
        assertEquals(Color(0xFFF9FAFB), dark.colors.primary)
        assertEquals(Color(0xFF555555), light.colors.secondary)
        assertEquals(Color(0xFFCFD3D6), dark.colors.secondary)
        assertEquals(Color(0xFF888888), light.colors.tertiary)
        assertEquals(Color(0xFFADB2B8), dark.colors.tertiary)
        assertEquals(0.10f, UiTokenData.colorBorder.lightAlpha, 0f)
        assertEquals(0.12f, UiTokenData.colorBorder.darkAlpha, 0f)
        assertEquals(0.04f, UiTokenData.colorBorderLight.lightAlpha, 0f)
        assertEquals(0.06f, UiTokenData.colorBorderLight.darkAlpha, 0f)
        assertEquals(Color(0xFF151517), UiTokenData.colors.getValue("colors.sessionSurface").color(true))
        // HomeSpec has separate text/success roles and does not overwrite parity aliases.
        assertEquals(Color(0xFFF7F7F7), light.colors.page)
        assertEquals(Color(0xFF101012), dark.colors.page)
        assertEquals(Color(0xFFFFFFFF), light.colors.surface)
        assertEquals(Color(0xFF1C1C1E), dark.colors.surface)
        assertEquals(Color(0xFFE8E8E8), light.colors.userBubble)
        assertEquals(Color(0xFF2C2C2E), dark.colors.userBubble)
        assertEquals(Color(0xFF191919), light.colors.primaryButton)
        assertEquals(Color(0xFFF2F2F2), dark.colors.primaryButton)
        assertEquals(Color(0xFFFFFFFF), light.colors.primaryButtonInk)
        assertEquals(Color(0xFF111111), dark.colors.primaryButtonInk)
        assertEquals(Color(0xFF1A1A1A), light.colors.textPrimary)
        assertEquals(Color(0xFF555555), light.colors.textSecondary)
        assertEquals(Color(0xFF717171), light.colors.textTertiary)
        assertEquals(Color(0xFF7D7D7D), light.colors.textSubtle)
        assertEquals(Color(0xFF888888), light.colors.textPlaceholder)
        assertEquals(Color(0xFF8B8B8B), light.colors.inputPlaceholder)
        assertEquals(Color(0xFFA9A9A9), light.colors.iconMuted)
        assertEquals(Color(0xFF3DC979), light.colors.homeSuccess)
        assertEquals(Color(0xFF3DC979), dark.colors.homeSuccess)
        assertEquals(Color(0xFF000000), light.colors.taskScreen)
        assertEquals(Color(0xFF000000), dark.colors.taskScreen)
        assertEquals(Color(0xFF3DC979), light.colors.success)
        assertEquals(Color(0xFF22C55E), dark.colors.success)
        assertEquals(Color(0xFFE2E2E2), light.colors.borderList)
        assertEquals(0.05f, light.shadow.floatingOpacity, 0f)
        assertEquals(5f, light.shadow.floatingRadius.value, 0f)
        assertEquals(0.08f, light.shadow.composerOpacity, 0f)
        assertEquals(24f, light.radius.bubble.value, 0f)
        assertEquals(24f, light.radius.composer.value, 0f)
        assertEquals(12f, light.radius.card.value, 0f)
        assertEquals(12f, light.radius.codeBlock.value, 0f)
        assertEquals(312f, light.geometry.bubbleMaxWidth.value, 0f)
        assertEquals(272f, UiTokens.resolve(false, 380f.dp).geometry.bubbleMaxWidth.value, 0f)
        assertEquals(312f, light.geometry.maxBubbleWidth(430f.dp, 20f.dp).value, 0f)
        assertEquals(272f, light.geometry.maxBubbleWidth(380f.dp, 20f.dp).value, 0f)
        assertEquals(0.4f, light.geometry.cardAreaMaxHeightRatio, 0f)
        // NativeChatTheme.background is HomeSpec.page, so preserve the measured fill.
        assertEquals(Color(0xFFF7F7F7), light.colors.background)
        assertEquals(Color(0xFF101012), dark.colors.background)
        assertFalse(light.colors.backgroundUnmeasured)
        assertTrue(light.motion.shimmerRepeat)
        assertEquals("easeOut", light.motion.disclosureCurve)
    }

    /** The transcript owns inter-row spacing and the grouped process-card chrome. */
    private fun verifiedParentRoles(surface: String): Set<String> {
        fun source(file: String): String = String(java.nio.file.Files.readAllBytes(
            SpecFixtures.repoRoot.resolve("android/lib/src/main/kotlin/com/phonedsh/ui/page/$file"),
        ), Charsets.UTF_8)
        return when (surface) {
            "bubble" -> {
                val rows = source("ChatRows.kt")
                assertTrue("The live row must place the bubble", rows.contains("ChatBubble("))
                assertTrue("Bubble paragraph spacing must remain row-owned", rows.contains("Arrangement.spacedBy(HomeMetrics.paragraphGap)"))
                val spacing = SpecFixtures.tokens["spacing"] as JsonObject
                assertEquals((spacing["paragraphGap"] as JsonNumber).raw.toFloat(), HomeMetrics.paragraphGap.value, 0f)
                setOf("spacing.paragraphGap")
            }
            "toolRow" -> {
                val rows = source("ChatRows.kt")
                assertTrue("The live process group must contain tool rows", rows.contains("ProcessGroupRow(") && rows.contains("ToolRow("))
                assertTrue(rows.contains(".background(tokens.colors.surface)"))
                assertTrue(rows.contains("tokens.colors.borderList"))
                assertTrue(rows.contains("RoundedCornerShape(HomeMetrics.listCardRadius)"))
                val radius = SpecFixtures.tokens["radius"] as JsonObject
                assertEquals((radius["listCard"] as JsonNumber).raw.toFloat(), HomeMetrics.listCardRadius.value, 0f)
                setOf("colors.surface", "colors.borderList", "radius.listCard")
            }
            "failLoudBanner" -> {
                // Production TURN/SEND rows live in ChatPage; the shared legacy
                // component is kept API-compatible but does not own this retry ink.
                val page = source("ChatPage.kt")
                assertTrue(page.contains("private fun SendFailureLine(") || page.contains("private fun SendFailureRow(") || page.contains("SEND_FAILED"))
                assertTrue(page.contains("tokens.colors.accent"))
                setOf("colors.sessionAccent")
            }
            else -> emptySet()
        }
    }

    private fun componentCompatibility(): Map<String, Set<String>> {
        val inventory = SpecFixtures.tokens["componentCompatibility"] as? JsonObject ?: return emptyMap()
        return inventory.members.mapValues { (_, raw) ->
            ((raw as JsonObject)["tokens"] as JsonArray).values.map { (it as JsonString).value }.toSet()
        }
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
