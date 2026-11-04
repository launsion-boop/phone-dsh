// Signature surface 5/6: the composer (JVM + Robolectric).
// SPDX-License-Identifier: MIT
//
// The four states the iOS `composer` has: idle with text, idle without text, a
// pending ask (visible but disabled) and a running turn — where the trailing
// corner either swaps the send key for the stop key or shows both, exactly as
// ChatPage.swift's `actionButton` + `overlay(alignment: .bottomTrailing)`.
package com.phonedsh.ui.surface

import androidx.compose.foundation.text.BasicText
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertIsEnabled
import androidx.compose.ui.test.assertIsFocused
import androidx.compose.ui.test.assertIsNotFocused
import androidx.compose.ui.test.click
import androidx.compose.ui.test.assertIsNotEnabled
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performImeAction
import androidx.compose.ui.test.performKeyInput
import androidx.compose.ui.test.performTouchInput
import androidx.compose.ui.test.ExperimentalTestApi
import androidx.compose.ui.test.getUnclippedBoundsInRoot
import androidx.compose.ui.input.key.Key
import androidx.compose.ui.geometry.Offset
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.phonedsh.ui.UiStrings
import com.phonedsh.ui.UiTags
import com.phonedsh.ui.state.ComposerStatsMode
import com.phonedsh.ui.state.SessionStats
import com.phonedsh.ui.state.SessionTokenUsage
import com.phonedsh.ui.state.ContextPressure
import com.phonedsh.ui.state.ContextBreakdown
import com.phonedsh.ui.theme.PdshTheme
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.annotation.Config

@RunWith(AndroidJUnit4::class)
@Config(sdk = [34])
class ComposerSurfaceTest {
    @get:Rule
    val compose = createComposeRule()

    @Test
    fun `a submittable draft sends from the accent key`() {
        var sent = 0
        show(text = "hello", canSubmit = true, onSend = { sent += 1 })
        compose.onNodeWithTag(UiTags.COMPOSER).assertIsDisplayed()
        compose.onNodeWithTag(UiTags.COMPOSER_SEND).assertIsEnabled()
        compose.onNodeWithTag(UiTags.COMPOSER_SEND).performClick()
        assertEquals(1, sent)
    }

    @Test
    fun `the soft keyboard send action submits a submittable draft`() {
        var sent = 0
        show(text = "hello", canSubmit = true, onSend = { sent += 1 })
        compose.onNodeWithTag(UiTags.COMPOSER_FIELD).performImeAction()
        assertEquals(1, sent)
    }

    @Test
    fun `an empty draft keeps the send key disabled and shows the placeholder`() {
        show(text = "", canSubmit = false)
        compose.onNodeWithTag(UiTags.COMPOSER_SEND).assertIsNotEnabled()
        compose.onNodeWithText(UiStrings.COMPOSER_PLACEHOLDER_IDLE).assertIsDisplayed()
    }

    @Test
    fun `a pending ask disables the dock without hiding it`() {
        show(text = "", canSubmit = false, enabled = false)
        compose.onNodeWithTag(UiTags.COMPOSER).assertIsDisplayed()
        compose.onNodeWithTag(UiTags.COMPOSER_FIELD).assertIsNotEnabled()
        compose.onNodeWithTag(UiTags.COMPOSER_SEND).assertIsNotEnabled()
    }

    @Test
    fun `a running turn with no submittable draft shows only the stop key`() {
        var stopped = 0
        show(
            text = "draft",
            running = true,
            canSubmit = false,
            mode = ComposerMode.STOP,
            onStop = { stopped += 1 },
        )
        compose.onNodeWithTag(UiTags.COMPOSER_SEND).assertDoesNotExist()
        compose.onNodeWithTag(UiTags.COMPOSER_STOP).assertIsDisplayed()
        compose.onNodeWithTag(UiTags.COMPOSER_STOP).performClick()
        assertEquals(1, stopped)
    }

