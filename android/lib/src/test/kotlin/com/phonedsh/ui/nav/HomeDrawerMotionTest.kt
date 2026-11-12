// Contract motion + drag + back behaviour for the home drawer.
// SPDX-License-Identifier: MIT
package com.phonedsh.ui.nav

import androidx.activity.ComponentActivity
import androidx.activity.OnBackPressedDispatcherOwner
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.performSemanticsAction
import androidx.compose.ui.test.performTouchInput
import androidx.compose.ui.semantics.SemanticsActions
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.phonedsh.ui.theme.PdshTheme
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.annotation.Config
import org.robolectric.shadows.ShadowDialog
import kotlin.math.roundToLong

@RunWith(AndroidJUnit4::class)
@Config(sdk = [34], qualifiers = "w411dp-h891dp")
class HomeDrawerMotionTest {
    @get:Rule
    val compose = createAndroidComposeRule<ComponentActivity>()

    private val density: Float get() = compose.activity.resources.displayMetrics.density
    private val closedOffset: Float
        get() = -(UiDrawerTokens.width + UiDrawerTokens.closedOverhang)

    @Test
    fun `open animates from the closed overhang to zero over 280ms`() {
        compose.mainClock.autoAdvance = false
        mount()
        compose.onNodeWithTag(HomeDrawerTags.PANEL).assertExists()
        val start = panelLeftDp()
        assertEquals("open frame 0 starts at -(width + overhang)", closedOffset, start, 1f)

        // The dialog's first frame is not necessarily animation time 0. Observe
        // the first frame that moved, invert the contract curve to recover the
        // start instant, then sample exactly 140 ms and 280 ms after it.
        var moved = 0f
        while (moved < 0.2f) {
            compose.mainClock.advanceTimeByFrame()
            moved = (closedOffset - panelLeftDp()) / closedOffset
        }
        val observedAt = compose.mainClock.currentTime
        val elapsedAtMove = elapsedForProgress(moved)
        val startedAt = observedAt - elapsedAtMove

        compose.mainClock.advanceTimeBy((startedAt + 140.0 - observedAt).roundToLong())
        val atMiddle = compose.mainClock.currentTime
        val elapsed = atMiddle - startedAt
        assertTrue("the middle sample is within one frame of 140 ms", kotlin.math.abs(elapsed - 140.0) <= 16.0)
        val expectedMiddle = (closedOffset * (1.0 - easeInOut(elapsed / 280.0))).toFloat()
        assertEquals("the panel follows easeInOut at the middle sample", expectedMiddle, panelLeftDp(), 1f)

        compose.mainClock.advanceTimeBy(200)
        assertEquals("open frame 280 is fully open", 0f, panelLeftDp(), 1f)
    }

    @Test
    fun `scrim tap keeps the panel until the 220ms close animation ends`() {
        compose.mainClock.autoAdvance = false
        var closed = false
        mount(onClose = { closed = true })
        compose.mainClock.advanceTimeBy(300)
        compose.mainClock.advanceTimeByFrame()

        compose.onNodeWithTag(HomeDrawerTags.SCRIM).performSemanticsAction(SemanticsActions.OnClick)
        compose.mainClock.advanceTimeBy(110)
        compose.onNodeWithTag(HomeDrawerTags.PANEL).assertExists()
        assertFalse("onClose must wait for the close animation", closed)

        compose.mainClock.advanceTimeBy(160)
        compose.mainClock.advanceTimeByFrame()
        compose.onNodeWithTag(HomeDrawerTags.PANEL).assertDoesNotExist()
        assertTrue("the host is told after the close animation", closed)
    }

    @Test
    fun `a slow 170dp drag closes with the close motion`() {
        compose.mainClock.autoAdvance = false
        mount()
        compose.mainClock.advanceTimeBy(300)
        compose.mainClock.advanceTimeByFrame()

        dragPanel(steps = 20, stepDp = -8.5f, eventMillis = 50)
        compose.mainClock.advanceTimeBy(110)
        compose.onNodeWithTag(HomeDrawerTags.PANEL).assertExists()
        compose.mainClock.advanceTimeBy(160)
        compose.mainClock.advanceTimeByFrame()
        compose.onNodeWithTag(HomeDrawerTags.PANEL).assertDoesNotExist()
    }

    @Test
    fun `a slow 100dp drag settles back to zero`() {
        compose.mainClock.autoAdvance = false
        mount()
        compose.mainClock.advanceTimeBy(300)
        compose.mainClock.advanceTimeByFrame()

        dragPanel(steps = 20, stepDp = -5f, eventMillis = 50)
        compose.mainClock.advanceTimeBy(300)
        compose.mainClock.advanceTimeByFrame()
        compose.onNodeWithTag(HomeDrawerTags.PANEL).assertExists()
        assertEquals("a below-threshold release settles to 0", 0f, panelLeftDp(), 1f)
    }

