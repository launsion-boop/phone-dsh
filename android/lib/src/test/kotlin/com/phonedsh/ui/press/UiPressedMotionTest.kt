// Compose behaviour for spec/ui/v1/interaction.md §6 (pressed states).
// SPDX-License-Identifier: MIT
//
// The interaction source is driven directly so the assertions are about this
// component's transient state machine, not about Compose's gesture detector.
// The alpha exposed on the semantics node is the exact value the draw pass
// reads, so the animated overlay/fill targets are observable on the JVM.
//
// JVM coverage: rule 1 (release/cancel), rule 2/3 targets, rule 4's measured-size
// invariance, rule 6 (disabled gating). Not JVM-testable here: the *absence* of
// a platform ripple/elevation and the final composited pixel colour. Robolectric
// cannot force the hardware window redraw (`captureToImage` times out), and the
// modifiers install no ripple/elevation/scale by construction; the pixel proof
// belongs to the instrumented suite on a device renderer.
package com.phonedsh.ui.press

import androidx.activity.ComponentActivity
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.PressInteraction
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.unit.dp
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.phonedsh.ui.theme.LocalUiTokens
import com.phonedsh.ui.theme.PdshTheme
import com.phonedsh.ui.theme.generated.UiTokenData
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.annotation.Config

@RunWith(AndroidJUnit4::class)
@Config(sdk = [34], qualifiers = "w430dp-h932dp")
class UiPressedMotionTest {
    @get:Rule
    val compose = createAndroidComposeRule<ComponentActivity>()

    @Test
    fun `pill eases to 0_06, release and cancel snap to rest, size is unchanged`() {
        compose.mainClock.autoAdvance = false
        val source = MutableInteractionSource()
        mountPill(source, enabled = true)
        assertEquals("rest overlay", 0f, alpha(PILL), 0f)
        val restBounds = bounds(PILL)

        val press = PressInteraction.Press(Offset.Zero)
        emit(source, press)
        compose.mainClock.advanceTimeBy(60)
        val middle = alpha(PILL)
        assertTrue("press-in is animated, not a snap ($middle)", middle > 0f && middle < PRESSED_PILL)
        compose.mainClock.advanceTimeBy(100)
        assertEquals("rule 2/4: pill target after motion.pressed", PRESSED_PILL, alpha(PILL), 1e-4f)
        assertEquals("rule 4: pressed does not remeasure", restBounds, bounds(PILL))

        emit(source, PressInteraction.Release(press))
        settleRelease()
        assertEquals("rule 1: release reaches rest immediately", 0f, alpha(PILL), 0f)

        val cancelPress = PressInteraction.Press(Offset.Zero)
        emit(source, cancelPress)
        compose.mainClock.advanceTimeBy(200)
        assertEquals("pressed again for the cancel case", PRESSED_PILL, alpha(PILL), 1e-4f)
        emit(source, PressInteraction.Cancel(cancelPress))
        settleRelease()
        assertEquals("rule 1: cancel also returns to rest immediately", 0f, alpha(PILL), 0f)
    }

    @Test
    fun `row eases to 0_7 and release returns to rest`() {
        compose.mainClock.autoAdvance = false
        val source = MutableInteractionSource()
        mountRow(source, enabled = true)
        val restBounds = bounds(ROW)
        assertEquals("rest fill", 0f, alpha(ROW), 0f)

        val press = PressInteraction.Press(Offset.Zero)
        emit(source, press)
        compose.mainClock.advanceTimeBy(60)
        val middle = alpha(ROW)
        assertTrue("row press-in is animated ($middle)", middle > 0f && middle < PRESSED_ROW)
        compose.mainClock.advanceTimeBy(100)
        assertEquals("rule 2: row fill target", PRESSED_ROW, alpha(ROW), 1e-4f)
        assertEquals("rule 4: row does not remeasure", restBounds, bounds(ROW))

        emit(source, PressInteraction.Release(press))
        settleRelease()
        assertEquals("rule 1: row release", 0f, alpha(ROW), 0f)
    }

    @Test
    fun `primary dims its whole content to 0_8 and returns to rest`() {
        compose.mainClock.autoAdvance = false
        val source = MutableInteractionSource()
        mountPrimary(source, enabled = true)
        assertEquals("rest content alpha", 1f, alpha(PRIMARY), 0f)
        assertEquals("rest fill", 1f, backgroundAlpha(PRIMARY), 0f)
        val restBounds = bounds(PRIMARY)

        val press = PressInteraction.Press(Offset.Zero)
        emit(source, press)
        compose.mainClock.advanceTimeBy(60)
        val middle = alpha(PRIMARY)
        assertTrue("primary press-in is animated ($middle)", middle < 1f && middle > PRESSED_PRIMARY)
        compose.mainClock.advanceTimeBy(100)
        assertEquals("rule 3: whole-content target", PRESSED_PRIMARY, alpha(PRIMARY), 1e-4f)
        assertEquals("rule 4: primary does not remeasure", restBounds, bounds(PRIMARY))

        emit(source, PressInteraction.Release(press))
        settleRelease()
        assertEquals("rule 1: primary release", 1f, alpha(PRIMARY), 0f)
    }