    @Test
    fun `a running turn with a submittable draft keeps send and adds the small stop key`() {
        // iOS: `if model.turnRunning, canSubmit { stopButton(diameter: 24) }` + send.
        show(text = "补充", running = true, canSubmit = true, mode = ComposerMode.SEND)
        compose.onNodeWithTag(UiTags.COMPOSER_SEND).assertIsDisplayed()
        compose.onNodeWithTag(UiTags.COMPOSER_STOP).assertIsDisplayed()
    }

    @Test
    fun `the stat pills are the usage text and the context ring`() {
        show(
            text = "draft",
            canSubmit = true,
            stat = "1.2k tokens",
            contextPercent = 62,
        )
        compose.onNodeWithTag(UiTags.COMPOSER_STAT).assertIsDisplayed()
        compose.onNodeWithText("1.2k tokens").assertIsDisplayed()
        compose.onNodeWithText("62%").assertIsDisplayed()
    }

    @Test
    fun `compact mode uses only available speed and cache hit`() {
        show(
            text = "", canSubmit = false,
            sessionStats = SessionStats(1, 2, 0.0, 0.0, 0.0, 0, 1000.0, 25),
            tokenUsage = SessionTokenUsage(100, 20, 80, 0),
            contextPressure = ContextPressure(500, 700, 1000),
            statsMode = ComposerStatsMode.COMPACT,
        )
        compose.onNodeWithTag("pdsh.composer.metrics.compact").assertIsDisplayed()
        compose.onNodeWithText("25 tok/s", substring = true).assertIsDisplayed()
        compose.onNodeWithText("缓存命中 44%", substring = true).assertIsDisplayed()
        compose.onNodeWithTag("pdsh.composer.metrics.activity").assertDoesNotExist()
        compose.onNodeWithTag("pdsh.composer.metrics.context").assertDoesNotExist()
    }

    @Test
    fun `detailed mode chips open source-data detail sheets`() {
        show(
            text = "", canSubmit = false,
            sessionStats = SessionStats(2, 4, 1200.0, 0.0, 600.0, 2, 2000.0, 50),
            tokenUsage = SessionTokenUsage(100, 20, 80, 10),
            contextPressure = ContextPressure(800, 900, 1000),
            contextBreakdown = ContextBreakdown(30, 40, 800),
        )
        compose.onNodeWithText("210 tok", substring = true).assertIsDisplayed()
        compose.onNodeWithTag("pdsh.composer.metrics.usage").performClick()
        compose.onNodeWithText("Token 用量").assertIsDisplayed()
        compose.onNodeWithText("缓存读取").assertIsDisplayed()
        compose.onNodeWithText("80 tok").assertIsDisplayed()
        compose.onNodeWithTag("pdsh.composer.metrics.done").assertIsDisplayed()
    }

    @Test
    fun `activity chip opens its session detail`() {
        show(
            text = "", canSubmit = false,
            sessionStats = SessionStats(2, 4, 1200.0, 300.0, 600.0, 2, 2000.0, 50),
        )
        compose.onNodeWithTag("pdsh.composer.metrics.activity").performClick()
        compose.onNodeWithText("会话统计").assertIsDisplayed()
        compose.onNodeWithText("轮 / 步").assertIsDisplayed()
        compose.onNodeWithText("模型用时").assertIsDisplayed()
    }

    @Test
    fun `context chip opens the supplied context breakdown`() {
        show(
            text = "", canSubmit = false,
            contextPressure = ContextPressure(800, 900, 1000),
            contextBreakdown = ContextBreakdown(30, 40, 800),
        )
        compose.onNodeWithTag("pdsh.composer.metrics.context").performClick()
        compose.onNodeWithText("上下文").assertIsDisplayed()
        compose.onNodeWithText("系统提示").assertIsDisplayed()
        compose.onNodeWithText("~30").assertIsDisplayed()
    }

    @Test
    fun `the controls slot is docked inside the card`() {
        // ChatPage.swift `composerControls`: the tool row lives inside the card.
        show(
            text = "",
            canSubmit = false,
            controls = {
                BasicText(
                    text = "controls",
                    modifier = Modifier.testTag(CONTROLS_TAG),
                )
            },
        )
        compose.onNodeWithTag(CONTROLS_TAG).assertIsDisplayed()
    }

