// AndroidADBSettingsPage: drafts reach the host, busy/disabled guards, status line.
// SPDX-License-Identifier: MIT
package com.phonedsh.ui.page

import androidx.compose.ui.test.assertIsEnabled
import androidx.compose.ui.test.assertIsNotEnabled
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollToNode
import androidx.compose.ui.test.performTextReplacement
import androidx.compose.ui.test.hasTestTag
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.phonedsh.ui.nav.PdshRoute
import com.phonedsh.ui.nav.PdshSettingsRows
import com.phonedsh.ui.theme.PdshTheme
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.annotation.Config

@RunWith(AndroidJUnit4::class)
@Config(sdk = [34], qualifiers = "w411dp-h891dp")
class AndroidADBSettingsPageTest {
    @get:Rule val compose = createComposeRule()

    private val saved = mutableListOf<AndroidAdbDraft>()
    private val checked = mutableListOf<AndroidAdbDraft>()
    private var cancelled = 0

    private fun show(facts: AndroidAdbFacts) {
        compose.setContent {
            PdshTheme {
                AndroidADBSettingsPage(
                    facts = facts,
                    onBack = {},
                    onSave = { saved += it },
                    onCheck = { checked += it },
                    onCancel = { cancelled += 1 },
                )
            }
        }
    }

    @Test
    fun draftsAreSentToTheHost() {
        show(AndroidAdbFacts(available = true, enabled = false, host = "", port = 5555))
        compose.onNodeWithTag(UiPageTags.ANDROID_ADB_CHECK).assertIsNotEnabled()
        compose.onNodeWithTag(UiPageTags.ANDROID_ADB_TOGGLE).performClick()
        compose.onNodeWithTag(UiPageTags.ANDROID_ADB_HOST).performTextReplacement("192.0.2.7")
        compose.onNodeWithTag(UiPageTags.ANDROID_ADB_PORT).performTextReplacement("5556")
        compose.onNodeWithTag(UiPageTags.ANDROID_ADB_SAVE).performClick()
        compose.onNodeWithTag(UiPageTags.ANDROID_ADB_CHECK).assertIsEnabled().performClick()
        compose.onNodeWithTag(UiPageTags.ANDROID_ADB_CANCEL).performClick()
        assertEquals(listOf(AndroidAdbDraft(true, "192.0.2.7", "5556")), saved)
        assertEquals(listOf(AndroidAdbDraft(true, "192.0.2.7", "5556")), checked)
        assertEquals(1, cancelled)
    }

    @Test
    fun busyDisablesSaveAndCheckAndTheStatusSectionAppears() {
        show(AndroidAdbFacts(available = true, enabled = true, host = "192.0.2.7", busy = true, status = "请查看 Android 上的调试授权提示。"))
        compose.onNodeWithTag(UiPageTags.ANDROID_ADB_SAVE).assertIsNotEnabled()
        compose.onNodeWithTag(UiPageTags.ANDROID_ADB_CHECK).assertIsNotEnabled()
        compose.onNodeWithTag(UiPageTags.ANDROID_ADB_CANCEL).assertIsEnabled()
        compose.onNodeWithTag(UiPageTags.ANDROID_ADB_LIST).performScrollToNode(hasTestTag(UiPageTags.ANDROID_ADB_STATUS))
        compose.onNodeWithText("连接状态").assertExists()
        compose.onNodeWithText("请查看 Android 上的调试授权提示。").assertExists()
    }

    @Test
    fun aHostWithoutAdbLeavesEveryControlDisabled() {
        show(AndroidAdbFacts(available = false))
        compose.onNodeWithTag(UiPageTags.ANDROID_ADB_SAVE).assertIsNotEnabled()
        compose.onNodeWithTag(UiPageTags.ANDROID_ADB_CHECK).assertIsNotEnabled()
        compose.onNodeWithTag(UiPageTags.ANDROID_ADB_CANCEL).assertIsNotEnabled()
        compose.onNodeWithTag(UiPageTags.ANDROID_ADB_STATUS).assertDoesNotExist()
    }

    @Test
    fun theSettingsRowRoutesToThePage() {
        assertEquals(PdshRoute.AndroidAdb, PdshSettingsRows.targetOf(SettingsDestination.ANDROID_ADB))
    }
}
