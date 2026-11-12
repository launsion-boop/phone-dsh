// BotDrawer: roster order, status/unread, rename validation, last-Bot guard and
// the shared context-menu actions, driven by the shared JSON vectors.
// SPDX-License-Identifier: MIT
//
// Every test renders the real `BotDrawer`; roster entries come from
// `spec/ui/v1/bot/golden/value-vectors.json`, and the status/unread cases come
// from `spec/ui/v1/bot/golden/ui-state-vectors.json`. No vector is copied here.
package com.phonedsh.ui.bot.page.drawer

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.size
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import com.phonedsh.agentcore.JsonObject
import com.phonedsh.agentcore.JsonString
import androidx.compose.ui.test.assertCountEquals
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.getUnclippedBoundsInRoot
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.longClick
import androidx.compose.ui.test.onAllNodesWithTag
import androidx.compose.ui.test.onAllNodesWithText
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onRoot
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.click
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performSemanticsAction
import androidx.compose.ui.test.performTextClearance
import androidx.compose.ui.test.performTextReplacement
import androidx.compose.ui.test.performTouchInput
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.phonedsh.bot.profile.BotFishColor
import com.phonedsh.bot.profile.BotFishHairstyle
import com.phonedsh.ui.bot.page.BotFishSlot
import com.phonedsh.ui.bot.state.BotDrawerIntent
import com.phonedsh.ui.bot.state.BotDrawerStatusColor
import com.phonedsh.ui.bot.state.BotNameValidation
import com.phonedsh.ui.bot.state.BotRosterEntry
import com.phonedsh.ui.bot.state.BotRosterRuntimeState
import com.phonedsh.ui.bot.state.BotUiContext
import com.phonedsh.ui.bot.state.BotUiStateDerivation
import com.phonedsh.ui.bot.state.BotUiStateInput
import com.phonedsh.ui.bot.state.BotUiStrings
import com.phonedsh.ui.theme.PdshTheme
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

@RunWith(AndroidJUnit4::class)
@Config(sdk = [34], qualifiers = "w411dp-h640dp")
@GraphicsMode(GraphicsMode.Mode.NATIVE)
class BotDrawerTest {
    @get:Rule
    val compose = createComposeRule()

    private val intents = mutableListOf<BotDrawerIntent>()
    private var closed = 0

    private val fish: BotFishSlot = { _, _, crowned, size, _, modifier ->
        Box(
            modifier
                .size(size)
                .testTag(if (crowned) FISH_CROWNED else FISH_PLAIN),
        )
    }

    private fun show(
        entries: List<BotRosterEntry>,
        selection: String? = null,
        now: Long = BotPageFixtures.pinnedNow,
        error: String? = null,
        persistent: Boolean = false,
    ) {
        compose.setContent {
            PdshTheme {
                BotDrawer(
                    entries = entries,
                    selection = selection,
                    onIntent = { intents += it },
                    fish = fish,
                    now = now,
                    error = error,
                    persistent = persistent,
                    onClose = { closed += 1 },
                )
            }
        }
    }

    private fun openRowMenu(botID: String) {
        compose.onNodeWithTag(BotDrawerTags.row(botID)).performTouchInput { longClick() }
        compose.waitForIdle()
    }

    /** The shared menu closes first and dispatches the chosen action from a LaunchedEffect (rule 7). */
    private fun chooseMenu(label: String) {
        compose.onNodeWithText(label).performClick()
        compose.waitForIdle()
    }

    private fun y(tag: String): Float =
        compose.onNodeWithTag(tag).getUnclippedBoundsInRoot().top.value

    // -------------------------------------------------------------- roster order

