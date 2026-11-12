// Per-tab route stacks (`interaction.md` §4 rules 1-3), driven as a value.
// SPDX-License-Identifier: MIT
package com.phonedsh.ui.nav

import org.junit.Assert.assertEquals
import org.junit.Assert.assertSame
import org.junit.Test

class PdshNavStateTest {
    private val tasksFloor = PdshNavState(listOf(PdshRoute.Chat))

    @Test
    fun `each tab keeps its own route stack across a switch`() {
        var nav = tasksFloor
            .push(PdshRoute.WorkspaceFolders)
            .push(PdshRoute.Files("notes"))
        assertEquals("two pages above the tasks root", 2, nav.depthOf(HomeTab.TASKS))
        assertEquals(PdshRoute.Files("notes"), nav.current)

        nav = nav.selectHomeTab(HomeTab.DISCOVER)
        assertEquals(
            "a first visit starts at the tab root on the home floor",
            listOf(PdshRoute.Chat, PdshRoute.Discover),
            nav.stack,
        )
        assertEquals(0, nav.depthOf(HomeTab.DISCOVER))
        assertEquals("the hidden tasks stack is intact", 2, nav.depthOf(HomeTab.TASKS))

        nav = nav.push(PdshRoute.Bluetooth)
        assertEquals(1, nav.depthOf(HomeTab.DISCOVER))
        assertEquals(2, nav.depthOf(HomeTab.TASKS))

        nav = nav.selectHomeTab(HomeTab.TASKS)
        assertEquals(
            "switching back restores the pushed routes, not just the depth",
            listOf(PdshRoute.Chat, PdshRoute.WorkspaceFolders, PdshRoute.Files("notes")),
            nav.stack,
        )
        assertEquals(PdshRoute.Files("notes"), nav.current)
        assertEquals(2, nav.depthOf(HomeTab.TASKS))
    }

    @Test
    fun `back pops the selected tab only`() {
        val nav = tasksFloor
            .selectHomeTab(HomeTab.DISCOVER)
            .push(PdshRoute.Bluetooth)
            .push(PdshRoute.AndroidAdb)
            .selectHomeTab(HomeTab.TASKS)
            .push(PdshRoute.Settings)

        val after = nav.pop()
        assertEquals("tasks loses one page", 0, after.depthOf(HomeTab.TASKS))
        assertEquals(listOf(PdshRoute.Chat), after.stack)
        assertEquals(
            "discover keeps both pages while tasks pops",
            2,
            after.depthOf(HomeTab.DISCOVER),
        )

        val discover = after.selectHomeTab(HomeTab.DISCOVER)
        assertEquals(PdshRoute.AndroidAdb, discover.current)
        assertEquals(
            listOf(PdshRoute.Chat, PdshRoute.Discover, PdshRoute.Bluetooth, PdshRoute.AndroidAdb),
            discover.stack,
        )
    }

    @Test
    fun `re-selecting the current tab is the same value and never pops to root`() {
        val deep = tasksFloor.push(PdshRoute.Settings).push(PdshRoute.Runtime)
        assertSame("a re-tap cannot move the stack", deep, deep.selectHomeTab(HomeTab.TASKS))
        assertEquals(2, deep.selectHomeTab(HomeTab.TASKS).depthOf(HomeTab.TASKS))
    }

    @Test
    fun `a non-tasks tab root pushed from the home floor shows that tab`() {
        val discover = tasksFloor.push(PdshRoute.Discover)
        assertEquals(HomeTab.DISCOVER, discover.selectedTab)
        assertEquals(listOf(PdshRoute.Chat, PdshRoute.Discover), discover.stack)
        assertEquals(0, discover.depthOf(HomeTab.DISCOVER))

        val me = tasksFloor.push(PdshRoute.MeTab)
        assertEquals(HomeTab.ME, me.selectedTab)
        assertEquals(listOf(PdshRoute.Chat, PdshRoute.MeTab), me.stack)
    }

    @Test
    fun `a tab root above a pushed page is a page, not a tab switch`() {
        val nav = tasksFloor
            .push(PdshRoute.Settings)
            .push(PdshRoute.MeTab)
        assertEquals(HomeTab.TASKS, nav.selectedTab)
        assertEquals(
            listOf(PdshRoute.Chat, PdshRoute.Settings, PdshRoute.MeTab),
            nav.stack,
        )
        assertEquals("both routes are above the tasks root", 2, nav.depthOf(HomeTab.TASKS))
    }

    @Test
    fun `the pre-per-tab constructor still names the selected tab from the stack`() {
        val tasks = PdshNavState(listOf(PdshRoute.Home, PdshRoute.Chat, PdshRoute.Settings))
        assertEquals(HomeTab.TASKS, tasks.selectedTab)
        assertEquals(1, tasks.depthOf(HomeTab.TASKS))
        assertEquals(
            listOf(PdshRoute.Home, PdshRoute.Chat, PdshRoute.Settings),
            tasks.stack,
        )

        val discover = PdshNavState(listOf(PdshRoute.Home, PdshRoute.Chat, PdshRoute.Discover))
        assertEquals(HomeTab.DISCOVER, discover.selectedTab)
        assertEquals(listOf(PdshRoute.Home, PdshRoute.Chat, PdshRoute.Discover), discover.stack)
    }

    @Test
    fun `popping a tab root returns to the tasks floor`() {
        val discover = tasksFloor.selectHomeTab(HomeTab.DISCOVER)
        val popped = discover.pop()

        assertEquals(HomeTab.TASKS, popped.selectedTab)
        assertEquals(listOf(PdshRoute.Chat), popped.stack)
        assertEquals("the closed tab has no saved depth", 0, popped.depthOf(HomeTab.DISCOVER))
        assertEquals(
            "selecting it again recreates the root, never a leftover Chat page",
            listOf(PdshRoute.Chat, PdshRoute.Discover),
            popped.selectHomeTab(HomeTab.DISCOVER).stack,
        )
    }

    @Test
    fun `the first root occurrence is the floor and a repeated root is a page`() {
        val nav = tasksFloor.push(PdshRoute.Chat)
        assertEquals(listOf(PdshRoute.Chat, PdshRoute.Chat), nav.stack)
        assertEquals("a re-pushed Chat is one level, not a new floor", 1, nav.depthOf(HomeTab.TASKS))
        assertEquals(HomeTab.TASKS, nav.selectedTab)
    }

    @Test
    fun `replaceTop keeps the depth and stays inside the selected tab`() {
        val nav = tasksFloor
            .selectHomeTab(HomeTab.DISCOVER)
            .push(PdshRoute.Bluetooth)
            .selectHomeTab(HomeTab.TASKS)
            .push(PdshRoute.Settings)

        val replaced = nav.replaceTop(PdshRoute.Runtime)
        assertEquals(listOf(PdshRoute.Chat, PdshRoute.Runtime), replaced.stack)
        assertEquals(1, replaced.depthOf(HomeTab.TASKS))
        assertEquals("the other tab's stack is untouched", 1, replaced.depthOf(HomeTab.DISCOVER))
        assertEquals(
            listOf(PdshRoute.Chat, PdshRoute.Discover, PdshRoute.Bluetooth),
            replaced.selectHomeTab(HomeTab.DISCOVER).stack,
        )
    }

    @Test
    fun `the root is a fixed point`() {
        val root = PdshNavState()
        assertSame(root, root.pop())
        assertEquals(listOf(PdshRoute.Home), root.stack)
    }
}
