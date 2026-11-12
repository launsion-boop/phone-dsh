// The settings root's measured row, titled-section band and Done geometry.
// SPDX-License-Identifier: MIT
package com.phonedsh.ui.page

import androidx.compose.ui.test.assertHeightIsEqualTo
import androidx.compose.ui.test.assertWidthIsEqualTo
import androidx.compose.ui.test.getUnclippedBoundsInRoot
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.unit.dp
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.phonedsh.ui.SettingsMetrics
import com.phonedsh.ui.UiStrings
import com.phonedsh.ui.page.UiPageTags.SETTINGS_INDEX_GROUP_PREFIX
import com.phonedsh.ui.page.UiPageTags.SETTINGS_INDEX_ROW_PREFIX
import com.phonedsh.ui.theme.PdshTheme
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.annotation.Config

/**
 * The real settings root, measured against the iOS XCUITest export recorded in
 * `docs/parity/bench.md` § settings-root.
 */
@RunWith(AndroidJUnit4::class)
@Config(sdk = [34], qualifiers = "w402dp-h874dp")
class SettingsRootGeometryTest {
    @get:Rule
    val compose = createComposeRule()

    private var backCount = 0

    private fun show() {
        compose.setContent {
            PdshTheme {
                SettingsPage(
                    state = SettingsScreenState.from(
                        SettingsFacts(preferences = SettingsPreferences(language = SettingsLanguage.ZH)),
                    ),
                    onNavigate = {},
                    onToggleBackgroundKeepAlive = {},
                    onSelectBusyEnterMode = {},
                    onBack = { backCount += 1 },
                    mode = SettingsPageMode.SHEET,
                )
            }
        }
    }

    private fun row(id: String) = SETTINGS_INDEX_ROW_PREFIX + id

    @Test
    fun `root rows are 62 pt and the separator stays inside the row`() {
        show()
        val model = compose.onNodeWithTag(row("modelProvider")).getUnclippedBoundsInRoot()
        val tono = compose.onNodeWithTag(row("tonoAccount")).getUnclippedBoundsInRoot()
        val presets = compose.onNodeWithTag(row("agentPresets")).getUnclippedBoundsInRoot()

        assertEquals(62.0f, (model.bottom - model.top).value, 0.01f)
        assertEquals(62.0f, (tono.bottom - tono.top).value, 0.01f)
        assertEquals(62.0f, (presets.bottom - presets.top).value, 0.01f)
        // The row pitch is the row height: the 1 pt separator is painted inside
        // the tagged node, not appended below it.
        assertEquals(model.bottom.value, tono.top.value, 0.01f)
        assertEquals(tono.bottom.value, presets.top.value, 0.01f)
    }

    @Test
    fun `a titled group starts 57 pt below the previous row`() {
        show()
        val lastModelsRow = compose.onNodeWithTag(row("pluginsTools")).getUnclippedBoundsInRoot()
        val firstPermissionsRow = compose.onNodeWithTag(row("permissionDefaults")).getUnclippedBoundsInRoot()
        val header = compose.onNodeWithTag(SETTINGS_INDEX_GROUP_PREFIX + "permissionsPrivacy")
            .getUnclippedBoundsInRoot()

        assertEquals(57.0f, (firstPermissionsRow.top - lastModelsRow.bottom).value, 0.01f)
        // The header text lives inside that band, not above or below it.
        assertEquals(lastModelsRow.bottom.value, header.top.value, 0.01f)
        assertEquals(firstPermissionsRow.top.value, header.bottom.value, 0.01f)
        val headerText = compose.onNodeWithText(UiStrings.SETTINGS_SECTION_PERMISSIONS_PRIVACY)
            .getUnclippedBoundsInRoot()
        assertTrue(headerText.top >= header.top)
        assertTrue(headerText.bottom <= header.bottom)
        // Bottom-aligned `cardInset` (12 pt) above the next card, as measured on
        // the iOS export's header ink.
        assertEquals(12.0f, (header.bottom - headerText.bottom).value, 0.5f)
    }

    @Test
    fun `the first titled section keeps the measured first-section header block`() {
        show()
        val header = compose.onNodeWithTag(SETTINGS_INDEX_GROUP_PREFIX + "modelsAgents")
            .getUnclippedBoundsInRoot()
        assertEquals(
            SettingsMetrics.ROOT_FIRST_SECTION_HEIGHT_PT,
            (header.bottom - header.top).value,
            0.5f,
        )
    }

    @Test
    fun `done keeps its label and action at 58 by 36`() {
        show()
        val done = compose.onNodeWithTag(UiPageTags.SETTINGS_DONE)
        done.assertWidthIsEqualTo(SettingsMetrics.DONE_BUTTON_WIDTH_PT.dp)
        done.assertHeightIsEqualTo(SettingsMetrics.DONE_BUTTON_HEIGHT_PT.dp)
        compose.onNodeWithText(UiStrings.SETTINGS_DONE).assertExists()

        done.performClick()
        assertEquals(1, backCount)
    }
}
