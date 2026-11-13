// SPDX-License-Identifier: MIT
package com.phonedsh.ui.bot.fish

import android.content.Context
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.phonedsh.bot.profile.BotFishAppearance
import com.phonedsh.bot.profile.BotFishColor
import com.phonedsh.bot.profile.BotFishHairstyle
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.annotation.Config

/**
 * Runtime smoke test for the Android layer renderer against the merged AAR
 * assets: tinted body, crowned base, expressive face and the lively head-slice
 * path all have to decode. This is not a pixel-parity gate.
 */
@RunWith(AndroidJUnit4::class)
@Config(sdk = [34])
class BotFishRendererTest {
    @Test
    fun `renderer decodes tinted crowned face and lively slice layers`() {
        val context = ApplicationProvider.getApplicationContext<Context>()
        val renderer = BotFishRenderer(context.assets)
        val appearance = BotFishAppearance(BotFishColor.SKY, BotFishHairstyle.TWIN_TAIL)
        val params = BotFishParams(
            blush = 0.5,
            eyeArt = "excited",
            mouthArt = "smile",
            mouth = 0.4,
            decoration = "dots",
            phase = 0.125,
            headX = 1.0,
            headY = 1.0,
            hairSway = 1.0,
            earFlutter = 1.0,
        )
        val frame = BotFishFrame(
            timeMs = 0.0,
            params = params,
            pose = BotFishPose(),
            alpha = 1.0,
            needsAnimation = true,
            pixelSide = 192,
            viewMotionScale = 1.0,
        )

        val layers = renderer.render(
            frame = frame,
            sizePt = 96.0,
            displayScale = 2.0,
            appearance = appearance,
            crowned = true,
            profile = BotFishMotionProfile.LIVELY,
        )
        assertNotNull("renderer returned no layers", layers)
        assertEquals(192, layers!!.base.width)
        assertEquals(192, layers.base.height)
        assertEquals(192, layers.face.width)
        assertEquals(192, layers.face.height)

        // The standard quantum takes the same path; both cache keys include
        // the active quantum, so a profile flip cannot reuse the other slice.
        val standard = renderer.render(
            frame = frame,
            sizePt = 96.0,
            displayScale = 2.0,
            appearance = appearance,
            crowned = true,
            profile = BotFishMotionProfile.STANDARD,
        )
        assertNotNull("standard slice path returned no layers", standard)
        assertEquals(192, standard!!.base.width)
    }
}
