// Drawer easing and duration exposure, with no linear fallback.
// SPDX-License-Identifier: MIT
package com.phonedsh.ui.theme

import androidx.compose.animation.core.CubicBezierEasing
import com.phonedsh.ui.theme.generated.UiTokenData
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

class DrawerEasingTest {
    private val motion = UiTokens.resolve(dark = false).motion

    @Test
    fun `easeInOut uses the Core Animation control points`() {
        val easing = motion.easing(UiMotion.EASE_IN_OUT)
        assertTrue("easeInOut must be a cubic bezier", easing is CubicBezierEasing)
        assertEquals(listOf(0.42f, 0f, 0.58f, 1f), controlPoints(easing))
    }

    @Test
    fun `drawer open close and settle read their generated motion tokens`() {
        assertEquals(280, motion.drawerOpenMs)
        assertEquals(UiMotion.EASE_IN_OUT, motion.drawerOpenCurve)
        assertEquals(220, motion.drawerCloseMs)
        assertEquals(UiMotion.EASE_IN_OUT, motion.drawerCloseCurve)
        assertEquals(220, motion.drawerSettleMs)
        assertEquals(UiMotion.EASE_IN_OUT, motion.drawerSettleCurve)
        assertEquals(UiTokenData.drawer.openMotion.durationMs, motion.drawerOpenMs)
        assertEquals(UiTokenData.drawer.closeMotion.durationMs, motion.drawerCloseMs)
        assertEquals(UiTokenData.drawer.settleMotion.durationMs, motion.drawerSettleMs)
        assertEquals(listOf(0.42f, 0f, 0.58f, 1f), controlPoints(motion.drawerOpenEasing))
        assertEquals(listOf(0.42f, 0f, 0.58f, 1f), controlPoints(motion.drawerCloseEasing))
        assertEquals(listOf(0.42f, 0f, 0.58f, 1f), controlPoints(motion.drawerSettleEasing))
    }

    @Test
    fun `an unknown curve fails instead of falling back to linear`() {
        try {
            motion.easing("spring")
            fail("unknown curve 'spring' must throw")
        } catch (expected: IllegalStateException) {
            assertTrue(expected.message.orEmpty().contains("unknown motion curve"))
        }
    }

    /**
     * `CubicBezierEasing` exposes no control-point getter; read the four
     * constructor fields so the assertion is about the curve, not a sample.
     */
    private fun controlPoints(easing: androidx.compose.animation.core.Easing): List<Float> =
        listOf("a", "b", "c", "d").map { name ->
            easing.javaClass.getDeclaredField(name).apply { isAccessible = true }.getFloat(easing)
        }
}
