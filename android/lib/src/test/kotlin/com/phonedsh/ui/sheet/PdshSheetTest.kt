// Compose behaviour for the shared modal bottom sheet, interaction.md §2.
// SPDX-License-Identifier: MIT
package com.phonedsh.ui.sheet

import androidx.activity.ComponentActivity
import androidx.activity.OnBackPressedDispatcherOwner
import androidx.compose.foundation.text.BasicText
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onNodeWithTag
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

/**
 * JVM-observable rules: content mount, rule 4's grabber, rule 1's back path and
 * rule 9's inner-stack / top-sheet order. Scrim tap and drag-down are platform
 * Material behaviour whose touches Robolectric does not route into the sheet's
 * separate window; those stay device-verified (see the handoff).
 */
@RunWith(AndroidJUnit4::class)
@Config(sdk = [34], qualifiers = "w411dp-h891dp")
class PdshSheetTest {
    @get:Rule
    val compose = createAndroidComposeRule<ComponentActivity>()

    private val contentTag = "sheet_test_content"

    @Test
    fun `connector chrome draws the grabber and catalog chrome hides it`() {
        var chrome by mutableStateOf(SheetChrome.Connectors)
        compose.setContent {
            PdshTheme(darkTheme = false) {
                PdshSheet(
                    pageId = "connectors",
                    onDismissRequest = {},
                    chrome = chrome,
                ) {
                    BasicText("sheet content", Modifier.testTag(contentTag))
                }
            }
        }
        compose.waitForIdle()
        compose.onNodeWithTag(contentTag).assertExists()
        compose.onNodeWithTag(PdshSheetTags.DRAG_HANDLE, useUnmergedTree = true).assertExists()

        compose.runOnIdle { chrome = SheetChrome.SubagentCatalog }
        compose.waitForIdle()
        compose.onNodeWithTag(PdshSheetTags.DRAG_HANDLE, useUnmergedTree = true).assertDoesNotExist()
        compose.onNodeWithTag(contentTag).assertExists()
    }

    @Test
    fun `the default chrome follows the hidden system grabber`() {
        compose.setContent {
            PdshTheme(darkTheme = false) {
                PdshSheet(pageId = "previewShare", onDismissRequest = {}) {
                    BasicText("sheet content", Modifier.testTag(contentTag))
                }
            }
        }
        compose.waitForIdle()
        compose.onNodeWithTag(contentTag).assertExists()
        compose.onNodeWithTag(PdshSheetTags.DRAG_HANDLE, useUnmergedTree = true).assertDoesNotExist()
    }

    @Test
    fun `system back dismisses a sheet with no inner stack`() {
        var dismissed = false
        show(onDismiss = { dismissed = true })
        pressBackAndSettle()
        assertTrue("rule 1: system back closes the sheet", dismissed)
    }

    @Test
    fun `system back reports the dismissal only after the platform hide`() {
        compose.mainClock.autoAdvance = false
        var dismissed = false
        show(onDismiss = { dismissed = true })
        compose.mainClock.advanceTimeBy(600)
        compose.mainClock.advanceTimeByFrame()

        pressSystemBack()
        compose.mainClock.advanceTimeBy(30)
        assertFalse("rule 7: the sheet must still be leaving the screen", dismissed)

        compose.mainClock.advanceTimeBy(1_000)
        compose.mainClock.advanceTimeByFrame()
        assertTrue("the host is told after the platform hide", dismissed)
    }

    @Test
    fun `system back pops the inner stack before it closes the sheet`() {
        var pops = 0
        var dismissed = false
        val inner = SheetInnerNavigation {
            pops += 1
            pops == 1
        }
        show(inner = inner, onDismiss = { dismissed = true })

        pressBackAndSettle()
        assertEquals("rule 9: the first back leaves the inner stack", 1, pops)
        assertFalse("the sheet remains open at the inner root", dismissed)

        pressBackAndSettle()
        assertEquals("the second back reaches the inner root", 2, pops)
        assertTrue("the root step closes the sheet", dismissed)
    }

    @Test
    fun `the supplied back host consumes the sheet layer`() {
        var dismissed = false
        val host = SheetBackHost()
        show(backHost = host, onDismiss = { dismissed = true })
        assertTrue(host.hasSheet)
        assertTrue(host.dispatch())
        compose.waitForIdle()
        assertTrue("W2-NAV can dispatch the sheet layer", dismissed)
    }

    @Test
    fun `an unknown page id still mounts on the contract default`() {
        var dismissed = false
        show(pageId = "not-a-contract-page", onDismiss = { dismissed = true })
        compose.onNodeWithTag(contentTag).assertExists()
        pressBackAndSettle()
        assertTrue("the default sheet keeps the back dismiss path", dismissed)
    }

    private fun show(
        pageId: String = "connectors",
        chrome: SheetChrome = SheetChrome.Connectors,
        inner: SheetInnerNavigation? = null,
        backHost: SheetBackHost? = null,
        onDismiss: () -> Unit = {},
    ) {
        compose.setContent {
            PdshTheme(darkTheme = false) {
                PdshSheet(
                    pageId = pageId,
                    onDismissRequest = onDismiss,
                    chrome = chrome,
                    innerNavigation = inner,
                    backHost = backHost,
                ) {
                    BasicText("sheet content", Modifier.testTag(contentTag))
                }
            }
        }
        compose.waitForIdle()
    }

    /**
     * Robolectric models the sheet as its own dialog; dispatch on that dialog's
     * owner exactly as the platform window would, then let the hide animation
     * finish on the test clock.
     */
    private fun pressBackAndSettle() {
        pressSystemBack()
        compose.mainClock.advanceTimeBy(1_000)
        compose.waitForIdle()
    }

    private fun pressSystemBack() {
        val dialog = ShadowDialog.getLatestDialog()
        (dialog as OnBackPressedDispatcherOwner).onBackPressedDispatcher.onBackPressed()
    }
}
