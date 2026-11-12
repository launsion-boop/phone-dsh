// The host's mirrored route stack + per-tab push state, driven by the shared golden.
// SPDX-License-Identifier: MIT
//
// `spec/ui/v1/golden/push-back.golden.json` is the contract's own fixture: every
// case is read from disk and applied to the real `PushBackState` through
// `dispatchBack`, then to the app's `HostBackChain`. The host glue is what this
// file owns, so the assertions are the two halves agreeing (route count, depth,
// overlay, tab bar, exit), not a hand-copied sequence.
package com.phonedsh.probe

import com.phonedsh.ui.nav.BackDispatch
import com.phonedsh.ui.nav.HomeTab
import com.phonedsh.ui.nav.PdshNavState
import com.phonedsh.ui.nav.PdshRoute
import com.phonedsh.ui.nav.PushBackLayer
import com.phonedsh.ui.nav.PushBackState
import com.phonedsh.ui.nav.PushOverlay
import com.phonedsh.ui.nav.dispatchBack
import com.phonedsh.ui.theme.generated.TokenBackLayer
import java.io.File
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test

class HostBackChainTest {
    private val golden: JSONObject by lazy {
        val root = File(
            System.getProperty("pdsh.repo.root") ?: error("pdsh.repo.root is not set"),
        )
        JSONObject(File(root, "spec/ui/v1/golden/push-back.golden.json").readText())
    }

    private fun cases(): List<JSONObject> {
        val array = golden.getJSONArray("cases")
        return (0 until array.length()).map { array.getJSONObject(it) }
    }

    private fun stateFor(case: JSONObject): PushBackState {
        val depth = case.getInt("depth")
        val overlays = when (val spec = case.getString("overlay")) {
            "none" -> emptyList()
            else -> spec.split(",").map { name ->
                PushOverlay.entries.single { it.spec == name.trim() }
            }
        }
        return PushBackState(
            selectedTab = HomeTab.TASKS,
            stackDepths = if (depth == 0) emptyMap() else mapOf(HomeTab.TASKS to depth),
            overlays = overlays,
            keyboardVisible = case.getBoolean("keyboard"),
        )
    }

    /** A task-tab stack of [depth] pages above `Chat`, the host's product floor. */
    private fun chainFor(case: JSONObject): HostBackChain = HostBackChain(
        nav = PdshNavState(
            listOf(PdshRoute.Chat) + listOf(
                PdshRoute.WorkspaceFolders,
                PdshRoute.Files("notes"),
            ).take(case.getInt("depth")),
        ),
        pushBack = stateFor(case),
    )

    private fun overlaySpec(state: PushBackState): String =
        state.overlays.joinToString(",") { it.spec }.ifEmpty { "none" }

    @Test
    fun `the shared golden has the frozen eleven cases`() {
        assertEquals(
            "the fixture is the contract, not a local table",
            11,
            cases().size,
        )
    }

    @Test
    fun `every push-back golden case matches the mirrored host state machine`() {
        cases().forEach { case ->
            val id = case.getString("id")
            val before = chainFor(case)
            val result: BackDispatch
            val after: HostBackChain
            when (val action = case.getString("action")) {
                "push" -> {
                    result = BackDispatch(
                        state = before.pushBack,
                        exited = false,
                        consumedByLayer = false,
                        layer = null,
                    )
                    after = before.push(PdshRoute.Files("next"))
                    assertEquals("$id: push adds one route", before.nav.stack.size + 1, after.nav.stack.size)
                }
                "back" -> {
                    result = dispatchBack(before.pushBack)
                    after = before.applyPushState(result.state)
                }
                "predictive-cancel" -> {
                    assertSame(
                        "$id: progress must not change the state",
                        before.pushBack,
                        before.pushBack.predictiveProgress(0.5f),
                    )
                    result = BackDispatch(
                        state = before.pushBack.predictiveCancel(),
                        exited = false,
                        consumedByLayer = false,
                        layer = null,
                    )
                    after = before.applyPushState(result.state)
                    assertEquals("$id: cancel keeps the route stack", before.nav, after.nav)
                }
                else -> error("$id: unknown action '$action'")
            }

            assertEquals("$id: depthAfter", case.getInt("depthAfter"), after.depth)
            assertEquals("$id: overlayAfter", case.getString("overlayAfter"), overlaySpec(after.pushBack))
            assertEquals("$id: barVisible", case.getBoolean("barVisible"), after.pushBack.tabBarVisible)
            assertEquals("$id: exited", case.getBoolean("exited"), result.exited)
            assertEquals(
                "$id: the route stack mirrors the depth",
                case.getInt("depthAfter"),
                after.nav.stack.size - 1,
            )
        }
    }

