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
import androidx.compose.ui.test.assertIsNotEnabled
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.phonedsh.ui.UiStrings
import com.phonedsh.ui.UiTags
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

    private fun show(
        text: String,
        canSubmit: Boolean,
        enabled: Boolean = true,
        running: Boolean = false,
        mode: ComposerMode = ComposerMode.SEND,
        stat: String? = null,
        contextPercent: Int? = null,
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
                    controls = controls,
                )
            }
        }
    }
}

/** The tag the controls-slot assertion addresses. */
private const val CONTROLS_TAG: String = "pdsh.composer.controls-test"