    @Test
    @OptIn(ExperimentalTestApi::class)
    fun `hardware enter sends only after the editor has no composing region`() {
        var sent = 0
        show(text = "hello", canSubmit = true, onSend = { sent += 1 })
        compose.onNodeWithTag(UiTags.COMPOSER_FIELD).performClick()
        compose.onNodeWithTag(UiTags.COMPOSER_FIELD).performKeyInput {
            keyDown(Key.Enter)
            keyUp(Key.Enter)
        }
        assertEquals(1, sent)
    }

    @Test
    @OptIn(ExperimentalTestApi::class)
    fun `open card and primary action meet PR22 minimum geometry`() {
        show(text = "", canSubmit = false)
        val cardBounds = compose.onNodeWithTag(UiTags.COMPOSER).getUnclippedBoundsInRoot()
        val sendBounds = compose.onNodeWithTag(UiTags.COMPOSER_SEND).getUnclippedBoundsInRoot()
        val cardHeight = (cardBounds.bottom - cardBounds.top).value
        val sendHitWidth = (sendBounds.right - sendBounds.left).value
        val sendCircleBounds = compose.onNodeWithTag("pdsh.composer.send-circle", useUnmergedTree = true).getUnclippedBoundsInRoot()
        val sendDiameter = (sendCircleBounds.right - sendCircleBounds.left).value
        assertEquals(true, cardHeight >= 104f)
        assertEquals(44f, sendHitWidth, 0.1f)
        assertEquals(36f, sendDiameter, 0.1f)
    }

    @Test
    @OptIn(ExperimentalTestApi::class)
    fun `blank card tap focuses input and send child still invokes its action`() {
        var sent = 0
        show(text = "hello", canSubmit = true, onSend = { sent += 1 })
        compose.onNodeWithTag(UiTags.COMPOSER_FIELD).assertIsNotFocused()
        compose.onNodeWithTag("pdsh.composer.card").performTouchInput {
            // Two physical pixels inside the top-left card corner: outside the
            // port's sourced 8pt top / 11pt leading insets and clear of controls.
            click(Offset(2f, 2f))
        }
        compose.onNodeWithTag(UiTags.COMPOSER_FIELD).assertIsFocused()
        compose.onNodeWithTag(UiTags.COMPOSER_SEND).performClick()
        assertEquals(1, sent)
    }

    private fun show(
        text: String,
        canSubmit: Boolean,
        enabled: Boolean = true,
        running: Boolean = false,
        mode: ComposerMode = ComposerMode.SEND,
        stat: String? = null,
        contextPercent: Int? = null,
        sessionStats: SessionStats? = null,
        tokenUsage: SessionTokenUsage? = null,
        contextPressure: ContextPressure? = null,
        contextBreakdown: ContextBreakdown? = null,
        statsMode: ComposerStatsMode = ComposerStatsMode.DETAILED,
        onSend: () -> Unit = {},
        onStop: () -> Unit = {},
        controls: (@androidx.compose.runtime.Composable () -> Unit)? = null,
    ) {
        compose.setContent {
            PdshTheme {
                Composer(
                    text = text,
                    onTextChange = {},
                    placeholder = UiStrings.COMPOSER_PLACEHOLDER_IDLE,
                    mode = mode,
                    enabled = enabled,
                    canSubmit = canSubmit,
                    running = running,
                    onSend = onSend,
                    onStop = onStop,
                    stat = stat,
                    contextPercent = contextPercent,
                    sessionStats = sessionStats,
                    tokenUsage = tokenUsage,
                    contextPressure = contextPressure,
                    contextBreakdown = contextBreakdown,
                    statsMode = statsMode,
                    controls = controls,
                )
            }
        }
    }
}

/** The tag the controls-slot assertion addresses. */
private const val CONTROLS_TAG: String = "pdsh.composer.controls-test"
