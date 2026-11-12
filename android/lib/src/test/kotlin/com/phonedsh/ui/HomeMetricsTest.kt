// HomeSpec compatibility facade is generated from the reviewed JSON authority.
// SPDX-License-Identifier: MIT
package com.phonedsh.ui

import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.phonedsh.agentcore.JsonNumber
import com.phonedsh.agentcore.JsonObject
import com.phonedsh.ui.theme.UiTokens
import com.phonedsh.ui.theme.UiType
import com.phonedsh.ui.theme.UiTypePreferences
import com.phonedsh.ui.theme.applyPreferences
import com.phonedsh.ui.theme.generated.HomeSpecData
import com.phonedsh.ui.theme.generated.UiTokenData
import com.phonedsh.ui.theme.maxBubbleWidth
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.nio.file.Files

class HomeMetricsTest {
    private val generated: String by lazy {
        String(
            Files.readAllBytes(
                SpecFixtures.repoRoot.resolve(
                    "android/lib/build/generated/ui-tokens/kotlin/com/phonedsh/ui/theme/generated/HomeSpecData.kt",
                ),
            ),
            Charsets.UTF_8,
        )
    }

    @Test
    fun `HomeMetrics compatibility constants are emitted from JSON only`() {
        assertTrue(generated.contains("Source: spec/ui/v1/tokens.json"))
        assertFalse(generated.contains("HomeSpec.swift"))
        assertFalse(generated.contains("ios-home-design-spec"))

        val geometry = SpecFixtures.tokens["geometry"] as JsonObject
        val spacing = SpecFixtures.tokens["spacing"] as JsonObject
        val radius = SpecFixtures.tokens["radius"] as JsonObject
        assertEquals(number(geometry, "chromeInset"), HomeMetrics.CHROME_INSET_PT, 0f)
        assertEquals(number(geometry, "contentInset"), HomeMetrics.CONTENT_INSET_PT, 0f)
        assertEquals(number(spacing, "paragraphGap"), HomeMetrics.PARAGRAPH_GAP_PT, 0f)
        assertEquals(number(radius, "bubble"), HomeMetrics.BUBBLE_RADIUS_PT, 0f)
        assertEquals(number(geometry, "bubbleMaxWidthRatio"), HomeMetrics.BUBBLE_MAX_WIDTH_RATIO, 0f)
        assertEquals(312f, ChatMetrics.userBubbleMaxWidth(430f.dp, 20f.dp).value, 0f)
        assertEquals(272f, ChatMetrics.userBubbleMaxWidth(380f.dp, 20f.dp).value, 0f)
        assertEquals(312f, UiTokens.resolve(false).geometry.maxBubbleWidth(430f.dp, 20f.dp).value, 0f)
    }

    @Test
    fun `home typography resolves JSON size weight and line boxes`() {
        val type = UiType.fromSpec()
        assertEquals(UiTokenData.types.getValue("typography.navTitle").baseSize.sp, type.navTitle.fontSize)
        assertEquals(FontWeight(600), type.navTitle.fontWeight)
        assertEquals(22.sp, type.navTitle.lineHeight)
        assertEquals(14.5f.sp, type.navSubtitle.fontSize)
        assertEquals(20.sp, type.navSubtitle.lineHeight)
        // The old 17 pt body is retired: every body consumer now renders 16/24.
        assertEquals(16.sp, type.body.fontSize)
        assertEquals(24.sp, type.body.lineHeight)
        assertEquals(16.sp, type.homeBody.fontSize)
        assertEquals(24.sp, type.homeBody.lineHeight)
        assertEquals(15.sp, type.processBody.fontSize)
        assertEquals(24.sp, type.processBody.lineHeight)
        assertEquals(14.sp, type.listItem.fontSize)
        assertEquals(22.sp, type.listItem.lineHeight)
        assertEquals(16.sp, type.buttonLabel.fontSize)
        assertEquals(FontWeight(600), type.buttonLabel.fontWeight)
        assertEquals(12.sp, type.tagLabel.fontSize)
        assertEquals(FontWeight(500), type.tagLabel.fontWeight)
        assertEquals(10.5f.sp, type.tabLabel.fontSize)
        // No active home tab bar exists; HomeSpec states only the size, so the
        // line box stays platform-owned rather than an invented 14.
        assertEquals(androidx.compose.ui.unit.TextUnit.Unspecified, type.tabLabel.lineHeight)
        assertEquals(13.sp, type.terminal.fontSize)
        assertEquals(FontWeight.Normal, type.terminal.fontWeight)
        assertEquals(FontFamily.Monospace, type.terminal.fontFamily)
        assertEquals(17.sp, type.pageTitle.fontSize)
        assertEquals(FontWeight(600), type.pageTitle.fontWeight)
    }

    @Test
    fun `HomeSpec list and primary-action modifiers stay JSON sourced`() {
        val tokens = SpecFixtures.tokens
        val geometry = tokens["geometry"] as JsonObject
        assertEquals(48, HomeMetrics.DEFAULT_MIN_LIST_ROW_HEIGHT_PT.toInt())
        assertEquals(50, HomeMetrics.HOME_PRIMARY_BUTTON_HEIGHT_PT.toInt())
        assertEquals(number(geometry, "defaultMinListRowHeight"), HomeMetrics.DEFAULT_MIN_LIST_ROW_HEIGHT_PT, 0f)
        assertEquals(number(geometry, "homePrimaryButtonHeight"), HomeMetrics.HOME_PRIMARY_BUTTON_HEIGHT_PT, 0f)
        assertEquals(48f, HomeMetrics.defaultMinListRowHeight.value, 0f)
        assertEquals(50f, HomeMetrics.homePrimaryButtonHeight.value, 0f)
        assertTrue(generated.contains("const val DEFAULT_MIN_LIST_ROW_HEIGHT: Float = 48f"))
        assertTrue(generated.contains("const val HOME_PRIMARY_BUTTON_HEIGHT: Float = 50f"))
    }

