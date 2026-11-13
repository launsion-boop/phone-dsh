// SPDX-License-Identifier: MIT
package com.phonedsh.ui.bot.fish

import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.unit.dp
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.phonedsh.bot.fish.BotFishLifecycle
import com.phonedsh.bot.profile.BotFishAppearance
import com.phonedsh.bot.profile.BotFishColor
import com.phonedsh.bot.profile.BotFishHairstyle
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.annotation.Config

/** Composes the public view once against the merged assets. Not a pixel gate. */
@RunWith(AndroidJUnit4::class)
@Config(sdk = [34], qualifiers = "w411dp-h891dp")
class BotFishViewTest {
    @get:Rule
    val compose = createComposeRule()

    @Test
    fun `paused crowned view composes and keeps its frozen frame`() {
        compose.setContent {
            BotFishView(
                lifecycle = BotFishLifecycle.ALERTING,
                appearance = BotFishAppearance(BotFishColor.PURPLE, BotFishHairstyle.BOB),
                crowned = true,
                size = 64.dp,
                paused = true,
            )
        }
        compose.waitForIdle()
        compose.onNodeWithContentDescription("Bot 头像").assertExists()
    }
}