    @Test
    fun `one back closes the top sheet before the page stack, then the next back pops`() {
        // depth 2, sheet open, drawer closed: the sheet is the first layer.
        var chain = HostBackChain(
            nav = PdshNavState(
                listOf(PdshRoute.Chat, PdshRoute.WorkspaceFolders, PdshRoute.Files("notes")),
            ),
            pushBack = PushBackState(
                stackDepths = mapOf(HomeTab.TASKS to 2),
                overlays = listOf(PushOverlay.SHEET),
            ),
        )
        val sheet = object : PushBackLayer {
            override val layer: TokenBackLayer = TokenBackLayer.SHEET
            override fun consumeBack(): Boolean = false
        }

        val first = dispatchBack(chain.pushBack, listOf(sheet))
        chain = chain.applyPushState(first.state)
        assertEquals("the sheet closes first", emptyList<PushOverlay>(), chain.pushBack.overlays)
        assertEquals("the host stack is untouched", 2, chain.depth)
        assertEquals("the route stack is untouched", 3, chain.nav.stack.size)

        val second = dispatchBack(chain.pushBack, listOf(sheet))
        chain = chain.applyPushState(second.state)
        assertEquals("the next back pops one page", 1, chain.depth)
        assertEquals("the navigator mirrors the pop", 2, chain.nav.stack.size)
        assertEquals(PdshRoute.WorkspaceFolders, chain.nav.current)
        assertFalse("a stack pop is not an exit", second.exited)
    }

    @Test
    fun `a sheet layer that pops its inner stack leaves both halves unchanged`() {
        var inner = 1
        val sheet = object : PushBackLayer {
            override val layer: TokenBackLayer = TokenBackLayer.SHEET
            override fun consumeBack(): Boolean {
                if (inner == 0) return false
                inner -= 1
                return true
            }
        }
        val chain = HostBackChain(
            nav = PdshNavState(listOf(PdshRoute.Chat, PdshRoute.Settings)),
            pushBack = PushBackState(
                stackDepths = mapOf(HomeTab.TASKS to 1),
                overlays = listOf(PushOverlay.SHEET),
            ),
        )

        val first = dispatchBack(chain.pushBack, listOf(sheet))
        assertTrue("the sheet's child consumes the gesture", first.consumedByLayer)
        assertEquals(chain, chain.applyPushState(first.state))

        val second = dispatchBack(chain.pushBack, listOf(sheet))
        assertFalse("at the inner root the sheet itself closes", second.consumedByLayer)
        assertEquals(emptyList<PushOverlay>(), second.state.overlays)
        assertEquals("closing the sheet does not pop the host stack", 1, second.state.depth)
    }

    @Test
    fun `back closes the open drawer with the page stack and depth unchanged`() {
        val chain = HostBackChain(
            nav = PdshNavState(listOf(PdshRoute.Chat, PdshRoute.WorkspaceFolders)),
            pushBack = PushBackState(
                stackDepths = mapOf(HomeTab.TASKS to 1),
                overlays = listOf(PushOverlay.DRAWER),
            ),
        )
        assertTrue(chain.drawerOpen)

        val back = dispatchBack(chain.pushBack)
        val after = chain.applyPushState(back.state)

        assertFalse("the drawer layer is consumed", after.drawerOpen)
        assertEquals("the drawer does not pop the page", 1, after.depth)
        assertEquals("the route stack is untouched", chain.nav, after.nav)
        assertFalse("closing the drawer is not an exit", back.exited)
        // The host keeps `drawerMounted` true until HomeDrawer reports the end of
        // the close motion (§1 rule 8); the chain only owns the open overlay, so a
        // false `drawerOpen` is exactly the request the host passes to `isOpen`.
    }