    @Test
    fun `HomeSpec palette resolves from canonical JSON values`() {
        val light = UiTokens.resolve(false).colors
        val dark = UiTokens.resolve(true).colors
        assertEquals(Color(HomeSpecData.PAGE_LIGHT), light.page)
        assertEquals(Color(HomeSpecData.PAGE_DARK), dark.page)
        assertEquals(Color(HomeSpecData.TEXT_PRIMARY_LIGHT), light.textPrimary)
        assertEquals(Color(HomeSpecData.TEXT_PRIMARY_DARK), dark.textPrimary)
        assertEquals(Color(HomeSpecData.SUCCESS_LIGHT), light.homeSuccess)
        assertEquals(Color(HomeSpecData.SUCCESS_DARK), dark.homeSuccess)
        assertEquals(Color(HomeSpecData.USER_BUBBLE_LIGHT), light.userBubble)
        assertEquals(Color(HomeSpecData.BORDER_LIST_DARK), dark.borderList)
    }

    @Test
    fun `persisted text preference changes the body role but fresh defaults stay 16-24`() {
        val type = UiType.fromSpec()
        assertEquals(16.sp, type.body.fontSize)
        assertEquals(24.sp, type.body.lineHeight)
        // No stored preference is a no-op, not a silent 17 pt fallback.
        assertEquals(type, type.applyPreferences(UiTypePreferences()))
        val larger = type.applyPreferences(UiTypePreferences(textSizePt = 22f))
        assertEquals(22.sp, larger.body.fontSize)
        assertEquals(33.sp, larger.body.lineHeight)
        assertEquals(22.sp, larger.homeBody.fontSize)
        // Fixed secondary/caption roles are not user-preference roles.
        assertEquals(type.secondary, larger.secondary)
        assertEquals(type.code, larger.code)
    }

    @Test
    fun `no page source or HomeMetrics line re-types a dp or sp value`() {
        val length = Regex("""\b\d+(?:\.\d+)?\.(?:dp|sp)\b""")
        val pageDir = SpecFixtures.repoRoot.resolve("android/lib/src/main/kotlin/com/phonedsh/ui/page")
        Files.list(pageDir).use { stream ->
            stream.filter { it.fileName.toString().endsWith(".kt") }.forEach { file ->
                val found = length.findAll(String(Files.readAllBytes(file), Charsets.UTF_8))
                    .map { it.value }.toList()
                assertTrue("${file.fileName} re-types a length: $found", found.isEmpty())
            }
        }
        val metrics = String(
            Files.readAllBytes(
                SpecFixtures.repoRoot.resolve("android/lib/src/main/kotlin/com/phonedsh/ui/HomeMetrics.kt"),
            ),
            Charsets.UTF_8,
        )
        val homeFound = length.findAll(metrics).map { it.value }.toList()
        assertTrue("HomeMetrics.kt re-types a length: $homeFound", homeFound.isEmpty())
        val assignments = Regex("""=\s*[1-9][0-9]*\.?[0-9]*f""").findAll(metrics).map { it.value }.toList()
        assertTrue("HomeMetrics.kt hand-types a measured value: $assignments", assignments.isEmpty())
    }


    @Test
    fun `every HomeSpec constant is generated and re-exported exactly once`() {
        val home = String(
            Files.readAllBytes(
                SpecFixtures.repoRoot.resolve("examples/probe-app/PhoneDSHProbe/HomeSpec.swift"),
            ),
            Charsets.UTF_8,
        )
        val table = Regex("""static let (\w+): CGFloat = ([0-9.]+)""")
            .findAll(home)
            .associate { it.groupValues[1] to it.groupValues[2] }
        assertTrue("HomeSpec.swift must expose its full CGFloat table", table.size >= 30)
        val metrics = String(
            Files.readAllBytes(
                SpecFixtures.repoRoot.resolve("android/lib/src/main/kotlin/com/phonedsh/ui/HomeMetrics.kt"),
            ),
            Charsets.UTF_8,
        )
        table.forEach { (key, value) ->
            val constant = key.replace(Regex("([a-z0-9])([A-Z])"), "$1_$2").uppercase()
            val emitted = Regex("const val $constant: Float = ([0-9.]+)f")
                .find(generated)?.groupValues?.get(1)?.toFloat()
                ?: error("HomeSpecData is missing $constant = $value")
            assertEquals("HomeSpecData.$constant", value.toFloat(), emitted, 0f)
            val uses = Regex("HomeSpecData\\.$constant\\b").findAll(metrics).count()
            assertEquals("HomeMetrics must re-export $constant exactly once", 1, uses)
        }
        // The structural square corner is not a `static let`; it is still owned once.
        assertTrue(metrics.contains("BUBBLE_TOP_TRAILING_RADIUS_PT: Float = HomeSpecData.BUBBLE_TOP_TRAILING_RADIUS"))
    }

    private fun number(objectValue: JsonObject, key: String): Float {
        val value = objectValue[key]
        return when (value) {
            is JsonNumber -> value.raw.toFloat()
            is JsonObject -> (value["value"] as JsonNumber).raw.toFloat()
            else -> error("$key is not a numeric token")
        }
    }
}
