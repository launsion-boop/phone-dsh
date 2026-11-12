// Geometry ownership: every token is surface-owned, page-shared or HomeSpec-owned.
// SPDX-License-Identifier: MIT
//
// `spec/ui/v1/tokens.json` has three kinds of geometry:
//   * signature-surface geometry, listed in `signatureSurfaces.*.tokens`;
//   * active component compatibility geometry, declared by the surface source
//     inventory (and mirrored in `componentCompatibility`);
//   * HomeSpec page geometry owned by `HomeMetrics` (its explicit CGFloat table
//     plus the three source-anchored structural/action values);
//   * geometry referenced by a contract table such as `interaction.drawer`
//     (the drawer width is owned by the interaction, not by a page or surface).
//
// A geometry token with none of those owners is an orphan: a page-private length
// that leaked into the spec, or a surface token whose surface forgot it.
package com.phonedsh.ui.page

import com.phonedsh.agentcore.JsonNull
import com.phonedsh.agentcore.JsonNumber
import com.phonedsh.agentcore.JsonObject
import com.phonedsh.agentcore.JsonString
import com.phonedsh.ui.SpecFixtures
import com.phonedsh.ui.surface.ApprovalCardTokens
import com.phonedsh.ui.surface.BubbleTokens
import com.phonedsh.ui.surface.ComposerTokens
import com.phonedsh.ui.surface.FailLoudBannerTokens
import com.phonedsh.ui.surface.ThinkingPillTokens
import com.phonedsh.ui.surface.ToolRowTokens
import com.phonedsh.ui.surfaces
import com.phonedsh.ui.text
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.nio.file.Files

class PageGeometryTokenTest {
    @Test
    fun `every geometry token is surface-owned or used by at least two pages`() {
        val geometry = SpecFixtures.tokens["geometry"] as JsonObject
        val geometryNames = geometry.members.keys.map { "geometry.$it" }.toSet()
        val signatureTokens = SpecFixtures.surfaces().associate { surface ->
            surface.id to surface.tokens.map(::canonicalToken).toSet()
        }
        val activeSurfaceReads = componentSurfaceReads()
        val surfaceGeometry = (signatureTokens.values.flatten() + activeSurfaceReads.values.flatten())
            .filter { it.startsWith("geometry.") }
            .toSet()
        val interactionGeometry = drawerInteractionGeometry()
        assertEquals(
            "a signature surface declares geometry that tokens.json does not define",
            emptySet<String>(),
            surfaceGeometry - geometryNames,
        )
        val pageLevel = geometryNames - surfaceGeometry
        assertTrue(
            "tokens.json has no page-level geometry token; this test would be vacuous",
            pageLevel.isNotEmpty(),
        )
        val sources = pageSources()
        val homeOwned = homeSpecNumbers().keys + verifiedHomeSpecGeometry(geometry)
        geometryNames.sorted().forEach { token ->
            val users = sources.filterValues { source ->
                PAGE_TOKEN_REF.findAll(source).any {
                    canonicalToken("${it.groupValues[1]}.${it.groupValues[2]}") == token
                }
            }.keys.sorted()
            val homeLength = token.removePrefix("geometry.") in homeOwned
            assertTrue(
                "$token is an orphan geometry token: no signature/compatibility surface owns it and " +
                    "only ${users.size} page(s) $users read it. Every geometry token must be " +
                    "surface-owned, contract-owned, used by at least 2 pages, or a PR22 HomeSpec length owned by " +
                    "`HomeMetrics`; a one-page length keeps reusing a declared token with the " +
                    "`unverified geometry` marker instead of entering the spec.",
                token in surfaceGeometry || token in interactionGeometry || users.size >= 2 || homeLength,
            )
        }
        // Every page-level length is a fixed point value; only a signature
        // surface may derive a screen ratio.
        pageLevel.sorted().forEach { token ->
            val entry = geometry.members.getValue(token.removePrefix("geometry.")) as JsonObject
            assertEquals("$token is page-level and must be a pt length", "pt", entry.text("unit"))
            assertTrue(
                "$token is page-level and must be a fixed length (scalesWith: null)",
                entry["scalesWith"] is JsonNull,
            )
        }
    }

    /** Geometry referenced by `interaction.drawer`, the contract that owns it. */
    private fun drawerInteractionGeometry(): Set<String> {
        val interaction = SpecFixtures.tokens["interaction"] as? JsonObject ?: return emptySet()
        val drawer = interaction["drawer"] as? JsonObject ?: return emptySet()
        return drawer.members.values.mapNotNull { raw ->
            ((raw as? JsonObject)?.get("token") as? JsonString)?.value
        }.filter { it.startsWith("geometry.") }.toSet()
    }

