// SPDX-License-Identifier: MIT
package com.phonedsh.ui.bot.fish

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** Focused checks for the frozen geometry and the FISH-1 slice decision. */
class BotFishGeometryTest {
    @Test
    fun `pixel side and motion boost follow the size tiers`() {
        assertEquals(128, BotFishGeometry.pixelSide(64.0, 2.0))
        assertEquals(96, BotFishGeometry.pixelSide(32.0, 3.0))
        assertEquals(84, BotFishGeometry.pixelSide(28.0, 3.0))
        assertEquals(1, BotFishGeometry.pixelSide(0.0, 0.0))

        assertEquals(2.2, BotFishGeometry.motionBoost(32.0), 1e-12)
        assertEquals(1.0, BotFishGeometry.motionBoost(64.0), 1e-12)
        assertEquals(1.6, BotFishGeometry.motionBoost(52.0), 1e-12)
        assertFalse(BotFishGeometry.headSlicingEnabled(BotFishMotionProfile.STANDARD, 40.0))
        assertTrue(BotFishGeometry.headSlicingEnabled(BotFishMotionProfile.STANDARD, 41.0))
        assertTrue(BotFishGeometry.headSlicingEnabled(BotFishMotionProfile.LIVELY, 24.0))
        assertFalse(BotFishGeometry.headSlicingEnabled(BotFishMotionProfile.LIVELY, 23.0))
    }

    @Test
    fun `frame clock requests 15 20 and 30 fps`() {
        assertEquals(1000.0 / 15.0, BotFishFrameClock.intervalMilliseconds(28.0, BotFishMotionProfile.STANDARD), 1e-12)
        assertEquals(1000.0 / 15.0, BotFishFrameClock.intervalMilliseconds(40.0, BotFishMotionProfile.STANDARD), 1e-12)
        assertEquals(1000.0 / 20.0, BotFishFrameClock.intervalMilliseconds(41.0, BotFishMotionProfile.STANDARD), 1e-12)
        assertEquals(1000.0 / 30.0, BotFishFrameClock.intervalMilliseconds(96.0, BotFishMotionProfile.LIVELY), 1e-12)
    }

    /**
     * FISH-1: the signature quantiser and the displacement converter use the
     * same active quantum. A standard and a lively signature of an exact
     * multiple therefore produce the same displacement, instead of the old
     * lively 0.1 × 0.25 mismatch.
     */
    @Test
    fun `head slicing uses the active profile quantum end to end`() {
        val params = BotFishParams(headX = 1.0, headY = 1.0, hairSway = 1.0, earFlutter = 1.0)
        val standard = BotFishHeadSlicing.signature(params, true, BotFishGeometry.HEAD_SLICE_QUANTUM)
        val lively = BotFishHeadSlicing.signature(params, true, BotFishGeometry.LIVELY_HEAD_SLICE_QUANTUM)
        assertEquals(10, standard.headX)
        assertEquals(4, lively.headX)

        val standardDx = BotFishHeadSlicing.displacement(300.0, standard, BotFishGeometry.HEAD_SLICE_QUANTUM).first
        val livelyDx = BotFishHeadSlicing.displacement(300.0, lively, BotFishGeometry.LIVELY_HEAD_SLICE_QUANTUM).first
        assertEquals(standardDx, livelyDx, 1e-12)

        val standardDy = BotFishHeadSlicing.displacement(245.0, standard, BotFishGeometry.HEAD_SLICE_QUANTUM).second
        val livelyDy = BotFishHeadSlicing.displacement(245.0, lively, BotFishGeometry.LIVELY_HEAD_SLICE_QUANTUM).second
        assertEquals(standardDy, livelyDy, 1e-12)
    }

    @Test
    fun `pose quantises offsets scales roll and alpha`() {
        val params = BotFishParams(x = 2.0, y = -2.0, roll = 1.234, sx = 1.01, sy = 0.99)
        val pose = BotFishGeometry.pose(params, size = 64.0, pixelSide = 128, crowned = false)
        assertEquals(0.25, BotFishGeometry.OFFSET_QUANTUM, 0.0)
        assertEquals(1.2, pose.roll, 1e-12)
        assertEquals(0.0, (pose.scaleX * 128 / 0.5) % 1.0, 1e-9)
        assertEquals(1.0, BotFishGeometry.quantisedAlpha(1.4), 0.0)
        assertEquals(0.0, BotFishGeometry.quantisedAlpha(-0.2), 0.0)
    }
}
