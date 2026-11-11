// Compose-glue behaviour for the layered back chain (`interaction.md` §4).
// SPDX-License-Identifier: MIT
package com.phonedsh.ui.nav

import androidx.activity.BackEventCompat
import androidx.activity.ComponentActivity
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.phonedsh.ui.theme.PdshTheme
import com.phonedsh.ui.theme.generated.TokenBackLayer
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.annotation.Config

@RunWith(AndroidJUnit4::class)
@Config(sdk = [34], qualifiers = "w411dp-h891dp")
class BackCoordinatorTest {
    @get:Rule
    val compose = createAndroidComposeRule<ComponentActivity>()

    private var state by mutableStateOf(PushBackState())

    private fun mount(
        layers: List<PushBackLayer> = emptyList(),
        onExit: (() -> Unit)? = null,
    ) {
        compose.setContent {
            PdshTheme(darkTheme = false) {
                BackCoordinator(
                    state = state,
                    onStateChange = { state = it },
                    layers = layers,
                    onExit = onExit,
                )
            }
        }
        compose.waitForIdle()
    }

    private fun systemBack() {
        compose.runOnIdle { compose.activity.onBackPressedDispatcher.onBackPressed() }
        compose.waitForIdle()
    }

    @Test
    fun `committed back pops exactly one stack level`() {
        state = PushBackState(stackDepths = mapOf(HomeTab.TASKS to 2))
        mount()

        systemBack()
        assertEquals("one committed gesture pops one level", 1, state.depth)
        systemBack()
        assertEquals("the root is reached without a second pop", 0, state.depth)
        assertEquals("the stack was not cleared before its turn", 0, state.depthOf(HomeTab.DISCOVER))
    }

    @Test
    fun `predictive progress does not change state and cancel restores nothing-changed`() {
        state = PushBackState(
            stackDepths = mapOf(HomeTab.TASKS to 1),
            overlays = listOf(PushOverlay.SHEET),
        )
        val calls = mutableListOf<String>()
        val sheet = object : PushBackLayer {
            override val layer: TokenBackLayer = TokenBackLayer.SHEET
            override fun consumeBack(): Boolean = false
            override fun onPredictiveBackStarted() {
                calls += "started"
            }

            override fun onPredictiveBackProgressed(progress: Float) {
                calls += "progress:$progress"
            }

            override fun onPredictiveBackCancelled() {
                calls += "cancelled"
            }
        }
        mount(layers = listOf(sheet))

        val before = state
        val dispatcher = compose.activity.onBackPressedDispatcher
        compose.runOnIdle {
            dispatcher.dispatchOnBackStarted(BackEventCompat(0f, 0f, 0.1f, BackEventCompat.EDGE_LEFT))
        }
        compose.waitForIdle()
        compose.runOnIdle {
            dispatcher.dispatchOnBackProgressed(BackEventCompat(0f, 0f, 0.7f, BackEventCompat.EDGE_LEFT))
        }
        compose.waitForIdle()
        assertSame("progress must not change the state", before, state)

        compose.runOnIdle { dispatcher.dispatchOnBackCancelled() }
        compose.waitForIdle()
        assertSame("cancel restores nothing-changed", before, state)
        assertEquals("started is forwarded once", 1, calls.count { it == "started" })
        assertTrue("progress is forwarded to the layer", calls.any { it.startsWith("progress:") })
        assertTrue("cancel is forwarded to the layer", calls.contains("cancelled"))
    }

    @Test
    fun `predictive commit equals a non-predictive back`() {
        state = PushBackState(stackDepths = mapOf(HomeTab.TASKS to 1))
        mount()
        val dispatcher = compose.activity.onBackPressedDispatcher

        compose.runOnIdle {
            dispatcher.dispatchOnBackStarted(BackEventCompat(0f, 0f, 0.1f, BackEventCompat.EDGE_LEFT))
            dispatcher.dispatchOnBackProgressed(BackEventCompat(0f, 0f, 0.8f, BackEventCompat.EDGE_LEFT))
            dispatcher.onBackPressed()
        }
        compose.waitForIdle()
        assertEquals("the committed gesture ran the same transition", 0, state.depth)
    }

    @Test
    fun `the sheet's inner stack pops before the sheet closes`() {
        state = PushBackState(
            stackDepths = mapOf(HomeTab.TASKS to 1),
            overlays = listOf(PushOverlay.SHEET),
        )
        var innerDepth = 1
        val sheet = object : PushBackLayer {
            override val layer: TokenBackLayer = TokenBackLayer.SHEET
            override fun consumeBack(): Boolean {
                if (innerDepth == 0) return false
                innerDepth -= 1
                return true
            }
        }
        mount(layers = listOf(sheet))

        systemBack()
        assertEquals("the sheet's child page consumed the gesture", 0, innerDepth)
        assertEquals("the sheet is still open", listOf(PushOverlay.SHEET), state.overlays)
        assertEquals("the host stack is untouched", 1, state.depth)

        systemBack()
        assertTrue("the sheet closes only after its inner stack", state.overlays.isEmpty())
        assertEquals("closing the sheet does not pop the host stack", 1, state.depth)
    }

    @Test
    fun `root back exits through the host callback`() {
        state = PushBackState()
        var exits = 0
        mount(onExit = { exits += 1 })

        systemBack()
        assertEquals("the root back is the exit", 1, exits)
        assertEquals("exit does not create a stack entry", 0, state.depth)
        assertTrue("the root remains the root", state.overlays.isEmpty())
        assertFalse("the root has no non-root layer left", state.canConsumeBack)
    }
}