    @Test
    fun `PR22 HomeSpec lengths agree with tokens json when it declares them`() {
        val home = homeSpecNumbers()
        assertTrue("HomeSpec.swift must expose its grid/size/radius table", home.size >= 30)
        val generated = String(
            Files.readAllBytes(
                SpecFixtures.repoRoot.resolve(
                    "android/lib/build/generated/ui-tokens/kotlin/com/phonedsh/ui/theme/generated/HomeSpecData.kt",
                ),
            ),
            Charsets.UTF_8,
        )
        val geometry = SpecFixtures.tokens["geometry"] as JsonObject
        home.forEach { (key, value) ->
            val emitted = Regex(
                "const val ${upperSnake(key)}: Float = ([0-9.]+)f",
            ).find(generated)?.groupValues?.get(1)?.toFloat()
                ?: error("HomeSpecData has no generated ${upperSnake(key)}")
            assertEquals("HomeSpecData.${upperSnake(key)}", value, emitted, 0f)
            val declared = geometry.members[key] as? JsonObject ?: return@forEach
            assertEquals("geometry.$key unit", "pt", declared.text("unit"))
            assertEquals(
                "geometry.$key value must equal HomeSpec.${key}",
                value,
                (declared["value"] as JsonNumber).raw.toFloat(),
                0f,
            )
        }
    }

    /** The only HomeSpec geometry outside its explicit CGFloat table has source-anchored owner cases. */
    private fun verifiedHomeSpecGeometry(geometry: JsonObject): Set<String> {
        val homeSource = String(
            Files.readAllBytes(SpecFixtures.repoRoot.resolve("examples/probe-app/PhoneDSHProbe/HomeSpec.swift")),
            Charsets.UTF_8,
        )
        val homeMetrics = homeMetricsSource()
        val cases = listOf(
            HomeGeometryOwner("bubbleTopTrailingRadius", 0f, "topTrailingRadius: 0", "BUBBLE_TOP_TRAILING_RADIUS_PT"),
            HomeGeometryOwner("defaultMinListRowHeight", 48f, "defaultMinListRowHeight, 48", "DEFAULT_MIN_LIST_ROW_HEIGHT_PT"),
            HomeGeometryOwner("homePrimaryButtonHeight", 50f, "frame(height: 50)", "HOME_PRIMARY_BUTTON_HEIGHT_PT"),
        )
        return cases.mapNotNull { owner ->
            val entry = geometry.members[owner.key] as? JsonObject ?: return@mapNotNull null
            val value = (entry["value"] as? JsonNumber)?.raw?.toFloat() ?: return@mapNotNull null
            if (entry.text("unit") == "pt" && value == owner.value &&
                homeSource.contains(owner.swiftAnchor) && homeMetrics.contains(owner.metricsOwner)
            ) owner.key else null
        }.toSet()
    }

    private data class HomeGeometryOwner(
        val key: String,
        val value: Float,
        val swiftAnchor: String,
        val metricsOwner: String,
    )

    /** Resolves generated compatibility spellings through the JSON canonical map. */
    private fun canonicalToken(token: String): String {
        val family = token.substringBefore('.')
        val leaf = token.substringAfter('.', missingDelimiterValue = "")
        val aliases = (SpecFixtures.tokens["aliases"] as? JsonObject)?.get(family) as? JsonObject
            ?: return token
        return (aliases[leaf] as? JsonString)?.value ?: token
    }

    /** Actual Android surface source inventories, already resolved through generated UiTokenNames. */
    private fun componentSurfaceReads(): Map<String, Set<String>> = mapOf(
        "bubble" to BubbleTokens.refs.toSet(),
        "toolRow" to ToolRowTokens.refs.toSet(),
        "thinkingPill" to ThinkingPillTokens.refs.toSet(),
        "approvalCard" to (ApprovalCardTokens.declared + ApprovalCardTokens.gaps).toSet(),
        "composer" to (ComposerTokens.declared + ComposerTokens.gaps).toSet(),
        "failLoudBanner" to FailLoudBannerTokens.refs.toSet(),
    )

    /** The `static let ...: CGFloat` table from HomeSpec.swift, keyed by its Swift name. */
    private fun homeSpecNumbers(): Map<String, Float> {
        val source = String(
            Files.readAllBytes(
                SpecFixtures.repoRoot.resolve("examples/probe-app/PhoneDSHProbe/HomeSpec.swift"),
            ),
            Charsets.UTF_8,
        )
        return Regex("""static let (\w+): CGFloat = ([0-9.]+)""")
            .findAll(source)
            .associate { it.groupValues[1] to it.groupValues[2].toFloat() }
    }

    private fun upperSnake(name: String): String =
        name.replace(Regex("([a-z0-9])([A-Z])"), "$1_$2").uppercase()

    private fun homeMetricsSource(): String = String(
        Files.readAllBytes(SpecFixtures.repoRoot.resolve("android/lib/src/main/kotlin/com/phonedsh/ui/HomeMetrics.kt")),
        Charsets.UTF_8,
    )

    /** Every `.kt` file under the page package, keyed by file name. */
    private fun pageSources(): Map<String, String> {
        val dir = SpecFixtures.repoRoot.resolve("android/lib/src/main/kotlin/com/phonedsh/ui/page")
        return Files.list(dir).use { stream ->
            stream.filter { it.fileName.toString().endsWith(".kt") }
                .sorted()
                .toList()
                .associate { it.fileName.toString() to String(Files.readAllBytes(it), Charsets.UTF_8) }
        }
    }

    private companion object {
        val PAGE_TOKEN_REF: Regex = Regex("""tokens\.(colors|spacing|radius|stroke|motion|geometry)\.([A-Za-z0-9_]+)""")
    }
}