    @Test
    fun `a vertical drag in the list does not move the panel`() {
        compose.mainClock.autoAdvance = false
        mount()
        compose.mainClock.advanceTimeBy(300)
        compose.mainClock.advanceTimeByFrame()
        val before = panelLeftDp()

        compose.onNodeWithTag(HomeDrawerTags.SCROLL).performTouchInput {
            down(center)
            repeat(10) {
                advanceEventTime(30)
                moveBy(Offset(0f, -20f * density))
            }
            up()
        }
        compose.mainClock.advanceTimeBy(300)
        assertEquals("a vertical list scroll must not drag the drawer", before, panelLeftDp(), 0.5f)
    }

    @Test
    fun `system back closes the drawer with the close animation`() {
        compose.mainClock.autoAdvance = false
        var closed = false
        mount(onClose = { closed = true })
        compose.mainClock.advanceTimeBy(300)
        compose.mainClock.advanceTimeByFrame()

        val dialog = ShadowDialog.getLatestDialog()
        (dialog as OnBackPressedDispatcherOwner).onBackPressedDispatcher.onBackPressed()
        compose.mainClock.advanceTimeByFrame()
        compose.mainClock.advanceTimeBy(110)
        compose.onNodeWithTag(HomeDrawerTags.PANEL).assertExists()
        assertFalse("back must not dismiss instantly", closed)

        compose.mainClock.advanceTimeBy(160)
        compose.mainClock.advanceTimeByFrame()
        compose.onNodeWithTag(HomeDrawerTags.PANEL).assertDoesNotExist()
        assertTrue("back reports the dismissal after the animation", closed)
    }

    private fun mount(
        onClose: () -> Unit = {},
        openState: androidx.compose.runtime.MutableState<Boolean>? = null,
    ) {
        val facts = HomeDrawerFacts(
            folders = listOf(
                HomeDrawerFolder(
                    id = "daily",
                    title = "日常",
                    sessions = (1..12).map { HomeDrawerSession("s$it", "会话$it") },
                    isDefault = true,
                ),
            ),
            unassignedSessions = emptyList(),
        )
        compose.setContent {
            PdshTheme(darkTheme = false) {
                Box(Modifier.fillMaxSize()) {
                    var localOpen by remember { mutableStateOf(true) }
                    val open = openState?.value ?: localOpen
                    HomeDrawer(
                        facts = facts,
                        isOpen = open,
                        onClose = {
                            if (openState != null) openState.value = false else localOpen = false
                            onClose()
                        },
                        onCreateSession = { true },
                    )
                }
            }
        }
    }

    private fun panelLeftDp(): Float =
        compose.onNodeWithTag(HomeDrawerTags.PANEL).fetchSemanticsNode().boundsInRoot.left / density

    private fun dragPanel(steps: Int, stepDp: Float, eventMillis: Long) {
        compose.onNodeWithTag(HomeDrawerTags.PANEL).performTouchInput {
            down(center)
            repeat(steps) {
                advanceEventTime(eventMillis)
                moveBy(Offset(stepDp * density, 0f))
            }
            up()
        }
    }

    /** The contract's cubic-bezier(0.42, 0, 0.58, 1) y for a time fraction x. */
    private fun easeInOut(x: Double): Double {
        var lo = 0.0
        var hi = 1.0
        repeat(40) {
            val mid = (lo + hi) / 2.0
            if (bezier(mid, 0.42, 0.58) < x) lo = mid else hi = mid
        }
        return bezier((lo + hi) / 2.0, 0.0, 1.0)
    }

    /** Inverts [easeInOut] to the elapsed milliseconds that reach [progress]. */
    private fun elapsedForProgress(progress: Float): Double {
        var lo = 0.0
        var hi = 1.0
        repeat(40) {
            val mid = (lo + hi) / 2.0
            if (easeInOut(mid) < progress) lo = mid else hi = mid
        }
        return ((lo + hi) / 2.0) * 280.0
    }

    private fun bezier(t: Double, p1: Double, p2: Double): Double {
        val u = 1.0 - t
        return 3.0 * u * u * t * p1 + 3.0 * u * t * t * p2 + t * t * t
    }

    private object UiDrawerTokens {
        val width: Float = com.phonedsh.ui.theme.generated.UiTokenData.drawer.width.value
        val closedOverhang: Float =
            com.phonedsh.ui.theme.generated.UiTokenData.drawer.closedOverhangPt
    }
}
