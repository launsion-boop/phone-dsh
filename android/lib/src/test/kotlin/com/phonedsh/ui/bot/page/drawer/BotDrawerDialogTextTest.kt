// SPDX-License-Identifier: MIT
// The Bot drawer's two editable dialogs. They live in their own class because a
// platform `Dialog` holding an editable `BasicTextField` starts a cursor/idle
// loop once the drawer-animation tests have run in the same Robolectric
// sandbox; a fresh class keeps the editor wiring covered. The name cap and trim
// themselves are pure rules covered by BotDrawerTest's model-layer assertions.
// SPDX-License-Identifier: MIT
package com.phonedsh.ui.bot.page.drawer

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.size
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.longClick
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performTextReplacement
import androidx.compose.ui.test.performTouchInput
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.phonedsh.bot.profile.BotFishColor
import com.phonedsh.bot.profile.BotFishHairstyle
import com.phonedsh.ui.bot.state.BotDrawerIntent
import com.phonedsh.ui.bot.state.BotRosterEntry
import com.phonedsh.ui.bot.state.BotUiStrings
import com.phonedsh.ui.theme.PdshTheme
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

@RunWith(AndroidJUnit4::class)
@Config(sdk = [34], qualifiers = "w411dp-h640dp")
@GraphicsMode(GraphicsMode.Mode.NATIVE)
class BotDrawerDialogTextTest {
    @get:Rule
    val compose = createComposeRule()

    private val intents = mutableListOf<BotDrawerIntent>()

    private fun show(entries: List<BotRosterEntry>) {
        compose.setContent {
            PdshTheme {
                BotDrawer(
                    entries = entries,
                    selection = null,
                    onIntent = { intents += it },
                    fish = { _, _, _, size, _, modifier -> Box(modifier.size(size)) },
                    now = BotPageFixtures.pinnedNow,
                    onClose = {},
                )
            }
        }
        compose.waitForIdle()
    }

    private fun openRowMenu(botID: String) {
        compose.onNodeWithTag(BotDrawerTags.row(botID)).performTouchInput { longClick() }
        compose.waitForIdle()
    }

    private fun chooseMenu(label: String) {
        compose.onNodeWithText(label).performClick()
        compose.waitForIdle()
    }

    @Test
    fun `add dialog caps a typed name at 60 units and emits create with the defaults`() {
        show(listOf(BotPageFixtures.rosterEntry()))

        compose.onNodeWithTag(BotDrawerTags.ADD).performClick()
        compose.onNodeWithTag(BotDrawerTags.ADD_NAME).performTextReplacement("名".repeat(61))
        compose.onNodeWithTag(BotDrawerTags.ADD_CREATE).performClick()

        val create = intents.filterIsInstance<BotDrawerIntent.Create>().single()
        assertEquals(60, create.name.length)
        assertEquals(BotFishColor.BLUE, create.color)
        assertEquals(BotFishHairstyle.LONG, create.hairstyle)
    }

    @Test
    fun `rename dialog opens with the Bot's name and save emits the rename`() {
        val main = BotPageFixtures.rosterEntry()
        val second = main.copy(id = "second", name = "第二 Bot", isMainBot = false, unreadCount = 0)
        show(listOf(main, second))

        openRowMenu("second")
        chooseMenu(BotUiStrings.DRAWER_MENU_RENAME)
        // A platform Dialog's window is not "displayed" in the Robolectric
        // root; the add-dialog test uses the same existence check.
        compose.onNodeWithTag(BotDrawerTags.RENAME_PANEL, useUnmergedTree = true)
            .assertExists()
        compose.onNodeWithTag(BotDrawerTags.RENAME_FIELD, useUnmergedTree = true)
            .assertExists()
        compose.onNodeWithTag(BotDrawerTags.RENAME_SAVE, useUnmergedTree = true)
            .performClick()
        compose.waitForIdle()

        assertEquals(
            BotDrawerIntent.Rename("second", "第二 Bot"),
            intents.filterIsInstance<BotDrawerIntent.Rename>().single(),
        )
    }

}