    @Test
    fun `the tab bar is hidden at depth greater than zero and while the keyboard is up`() {
        assertTrue("root without keyboard", HostBackChain().pushBack.tabBarVisible)
        assertFalse(
            "one pushed page hides the bar",
            HostBackChain().push(PdshRoute.WorkspaceFolders).pushBack.tabBarVisible,
        )
        assertFalse(
            "the keyboard hides the bar at depth 0",
            HostBackChain().withKeyboard(true).pushBack.tabBarVisible,
        )
        assertFalse(
            "depth 2 with the keyboard up",
            HostBackChain()
                .push(PdshRoute.WorkspaceFolders)
                .push(PdshRoute.Files("a"))
                .withKeyboard(true)
                .pushBack.tabBarVisible,
        )
    }

    @Test
    fun `re-tapping the selected tab is a no-op and never pops to root`() {
        val deep = HostBackChain().selectTab(HomeTab.DISCOVER)
            .push(PdshRoute.Bluetooth)
            .push(PdshRoute.AndroidAdb)
        assertEquals(HomeTab.DISCOVER, deep.pushBack.selectedTab)
        assertEquals(2, deep.depth)

        val reTap = deep.selectTab(HomeTab.DISCOVER)
        assertSame("a re-tap returns the same value", deep, reTap)
        assertEquals("the re-tap does not pop the stack", deep.nav, reTap.nav)

        val backToTasks = deep.selectTab(HomeTab.TASKS)
        assertEquals("TASKS is the floor", PdshNavState(listOf(PdshRoute.Chat)), backToTasks.nav)
        assertEquals("the target tab starts at its root", 0, backToTasks.depth)
    }

    @Test
    fun `popping to a tab root re-selects that tab`() {
        val stale = HostBackChain(
            nav = PdshNavState(listOf(PdshRoute.Chat)),
            pushBack = PushBackState(selectedTab = HomeTab.DISCOVER),
        ).push(PdshRoute.WorkspaceFolders)

        val after = stale.pop()
        assertEquals(PdshRoute.Chat, after.nav.current)
        assertEquals(HomeTab.TASKS, after.pushBack.selectedTab)
        assertEquals(0, after.depth)
    }

    @Test
    fun `pushing the chat route above another page is a level, not a new root`() {
        // 会话 → onOpenChat pushes Chat again. The first Chat is the tab floor;
        // the second is one page above it, so the bar leaves and back pops it.
        val chain = HostBackChain(nav = PdshNavState(listOf(PdshRoute.Chat, PdshRoute.Sessions)))
            .push(PdshRoute.Chat)

        assertEquals(2, chain.depth)
        assertFalse("a re-pushed tab root is still a pushed page", chain.pushBack.tabBarVisible)
        assertEquals(PdshRoute.Chat, chain.nav.current)
        assertEquals(PdshRoute.Sessions, chain.pop().nav.current)
        assertEquals(PdshRoute.Chat, chain.pop().pop().nav.current)
    }

    @Test
    fun `the page header back pops the route and the mirrored depth together`() {
        val deep = HostBackChain().push(PdshRoute.Settings).push(PdshRoute.Runtime)
        assertEquals(2, deep.depth)

        val popped = deep.pop()
        assertEquals(1, popped.depth)
        assertEquals(PdshRoute.Settings, popped.nav.current)
        assertEquals(1, popped.pushBack.depthOf(HomeTab.TASKS))

        assertEquals("the root is a fixed point", HostBackChain(), HostBackChain().pop())
    }

    @Test
    fun `a reset to the product floor drops the depth and the overlays`() {
        val open = HostBackChain()
            .push(PdshRoute.Settings)
            .openDrawer()
        val reset = open.resetTo(PdshRoute.Chat)

        assertEquals(PdshNavState(listOf(PdshRoute.Chat)), reset.nav)
        assertEquals(0, reset.depth)
        assertFalse(reset.drawerOpen)
        assertEquals("reset is the new-session/open-session floor", true, reset.pushBack.tabBarVisible)
    }

    @Test
    fun `the root back is an exit and carries no non-root layer`() {
        val root = HostBackChain()
        val result = dispatchBack(root.pushBack)

        assertTrue("depth 0 is the contract's exit", result.exited)
        assertEquals("exit does not change the stack", root, root.applyPushState(result.state))
        assertFalse("no callback-enabling layer remains", root.pushBack.canConsumeBack)
    }
}
