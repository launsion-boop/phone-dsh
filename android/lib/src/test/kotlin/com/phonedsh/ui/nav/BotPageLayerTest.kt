// SPDX-License-Identifier: MIT
// The Bot tab's internal wiring: the default host opens the K5b drawer/info/
// appearance surfaces, the host overrides still win, and no overlay survives the
// Bot tab or the driver.
// SPDX-License-Identifier: MIT
package com.phonedsh.ui.nav

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.size
import androidx.compose.runtime.MutableState
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.test.assertCountEquals
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.hasTestTag
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performSemanticsAction
import androidx.compose.ui.unit.dp
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.phonedsh.bot.profile.BotFishColor
import com.phonedsh.ui.SpecFixtures
import com.phonedsh.ui.UiStrings
import com.phonedsh.ui.bot.driver.BotChatDriver
import com.phonedsh.ui.bot.driver.FixtureBotChatDriver
import com.phonedsh.ui.bot.page.BotPageLayer
import com.phonedsh.ui.bot.page.BotPageLayerTags
import com.phonedsh.ui.bot.page.appearance.BotAppearanceTags
import com.phonedsh.ui.bot.page.chat.BotChatTags
import com.phonedsh.ui.bot.page.drawer.BotDrawerTags
import com.phonedsh.ui.bot.page.drawer.BotPageFixtures
import com.phonedsh.ui.bot.page.info.BotInfoCopy
import com.phonedsh.ui.bot.page.info.BotInfoTags
import com.phonedsh.ui.bot.state.BotAppearanceIntent
import com.phonedsh.ui.bot.state.BotDrawerIntent
import com.phonedsh.ui.bot.state.BotInfoIntent
import com.phonedsh.ui.bot.state.BotUiContext
import com.phonedsh.ui.bot.state.BotUiStrings
import com.phonedsh.ui.theme.PdshTheme
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.annotation.Config

/**
 * K5c: `PdshNavHost` connects the K5a Bot chat page to the K5b drawer, info page
 * and appearance editor without changing the host override contract.
 *
 * Row/menu gestures use the semantics actions those rows publish (the pattern
 * `SubagentCatalogTest` uses for its long press): touch injection into the
 * drawer row is not reliable under Robolectric. The header, scrim and back
 * controls keep real clicks.
 */
@RunWith(AndroidJUnit4::class)
@Config(sdk = [34], qualifiers = "w411dp-h891dp")
class BotPageLayerTest {
    @get:Rule
    val compose = createComposeRule()

    private val driver = FixtureBotChatDriver.fromJson(
        SpecFixtures.repoJson("spec/ui/v1/bot/golden/fixtures.json"),
        scenario = "empty",
    )
    private val mainBot = BotPageFixtures.rosterEntry()
    private val secondBot = mainBot.copy(
        id = "second",
        name = "第二 Bot",
        isMainBot = false,
        unreadCount = 0,
    )
    private val roster = listOf(mainBot, secondBot)
    private val infoState = BotPageFixtures.infoModel()
    private val appearance = BotPageFixtures.fixtureAppearance()
    private val botContext = BotUiContext(botID = mainBot.id, botName = mainBot.name)
    private val botNav = PdshNavState(
        stacks = mapOf(
            HomeTab.BOT to listOf(PdshRoute.Home, PdshRoute.Chat),
            HomeTab.TASKS to listOf(PdshRoute.Home),
        ),
        selectedTab = HomeTab.BOT,
    )

