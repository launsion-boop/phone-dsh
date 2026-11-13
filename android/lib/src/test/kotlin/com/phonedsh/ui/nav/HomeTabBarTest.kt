// PR #60 parity: the bottom menu's tab ↔ stack mapping.
// SPDX-License-Identifier: MIT
package com.phonedsh.ui.nav

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class HomeTabBarTest {
    private val chat = PdshNavState(listOf(PdshRoute.Chat))

    @Test
    fun `a tab root on the home floor is the selected tab`() {
        assertEquals(HomeTab.TASKS, chat.selectedHomeTab())
        assertEquals(HomeTab.DISCOVER, chat.push(PdshRoute.Discover).selectedHomeTab())
        assertEquals(HomeTab.ME, chat.push(PdshRoute.MeTab).selectedHomeTab())
        assertEquals(HomeTab.TASKS, PdshNavState(listOf(PdshRoute.Home, PdshRoute.Chat)).selectedHomeTab())
        assertEquals(
            HomeTab.BOT,
            PdshNavState(
                stacks = mapOf(HomeTab.BOT to listOf(PdshRoute.Home, PdshRoute.Chat)),
                selectedTab = HomeTab.BOT,
            ).selectedHomeTab(),
        )
    }

    @Test
    fun `Bot is the first tab and its root is the Bot route`() {
        assertEquals(HomeTab.BOT, HomeTab.entries.first())
        assertEquals(PdshRoute.Bot, HomeTab.BOT.root)
        assertEquals(listOf("Bot", "DSH", "发现", "我的"), HomeTab.entries.map { it.title })
    }

    @Test
    fun `the Bot tab is present only with a driver`() {
        assertEquals(
            listOf(HomeTab.TASKS, HomeTab.DISCOVER, HomeTab.ME),
            HomeTab.visibleTabs(showBot = false),
        )
        assertEquals(
            listOf(HomeTab.BOT, HomeTab.TASKS, HomeTab.DISCOVER, HomeTab.ME),
            HomeTab.visibleTabs(showBot = true),
        )
        assertTrue(HomeTab.visibleTabs(showBot = false).none { it.requiresBotDriver })
        assertTrue(HomeTab.visibleTabs(showBot = true).any { it.requiresBotDriver })
    }

    @Test
    fun `selecting the Bot tab gives it a root stack and back returns to tasks`() {
        val bot = chat.selectHomeTab(HomeTab.BOT)
        assertEquals(HomeTab.BOT, bot.selectedTab)
        assertEquals(listOf(PdshRoute.Chat), bot.stack)
        assertEquals(0, bot.depthOf(HomeTab.TASKS))
        assertEquals(HomeTab.BOT, bot.selectHomeTab(HomeTab.BOT).selectedTab)
        assertEquals(PdshRoute.Chat, bot.pop().current)
        assertEquals(HomeTab.BOT, bot.pop().selectedTab)
        assertEquals(HomeTab.TASKS, bot.selectHomeTab(HomeTab.TASKS).selectedTab)
        assertEquals(listOf(PdshRoute.Chat), bot.selectHomeTab(HomeTab.TASKS).stack)
    }

    @Test
    fun `a pushed page hides the bar`() {
        assertNull(chat.push(PdshRoute.Settings).selectedHomeTab())
        assertNull(chat.push(PdshRoute.MeTab).push(PdshRoute.SettingsMore).selectedHomeTab())
        assertNull(chat.push(PdshRoute.Discover).push(PdshRoute.Bluetooth).selectedHomeTab())
        assertNull(PdshNavState(listOf(PdshRoute.Home)).selectedHomeTab())
        // A tab root that is not on the home floor is a pushed page, not a tab.
        assertNull(chat.push(PdshRoute.Settings).push(PdshRoute.MeTab).selectedHomeTab())
    }

    @Test
    fun `selecting a tab replaces the stack above the home floor`() {
        val deep = chat.push(PdshRoute.Discover)
        assertEquals(listOf(PdshRoute.Chat, PdshRoute.MeTab), deep.selectHomeTab(HomeTab.ME).stack)
        assertEquals(listOf(PdshRoute.Chat), deep.selectHomeTab(HomeTab.TASKS).stack)
        assertEquals(
            listOf(PdshRoute.Home, PdshRoute.Chat, PdshRoute.Discover),
            PdshNavState(listOf(PdshRoute.Home)).selectHomeTab(HomeTab.DISCOVER).stack,
        )
        // Back from 发现 or 我的 returns to DSH.
        assertEquals(PdshRoute.Chat, chat.selectHomeTab(HomeTab.ME).pop().current)
    }
}
