// BotAppearancePicker: the fixture appearance, the 4 x 15 matrix, selection
// semantics and the emitted `BotAppearanceIntent`.
// SPDX-License-Identifier: MIT
//
// The appearance comes from `spec/ui/v1/bot/golden/fixtures.json`'s
// `infoAppearance` scenario; the 4 hairstyles and 15 colours are the `:bot`
// value enums, so a copy change reaches this test.
package com.phonedsh.ui.bot.page.appearance

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.size
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.test.assertCountEquals
import androidx.compose.ui.test.hasScrollAction
import androidx.compose.ui.test.assertIsSelected
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onAllNodesWithTag
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollToIndex
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.phonedsh.bot.fish.BotFishLifecycle
import com.phonedsh.bot.profile.BotFishAppearance
import com.phonedsh.bot.profile.BotFishColor
import com.phonedsh.bot.profile.BotFishHairstyle
import com.phonedsh.ui.bot.page.BotFishSlot
import com.phonedsh.ui.bot.page.drawer.BotPageFixtures
import com.phonedsh.ui.bot.state.BotAppearanceIntent
import com.phonedsh.ui.theme.PdshTheme
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.annotation.Config

@RunWith(AndroidJUnit4::class)
@Config(sdk = [34], qualifiers = "w411dp-h640dp")
class BotAppearancePickerTest {
    @get:Rule
    val compose = createComposeRule()

    private val intents = mutableListOf<BotAppearanceIntent>()

    private val fish: BotFishSlot = { _, _, _, size, _, modifier ->
        Box(modifier.size(size).testTag(FISH))
    }

    private fun show(
        appearance: BotFishAppearance,
        showsPreview: Boolean = false,
    ) {
        compose.setContent {
            PdshTheme {
                BotAppearancePicker(
                    appearance = appearance,
                    onIntent = { intents += it },
                    fish = fish,
                    showsPreview = showsPreview,
                )
            }
        }
    }

    @Test
    fun `renders four hairstyles and fifteen colours with the fixture selection`() {
        val appearance = BotPageFixtures.fixtureAppearance()
        show(appearance)

        BotFishHairstyle.entries.forEach { hairstyle ->
            compose.onNodeWithTag(
                BotAppearanceTags.hair(BotAppearanceTags.INFO_PREFIX, hairstyle.wire),
            ).assertExists()
        }
        // The colour row is a LazyRow: each swatch is asserted after scrolling
        // it into the composed window (the hairstyle row is a plain Row).
        val colours = compose.onNode(hasScrollAction())
        BotFishColor.entries.forEachIndexed { index, color ->
            colours.performScrollToIndex(index)
            compose.onNodeWithTag(
                BotAppearanceTags.color(BotAppearanceTags.INFO_PREFIX, color.wire),
            ).assertExists()
        }
        compose.onNodeWithTag(
            BotAppearanceTags.hair(
                BotAppearanceTags.INFO_PREFIX,
                appearance.hairstyle.wire,
            ),
        ).assertIsSelected()
        colours.performScrollToIndex(BotFishColor.entries.indexOf(appearance.color))
        compose.onNodeWithTag(
            BotAppearanceTags.color(
                BotAppearanceTags.INFO_PREFIX,
                appearance.color.wire,
            ),
        ).assertIsSelected()
        // Selectable thumbnails merge their descendants; the fish tag is only
        // visible in the unmerged tree.
        compose.onAllNodesWithTag(FISH, useUnmergedTree = true)
            .assertCountEquals(BotFishHairstyle.entries.size)
    }

    @Test
    fun `a colour tap emits SelectColor`() {
        show(BotPageFixtures.fixtureAppearance())

        compose.onNodeWithTag(
            BotAppearanceTags.color(BotAppearanceTags.INFO_PREFIX, BotFishColor.BLUE.wire),
        ).performClick()

        assertEquals(
            BotAppearanceIntent.SelectColor(BotFishColor.BLUE),
            intents.single(),
        )
    }

    @Test
    fun `a hairstyle tap emits SelectHairstyle`() {
        show(BotPageFixtures.fixtureAppearance())

        compose.onNodeWithTag(
            BotAppearanceTags.hair(BotAppearanceTags.INFO_PREFIX, BotFishHairstyle.BOB.wire),
        ).performClick()

        assertEquals(
            BotAppearanceIntent.SelectHairstyle(BotFishHairstyle.BOB),
            intents.single(),
        )
    }

    @Test
    fun `showsPreview draws the live preview through the fish slot`() {
        val appearance = BotPageFixtures.fixtureAppearance()
        show(appearance, showsPreview = true)

        // Four still thumbnails plus the one preview.
        compose.onAllNodesWithTag(FISH, useUnmergedTree = true)
            .assertCountEquals(BotFishHairstyle.entries.size + 1)
        compose.onNodeWithContentDescription(
            BotAppearanceCopy.previewLabel(
                appearance.color.displayName,
                appearance.hairstyle.displayName,
            ),
        ).assertExists()
    }

    @Test
    fun `the add dialog prefix is a different id namespace`() {
        assertEquals("bot.add.appearance.hair.long", BotAppearanceTags.hair(BotAppearanceTags.ADD_PREFIX, "long"))
        assertEquals("bot.info.appearance.color.blue", BotAppearanceTags.color(BotAppearanceTags.INFO_PREFIX, "blue"))
    }

    private companion object {
        private const val FISH = "test.appearance.fish"

        @Suppress("unused")
        private val lifecycle = BotFishLifecycle.IDLE
    }
}
