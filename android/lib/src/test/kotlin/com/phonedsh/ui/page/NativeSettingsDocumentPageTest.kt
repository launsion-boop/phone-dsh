// NativeSettingsDocumentPage: the five read outcomes, the share gating and the
// redaction note the baseline prints.
// SPDX-License-Identifier: MIT
//
// The distinction this test protects is `null` vs `""`: a host that did not
// report a document is 未知, a host that read and found nothing is EMPTY, and
// the page must not draw an empty editor for the first case (it would read as
// "DSH has no settings").
package com.phonedsh.ui.page

import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertIsEnabled
import androidx.compose.ui.test.assertIsNotEnabled
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.phonedsh.ui.UiStrings
import com.phonedsh.ui.theme.PdshTheme
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.annotation.Config

@RunWith(AndroidJUnit4::class)
@Config(sdk = [34], qualifiers = "w411dp-h900dp")
class NativeSettingsDocumentPageTest {
    @get:Rule
    val compose = createComposeRule()

    private fun mount(
        state: SettingsDocumentScreenState,
        onShare: (() -> Unit)? = null,
        onDone: () -> Unit = {},
    ) {
        compose.setContent {
            PdshTheme(darkTheme = false) {
                NativeSettingsDocumentPage(state = state, onShare = onShare, onDone = onDone)
            }
        }
        compose.waitForIdle()
    }

    @Test
    fun `an unreported document is 未知, not an empty editor`() {
        val state = SettingsDocumentScreenState.from(SettingsDocumentFacts())
        assertEquals(SettingsDocumentStatus.UNKNOWN, state.status)
        assertNull(state.document)
        assertFalse(state.canShare)
    }

    @Test
    fun `a reported empty document is EMPTY, a non-blank one is READY`() {
        val empty = SettingsDocumentScreenState.from(SettingsDocumentFacts(document = ""))
        assertEquals(SettingsDocumentStatus.EMPTY, empty.status)
        val ready = SettingsDocumentScreenState.from(SettingsDocumentFacts(document = "{}"))
        assertEquals(SettingsDocumentStatus.READY, ready.status)
        assertEquals("{}", ready.document)
    }

    @Test
    fun `loading wins over a previous document and a failure is FAILED`() {
        val loading = SettingsDocumentScreenState.from(
            SettingsDocumentFacts(document = "{}", loading = true),
        )
        assertEquals(SettingsDocumentStatus.LOADING, loading.status)
        val failed = SettingsDocumentScreenState.from(
            SettingsDocumentFacts(failure = "engine down"),
        )
        assertEquals(SettingsDocumentStatus.FAILED, failed.status)
        assertEquals("engine down", failed.failure)
    }

    @Test
    fun `the share is offered only with a host share and a document`() {
        val ready = SettingsDocumentFacts(document = "{}")
        assertFalse(SettingsDocumentScreenState.from(ready, shareAvailable = false).canShare)
        assertTrue(SettingsDocumentScreenState.from(ready, shareAvailable = true).canShare)
        assertFalse(
            SettingsDocumentScreenState.from(
                SettingsDocumentFacts(),
                shareAvailable = true,
            ).canShare,
        )
    }

    @Test
    fun `the unknown state shows the note, the state and the read-only line`() {
        mount(SettingsDocumentScreenState.from(SettingsDocumentFacts()))
        compose.onNodeWithText(UiStrings.SETTINGS_DOCUMENT_REDACTION_NOTE).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.SETTINGS_DOCUMENT_UNKNOWN).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.SETTINGS_DOCUMENT_UNKNOWN_HINT).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.SETTINGS_DOCUMENT_SHARE_UNAVAILABLE).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.SETTINGS_DONE).assertIsDisplayed()
        // No host share: the glyph exists, disabled.
        compose.onNodeWithTag(UiPageTags.SETTINGS_DOCUMENT_SHARE).assertIsNotEnabled()
    }

    @Test
    fun `a ready document is drawn verbatim and the share stays disabled without a host share`() {
        val document = "{\n  \"revision\": 7\n}"
        mount(SettingsDocumentScreenState.from(SettingsDocumentFacts(document = document), shareAvailable = true))
        compose.onNodeWithText(document).assertIsDisplayed()
        compose.onNodeWithTag(UiPageTags.SETTINGS_DOCUMENT_SHARE).assertIsNotEnabled()
    }

    @Test
    fun `a host share is enabled when there is a document and fires`() {
        var shared = false
        mount(
            SettingsDocumentScreenState.from(
                SettingsDocumentFacts(document = "{}"),
                shareAvailable = true,
            ),
            onShare = { shared = true },
        )
        compose.onNodeWithTag(UiPageTags.SETTINGS_DOCUMENT_SHARE).assertIsEnabled().performClick()
        compose.runOnIdle { assertTrue(shared) }
    }

    @Test
    fun `完成 dismisses the sheet`() {
        var done = false
        mount(SettingsDocumentScreenState.from(SettingsDocumentFacts()), onDone = { done = true })
        compose.onNodeWithTag(UiPageTags.SETTINGS_DOCUMENT_DONE).performClick()
        compose.runOnIdle { assertTrue(done) }
    }
}
