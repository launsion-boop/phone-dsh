// SPDX-License-Identifier: MIT
package com.phonedsh.ui.surface.composer

import androidx.compose.foundation.text.BasicText
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.phonedsh.ui.theme.PdshTheme
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.annotation.Config

@RunWith(AndroidJUnit4::class)
@Config(sdk = [34])
class ComposerDockTest {
    @get:Rule val compose = createComposeRule()

    @Test
    fun `toolbar keeps add access and model controls in one permanent row`() {
        compose.setContent {
            PdshTheme {
                ComposerToolbar(
                    add = { BasicText("add", Modifier.testTag("add")) },
                    access = { BasicText("access", Modifier.testTag("access")) },
                    model = { BasicText("model", Modifier.testTag("model")) },
                )
            }
        }
        compose.onNodeWithTag(COMPOSER_TOOLBAR_TAG).assertIsDisplayed()
        compose.onNodeWithTag("add").assertIsDisplayed()
        compose.onNodeWithTag("access").assertIsDisplayed()
        compose.onNodeWithTag("model").assertIsDisplayed()
    }

    @Test
    fun `toolbar omits a synthetic progress spinner and voice input control`() {
        compose.setContent {
            PdshTheme {
                ComposerToolbar(
                    add = { BasicText("add", Modifier.testTag("add")) },
                    access = { BasicText("access", Modifier.testTag("access")) },
                    model = { BasicText("model", Modifier.testTag("model")) },
                )
            }
        }
        compose.onNodeWithTag("pdsh.composer.running").assertDoesNotExist()
        compose.onNodeWithTag("pdsh.composer.voice").assertDoesNotExist()
    }
}