    @Test
    fun `disabled surfaces ignore a press and never enter pressed`() {
        compose.mainClock.autoAdvance = false
        val pill = MutableInteractionSource()
        val row = MutableInteractionSource()
        val primary = MutableInteractionSource()
        mountAllStylesDisabled(pill, row, primary)

        val press = PressInteraction.Press(Offset.Zero)
        runBlocking {
            pill.emit(press)
            row.emit(press)
            primary.emit(press)
        }
        compose.mainClock.advanceTimeBy(300)

        assertEquals("rule 6: disabled pill stays at rest", 0f, alpha(PILL), 0f)
        assertEquals("rule 6: disabled row stays at rest", 0f, alpha(ROW), 0f)
        assertEquals("rule 6: disabled primary content stays opaque", 1f, alpha(PRIMARY), 0f)
        assertEquals(
            "rule 3: disabled primary fill is 0.25, not pressed",
            UiTokenData.pressed.primaryDisabledOpacity,
            backgroundAlpha(PRIMARY),
            0f,
        )
    }

    @Test
    fun `primary disabled fill uses 0_25 while the content stays opaque`() {
        compose.mainClock.autoAdvance = false
        val source = MutableInteractionSource()
        mountPrimary(source, enabled = false)
        assertEquals("rule 6: disabled content alpha is rest", 1f, alpha(PRIMARY), 0f)
        assertEquals(
            "rule 3: disabled background alpha reads the generated value",
            UiTokenData.pressed.primaryDisabledOpacity,
            backgroundAlpha(PRIMARY),
            0f,
        )
    }

    private fun mountPill(source: MutableInteractionSource, enabled: Boolean) {
        compose.setContent {
            PdshTheme(darkTheme = false) {
                Box(Modifier.fillMaxSize().background(Color.White), contentAlignment = Alignment.Center) {
                    Box(
                        Modifier
                            .size(120.dp, 56.dp)
                            .background(Color.White)
                            .testTag(PILL)
                            .pillPressed(source, enabled)
                            .clickable(
                                interactionSource = source,
                                indication = null,
                                enabled = enabled,
                                role = Role.Button,
                            ) {},
                    )
                }
            }
        }
    }

    private fun mountRow(source: MutableInteractionSource, enabled: Boolean) {
        compose.setContent {
            PdshTheme(darkTheme = false) {
                Box(Modifier.fillMaxSize().background(Color.White), contentAlignment = Alignment.Center) {
                    Box(
                        Modifier
                            .size(220.dp, 48.dp)
                            .background(Color.White)
                            .testTag(ROW)
                            .rowPressed(source, enabled, RoundedCornerShape(12.dp))
                            .clickable(
                                interactionSource = source,
                                indication = null,
                                enabled = enabled,
                                role = Role.Button,
                            ) {},
                    )
                }
            }
        }
    }

    private fun mountPrimary(source: MutableInteractionSource, enabled: Boolean) {
        compose.setContent {
            PdshTheme(darkTheme = false) {
                Box(Modifier.fillMaxSize().background(Color.White), contentAlignment = Alignment.Center) {
                    PrimaryBox(source, enabled)
                }
            }
        }
    }

    private fun mountAllStylesDisabled(
        pill: MutableInteractionSource,
        row: MutableInteractionSource,
        primary: MutableInteractionSource,
    ) {
        compose.setContent {
            PdshTheme(darkTheme = false) {
                Column(Modifier.fillMaxSize().background(Color.White)) {
                    Box(Modifier.size(120.dp, 56.dp).testTag(PILL).pillPressed(pill, enabled = false))
                    Box(
                        Modifier
                            .size(220.dp, 48.dp)
                            .testTag(ROW)
                            .rowPressed(row, enabled = false, shape = RoundedCornerShape(12.dp)),
                    )
                    PrimaryBox(primary, enabled = false)
                }
            }
        }
    }

    @Composable
    private fun PrimaryBox(source: MutableInteractionSource, enabled: Boolean) {
        val tokens = LocalUiTokens.current
        Box(
            Modifier
                .size(200.dp, 50.dp)
                .background(Color.White)
                .testTag(PRIMARY)
                .primaryPressed(
                    interactionSource = source,
                    backgroundColor = tokens.colors.primaryButton,
                    shape = RoundedCornerShape(percent = 50),
                    enabled = enabled,
                )
                .clickable(
                    interactionSource = source,
                    indication = null,
                    enabled = enabled,
                    role = Role.Button,
                ) {},
        )
    }

    private fun alpha(tag: String): Float =
        compose.onNodeWithTag(tag).fetchSemanticsNode().config[PressedAlphaSemantics]

    private fun backgroundAlpha(tag: String): Float =
        compose.onNodeWithTag(tag).fetchSemanticsNode().config[PressedBackgroundAlphaSemantics]

    private fun bounds(tag: String): androidx.compose.ui.geometry.Rect =
        compose.onNodeWithTag(tag).fetchSemanticsNode().boundsInRoot

    private fun emit(source: MutableInteractionSource, interaction: PressInteraction) {
        runBlocking { source.emit(interaction) }
    }

    /** A release/cancel is applied on the next composition, then the snap lands. */
    private fun settleRelease() {
        compose.waitForIdle()
        repeat(3) { compose.mainClock.advanceTimeByFrame() }
    }

    private companion object {
        const val PILL = "press.pill"
        const val ROW = "press.row"
        const val PRIMARY = "press.primary"

        // The generated table, read through the same pure function the component
        // uses. The assertions below intentionally compare against it rather
        // than a second hand-typed number.
        val PRESSED_PILL: Float
            get() = PressedStyle.valuesFor(PressedSurface.DrawerPill, PressedState.Pressed).alpha
        val PRESSED_ROW: Float
            get() = PressedStyle.valuesFor(PressedSurface.DrawerRow, PressedState.Pressed).alpha
        val PRESSED_PRIMARY: Float
            get() = PressedStyle.valuesFor(PressedSurface.PrimaryButton, PressedState.Pressed).alpha
    }
}