    private fun mountHost(
        navState: MutableState<PdshNavState> = mutableStateOf(botNav),
        driverState: MutableState<BotChatDriver?> = mutableStateOf(driver),
        onOpenDrawer: (() -> Unit)? = null,
        onOpenInfo: (() -> Unit)? = null,
        onDrawerIntent: (BotDrawerIntent) -> Unit = {},
        onInfoIntent: (BotInfoIntent) -> Unit = {},
        onAppearanceIntent: (BotAppearanceIntent) -> Unit = {},
    ) {
        compose.setContent {
            PdshTheme(darkTheme = false) {
                PdshNavHost(
                    nav = navState.value,
                    facts = PdshNavFacts(),
                    onNavigate = {},
                    onBack = {},
                    onHome = {},
                    onHostAction = {},
                    home = {},
                    webSurface = {},
                    botDriver = driverState.value,
                    botContext = botContext,
                    botAppearance = appearance,
                    botIsMainBot = mainBot.isMainBot,
                    botFish = { _, _, _, _, _, _ -> Box(Modifier) },
                    botRoster = roster,
                    botInfoState = infoState,
                    botDescription = mainBot.description,
                    onOpenBotDrawer = onOpenDrawer,
                    onOpenBotInfo = onOpenInfo,
                    onBotDrawerIntent = onDrawerIntent,
                    onBotInfoIntent = onInfoIntent,
                    onBotAppearanceIntent = onAppearanceIntent,
                )
            }
        }
        compose.waitForIdle()
    }

    private fun openDrawer() {
        compose.onNodeWithTag(BotChatTags.DRAWER_OPEN).performClick()
        compose.waitForIdle()
        compose.onNodeWithTag(BotDrawerTags.PANEL).assertIsDisplayed()
    }

    private fun openAppearance() {
        openDrawer()
        compose.onNodeWithTag(BotDrawerTags.row(secondBot.id))
            .performSemanticsAction(SemanticsActions.OnLongClick)
        compose.waitForIdle()
        compose.onNodeWithText(BotUiStrings.DRAWER_MENU_APPEARANCE)
            .performSemanticsAction(SemanticsActions.OnClick)
        compose.waitForIdle()
        compose.onNodeWithTag(BotPageLayerTags.APPEARANCE).assertIsDisplayed()
    }

    @Test
    fun `the default host opens the drawer and closes it back to chat`() {
        mountHost()

        openDrawer()
        compose.onNodeWithTag(BotDrawerTags.SCRIM).performClick()
        compose.waitForIdle()

        compose.onNodeWithTag(BotDrawerTags.PANEL).assertDoesNotExist()
        compose.onNodeWithTag(BotChatTags.EMPTY).assertIsDisplayed()
    }

    @Test
    fun `the default host opens info and its back returns to chat`() {
        mountHost()

        compose.onNodeWithTag(BotChatTags.INFO_OPEN).performClick()
        compose.onNodeWithTag(BotInfoTags.ROOT).assertIsDisplayed()
        compose.onNodeWithContentDescription(UiStrings.BACK).performClick()

        compose.onNodeWithTag(BotInfoTags.ROOT).assertDoesNotExist()
        compose.onNodeWithTag(BotChatTags.EMPTY).assertIsDisplayed()
    }

    @Test
    fun `the drawer appearance action opens the picker and writes an intent`() {
        val intents = mutableListOf<BotAppearanceIntent>()
        mountHost(onAppearanceIntent = { intents += it })

        openAppearance()
        compose.onNodeWithTag(BotDrawerTags.PANEL).assertDoesNotExist()
        compose.onNodeWithTag(
            BotAppearanceTags.color(BotAppearanceTags.INFO_PREFIX, BotFishColor.BLUE.wire),
        ).performClick()

        assertEquals(BotAppearanceIntent.SelectColor(BotFishColor.BLUE), intents.single())

        compose.onNodeWithContentDescription(UiStrings.BACK).performClick()
        compose.onNodeWithTag(BotPageLayerTags.APPEARANCE).assertDoesNotExist()
    }

