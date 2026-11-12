// Sub-page Settings rows stay on the 48 pt token pitch after the root's 62 pt row.
// SPDX-License-Identifier: MIT
package com.phonedsh.ui.surface

import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.test.getUnclippedBoundsInRoot
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.phonedsh.ui.SettingsMetrics
import com.phonedsh.ui.theme.PdshTheme
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.annotation.Config

/** The root-only 62 pt row must not leak into the token-backed sub-page rows. */
@RunWith(AndroidJUnit4::class)
@Config(sdk = [34], qualifiers = "w402dp-h874dp")
class SettingsChromeGeometryTest {
    @get:Rule
    val compose = createComposeRule()

    @Test
    fun `sub-page grouped row keeps the 48 pt token height`() {
        compose.setContent {
            PdshTheme {
                SettingsGroupCard {
                    SettingsGroupedRow(
                        title = "关于",
                        modifier = Modifier.testTag("subpage.grouped.row"),
                        dividerBelow = false,
                    )
                }
            }
        }
        val row = compose.onNodeWithTag("subpage.grouped.row").getUnclippedBoundsInRoot()
        assertEquals(SettingsMetrics.ROW_HEIGHT_PT, (row.bottom - row.top).value, 0.01f)
        assertEquals(48.0f, (row.bottom - row.top).value, 0.01f)
    }

    @Test
    fun `sub-page form row keeps the 48 pt token height`() {
        compose.setContent {
            PdshTheme {
                SettingsFormRow(
                    title = "地址",
                    modifier = Modifier.testTag("subpage.form.row"),
                    dividerBelow = false,
                )
            }
        }
        val row = compose.onNodeWithTag("subpage.form.row").getUnclippedBoundsInRoot()
        assertEquals(SettingsMetrics.ROW_HEIGHT_PT, (row.bottom - row.top).value, 0.01f)
        assertEquals(48.0f, (row.bottom - row.top).value, 0.01f)
    }
}
