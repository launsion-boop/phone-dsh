// Tests exercise real Compose ImageVector rendering semantics, not source grep or PixelCopy.
// SPDX-License-Identifier: MIT
package com.phonedsh.ui.icon

import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.vector.VectorPath
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.test.assertContentDescriptionEquals
import androidx.compose.ui.test.assertHeightIsEqualTo
import androidx.compose.ui.test.assertWidthIsEqualTo
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.unit.dp
import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.annotation.Config

@RunWith(AndroidJUnit4::class)
@Config(sdk = [34])
class PdshIconsTest {
    @get:Rule
    val compose = createComposeRule()

    @Test
    fun `icon composes with caller size tint and semantic description`() {
        val tint = Color(0xFF7D5CFF)
        compose.setContent {
            PdshIconView(
                icon = PdshIcon.NEW_CHAT,
                size = 31.dp,
                tint = tint,
                contentDescription = "New chat",
                modifier = Modifier.testTag("pdsh.icon.new-chat"),
            )
        }

        compose.onNodeWithTag("pdsh.icon.new-chat")
            .assertExists()
            .assertContentDescriptionEquals("New chat")
            .assertWidthIsEqualTo(31.dp)
            .assertHeightIsEqualTo(31.dp)

        val paths = PdshIcons.vector(PdshIcon.NEW_CHAT, tint).root.toList().filterIsInstance<VectorPath>()
        assertTrue(paths.isNotEmpty())
        assertTrue(paths.any { ((it.stroke ?: it.fill) as? SolidColor)?.value == tint })
    }

    @Test
    fun `every registered symbol has distinct nonempty vector geometry`() {
        val icons = PdshIcon.values()
        assertTrue("registry should cover the HomeSpec and settings symbol set", icons.size >= 35)
        val unsourcedFallbacks = icons.filter { it.sourceOwner == null }.map { "${it.sfSymbol}@${it.sourceWeight?.weight ?: "default"}" }
        assertEquals("SF-only entries have distinct symbol and explicit-weight owners", unsourcedFallbacks.size, unsourcedFallbacks.toSet().size)
        val sourceIds = icons.mapNotNull { it.sourceOwner }
        assertEquals("asset source IDs are distinct", sourceIds.size, sourceIds.toSet().size)
        val owners = icons.map { it.sourceOwner ?: "sf:${it.sfSymbol}@${it.sourceWeight?.weight ?: "default"}" }
        assertEquals("each entry has a unique source owner or SF fallback", owners.size, owners.toSet().size)
        val signatures = icons.map { icon ->
            val vector = PdshIcons.vector(icon, Color.Black)
            val paths = vector.root.toList().filterIsInstance<VectorPath>()
            assertTrue("${icon.sfSymbol} has no vector paths", paths.isNotEmpty())
            paths.joinToString("|") { path -> path.pathData.joinToString(";") }
        }
        assertEquals("each symbol has its own path set", signatures.size, signatures.toSet().size)
    }

    @Test
    fun `microphone symbol is marked permission only`() {
        assertTrue(PdshIcon.MICROPHONE_PERMISSION.permissionOnly)
        assertFalse(PdshIcon.NEW_CHAT.permissionOnly)
    }

    @Test
    fun `settings permission engine and runtime use their actual PR22 symbols`() {
        assertEquals("doc.on.doc", PdshIcon.COPY.sfSymbol)
        assertEquals("text.alignleft", PdshIcon.TEXT_ALIGN_LEFT.sfSymbol)
        assertEquals("arrow.left.and.right", PdshIcon.ARROW_LEFT_RIGHT.sfSymbol)
        assertEquals("hand.raised", PdshIcon.HAND.sfSymbol)
        assertEquals("bolt.horizontal", PdshIcon.BOLT.sfSymbol)
        assertEquals("waveform.path.ecg", PdshIcon.WAVEFORM.sfSymbol)
    }

    @Test
    fun `message atom assets have explicit owner IDs and their own tinted vector paths`() {
        val expectedOwners = mapOf(
            PdshIcon.THINK to "Assets.xcassets/DSHThink.imageset/DSHThink.svg",
            PdshIcon.READ to "Assets.xcassets/DSHRead.imageset/DSHRead.svg",
            PdshIcon.EDIT to "Assets.xcassets/DSHEdit.imageset/DSHEdit.svg",
            PdshIcon.CODE to "Assets.xcassets/DSHCode.imageset/DSHCode.svg",
            PdshIcon.SEARCH to "Assets.xcassets/DSHSearch.imageset/DSHSearch.svg",
            PdshIcon.TERMINAL to "Assets.xcassets/DSHTerminal.imageset/DSHTerminal.svg",
            PdshIcon.SPARKLE to "Assets.xcassets/DSHSparkle.imageset/DSHSparkle.svg",
            PdshIcon.BRANCH to "Assets.xcassets/DSHBranch.imageset/DSHBranch.svg",
            PdshIcon.DATABASE to "Assets.xcassets/DSHDatabase.imageset/DSHDatabase.svg",
            PdshIcon.GAUGE to "Assets.xcassets/DSHGauge.imageset/DSHGauge.svg",
        )
        expectedOwners.forEach { (icon, owner) ->
            assertEquals(icon.name, owner, icon.sourceOwner)
            val vectorPaths = PdshIcons.vector(icon, Color(0xFF287A63)).root
                .toList().filterIsInstance<VectorPath>()
            assertTrue("${icon.name} renders its source asset paths", vectorPaths.isNotEmpty())
            assertTrue(
                "${icon.name} uses the caller tint",
                vectorPaths.any { ((it.stroke ?: it.fill) as? SolidColor)?.value == Color(0xFF287A63) },
            )
        }
        assertEquals("brain.head.profile", PdshIcon.THINK.sfSymbol)
    }

    @Test
    fun `thinking atom composes at its caller size with the source-backed vector`() {
        val tint = Color(0xFF287A63)
        compose.setContent {
            PdshIconView(
                icon = PdshIcon.THINK,
                size = 18.dp,
                tint = tint,
                contentDescription = "思考",
                modifier = Modifier.testTag("pdsh.icon.think"),
            )
        }
        compose.onNodeWithTag("pdsh.icon.think")
            .assertExists()
            .assertContentDescriptionEquals("思考")
            .assertWidthIsEqualTo(18.dp)
            .assertHeightIsEqualTo(18.dp)
        val paths = PdshIcons.vector(PdshIcon.THINK, tint).root.toList().filterIsInstance<VectorPath>()
        assertEquals(3, paths.size)
        assertTrue(paths.any { it.fill is SolidColor })
    }
}