    @Test
    fun `drawer puts the main Bot first, keeps insertion order and hides hidden Bots`() {
        val main = BotPageFixtures.rosterEntry()
        val second = main.copy(id = "second", name = "第二 Bot", isMainBot = false, unreadCount = 0)
        val third = main.copy(id = "third", name = "第三 Bot", isMainBot = false, unreadCount = 0)
        val hidden = main.copy(id = "hidden", name = "隐藏 Bot", isMainBot = false, isHidden = true)

        show(listOf(second, hidden, third, main))
        val actual = listOf("main", "second", "third").sortedBy { y(BotDrawerTags.row(it)) }
        assertEquals(listOf("main", "second", "third"), actual)
        compose.onNodeWithTag(BotDrawerTags.row("hidden")).assertDoesNotExist()
        compose.onAllNodesWithTag(FISH_CROWNED, useUnmergedTree = true).assertCountEquals(1)
    }

    @Test
    fun `drawer renders the activity status vector`() {
        val case = BotPageFixtures.uiStateCase("drawer-running-activity")
        show(listOf(BotPageFixtures.drawerEntry(case)), now = BotPageFixtures.uiStateNow(case))
        val status = (case["expected"] as JsonObject)["drawerStatus"] as JsonObject
        compose.onNodeWithText((status["text"] as JsonString).value).assertIsDisplayed()
    }

    @Test
    fun `drawer renders the fish fallback status vector`() {
        val case = BotPageFixtures.uiStateCase("drawer-running-fish-fallback")
        show(listOf(BotPageFixtures.drawerEntry(case)), now = BotPageFixtures.uiStateNow(case))
        val status = (case["expected"] as JsonObject)["drawerStatus"] as JsonObject
        compose.onNodeWithText((status["text"] as JsonString).value).assertIsDisplayed()
    }

    @Test
    fun `drawer renders the relative time and 99 plus unread vector`() {
        val case = BotPageFixtures.uiStateCase("drawer-idle-relative-unread")
        show(listOf(BotPageFixtures.drawerEntry(case)), now = BotPageFixtures.uiStateNow(case))
        val expected = case["expected"] as JsonObject
        val status = expected["drawerStatus"] as JsonObject
        compose.onNodeWithText((status["text"] as JsonString).value).assertIsDisplayed()
        val badge = expected["unreadBadge"] as JsonObject
        compose.onNodeWithContentDescription(
            (badge["accessibility"] as JsonString).value,
            useUnmergedTree = true,
        ).assertIsDisplayed()
        compose.onNodeWithText((badge["text"] as JsonString).value).assertIsDisplayed()
    }

    @Test
    fun `pending approvals use the warning status`() {
        val entry = BotPageFixtures.rosterEntry().copy(
            runtime = BotRosterRuntimeState(pendingApprovalCount = 2),
        )
        val status = BotUiStateDerivation.drawerStatus(
            BotUiStateInput(
                context = BotUiContext(entry.id, entry.name),
                rows = emptyList(),
                now = BotPageFixtures.pinnedNow,
                drawer = com.phonedsh.ui.bot.state.BotDrawerState(isRunning = false),
            ),
            pendingApprovals = 2,
        )
        assertEquals(BotDrawerStatusColor.WARNING, status.color)

        show(listOf(entry))
        compose.onNodeWithText(BotUiStrings.format("drawer.pending", "count" to 2))
            .assertIsDisplayed()
    }

    // ------------------------------------------------------------------ rename

    @Test
    fun `model-layer name messages are the K3 validation values`() {
        assertEquals(
            BotUiStrings.VALIDATION_NAME_EMPTY,
            BotNameValidation.problem("   "),
        )
        assertEquals(
            BotUiStrings.format(
                "validation.name.tooLong",
                "max" to BotNameValidation.MAX_UTF16_UNITS,
                "count" to 61,
            ),
            BotNameValidation.problem("名".repeat(61)),
        )
        // The name field delegates its cap and trim to these rules.
        assertEquals("名".repeat(60), BotNameValidation.capped("名".repeat(61)))
        assertEquals("新名字", BotNameValidation.trimmed("  新名字  "))
    }

