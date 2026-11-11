// Compose behaviour for the §5 send/stop keys (JVM + Robolectric).
// SPDX-License-Identifier: MIT
//
// The golden truth table lives in UiComposerSendContractTest; this file pins the
// parts only a composition can observe: the 36 pt click circle, disabled
// visibility/non-submission, stop-first order with the rule 1 gap, the verbatim
// accessibility labels, and the canSubmit-keyed 120 ms transition.
package com.phonedsh.ui.composer

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertIsNotEnabled
import androidx.compose.ui.test.click
import androidx.compose.ui.test.getUnclippedBoundsInRoot
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performTextInput
import androidx.compose.ui.test.performTouchInput
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.phonedsh.ui.UiStrings
import com.phonedsh.ui.UiTags
import com.phonedsh.ui.theme.PdshTheme
import com.phonedsh.ui.theme.generated.UiTokenData
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.annotation.Config

@RunWith(AndroidJUnit4::class)
@Config(sdk = [34], qualifiers = "w411dp-h891dp")
class ComposerSendBehaviorTest {
    @get:Rule
    val compose = createComposeRule()

    @Test
    fun `the send key's click area is the 36 dp circle`() {
        var sent = 0
        compose.setContent {
            PdshTheme(darkTheme = false) {
                PdshSendButton(
                    canSubmit = true,
                    turnRunning = false,
                    steer = false,
                    onClick = { sent += 1 },
                )
            }
        }
        val bounds = compose.onNodeWithTag(UiTags.COMPOSER_SEND).getUnclippedBoundsInRoot()
        assertEquals(36f, (bounds.right - bounds.left).value, 0.5f)
        assertEquals(36f, (bounds.bottom - bounds.top).value, 0.5f)
        compose.onNodeWithContentDescription(UiStrings.COMPOSER_SEND_LABEL).assertExists()
        compose.onNodeWithTag(UiTags.COMPOSER_SEND).performClick()
        assertEquals(1, sent)
    }

    @Test
    fun `a disabled send key stays visible and never submits`() {
        var sent = 0
        compose.setContent {
            PdshTheme(darkTheme = false) {
                PdshSendButton(
                    canSubmit = false,
                    turnRunning = false,
                    steer = false,
                    onClick = { sent += 1 },
                )
            }
        }
        compose.onNodeWithTag(UiTags.COMPOSER_SEND).assertIsDisplayed()
        compose.onNodeWithTag(UiTags.COMPOSER_SEND).assertIsNotEnabled()
        compose.onNodeWithContentDescription(UiStrings.COMPOSER_SEND_LABEL).assertExists()
        compose.onNodeWithTag(UiTags.COMPOSER_SEND).performTouchInput { click() }
        assertEquals("a disabled send key must not submit", 0, sent)
    }

    @Test
    fun `the stop key reports its callback and its stopping label`() {
        var stopped = 0
        val stopping = mutableStateOf(false)
        compose.setContent {
            PdshTheme(darkTheme = false) {
                PdshStopButton(
                    onClick = { stopped += 1 },
                    stopping = stopping.value,
                )
            }
        }
        compose.onNodeWithContentDescription(UiStrings.COMPOSER_STOP_LABEL).assertExists()
        compose.onNodeWithTag(UiTags.COMPOSER_STOP).performClick()
        assertEquals(1, stopped)

        stopping.value = true
        compose.waitForIdle()
        compose.onNodeWithContentDescription(UiStrings.COMPOSER_STOPPING).assertExists()
        compose.onNodeWithTag(UiTags.COMPOSER_STOP).performClick()
        assertEquals("the stopping guard suppresses a repeat stop", 1, stopped)
    }

    @Test
    fun `rule 1 shows send, stop or both in the frozen states`() {
        val canSubmit = mutableStateOf(false)
        val turnRunning = mutableStateOf(true)
        compose.setContent {
            PdshTheme(darkTheme = false) {
                PdshComposerSendKeys(
                    canSubmit = canSubmit.value,
                    turnRunning = turnRunning.value,
                    steer = false,
                    onSend = {},
                    onStop = {},
                )
            }
        }

        // Running and not submittable: the stop key takes the send slot.
        compose.onNodeWithTag(UiTags.COMPOSER_SEND).assertDoesNotExist()
        compose.onNodeWithTag(UiTags.COMPOSER_STOP).assertIsDisplayed()

        // Running and submittable: both, stop first.
        canSubmit.value = true
        compose.waitForIdle()
        compose.onNodeWithTag(UiTags.COMPOSER_SEND).assertIsDisplayed()
        compose.onNodeWithTag(UiTags.COMPOSER_STOP).assertIsDisplayed()
        val stop = compose.onNodeWithTag(UiTags.COMPOSER_STOP).getUnclippedBoundsInRoot()
        val send = compose.onNodeWithTag(UiTags.COMPOSER_SEND).getUnclippedBoundsInRoot()
        assertTrue("the stop key comes first", stop.right.value <= send.left.value)
        val gap = send.left - stop.right
        assertEquals(ComposerSendRule.STOP_SEND_GAP.value, gap.value, 0.5f)

        // Idle: only the send key.
        turnRunning.value = false
        compose.waitForIdle()
        compose.onNodeWithTag(UiTags.COMPOSER_SEND).assertIsDisplayed()
        compose.onNodeWithTag(UiTags.COMPOSER_STOP).assertDoesNotExist()
    }

