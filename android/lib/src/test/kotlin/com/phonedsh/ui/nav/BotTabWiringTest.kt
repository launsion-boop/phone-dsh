// SPDX-License-Identifier: MIT
package com.phonedsh.ui.nav

import androidx.compose.foundation.layout.Box
import androidx.compose.ui.Modifier
import androidx.compose.ui.test.assertCountEquals
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.hasTestTag
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.performClick
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.phonedsh.ui.SpecFixtures
import com.phonedsh.ui.bot.driver.FixtureBotChatDriver
import com.phonedsh.ui.bot.page.chat.BotChatTags
import com.phonedsh.ui.theme.PdshTheme
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.annotation.Config

/**
 * The Bot tab's two gates: the bar renders it only when the host supplies a
 * driver, and [PdshNavHost] renders the Bot page on the Bot tab's root route
 * only with a driver. Both halves are asserted here, never one of them by
 * assumption.
 */
@RunWith(AndroidJUnit4::class)
@Config(sdk = [34], qualifiers = "w411dp-h891dp")
class BotTabWiringTest {
    @get:Rule
    val compose = createComposeRule()

    private val driver = FixtureBotChatDriver.fromJson(
        SpecFixtures.repoJson("spec/ui/v1/bot/golden/fixtures.json"),
        scenario = "empty",
    )

    private fun mountBar(showBot: Boolean) {
        compose.setContent {
            PdshTheme(darkTheme = false) {
                HomeTabBar(selection = HomeTab.TASKS, onSelect = {}, showBot = showBot)
            }
        }
        compose.waitForIdle()
    }

    @Test
    fun `without a driver the bar keeps the three pre-Bot tabs`() {
        mountBar(showBot = false)
        compose.onNodeWithTag(HomeTabBarTags.BAR).assertIsDisplayed()
        listOf("tasks", "discover", "me").forEach { name ->
            assertEquals(
                "tab $name",
                1,
                compose.onAllNodes(hasTestTag(HomeTabBarTags.TAB_PREFIX + name))
                    .fetchSemanticsNodes().size,
            )
        }
        compose.onAllNodes(hasTestTag(HomeTabBarTags.TAB_PREFIX + "bot"))
            .assertCountEquals(0)
    }

    @Test
    fun `with a driver the bar adds Bot`() {
        mountBar(showBot = true)
        listOf("bot", "tasks", "discover", "me").forEach { name ->
            assertEquals(
                "tab $name",
                1,
                compose.onAllNodes(hasTestTag(HomeTabBarTags.TAB_PREFIX + name))
                    .fetchSemanticsNodes().size,
            )
        }
    }

    private fun mountBotRoute(withDriver: Boolean, onDrawer: () -> Unit = {}, onInfo: () -> Unit = {}) {
        compose.setContent {
            PdshTheme(darkTheme = false) {
                PdshNavHost(
                    nav = PdshNavState(
                        stacks = mapOf(
                            HomeTab.BOT to listOf(
                                PdshRoute.Home,
                                PdshRoute.Chat,
                            ),
                        ),
                        selectedTab = HomeTab.BOT,
                    ),
                    facts = PdshNavFacts(),
                    onNavigate = {},
                    onBack = {},
                    onHome = {},
                    onHostAction = {},
                    home = {},
                    webSurface = {},
                    botDriver = if (withDriver) driver else null,
                    botFish = { _, _, _, _, _, _ -> Box(Modifier) },
                    onOpenBotDrawer = onDrawer,
                    onOpenBotInfo = onInfo,
                )
            }
        }
        compose.waitForIdle()
    }

    @Test
    fun `the Bot route renders the chat page with a driver`() {
        var drawer = 0
        var info = 0
        mountBotRoute(withDriver = true, onDrawer = { drawer++ }, onInfo = { info++ })
        compose.onNodeWithTag(BotChatTags.EMPTY).assertIsDisplayed()
        compose.onNodeWithTag(BotChatTags.DRAWER_OPEN).performClick()
        compose.onNodeWithTag(BotChatTags.INFO_OPEN).performClick()
        compose.runOnIdle {
            assertEquals(1, drawer)
            assertEquals(1, info)
        }
    }

    @Test
    fun `the Bot route renders nothing without a driver`() {
        mountBotRoute(withDriver = false)
        compose.onAllNodes(hasTestTag(BotChatTags.EMPTY)).assertCountEquals(0)
        compose.onAllNodes(hasTestTag(BotChatTags.TRANSCRIPT)).assertCountEquals(0)
    }
}
