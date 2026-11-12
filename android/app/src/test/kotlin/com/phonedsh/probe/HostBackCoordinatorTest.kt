// The real `BackCoordinator` mounted in a real Activity, driven by platform back.
// SPDX-License-Identifier: MIT
//
// The pure state machine and the shared golden live in `HostBackChainTest`. This
// file is the behaviour test on the composed surface: the coordinator's callback
// is the only registered back path, a committed gesture runs one transition, and
// a cancelled predictive gesture publishes nothing. Robolectric + a
// `ComponentActivity` is a JVM host, not a device test.
package com.phonedsh.probe

import android.os.Looper
import androidx.activity.BackEventCompat
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import com.phonedsh.ui.nav.BackCoordinator
import com.phonedsh.ui.nav.HomeTab
import com.phonedsh.ui.nav.PushBackLayer
import com.phonedsh.ui.nav.PushBackState
import com.phonedsh.ui.nav.PushOverlay
import com.phonedsh.ui.sheet.SheetBackHost
import com.phonedsh.ui.theme.PdshTheme
import com.phonedsh.ui.theme.generated.TokenBackLayer
import org.junit.Assert.assertEquals
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
class HostBackCoordinatorTest {
    private lateinit var activity: ComponentActivity
    private var state by mutableStateOf(PushBackState())

    @Before
    fun setUp() {
        activity = Robolectric.buildActivity(ComponentActivity::class.java).setup().get()
    }

    private fun idle() {
        shadowOf(Looper.getMainLooper()).idle()
    }

    private fun mount(onExit: (() -> Unit)? = null, layers: List<PushBackLayer> = emptyList()) {
        activity.setContent {
            PdshTheme(darkTheme = false) {
                BackCoordinator(
                    state = state,
                    onStateChange = { state = it },
                    layers = layers,
                    onExit = onExit,
                )
            }
        }
        idle()
    }

    private fun systemBack() {
        activity.onBackPressedDispatcher.onBackPressed()
        idle()
    }

    @Test
    fun `one committed gesture pops exactly one page of the mirrored stack`() {
        state = PushBackState(stackDepths = mapOf(HomeTab.TASKS to 2))
        val backLevel = com.phonedsh.ui.nav.PdshBackLevel()
        mount(layers = listOf(observingBackLayer(TokenBackLayer.STACK) { backLevel.consume() }))

        systemBack()
        assertEquals("the first back pops one page", 1, state.depth)
        systemBack()
        assertEquals("the root is reached without a second pop", 0, state.depth)
    }

    @Test
    fun `the root registers no behaviour of its own, so the platform finishes`() {
        state = PushBackState()
        mount()

        systemBack()
        assertTrue(
            "depth 0 is the platform's own exit, not a host transition",
            activity.isFinishing,
        )
        assertEquals(0, state.depth)
    }

    @Test
    fun `predictive progress and cancel leave the state untouched`() {
        state = PushBackState(stackDepths = mapOf(HomeTab.TASKS to 1))
        val backLevel = com.phonedsh.ui.nav.PdshBackLevel()
        mount(layers = listOf(observingBackLayer(TokenBackLayer.STACK) { backLevel.consume() }))
        val before = state
        val dispatcher = activity.onBackPressedDispatcher

        dispatcher.dispatchOnBackStarted(BackEventCompat(0f, 0f, 0.1f, BackEventCompat.EDGE_LEFT))
        idle()
        dispatcher.dispatchOnBackProgressed(BackEventCompat(0f, 0f, 0.8f, BackEventCompat.EDGE_LEFT))
        idle()
        assertSame("progress must not change the depth", before, state)
        assertTrue(
            "the coordinator forwards the gesture to the observing layer",
            PredictiveBack.observedOnThisDevice,
        )

        dispatcher.dispatchOnBackCancelled()
        idle()
        assertSame("a cancelled gesture restores nothing-changed", before, state)
    }

    @Test
    fun `the sheet layer closes a mounted sheet before the page stack`() {
        // depth 2 and a sheet overlay: the generated back order puts SHEET
        // first, so the sheet closes while the host stack stays at 2. The
        // next gesture falls through to the STACK layer and pops one page.
        state = PushBackState(
            stackDepths = mapOf(HomeTab.TASKS to 2),
            overlays = listOf(PushOverlay.SHEET),
        )
        val sheetHost = SheetBackHost()
        val backLevel = com.phonedsh.ui.nav.PdshBackLevel()
        mount(
            layers = listOf(
                observingBackLayer(TokenBackLayer.SHEET) { sheetHost.dispatch() },
                observingBackLayer(TokenBackLayer.STACK) { backLevel.consume() },
            ),
        )

        systemBack()
        assertEquals("the sheet layer is consumed first", emptyList<PushOverlay>(), state.overlays)
        assertEquals("the page stack is untouched", 2, state.depth)

        systemBack()
        assertEquals("the next back pops one page", 1, state.depth)
    }

    @Test
    fun `the route-inner level is asked before the stack pops`() {
        state = PushBackState(stackDepths = mapOf(HomeTab.TASKS to 1))
        var innerSteps = 1
        val routeLevel = object : PushBackLayer {
            override val layer: TokenBackLayer = TokenBackLayer.STACK
            override fun consumeBack(): Boolean {
                if (innerSteps == 0) return false
                innerSteps -= 1
                return true
            }
        }
        mount(layers = listOf(routeLevel))

        systemBack()
        assertEquals("the inner step consumed the gesture", 0, innerSteps)
        assertEquals("the mirrored depth is unchanged", 1, state.depth)

        systemBack()
        assertEquals("at the inner root the stack pops", 0, state.depth)
    }
}
