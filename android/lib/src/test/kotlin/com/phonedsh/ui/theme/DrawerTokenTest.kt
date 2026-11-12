// The generated interaction.drawer table equals spec/ui/v1/tokens.json.
// SPDX-License-Identifier: MIT
package com.phonedsh.ui.theme

import com.phonedsh.agentcore.JsonNumber
import com.phonedsh.agentcore.JsonObject
import com.phonedsh.agentcore.JsonString
import com.phonedsh.ui.SessionsMetrics
import com.phonedsh.ui.SpecFixtures
import com.phonedsh.ui.theme.generated.UiTokenData
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class DrawerTokenTest {
    private val tokens: JsonObject = SpecFixtures.tokens
    private val drawer: JsonObject =
        ((tokens["interaction"] as JsonObject)["drawer"] as JsonObject)

    @Test
    fun `drawer token references resolve to the generated token objects`() {
        assertEquals(reference("width"), UiTokenData.drawer.width.name)
        assertEquals(reference("panelTrailingRadius"), UiTokenData.drawer.panelTrailingRadius.name)
        assertEquals(reference("shadow"), UiTokenData.drawer.shadow.name)
        assertEquals(reference("openMotion"), UiTokenData.drawer.openMotion.name)
        assertEquals(reference("closeMotion"), UiTokenData.drawer.closeMotion.name)
        assertEquals(reference("settleMotion"), UiTokenData.drawer.settleMotion.name)

        assertEquals(UiTokenData.geometry.getValue(reference("width")), UiTokenData.drawer.width)
        assertEquals(UiTokenData.radius.getValue(reference("panelTrailingRadius")), UiTokenData.drawer.panelTrailingRadius)
        assertEquals(UiTokenData.shadows.getValue(reference("shadow")), UiTokenData.drawer.shadow)
        assertEquals(UiTokenData.motion.getValue(reference("openMotion")), UiTokenData.drawer.openMotion)
        assertEquals(UiTokenData.motion.getValue(reference("closeMotion")), UiTokenData.drawer.closeMotion)
        assertEquals(UiTokenData.motion.getValue(reference("settleMotion")), UiTokenData.drawer.settleMotion)
    }

    @Test
    fun `drawer parameters equal the JSON values`() {
        assertEquals(number("closedOverhang", "value"), UiTokenData.drawer.closedOverhangPt, 0f)
        assertEquals(number("scrimMaxOpacity", "value"), UiTokenData.drawer.scrimMaxOpacity, 0f)
        assertEquals(number("dragMinimumDistance", "value"), UiTokenData.drawer.dragMinimumDistancePt, 0f)
        assertEquals(number("closeThreshold", "value"), UiTokenData.drawer.closeThresholdFraction, 0f)
        assertEquals(number("velocityProjection", "value"), UiTokenData.drawer.velocityProjectionSeconds, 0f)
    }

    @Test
    fun `shadows expose x with a zero default and the drawer role`() {
        val shadows = tokens["shadows"] as JsonObject
        shadows.members.forEach { (key, raw) ->
            val entry = raw as JsonObject
            val generated = UiTokenData.shadows.getValue("shadows.$key")
            assertEquals("shadows.$key opacity", (entry["opacity"] as JsonNumber).raw.toFloat(), generated.opacity, 0f)
            assertEquals("shadows.$key radius", (entry["radius"] as JsonNumber).raw.toFloat(), generated.radius, 0f)
            assertEquals(
                "shadows.$key x defaults to 0",
                (entry["x"] as? JsonNumber)?.raw?.toFloat() ?: 0f,
                generated.x,
                0f,
            )
            assertEquals("shadows.$key y", (entry["y"] as JsonNumber).raw.toFloat(), generated.y, 0f)
        }
        assertTrue("shadows.drawer must be generated", "shadows.drawer" in UiTokenData.shadows)
        assertEquals("shadows.drawer", UiTokenData.drawer.shadow.name)
    }

    @Test
    fun `SessionsMetrics drawer constants are projections of the generated tokens`() {
        assertEquals(UiTokenData.drawer.width.value.toInt(), SessionsMetrics.DRAWER_WIDTH_PT)
        assertEquals(UiTokenData.drawer.panelTrailingRadius.value.toInt(), SessionsMetrics.DRAWER_PANEL_RADIUS_PT)
        assertEquals(UiTokenData.drawer.scrimMaxOpacity, SessionsMetrics.DRAWER_SCRIM_ALPHA, 0f)
        assertEquals(UiTokenData.drawer.width.value, SessionsMetrics.drawerWidth.value, 0f)
    }

    @Test
    fun `drawer motion comes through the generic motion path`() {
        val motion = tokens["motion"] as JsonObject
        for (name in listOf("drawerOpen", "drawerClose")) {
            val entry = motion[name] as JsonObject
            val generated = UiTokenData.motion.getValue("motion.$name")
            assertEquals("motion.$name duration", (entry["durationMs"] as JsonNumber).raw.toInt(), generated.durationMs)
            assertEquals("motion.$name curve", (entry["curve"] as JsonString).value, generated.curve)
            assertEquals("motion.$name repeat", (entry["repeat"] as JsonString).value, generated.repeat)
        }
    }

    private fun reference(key: String): String =
        ((drawer[key] as JsonObject)["token"] as JsonString).value

    private fun number(key: String, field: String): Float =
        ((drawer[key] as JsonObject)[field] as JsonNumber).raw.toFloat()
}
