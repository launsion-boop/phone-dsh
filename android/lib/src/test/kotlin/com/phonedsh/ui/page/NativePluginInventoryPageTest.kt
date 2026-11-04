// SPDX-License-Identifier: MIT
package com.phonedsh.ui.page

import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertIsEnabled
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.phonedsh.ui.UiStrings
import com.phonedsh.ui.theme.PdshTheme
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.annotation.Config

@RunWith(AndroidJUnit4::class)
@Config(sdk = [34], qualifiers = "w411dp-h640dp")
class NativePluginInventoryPageTest {
    @get:Rule
    val compose = createComposeRule()

    @Test
    fun `reported loading state remains loading while a read is in flight`() {
        var refreshes = 0
        compose.setContent {
            PdshTheme {
                NativePluginInventoryPage(
                    state = PluginInventoryScreenState.from(
                        PluginInventoryFacts(isLoading = true),
                    ),
                    onRefresh = { refreshes += 1 },
                )
            }
        }

        compose.onNodeWithTag(UiPageTags.PLUGIN_INVENTORY_LOADING).assertIsDisplayed()
        compose.waitForIdle()
        assertEquals(1, refreshes)
    }

    @Test
    fun `inventory error retries through the supplied host refresh`() {
        var refreshes = 0
        compose.setContent {
            PdshTheme {
                NativePluginInventoryPage(
                    state = PluginInventoryScreenState.from(
                        PluginInventoryFacts(failure = "inventory read failed"),
                    ),
                    onRefresh = { refreshes += 1 },
                )
            }
        }
        compose.waitForIdle()

        compose.onNodeWithTag(UiPageTags.PLUGIN_INVENTORY_FAILURE).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.PLUGIN_INVENTORY_UNREAD).assertIsDisplayed()
        compose.onNodeWithTag(UiPageTags.PLUGIN_INVENTORY_RETRY)
            .assertIsDisplayed()
            .assertIsEnabled()
            .performClick()
        assertEquals(2, refreshes) // one page-entry read, one explicit retry
    }
}
