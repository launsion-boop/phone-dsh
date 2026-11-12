// The host-wide sheet back seam, interaction.md §2 rule 9 / §4 rule 5.
// SPDX-License-Identifier: MIT
//
// `PdshSheet` resolves its back layer as
// `backHost ?: LocalSheetBackHost.current ?: remember { SheetBackHost() }`.
// These cases drive the real composable through each arm: the host's shared
// instance when a provider exists, an explicit instance when the caller passes
// one, and a private chain when the sheet is previewed outside any host.
package com.phonedsh.ui.sheet

import androidx.activity.ComponentActivity
import androidx.activity.OnBackPressedDispatcherOwner
import androidx.compose.foundation.text.BasicText
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.State
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.phonedsh.ui.theme.PdshTheme
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.annotation.Config
import org.robolectric.shadows.ShadowDialog

@RunWith(AndroidJUnit4::class)
@Config(sdk = [34], qualifiers = "w411dp-h891dp")
class LocalSheetBackHostTest {
    @get:Rule
    val compose = createAndroidComposeRule<ComponentActivity>()

    private val contentTag = "local_sheet_back_host_content"

    @Test
    fun `outside a host the local has no instance`() {
        var seen: SheetBackHost? = SheetBackHost()
        compose.setContent {
            PdshTheme(darkTheme = false) {
                seen = LocalSheetBackHost.current
            }
        }
        compose.waitForIdle()
        assertNull("a sheet previewed without a host keeps its private chain", seen)
    }

    @Test
    fun `a provided host sees the sheet and closes exactly one layer`() {
        val host = SheetBackHost()
        val visible = mutableStateOf(true)
        var dismissals = 0
        show(
            backHost = null,
            providerHost = host,
            visible = visible,
            onDismiss = {
                dismissals += 1
                visible.value = false
            },
        )

        assertTrue("the page-owned sheet registered on the host chain", host.hasSheet)
        assertTrue("the sheet layer consumes the gesture", host.dispatch())
        settle()
        assertEquals(1, dismissals)
        assertFalse("the disposed sheet left the chain", host.hasSheet)
    }

    @Test
    fun `an explicit back host wins over the provided one`() {
        val provided = SheetBackHost()
        val explicit = SheetBackHost()
        val visible = mutableStateOf(true)
        var dismissals = 0
        show(
            backHost = explicit,
            providerHost = provided,
            visible = visible,
            onDismiss = {
                dismissals += 1
                visible.value = false
            },
        )

        assertTrue("the caller's instance is the registered one", explicit.hasSheet)
        assertFalse("the provider is not used when backHost is passed", provided.hasSheet)
        assertFalse(provided.dispatch())

        assertTrue(explicit.dispatch())
        settle()
        assertEquals(1, dismissals)
    }

    @Test
    fun `without a provider system back still closes the private sheet`() {
        val visible = mutableStateOf(true)
        var dismissals = 0
        show(
            backHost = null,
            providerHost = null,
            visible = visible,
            onDismiss = {
                dismissals += 1
                visible.value = false
            },
        )

        val dialog = ShadowDialog.getLatestDialog()
        (dialog as OnBackPressedDispatcherOwner).onBackPressedDispatcher.onBackPressed()
        settle()
        assertEquals("rule 1: the sheet keeps its own back path", 1, dismissals)
    }

    @Test
    fun `two page-owned sheets on one host close top first`() {
        val host = SheetBackHost()
        val bottomVisible = mutableStateOf(true)
        val topVisible = mutableStateOf(true)
        val order = mutableListOf<String>()
        compose.setContent {
            PdshTheme(darkTheme = false) {
                CompositionLocalProvider(LocalSheetBackHost provides host) {
                    if (bottomVisible.value) {
                        PdshSheet(
                            pageId = "chatSessions",
                            chrome = SheetChrome.HomeSheet,
                            onDismissRequest = {
                                order += "bottom"
                                bottomVisible.value = false
                            },
                        ) {
                            BasicText("bottom", Modifier.testTag(contentTag))
                        }
                    }
                    if (topVisible.value) {
                        PdshSheet(
                            pageId = "chatJobs",
                            chrome = SheetChrome.HomeSheet,
                            onDismissRequest = {
                                order += "top"
                                topVisible.value = false
                            },
                        ) {
                            BasicText("top", Modifier.testTag(contentTag))
                        }
                    }
                }
            }
        }
        compose.waitForIdle()
        assertTrue("both sheets share the one host chain", host.hasSheet)

        assertTrue(host.dispatch())
        settle()
        assertEquals("§2 rule 9: one back closes the top sheet only", listOf("top"), order)

        assertTrue(host.dispatch())
        settle()
        assertEquals(listOf("top", "bottom"), order)
        assertFalse(host.hasSheet)
    }

    /** Mounts one sheet, optionally inside a provider, and removes it on dismiss. */
    private fun show(
        backHost: SheetBackHost?,
        providerHost: SheetBackHost?,
        visible: State<Boolean>,
        onDismiss: () -> Unit,
    ) {
        compose.setContent {
            PdshTheme(darkTheme = false) {
                val sheet: @Composable () -> Unit = {
                    if (visible.value) {
                        PdshSheet(
                            pageId = "chatJobs",
                            chrome = SheetChrome.HomeSheet,
                            onDismissRequest = onDismiss,
                            backHost = backHost,
                        ) {
                            BasicText("sheet content", Modifier.testTag(contentTag))
                        }
                    }
                }
                if (providerHost == null) {
                    sheet()
                } else {
                    CompositionLocalProvider(LocalSheetBackHost provides providerHost) {
                        sheet()
                    }
                }
            }
        }
        compose.waitForIdle()
        assertTrue("the sheet content is mounted", visible.value)
        compose.onNodeWithTag(contentTag).assertExists()
    }

    /** The platform hide animation owns the dismissal report; finish it. */
    private fun settle() {
        compose.mainClock.advanceTimeBy(1_000)
        compose.waitForIdle()
    }
}