    // --------------------------------------------------------------- add dialog

    // ------------------------------------------------------------- delete guard

    @Test
    fun `the last Bot shows the frozen explanation and no delete action`() {
        show(listOf(BotPageFixtures.rosterEntry()))

        openRowMenu("main")
        compose.onNodeWithText(BotUiStrings.DRAWER_MENU_LASTBOT).assertIsDisplayed()
        compose.onAllNodesWithText(BotUiStrings.DRAWER_MENU_DELETE).assertCountEquals(0)
        assertTrue(intents.none { it is BotDrawerIntent.Delete })
    }

    @Test
    fun `delete is confirmed once and emits the Bot id`() {
        val main = BotPageFixtures.rosterEntry()
        val second = main.copy(id = "second", name = "第二 Bot", isMainBot = false, unreadCount = 0)
        show(listOf(main, second))

        openRowMenu("second")
        chooseMenu(BotUiStrings.DRAWER_MENU_DELETE)
        compose.onNodeWithText(BotUiStrings.DRAWER_DELETE_CONFIRM).assertIsDisplayed()
        compose.onNodeWithTag(BotDrawerTags.DELETE_CONFIRM).performClick()

        assertEquals(
            BotDrawerIntent.Delete("second"),
            intents.filterIsInstance<BotDrawerIntent.Delete>().single(),
        )
    }

    // ------------------------------------------------------------- menu actions

    @Test
    fun `the shared botRow menu emits appearance`() {
        val main = BotPageFixtures.rosterEntry()
        val second = main.copy(id = "second", name = "第二 Bot", isMainBot = false, unreadCount = 0)
        show(listOf(main, second))

        openRowMenu("second")
        chooseMenu(BotUiStrings.DRAWER_MENU_APPEARANCE)

        assertEquals(BotDrawerIntent.Appearance("second"), intents.last())
    }

    @Test
    fun `the shared botRow menu emits set-main`() {
        val main = BotPageFixtures.rosterEntry()
        val second = main.copy(id = "second", name = "第二 Bot", isMainBot = false, unreadCount = 0)
        show(listOf(main, second))

        openRowMenu("second")
        chooseMenu(BotUiStrings.DRAWER_MENU_SETMAIN)

        assertEquals(BotDrawerIntent.SetMain("second"), intents.last())
    }

    @Test
    fun `the shared botRow menu emits hide`() {
        val main = BotPageFixtures.rosterEntry()
        val second = main.copy(id = "second", name = "第二 Bot", isMainBot = false, unreadCount = 0)
        show(listOf(main, second))

        openRowMenu("second")
        chooseMenu(BotUiStrings.DRAWER_MENU_HIDE)

        assertEquals(BotDrawerIntent.SetHidden("second", true), intents.last())
    }

    @Test
    fun `tapping a row selects the Bot and asks the host to close`() {
        val main = BotPageFixtures.rosterEntry()
        show(listOf(main))

        compose.onNodeWithTag(BotDrawerTags.row("main")).performClick()

        assertTrue(intents.contains(BotDrawerIntent.Select("main")))
    }

    // --------------------------------------------------------------- management

    @Test
    fun `the management list is the only place a hidden Bot remains visible`() {
        val main = BotPageFixtures.rosterEntry()
        val hidden = main.copy(id = "hidden", name = "隐藏 Bot", isMainBot = false, isHidden = true)
        show(listOf(main, hidden))

        compose.onNodeWithTag(BotDrawerTags.row("hidden")).assertDoesNotExist()
        compose.onNodeWithTag(BotDrawerTags.MANAGE).performClick()
        compose.onNodeWithTag(BotDrawerTags.manageRow("hidden")).assertIsDisplayed()
        assertTrue(intents.contains(BotDrawerIntent.Manage))
    }

    private companion object {
        private const val FISH_CROWNED = "test.fish.crowned"
        private const val FISH_PLAIN = "test.fish.plain"
    }
}