    @Test
    fun `rule 7 labels follow idle, steer, queue and stopping`() {
        val turnRunning = mutableStateOf(false)
        val steer = mutableStateOf(true)
        val stopping = mutableStateOf(false)
        compose.setContent {
            PdshTheme(darkTheme = false) {
                PdshComposerSendKeys(
                    canSubmit = true,
                    turnRunning = turnRunning.value,
                    steer = steer.value,
                    onSend = {},
                    onStop = {},
                    stopping = stopping.value,
                )
            }
        }
        compose.onNodeWithContentDescription(UiStrings.COMPOSER_SEND_LABEL).assertExists()

        turnRunning.value = true
        compose.waitForIdle()
        compose.onNodeWithContentDescription(UiStrings.COMPOSER_SEND_LABEL_STEER).assertExists()
        compose.onNodeWithContentDescription(UiStrings.COMPOSER_STOP_LABEL).assertExists()

        steer.value = false
        compose.waitForIdle()
        compose.onNodeWithContentDescription(UiStrings.COMPOSER_SEND_LABEL_QUEUE).assertExists()

        stopping.value = true
        compose.waitForIdle()
        compose.onNodeWithContentDescription(UiStrings.COMPOSER_STOPPING).assertExists()
    }

    @Test
    fun `the stop key keeps its 36 dp circle while the send key enters`() {
        compose.mainClock.autoAdvance = false
        val canSubmit = mutableStateOf(false)
        compose.setContent {
            PdshTheme(darkTheme = false) {
                PdshComposerSendKeys(
                    canSubmit = canSubmit.value,
                    turnRunning = true,
                    steer = false,
                    onSend = {},
                    onStop = {},
                )
            }
        }
        compose.mainClock.advanceTimeByFrame()
        val before = compose.onNodeWithTag(UiTags.COMPOSER_STOP).getUnclippedBoundsInRoot()
        assertEquals(36f, (before.right - before.left).value, 0.5f)

        canSubmit.value = true
        compose.mainClock.advanceTimeByFrame()
        compose.mainClock.advanceTimeBy(60)
        val duringSendEnter = compose.onNodeWithTag(UiTags.COMPOSER_STOP).getUnclippedBoundsInRoot()
        assertEquals(
            "the stop key has no scale transition of its own",
            36f,
            (duringSendEnter.right - duringSendEnter.left).value,
            0.5f,
        )
        assertEquals(36f, (duringSendEnter.bottom - duringSendEnter.top).value, 0.5f)
    }

    @Test
    fun `typing more text with canSubmit unchanged does not restart the transition`() {
        compose.mainClock.autoAdvance = false
        val transition = ComposerSendTransition()
        val draft = mutableStateOf("hello")
        compose.setContent {
            PdshTheme(darkTheme = false) {
                Column {
                    BasicTextField(
                        value = draft.value,
                        onValueChange = { draft.value = it },
                        modifier = Modifier.testTag(DRAFT_TAG),
                    )
                    ComposerSendButton(
                        canSubmit = draft.value.isNotEmpty(),
                        turnRunning = false,
                        steer = false,
                        onClick = {},
                        transition = transition,
                    )
                }
            }
        }
        compose.mainClock.advanceTimeByFrame()
        assertEquals("the initial submittable state starts one transition", 1, transition.animationStarts)
        compose.mainClock.advanceTimeBy(48)
        val mid = transition.progress.value
        assertTrue("the entry transition is mid-flight at 48 ms (got $mid)", mid > 0f && mid < 1f)

        compose.onNodeWithTag(DRAFT_TAG).performTextInput(" world")
        compose.mainClock.advanceTimeByFrame()
        assertEquals(
            "typing with canSubmit still true must not start another transition",
            1,
            transition.animationStarts,
        )

        compose.mainClock.advanceTimeBy(UiTokenData.composerSend.motion.durationMs.toLong())
        compose.mainClock.advanceTimeByFrame()
        assertEquals("the original transition still finishes", 1f, transition.progress.value, 0.0001f)
    }

    @Test
    fun `a canSubmit change runs the token transition from scale 0_8 and opacity 0`() {
        compose.mainClock.autoAdvance = false
        val transition = ComposerSendTransition()
        val canSubmit = mutableStateOf(false)
        compose.setContent {
            PdshTheme(darkTheme = false) {
                ComposerSendButton(
                    canSubmit = canSubmit.value,
                    turnRunning = false,
                    steer = false,
                    onClick = {},
                    transition = transition,
                )
            }
        }
        compose.mainClock.advanceTimeByFrame()
        assertEquals(0f, transition.progress.value, 0f)

        canSubmit.value = true
        compose.mainClock.advanceTimeByFrame()
        compose.mainClock.advanceTimeBy(60)
        val mid = transition.progress.value
        assertTrue("the transition is mid-flight at 60 ms (got $mid)", mid > 0f && mid < 1f)
        assertTrue(ComposerSendRule.transitionScale(mid) > UiTokenData.composerSend.transitionScale)
        assertTrue(ComposerSendRule.transitionScale(mid) < 1f)
        assertTrue(ComposerSendRule.transitionAlpha(mid) > UiTokenData.composerSend.transitionOpacity)
        assertTrue(ComposerSendRule.transitionAlpha(mid) < 1f)

        compose.mainClock.advanceTimeBy(60)
        compose.mainClock.advanceTimeByFrame()
        assertEquals("the transition settles at the enabled appearance", 1f, transition.progress.value, 0.0001f)
    }

    private companion object {
        const val DRAFT_TAG: String = "pdsh.composer.test.draft"
    }
}
