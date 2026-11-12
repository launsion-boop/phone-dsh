// The host's shared sheet layer, wired the way `HostShell` wires it.
// SPDX-License-Identifier: MIT
//
// `HostShell` owns one `SheetBackHost`, registers it as the `SHEET` layer of
// `interaction.md` §4 rule 5, and hands the same instance to `PdshNavHost`, which
// provides it through `LocalSheetBackHost`. This file proves that host half on the
// real app state machine:
//
//   * the instance the router provides to route content is the host's shared one
//     (and an absent host leaves the local empty);
//   * `HostBackChain` records the sheet overlay while a sheet-presented route is
//     current, one committed back consumes exactly that layer, and the sheet-route
//     pop clears the overlay without touching the page under it.
//
// The real `PdshSheet` dismissal (platform hide animation, one sheet per back) is
// driven in `:lib` (`PdshSheetRoutesTest`, `LocalSheetBackHostTest`); `:app`'s unit
// tests do not enable Android resources, so a Material3 sheet cannot be composed
// here. Robolectric + a `ComponentActivity` is a JVM host, not a device test.
package com.phonedsh.probe

import android.os.Looper
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.text.BasicText
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import com.phonedsh.ui.nav.BackDispatch
import com.phonedsh.ui.nav.HomeTab
import com.phonedsh.ui.nav.PdshNavFacts
import com.phonedsh.ui.nav.PdshNavHost
import com.phonedsh.ui.nav.PdshNavState
import com.phonedsh.ui.nav.PdshRoute
import com.phonedsh.ui.nav.PushBackState
import com.phonedsh.ui.nav.PushOverlay
import com.phonedsh.ui.nav.dispatchBack
import com.phonedsh.ui.sheet.LocalSheetBackHost
import com.phonedsh.ui.sheet.SheetBackHost
import com.phonedsh.ui.theme.PdshTheme
import com.phonedsh.ui.theme.generated.TokenBackLayer
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34], qualifiers = "w411dp-h891dp")
class HostSheetLayerTest {
    private lateinit var activity: ComponentActivity
    private val sheetHost = SheetBackHost()
    private var chain by mutableStateOf(HostBackChain())

    @Before
    fun setUp() {
        activity = Robolectric.buildActivity(ComponentActivity::class.java).setup().get()
    }

    private fun mount(
        host: SheetBackHost? = sheetHost,
        slot: (@Composable () -> Unit)? = null,
    ) {
        activity.setContent {
            PdshTheme(darkTheme = false) {
                PdshNavHost(
                    nav = PdshNavState(listOf(PdshRoute.Chat, PdshRoute.Sessions)),
                    facts = PdshNavFacts(),
                    onNavigate = {},
                    onBack = {},
                    onHome = {},
                    onHostAction = {},
                    home = { BasicText("home") },
                    webSurface = {},
                    sessions = slot,
                    sheetBackHost = host,
                )
            }
        }
        shadowOf(Looper.getMainLooper()).idle()
    }

    @Test
    fun `the host's shared chain is the instance route content resolves`() {
        var seen: SheetBackHost? = null
        mount(
            slot = {
                seen = LocalSheetBackHost.current
                BasicText("host session slot")
            },
        )
        assertSame("HostShell's instance is the one pages receive", sheetHost, seen)
    }

    @Test
    fun `a host that passes no chain leaves the local empty`() {
        var seen: SheetBackHost? = sheetHost
        mount(
            host = null,
            slot = {
                seen = LocalSheetBackHost.current
                BasicText("host session slot")
            },
        )
        assertNull("sheets fall back to their private chain", seen)
    }

    @Test
    fun `the app chain records the sheet overlay and one back consumes it`() {
        chain = HostBackChain(
            nav = PdshNavState(listOf(PdshRoute.Chat, PdshRoute.Settings)),
            pushBack = PushBackState(
                stackDepths = mapOf(HomeTab.TASKS to 1),
                overlays = listOf(PushOverlay.SHEET),
            ),
        )
        // The host's SHEET delegate: a mounted sheet consumes the layer.
        val sheetLayer = observingBackLayer(TokenBackLayer.SHEET) { true }

        val committed: BackDispatch = dispatchBack(chain.pushBack, listOf(sheetLayer))
        assertTrue("the sheet layer is the first layer in backOrder", committed.consumedByLayer)
        assertEquals("a layer that consumed the gesture publishes no state change", chain, chain.applyPushState(committed.state))
        assertTrue("the host records the sheet layer", PushOverlay.SHEET in chain.pushBack.overlays)

        // The sheet component reports its dismissal after the platform hide; the
        // host pops the sheet route and clears the overlay it recorded.
        val popped = chain.pop()
        val closed = popped.copy(
            pushBack = popped.pushBack.closeOverlay(PushOverlay.SHEET),
        )
        assertEquals("the sheet layer is consumed", emptyList<PushOverlay>(), closed.pushBack.overlays)
        assertEquals(
            "the page the sheet covered stays current",
            listOf(PdshRoute.Chat),
            closed.nav.stack,
        )
        assertEquals("the sheet route was the only popped level", 0, closed.pushBack.depth)
    }

    @Test
    fun `a non-sheet page never records the sheet overlay`() {
        chain = HostBackChain(
            nav = PdshNavState(listOf(PdshRoute.Chat, PdshRoute.Files("notes"))),
            pushBack = PushBackState(stackDepths = mapOf(HomeTab.TASKS to 1)),
        )
        val sheetLayer = observingBackLayer(TokenBackLayer.SHEET) { false }

        val committed = dispatchBack(chain.pushBack, listOf(sheetLayer))

        assertEquals("no sheet is mounted, so the stack layer is the top layer", TokenBackLayer.STACK, committed.layer)
        assertEquals("the stack layer pops one level", 0, committed.state.depth)
        assertTrue("the host records no sheet overlay", PushOverlay.SHEET !in committed.state.overlays)
    }
}