    @Test
    fun `the drawer and info callbacks receive their intents`() {
        val drawerIntents = mutableListOf<BotDrawerIntent>()
        val infoIntents = mutableListOf<BotInfoIntent>()
        mountHost(
            onDrawerIntent = { drawerIntents += it },
            onInfoIntent = { infoIntents += it },
        )

        compose.onNodeWithTag(BotChatTags.INFO_OPEN).performClick()
        compose.onNodeWithContentDescription(BotInfoCopy.REFRESH).performClick()
        assertEquals(listOf(BotInfoIntent.Load), infoIntents)
        compose.onNodeWithContentDescription(UiStrings.BACK).performClick()

        openDrawer()
        compose.onNodeWithTag(BotDrawerTags.row(mainBot.id))
            .performSemanticsAction(SemanticsActions.OnClick)
        compose.waitForIdle()
        assertTrue(
            "the host must receive the row's Select intent",
            drawerIntents.contains(BotDrawerIntent.Select(mainBot.id)),
        )
    }

    @Test
    fun `host open overrides keep precedence and open no internal surface`() {
        var drawer = 0
        var info = 0
        mountHost(onOpenDrawer = { drawer++ }, onOpenInfo = { info++ })

        compose.onNodeWithTag(BotChatTags.DRAWER_OPEN).performClick()
        compose.onNodeWithTag(BotChatTags.INFO_OPEN).performClick()

        compose.runOnIdle {
            assertEquals(1, drawer)
            assertEquals(1, info)
        }
        compose.onAllNodes(hasTestTag(BotDrawerTags.PANEL)).assertCountEquals(0)
        compose.onAllNodes(hasTestTag(BotInfoTags.ROOT)).assertCountEquals(0)
    }

    @Test
    fun `leaving the Bot tab closes an open overlay`() {
        val navState = mutableStateOf(botNav)
        mountHost(navState = navState)
        openDrawer()

        compose.runOnUiThread {
            navState.value = botNav.copy(selectedTab = HomeTab.TASKS)
        }
        compose.waitForIdle()

        compose.onNodeWithTag(BotDrawerTags.PANEL).assertDoesNotExist()
    }

    @Test
    fun `losing the driver closes an open overlay`() {
        val driverState = mutableStateOf<BotChatDriver?>(driver)
        mountHost(driverState = driverState)
        openDrawer()

        compose.runOnUiThread { driverState.value = null }
        compose.waitForIdle()

        compose.onNodeWithTag(BotDrawerTags.PANEL).assertDoesNotExist()
    }

    @Test
    fun `an inactive layer closes its overlay without leaving the composition`() {
        val active = mutableStateOf(true)
        compose.setContent {
            PdshTheme(darkTheme = false) {
                BotPageLayer(
                    active = active.value,
                    botRoster = roster,
                    botContext = botContext,
                    botInfoState = infoState,
                    botAppearance = appearance,
                    botIsMainBot = mainBot.isMainBot,
                    botDescription = mainBot.description,
                    fish = { _, _, _, _, _, _ -> Box(Modifier) },
                    onBotDrawerIntent = {},
                    onBotInfoIntent = {},
                    onBotAppearanceIntent = {},
                ) { openDrawer, _ ->
                    Column(Modifier.fillMaxSize()) {
                        Box(
                            Modifier
                                .size(48.dp)
                                .testTag(CHAT_DRAWER_OPEN)
                                .clickable { openDrawer() },
                        )
                    }
                }
            }
        }
        compose.waitForIdle()

        compose.onNodeWithTag(CHAT_DRAWER_OPEN).performClick()
        compose.waitForIdle()
        compose.onNodeWithTag(BotDrawerTags.PANEL).assertIsDisplayed()

        compose.runOnUiThread { active.value = false }
        compose.waitForIdle()

        compose.onNodeWithTag(BotDrawerTags.PANEL).assertDoesNotExist()
        compose.onNodeWithTag(CHAT_DRAWER_OPEN).assertIsDisplayed()
    }

    private companion object {
        private const val CHAT_DRAWER_OPEN = "test.bot.chat.drawer.open"
    }
}
