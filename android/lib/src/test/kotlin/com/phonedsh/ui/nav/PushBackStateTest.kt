// Rule-level tests for the per-tab push state (`interaction.md` §4).
// SPDX-License-Identifier: MIT
package com.phonedsh.ui.nav

import com.phonedsh.ui.theme.generated.TokenBackLayer
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test

class PushBackStateTest {
    @Test
    fun `each tab keeps its own depth and switching tabs never clears it`() {
        var state = PushBackState()
        state = state.push()
        assertEquals("the selected tab has one page", 1, state.depth)
        assertEquals("the other tabs are still at root", 0, state.depthOf(HomeTab.DISCOVER))

        state = state.selectTab(HomeTab.DISCOVER)
        state = state.push().push()
        assertEquals("discover has two pages", 2, state.depth)
        assertEquals("the tasks stack survives the switch", 1, state.depthOf(HomeTab.TASKS))

        state = state.selectTab(HomeTab.TASKS)
        assertEquals("returning to tasks restores its stack", 1, state.depth)
        assertEquals("discover still has two pages", 2, state.depthOf(HomeTab.DISCOVER))
    }

    @Test
    fun `re-tapping the current tab is a no-op`() {
        var state = PushBackState()
        state = state.push().push()
        val before = state

        assertSame("the same value is returned", before, before.selectTab(HomeTab.TASKS))
        assertEquals("the re-tap cannot pop to root", 2, before.selectTab(HomeTab.TASKS).depth)
    }

    @Test
    fun `back consumes sheet then drawer then stack then root`() {
        var state = PushBackState(stackDepths = mapOf(HomeTab.TASKS to 2))
            .openOverlay(PushOverlay.DRAWER)
            .openOverlay(PushOverlay.SHEET)
        assertEquals("golden vocabulary order", "sheet,drawer", state.overlays.joinToString(",") { it.spec })

        var result = state.back()
        assertEquals("sheet closes first", "drawer", result.state.overlays.joinToString(",") { it.spec })
        assertEquals("the stack is untouched", 2, result.state.depth)
        assertFalse(result.exited)

        result = result.state.back()
        assertTrue("drawer closes second", result.state.overlays.isEmpty())
        assertEquals("the stack is still untouched", 2, result.state.depth)
        assertFalse(result.exited)

        result = result.state.back()
        assertEquals("stack pops third", 1, result.state.depth)
        assertFalse(result.exited)

        result = result.state.back()
        assertEquals("the last page is still there", 0, result.state.depth)
        assertFalse(result.exited)

        result = result.state.back()
        assertEquals("the root stays at depth zero", 0, result.state.depth)
        assertTrue("root back exits", result.exited)
    }

    @Test
    fun `pop at the root cannot create a negative depth`() {
        val root = PushBackState()
        assertSame(root, root.pop())
        assertEquals(0, root.pop().depth)
    }

    @Test
    fun `tab bar follows selected depth and keyboard`() {
        val root = PushBackState()
        assertTrue("visible at the root with no keyboard", root.tabBarVisible)
        assertFalse("hidden by the keyboard", root.withKeyboardVisible(true).tabBarVisible)

        val pushed = root.push()
        assertFalse("hidden while a page is pushed", pushed.tabBarVisible)
        assertFalse("still hidden after the keyboard closes", pushed.withKeyboardVisible(false).tabBarVisible)

        val back = pushed.back()
        assertTrue("restored at the root", back.state.tabBarVisible)
        assertFalse("the keyboard result is preserved", pushed.withKeyboardVisible(true).back().state.tabBarVisible)
    }

    @Test
    fun `predictive progress and cancel keep the exact state`() {
        val state = PushBackState(stackDepths = mapOf(HomeTab.TASKS to 1))
            .openOverlay(PushOverlay.SHEET)
            .withKeyboardVisible(true)
        assertSame(state, state.predictiveProgress(0f))
        assertSame(state, state.predictiveProgress(0.5f))
        assertSame(state, state.predictiveProgress(1f))
        assertSame(state, state.predictiveCancel())
    }

    @Test
    fun `the top layer is offered before the state transition`() {
        var innerDepth = 1
        var drawerCalls = 0
        val sheet = object : PushBackLayer {
            override val layer: TokenBackLayer = TokenBackLayer.SHEET
            override fun consumeBack(): Boolean {
                if (innerDepth == 0) return false
                innerDepth -= 1
                return true
            }
        }
        val drawer = object : PushBackLayer {
            override val layer: TokenBackLayer = TokenBackLayer.DRAWER
            override fun consumeBack(): Boolean {
                drawerCalls += 1
                return true
            }
        }
        val state = PushBackState(
            stackDepths = mapOf(HomeTab.TASKS to 1),
            overlays = listOf(PushOverlay.DRAWER, PushOverlay.SHEET),
        )

        var dispatch = dispatchBack(state, listOf(sheet, drawer))
        assertTrue("the sheet's inner stack consumes first", dispatch.consumedByLayer)
        assertSame("the layer consumed without changing state", state, dispatch.state)
        assertEquals("the drawer delegate was not consulted under the sheet", 0, drawerCalls)

        dispatch = dispatchBack(state, listOf(sheet, drawer))
        assertFalse("an empty inner stack lets the sheet close", dispatch.consumedByLayer)
        assertEquals(
            "only the sheet closes; the drawer waits for its own turn",
            listOf(PushOverlay.DRAWER),
            dispatch.state.overlays,
        )
        assertEquals("the host stack did not pop", 1, dispatch.state.depth)
    }

    @Test
    fun `top layer uses the generated back order`() {
        assertEquals(
            TokenBackLayer.SHEET,
            PushBackState().openOverlay(PushOverlay.SHEET).topLayer(),
        )
        assertEquals(
            TokenBackLayer.DRAWER,
            PushBackState().openOverlay(PushOverlay.DRAWER).topLayer(),
        )
        assertEquals(
            TokenBackLayer.STACK,
            PushBackState().push().topLayer(),
        )
        assertEquals(
            TokenBackLayer.ROOT,
            PushBackState().topLayer(),
        )
    }
}
