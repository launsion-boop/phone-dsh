// Settings page: the list shell and the Android-only platform appendix.
// SPDX-License-Identifier: MIT
//
// The host-row cases that used to live here were superseded when the settings page
// was re-mirrored from `SettingsPage.swift` (N4 lane): the baseline has a fixed
// index, not host-supplied groups, so those assertions now live in
// `SettingsPageTest.kt`. What stays here is this file's original subject, the
// Android-only part of the page: the shared list tag and the three platform facts
// that exist on every render.
package com.phonedsh.ui.page

import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.performScrollToNode
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.phonedsh.ui.UiStrings
import com.phonedsh.ui.UiTags
import com.phonedsh.ui.theme.PdshTheme
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.annotation.Config

@RunWith(AndroidJUnit4::class)
@Config(sdk = [34])
class FilesSettingsPageTest {
    @get:Rule
    val compose = createComposeRule()

    /**
     * The mirrored index renders into the shared settings list tag, and it has no
     * empty state: thirteen baseline rows plus three platform facts always exist.
     */
    @Test
    fun `the index renders into the shared list tag and has no empty state`() {
        compose.setContent {
            PdshTheme {
                SettingsPage(
                    state = SettingsScreenState.from(SettingsFacts()),
                    onNavigate = {},
                    onToggleBackgroundKeepAlive = {},
                    onSelectBusyEnterMode = {},
                    onBack = {},
                )
            }
        }
        compose.onNodeWithTag(UiTags.SETTINGS_LIST).assertIsDisplayed()
        compose.onNodeWithTag(UiTags.SETTINGS_EMPTY).assertDoesNotExist()
    }

    /**
     * With no platform snapshot the three fact rows still render as 未知: an
     * omitted row would claim the page has no such fact. The list is lazy, so each
     * row is scrolled into composition before it is asserted.
     */
    @Test
    fun `the three platform facts render as 未知 without a snapshot`() {
        compose.setContent {
            PdshTheme {
                SettingsPage(
                    state = SettingsScreenState.from(SettingsFacts()),
                    onNavigate = {},
                    onToggleBackgroundKeepAlive = {},
                    onSelectBusyEnterMode = {},
                    onBack = {},
                )
            }
        }
        listOf(
            UiStrings.SETTINGS_NOTIFICATIONS,
            UiStrings.SETTINGS_BATTERY,
            UiStrings.SETTINGS_BACK,
        ).forEach { title ->
            compose.onNodeWithTag(UiTags.SETTINGS_LIST).performScrollToNode(hasText(title))
            compose.onNode(hasText(title) and hasText(UiStrings.UNKNOWN)).assertExists()
        }
    }
}
